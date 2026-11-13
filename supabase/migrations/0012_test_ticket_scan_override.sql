-- Backend minimo y exclusivo de pruebas para QR, escaneo y ascensos autorizados.
-- No emite pasajes comerciales ni acepta los QR JSON del prototipo de pasajeros.
-- Reutiliza una tabla tickets existente y agrega campos sin eliminar datos.

create table if not exists public.tickets (
  id                    uuid primary key default gen_random_uuid(),
  company_id            uuid not null references public.companies (id),
  trip_id               uuid not null references public.trips (id),
  code                  text not null unique,
  passenger_name        text not null check (length(btrim(passenger_name)) between 1 and 120),
  boarding_stop_id      uuid not null references public.route_stops (id),
  alighting_stop_id     uuid not null references public.route_stops (id),
  status                text not null default 'valid' check (status in ('valid', 'boarded', 'cancelled')),
  is_test               boolean not null default true check (is_test),
  actual_boarding_stop_id uuid references public.route_stops (id),
  boarding_event_id     uuid,
  boarded_at            timestamptz,
  boarded_by            uuid references public.profiles (id),
  boarding_override     boolean not null default false,
  boarding_override_at  timestamptz,
  boarding_override_by  uuid references public.profiles (id),
  created_at            timestamptz not null default now(),
  constraint ticket_override_state_check check (
    (not boarding_override and boarding_override_at is null and boarding_override_by is null)
    or (
      boarding_override
      and actual_boarding_stop_id is not null
      and actual_boarding_stop_id <> boarding_stop_id
      and boarding_override_at is not null
      and boarding_override_by is not null
    )
  ),
  constraint ticket_override_stop_check check (
    not boarding_override or actual_boarding_stop_id <> boarding_stop_id
  )
);
alter table public.tickets
  add column if not exists actual_boarding_stop_id uuid references public.route_stops (id),
  add column if not exists boarding_event_id uuid,
  add column if not exists boarded_by uuid references public.profiles (id),
  add column if not exists boarding_override boolean not null default false,
  add column if not exists boarding_override_at timestamptz,
  add column if not exists boarding_override_by uuid references public.profiles (id);
do $$ begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.tickets'::regclass
       and conname = 'ticket_override_state_check'
  ) then
    alter table public.tickets
      add constraint ticket_override_state_check check (
        (not boarding_override and boarding_override_at is null and boarding_override_by is null)
        or (
          boarding_override
          and actual_boarding_stop_id is not null
          and actual_boarding_stop_id <> boarding_stop_id
          and boarding_override_at is not null
          and boarding_override_by is not null
        )
      ) not valid;
  end if;
end $$;
do $$ begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.tickets'::regclass
       and conname = 'ticket_override_stop_check'
  ) then
    alter table public.tickets
      add constraint ticket_override_stop_check check (
        not boarding_override
        or (actual_boarding_stop_id is not null and actual_boarding_stop_id <> boarding_stop_id)
      ) not valid;
  end if;
end $$;
create index if not exists tickets_trip_status_idx on public.tickets (trip_id, status);
alter table public.tickets enable row level security;
do $$ begin
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'tickets' and policyname = 'tickets_select'
  ) then
    create policy tickets_select on public.tickets for select to authenticated
      using (
        company_id = public.current_company_id()
        and (
          public.current_user_role() in ('company_admin', 'support')
          or (
            public.current_user_role() = 'driver'
            and exists (
              select 1 from public.trips t
               where t.id = tickets.trip_id and t.driver_id = auth.uid()
            )
          )
        )
      );
  end if;
end $$;
revoke all on public.tickets from anon, authenticated;
grant select on public.tickets to authenticated;

create table if not exists public.ticket_boarding_events (
  id                      uuid primary key default gen_random_uuid(),
  company_id              uuid not null references public.companies (id),
  trip_id                 uuid not null references public.trips (id),
  ticket_id               uuid not null unique references public.tickets (id),
  driver_id               uuid not null references public.profiles (id),
  planned_boarding_stop_id uuid not null references public.route_stops (id),
  actual_boarding_stop_id  uuid not null references public.route_stops (id),
  was_overridden          boolean not null,
  client_event_id         uuid not null,
  boarded_at              timestamptz not null default now(),
  constraint ticket_boarding_event_override_check
    check (not was_overridden or planned_boarding_stop_id <> actual_boarding_stop_id),
  unique (trip_id, client_event_id)
);
create index if not exists ticket_boarding_events_company_time_idx
  on public.ticket_boarding_events (company_id, boarded_at desc);
