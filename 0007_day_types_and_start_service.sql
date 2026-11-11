-- Tipos de dia, iniciar servicio desde la app del conductor e incidencias.
--   Cada salida indica en que tipos de dia circula: weekday (habil), saturday, sunday, holiday (feriado).
--   No hay calendario de feriados: el tipo de dia lo elige quien inicia el servicio (o quien genera los viajes).

-- ---------------------------------------------------------------- tipos de dia
alter table public.service_departures add column day_types text[];
update public.service_departures set day_types = array_remove(array[
  case when days_of_week && array[1,2,3,4,5]::smallint[] then 'weekday' end,
  case when 6 = any (days_of_week) then 'saturday' end,
  case when 7 = any (days_of_week) then 'sunday' end], null);
alter table public.service_departures alter column day_types set not null;
alter table public.service_departures add constraint service_departures_day_types_check
  check (cardinality(day_types) > 0 and day_types <@ array['weekday','saturday','sunday','holiday']);

-- el trigger guard_departure comparaba days_of_week: se rehace con day_types
create or replace function public.guard_departure() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.routes where id = new.route_id and company_id = new.company_id) then
    raise exception 'ROUTE_INVALID: el recorrido no pertenece a esta empresa';
  end if;
  if tg_op = 'UPDATE' and (new.route_id <> old.route_id or new.departure_time <> old.departure_time
                           or new.day_types <> old.day_types)
     and coalesce(current_setting('app.service_rpc', true), '') <> 'on' then
    raise exception 'USE_RPC: la salida se edita con save_service';
  end if;
  return new;
end $$;
alter table public.service_departures drop column days_of_week;

-- tipo de dia por defecto segun el dia de la semana (el feriado se elige a mano)
create function public.day_type_of(p_date date) returns text
language sql immutable as $$
  select case extract(isodow from p_date)::int when 6 then 'saturday' when 7 then 'sunday' else 'weekday' end $$;

alter table public.trips add column day_type text;
update public.trips set day_type = public.day_type_of(service_date);
alter table public.trips alter column day_type set not null;
alter table public.trips add constraint trips_day_type_check check (day_type in ('weekday','saturday','sunday','holiday'));

-- ---------------------------------------------------------------- generar viajes con tipo de dia
drop function public.generate_trips(date);
create function public.generate_trips(p_date date, p_day_type text default null) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := public.current_company_id();
  v_type    text := coalesce(p_day_type, public.day_type_of(p_date));
  v_n int;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if v_type not in ('weekday','saturday','sunday','holiday') then raise exception 'DAY_TYPE_INVALID: tipo de dia invalido'; end if;
  insert into public.trips (company_id, service_id, departure_id, service_date, scheduled_departure, day_type)
  select d.company_id, d.service_id, d.id, p_date, (p_date + d.departure_time) at time zone 'America/Argentina/Buenos_Aires', v_type
  from public.service_departures d
  join public.services s on s.id = d.service_id
  where d.company_id = v_company and s.active and d.active and v_type = any (d.day_types)
  on conflict (departure_id, service_date) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public.generate_trips(date, text) from public, anon;
grant execute on function public.generate_trips(date, text) to authenticated;

