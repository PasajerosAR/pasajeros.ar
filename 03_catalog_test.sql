-- Catalogo de recorridos, tiempos por servicio y administrador general (despues de 01 y 02).
\set ON_ERROR_STOP on

-- ---- 1. alta de empresa y catalogo: solo administrador general
select t.login('f0000000-0000-0000-0000-000000000001');
insert into public.places (id, name, province) values
  ('77777777-0000-0000-0000-000000000001', 'Parana', 'Entre Rios'),
  ('77777777-0000-0000-0000-000000000002', 'Colonia Avellaneda', 'Entre Rios'),
  ('77777777-0000-0000-0000-000000000003', 'Santa Fe', 'Santa Fe');
create temp table nc as select public.create_company('Empresa C') as id;
grant all on nc to authenticated;
select t.expect_eq((select count(*) from public.companies where name = 'Empresa C'), 1::bigint, 'plataforma crea empresa');
select t.expect_fail($q$select public.create_company('  ')$q$, 'NAME_REQUIRED');
create temp table nr as select public.save_route(null, 'Parana - Oro Verde', true,
  '[{"name":"Parana","lat":-31.73,"lng":-60.52,"place_id":"77777777-0000-0000-0000-000000000001"},{"name":"Oro Verde","place_id":"77777777-0000-0000-0000-000000000001"}]'::jsonb, 'aaaaaaaa-0000-0000-0000-000000000001') as id;
create temp table nrc as select public.save_route(null, 'Ruta de C', true,
  '[{"name":"X","place_id":"77777777-0000-0000-0000-000000000001"},{"name":"Y","place_id":"77777777-0000-0000-0000-000000000001"}]'::jsonb, (select id from nc)) as id;
grant all on nrc to authenticated;
select t.expect_fail($q$select public.save_route(null, 'Sin empresa', true, '[{"name":"a","place_id":"77777777-0000-0000-0000-000000000001"},{"name":"b","place_id":"77777777-0000-0000-0000-000000000001"}]'::jsonb, null)$q$, 'COMPANY_REQUIRED');
grant all on nr to authenticated;
select t.expect_eq((select count(*) from public.route_stops where route_id = (select id from nr)), 2::bigint, 'dos paradas');
select t.expect_eq((select position from public.route_stops where route_id = (select id from nr) and name = 'Oro Verde'), 2, 'posiciones en orden');
select public.save_route((select id from nr), 'Parana - Oro Verde', true,
  '[{"name":"Parana","place_id":"77777777-0000-0000-0000-000000000001"},{"name":"Colonia","place_id":"77777777-0000-0000-0000-000000000001"},{"name":"Oro Verde","place_id":"77777777-0000-0000-0000-000000000001"}]'::jsonb, 'aaaaaaaa-0000-0000-0000-000000000001');
select t.expect_eq((select count(*) from public.route_stops where route_id = (select id from nr)), 3::bigint, 'tres paradas tras editar (sin servicios)');
select t.expect_fail($q$select public.save_route(null, 'Corto', true, '[{"name":"Solo una","place_id":"77777777-0000-0000-0000-000000000001"}]'::jsonb, 'aaaaaaaa-0000-0000-0000-000000000001')$q$, 'STOPS_REQUIRED');
-- recorrido en uso: solo correcciones, misma cantidad de paradas
select t.expect_fail($q$select public.save_route('33333333-0000-0000-0000-000000000001', 'Parana - Santa Fe', true,
  '[{"name":"A","place_id":"77777777-0000-0000-0000-000000000001"},{"name":"B","place_id":"77777777-0000-0000-0000-000000000001"}]'::jsonb, 'aaaaaaaa-0000-0000-0000-000000000001')$q$, 'ROUTE_IN_USE');
select t.expect_fail($q$select public.save_route('33333333-0000-0000-0000-000000000001', 'Parana - Santa Fe', true,
  '[{"name":"A","place_id":"77777777-0000-0000-0000-000000000001"},{"name":"B","place_id":"77777777-0000-0000-0000-000000000001"},{"name":"C","place_id":"77777777-0000-0000-0000-000000000001"}]'::jsonb, 'bbbbbbbb-0000-0000-0000-000000000001')$q$, 'COMPANY_LOCKED');
