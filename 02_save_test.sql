-- Pruebas de save_layout y save_route (se ejecuta despues de 01_core_test.sql, que deja datos y el schema t).
\set ON_ERROR_STOP on

select t.login('a1000000-0000-0000-0000-000000000001');

-- 1. disposicion nueva, atomica
create temp table nl as select public.save_layout(
  null, 'Combi 2',
  '[{"floor":1,"rows":2,"cols":3}]'::jsonb,
  '[{"floor":1,"row_idx":0,"col_idx":0,"kind":"seat","label":"1"},
    {"floor":1,"row_idx":0,"col_idx":1,"kind":"aisle"},
    {"floor":1,"row_idx":0,"col_idx":2,"kind":"seat","label":"2","accessible":true},
    {"floor":1,"row_idx":1,"col_idx":0,"kind":"driver"}]'::jsonb) as id;
grant all on nl to authenticated;
select t.expect_eq((select seats from public.seat_layout_capacity where layout_id = (select id from nl)), 2::bigint, 'save_layout nueva: capacidad');
select t.expect_eq((select count(*) from public.layout_cells where layout_id = (select id from nl)), 4::bigint, 'save_layout nueva: celdas');

-- 2. editar una no usada: se reemplaza en el mismo registro
select t.expect_eq(public.save_layout((select id from nl), 'Combi 2 b',
  '[{"floor":1,"rows":1,"cols":2}]'::jsonb,
  '[{"floor":1,"row_idx":0,"col_idx":0,"kind":"seat","label":"1"},{"floor":1,"row_idx":0,"col_idx":1,"kind":"seat","label":"2"}]'::jsonb),
  (select id from nl), 'editar una no usada conserva el id');
select t.expect_eq((select name from public.seat_layouts where id = (select id from nl)), 'Combi 2 b', 'nombre actualizado');
select t.expect_eq((select count(*) from public.layout_cells where layout_id = (select id from nl)), 2::bigint, 'celdas reemplazadas');

-- 3. editar una en uso crea la version siguiente y no toca la original
create temp table nv as select public.save_layout('11111111-0000-0000-0000-000000000001', 'Combi 4',
  '[{"floor":1,"rows":1,"cols":2}]'::jsonb,
  '[{"floor":1,"row_idx":0,"col_idx":0,"kind":"seat","label":"A"},{"floor":1,"row_idx":0,"col_idx":1,"kind":"seat","label":"B"}]'::jsonb) as id;
grant all on nv to authenticated;
select t.expect_eq((select id <> '11111111-0000-0000-0000-000000000001'::uuid from nv), true, 'version nueva con otro id');
select t.expect_eq((select version from public.seat_layouts where id = (select id from nv)), 3, 'siguiente version (la 2 ya existia por la prueba anterior)');
select t.expect_eq((select count(*) from public.layout_cells where layout_id = '11111111-0000-0000-0000-000000000001'), 5::bigint, 'la original queda intacta');

-- 4. validaciones
select t.expect_fail($q$select public.save_layout(null, '  ', '[{"floor":1,"rows":1,"cols":1}]'::jsonb, '[]'::jsonb)$q$, 'NAME_REQUIRED');
select t.expect_fail($q$select public.save_layout(null, 'X', '[]'::jsonb, '[]'::jsonb)$q$, 'INVALID_FLOORS');
select t.expect_fail($q$select public.save_layout(null, 'X', '[{"floor":1,"rows":1,"cols":1}]'::jsonb,
  '[{"floor":1,"row_idx":0,"col_idx":0,"kind":"aisle","label":"9"}]'::jsonb)$q$, 'cell_flags_only_seats');
select t.expect_fail($q$select public.save_layout('22222222-0000-0000-0000-000000000099', 'X', '[{"floor":1,"rows":1,"cols":1}]'::jsonb, '[]'::jsonb)$q$, 'NOT_FOUND');

-- 5. (recorridos: ver 03_catalog_test.sql)
select t.logout();

-- 6. un conductor y otra empresa no pueden guardar
select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_fail($q$select public.save_layout(null, 'X', '[{"floor":1,"rows":1,"cols":1}]'::jsonb, '[]'::jsonb)$q$, 'FORBIDDEN');
select t.logout();
select t.login('b1000000-0000-0000-0000-000000000001');
select t.expect_fail($q$select public.save_layout((select id from nl), 'Robo', '[{"floor":1,"rows":1,"cols":1}]'::jsonb, '[]'::jsonb)$q$, 'NOT_FOUND');
select t.logout();

\echo 'PRUEBAS DE GUARDADO PASARON'
