-- Eliminacion permanente de servicios sin viajes y fecha explicita al iniciar.

drop function if exists public.delete_service(uuid);
create function public.delete_service(p_service uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := public.current_company_id();
  v_service public.services;
  v_trips bigint;
  v_departures bigint;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;

  select * into v_service
    from public.services
   where id = p_service and company_id = v_company
   for update;
  if not found then raise exception 'NOT_FOUND'; end if;

  select count(*) into v_trips
    from public.trips
   where service_id = p_service;
  if v_trips > 0 then
    raise exception 'SERVICE_HAS_TRIPS: No se puede eliminar: el servicio tiene % viaje(s) asociado(s).', v_trips;
  end if;

  select count(*) into v_departures
    from public.service_departures
   where service_id = p_service and company_id = v_company;

  delete from public.services
   where id = p_service and company_id = v_company;

  return jsonb_build_object(
    'deleted', true,
    'deleted_departures', v_departures
  );
end $$;
revoke all on function public.delete_service(uuid) from public, anon;
grant execute on function public.delete_service(uuid) to authenticated;

drop function if exists public.start_service(uuid, uuid, text, uuid, text);
create or replace function public.start_service(
  p_service uuid, p_departure uuid, p_day_type text, p_vehicle uuid,
  p_reason text default null, p_service_date date default null
) returns public.trips
language plpgsql security definer set search_path = public as $$
declare
  v_company      uuid := public.current_company_id();
  v_dep          public.service_departures;
  v_veh          public.vehicles;
  v_trip         public.trips;
  v_service_date date := coalesce(p_service_date, (now() at time zone 'America/Argentina/Buenos_Aires')::date);
  v_sched        timestamptz;
  v_forced       boolean;
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

  v_sched := (v_service_date + v_dep.departure_time) at time zone 'America/Argentina/Buenos_Aires';
  v_forced := abs(extract(epoch from (now() - v_sched))) > 45 * 60;
  if v_forced and (p_reason is null or length(trim(p_reason)) < 3) then
    raise exception 'REASON_REQUIRED: la salida esta fuera de horario (mas de 45 minutos); indique el motivo';
  end if;

  select * into v_trip
    from public.trips
   where departure_id = p_departure and service_date = v_service_date
   for update;
  if found then
    if v_trip.status <> 'scheduled' then raise exception 'ALREADY_STARTED: esa salida ya se inicio en esa fecha'; end if;
    if v_trip.driver_id is not null and v_trip.driver_id <> auth.uid() then
      raise exception 'TAKEN: esa salida esta asignada a otro conductor';
    end if;
    update public.trips
       set driver_id = auth.uid(), vehicle_id = p_vehicle, day_type = p_day_type
     where id = v_trip.id;
  else
    insert into public.trips (
      company_id, service_id, departure_id, service_date, scheduled_departure,
      day_type, vehicle_id, driver_id
    )
    values (
      v_company, p_service, p_departure, v_service_date, v_sched,
      p_day_type, p_vehicle, auth.uid()
    )
    returning * into v_trip;
  end if;

  perform set_config('app.trip_rpc', 'on', true);
  update public.trips
     set status = 'in_progress', started_at = now(),
         started_manually = v_forced, start_reason = case when v_forced then trim(p_reason) end
   where id = v_trip.id
   returning * into v_trip;
  return v_trip;
end $$;
revoke all on function public.start_service(uuid, uuid, text, uuid, text, date) from public, anon;
grant execute on function public.start_service(uuid, uuid, text, uuid, text, date) to authenticated;