-- ---------------------------------------------------------------- save_service con tipos de dia
drop function public.save_service(uuid, text, boolean, jsonb, jsonb);
create or replace function public.save_service(
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
  v_days     text[];
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
    select coalesce(array_agg(x), '{}') into v_days from jsonb_array_elements_text(coalesce(v_dep -> 'day_types', '[]'::jsonb)) x;
    if cardinality(v_days) = 0 or not (v_days <@ array['weekday','saturday','sunday','holiday']) then
      raise exception 'DAYS_INVALID: elija al menos un tipo de dia en cada salida';
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
    select coalesce(array_agg(x), '{}') into v_days from jsonb_array_elements_text(v_dep -> 'day_types') x;
    v_dep_id := nullif(v_dep ->> 'id', '')::uuid;
    if v_dep_id is null then
      insert into public.service_departures (service_id, company_id, route_id, departure_time, day_types, active)
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
             day_types = v_days, active = coalesce((v_dep ->> 'active')::boolean, true)
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

-- ---------------------------------------------------------------- iniciar servicio (lo declara el conductor)
-- Crea el viaje de la salida elegida (o toma el que el administrador ya dejo generado) y lo inicia.
-- Fuera de la ventana de +-45 minutos respecto del horario programado se exige un motivo (inicio forzado).
create function public.start_service(
  p_service uuid, p_departure uuid, p_day_type text, p_vehicle uuid, p_reason text default null
) returns public.trips
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := public.current_company_id();
  v_dep     public.service_departures;
  v_veh     public.vehicles;
  v_trip    public.trips;
  v_today   date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
  v_sched   timestamptz;
  v_forced  boolean;
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;
  if p_day_type is null or p_day_type not in ('weekday','saturday','sunday','holiday') then
    raise exception 'DAY_TYPE_INVALID: elija el tipo de dia';
  end if;
  if not exists (select 1 from public.shifts where driver_id = auth.uid() and ended_at is null) then
    raise exception 'NO_OPEN_SHIFT: inicie la jornada primero';
  end if;
  if exists (select 1 from public.trips where driver_id = auth.uid() and status = 'in_progress') then
    raise exception 'TRIP_IN_PROGRESS: ya tiene un viaje en curso';
  end if;

  select d.* into v_dep from public.service_departures d
    join public.services s on s.id = d.service_id
   where d.id = p_departure and d.service_id = p_service and d.company_id = v_company and d.active and s.active;
  if not found then raise exception 'NOT_FOUND: la salida no existe o esta pausada'; end if;
  if not (p_day_type = any (v_dep.day_types)) then
    raise exception 'DAY_TYPE_MISMATCH: esa salida no circula en ese tipo de dia';
  end if;

  select * into v_veh from public.vehicles where id = p_vehicle and company_id = v_company;
  if not found then raise exception 'NO_VEHICLE: elija la unidad'; end if;
  if v_veh.status in ('maintenance', 'out_of_service', 'retired') then
    raise exception 'VEHICLE_UNAVAILABLE: la unidad no esta disponible';
  end if;
  if exists (select 1 from public.trips where vehicle_id = p_vehicle and status = 'in_progress') then
    raise exception 'VEHICLE_BUSY: la unidad ya tiene un viaje en curso';
  end if;

  v_sched  := (v_today + v_dep.departure_time) at time zone 'America/Argentina/Buenos_Aires';
  v_forced := abs(extract(epoch from (now() - v_sched))) > 45 * 60;
  if v_forced and (p_reason is null or length(trim(p_reason)) < 3) then
    raise exception 'REASON_REQUIRED: la salida esta fuera de horario (mas de 45 minutos); indique el motivo';
  end if;

  select * into v_trip from public.trips where departure_id = p_departure and service_date = v_today for update;
  if found then
    if v_trip.status <> 'scheduled' then raise exception 'ALREADY_STARTED: esa salida ya se inicio hoy'; end if;
    if v_trip.driver_id is not null and v_trip.driver_id <> auth.uid() then
      raise exception 'TAKEN: esa salida esta asignada a otro conductor';
    end if;
    update public.trips set driver_id = auth.uid(), vehicle_id = p_vehicle, day_type = p_day_type where id = v_trip.id;
  else
    insert into public.trips (company_id, service_id, departure_id, service_date, scheduled_departure, day_type, vehicle_id, driver_id)
    values (v_company, p_service, p_departure, v_today, v_sched, p_day_type, p_vehicle, auth.uid())
    returning * into v_trip;
  end if;

  perform set_config('app.trip_rpc', 'on', true);
  update public.trips
     set status = 'in_progress', started_at = now(),
         started_manually = v_forced, start_reason = case when v_forced then trim(p_reason) end
   where id = v_trip.id returning * into v_trip;
  return v_trip;
end $$;
revoke all on function public.start_service(uuid, uuid, text, uuid, text) from public, anon;
grant execute on function public.start_service(uuid, uuid, text, uuid, text) to authenticated;

-- ---------------------------------------------------------------- incidencias
create table public.incidents (
  id         uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id),
  trip_id    uuid not null references public.trips (id),
  driver_id  uuid not null references public.profiles (id),
  kind       text not null check (kind in ('breakdown','delay','accident','traffic','other')),
  note       text,
  created_at timestamptz not null default now()
);
create index incidents_trip_idx on public.incidents (trip_id);
create index incidents_company_idx on public.incidents (company_id, created_at desc);
alter table public.incidents enable row level security;
-- el personal de la empresa ve todas; el conductor, las suyas
create policy incidents_select on public.incidents for select to authenticated
  using (company_id = public.current_company_id()
         and (public.current_user_role() <> 'driver' or driver_id = auth.uid()));
create trigger audit_incidents after insert or update or delete on public.incidents
  for each row execute function public.audit_row();

create function public.report_incident(p_trip uuid, p_kind text, p_note text default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;
  if p_kind not in ('breakdown','delay','accident','traffic','other') then raise exception 'KIND_INVALID: tipo de incidencia invalido'; end if;
  if p_kind = 'other' and (p_note is null or length(trim(p_note)) < 3) then raise exception 'NOTE_REQUIRED: describa la incidencia'; end if;
  if not exists (select 1 from public.trips where id = p_trip and driver_id = auth.uid() and company_id = public.current_company_id()) then
    raise exception 'NOT_FOUND';
  end if;
  insert into public.incidents (company_id, trip_id, driver_id, kind, note)
  values (public.current_company_id(), p_trip, auth.uid(), p_kind, nullif(trim(p_note), ''))
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.report_incident(uuid, text, text) from public, anon;
grant execute on function public.report_incident(uuid, text, text) to authenticated;
