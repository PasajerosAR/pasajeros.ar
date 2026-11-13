\set ON_ERROR_STOP on

select t.login('f0000000-0000-0000-0000-000000000001');
select public.save_route_maneuvers(
  '33333333-0000-0000-0000-000000000001',
  '[{"lat":-31.7,"lng":-60.5,"type":"turn","modifier":"left","name":"Calle Mitre","exit":null}]'::jsonb
);
select t.expect_eq(
  (select jsonb_array_length(maneuvers) from public.routes where id = '33333333-0000-0000-0000-000000000001'),
  1,
  'guarda las indicaciones del recorrido'
);
select t.expect_fail(
  $q$select public.save_route_maneuvers('33333333-0000-0000-0000-000000000001', '[{"lat":100,"lng":-60.5,"type":"turn","modifier":"left","name":"Calle","exit":null}]'::jsonb)$q$,
  'PATH_INVALID'
);
select public.save_route_maneuvers('33333333-0000-0000-0000-000000000001', null);
select t.expect_eq(
  (select maneuvers is null from public.routes where id = '33333333-0000-0000-0000-000000000001'),
  true,
  'permite limpiar las indicaciones'
);
select t.logout();

select t.login('a2000000-0000-0000-0000-000000000001');
select t.expect_fail(
  $q$select public.save_route_maneuvers('33333333-0000-0000-0000-000000000001', '[]'::jsonb)$q$,
  'FORBIDDEN'
);
select t.logout();

\echo 'PRUEBAS DE INDICACIONES DE GIRO PASARON'
