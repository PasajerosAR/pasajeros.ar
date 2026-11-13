-- Guarda solo la ultima ubicacion de cada viaje activo; no mantiene historial de recorrido.
create table public.trip_live_positions (
  trip_id     uuid primary key references public.trips (id) on delete cascade,
  company_id  uuid not null references public.companies (id),
  driver_id   uuid not null references public.profiles (id),
  latitude    double precision not null check (latitude between -90 and 90),
  longitude   double precision not null check (longitude between -180 and 180),
  accuracy_m  real not null check (accuracy_m between 0 and 100),
  heading     real check (heading is null or heading >= 0 and heading < 360),
  recorded_at timestamptz not null
);
alter table public.trip_live_positions enable row level security;
revoke all on public.trip_live_positions from anon, authenticated;

create function public.update_trip_live_position(
  p_trip uuid,
  p_latitude double precision,
  p_longitude double precision,
  p_accuracy_m real,
  p_heading real,
  p_recorded_at timestamptz
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_trip public.trips;
  v_now timestamptz := clock_timestamp();
begin
  if public.current_user_role() is distinct from 'driver' then raise exception 'FORBIDDEN'; end if;
  if p_latitude is null or p_latitude not between -90 and 90
     or p_longitude is null or p_longitude not between -180 and 180
     or p_accuracy_m is null or p_accuracy_m not between 0 and 100
     or (p_heading is not null and (p_heading < 0 or p_heading >= 360))
     or p_recorded_at is null
     or p_recorded_at < v_now - interval '90 seconds'
     or p_recorded_at > v_now + interval '30 seconds' then
    raise exception 'GPS_INVALID: la ubicacion no es valida, precisa o reciente';
  end if;

  select * into v_trip
    from public.trips
   where id = p_trip
     and company_id = public.current_company_id()
     and driver_id = auth.uid()
     and status = 'in_progress'
   for update;
  if not found then raise exception 'TRIP_NOT_ACTIVE: el viaje no esta asignado al conductor o no esta en curso'; end if;

  insert into public.trip_live_positions (
    trip_id, company_id, driver_id, latitude, longitude, accuracy_m, heading, recorded_at
  ) values (
    v_trip.id, v_trip.company_id, auth.uid(), p_latitude, p_longitude, p_accuracy_m, p_heading, p_recorded_at
  )
  on conflict (trip_id) do update set
    company_id = excluded.company_id,
    driver_id = excluded.driver_id,
    latitude = excluded.latitude,
    longitude = excluded.longitude,
    accuracy_m = excluded.accuracy_m,
    heading = excluded.heading,
    recorded_at = excluded.recorded_at
  where public.trip_live_positions.recorded_at < excluded.recorded_at;
end $$;
revoke all on function public.update_trip_live_position(uuid, double precision, double precision, real, real, timestamptz) from public, anon;
grant execute on function public.update_trip_live_position(uuid, double precision, double precision, real, real, timestamptz) to authenticated;

create function public.admin_live_trips(p_company_id uuid default null)
returns table (
  trip_id uuid,
  company_id uuid,
  company_name text,
  service_code text,
  service_date date,
  scheduled_departure timestamptz,
  started_at timestamptz,
  route_id uuid,
  route_name text,
  route_path jsonb,
  vehicle_number text,
  vehicle_plate text,
  driver_name text,
  latitude double precision,
  longitude double precision,
  accuracy_m real,
  heading real,
  location_at timestamptz
)
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
  select t.id, t.company_id, c.name, s.code, t.service_date, t.scheduled_departure, t.started_at,
         r.id, r.name, r.path,
         v.internal_number, v.plate, p.full_name,
         live.latitude, live.longitude, live.accuracy_m, live.heading, live.recorded_at
    from public.trips t
    join public.companies c on c.id = t.company_id
    join public.services s on s.id = t.service_id
    join public.service_departures d on d.id = t.departure_id
    join public.routes r on r.id = d.route_id
    left join public.vehicles v on v.id = t.vehicle_id
    left join public.profiles p on p.id = t.driver_id
    left join public.trip_live_positions live on live.trip_id = t.id
   where t.status = 'in_progress'
     and (
       (v_role = 'company_admin' and t.company_id = v_company)
       or (v_role = 'platform_admin' and (p_company_id is null or t.company_id = p_company_id))
     )
   order by c.name, s.code, t.scheduled_departure;
end $$;
revoke all on function public.admin_live_trips(uuid) from public, anon;
grant execute on function public.admin_live_trips(uuid) to authenticated;

create function public.clear_finished_trip_live_position() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status <> 'in_progress' or new.driver_id is distinct from old.driver_id then
    delete from public.trip_live_positions where trip_id = new.id;
  end if;
  return new;
end $$;
create trigger clear_finished_trip_live_position
  after update of status, driver_id on public.trips
  for each row execute function public.clear_finished_trip_live_position();
