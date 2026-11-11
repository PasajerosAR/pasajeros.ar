-- Un servicio ("214") agrupa varias salidas, de ida y de vuelta, cada una con su horario y sus dias.
--   services            -> codigo y estado del servicio
--   service_departures  -> cada salida: recorrido (sentido), hora, dias
--   service_stops       -> tiempos por parada (iguales para todas las salidas del mismo sentido)
--   trips               -> un viaje por salida y por dia

create table public.service_departures (
  id             uuid primary key default gen_random_uuid(),
  service_id     uuid not null references public.services (id) on delete cascade,
  company_id     uuid not null references public.companies (id),
  route_id       uuid not null references public.routes (id),
  departure_time time not null,
  days_of_week   smallint[] not null default '{1,2,3,4,5,6,7}'
                 check (days_of_week <@ array[1,2,3,4,5,6,7]::smallint[] and cardinality(days_of_week) > 0),
  active         boolean not null default true,
  created_at     timestamptz not null default now(),
  unique (service_id, route_id, departure_time)
);
create index service_departures_service_idx on public.service_departures (service_id);
create index service_departures_company_idx on public.service_departures (company_id);
alter table public.service_departures enable row level security;
create policy service_departures_select on public.service_departures for select to authenticated
  using (company_id = public.current_company_id());
create policy service_departures_update on public.service_departures for update to authenticated
  using (company_id = public.current_company_id() and public.is_company_admin())
  with check (company_id = public.current_company_id() and public.is_company_admin());
create trigger audit_departures after insert or update or delete on public.service_departures
  for each row execute function public.audit_row();

-- ---------------------------------------------------------------- migrar lo existente: cada servicio pasa a tener una salida
insert into public.service_departures (service_id, company_id, route_id, departure_time, days_of_week, active)
select id, company_id, route_id, departure_time, days_of_week, active from public.services;

alter table public.trips add column departure_id uuid references public.service_departures (id);
update public.trips t set departure_id = d.id from public.service_departures d where d.service_id = t.service_id;
alter table public.trips alter column departure_id set not null;
alter table public.trips drop constraint trips_service_id_service_date_key;
alter table public.trips add constraint trips_departure_date_key unique (departure_id, service_date);
create index trips_departure_idx on public.trips (departure_id);

-- ---------------------------------------------------------------- limpiar services
drop trigger guard_service_route on public.services;
drop trigger guard_service_company on public.services;
drop function public.guard_service_route();
drop function public.guard_service_company();
alter table public.services drop column route_id, drop column departure_time, drop column days_of_week;

-- Cada salida usa un recorrido de su empresa; el recorrido solo cambia por save_service.
create function public.guard_departure() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.routes where id = new.route_id and company_id = new.company_id) then
    raise exception 'ROUTE_INVALID: el recorrido no pertenece a esta empresa';
  end if;
  if tg_op = 'UPDATE' and (new.route_id <> old.route_id or new.departure_time <> old.departure_time
                           or new.days_of_week <> old.days_of_week)
     and coalesce(current_setting('app.service_rpc', true), '') <> 'on' then
    raise exception 'USE_RPC: la salida se edita con save_service';
  end if;
  return new;
end $$;
create trigger guard_departure before insert or update on public.service_departures
  for each row execute function public.guard_departure();

-- ---------------------------------------------------------------- generar viajes: uno por salida y dia
create or replace function public.generate_trips(p_date date) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := public.current_company_id();
  v_n int;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  insert into public.trips (company_id, service_id, departure_id, service_date, scheduled_departure)
  select d.company_id, d.service_id, d.id, p_date, (p_date + d.departure_time) at time zone 'America/Argentina/Buenos_Aires'
  from public.service_departures d
  join public.services s on s.id = d.service_id
  where d.company_id = v_company and s.active and d.active
    and extract(isodow from p_date)::int = any (d.days_of_week)
  on conflict (departure_id, service_date) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

create or replace function public.register_count(
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
    select 1 from public.route_stops rs join public.service_departures d on d.route_id = rs.route_id
     where rs.id = p_stop and d.id = v_trip.departure_id) then
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

