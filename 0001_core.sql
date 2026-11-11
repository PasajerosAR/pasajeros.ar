-- Fase 1: nucleo operativo multiempresa.
-- Aislamiento por empresa con RLS. La logica critica (viajes, jornada, contador)
-- va en funciones del servidor, no en el cliente.

-- ---------------------------------------------------------------- tipos
create type public.user_role     as enum ('platform_admin', 'company_admin', 'support', 'driver');
create type public.vehicle_kind  as enum ('combi', 'colectivo');
create type public.vehicle_status as enum ('available', 'assigned', 'in_service', 'maintenance', 'out_of_service', 'retired');
create type public.cell_kind     as enum ('seat', 'aisle', 'empty', 'driver', 'door', 'stairs', 'toilet', 'trunk');
create type public.trip_status   as enum ('scheduled', 'in_progress', 'completed', 'cancelled');
create type public.count_kind    as enum ('board', 'alight');

-- ---------------------------------------------------------------- empresas y perfiles
create table public.companies (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (length(trim(name)) > 0),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  company_id uuid references public.companies (id),
  role       public.user_role not null,
  full_name  text not null check (length(trim(full_name)) > 0),
  dni        text,
  phone      text,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  constraint profile_company_required check (role = 'platform_admin' or company_id is not null)
);
create index profiles_company_idx on public.profiles (company_id);

-- Funciones auxiliares. security definer para leer profiles sin recursion de RLS.
create function public.current_company_id() returns uuid
language sql stable security definer set search_path = public as $$
  select company_id from public.profiles where id = auth.uid() and active
$$;

create function public.current_user_role() returns public.user_role
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid() and active
$$;

create function public.is_company_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.current_user_role() = 'company_admin', false)
$$;

create function public.is_platform_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.current_user_role() = 'platform_admin', false)
$$;

-- ---------------------------------------------------------------- disposiciones de asientos (versionadas)
create table public.seat_layouts (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.companies (id),
  group_id    uuid not null default gen_random_uuid(),  -- agrupa las versiones de una misma disposicion
  version     int  not null default 1 check (version >= 1),
  name        text not null check (length(trim(name)) > 0),
  is_template boolean not null default false,
  locked_at   timestamptz,                               -- se fija cuando un viaje la usa: pasa a ser inmutable
  created_at  timestamptz not null default now(),
  unique (group_id, version)
);
create index seat_layouts_company_idx on public.seat_layouts (company_id);

create table public.layout_floors (
  layout_id  uuid not null references public.seat_layouts (id) on delete cascade,
  company_id uuid not null references public.companies (id),
  floor      int  not null check (floor between 1 and 2),
  rows       int  not null check (rows between 1 and 30),
  cols       int  not null check (cols between 1 and 12),
  primary key (layout_id, floor)
);

create table public.layout_cells (
  id          uuid primary key default gen_random_uuid(),
  layout_id   uuid not null references public.seat_layouts (id) on delete cascade,
  company_id  uuid not null references public.companies (id),
  floor       int  not null check (floor between 1 and 2),
  row_idx     int  not null check (row_idx >= 0),
  col_idx     int  not null check (col_idx >= 0),
  kind        public.cell_kind not null,
  label       text,                                      -- numero o etiqueta del asiento
  accessible  boolean not null default false,
  blocked     boolean not null default false,            -- bloqueado por la empresa
  unusable    boolean not null default false,
  unique (layout_id, floor, row_idx, col_idx),
  constraint cell_flags_only_seats check (kind = 'seat' or (not accessible and not blocked and not unusable and label is null))
);
create index layout_cells_layout_idx on public.layout_cells (layout_id);

-- Capacidad calculada desde la grilla (no se carga aparte).
create view public.seat_layout_capacity with (security_invoker = true) as
select l.id as layout_id,
       count(c.id) filter (where c.kind = 'seat' and not c.unusable) as seats
from public.seat_layouts l
left join public.layout_cells c on c.layout_id = l.id
group by l.id;