alter table public.ticket_boarding_events enable row level security;
do $$ begin
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'ticket_boarding_events'
       and policyname = 'ticket_boarding_events_select'
  ) then
    create policy ticket_boarding_events_select on public.ticket_boarding_events for select to authenticated
      using (
        company_id = public.current_company_id()
        and (
          public.current_user_role() in ('company_admin', 'support')
          or driver_id = auth.uid()
        )
      );
  end if;
end $$;
revoke all on public.ticket_boarding_events from anon, authenticated;
grant select on public.ticket_boarding_events to authenticated;

create or replace function public.create_test_tickets(p_trip uuid, p_count int default 8) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_trip public.trips;
  v_route uuid;
  v_stop_count int;
  v_boarding uuid;
  v_alighting uuid;
  v_position int;
  v_inserted int := 0;
  v_existing int;
  i int;
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;
  if p_count is null or p_count < 2 or p_count > 20 then
    raise exception 'TEST_TICKET_COUNT_INVALID: genere entre 2 y 20 pasajes de prueba';
  end if;

  select * into v_trip
    from public.trips
   where id = p_trip
     and company_id = public.current_company_id()
     and driver_id = auth.uid()
   for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_trip.status <> 'in_progress' then raise exception 'INVALID_STATE: el viaje debe estar en curso'; end if;
  if exists (select 1 from public.tickets where trip_id = v_trip.id and is_test is distinct from true) then
    raise exception 'TEST_TICKETS_MIXED_WITH_REAL: no se pueden agregar pasajes de prueba a un viaje con pasajes reales';
  end if;
  select count(*) into v_existing
    from public.tickets where trip_id = v_trip.id and is_test is true;
  if v_existing > 0 then return v_existing; end if;

  select route_id into v_route
    from public.service_departures
   where id = v_trip.departure_id and service_id = v_trip.service_id and company_id = v_trip.company_id;
  if not found then raise exception 'NOT_FOUND'; end if;

  select count(*) into v_stop_count from public.route_stops where route_id = v_route;
  if v_stop_count < 2 then raise exception 'ROUTE_STOPS_REQUIRED: el recorrido necesita al menos dos paradas'; end if;

  for i in 1..p_count loop
    select id into v_boarding
      from public.route_stops
     where route_id = v_route
     order by position
      limit 1
      offset (case when v_stop_count >= 3 and i % 2 = 0 then 1 else 0 end);
    select id into v_alighting
      from public.route_stops
     where route_id = v_route
     order by position desc
     limit 1;
    insert into public.tickets (
      company_id, trip_id, code, passenger_name, boarding_stop_id, alighting_stop_id, status, is_test
    )
    values (
      v_trip.company_id, v_trip.id,
      'TEST-' || upper(replace(gen_random_uuid()::text, '-', '')),
      'Pasajero de prueba ' || i, v_boarding, v_alighting,
      case when i = p_count then 'cancelled' else 'valid' end,
      true
    );
    v_inserted := v_inserted + 1;
  end loop;
  return v_inserted;
end $$;
revoke all on function public.create_test_tickets(uuid, int) from public, anon, authenticated;
grant execute on function public.create_test_tickets(uuid, int) to authenticated;

