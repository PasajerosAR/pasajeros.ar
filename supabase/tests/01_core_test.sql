-- Pruebas de la fase 1. Cualquier fallo corta la ejecucion (ON_ERROR_STOP).
\set ON_ERROR_STOP on

create schema t;
grant usage on schema t to authenticated;

create function t.login(u uuid) returns void language plpgsql as $$
begin
  perform set_config('test.uid', u::text, false);
  execute 'set role authenticated';
end $$;

create function t.logout() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('test.uid', '', false);
end $$;

-- Ejecuta sql y exige que falle con un mensaje que contenga "pattern".
create function t.expect_fail(q text, pattern text) returns void language plpgsql as $$
declare ok boolean := false;
begin
  begin
    execute q;
  exception when others then
    if sqlerrm like '%' || pattern || '%' then ok := true;
    else raise exception 'fallo inesperado (%) para: %', sqlerrm, q;
    end if;
  end;
  if not ok then raise exception 'se esperaba un error con "%" para: %', pattern, q; end if;
end $$;

create function t.expect_eq(actual anyelement, expected anyelement, label text) returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FALLA [%]: esperado %, obtenido %', label, expected, actual;
  end if;
end $$;
grant execute on all functions in schema t to authenticated;

-- ---------------------------------------------------------------- datos base (como superusuario)
insert into public.companies (id, name) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Empresa A'),
  ('bbbbbbbb-0000-0000-0000-000000000001', 'Empresa B');

insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000001', 'admin.a@test'),
  ('a2000000-0000-0000-0000-000000000001', 'chofer.a@test'),
  ('a3000000-0000-0000-0000-000000000001', 'chofer2.a@test'),
  ('b1000000-0000-0000-0000-000000000001', 'admin.b@test'),
  ('f0000000-0000-0000-0000-000000000001', 'plataforma@test');

