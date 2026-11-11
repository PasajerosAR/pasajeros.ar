-- Localidades (origen y destino para el pasajero) y trazado por calles de cada recorrido.
--   places           -> catalogo de localidades, lo administra la plataforma
--   route_stops      -> cada parada pertenece a una localidad
--   routes           -> origen y destino (localidad de la primera y ultima parada), trazado y puntos de paso
-- Una localidad intermedia es una parada donde el servicio "pasa": el pasajero la ve como origen o destino posible.

create table public.places (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (length(trim(name)) > 0),
  province   text,
  created_at timestamptz not null default now()
);
create unique index places_name_key on public.places (lower(trim(name)), lower(coalesce(trim(province), '')));
alter table public.places enable row level security;
create policy places_select on public.places for select to authenticated using (true);
create policy places_platform on public.places for all to authenticated
  using (public.is_platform_admin()) with check (public.is_platform_admin());
create trigger audit_places after insert or update or delete on public.places
  for each row execute function public.audit_row();

alter table public.route_stops add column place_id uuid references public.places (id);
create index route_stops_place_idx on public.route_stops (place_id);

alter table public.routes
  add column origin_place_id      uuid references public.places (id),
  add column destination_place_id uuid references public.places (id),
  add column path jsonb,   -- [[lat,lng], ...] siguiendo las calles
  add column via  jsonb;   -- [{"seg":0,"lat":..,"lng":..}, ...] puntos de paso entre la parada seg y la seg+1
create index routes_origin_idx on public.routes (origin_place_id, destination_place_id);

-- save_route: ahora cada parada lleva su localidad; guarda origen/destino, trazado y puntos de paso.
-- p_stops = [{name, lat, lng, place_id}]
drop function public.save_route(uuid, text, boolean, jsonb, uuid);
create function public.save_route(
  p_route uuid, p_name text, p_active boolean, p_stops jsonb, p_company uuid,
  p_path jsonb default null, p_via jsonb default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_n  int;
  v_prev_company uuid;
  v_first uuid;
  v_last  uuid;
begin
  if not public.is_platform_admin() then raise exception 'FORBIDDEN'; end if;
  if p_name is null or length(trim(p_name)) = 0 then raise exception 'NAME_REQUIRED: falta el nombre del recorrido'; end if;
  if p_company is null or not exists (select 1 from public.companies where id = p_company) then
    raise exception 'COMPANY_REQUIRED: elija la empresa duena del recorrido';
  end if;
  if p_stops is null or jsonb_typeof(p_stops) <> 'array' or jsonb_array_length(p_stops) < 2 then
    raise exception 'STOPS_REQUIRED: el recorrido necesita al menos origen y destino';
  end if;
  if exists (select 1 from jsonb_array_elements(p_stops) e where coalesce(e ->> 'place_id', '') = '') then
    raise exception 'PLACE_REQUIRED: cada parada necesita su localidad';
  end if;
  if exists (select 1 from jsonb_array_elements(p_stops) e
              where not exists (select 1 from public.places pl where pl.id::text = e ->> 'place_id')) then
    raise exception 'PLACE_INVALID: una de las localidades no existe';
  end if;
  if p_path is not null and (jsonb_typeof(p_path) <> 'array' or jsonb_array_length(p_path) > 20000
      or exists (select 1 from jsonb_array_elements(p_path) e
                  where jsonb_typeof(e) <> 'array' or jsonb_array_length(e) <> 2)) then
    raise exception 'PATH_INVALID: el trazado no es valido';
  end if;
  if p_via is not null and (jsonb_typeof(p_via) <> 'array' or jsonb_array_length(p_via) > 200) then
    raise exception 'PATH_INVALID: los puntos de paso no son validos';
  end if;

  v_first := (p_stops -> 0 ->> 'place_id')::uuid;
  v_last  := (p_stops -> (jsonb_array_length(p_stops) - 1) ->> 'place_id')::uuid;

  if p_route is null then
    insert into public.routes (name, active, company_id, origin_place_id, destination_place_id, path, via)
    values (trim(p_name), coalesce(p_active, true), p_company, v_first, v_last, p_path, p_via) returning id into v_id;
  else
    select company_id into v_prev_company from public.routes where id = p_route for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    if v_prev_company is distinct from p_company and exists (select 1 from public.service_departures where route_id = p_route) then
      raise exception 'COMPANY_LOCKED: hay servicios con este recorrido; no se puede cambiar de empresa';
    end if;
    update public.routes
       set name = trim(p_name), active = coalesce(p_active, active), company_id = p_company,
           origin_place_id = v_first, destination_place_id = v_last, path = p_path, via = p_via
     where id = p_route returning id into v_id;

    if exists (select 1 from public.service_departures where route_id = v_id) then
      select count(*) into v_n from public.route_stops where route_id = v_id;
      if jsonb_array_length(p_stops) <> v_n then
        raise exception 'ROUTE_IN_USE: hay servicios con este recorrido; solo se pueden corregir nombres, localidades y coordenadas';
      end if;
      update public.route_stops rs
         set name = trim(s.e ->> 'name'),
             lat = nullif(s.e ->> 'lat', '')::numeric,
             lng = nullif(s.e ->> 'lng', '')::numeric,
             place_id = (s.e ->> 'place_id')::uuid
        from jsonb_array_elements(p_stops) with ordinality as s(e, ord)
       where rs.route_id = v_id and rs.position = s.ord::int;
      return v_id;
    end if;
    delete from public.route_stops where route_id = v_id;
  end if;

  insert into public.route_stops (route_id, position, name, lat, lng, place_id)
  select v_id, s.ord::int, trim(s.e ->> 'name'), nullif(s.e ->> 'lat', '')::numeric, nullif(s.e ->> 'lng', '')::numeric,
         (s.e ->> 'place_id')::uuid
  from jsonb_array_elements(p_stops) with ordinality as s(e, ord);
  return v_id;
end $$;

revoke all on function public.save_route(uuid, text, boolean, jsonb, uuid, jsonb, jsonb) from public, anon;
grant execute on function public.save_route(uuid, text, boolean, jsonb, uuid, jsonb, jsonb) to authenticated;
