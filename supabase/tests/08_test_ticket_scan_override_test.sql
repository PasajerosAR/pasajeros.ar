\set ON_ERROR_STOP on

update public.route_stops
   set lat = case position when 1 then -31.730000 when 2 then -31.700000 when 3 then -31.630000 end,
       lng = case position when 1 then -60.520000 when 2 then -60.450000 when 3 then -60.700000 end
 where route_id = '33333333-0000-0000-0000-000000000001';

insert into public.trips (
  id, company_id, service_id, departure_id, service_date, scheduled_departure,
  day_type, vehicle_id, driver_id, status, started_at
)
select
  '55555555-0000-0000-0000-000000000012',
  'aaaaaaaa-0000-0000-0000-000000000001',
  s.id,
  d.id,
  date '2099-01-01',
  now(),
  'weekday',
  '22222222-0000-0000-0000-000000000001',
  'a2000000-0000-0000-0000-000000000001',
  'in_progress',
  now()
from public.services s
join public.service_departures d on d.service_id = s.id
where s.company_id = 'aaaaaaaa-0000-0000-0000-000000000001'
  and s.code = '214'
  and d.route_id = '33333333-0000-0000-0000-000000000001'
limit 1;

insert into auth.users (id, email)
values ('b2000000-0000-0000-0000-000000000001', 'chofer.b@test');
insert into public.profiles (id, company_id, role, full_name)
values ('b2000000-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000001', 'driver', 'Chofer B');

select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_eq(public.create_test_tickets('55555555-0000-0000-0000-000000000012', 8), 8, 'crea solo pasajes de prueba');
select t.expect_eq(public.create_test_tickets('55555555-0000-0000-0000-000000000012', 8), 8, 'no duplica el lote de prueba');

create temp table ticket_codes as
select
  max(code) filter (where passenger_name = 'Pasajero de prueba 1') as first_code,
  max(code) filter (where passenger_name = 'Pasajero de prueba 2') as second_code,
  max(code) filter (where passenger_name = 'Pasajero de prueba 3') as third_code,
  max(code) filter (where passenger_name = 'Pasajero de prueba 8') as cancelled_code
from public.tickets
where trip_id = '55555555-0000-0000-0000-000000000012';
grant all on ticket_codes to authenticated;

select t.expect_eq((select count(*) from public.tickets where trip_id = '55555555-0000-0000-0000-000000000012'), 8::bigint, 'el conductor ve sus pasajes de prueba');
select t.expect_eq((select bool_and(is_test) from public.tickets where trip_id = '55555555-0000-0000-0000-000000000012'), true, 'todos los pasajes son de prueba');
select t.expect_eq((select count(*) from public.tickets where trip_id = '55555555-0000-0000-0000-000000000012' and status = 'cancelled'), 1::bigint, 'genera un QR anulado de prueba');
select t.expect_fail($q$insert into public.tickets (company_id, trip_id, code, passenger_name, boarding_stop_id, alighting_stop_id)
  values ('aaaaaaaa-0000-0000-0000-000000000001', '55555555-0000-0000-0000-000000000012', 'MANUAL-TEST', 'X',
    '44444444-0000-0000-0000-000000000001', '44444444-0000-0000-0000-000000000003')$q$, 'permission denied');
select t.expect_fail($q$select public._commit_test_ticket_boarding(
  '55555555-0000-0000-0000-000000000012', 'TEST-12345678', gen_random_uuid(), true,
  '44444444-0000-0000-0000-000000000002', -31.7, -60.45, 5, now())$q$, 'permission denied');
select t.expect_fail($q$select public.scan_ticket(
  '55555555-0000-0000-0000-000000000012', 'TEST-12345678',
  '44444444-0000-0000-0000-000000000002', gen_random_uuid())$q$, 'permission denied');

