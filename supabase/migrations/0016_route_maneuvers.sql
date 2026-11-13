-- Guarda las indicaciones de giro calculadas al trazar cada recorrido.
alter table public.routes add column maneuvers jsonb;

comment on column public.routes.maneuvers is
  'Maniobras del recorrido en orden: lat, lng, type, modifier, name y exit.';

create function public.save_route_maneuvers(p_route uuid, p_maneuvers jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'FORBIDDEN'; end if;

  if p_maneuvers is not null then
    if jsonb_typeof(p_maneuvers) <> 'array' or jsonb_array_length(p_maneuvers) > 2000 then
      raise exception 'PATH_INVALID: las indicaciones de giro no son validas';
    end if;
    if exists (
      select 1
      from jsonb_array_elements(p_maneuvers) as item(m)
      where jsonb_typeof(m) <> 'object'
         or coalesce(jsonb_typeof(m -> 'lat'), 'null') <> 'number'
         or coalesce(jsonb_typeof(m -> 'lng'), 'null') <> 'number'
         or coalesce(jsonb_typeof(m -> 'type'), 'null') <> 'string'
         or length(trim(coalesce(m ->> 'type', ''))) = 0
         or length(m ->> 'type') > 40
         or coalesce(jsonb_typeof(m -> 'name'), 'null') <> 'string'
         or coalesce(jsonb_typeof(m -> 'modifier'), 'null') not in ('string', 'null')
         or coalesce(jsonb_typeof(m -> 'exit'), 'null') not in ('number', 'null')
         or case when jsonb_typeof(m -> 'lat') = 'number'
              then (m ->> 'lat')::numeric not between -90 and 90 else true end
         or case when jsonb_typeof(m -> 'lng') = 'number'
              then (m ->> 'lng')::numeric not between -180 and 180 else true end
         or case when jsonb_typeof(m -> 'exit') = 'number'
              then (m ->> 'exit')::numeric not between 1 and 100
                   or (m ->> 'exit')::numeric <> trunc((m ->> 'exit')::numeric)
              else false end
    ) then
      raise exception 'PATH_INVALID: las indicaciones de giro no son validas';
    end if;
  end if;

  update public.routes set maneuvers = p_maneuvers where id = p_route;
  if not found then raise exception 'NOT_FOUND'; end if;
end $$;

revoke all on function public.save_route_maneuvers(uuid, jsonb) from public, anon;
grant execute on function public.save_route_maneuvers(uuid, jsonb) to authenticated;
