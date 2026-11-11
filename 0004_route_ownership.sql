-- Cada recorrido pertenece a una sola empresa (exclusivo). Lo carga y lo asigna la plataforma.
-- Los recorridos que ya existian quedan sin empresa: solo la plataforma los ve hasta que los asigne.

alter table public.routes add column company_id uuid references public.companies (id);
create index routes_company_idx on public.routes (company_id);

drop policy routes_select on public.routes;
drop policy route_stops_select on public.route_stops;
create policy routes_select on public.routes for select to authenticated
  using (public.is_platform_admin() or company_id = public.current_company_id());
create policy route_stops_select on public.route_stops for select to authenticated
  using (public.is_platform_admin() or exists (
    select 1 from public.routes r where r.id = route_id and r.company_id = public.current_company_id()));

-- Un servicio solo puede usar recorridos de su propia empresa (aunque se intente por otra via).
create function public.guard_service_company() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.routes where id = new.route_id and company_id = new.company_id) then
    raise exception 'ROUTE_INVALID: el recorrido no pertenece a esta empresa';
  end if;
  return new;
end $$;
create trigger guard_service_company before insert or update of route_id on public.services
  for each row execute function public.guard_service_company();

-- save_service: mismo comportamiento, pero el recorrido debe ser de la empresa.
create or replace function public.save_service(
  p_service uuid, p_code text, p_route uuid, p_time time, p_days int[], p_active boolean, p_stops jsonb
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_company  uuid := public.current_company_id();
  v_id       uuid;
  v_old      public.services;
  v_expected int;
  v_prev     int := 0;
  r          record;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if p_code is null or length(trim(p_code)) = 0 then raise exception 'CODE_REQUIRED: falta el codigo del servicio'; end if;
  if p_time is null then raise exception 'TIME_REQUIRED: falta la hora de salida'; end if;
  if p_days is null or cardinality(p_days) = 0 or not (p_days <@ array[1,2,3,4,5,6,7]) then
    raise exception 'DAYS_INVALID: elija al menos un dia';
  end if;
  if not exists (select 1 from public.routes where id = p_route and active and company_id = v_company) then
    raise exception 'ROUTE_INVALID: el recorrido no existe, no esta activo o no es de su empresa';
  end if;
  if p_stops is null or jsonb_typeof(p_stops) <> 'array' then raise exception 'STOPS_MISMATCH: faltan los tiempos de las paradas'; end if;

  select count(*) into v_expected from public.route_stops where route_id = p_route;
  if jsonb_array_length(p_stops) <> v_expected
     or (select count(distinct e ->> 'route_stop_id') from jsonb_array_elements(p_stops) e) <> v_expected
     or exists (select 1 from jsonb_array_elements(p_stops) e
                 where not exists (select 1 from public.route_stops rs
                                    where rs.route_id = p_route and rs.id::text = e ->> 'route_stop_id')) then
    raise exception 'STOPS_MISMATCH: los tiempos deben cubrir todas las paradas del recorrido';
  end if;

  for r in
    select rs.position, coalesce((e ->> 'minutes_from_start')::int, -1) as m
      from public.route_stops rs
      join jsonb_array_elements(p_stops) e on e ->> 'route_stop_id' = rs.id::text
     where rs.route_id = p_route order by rs.position
  loop
    if r.m < 0 then raise exception 'TIMES_INVALID: falta el minuto de la parada %', r.position; end if;
    if r.position = 1 and r.m <> 0 then raise exception 'TIMES_INVALID: la primera parada sale en el minuto 0'; end if;
    if r.m < v_prev then raise exception 'TIMES_INVALID: los minutos no pueden disminuir entre paradas'; end if;
    v_prev := r.m;
  end loop;

  if p_service is null then
    insert into public.services (company_id, code, route_id, departure_time, days_of_week, active)
    values (v_company, trim(p_code), p_route, p_time, p_days::smallint[], coalesce(p_active, true))
    returning id into v_id;
  else
    select * into v_old from public.services where id = p_service and company_id = v_company for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    if v_old.route_id <> p_route and exists (select 1 from public.trips where service_id = p_service) then
      raise exception 'ROUTE_LOCKED: el servicio ya tiene viajes; cree uno nuevo para cambiar de recorrido';
    end if;
    perform set_config('app.service_rpc', 'on', true);
    update public.services
       set code = trim(p_code), route_id = p_route, departure_time = p_time,
           days_of_week = p_days::smallint[], active = coalesce(p_active, active)
     where id = p_service;
    v_id := p_service;
    delete from public.service_stops where service_id = v_id;
  end if;

  insert into public.service_stops (service_id, route_stop_id, company_id, minutes_from_start, dwell_minutes)
  select v_id, (e ->> 'route_stop_id')::uuid, v_company,
         (e ->> 'minutes_from_start')::int, coalesce((e ->> 'dwell_minutes')::int, 0)
  from jsonb_array_elements(p_stops) e;
  return v_id;
end $$;

-- save_route ahora recibe la empresa duena. La empresa no se puede cambiar si ya hay servicios.
drop function public.save_route(uuid, text, boolean, jsonb);
create function public.save_route(p_route uuid, p_name text, p_active boolean, p_stops jsonb, p_company uuid) returns uuid
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
    if v_prev_company is distinct from p_company and exists (select 1 from public.services where route_id = p_route) then
      raise exception 'COMPANY_LOCKED: hay servicios con este recorrido; no se puede cambiar de empresa';
    end if;
    update public.routes set name = trim(p_name), active = coalesce(p_active, active), company_id = p_company
     where id = p_route returning id into v_id;

    if exists (select 1 from public.services where route_id = v_id) then
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

revoke all on function public.save_route(uuid, text, boolean, jsonb, uuid) from public, anon;
grant execute on function public.save_route(uuid, text, boolean, jsonb, uuid) to authenticated;