select t.expect_eq((public.scan_ticket(
  '55555555-0000-0000-0000-000000000012', 'TEST-12345678', gen_random_uuid(),
  null, null, null, now()
) ->> 'code'), 'GPS_REQUIRED', 'bloquea un escaneo sin GPS');
select t.expect_eq((public.scan_ticket(
  '55555555-0000-0000-0000-000000000012', 'TEST-12345678', gen_random_uuid(),
  -31.7, -60.45, 5, now() - interval '16 seconds'
) ->> 'code'), 'GPS_REQUIRED', 'bloquea una ubicacion GPS antigua');
select t.expect_eq((public.scan_ticket(
  '55555555-0000-0000-0000-000000000012', 'TEST-12345678', gen_random_uuid(),
  -31.7, -60.45, 51, now()
) ->> 'code'), 'GPS_REQUIRED', 'bloquea una precision GPS insuficiente');
select t.expect_eq((public.scan_ticket(
  '55555555-0000-0000-0000-000000000012', 'TEST-12345678', gen_random_uuid(),
  'NaN'::double precision, -60.45, 5, now()
) ->> 'code'), 'GPS_REQUIRED', 'bloquea coordenadas GPS no finitas');
select t.expect_eq((public.scan_ticket(
  '55555555-0000-0000-0000-000000000012', 'TEST-12345678', gen_random_uuid(),
  -31.8, -60.8, 5, now()
) ->> 'code'), 'GPS_NOT_AT_STOP', 'bloquea ubicacion alejada de las paradas');
select t.expect_fail($q$select public.override_ticket_boarding(
  '55555555-0000-0000-0000-000000000012', 'TEST-12345678', null,
  gen_random_uuid(), -31.7, -60.45, 5, now())$q$, 'OVERRIDE_STOP_REQUIRED');

select t.logout();
update public.route_stops
   set lat = -31.700000, lng = -60.450000
 where id = '44444444-0000-0000-0000-000000000001';
select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_eq((public.scan_ticket(
  '55555555-0000-0000-0000-000000000012', 'TEST-12345678', gen_random_uuid(),
  -31.7, -60.45, 5, now()
) ->> 'code'), 'GPS_STOP_AMBIGUOUS', 'bloquea coordenadas ambiguas entre paradas');
select t.logout();
update public.route_stops
   set lat = -31.730000, lng = -60.520000
 where id = '44444444-0000-0000-0000-000000000001';
select t.login('a2000000-0000-0000-0000-000000000001');
select t.logout();
update public.route_stops set lat = null
 where id = '44444444-0000-0000-0000-000000000003';
select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_eq((public.scan_ticket(
  '55555555-0000-0000-0000-000000000012', 'TEST-12345678', gen_random_uuid(),
  -31.7, -60.45, 5, now()
) ->> 'code'), 'GPS_STOPS_UNCONFIGURED', 'bloquea recorridos sin coordenadas completas');
select t.logout();
update public.route_stops set lat = -31.630000
 where id = '44444444-0000-0000-0000-000000000003';
select t.login('a2000000-0000-0000-0000-000000000001');

create temp table mismatch_result as
select public.scan_ticket(
  '55555555-0000-0000-0000-000000000012',
  (select first_code from ticket_codes),
  '66666666-0000-0000-0000-000000000001',
  -31.7, -60.45, 5, now()
) as result;
grant all on mismatch_result to authenticated;
select t.expect_eq((select result ->> 'code' from mismatch_result), 'BOARDING_STOP_MISMATCH', 'detecta otra parada de ascenso');
select t.expect_eq((select result ->> 'can_override' from mismatch_result), 'true', 'el servidor permite pedir autorizacion');
select t.expect_eq(public.trip_onboard('55555555-0000-0000-0000-000000000012'), 0, 'el conflicto no cuenta un ascenso');
select t.expect_eq((public.override_ticket_boarding(
  '55555555-0000-0000-0000-000000000012',
  (select first_code from ticket_codes),
  '44444444-0000-0000-0000-000000000001',
  '66666666-0000-0000-0000-000000000001',
  -31.7, -60.45, 5, now()
) ->> 'code'), 'GPS_STOP_CHANGED', 'rechaza una parada elegida que no coincide con el GPS');