select public.save_route('33333333-0000-0000-0000-000000000001', 'Parana - Santa Fe', true,
  '[{"name":"Parana","place_id":"77777777-0000-0000-0000-000000000001"},{"name":"Colonia Avellaneda","place_id":"77777777-0000-0000-0000-000000000001"},{"name":"Santa Fe Terminal","place_id":"77777777-0000-0000-0000-000000000001"}]'::jsonb, 'aaaaaaaa-0000-0000-0000-000000000001');
select t.expect_eq((select name from public.route_stops where id = '44444444-0000-0000-0000-000000000003'), 'Santa Fe Terminal', 'correccion conserva el id de la parada');
-- localidad obligatoria, origen/destino y trazado
select t.expect_fail($q$select public.save_route(null, 'Sin localidad', true, '[{"name":"a"},{"name":"b"}]'::jsonb, 'aaaaaaaa-0000-0000-0000-000000000001')$q$, 'PLACE_REQUIRED');
select t.expect_fail($q$select public.save_route(null, 'Localidad falsa', true,
  '[{"name":"a","place_id":"99999999-0000-0000-0000-000000000001"},{"name":"b","place_id":"99999999-0000-0000-0000-000000000001"}]'::jsonb, 'aaaaaaaa-0000-0000-0000-000000000001')$q$, 'PLACE_INVALID');
select t.expect_fail($q$select public.save_route(null, 'Trazado roto', true,
  '[{"name":"a","place_id":"77777777-0000-0000-0000-000000000001"},{"name":"b","place_id":"77777777-0000-0000-0000-000000000003"}]'::jsonb,
  'aaaaaaaa-0000-0000-0000-000000000001', '[[1,2,3]]'::jsonb)$q$, 'PATH_INVALID');
create temp table nrp as select public.save_route(null, 'Parana - Santa Fe (trazado)', true,
  '[{"name":"Terminal Parana","place_id":"77777777-0000-0000-0000-000000000001"},
    {"name":"Colonia","place_id":"77777777-0000-0000-0000-000000000002"},
    {"name":"Terminal Santa Fe","place_id":"77777777-0000-0000-0000-000000000003"}]'::jsonb,
  'aaaaaaaa-0000-0000-0000-000000000001',
  '[[-31.73,-60.52],[-31.7,-60.3],[-31.63,-60.7]]'::jsonb, '[{"seg":0,"lat":-31.71,"lng":-60.4}]'::jsonb) as id;
grant all on nrp to authenticated;
select t.expect_eq((select origin_place_id from public.routes where id = (select id from nrp)), '77777777-0000-0000-0000-000000000001'::uuid, 'origen = localidad de la primera parada');
select t.expect_eq((select destination_place_id from public.routes where id = (select id from nrp)), '77777777-0000-0000-0000-000000000003'::uuid, 'destino = localidad de la ultima parada');
select t.expect_eq((select jsonb_array_length(path) from public.routes where id = (select id from nrp)), 3, 'trazado guardado');
select t.expect_eq((select jsonb_array_length(via) from public.routes where id = (select id from nrp)), 1, 'punto de paso guardado');
select t.expect_fail($q$insert into public.places (name, province) values ('parana', 'entre rios')$q$, 'duplicate key');
-- la plataforma no ve datos de empresas
select t.expect_eq((select count(*) from public.vehicles), 0::bigint, 'plataforma no ve vehiculos');
select t.expect_eq((select count(*) from public.services), 0::bigint, 'plataforma no ve servicios');
select t.expect_eq((select count(*) from public.trips), 0::bigint, 'plataforma no ve viajes');
select t.logout();

-- ---- 2. las empresas leen el catalogo pero no lo editan
select t.login('b1000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*) from public.routes), 0::bigint, 'empresa B no ve recorridos de otras empresas');
select t.expect_eq((select count(*) from public.route_stops), 0::bigint, 'ni sus paradas');
select t.expect_fail($q$select public.save_route(null, 'X', true, '[{"name":"a"},{"name":"b"}]'::jsonb, 'bbbbbbbb-0000-0000-0000-000000000001')$q$, 'FORBIDDEN');
select t.expect_fail($q$select public.create_company('X')$q$, 'FORBIDDEN');
update public.route_stops set name = 'hack';
select t.expect_eq((select count(*) from public.route_stops where name = 'hack'), 0::bigint, 'RLS: no edita paradas');
select t.expect_eq((select count(*) from public.service_stops), 0::bigint, 'B no ve tiempos de A');
select t.logout();

-- ---- 3. servicios con varias salidas (ida y vuelta)
create function t.stops_json(routes uuid[], first_m int default 0) returns jsonb language sql stable as $$
  select jsonb_agg(jsonb_build_object('route_stop_id', id, 'minutes_from_start', case when position = 1 then first_m else (position - 1) * 20 end) order by route_id, position)
    from public.route_stops where route_id = any (routes) $$;
create function t.deps(sid uuid) returns jsonb language sql stable as $$
  select jsonb_agg(jsonb_build_object('id', id, 'route_id', route_id, 'time', departure_time, 'day_types', day_types, 'active', active) order by departure_time)
    from public.service_departures where service_id = sid $$;
grant execute on all functions in schema t to authenticated;

select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*) from public.routes), 3::bigint, 'A ve solo sus 3 recorridos');
select t.expect_eq((select count(*) from public.service_departures), 2::bigint, 'A tiene 2 salidas (los servicios 214 y 216)');

