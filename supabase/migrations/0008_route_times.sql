-- Horarios estandar por recorrido (cada empresa) y cambio de sentido en salidas sin viajes realizados.
create table public.route_times (
  company_id         uuid not null references public.companies (id),
  route_stop_id      uuid not null references public.route_stops (id) on delete cascade,
  minutes_from_start int  not null check (minutes_from_start >= 0),
  dwell_minutes      int  not null default 0 check (dwell_minutes >= 0),
  primary key (company_id, route_stop_id)
);
alter table public.route_times enable row level security;
create policy route_times_select on public.route_times for select to authenticated
  using (company_id = public.current_company_id());
create policy route_times_admin on public.route_times for all to authenticated
  using (company_id = public.current_company_id() and public.is_company_admin())
  with check (company_id = public.current_company_id() and public.is_company_admin());

-- Los tiempos ya cargados pasan a ser el estandar (el servicio mas reciente de cada parada)
insert into public.route_times (company_id, route_stop_id, minutes_from_start, dwell_minutes)
select distinct on (ss.company_id, ss.route_stop_id) ss.company_id, ss.route_stop_id, ss.minutes_from_start, ss.dwell_minutes
from public.service_stops ss join public.services s on s.id = ss.service_id
order by ss.company_id, ss.route_stop_id, s.created_at desc;

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
      if v_old.route_id <> (v_dep ->> 'route_id')::uuid then
        -- solo se puede cambiar de sentido si ningun viaje de la salida se inicio; los programados se descartan
        if exists (select 1 from public.trips where departure_id = v_dep_id and status <> 'scheduled') then
          raise exception 'ROUTE_LOCKED: esta salida ya tiene viajes realizados; pausela y cree una nueva para el otro sentido';
        end if;
        delete from public.trips where departure_id = v_dep_id;
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