-- ---------------------------------------------------------------- guardar un servicio completo
-- p_departures = [{id?, route_id, time, days:[..], active}]
-- p_stops      = [{route_stop_id, minutes_from_start, dwell_minutes}] de TODAS las paradas de TODOS los recorridos usados
drop function public.save_service(uuid, text, uuid, time, int[], boolean, jsonb);
create function public.save_service(
  p_service uuid, p_code text, p_active boolean, p_departures jsonb, p_stops jsonb
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_company  uuid := public.current_company_id();
  v_id       uuid;
  v_routes   uuid[];
  v_expected int;
  v_prev     int;
  v_keep     uuid[];
  v_dep      jsonb;
  v_dep_id   uuid;
  v_old      public.service_departures;
  v_days     smallint[];
  r          record;
  rt         uuid;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if p_code is null or length(trim(p_code)) = 0 then raise exception 'CODE_REQUIRED: falta el codigo del servicio'; end if;
  if p_departures is null or jsonb_typeof(p_departures) <> 'array' or jsonb_array_length(p_departures) = 0 then
    raise exception 'DEPARTURES_REQUIRED: agregue al menos una salida';
  end if;
  if p_stops is null or jsonb_typeof(p_stops) <> 'array' then raise exception 'STOPS_MISMATCH: faltan los tiempos de las paradas'; end if;

  -- validar cada salida
  for v_dep in select * from jsonb_array_elements(p_departures) loop
    if coalesce(v_dep ->> 'time', '') = '' then raise exception 'TIME_REQUIRED: falta la hora de una salida'; end if;
    select coalesce(array_agg(x::smallint), '{}') into v_days from jsonb_array_elements_text(coalesce(v_dep -> 'days', '[]'::jsonb)) x;
    if cardinality(v_days) = 0 or not (v_days <@ array[1,2,3,4,5,6,7]::smallint[]) then
      raise exception 'DAYS_INVALID: elija al menos un dia en cada salida';
    end if;
    if not exists (select 1 from public.routes where id = (v_dep ->> 'route_id')::uuid and active and company_id = v_company) then
      raise exception 'ROUTE_INVALID: el recorrido no existe, no esta activo o no es de su empresa';
    end if;
  end loop;
  if (select count(*) from jsonb_array_elements(p_departures) e)
     <> (select count(distinct (e ->> 'route_id') || '|' || (e ->> 'time')) from jsonb_array_elements(p_departures) e) then
    raise exception 'DEPARTURE_DUPLICATED: hay dos salidas iguales (mismo sentido y hora)';
  end if;

  select array_agg(distinct (e ->> 'route_id')::uuid) into v_routes from jsonb_array_elements(p_departures) e;

  -- tiempos: exactamente las paradas de los recorridos usados, sin repetir
  select count(*) into v_expected from public.route_stops where route_id = any (v_routes);
  if jsonb_array_length(p_stops) <> v_expected
     or (select count(distinct e ->> 'route_stop_id') from jsonb_array_elements(p_stops) e) <> v_expected
     or exists (select 1 from jsonb_array_elements(p_stops) e
                 where not exists (select 1 from public.route_stops rs
                                    where rs.route_id = any (v_routes) and rs.id::text = e ->> 'route_stop_id')) then
    raise exception 'STOPS_MISMATCH: los tiempos deben cubrir todas las paradas de los recorridos del servicio';
  end if;
  foreach rt in array v_routes loop
    v_prev := 0;
    for r in
      select rs.position, coalesce((e ->> 'minutes_from_start')::int, -1) as m
        from public.route_stops rs
        join jsonb_array_elements(p_stops) e on e ->> 'route_stop_id' = rs.id::text
       where rs.route_id = rt order by rs.position
    loop
      if r.m < 0 then raise exception 'TIMES_INVALID: falta el minuto de la parada %', r.position; end if;
      if r.position = 1 and r.m <> 0 then raise exception 'TIMES_INVALID: la primera parada sale en el minuto 0'; end if;
      if r.m < v_prev then raise exception 'TIMES_INVALID: los minutos no pueden disminuir entre paradas'; end if;
      v_prev := r.m;
    end loop;
  end loop;

  -- servicio
  if p_service is null then
    insert into public.services (company_id, code, active) values (v_company, trim(p_code), coalesce(p_active, true))
    returning id into v_id;
  else
    perform 1 from public.services where id = p_service and company_id = v_company for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    update public.services set code = trim(p_code), active = coalesce(p_active, active) where id = p_service;
    v_id := p_service;
  end if;
  perform set_config('app.service_rpc', 'on', true);

  -- salidas: actualizar las que vienen con id, crear las nuevas, quitar las que no vienen
  v_keep := '{}';
  for v_dep in select * from jsonb_array_elements(p_departures) loop
    select coalesce(array_agg(x::smallint), '{}') into v_days from jsonb_array_elements_text(v_dep -> 'days') x;
    v_dep_id := nullif(v_dep ->> 'id', '')::uuid;
    if v_dep_id is null then
      insert into public.service_departures (service_id, company_id, route_id, departure_time, days_of_week, active)
      values (v_id, v_company, (v_dep ->> 'route_id')::uuid, (v_dep ->> 'time')::time, v_days, coalesce((v_dep ->> 'active')::boolean, true))
      returning id into v_dep_id;
    else
      select * into v_old from public.service_departures where id = v_dep_id and service_id = v_id and company_id = v_company for update;
      if not found then raise exception 'NOT_FOUND'; end if;
      if v_old.route_id <> (v_dep ->> 'route_id')::uuid and exists (select 1 from public.trips where departure_id = v_dep_id) then
        raise exception 'ROUTE_LOCKED: la salida ya tiene viajes; cree una nueva para cambiar de sentido';
      end if;
      update public.service_departures
         set route_id = (v_dep ->> 'route_id')::uuid, departure_time = (v_dep ->> 'time')::time,
             days_of_week = v_days, active = coalesce((v_dep ->> 'active')::boolean, true)
       where id = v_dep_id;
    end if;
    v_keep := v_keep || v_dep_id;
  end loop;
  if exists (select 1 from public.service_departures d
              where d.service_id = v_id and d.id <> all (v_keep)
                and exists (select 1 from public.trips t where t.departure_id = d.id)) then
    raise exception 'DEPARTURE_HAS_TRIPS: una salida con viajes no se puede quitar; pausela';
  end if;
  delete from public.service_departures where service_id = v_id and id <> all (v_keep);

  delete from public.service_stops where service_id = v_id;
  insert into public.service_stops (service_id, route_stop_id, company_id, minutes_from_start, dwell_minutes)
  select v_id, (e ->> 'route_stop_id')::uuid, v_company,
         (e ->> 'minutes_from_start')::int, coalesce((e ->> 'dwell_minutes')::int, 0)
  from jsonb_array_elements(p_stops) e;
  return v_id;
end $$;

revoke all on function public.save_service(uuid, text, boolean, jsonb, jsonb) from public, anon;
grant execute on function public.save_service(uuid, text, boolean, jsonb, jsonb) to authenticated;


-- save_route: un recorrido esta en uso si alguna salida lo usa
create or replace function public.save_route(p_route uuid, p_name text, p_active boolean, p_stops jsonb, p_company uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_n  int;
  v_prev_company uuid;
begin
  if not public.is_platform_admin() then raise exception 'FORBIDDEN'; end if;
  if p_name is null or length(trim(p_name)) = 0 then raise exception 'NAME_REQUIRED: falta el nombre del recorrido'; end if;
  if p_company is null or not exists (select 1 from public.companies where id = p_company) then
    raise exception 'COMPANY_REQUIRED: elija la empresa duena del recorrido';
  end if;
  if p_stops is null or jsonb_typeof(p_stops) <> 'array' or jsonb_array_length(p_stops) < 2 then
    raise exception 'STOPS_REQUIRED: el recorrido necesita al menos origen y destino';
  end if;

  if p_route is null then
    insert into public.routes (name, active, company_id) values (trim(p_name), coalesce(p_active, true), p_company) returning id into v_id;
  else
    select company_id into v_prev_company from public.routes where id = p_route for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    if v_prev_company is distinct from p_company and exists (select 1 from public.service_departures where route_id = p_route) then
      raise exception 'COMPANY_LOCKED: hay servicios con este recorrido; no se puede cambiar de empresa';
    end if;
    update public.routes set name = trim(p_name), active = coalesce(p_active, active), company_id = p_company
     where id = p_route returning id into v_id;

    if exists (select 1 from public.service_departures where route_id = v_id) then
      select count(*) into v_n from public.route_stops where route_id = v_id;
      if jsonb_array_length(p_stops) <> v_n then
        raise exception 'ROUTE_IN_USE: hay servicios con este recorrido; solo se pueden corregir nombres y coordenadas';
      end if;
      update public.route_stops rs
         set name = trim(s.e ->> 'name'),
             lat = nullif(s.e ->> 'lat', '')::numeric,
             lng = nullif(s.e ->> 'lng', '')::numeric
        from jsonb_array_elements(p_stops) with ordinality as s(e, ord)
       where rs.route_id = v_id and rs.position = s.ord::int;
      return v_id;
    end if;
    delete from public.route_stops where route_id = v_id;
  end if;

  insert into public.route_stops (route_id, position, name, lat, lng)
  select v_id, s.ord::int, trim(s.e ->> 'name'), nullif(s.e ->> 'lat', '')::numeric, nullif(s.e ->> 'lng', '')::numeric
  from jsonb_array_elements(p_stops) with ordinality as s(e, ord);
  return v_id;
end $$;
