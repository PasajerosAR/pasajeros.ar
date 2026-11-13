-- Categorías por asiento para diferenciar, por ejemplo, semicama en planta alta
-- y cama/premium en planta baja. La cantidad de pisos ya está en layout_floors.
alter type public.vehicle_kind add value if not exists 'minibus';

alter table public.layout_cells
  add column seat_class text not null default 'Común'
  check (length(btrim(seat_class)) between 1 and 40);

create or replace function public.save_layout(p_layout uuid, p_name text, p_floors jsonb, p_cells jsonb) returns uuid
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
      delete from public.layout_cells where layout_id = v_id;
      delete from public.layout_floors where layout_id = v_id;
    end if;
  end if;

  insert into public.layout_floors (layout_id, company_id, floor, rows, cols)
  select v_id, v_company, f.floor, f.rows, f.cols
  from jsonb_to_recordset(p_floors) as f(floor int, rows int, cols int);

  insert into public.layout_cells (layout_id, company_id, floor, row_idx, col_idx, kind, label, accessible, blocked, unusable, seat_class)
  select v_id, v_company, c.floor, c.row_idx, c.col_idx, c.kind::public.cell_kind,
         nullif(trim(c.label), ''), coalesce(c.accessible, false), coalesce(c.blocked, false),
         coalesce(c.unusable, false),
         case when c.kind = 'seat' then coalesce(nullif(trim(c.seat_class), ''), 'Común') else 'Común' end
  from jsonb_to_recordset(p_cells) as c(floor int, row_idx int, col_idx int, kind text, label text,
                                        accessible boolean, blocked boolean, unusable boolean, seat_class text);
  return v_id;
end $$;

create or replace function public.clone_layout(p_layout uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_src public.seat_layouts;
  v_new uuid;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;
  select * into v_src from public.seat_layouts where id = p_layout and company_id = public.current_company_id();
  if not found then raise exception 'NOT_FOUND'; end if;

  insert into public.seat_layouts (company_id, group_id, version, name, is_template)
  values (v_src.company_id, v_src.group_id,
          (select max(version) + 1 from public.seat_layouts where group_id = v_src.group_id),
          v_src.name, v_src.is_template)
  returning id into v_new;

  insert into public.layout_floors (layout_id, company_id, floor, rows, cols)
  select v_new, company_id, floor, rows, cols from public.layout_floors where layout_id = p_layout;

  insert into public.layout_cells (layout_id, company_id, floor, row_idx, col_idx, kind, label, accessible, blocked, unusable, seat_class)
  select v_new, company_id, floor, row_idx, col_idx, kind, label, accessible, blocked, unusable, seat_class
  from public.layout_cells where layout_id = p_layout;

  return v_new;
end $$;
