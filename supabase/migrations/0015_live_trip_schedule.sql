create function public.admin_live_trip_schedule(p_company_id uuid default null)
returns table (trip_id uuid, route_stops jsonb)
language plpgsql security definer set search_path = public as $$
declare
  v_role public.user_role := public.current_user_role();
  v_company uuid := public.current_company_id();
begin
  if v_role is null or v_role not in ('company_admin', 'platform_admin') then raise exception 'FORBIDDEN'; end if;
  if v_role = 'company_admin' and p_company_id is not null and p_company_id is distinct from v_company then
    raise exception 'FORBIDDEN';
  end if;

  return query
  select t.id,
         coalesce((
           select jsonb_agg(jsonb_build_object(
             'id', rs.id,
             'name', rs.name,
             'lat', rs.lat,
             'lng', rs.lng,
             'minutes_from_start', ss.minutes_from_start,
             'dwell_minutes', coalesce(ss.dwell_minutes, 0)
           ) order by rs.position)
             from public.route_stops rs
             left join public.service_stops ss
               on ss.service_id = t.service_id and ss.route_stop_id = rs.id
             where rs.route_id = d.route_id
         ), '[]'::jsonb)
    from public.trips t
    join public.service_departures d
      on d.id = t.departure_id and d.service_id = t.service_id and d.company_id = t.company_id
   where t.status = 'in_progress'
     and (
       (v_role = 'company_admin' and t.company_id = v_company)
       or (v_role = 'platform_admin' and (p_company_id is null or t.company_id = p_company_id))
     );
end $$;
revoke all on function public.admin_live_trip_schedule(uuid) from public, anon;
grant execute on function public.admin_live_trip_schedule(uuid) to authenticated;