create temp table override_result as
select public.override_ticket_boarding(
  '55555555-0000-0000-0000-000000000012',
  (select first_code from ticket_codes),
  '44444444-0000-0000-0000-000000000002',
  '66666666-0000-0000-0000-000000000001',
  -31.7, -60.45, 5, now()
) as result;
grant all on override_result to authenticated;
select t.expect_eq((select result ->> 'ok' from override_result), 'true', 'autoriza y registra el ascenso');
select t.expect_eq((select result ->> 'boarding_override' from override_result), 'true', 'la respuesta identifica la autorizacion');
select t.expect_eq(public.trip_onboard('55555555-0000-0000-0000-000000000012'), 1, 'el ascenso autorizado suma una sola persona');
select t.expect_eq((select boarding_override from public.tickets where code = (select first_code from ticket_codes)), true, 'el pasaje conserva la marca de autorizacion');
select t.expect_eq((select actual_boarding_stop_id::text from public.tickets where code = (select first_code from ticket_codes)), '44444444-0000-0000-0000-000000000002', 'conserva la parada real');
select t.expect_eq((select planned_boarding_stop_id::text from public.ticket_boarding_events where ticket_id = (select id from public.tickets where code = (select first_code from ticket_codes))), '44444444-0000-0000-0000-000000000001', 'conserva la parada comprada en la auditoria');
select t.expect_eq((select driver_id::text from public.ticket_boarding_events where ticket_id = (select id from public.tickets where code = (select first_code from ticket_codes))), auth.uid()::text, 'audita al conductor');
select t.expect_eq((select was_overridden from public.ticket_boarding_events where ticket_id = (select id from public.tickets where code = (select first_code from ticket_codes))), true, 'audita que se autorizo');
select t.expect_eq((public.override_ticket_boarding(
  '55555555-0000-0000-0000-000000000012',
  (select first_code from ticket_codes),
  '44444444-0000-0000-0000-000000000002',
 '66666666-0000-0000-0000-000000000001',
 -31.7, -60.45, 5, now()
) ->> 'ok'), 'true', 'reintento con el mismo evento es idempotente');
select t.expect_eq(public.trip_onboard('55555555-0000-0000-0000-000000000012'), 1, 'el reintento no duplica el ascenso');
select t.expect_eq((public.scan_ticket(
  '55555555-0000-0000-0000-000000000012',
  (select first_code from ticket_codes),
  '66666666-0000-0000-0000-000000000002',
  -31.7, -60.45, 5, now()
 ) ->> 'code'), 'ALREADY_BOARDED', 'el QR no se puede volver a utilizar');

select t.expect_eq((public.override_ticket_boarding(
  '55555555-0000-0000-0000-000000000012',
  (select second_code from ticket_codes),
  '44444444-0000-0000-0000-000000000002',
  '66666666-0000-0000-0000-000000000007',
  -31.7, -60.45, 5, now()
) ->> 'code'), 'OVERRIDE_NOT_NEEDED', 'no autoriza si coincide la parada');

select t.expect_eq((public.scan_ticket(
  '55555555-0000-0000-0000-000000000012',
  (select second_code from ticket_codes),
  '66666666-0000-0000-0000-000000000003',
  -31.7, -60.45, 5, now()
) ->> 'ok'), 'true', 'acepta el ascenso en la parada indicada');
select t.expect_eq((public.scan_ticket(
  '55555555-0000-0000-0000-000000000012',
  (select third_code from ticket_codes),
  '66666666-0000-0000-0000-000000000004',
  -31.63, -60.7, 5, now()
) ->> 'code'), 'PAST_ALIGHTING_STOP', 'rechaza ascenso al llegar al descenso');
select t.expect_eq((public.override_ticket_boarding(
  '55555555-0000-0000-0000-000000000012',
  (select third_code from ticket_codes),
  '44444444-0000-0000-0000-000000000003',
  '66666666-0000-0000-0000-000000000008',
  -31.63, -60.7, 5, now()
) ->> 'code'), 'PAST_ALIGHTING_STOP', 'la autorizacion no supera la parada de descenso');
select t.expect_eq((public.override_ticket_boarding(
  '55555555-0000-0000-0000-000000000012',
  (select cancelled_code from ticket_codes),
  '44444444-0000-0000-0000-000000000002',
  '66666666-0000-0000-0000-000000000005',
  -31.7, -60.45, 5, now()
) ->> 'code'), 'CANCELLED', 'no permite autorizar pasajes anulados');
select t.expect_eq((public.scan_ticket(
  '55555555-0000-0000-0000-000000000012', 'NOT-A-REAL-TICKET',
  '66666666-0000-0000-0000-000000000006', -31.7, -60.45, 5, now()
) ->> 'code'), 'INVALID_TICKET', 'rechaza codigos desconocidos');

select t.logout();
select t.login('b2000000-0000-0000-0000-000000000001');
select t.expect_fail(format(
  $q$select public.scan_ticket(%L, %L, gen_random_uuid(), -31.7, -60.45, 5, now())$q$,
  '55555555-0000-0000-0000-000000000012',
  (select first_code from ticket_codes)
), 'NOT_FOUND');
select t.logout();
select t.login('a2000000-0000-0000-0000-000000000001');
select public.end_trip('55555555-0000-0000-0000-000000000012', true);
select t.logout();

\echo 'PRUEBAS DE QR DE PRUEBA Y AUTORIZACION DE ASCENSO PASARON'