create or replace function public._commit_test_ticket_boarding(
  p_trip uuid, p_code text, p_event uuid, p_override boolean, p_expected_stop uuid,
  p_lat double precision, p_lng double precision, p_accuracy_m double precision, p_fix_at timestamptz
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_trip public.trips;
  v_ticket public.tickets;
  v_event public.ticket_boarding_events;
  v_route uuid;
  v_actual_stop_id uuid;
  v_actual_stop_name text;
  v_distance_m double precision;
  v_second_distance_m double precision;
  v_actual_position int;
  v_boarding_position int;
  v_alighting_position int;
  v_counts jsonb;
  v_title text;
begin
  if public.current_user_role() <> 'driver' then raise exception 'FORBIDDEN'; end if;
  if p_event is null then raise exception 'EVENT_REQUIRED'; end if;
  if p_override and p_expected_stop is null then raise exception 'OVERRIDE_STOP_REQUIRED'; end if;
  if p_code is null or length(btrim(p_code)) < 8 then
    return jsonb_build_object('ok', false, 'code', 'INVALID_TICKET', 'title', 'QR inválido', 'detail', 'El código no corresponde a un pasaje de prueba.');
  end if;

  select * into v_trip
    from public.trips
   where id = p_trip
     and company_id = public.current_company_id()
     and driver_id = auth.uid()
   for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_trip.status <> 'in_progress' then raise exception 'INVALID_STATE: el viaje no está en curso'; end if;

  select d.route_id into v_route
    from public.service_departures d
   where d.id = v_trip.departure_id and d.service_id = v_trip.service_id and d.company_id = v_trip.company_id;
  if not found then raise exception 'NOT_FOUND'; end if;

  if p_lat is null or p_lng is null
     or p_lat::text in ('NaN', 'Infinity', '-Infinity')
     or p_lng::text in ('NaN', 'Infinity', '-Infinity')
     or p_lat < -90 or p_lat > 90 or p_lng < -180 or p_lng > 180
     or p_accuracy_m::text in ('NaN', 'Infinity', '-Infinity')
     or p_accuracy_m is null or p_accuracy_m <= 0 or p_accuracy_m > 50
     or p_fix_at is null
     or p_fix_at > clock_timestamp() + interval '5 seconds'
     or p_fix_at < clock_timestamp() - interval '15 seconds' then
    return jsonb_build_object(
      'ok', false, 'code', 'GPS_REQUIRED', 'title', 'No se pudo verificar la parada',
      'detail', 'Se necesita una ubicación GPS reciente y precisa (máximo 50 m). Activá la ubicación y volvé a escanear.'
    );
  end if;
  if exists (
    select 1 from public.route_stops
     where route_id = v_route and (lat is null or lng is null)
  ) then
    return jsonb_build_object(
      'ok', false, 'code', 'GPS_STOPS_UNCONFIGURED', 'title', 'Faltan coordenadas del recorrido',
      'detail', 'Todas las paradas deben tener coordenadas para verificar el ascenso por GPS.'
    );
  end if;

  with candidates as (
    select rs.id, rs.name, rs.position,
      6371000::double precision * 2 * asin(sqrt(least(
        1::double precision,
        power(sin(radians(rs.lat::double precision - p_lat) / 2), 2)
        + cos(radians(p_lat)) * cos(radians(rs.lat::double precision))
          * power(sin(radians(rs.lng::double precision - p_lng) / 2), 2)
      ))) as distance_m
    from public.route_stops rs
    where rs.route_id = v_route
  ),
  ranked as (
    select id, name, position, distance_m,
      lead(distance_m) over (order by distance_m, position) as second_distance_m
    from candidates
  )
  select id, name, distance_m, second_distance_m
    into v_actual_stop_id, v_actual_stop_name, v_distance_m, v_second_distance_m
    from ranked
   order by distance_m, position
   limit 1;
  if not found then
    return jsonb_build_object(
      'ok', false, 'code', 'GPS_STOPS_UNCONFIGURED', 'title', 'No se pudieron verificar las paradas',
      'detail', 'Este recorrido no tiene paradas geolocalizadas.'
    );
  end if;
  if v_distance_m + p_accuracy_m > 80 then
    return jsonb_build_object(
      'ok', false, 'code', 'GPS_NOT_AT_STOP', 'title', 'La unidad no está junto a una parada',
      'detail', 'Acercá la unidad a una parada del recorrido antes de escanear.'
    );
  end if;
  if v_second_distance_m is not null and v_second_distance_m - v_distance_m <= p_accuracy_m then
    return jsonb_build_object(
      'ok', false, 'code', 'GPS_STOP_AMBIGUOUS', 'title', 'No se pudo distinguir la parada',
      'detail', 'Las paradas están demasiado cerca para la precisión actual del GPS. Esperá una ubicación más precisa.'
    );
  end if;
  if p_expected_stop is not null and p_expected_stop <> v_actual_stop_id then
    return jsonb_build_object(
      'ok', false, 'code', 'GPS_STOP_CHANGED', 'title', 'La ubicación cambió',
      'actual_stop_id', v_actual_stop_id, 'actual_stop', v_actual_stop_name,
      'detail', 'La ubicación GPS ya no coincide con la parada donde se leyó el pasaje. Volvé a escanearlo.'
    );
  end if;

  select rs.position into v_actual_position
    from public.route_stops rs
   where rs.id = v_actual_stop_id and rs.route_id = v_route;

  select * into v_ticket from public.tickets where code = btrim(p_code) for update;
  if not found or v_ticket.company_id <> v_trip.company_id then
    return jsonb_build_object('ok', false, 'code', 'INVALID_TICKET', 'title', 'QR inválido', 'detail', 'No se encontró un pasaje de prueba para este viaje.');
  end if;
  if v_ticket.trip_id <> v_trip.id then
    return jsonb_build_object('ok', false, 'code', 'OTHER_TRIP', 'title', 'Pasaje de otro viaje', 'detail', 'Este QR no pertenece al viaje actual.');
  end if;
  if v_ticket.is_test is distinct from true then
    return jsonb_build_object('ok', false, 'code', 'INVALID_TICKET', 'title', 'QR inválido', 'detail', 'Este escáner solo admite pasajes de prueba.');
  end if;
  if v_ticket.status = 'cancelled' then
    return jsonb_build_object('ok', false, 'code', 'CANCELLED', 'title', 'Pasaje anulado', 'detail', 'El pasaje fue anulado y no puede abordar.');
  end if;

  select * into v_event
    from public.ticket_boarding_events
   where trip_id = v_trip.id and client_event_id = p_event;
  if found then
    if v_event.ticket_id <> v_ticket.id then raise exception 'EVENT_REUSED: el evento ya fue usado por otro pasaje'; end if;
    select jsonb_build_object(
      'onboard', public.trip_onboard(v_trip.id),
      'capacity', coalesce(c.seats, 0),
      'over_capacity', coalesce(c.seats, 0) > 0 and public.trip_onboard(v_trip.id) > c.seats
    ) into v_counts
    from (select 1) q
    left join public.seat_layout_capacity c on c.layout_id = v_trip.layout_id;
    return v_counts || jsonb_build_object(
      'ok', true, 'code', v_ticket.code, 'title', 'Ascenso ya registrado',
      'detail', 'Este mismo evento de lectura ya había sido procesado.',
      'boarding_override', v_event.was_overridden
    );
  end if;
  if exists (
    select 1 from public.passenger_counts
     where trip_id = v_trip.id and client_event_id = p_event
  ) then
    raise exception 'EVENT_REUSED: el evento ya fue usado para otro conteo';
  end if;

  if v_ticket.status = 'boarded' then
    return jsonb_build_object('ok', false, 'code', 'ALREADY_BOARDED', 'title', 'QR ya utilizado', 'detail', 'Este pasaje ya fue validado.');
  end if;

  select rs.position into v_boarding_position
    from public.route_stops rs where rs.id = v_ticket.boarding_stop_id and rs.route_id = v_route;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'TICKET_ROUTE_INVALID', 'title', 'Pasaje inválido', 'detail', 'La parada de ascenso no pertenece al recorrido.');
  end if;
  select rs.position into v_alighting_position
    from public.route_stops rs where rs.id = v_ticket.alighting_stop_id and rs.route_id = v_route;
  if not found or v_boarding_position >= v_alighting_position then
    return jsonb_build_object('ok', false, 'code', 'TICKET_ROUTE_INVALID', 'title', 'Pasaje inválido', 'detail', 'El tramo del pasaje no corresponde al recorrido.');
  end if;
  if v_actual_position >= v_alighting_position then
    return jsonb_build_object('ok', false, 'code', 'PAST_ALIGHTING_STOP', 'title', 'Ascenso no permitido', 'detail', 'La unidad ya llegó a la parada de descenso indicada en el pasaje.');
  end if;

  if v_actual_position <> v_boarding_position and not p_override then
    return jsonb_build_object(
      'ok', false,
      'code', 'BOARDING_STOP_MISMATCH',
      'can_override', true,
      'actual_stop_id', v_actual_stop_id,
      'boarding_stop', (select name from public.route_stops where id = v_ticket.boarding_stop_id),
      'actual_stop', v_actual_stop_name,
      'title', 'El pasaje indica otro punto de ascenso',
      'detail', format('Ascenso registrado en %s; la parada actual es %s.', (select name from public.route_stops where id = v_ticket.boarding_stop_id), v_actual_stop_name)
    );
  end if;
  if p_override and v_actual_position = v_boarding_position then
    return jsonb_build_object('ok', false, 'code', 'OVERRIDE_NOT_NEEDED', 'title', 'No hace falta autorizar', 'detail', 'La parada actual coincide con el pasaje; volvé a escanearlo normalmente.');
  end if;

  v_counts := public.register_count(v_trip.id, 'board', 1, v_actual_stop_id, p_event);
  update public.tickets
     set status = 'boarded',
         actual_boarding_stop_id = v_actual_stop_id,
         boarding_event_id = p_event,
         boarded_at = now(),
         boarded_by = auth.uid(),
         boarding_override = p_override,
         boarding_override_at = case when p_override then now() else null end,
         boarding_override_by = case when p_override then auth.uid() else null end
   where id = v_ticket.id;

  insert into public.ticket_boarding_events (
    company_id, trip_id, ticket_id, driver_id, planned_boarding_stop_id,
    actual_boarding_stop_id, was_overridden, client_event_id
  )
  values (
    v_trip.company_id, v_trip.id, v_ticket.id, auth.uid(), v_ticket.boarding_stop_id,
    v_actual_stop_id, p_override, p_event
  );

  v_title := case when p_override then 'Ascenso autorizado' else 'Pasaje validado' end;
  return v_counts || jsonb_build_object(
    'ok', true, 'code', v_ticket.code, 'title', v_title,
    'actual_stop_id', v_actual_stop_id,
    'actual_stop', v_actual_stop_name,
    'detail', case when p_override then 'El conductor autorizó el ascenso en ' || v_actual_stop_name || '.' else 'Ascenso registrado.' end,
    'boarding_override', p_override
  );