insert into public.profiles (id, company_id, role, full_name) values
  ('a1000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'company_admin', 'Admin A'),
  ('a2000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'driver', 'Chofer A'),
  ('a3000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'driver', 'Chofer A2'),
  ('b1000000-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', 'company_admin', 'Admin B');
insert into public.profiles (id, company_id, role, full_name)
  values ('f0000000-0000-0000-0000-000000000001', null, 'platform_admin', 'Plataforma');

-- ---------------------------------------------------------------- 1. aislamiento entre empresas
select t.login('a1000000-0000-0000-0000-000000000001');

insert into public.seat_layouts (id, company_id, name)
  values ('11111111-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'Combi 4');
insert into public.layout_floors (layout_id, company_id, floor, rows, cols)
  values ('11111111-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 1, 2, 3);
insert into public.layout_cells (layout_id, company_id, floor, row_idx, col_idx, kind, label) values
  ('11111111-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 1, 0, 0, 'seat', '1'),
  ('11111111-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 1, 0, 1, 'aisle', null),
  ('11111111-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 1, 0, 2, 'seat', '2'),
  ('11111111-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 1, 1, 0, 'seat', '3'),
  ('11111111-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 1, 1, 2, 'seat', '4');

select t.expect_eq((select seats from public.seat_layout_capacity where layout_id = '11111111-0000-0000-0000-000000000001'), 4::bigint, 'capacidad calculada');

insert into public.vehicles (id, company_id, kind, internal_number, plate, layout_id)
  values ('22222222-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'combi', '12', 'AA111AA', '11111111-0000-0000-0000-000000000001');

select t.expect_fail($q$insert into public.vehicles (company_id, kind, internal_number, plate)
  values ('bbbbbbbb-0000-0000-0000-000000000001', 'combi', '1', 'ZZ999ZZ')$q$, 'row-level security');

select t.logout();
insert into public.vehicles (id, company_id, kind, internal_number, plate)
  values ('22222222-0000-0000-0000-000000000099', 'bbbbbbbb-0000-0000-0000-000000000001', 'colectivo', '7', 'BB222BB');

select t.login('a1000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*) from public.vehicles), 1::bigint, 'admin A solo ve sus vehiculos');
select t.expect_eq((select count(*) from public.companies), 1::bigint, 'admin A solo ve su empresa');
select t.logout();

select t.login('b1000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*) from public.vehicles), 1::bigint, 'admin B solo ve sus vehiculos');
select t.expect_eq((select count(*) from public.seat_layouts), 0::bigint, 'admin B no ve disposiciones de A');
select t.logout();

-- ---------------------------------------------------------------- 2. recorridos, servicios y generacion de viajes
select t.login('a1000000-0000-0000-0000-000000000001');
select t.logout();
-- el catalogo lo carga el administrador general
select t.login('f0000000-0000-0000-0000-000000000001');
insert into public.routes (id, name) values ('33333333-0000-0000-0000-000000000001', 'Parana - Santa Fe');
insert into public.route_stops (id, route_id, position, name) values
  ('44444444-0000-0000-0000-000000000001', '33333333-0000-0000-0000-000000000001', 1, 'Parana'),
  ('44444444-0000-0000-0000-000000000002', '33333333-0000-0000-0000-000000000001', 2, 'Colonia Avellaneda'),
  ('44444444-0000-0000-0000-000000000003', '33333333-0000-0000-0000-000000000001', 3, 'Santa Fe');
select t.logout();
select t.login('a1000000-0000-0000-0000-000000000001');
select public.save_service(null, '214', '33333333-0000-0000-0000-000000000001', '18:00', array[1,2,3,4,5,6,7], true,
  '[{"route_stop_id":"44444444-0000-0000-0000-000000000001","minutes_from_start":0},
    {"route_stop_id":"44444444-0000-0000-0000-000000000002","minutes_from_start":20,"dwell_minutes":2},
    {"route_stop_id":"44444444-0000-0000-0000-000000000003","minutes_from_start":100}]'::jsonb);
select t.expect_eq(public.generate_trips(date '2026-11-14'), 1, 'genera 1 viaje');
select t.expect_eq(public.generate_trips(date '2026-11-14'), 0, 'generar es idempotente');
select t.expect_eq((select scheduled_departure from public.trips limit 1),
                   timestamptz '2026-11-14 18:00-03', 'hora programada en zona Argentina');
select t.logout();

-- ---------------------------------------------------------------- 3. viaje: asignacion, bloqueo de disposicion, inmutabilidad
select t.login('a1000000-0000-0000-0000-000000000001');
update public.trips set vehicle_id = '22222222-0000-0000-0000-000000000001',
                        driver_id = 'a2000000-0000-0000-0000-000000000001';
select t.expect_eq((select locked_at is not null from public.seat_layouts where id = '11111111-0000-0000-0000-000000000001'),
                   true, 'la disposicion se bloquea al asignar un vehiculo a un viaje');
select t.expect_fail($q$update public.layout_cells set label = '99' where layout_id = '11111111-0000-0000-0000-000000000001' and label = '1'$q$, 'LAYOUT_LOCKED');
select t.expect_fail($q$delete from public.layout_cells where layout_id = '11111111-0000-0000-0000-000000000001'$q$, 'LAYOUT_LOCKED');
select t.expect_fail($q$delete from public.seat_layouts where id = '11111111-0000-0000-0000-000000000001'$q$, 'LAYOUT_LOCKED');

-- nueva version editable
create temp table v2 as select public.clone_layout('11111111-0000-0000-0000-000000000001') as id;
grant all on v2 to authenticated;
select t.expect_eq((select version from public.seat_layouts where id = (select id from v2)), 2, 'version 2');
update public.layout_cells set label = '99' where layout_id = (select id from v2) and label = '1';
select t.expect_eq((select seats from public.seat_layout_capacity where layout_id = (select id from v2)), 4::bigint, 'la copia conserva la capacidad');
select t.expect_eq((select label from public.layout_cells where layout_id = '11111111-0000-0000-0000-000000000001' and col_idx = 0 and row_idx = 0), '1', 'la version original no cambia');

-- el admin no puede iniciar un viaje por update directo
select t.expect_fail($q$update public.trips set status = 'in_progress'$q$, 'USE_RPC');
-- vehiculo de otra empresa
select t.expect_fail($q$update public.trips set vehicle_id = '22222222-0000-0000-0000-000000000099'$q$, 'VEHICLE_OTHER_COMPANY');
select t.logout();

-- ---------------------------------------------------------------- 4. conductor: jornada, viaje y contador
select t.login('a3000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*) from public.trips), 0::bigint, 'otro conductor no ve viajes ajenos');
select t.logout();

select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_eq((select count(*) from public.trips), 1::bigint, 'el conductor ve su viaje');
select t.expect_fail($q$insert into public.vehicles (company_id, kind, internal_number, plate)
  values ('aaaaaaaa-0000-0000-0000-000000000001', 'combi', '55', 'CC333CC')$q$, 'row-level security');
select t.expect_fail($q$select public.start_trip((select id from public.trips limit 1))$q$, 'NO_OPEN_SHIFT');

select public.start_shift();
select t.expect_eq((select count(*) from public.shifts where ended_at is null), 1::bigint, 'jornada abierta');
select public.start_shift();  -- idempotente
select t.expect_eq((select count(*) from public.shifts), 1::bigint, 'no se duplica la jornada');

select t.expect_fail($q$select public.register_count((select id from public.trips limit 1), 'board', 3, null, gen_random_uuid())$q$, 'INVALID_STATE');

select public.start_trip((select id from public.trips limit 1));
select t.expect_eq((select status::text from public.trips limit 1), 'in_progress', 'viaje iniciado');
select t.expect_fail($q$select public.end_shift()$q$, 'TRIP_IN_PROGRESS');

create temp table ev as select gen_random_uuid() as id;
grant all on ev to authenticated;
select t.expect_eq((public.register_count((select id from public.trips limit 1), 'board', 3, '44444444-0000-0000-0000-000000000001', (select id from ev)) ->> 'onboard')::int, 3, 'suben 3');
select t.expect_eq((public.register_count((select id from public.trips limit 1), 'board', 3, '44444444-0000-0000-0000-000000000001', (select id from ev)) ->> 'onboard')::int, 3, 'evento repetido no suma otra vez');
select t.expect_eq((public.register_count((select id from public.trips limit 1), 'board', 2, null, gen_random_uuid()) ->> 'over_capacity')::boolean, true, 'avisa si supera la capacidad (5 > 4)');
select t.expect_fail($q$select public.register_count((select id from public.trips limit 1), 'alight', 6, null, gen_random_uuid())$q$, 'NEGATIVE_COUNT');
select t.expect_fail($q$select public.register_count((select id from public.trips limit 1), 'board', 0, null, gen_random_uuid())$q$, 'INVALID_QUANTITY');
select t.expect_fail($q$select public.register_count((select id from public.trips limit 1), 'board', 1, '44444444-0000-0000-0000-000000000009', gen_random_uuid())$q$, 'STOP_NOT_IN_ROUTE');
select t.expect_eq(public.trip_onboard((select id from public.trips limit 1)), 5, 'a bordo = 5');
select t.expect_fail($q$insert into public.passenger_counts (company_id, trip_id, kind, quantity, recorded_by, client_event_id)
  values ('aaaaaaaa-0000-0000-0000-000000000001', (select id from public.trips limit 1), 'board', 1, auth.uid(), gen_random_uuid())$q$, 'row-level security');

select t.expect_fail($q$select public.end_trip((select id from public.trips limit 1))$q$, 'ONBOARD_REMAINING');
select public.register_count((select id from public.trips limit 1), 'alight', 5, '44444444-0000-0000-0000-000000000003', gen_random_uuid());
select public.end_trip((select id from public.trips limit 1));
select t.expect_eq((select status::text from public.trips limit 1), 'completed', 'viaje finalizado');
select public.end_shift();
select t.expect_eq((select count(*) from public.shifts where ended_at is null), 0::bigint, 'jornada cerrada');
select t.logout();

-- ---------------------------------------------------------------- 5. inicio manual por admin con motivo
select t.login('a1000000-0000-0000-0000-000000000001');
select public.save_service(null, '216', '33333333-0000-0000-0000-000000000001', '19:00', array[1,2,3,4,5,6,7], true,
  '[{"route_stop_id":"44444444-0000-0000-0000-000000000001","minutes_from_start":0},
    {"route_stop_id":"44444444-0000-0000-0000-000000000002","minutes_from_start":20},
    {"route_stop_id":"44444444-0000-0000-0000-000000000003","minutes_from_start":100}]'::jsonb);
select t.expect_eq(public.generate_trips(date '2026-11-14'), 1, 'genera el servicio nuevo');
update public.trips set vehicle_id = '22222222-0000-0000-0000-000000000001' where service_id = (select id from public.services where code = '216');
select t.expect_fail($q$select public.admin_start_trip((select id from public.trips where service_id = (select id from public.services where code = '216')), '')$q$, 'REASON_REQUIRED');
select public.admin_start_trip((select id from public.trips where service_id = (select id from public.services where code = '216')), 'Chofer sin senal');
select t.expect_eq((select started_manually from public.trips where service_id = (select id from public.services where code = '216')), true, 'queda marcado como manual');
select t.expect_eq((select count(*) > 0 from public.audit_log where entity = 'trips' and action = 'update'), true, 'hay auditoria de viajes');
select t.logout();

-- ---------------------------------------------------------------- 6. el usuario no puede elevar su rol
select t.login('a2000000-0000-0000-0000-000000000001');
update public.profiles set role = 'company_admin' where id = auth.uid();  -- RLS: 0 filas afectadas, no error
select t.logout();
select t.expect_eq((select role::text from public.profiles where id = 'a2000000-0000-0000-0000-000000000001'), 'driver', 'el chofer sigue siendo chofer');

\echo 'TODAS LAS PRUEBAS DE LA FASE 1 PASARON'
