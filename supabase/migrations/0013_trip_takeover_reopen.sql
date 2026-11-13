-- Permite relevar al conductor o retomar un viaje cerrado por una contingencia.
-- El viaje y sus conteos se conservan; el motivo queda en la auditoria de cambios.

create or replace function public.guard_trip() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_vehicle public.vehicles;
  v_driver  public.profiles;
  v_trip_rpc boolean;
begin
  v_trip_rpc := coalesce(current_setting('app.trip_rpc', true), '') = 'on';

  if new.vehicle_id is not null and (tg_op = 'INSERT' or new.vehicle_id is distinct from old.vehicle_id) then
    if tg_op = 'UPDATE' and old.status <> 'scheduled'
       and not (
         v_trip_rpc and new.status = 'in_progress'
         and (
           old.status = 'completed'
           or (old.status = 'in_progress' and new.driver_id is distinct from old.driver_id)
         )
       ) then
      raise exception 'TRIP_NOT_EDITABLE: el vehículo solo se cambia al relevar o retomar un viaje con el RPC autorizado';
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

  if tg_op = 'UPDATE' and old.status in ('in_progress', 'completed')
     and new.driver_id is distinct from old.driver_id
     and not (v_trip_rpc and new.status = 'in_progress') then
    raise exception 'USE_RPC: el cambio de conductor requiere una transferencia autorizada';
  end if;

  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if not (
      (old.status = 'scheduled' and new.status in ('in_progress', 'cancelled'))
      or (old.status = 'in_progress' and new.status = 'completed')
      or (old.status = 'completed' and new.status = 'in_progress' and v_trip_rpc)
    ) then
      raise exception 'INVALID_TRANSITION: % -> %', old.status, new.status;
    end if;
    if new.status in ('in_progress', 'completed') and not v_trip_rpc then
      raise exception 'USE_RPC: el estado se cambia con start_service / end_trip';
    end if;
  end if;
  return new;
end $$;

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
  v_exists       boolean := false;
  v_takeover     boolean := false;
  v_reopen       boolean := false;
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

  select * into v_trip
    from public.trips
   where departure_id = p_departure and service_id = p_service
     and company_id = v_company and service_date = v_service_date
   for update;
  v_exists := found;

  if v_exists then
    if v_trip.status = 'scheduled' then
      if v_trip.driver_id is not null and v_trip.driver_id <> auth.uid() then
        raise exception 'TAKEN: esa salida esta asignada a otro conductor';
      end if;
    elsif v_trip.status = 'in_progress' then
      if v_trip.driver_id = auth.uid() then
        raise exception 'TRIP_IN_PROGRESS: ya tiene un viaje en curso';
      end if;
      if p_reason is null or length(trim(p_reason)) < 3 then
        raise exception 'TAKEOVER_REASON_REQUIRED: escribí el motivo para relevar al conductor actual';
      end if;
      v_takeover := true;
    elsif v_trip.status = 'completed' then
      if p_reason is null or length(trim(p_reason)) < 3 then
        raise exception 'REOPEN_REASON_REQUIRED: escribí el motivo para retomar el viaje finalizado';
      end if;
      v_reopen := true;
    else
      raise exception 'INVALID_STATE: el viaje cancelado no se puede retomar';
    end if;
  end if;

  select * into v_veh from public.vehicles where id = p_vehicle and company_id = v_company;
  if not found then raise exception 'NO_VEHICLE: elija la unidad'; end if;
  if v_veh.status in ('maintenance', 'out_of_service', 'retired') then
    raise exception 'VEHICLE_UNAVAILABLE: la unidad no esta disponible';
  end if;
  if exists (
    select 1 from public.trips t
     where t.vehicle_id = p_vehicle and t.status = 'in_progress'
       and (not v_exists or t.id <> v_trip.id)
  ) then
    raise exception 'VEHICLE_BUSY: la unidad ya tiene un viaje en curso';
  end if;

  v_sched := (v_service_date + v_dep.departure_time) at time zone 'America/Argentina/Buenos_Aires';
  v_forced := abs(extract(epoch from (now() - v_sched))) > 45 * 60;
  if v_forced and (p_reason is null or length(trim(p_reason)) < 3) then
    raise exception 'REASON_REQUIRED: la salida esta fuera de horario (mas de 45 minutos); indique el motivo';
  end if;

  perform set_config('app.trip_rpc', 'on', true);
  if v_exists then
    update public.trips
       set driver_id = auth.uid(),
           vehicle_id = p_vehicle,
           day_type = p_day_type,
           status = 'in_progress',
           started_at = now(),
           ended_at = null,
           started_manually = v_forced or v_takeover or v_reopen,
           start_reason = case when v_forced or v_takeover or v_reopen then trim(p_reason) end
     where id = v_trip.id
     returning * into v_trip;
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

    update public.trips
       set status = 'in_progress',
           started_at = now(),
           started_manually = v_forced,
           start_reason = case when v_forced then trim(p_reason) end
     where id = v_trip.id
     returning * into v_trip;
  end if;
  return v_trip;
end $$;

revoke all on function public.start_service(uuid, uuid, text, uuid, text, date) from public, anon;
grant execute on function public.start_service(uuid, uuid, text, uuid, text, date) to authenticated;
