\set ON_ERROR_STOP on

create temp table trip_reopen_target as
select t.id, t.service_id, t.departure_id, t.vehicle_id, t.service_date
  from public.trips t
  join public.services s on s.id = t.service_id
 where s.code = '214' and t.service_date = date '2026-11-14';
grant all on trip_reopen_target to authenticated;

select t.login('a2000000-0000-0000-0000-000000000001');
select public.end_trip(
  (select t.id from public.trips t join public.services s on s.id = t.service_id
    where s.code = '216' and t.status = 'in_progress'),
  false
);
select t.logout();

select t.login('a3000000-0000-0000-0000-000000000001');
select public.start_shift();
select t.expect_fail(format(
  $q$select public.start_service(%L, %L, 'saturday', %L, null, date '2026-11-14')$q$,
  (select service_id from trip_reopen_target),
  (select departure_id from trip_reopen_target),
  (select vehicle_id from trip_reopen_target)
), 'REOPEN_REASON_REQUIRED');

select public.start_service(
  (select service_id from trip_reopen_target),
  (select departure_id from trip_reopen_target),
  'saturday',
  (select vehicle_id from trip_reopen_target),
  'Relevo por enfermedad',
  date '2026-11-14'
);
select t.expect_eq((select count(*) from public.trips where id = (select id from trip_reopen_target)), 1::bigint,
  'retoma el mismo viaje sin duplicarlo');
select t.expect_eq((select status::text from public.trips where id = (select id from trip_reopen_target)), 'in_progress',
  'reabre el viaje cerrado');
select t.expect_eq((select ended_at is null from public.trips where id = (select id from trip_reopen_target)), true,
  'limpia el cierre anterior al retomar');
select t.expect_eq((select driver_id::text from public.trips where id = (select id from trip_reopen_target)), auth.uid()::text,
  'asigna el viaje retomado al nuevo conductor');
select t.expect_eq((select started_manually from public.trips where id = (select id from trip_reopen_target)), true,
  'marca la reapertura como manual');
select t.expect_eq((select start_reason from public.trips where id = (select id from trip_reopen_target)), 'Relevo por enfermedad',
  'conserva el motivo de reapertura');
select t.logout();

select t.login('a2000000-0000-0000-0000-000000000001');
select public.start_shift();
select t.expect_fail(format(
  $q$select public.start_service(%L, %L, 'saturday', %L, null, date '2026-11-14')$q$,
  (select service_id from trip_reopen_target),
  (select departure_id from trip_reopen_target),
  (select vehicle_id from trip_reopen_target)
), 'TAKEOVER_REASON_REQUIRED');

select public.start_service(
  (select service_id from trip_reopen_target),
  (select departure_id from trip_reopen_target),
  'saturday',
  (select vehicle_id from trip_reopen_target),
  'Cambio de conductor por contingencia',
  date '2026-11-14'
);
select t.expect_eq((select status::text from public.trips where id = (select id from trip_reopen_target)), 'in_progress',
  'mantiene el viaje en curso durante el relevo');
select t.expect_eq((select driver_id::text from public.trips where id = (select id from trip_reopen_target)), auth.uid()::text,
  'transfiere el viaje al conductor que lo retoma');
select t.expect_eq((select count(*) from public.trips where departure_id = (select departure_id from trip_reopen_target)
  and service_date = date '2026-11-14'), 1::bigint, 'el relevo no crea otro viaje para la misma salida');
select t.logout();

select t.login('a3000000-0000-0000-0000-000000000001');
select t.expect_fail(format(
  $q$select public.register_count(%L, 'board', 1, null, gen_random_uuid())$q$,
  (select id from trip_reopen_target)
), 'NOT_FOUND');
select t.logout();

select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*) > 0 from public.audit_log
  where entity = 'trips'
    and entity_id = (select id from trip_reopen_target)
    and actor_id = 'a3000000-0000-0000-0000-000000000001'
    and details -> 'new' ->> 'start_reason' = 'Relevo por enfermedad'), true,
  'audita el motivo y quien reabrió el viaje');
select t.expect_eq((select count(*) > 0 from public.audit_log
  where entity = 'trips'
    and entity_id = (select id from trip_reopen_target)
    and actor_id = 'a2000000-0000-0000-0000-000000000001'
    and details -> 'new' ->> 'start_reason' = 'Cambio de conductor por contingencia'), true,
  'audita el motivo y quien tomó el relevo');
select t.logout();

\echo 'PRUEBAS DE RELEVO Y REAPERTURA DE VIAJE PASARON'