-- ---------------------------------------------------------------- flota
create table public.vehicles (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies (id),
  kind            public.vehicle_kind not null,
  internal_number text not null,
  plate           text not null,
  brand           text,
  model           text,
  year            int check (year between 1980 and 2100),
  status          public.vehicle_status not null default 'available',
  layout_id       uuid references public.seat_layouts (id),
  notes           text,
  created_at      timestamptz not null default now(),
  unique (company_id, plate),
  unique (company_id, internal_number)
);
create index vehicles_company_idx on public.vehicles (company_id);

-- ---------------------------------------------------------------- recorridos y servicios
create table public.routes (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id),
  name       text not null check (length(trim(name)) > 0),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
create index routes_company_idx on public.routes (company_id);

create table public.route_stops (
  id                 uuid primary key default gen_random_uuid(),
  company_id         uuid not null references public.companies (id),
  route_id           uuid not null references public.routes (id) on delete cascade,
  position           int  not null check (position >= 1),
  name               text not null check (length(trim(name)) > 0),
  lat                numeric(9, 6),
  lng                numeric(9, 6),
  minutes_from_start int  not null default 0 check (minutes_from_start >= 0),
  dwell_minutes      int  not null default 0 check (dwell_minutes >= 0),
  unique (route_id, position)
);
create index route_stops_route_idx on public.route_stops (route_id);

create table public.services (
  id             uuid primary key default gen_random_uuid(),
  company_id     uuid not null references public.companies (id),
  code           text not null check (length(trim(code)) > 0),
  route_id       uuid not null references public.routes (id),
  departure_time time not null,
  days_of_week   smallint[] not null default '{1,2,3,4,5,6,7}'
                 check (days_of_week <@ array[1,2,3,4,5,6,7]::smallint[] and cardinality(days_of_week) > 0),
  active         boolean not null default true,
  created_at     timestamptz not null default now(),
  unique (company_id, code)
);
create index services_company_idx on public.services (company_id);

-- ---------------------------------------------------------------- viajes, jornadas, contador
create table public.trips (
  id                   uuid primary key default gen_random_uuid(),
  company_id           uuid not null references public.companies (id),
  service_id           uuid not null references public.services (id),
  service_date         date not null,
  scheduled_departure  timestamptz not null,
  vehicle_id           uuid references public.vehicles (id),
  layout_id            uuid references public.seat_layouts (id),  -- foto de la disposicion al asignar el vehiculo
  driver_id            uuid references public.profiles (id),
  status               public.trip_status not null default 'scheduled',
  started_at           timestamptz,
  ended_at             timestamptz,
  started_manually     boolean not null default false,
  start_reason         text,
  created_at           timestamptz not null default now(),
  unique (service_id, service_date)
);
create index trips_company_date_idx on public.trips (company_id, service_date);
create index trips_driver_idx on public.trips (driver_id, service_date);

create table public.shifts (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id),
  driver_id  uuid not null references public.profiles (id),
  started_at timestamptz not null default now(),
  ended_at   timestamptz
);
create unique index shifts_one_open_per_driver on public.shifts (driver_id) where ended_at is null;

create table public.passenger_counts (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies (id),
  trip_id         uuid not null references public.trips (id),
  stop_id         uuid references public.route_stops (id),
  kind            public.count_kind not null,
  quantity        int  not null check (quantity > 0),
  recorded_by     uuid not null references public.profiles (id),
  client_event_id uuid not null,               -- idempotencia: el mismo evento no se registra dos veces
  recorded_at     timestamptz not null default now(),
  unique (trip_id, client_event_id)
);
create index passenger_counts_trip_idx on public.passenger_counts (trip_id);

create table public.audit_log (
  id         bigint generated always as identity primary key,
  company_id uuid,
  actor_id   uuid,
  action     text not null,
  entity     text not null,
  entity_id  uuid,
  details    jsonb,
  created_at timestamptz not null default now()
);
create index audit_log_company_idx on public.audit_log (company_id, created_at desc);