end $$;
revoke all on function public._commit_test_ticket_boarding(
  uuid, text, uuid, boolean, uuid, double precision, double precision, double precision, timestamptz
) from public, anon, authenticated;

create or replace function public.scan_ticket(p_trip uuid, p_code text, p_stop uuid, p_event uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  raise exception 'GPS_REQUIRED: esta versión del escáner no acepta una parada elegida por el cliente';
end
$$;
revoke all on function public.scan_ticket(uuid, text, uuid, uuid) from public, anon, authenticated;

create or replace function public.scan_ticket(
  p_trip uuid, p_code text, p_event uuid, p_lat double precision, p_lng double precision,
  p_accuracy_m double precision, p_fix_at timestamptz
) returns jsonb
language sql security definer set search_path = public as $$
  select public._commit_test_ticket_boarding(
    p_trip, p_code, p_event, false, null, p_lat, p_lng, p_accuracy_m, p_fix_at
  )
$$;
revoke all on function public.scan_ticket(uuid, text, uuid, double precision, double precision, double precision, timestamptz) from public, anon, authenticated;
grant execute on function public.scan_ticket(uuid, text, uuid, double precision, double precision, double precision, timestamptz) to authenticated;

create or replace function public.override_ticket_boarding(p_trip uuid, p_code text, p_stop uuid, p_event uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  raise exception 'GPS_REQUIRED: esta versión de autorización no verifica la ubicación GPS';
end
$$;
revoke all on function public.override_ticket_boarding(uuid, text, uuid, uuid) from public, anon, authenticated;

create or replace function public.override_ticket_boarding(
  p_trip uuid, p_code text, p_stop uuid, p_event uuid, p_lat double precision, p_lng double precision,
  p_accuracy_m double precision, p_fix_at timestamptz
) returns jsonb
language sql security definer set search_path = public as $$
  select public._commit_test_ticket_boarding(
    p_trip, p_code, p_event, true, p_stop, p_lat, p_lng, p_accuracy_m, p_fix_at
  )
$$;
revoke all on function public.override_ticket_boarding(uuid, text, uuid, uuid, double precision, double precision, double precision, timestamptz) from public, anon, authenticated;
grant execute on function public.override_ticket_boarding(uuid, text, uuid, uuid, double precision, double precision, double precision, timestamptz) to authenticated;
