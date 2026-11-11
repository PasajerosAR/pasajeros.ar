-- Guardado atomico de disposiciones y recorridos (todo o nada).

-- Guarda una disposicion. p_layout = null crea una nueva. Si la disposicion esta en uso
-- (bloqueada) no se modifica: se crea la version siguiente y se guarda ahi. Devuelve el id guardado.
create function public.save_layout(p_layout uuid, p_name text, p_floors jsonb, p_cells jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := public.current_company_id();
  v_src     public.seat_layouts;
  v_id      uuid;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if p_name is null or length(trim(p_name)) = 0 then raise exception 'NAME_REQUIRED: falta el nombre de la disposición'; end if;
  if jsonb_typeof(p_floors) <> 'array' or jsonb_array_length(p_floors) not between 1 and 2 then
    raise exception 'INVALID_FLOORS';
  end if;
  if jsonb_typeof(p_cells) <> 'array' then raise exception 'INVALID_CELLS'; end if;

  if p_layout is null then
    insert into public.seat_layouts (company_id, name) values (v_company, trim(p_name)) returning id into v_id;
  else
    select * into v_src from public.seat_layouts where id = p_layout and company_id = v_company for update;
    if not found then raise exception 'NOT_FOUND'; end if;
    if v_src.locked_at is not null then
      insert into public.seat_layouts (company_id, group_id, version, name, is_template)
      values (v_company, v_src.group_id,
              (select max(version) + 1 from public.seat_layouts where group_id = v_src.group_id),
              trim(p_name), v_src.is_template)
      returning id into v_id;
    else
      v_id := v_src.id;
      update public.seat_layouts set name = trim(p_name) where id = v_id;
      delete from public.layout_cells  where layout_id = v_id;
      delete from public.layout_floors where layout_id = v_id;
    end if;
  end if;

  insert into public.layout_floors (layout_id, company_id, floor, rows, cols)
  select v_id, v_company, f.floor, f.rows, f.cols
  from jsonb_to_recordset(p_floors) as f(floor int, rows int, cols int);

  insert into public.layout_cells (layout_id, company_id, floor, row_idx, col_idx, kind, label, accessible, blocked, unusable)
  select v_id, v_company, c.floor, c.row_idx, c.col_idx, c.kind::public.cell_kind,
         nullif(trim(c.label), ''), coalesce(c.accessible, false), coalesce(c.blocked, false), coalesce(c.unusable, false)
  from jsonb_to_recordset(p_cells) as c(floor int, row_idx int, col_idx int, kind text, label text,
                                        accessible boolean, blocked boolean, unusable boolean);
  return v_id;
end $$;

-- Guarda un recorrido con sus paradas. p_route = null crea uno nuevo. Las paradas se reemplazan.
create function public.save_route(p_route uuid, p_name text, p_active boolean, p_stops jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := public.current_company_id();
  v_id      uuid;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  if p_name is null or length(trim(p_name)) = 0 then raise exception 'NAME_REQUIRED: falta el nombre del recorrido'; end if;
  if jsonb_typeof(p_stops) <> 'array' or jsonb_array_length(p_stops) < 2 then
    raise exception 'STOPS_REQUIRED: el recorrido necesita al menos origen y destino';
  end if;

  if p_route is null then
    insert into public.routes (company_id, name, active) values (v_company, trim(p_name), coalesce(p_active, true))
    returning id into v_id;
  else
    update public.routes set name = trim(p_name), active = coalesce(p_active, active)
     where id = p_route and company_id = v_company returning id into v_id;
    if v_id is null then raise exception 'NOT_FOUND'; end if;
    -- paradas ya usadas por contadores se conservan: solo se puede reescribir si no hay registros
    if exists (select 1 from public.passenger_counts pc join public.route_stops rs on rs.id = pc.stop_id
                where rs.route_id = v_id) then
      raise exception 'ROUTE_IN_USE: el recorrido tiene registros de pasajeros; cree uno nuevo en lugar de editar las paradas';
    end if;
    delete from public.route_stops where route_id = v_id;
  end if;

  insert into public.route_stops (company_id, route_id, position, name, minutes_from_start, dwell_minutes)
  select v_company, v_id, s.ord::int, trim(s.e ->> 'name'),
         coalesce((s.e ->> 'minutes_from_start')::int, 0), coalesce((s.e ->> 'dwell_minutes')::int, 0)
  from jsonb_array_elements(p_stops) with ordinality as s(e, ord);
  return v_id;
end $$;

revoke all on function public.save_layout(uuid, text, jsonb, jsonb), public.save_route(uuid, text, boolean, jsonb) from public, anon;
grant execute on function public.save_layout(uuid, text, jsonb, jsonb), public.save_route(uuid, text, boolean, jsonb) to authenticated;