-- ---------------------------------------------------------------- auditoria
create function public.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_row jsonb;
begin
  v_row := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  insert into public.audit_log (company_id, actor_id, action, entity, entity_id, details)
  values (
    nullif(v_row ->> 'company_id', '')::uuid,
    auth.uid(),
    lower(tg_op),
    tg_table_name,
    nullif(v_row ->> 'id', '')::uuid,
    case when tg_op = 'UPDATE' then jsonb_build_object('old', to_jsonb(old), 'new', to_jsonb(new)) else v_row end
  );
  return null;
end $$;

create trigger audit_vehicles   after insert or update or delete on public.vehicles     for each row execute function public.audit_row();
create trigger audit_layouts    after insert or update or delete on public.seat_layouts for each row execute function public.audit_row();
create trigger audit_routes     after insert or update or delete on public.routes       for each row execute function public.audit_row();
create trigger audit_services   after insert or update or delete on public.services     for each row execute function public.audit_row();
create trigger audit_trips      after insert or update or delete on public.trips        for each row execute function public.audit_row();
create trigger audit_profiles   after insert or update or delete on public.profiles     for each row execute function public.audit_row();

-- ---------------------------------------------------------------- disposiciones en uso son inmutables
create function public.guard_locked_layout() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_layout uuid := case when tg_op = 'DELETE' then old.layout_id else new.layout_id end;
begin
  if exists (select 1 from public.seat_layouts where id = v_layout and locked_at is not null) then
    raise exception 'LAYOUT_LOCKED: la disposición está en uso por viajes; cree una versión nueva';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

create trigger guard_cells  before insert or update or delete on public.layout_cells  for each row execute function public.guard_locked_layout();
create trigger guard_floors before insert or update or delete on public.layout_floors for each row execute function public.guard_locked_layout();

create function public.guard_locked_layout_row() returns trigger
language plpgsql as $$
begin
  if old.locked_at is not null then
    raise exception 'LAYOUT_LOCKED: la disposición está en uso por viajes; cree una versión nueva';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

create trigger guard_layout_row before update or delete on public.seat_layouts for each row execute function public.guard_locked_layout_row();

