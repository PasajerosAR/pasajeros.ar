-- Pruebas de eliminacion segura y reasignacion de disposiciones.
\set ON_ERROR_STOP on
select t.login('a1000000-0000-0000-0000-000000000001');

-- Una disposición asignada a una unidad requiere un reemplazo.
create temp table delete_source as
select public.save_layout(null, 'Eliminar libre',
  '[{"floor":1,"rows":1,"cols":1}]'::jsonb,
  '[{"floor":1,"row_idx":0,"col_idx":0,"kind":"seat","label":"1","seat_class":"Semicama"}]'::jsonb) as id;
grant all on delete_source to authenticated;
insert into public.vehicles (company_id, kind, internal_number, plate, layout_id)
values ('aaaaaaaa-0000-0000-0000-000000000001', 'combi', 'DEL-01', 'ZZ001AA', (select id from delete_source));
select t.expect_fail($q$select public.delete_seat_layout((select id from delete_source), null, false)$q$, 'REPLACEMENT_REQUIRED');

create temp table delete_target as
select public.save_layout(null, 'Nueva libre',
  '[{"floor":1,"rows":1,"cols":1}]'::jsonb,
  '[{"floor":1,"row_idx":0,"col_idx":0,"kind":"seat","label":"1","seat_class":"Cama"}]'::jsonb) as id;
grant all on delete_target to authenticated;
create temp table delete_result as
select public.delete_seat_layout((select id from delete_source), (select id from delete_target), false) as result;
grant all on delete_result to authenticated;
select t.expect_eq((select result ->> 'deleted' from delete_result), 'true', 'elimina una disposición reasignada');
select t.expect_eq((select result ->> 'reassigned_vehicles' from delete_result), '1', 'reasigna todas las unidades');
select t.expect_eq((select layout_id from public.vehicles where internal_number = 'DEL-01'), (select id from delete_target), 'unidad conserva una disposición');
select t.expect_eq((select count(*) from public.seat_layouts where id = (select id from delete_source)), 0::bigint, 'se elimina disposición libre');

-- La opción de copia crea un reemplazo con la categoría y el plano originales.
create temp table copy_source as
select public.save_layout(null, 'Copiar disposición',
  '[{"floor":1,"rows":1,"cols":1}]'::jsonb,
  '[{"floor":1,"row_idx":0,"col_idx":0,"kind":"seat","label":"A","seat_class":"Cama premium"}]'::jsonb) as id;
grant all on copy_source to authenticated;
insert into public.vehicles (company_id, kind, internal_number, plate, layout_id)
values ('aaaaaaaa-0000-0000-0000-000000000001', 'colectivo', 'DEL-02', 'ZZ002AA', (select id from copy_source));
create temp table copy_result as
select public.delete_seat_layout((select id from copy_source), null, true) as result;
grant all on copy_result to authenticated;
select t.expect_eq((select result ->> 'deleted' from copy_result), 'true', 'elimina tras crear una copia');
select t.expect_eq((select layout_id from public.vehicles where internal_number = 'DEL-02'),
                   ((select result ->> 'replacement_id' from copy_result)::uuid), 'reasigna a la copia creada');
select t.expect_eq((select seat_class from public.layout_cells where layout_id =
                   ((select result ->> 'replacement_id' from copy_result)::uuid)), 'Cama premium', 'la copia conserva la categoría');

-- Un viaje terminado conserva su foto de asientos aunque se reasigne la flota actual.
create temp table history_target as
select public.save_layout(null, 'Reemplazo histórico',
  '[{"floor":1,"rows":1,"cols":1}]'::jsonb,
  '[{"floor":1,"row_idx":0,"col_idx":0,"kind":"seat","label":"1"}]'::jsonb) as id;
grant all on history_target to authenticated;
create temp table history_result as
select public.delete_seat_layout(
  '11111111-0000-0000-0000-000000000001',
  (select id from history_target), false
) as result;
grant all on history_result to authenticated;
select t.expect_eq((select result ->> 'deleted' from history_result), 'false', 'conserva disposición histórica');
select t.expect_eq((select result ->> 'retained_for_history' from history_result), 'true', 'marca conservación por historial');
select t.expect_eq((select layout_id from public.vehicles where id = '22222222-0000-0000-0000-000000000001'),
                   (select id from history_target), 'reasigna la unidad actual');
select t.expect_eq((select layout_id from public.trips limit 1),
                   '11111111-0000-0000-0000-000000000001'::uuid, 'viaje conserva su disposición original');

select t.logout();
select t.login('b1000000-0000-0000-0000-000000000001');
select t.expect_fail($q$select public.delete_seat_layout((select id from history_target), null, false)$q$, 'NOT_FOUND');
select t.logout();
\echo 'PRUEBAS DE ELIMINACIÓN DE DISPOSICIONES PASARON'
