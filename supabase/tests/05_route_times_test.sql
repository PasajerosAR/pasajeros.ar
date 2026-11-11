-- Horarios estandar por recorrido y cambio de sentido (despues de 01-04).
\set ON_ERROR_STOP on

-- recorrido de vuelta de la empresa 1
insert into public.routes (id, name, company_id) values ('33333333-0000-0000-0000-0000000000b1', 'Santa Fe - Parana', 'aaaaaaaa-0000-0000-0000-000000000001');
insert into public.route_stops (route_id, position, name) values
  ('33333333-0000-0000-0000-0000000000b1', 1, 'Santa Fe'), ('33333333-0000-0000-0000-0000000000b1', 2, 'Parana');

select t.login('a1000000-0000-0000-0000-000000000001');
-- el administrador guarda horarios estandar y los lee; otra empresa no los ve
insert into public.route_times (company_id, route_stop_id, minutes_from_start, dwell_minutes)
  select 'aaaaaaaa-0000-0000-0000-000000000001', id, (position - 1) * 50, 0 from public.route_stops where route_id = '33333333-0000-0000-0000-0000000000b1';
select t.expect_eq((select count(*) from public.route_times where company_id = 'aaaaaaaa-0000-0000-0000-000000000001'), 2::bigint, 'estandar de la vuelta guardado');
select t.expect_fail($q$insert into public.route_times (company_id, route_stop_id, minutes_from_start)
  select 'bbbbbbbb-0000-0000-0000-000000000002', id, 0 from public.route_stops limit 1$q$, 'row-level security');

-- servicio con una salida de ida sin viajes realizados: se puede cambiar de sentido (los viajes programados se descartan)
create temp table s700 as select public.save_service(null, '700', true,
  '[{"route_id":"33333333-0000-0000-0000-000000000001","time":"05:00","day_types":["weekday"]}]'::jsonb,
  t.stops_json(array['33333333-0000-0000-0000-000000000001'::uuid])) as id;
grant all on s700 to authenticated;
select public.generate_trips(date '2027-04-05', 'weekday');
select t.expect_eq((select count(*) from public.trips where service_id = (select id from s700)), 1::bigint, 'viaje programado de la salida');
create temp table d700 as select id from public.service_departures where service_id = (select id from s700);
grant all on d700 to authenticated;
select public.save_service((select id from s700), '700', true,
  format('[{"id":"%s","route_id":"33333333-0000-0000-0000-0000000000b1","time":"05:00","day_types":["weekday"]}]', (select id from d700))::jsonb,
  t.stops_json(array['33333333-0000-0000-0000-0000000000b1'::uuid]));
select t.expect_eq((select route_id::text from public.service_departures where id = (select id from d700)), '33333333-0000-0000-0000-0000000000b1', 'sentido cambiado');
select t.expect_eq((select count(*) from public.trips where service_id = (select id from s700)), 0::bigint, 'viaje programado descartado');
select t.logout();

-- con un viaje ya realizado no se puede
select t.login('a1000000-0000-0000-0000-000000000001');
select public.generate_trips(date '2027-04-06', 'weekday');
select t.logout();
select set_config('app.trip_rpc', 'on', false);
update public.trips set status = 'in_progress', started_at = now() where service_id = (select id from s700);
select set_config('app.trip_rpc', 'off', false);
select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_fail(format($q$select public.save_service(%L, '700', true,
  '[{"id":"%s","route_id":"33333333-0000-0000-0000-000000000001","time":"05:00","day_types":["weekday"]}]'::jsonb,
  t.stops_json(array['33333333-0000-0000-0000-000000000001'::uuid]))$q$, (select id from s700), (select id from d700)), 'ROUTE_LOCKED');
select t.logout();
select 'PRUEBAS DE HORARIOS ESTANDAR PASARON';