-- Crea la version siguiente de una disposicion copiando filas, columnas y celdas.
create function public.clone_layout(p_layout uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_src public.seat_layouts;
  v_new uuid;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  select * into v_src from public.seat_layouts where id = p_layout and company_id = public.current_company_id();
  if not found then raise exception 'NOT_FOUND'; end if;

  insert into public.seat_layouts (company_id, group_id, version, name, is_template)
  values (v_src.company_id, v_src.group_id,
          (select max(version) + 1 from public.seat_layouts where group_id = v_src.group_id),
          v_src.name, v_src.is_template)
  returning id into v_new;

  insert into public.layout_floors (layout_id, company_id, floor, rows, cols)
  select v_new, company_id, floor, rows, cols from public.layout_floors where layout_id = p_layout;

  insert into public.layout_cells (layout_id, company_id, floor, row_idx, col_idx, kind, label, accessible, blocked, unusable)
  select v_new, company_id, floor, row_idx, col_idx, kind, label, accessible, blocked, unusable
  from public.layout_cells where layout_id = p_layout;

  return v_new;
end $$;

-- ---------------------------------------------------------------- reglas de viajes
create function public.guard_trip() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_vehicle public.vehicles;
  v_driver  public.profiles;
begin
  if new.vehicle_id is not null and (tg_op = 'INSERT' or new.vehicle_id is distinct from old.vehicle_id) then
    if tg_op = 'UPDATE' and old.status <> 'scheduled' then
      raise exception 'TRIP_NOT_EDITABLE: no se puede cambiar el vehículo de un viaje iniciado o cerrado';
    end if;
    select * into v_vehicle from public.vehicles where id = new.vehicle_id;
    if v_vehicle.company_id <> new.company_id then raise exception 'VEHICLE_OTHER_COMPANY'; end if;
    new.layout_id := v_vehicle.layout_id;
  end if;

  if new.driver_id is not null and (tg_op = 'INSERT' or new.driver_id is distinct from old.driver_id) then
    select * into v_driver from public.profiles where id = new.driver_id;
    if v_driver.company_id is distinct from new.company_id or v_driver.role <> 'driver' then
      raise exception 'DRIVER_INVALID: el conductor no pertenece a la empresa';
    end if;
  end if;

  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if not ((old.status = 'scheduled'   and new.status in ('in_progress', 'cancelled'))
         or (old.status = 'in_progress' and new.status = 'completed')) then
      raise exception 'INVALID_TRANSITION: % -> %', old.status, new.status;
    end if;
    -- iniciar y finalizar solo mediante las funciones start_trip, end_trip, admin_start_trip
    if new.status in ('in_progress', 'completed')
       and coalesce(current_setting('app.trip_rpc', true), '') <> 'on' then
      raise exception 'USE_RPC: el estado se cambia con start_trip / end_trip';
    end if;
  end if;
  return new;
end $$;

create trigger guard_trip before insert or update on public.trips for each row execute function public.guard_trip();

-- Al asignar una disposicion a un viaje, queda bloqueada.
create function public.lock_layout_on_trip() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.layout_id is not null then
    update public.seat_layouts set locked_at = now() where id = new.layout_id and locked_at is null;
  end if;
  return null;
end $$;

-- Sin "update of layout_id": layout_id lo completa guard_trip, y Postgres no cuenta ese cambio.
create trigger lock_layout_on_trip after insert or update on public.trips
  for each row when (new.layout_id is not null) execute function public.lock_layout_on_trip();

-- ---------------------------------------------------------------- funciones de operacion
create function public.trip_onboard(p_trip uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(case kind when 'board' then quantity else -quantity end), 0)::int
  from public.passenger_counts
  where trip_id = p_trip and company_id = public.current_company_id()
$$;

-- Crea los viajes del dia segun los servicios activos (idempotente).
create function public.generate_trips(p_date date) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := public.current_company_id();
  v_n int;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  insert into public.trips (company_id, service_id, service_date, scheduled_departure)
  select s.company_id, s.id, p_date, (p_date + s.departure_time) at time zone 'America/Argentina/Buenos_Aires'
  from public.services s
  where s.company_id = v_company and s.active
    and extract(isodow from p_date)::int = any (s.days_of_week)
  on conflict (service_id, service_date) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

create function public.start_shift() returns public.shifts
language plpgsql security definer set search_path = public as $$
declare
  v_row public.shifts;
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;
  select * into v_row from public.shifts where driver_id = auth.uid() and ended_at is null;
  if found then return v_row; end if;
  insert into public.shifts (company_id, driver_id) values (public.current_company_id(), auth.uid())
  returning * into v_row;
  return v_row;
end $$;

create function public.end_shift() returns public.shifts
language plpgsql security definer set search_path = public as $$
declare
  v_row public.shifts;
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;
  if exists (select 1 from public.trips where driver_id = auth.uid() and status = 'in_progress') then
    raise exception 'TRIP_IN_PROGRESS: finalice el viaje antes de cerrar la jornada';
  end if;
  update public.shifts set ended_at = now() where driver_id = auth.uid() and ended_at is null
  returning * into v_row;
  if not found then raise exception 'NO_OPEN_SHIFT'; end if;
  return v_row;
end $$;

create function public.start_trip(p_trip uuid) returns public.trips
language plpgsql security definer set search_path = public as $$
declare
  v_trip    public.trips;
  v_vehicle public.vehicles;
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;
  select * into v_trip from public.trips
   where id = p_trip and driver_id = auth.uid() and company_id = public.current_company_id()
   for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_trip.status <> 'scheduled' then raise exception 'INVALID_STATE: el viaje no está programado'; end if;
  if not exists (select 1 from public.shifts where driver_id = auth.uid() and ended_at is null) then
    raise exception 'NO_OPEN_SHIFT: inicie la jornada primero';
  end if;
  if exists (select 1 from public.trips where driver_id = auth.uid() and status = 'in_progress') then
    raise exception 'TRIP_IN_PROGRESS: ya tiene un viaje en curso';
  end if;
  if v_trip.vehicle_id is null then raise exception 'NO_VEHICLE: el viaje no tiene vehículo asignado'; end if;
  select * into v_vehicle from public.vehicles where id = v_trip.vehicle_id;
  if v_vehicle.status in ('maintenance', 'out_of_service', 'retired') then
    raise exception 'VEHICLE_UNAVAILABLE: el vehículo no está disponible';
  end if;

  perform set_config('app.trip_rpc', 'on', true);
  update public.trips set status = 'in_progress', started_at = now() where id = p_trip
  returning * into v_trip;
  return v_trip;
end $$;

-- Inicio manual por un administrador (viaje que el conductor no inicio). Exige motivo.
create function public.admin_start_trip(p_trip uuid, p_reason text) returns public.trips
language plpgsql security definer set search_path = public as $$
declare
  v_trip public.trips;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if p_reason is null or length(trim(p_reason)) < 3 then raise exception 'REASON_REQUIRED'; end if;
  select * into v_trip from public.trips
   where id = p_trip and company_id = public.current_company_id() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_trip.status <> 'scheduled' then raise exception 'INVALID_STATE: el viaje no está programado'; end if;
  if v_trip.vehicle_id is null then raise exception 'NO_VEHICLE: el viaje no tiene vehículo asignado'; end if;

  perform set_config('app.trip_rpc', 'on', true);
  update public.trips
     set status = 'in_progress', started_at = now(), started_manually = true, start_reason = trim(p_reason)
   where id = p_trip returning * into v_trip;
  return v_trip;
end $$;

create function public.end_trip(p_trip uuid, p_force boolean default false) returns public.trips
language plpgsql security definer set search_path = public as $$
declare
  v_trip public.trips;
  v_onboard int;
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;
  select * into v_trip from public.trips
   where id = p_trip and driver_id = auth.uid() and company_id = public.current_company_id()
   for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_trip.status <> 'in_progress' then raise exception 'INVALID_STATE: el viaje no está en curso'; end if;

  v_onboard := public.trip_onboard(p_trip);
  if v_onboard > 0 and not p_force then
    raise exception 'ONBOARD_REMAINING: quedan % pasajeros a bordo', v_onboard;
  end if;

  perform set_config('app.trip_rpc', 'on', true);
  update public.trips set status = 'completed', ended_at = now() where id = p_trip
  returning * into v_trip;
  return v_trip;
end $$;

-- Registra ascensos o descensos. Idempotente por client_event_id; nunca deja el conteo negativo.
create function public.register_count(
  p_trip uuid, p_kind public.count_kind, p_quantity int, p_stop uuid, p_event uuid
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_trip     public.trips;
  v_onboard  int;
  v_capacity int;
  v_inserted int;
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;
  if p_quantity is null or p_quantity < 1 then raise exception 'INVALID_QUANTITY'; end if;

  -- bloquea el viaje para serializar registros concurrentes
  select * into v_trip from public.trips
   where id = p_trip and driver_id = auth.uid() and company_id = public.current_company_id()
   for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_trip.status <> 'in_progress' then raise exception 'INVALID_STATE: el viaje no está en curso'; end if;

  if p_stop is not null and not exists (
    select 1 from public.route_stops rs join public.services s on s.route_id = rs.route_id
     where rs.id = p_stop and s.id = v_trip.service_id) then
    raise exception 'STOP_NOT_IN_ROUTE';
  end if;

  v_onboard := public.trip_onboard(p_trip);
  if exists (select 1 from public.passenger_counts where trip_id = p_trip and client_event_id = p_event) then
    -- evento repetido: no se vuelve a aplicar
    null;
  else
    if p_kind = 'alight' and p_quantity > v_onboard then
      raise exception 'NEGATIVE_COUNT: no pueden bajar % si hay % a bordo', p_quantity, v_onboard;
    end if;
    insert into public.passenger_counts (company_id, trip_id, stop_id, kind, quantity, recorded_by, client_event_id)
    values (v_trip.company_id, p_trip, p_stop, p_kind, p_quantity, auth.uid(), p_event)
    on conflict (trip_id, client_event_id) do nothing;
    get diagnostics v_inserted = row_count;
    if v_inserted = 1 then
      v_onboard := v_onboard + case p_kind when 'board' then p_quantity else -p_quantity end;
    end if;
  end if;

  select coalesce(c.seats, 0) into v_capacity
    from public.seat_layout_capacity c where c.layout_id = v_trip.layout_id;

  return jsonb_build_object(
    'onboard', v_onboard,
    'capacity', coalesce(v_capacity, 0),
    'over_capacity', coalesce(v_capacity, 0) > 0 and v_onboard > v_capacity
  );
end $$;

-- ---------------------------------------------------------------- RLS
alter table public.companies        enable row level security;
alter table public.profiles         enable row level security;
alter table public.seat_layouts     enable row level security;
alter table public.layout_floors    enable row level security;
alter table public.layout_cells     enable row level security;
alter table public.vehicles         enable row level security;
alter table public.routes           enable row level security;
alter table public.route_stops      enable row level security;
alter table public.services         enable row level security;
alter table public.trips            enable row level security;
alter table public.shifts           enable row level security;
alter table public.passenger_counts enable row level security;
alter table public.audit_log        enable row level security;

-- empresas
create policy companies_select on public.companies for select to authenticated
  using (id = public.current_company_id() or public.is_platform_admin());
create policy companies_platform on public.companies for all to authenticated
  using (public.is_platform_admin()) with check (public.is_platform_admin());

-- perfiles: el alta de usuarios se hace con la funcion de servidor (service role)
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid()
         or public.is_platform_admin()
         or (company_id = public.current_company_id()
             and public.current_user_role() in ('company_admin', 'support')));
create policy profiles_update_admin on public.profiles for update to authenticated
  using (company_id = public.current_company_id() and public.is_company_admin())
  with check (company_id = public.current_company_id() and role <> 'platform_admin');

-- tablas de la empresa: lectura para el personal, escritura solo administrador
do $$
declare t text;
begin
  foreach t in array array['seat_layouts', 'layout_floors', 'layout_cells', 'vehicles', 'routes', 'route_stops', 'services']
  loop
    execute format('create policy %I on public.%I for select to authenticated using (company_id = public.current_company_id())',
                   t || '_select', t);
    execute format('create policy %I on public.%I for all to authenticated
                    using (company_id = public.current_company_id() and public.is_company_admin())
                    with check (company_id = public.current_company_id() and public.is_company_admin())',
                   t || '_admin', t);
  end loop;
end $$;

-- viajes: el conductor ve solo los suyos
create policy trips_select on public.trips for select to authenticated
  using (company_id = public.current_company_id()
         and (public.current_user_role() <> 'driver' or driver_id = auth.uid()));
create policy trips_admin on public.trips for all to authenticated
  using (company_id = public.current_company_id() and public.is_company_admin())
  with check (company_id = public.current_company_id() and public.is_company_admin());

-- jornadas y contador: lectura; la escritura es solo por funciones
create policy shifts_select on public.shifts for select to authenticated
  using (company_id = public.current_company_id()
         and (public.current_user_role() <> 'driver' or driver_id = auth.uid()));
create policy counts_select on public.passenger_counts for select to authenticated
  using (company_id = public.current_company_id()
         and (public.current_user_role() <> 'driver'
              or exists (select 1 from public.trips t where t.id = trip_id and t.driver_id = auth.uid())));
create policy audit_select on public.audit_log for select to authenticated
  using (company_id = public.current_company_id() and public.is_company_admin());

-- ---------------------------------------------------------------- permisos de funciones
revoke all on function
  public.clone_layout(uuid), public.generate_trips(date), public.start_shift(), public.end_shift(),
  public.start_trip(uuid), public.admin_start_trip(uuid, text), public.end_trip(uuid, boolean),
  public.register_count(uuid, public.count_kind, int, uuid, uuid), public.trip_onboard(uuid)
from public, anon;

grant execute on function
  public.clone_layout(uuid), public.generate_trips(date), public.start_shift(), public.end_shift(),
  public.start_trip(uuid), public.admin_start_trip(uuid, text), public.end_trip(uuid, boolean),
  public.register_count(uuid, public.count_kind, int, uuid, uuid), public.trip_onboard(uuid)
to authenticated;
