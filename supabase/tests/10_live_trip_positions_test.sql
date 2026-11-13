\set ON_ERROR_STOP on

select t.login('a2000000-0000-0000-0000-000000000001');
select public.update_trip_live_position(
  (select t.id from public.trips t join public.services s on s.id = t.service_id
    where s.code = '214' and t.status = 'in_progress'),
  -31.7333, -60.5236, 12, 90, now()
);
select t.expect_fail(format(
  $q$select public.update_trip_live_position(%L, -31.7, -60.5, 101, null, now())$q$,
  (select t.id from public.trips t join public.services s on s.id = t.service_id
    where s.code = '214' and t.status = 'in_progress')
), 'GPS_INVALID');
select t.logout();

select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*) from public.admin_live_trips(null)), 1::bigint,
  'el admin de empresa solo ve el viaje activo de su empresa');
select t.expect_eq((select service_code from public.admin_live_trips(null) limit 1), '214',
  'incluye los datos del servicio activo');
select t.expect_eq((select count(*) from public.admin_live_trips(null) where location_at is not null), 1::bigint,
  'el admin recibe la ubicacion vigente del viaje');
select t.expect_eq((select jsonb_array_length(route_stops) from public.admin_live_trip_schedule(null) limit 1), 3,
  'el admin recibe las paradas y horarios para calcular puntualidad');
select t.logout();

select t.login('b1000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*) from public.admin_live_trips(null)), 0::bigint,
  'otra empresa no ve posiciones ajenas');
select t.expect_eq((select count(*) from public.admin_live_trip_schedule(null)), 0::bigint,
  'otra empresa tampoco recibe los horarios ajenos');
select t.expect_fail(
  $q$select * from public.admin_live_trips('aaaaaaaa-0000-0000-0000-000000000001')$q$,
  'FORBIDDEN'
);
select t.expect_fail(
  $q$select * from public.admin_live_trip_schedule('aaaaaaaa-0000-0000-0000-000000000001')$q$,
  'FORBIDDEN'
);
select t.logout();

select t.login('f0000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*) from public.admin_live_trips(null)), 1::bigint,
  'el admin general puede ver los servicios activos de todas las empresas');
select t.expect_eq((select count(*) from public.admin_live_trip_schedule(null)), 1::bigint,
  'el admin general recibe el horario de las rutas activas');
select t.logout();

select t.login('a2000000-0000-0000-0000-000000000001');
select public.end_trip(
  (select t.id from public.trips t join public.services s on s.id = t.service_id
    where s.code = '214' and t.status = 'in_progress'),
  false
);
select t.logout();
select t.expect_eq((select count(*) from public.trip_live_positions), 0::bigint,
  'borra la ultima ubicacion al terminar el viaje');

\echo 'PRUEBAS DE GPS EN VIVO PASARON'