-- servicio 500: ida a las 06:00 (todos los dias) y 12:00 (lun-vie), vuelta a las 07:00 (todos los dias)
create temp table s500 as select public.save_service(null, '500', true,
  format('[{"route_id":"%1$s","time":"06:00","day_types":["weekday","saturday","sunday"]},
           {"route_id":"%1$s","time":"12:00","day_types":["weekday"]},
           {"route_id":"%2$s","time":"07:00","day_types":["weekday","saturday","sunday"]}]',
         '33333333-0000-0000-0000-000000000001', (select id from nr))::jsonb,
  t.stops_json(array['33333333-0000-0000-0000-000000000001'::uuid, (select id from nr)])) as id;
grant all on s500 to authenticated;
select t.expect_eq((select count(*) from public.service_departures where service_id = (select id from s500)), 3::bigint, 'servicio con 3 salidas');
select t.expect_eq((select count(*) from public.service_stops where service_id = (select id from s500)), 6::bigint, 'tiempos de ida (3 paradas) y vuelta (3)');

-- sabado: 214 y 216 + 06:00 y 07:00 del 500; lunes: 214 y 216 + las 3 salidas
select t.expect_eq(public.generate_trips(date '2026-11-28'), 4, 'sabado: 4 viajes');
select t.expect_eq(public.generate_trips(date '2026-11-30'), 5, 'lunes: 5 viajes');
select t.expect_eq(public.generate_trips(date '2026-11-30'), 0, 'generar sigue siendo idempotente');
select t.expect_eq((select count(*) from public.trips where service_id = (select id from s500) and service_date = date '2026-11-30'), 3::bigint, 'tres viajes del servicio 500 el lunes');

-- una salida con viajes no se quita, pero se puede pausar
select t.expect_fail(format($q$select public.save_service(%L, '500', true,
  (select jsonb_agg(e) from jsonb_array_elements(t.deps(%L)) e where e ->> 'time' <> '12:00:00'), t.stops_json(array['33333333-0000-0000-0000-000000000001'::uuid, (select id from nr)]))$q$,
  (select id from s500), (select id from s500)), 'DEPARTURE_HAS_TRIPS');
update public.service_departures set active = false where service_id = (select id from s500) and departure_time = '12:00';
select t.expect_eq(public.generate_trips(date '2026-12-07'), 4, 'lunes siguiente: la salida pausada no genera viaje');
-- no se cambia a mano la hora ni el sentido de una salida
select t.expect_fail($q$update public.service_departures set departure_time = '13:00' where service_id = (select id from s500)$q$, 'USE_RPC');
-- cambiar el sentido de una salida con viajes ya realizados (con solo programados se permite: ver 05)
select set_config('app.trip_rpc', 'on', false);
update public.trips set status = 'in_progress', started_at = now() where departure_id in (select id from public.service_departures where service_id = (select id from s500) and departure_time = '06:00');
select set_config('app.trip_rpc', 'off', false);
select t.expect_fail(format($q$select public.save_service(%L, '500', true,
  (select jsonb_agg(case when e ->> 'time' = '06:00:00' then e || jsonb_build_object('route_id', %L::uuid) else e end) from jsonb_array_elements(t.deps(%L)) e),
  t.stops_json(array['33333333-0000-0000-0000-000000000001'::uuid, (select id from nr)]))$q$,
  (select id from s500), (select id from nr), (select id from s500)), 'ROUTE_LOCKED');
-- agregar una salida nueva y cambiar tiempos
select public.save_service((select id from s500), '500', true,
  (select t.deps((select id from s500)) || '[{"route_id":"33333333-0000-0000-0000-000000000001","time":"18:00","day_types":["weekday","saturday"]}]'::jsonb),
  t.stops_json(array['33333333-0000-0000-0000-000000000001'::uuid, (select id from nr)]));
