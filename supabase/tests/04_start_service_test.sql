-- Iniciar servicio desde el conductor, tipos de dia e incidencias (despues de 01-03).
-- Nota: usa la hora real; solo es inestable en los 10 minutos previos a la medianoche (hora de Argentina).
\set ON_ERROR_STOP on

-- unidad libre para estas pruebas
insert into public.vehicles (id, company_id, kind, internal_number, plate)
  values ('22222222-0000-0000-0000-0000000000f1', 'aaaaaaaa-0000-0000-0000-000000000001', 'combi', '77', 'ZZ777ZZ');

-- ---- 1. el administrador arma el servicio 600 con tipos de dia
select t.login('a1000000-0000-0000-0000-000000000001');
create temp table hh as select
  to_char((now() at time zone 'America/Argentina/Buenos_Aires') + interval '10 minutes', 'HH24:MI') as near,
  to_char((now() at time zone 'America/Argentina/Buenos_Aires') + interval '180 minutes', 'HH24:MI') as far,
  to_char((now() at time zone 'America/Argentina/Buenos_Aires') + interval '20 minutes', 'HH24:MI') as sat;
grant all on hh to authenticated;
create temp table s600 as select public.save_service(null, '600', true,
  format('[{"route_id":"33333333-0000-0000-0000-000000000001","time":"%s","day_types":["weekday","holiday"]},
           {"route_id":"33333333-0000-0000-0000-000000000001","time":"%s","day_types":["holiday"]},
           {"route_id":"33333333-0000-0000-0000-000000000001","time":"%s","day_types":["saturday"]},
           {"route_id":"33333333-0000-0000-0000-000000000001","time":"00:00","day_types":["holiday"]}]',
         (select near from hh), (select far from hh), (select sat from hh))::jsonb,
  t.stops_json(array['33333333-0000-0000-0000-000000000001'::uuid])) as id;
grant all on s600 to authenticated;
select t.logout();
create function t.dep(h text) returns uuid language sql stable as
  $$ select id from public.service_departures where service_id = (select id from s600) and departure_time = h::time $$;
grant execute on function t.dep(text) to authenticated;
select t.login('a1000000-0000-0000-0000-000000000001');

-- feriado: solo salen las 3 salidas marcadas como feriado; el tipo de dia por defecto sale de la fecha
select t.expect_eq(public.generate_trips(date '2027-03-01', 'holiday'), 3, 'feriado: 3 salidas del servicio 600');
select t.expect_eq((select count(*) from public.trips where service_date = date '2027-03-01' and day_type = 'holiday'), 3::bigint, 'viajes con tipo feriado');
select t.expect_eq(public.day_type_of(date '2026-11-14'), 'saturday', 'sabado');
select t.expect_eq(public.day_type_of(date '2026-11-15'), 'sunday', 'domingo');
select t.expect_eq(public.day_type_of(date '2026-11-16'), 'weekday', 'lunes habil');
select t.expect_fail($q$select public.generate_trips(date '2027-03-02', 'otro')$q$, 'DAY_TYPE_INVALID');
select t.logout();

-- ---- 2. el conductor declara el servicio
select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_fail(format($q$select public.start_service(%L, %L, 'holiday', %L)$q$, (select id from s600), t.dep((select near from hh)), '22222222-0000-0000-0000-0000000000f1'), 'NO_OPEN_SHIFT');
select public.start_shift();
select t.expect_fail(format($q$select public.start_service(%L, %L, 'xyz', %L)$q$, (select id from s600), t.dep((select near from hh)), '22222222-0000-0000-0000-0000000000f1'), 'DAY_TYPE_INVALID');
select t.expect_fail(format($q$select public.start_service(%L, %L, 'sunday', %L)$q$, (select id from s600), t.dep((select near from hh)), '22222222-0000-0000-0000-0000000000f1'), 'DAY_TYPE_MISMATCH');
-- la unidad del viaje iniciado a mano en 01 sigue en curso
select t.expect_fail(format($q$select public.start_service(%L, %L, 'holiday', '22222222-0000-0000-0000-000000000001')$q$, (select id from s600), t.dep((select near from hh))), 'VEHICLE_BUSY');
-- dentro del horario: no hace falta motivo
select public.start_service((select id from s600), t.dep((select near from hh)), 'holiday', '22222222-0000-0000-0000-0000000000f1');
select t.expect_eq((select status::text from public.trips where departure_id = t.dep((select near from hh)) and day_type = 'holiday' and driver_id = auth.uid() order by created_at desc limit 1), 'in_progress', 'viaje en curso');
select t.expect_eq((select started_manually from public.trips where departure_id = t.dep((select near from hh)) and driver_id = auth.uid() order by created_at desc limit 1), false, 'dentro de horario: no es forzado');
select t.expect_fail(format($q$select public.start_service(%L, %L, 'holiday', '22222222-0000-0000-0000-0000000000f1')$q$, (select id from s600), t.dep((select far from hh))), 'TRIP_IN_PROGRESS');

