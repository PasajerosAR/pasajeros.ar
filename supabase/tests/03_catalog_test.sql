-- Catalogo de recorridos, tiempos por servicio y administrador general (despues de 01 y 02).
\set ON_ERROR_STOP on

-- ---- 1. alta de empresa y catalogo: solo administrador general
select t.login('f0000000-0000-0000-0000-000000000001');
create temp table nc as select public.create_company('Empresa C') as id;
grant all on nc to authenticated;
select t.expect_eq((select count(*) from public.companies where name = 'Empresa C'), 1::bigint, 'plataforma crea empresa');
select t.expect_fail($q$select public.create_company('  ')$q$, 'NAME_REQUIRED');
create temp table nr as select public.save_route(null, 'Parana - Oro Verde', true,
  '[{"name":"Parana","lat":-31.73,"lng":-60.52},{"name":"Oro Verde"}]'::jsonb) as id;
grant all on nr to authenticated;
select t.expect_eq((select count(*) from public.route_stops where route_id = (select id from nr)), 2::bigint, 'dos paradas');
select t.expect_eq((select position from public.route_stops where route_id = (select id from nr) and name = 'Oro Verde'), 2, 'posiciones en orden');
select public.save_route((select id from nr), 'Parana - Oro Verde', true,
  '[{"name":"Parana"},{"name":"Colonia"},{"name":"Oro Verde"}]'::jsonb);
select t.expect_eq((select count(*) from public.route_stops where route_id = (select id from nr)), 3::bigint, 'tres paradas tras editar (sin servicios)');
select t.expect_fail($q$select public.save_route(null, 'Corto', true, '[{"name":"Solo una"}]'::jsonb)$q$, 'STOPS_REQUIRED');
-- recorrido en uso: solo correcciones, misma cantidad de paradas
select t.expect_fail($q$select public.save_route('33333333-0000-0000-0000-000000000001', 'Parana - Santa Fe', true,
  '[{"name":"A"},{"name":"B"}]'::jsonb)$q$, 'ROUTE_IN_USE');
select public.save_route('33333333-0000-0000-0000-000000000001', 'Parana - Santa Fe', true,
  '[{"name":"Parana"},{"name":"Colonia Avellaneda"},{"name":"Santa Fe Terminal"}]'::jsonb);
select t.expect_eq((select name from public.route_stops where id = '44444444-0000-0000-0000-000000000003'), 'Santa Fe Terminal', 'correccion conserva el id de la parada');
-- la plataforma no ve datos de empresas
select t.expect_eq((select count(*) from public.vehicles), 0::bigint, 'plataforma no ve vehiculos');
select t.expect_eq((select count(*) from public.services), 0::bigint, 'plataforma no ve servicios');
select t.expect_eq((select count(*) from public.trips), 0::bigint, 'plataforma no ve viajes');
select t.logout();

-- ---- 2. las empresas leen el catalogo pero no lo editan
select t.login('b1000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*) from public.routes), 2::bigint, 'empresa B lee el catalogo');
select t.expect_fail($q$select public.save_route(null, 'X', true, '[{"name":"a"},{"name":"b"}]'::jsonb)$q$, 'FORBIDDEN');
select t.expect_fail($q$select public.create_company('X')$q$, 'FORBIDDEN');
update public.route_stops set name = 'hack';
select t.expect_eq((select count(*) from public.route_stops where name = 'hack'), 0::bigint, 'RLS: no edita paradas');
select t.expect_eq((select count(*) from public.service_stops), 0::bigint, 'B no ve tiempos de A');
select t.logout();

-- ---- 3. save_service: validaciones
select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*) from public.service_stops), 6::bigint, 'A ve los tiempos de sus 2 servicios');
select t.expect_fail($q$select public.save_service(null, '300', '33333333-0000-0000-0000-000000000001', '10:00', array[1], true,
  '[{"route_stop_id":"44444444-0000-0000-0000-000000000001","minutes_from_start":0}]'::jsonb)$q$, 'STOPS_MISMATCH');
select t.expect_fail($q$select public.save_service(null, '300', '33333333-0000-0000-0000-000000000001', '10:00', array[1], true,
  '[{"route_stop_id":"44444444-0000-0000-0000-000000000001","minutes_from_start":5},
    {"route_stop_id":"44444444-0000-0000-0000-000000000002","minutes_from_start":20},
    {"route_stop_id":"44444444-0000-0000-0000-000000000003","minutes_from_start":100}]'::jsonb)$q$, 'TIMES_INVALID');
select t.expect_fail($q$select public.save_service(null, '300', '33333333-0000-0000-0000-000000000001', '10:00', array[1], true,
  '[{"route_stop_id":"44444444-0000-0000-0000-000000000001","minutes_from_start":0},
    {"route_stop_id":"44444444-0000-0000-0000-000000000002","minutes_from_start":50},
    {"route_stop_id":"44444444-0000-0000-0000-000000000003","minutes_from_start":40}]'::jsonb)$q$, 'TIMES_INVALID');
select t.expect_fail($q$select public.save_service(null, '300', '33333333-0000-0000-0000-000000000001', '10:00', array[8], true, '[]'::jsonb)$q$, 'DAYS_INVALID');
select t.expect_fail($q$select public.save_service(null, '300', '99999999-0000-0000-0000-000000000001', '10:00', array[1], true, '[]'::jsonb)$q$, 'ROUTE_INVALID');
-- no se puede insertar un servicio directo (sin tiempos)
select t.expect_fail($q$insert into public.services (company_id, code, route_id, departure_time)
  values ('aaaaaaaa-0000-0000-0000-000000000001', '301', '33333333-0000-0000-0000-000000000001', '11:00')$q$, 'row-level security');
-- editar tiempos de un servicio con viajes
select public.save_service((select id from public.services where code = '214'), '214', '33333333-0000-0000-0000-000000000001', '18:00', array[1,2,3,4,5,6,7], true,
  '[{"route_stop_id":"44444444-0000-0000-0000-000000000001","minutes_from_start":0},
    {"route_stop_id":"44444444-0000-0000-0000-000000000002","minutes_from_start":25},
    {"route_stop_id":"44444444-0000-0000-0000-000000000003","minutes_from_start":110}]'::jsonb);
select t.expect_eq((select minutes_from_start from public.service_stops
  where service_id = (select id from public.services where code = '214') and route_stop_id = '44444444-0000-0000-0000-000000000003'), 110, 'tiempos actualizados');
-- con viajes, no cambia de recorrido
select t.expect_fail($q$select public.save_service((select id from public.services where code = '214'), '214', (select id from public.routes where name = 'Parana - Oro Verde'), '18:00', array[1], true,
  '[]'::jsonb)$q$, 'STOPS_MISMATCH');
select t.logout();

-- ---- 4. conductor no guarda servicios
select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_fail($q$select public.save_service(null, '9', '33333333-0000-0000-0000-000000000001', '10:00', array[1], true, '[]'::jsonb)$q$, 'FORBIDDEN');
select t.logout();

\echo 'PRUEBAS DE CATALOGO PASARON'