select t.expect_eq((select count(*) from public.service_departures where service_id = (select id from s500)), 4::bigint, 'se sumo una salida');

-- validaciones
select t.expect_fail($q$select public.save_service(null, '501', true, '[]'::jsonb, '[]'::jsonb)$q$, 'DEPARTURES_REQUIRED');
select t.expect_fail($q$select public.save_service(null, '501', true,
  '[{"route_id":"33333333-0000-0000-0000-000000000001","time":"06:00","day_types":["weekday"]},{"route_id":"33333333-0000-0000-0000-000000000001","time":"06:00","day_types":["weekday"]}]'::jsonb,
  t.stops_json(array['33333333-0000-0000-0000-000000000001'::uuid]))$q$, 'DEPARTURE_DUPLICATED');
select t.expect_fail($q$select public.save_service(null, '501', true,
  '[{"route_id":"33333333-0000-0000-0000-000000000001","time":"06:00","day_types":["bogus"]}]'::jsonb,
  t.stops_json(array['33333333-0000-0000-0000-000000000001'::uuid]))$q$, 'DAYS_INVALID');
select t.expect_fail($q$select public.save_service(null, '501', true,
  '[{"route_id":"33333333-0000-0000-0000-000000000001","time":"","day_types":["weekday"]}]'::jsonb,
  t.stops_json(array['33333333-0000-0000-0000-000000000001'::uuid]))$q$, 'TIME_REQUIRED');
select t.expect_fail(format($q$select public.save_service(null, '501', true,
  '[{"route_id":"%s","time":"06:00","day_types":["weekday"]}]'::jsonb, '[]'::jsonb)$q$, (select id from nrc)), 'ROUTE_INVALID');
select t.expect_fail($q$select public.save_service(null, '501', true,
  '[{"route_id":"33333333-0000-0000-0000-000000000001","time":"06:00","day_types":["weekday"]}]'::jsonb, '[]'::jsonb)$q$, 'STOPS_MISMATCH');
select t.expect_fail($q$select public.save_service(null, '501', true,
  '[{"route_id":"33333333-0000-0000-0000-000000000001","time":"06:00","day_types":["weekday"]}]'::jsonb,
  t.stops_json(array['33333333-0000-0000-0000-000000000001'::uuid], 5))$q$, 'TIMES_INVALID');
-- faltan los tiempos del sentido de vuelta
select t.expect_fail(format($q$select public.save_service(null, '501', true,
  '[{"route_id":"33333333-0000-0000-0000-000000000001","time":"06:00","day_types":["weekday"]},{"route_id":"%s","time":"07:00","day_types":["weekday"]}]'::jsonb,
  t.stops_json(array['33333333-0000-0000-0000-000000000001'::uuid]))$q$, (select id from nr)), 'STOPS_MISMATCH');
-- un servicio no se crea por insercion directa
select t.expect_fail($q$insert into public.services (company_id, code) values ('aaaaaaaa-0000-0000-0000-000000000001', '502')$q$, 'row-level security');
-- editar solo los tiempos de un servicio que ya tiene viajes
select public.save_service((select id from public.services where code = '214'), '214', true,
  t.deps((select id from public.services where code = '214')),
  (select jsonb_agg(case when e ->> 'route_stop_id' = '44444444-0000-0000-0000-000000000003' then e || '{"minutes_from_start":110}'::jsonb else e end)
     from jsonb_array_elements(t.stops_json(array['33333333-0000-0000-0000-000000000001'::uuid])) e));
select t.expect_eq((select minutes_from_start from public.service_stops
  where service_id = (select id from public.services where code = '214') and route_stop_id = '44444444-0000-0000-0000-000000000003'), 110, 'tiempos actualizados');
select t.logout();

-- ---- 4. otra empresa no ve nada; conductor no guarda
select t.login('b1000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*) from public.service_departures), 0::bigint, 'B no ve salidas de A');
select t.expect_fail($q$select public.save_service((select id from public.services limit 1), 'x', true, '[]'::jsonb, '[]'::jsonb)$q$, 'DEPARTURES_REQUIRED');
select t.logout();
select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_fail($q$select public.save_service(null, '9', true, '[]'::jsonb, '[]'::jsonb)$q$, 'FORBIDDEN');
select t.logout();

\echo 'PRUEBAS DE CATALOGO PASARON'
