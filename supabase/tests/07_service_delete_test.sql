-- Eliminacion permanente de servicios sin historial y proteccion de viajes asociados.
\set ON_ERROR_STOP on
select t.login('a1000000-0000-0000-0000-000000000001');

create temp table service_with_trips as
select id from public.services where company_id = 'aaaaaaaa-0000-0000-0000-000000000001' and code = '600';
grant all on service_with_trips to authenticated;
select t.expect_fail(
  format($q$select public.delete_service(%L)$q$, (select id from service_with_trips)),
  'SERVICE_HAS_TRIPS'
);
select t.expect_eq(
  (select count(*) from public.services where id = (select id from service_with_trips)),
  1::bigint, 'no borra un servicio con viajes'
);

create temp table service_to_delete as
select public.save_service(null, '998', true,
  '[{"route_id":"33333333-0000-0000-0000-000000000001","time":"12:00","day_types":["weekday"]}]'::jsonb,
  t.stops_json(array['33333333-0000-0000-0000-000000000001'::uuid])) as id;
grant all on service_to_delete to authenticated;
create temp table service_delete_result as
select public.delete_service((select id from service_to_delete)) as result;
grant all on service_delete_result to authenticated;
select t.expect_eq((select result ->> 'deleted' from service_delete_result), 'true', 'elimina el servicio sin viajes');
select t.expect_eq(
  (select count(*) from public.service_departures where service_id = (select id from service_to_delete)),
  0::bigint, 'elimina todas las salidas del servicio'
);
select t.expect_eq(
  (select count(*) from public.service_stops where service_id = (select id from service_to_delete)),
  0::bigint, 'elimina los tiempos por parada del servicio'
);
select t.expect_eq(
  (select count(*) from public.services where id = (select id from service_to_delete)),
  0::bigint, 'el servicio desaparece de la base'
);

select t.logout();
select t.login('b1000000-0000-0000-0000-000000000001');
select t.expect_fail(
  format($q$select public.delete_service(%L)$q$, (select id from service_with_trips)),
  'NOT_FOUND'
);
select t.logout();
\echo 'PRUEBAS DE ELIMINACION DE SERVICIOS PASARON'