-- incidencias del conductor
create temp table tr as select id from public.trips where driver_id = auth.uid() and status = 'in_progress';
grant all on tr to authenticated;
select public.report_incident((select id from tr), 'breakdown', 'Pinchadura');
select t.expect_fail(format($q$select public.report_incident(%L, 'other')$q$, (select id from tr)), 'NOTE_REQUIRED');
select t.expect_fail(format($q$select public.report_incident(%L, 'xx', 'nota')$q$, (select id from tr)), 'KIND_INVALID');
select t.expect_eq((select count(*) from public.incidents), 1::bigint, 'el conductor ve su incidencia');
select public.end_trip((select id from tr), true);

-- fuera de horario: exige motivo y queda marcado como forzado
select t.expect_fail(format($q$select public.start_service(%L, %L, 'holiday', '22222222-0000-0000-0000-0000000000f1')$q$, (select id from s600), t.dep((select far from hh))), 'REASON_REQUIRED');
select public.start_service((select id from s600), t.dep((select far from hh)), 'holiday', '22222222-0000-0000-0000-0000000000f1', 'Salida adelantada por demanda');
select t.expect_eq((select started_manually from public.trips where departure_id = t.dep((select far from hh)) and driver_id = auth.uid() order by created_at desc limit 1), true, 'fuera de horario: forzado');
select t.expect_eq((select start_reason from public.trips where departure_id = t.dep((select far from hh)) and driver_id = auth.uid() order by created_at desc limit 1), 'Salida adelantada por demanda', 'motivo guardado');
select public.end_trip((select id from public.trips where driver_id = auth.uid() and status = 'in_progress'), true);

-- Una salida a medianoche usa la fecha elegida en el calendario, no la fecha actual.
create temp table selected_date as
select (now() at time zone 'America/Argentina/Buenos_Aires')::date + 1 as service_date;
grant all on selected_date to authenticated;
select public.start_service((select id from s600), t.dep('00:00'), 'holiday',
  '22222222-0000-0000-0000-0000000000f1', 'Prueba de fecha seleccionada', (select service_date from selected_date));
select t.expect_eq(
  (select service_date::text from public.trips where departure_id = t.dep('00:00') and driver_id = auth.uid() order by created_at desc limit 1),
  (select service_date::text from selected_date), 'guarda la fecha elegida para salida de medianoche');
select t.expect_eq(
  (select to_char(scheduled_departure, 'YYYY-MM-DD HH24:MI') from public.trips where departure_id = t.dep('00:00') and driver_id = auth.uid() order by created_at desc limit 1),
  (select to_char((service_date + time '00:00') at time zone 'America/Argentina/Buenos_Aires', 'YYYY-MM-DD HH24:MI') from selected_date),
  'programa medianoche en el dia elegido');
select public.end_trip((select id from public.trips where driver_id = auth.uid() and status = 'in_progress'), true);

-- una salida que ya se inicio hoy no se vuelve a iniciar
select t.expect_fail(format($q$select public.start_service(%L, %L, 'holiday', '22222222-0000-0000-0000-0000000000f1')$q$, (select id from s600), t.dep((select near from hh))), 'ALREADY_STARTED');
select t.logout();

-- ---- 3. viaje que el administrador dejo asignado a otro conductor
-- (viaje generado hoy como sabado para la salida "sat" y asignado al conductor 2)
select t.login('a1000000-0000-0000-0000-000000000001');
select public.generate_trips((now() at time zone 'America/Argentina/Buenos_Aires')::date, 'saturday');
update public.trips set driver_id = 'a3000000-0000-0000-0000-000000000001'
 where departure_id = t.dep((select sat from hh)) and service_date = (now() at time zone 'America/Argentina/Buenos_Aires')::date;
select t.logout();
select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_fail(format($q$select public.start_service(%L, %L, 'saturday', '22222222-0000-0000-0000-0000000000f1')$q$, (select id from s600), t.dep((select sat from hh))), 'TAKEN');
select t.expect_eq((select count(*) from public.incidents where driver_id <> auth.uid()), 0::bigint, 'conductor no ve incidencias ajenas');
select t.logout();
select t.login('a3000000-0000-0000-0000-000000000001');
select public.start_shift();
select public.start_service((select id from s600), t.dep((select sat from hh)), 'saturday', '22222222-0000-0000-0000-0000000000f1');
select t.expect_eq((select count(*) from public.trips where departure_id = t.dep((select sat from hh)) and service_date = (now() at time zone 'America/Argentina/Buenos_Aires')::date), 1::bigint, 'reutiliza el viaje generado');
select t.expect_fail(format($q$select public.report_incident(%L, 'delay')$q$, (select id from tr)), 'NOT_FOUND');
select t.logout();

-- ---- 4. aislamiento de incidencias y servicios
select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*) from public.incidents), 1::bigint, 'el administrador ve las incidencias de la empresa');
select t.logout();
select t.login('b1000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*) from public.incidents), 0::bigint, 'otra empresa no ve incidencias');
select t.logout();

\echo 'PRUEBAS DE INICIO DE SERVICIO PASARON'
