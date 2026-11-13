-- Elimina disposiciones libres o reasigna primero las unidades que las usan.
-- Los viajes conservan su plano historico; una disposicion asociada a viajes
-- se conserva aunque se actualice la disposicion actual de la unidad.
create function public.delete_seat_layout(
  p_layout uuid, p_replacement uuid default null, p_create_copy boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_company uuid := public.current_company_id();
  v_source public.seat_layouts;
  v_target public.seat_layouts;
  v_replacement uuid := p_replacement;
  v_assigned int;
  v_reassigned int := 0;
  v_has_history boolean;
begin
  if not public.is_company_admin() then raise exception 'FORBIDDEN'; end if;

  select * into v_source
    from public.seat_layouts
   where id = p_layout and company_id = v_company
   for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_create_copy and p_replacement is not null then
    raise exception 'REPLACEMENT_INVALID: elija una disposición existente o cree una copia';
  end if;

  select count(*) into v_assigned
    from public.vehicles
   where company_id = v_company and layout_id = p_layout;

  if v_assigned > 0 then
    if p_create_copy then
      insert into public.seat_layouts (company_id, group_id, version, name, is_template)
      values (
        v_company, v_source.group_id,
        (select max(version) + 1 from public.seat_layouts where group_id = v_source.group_id),
        v_source.name || ' (copia)', v_source.is_template
      )
      returning id into v_replacement;

      insert into public.layout_floors (layout_id, company_id, floor, rows, cols)
      select v_replacement, company_id, floor, rows, cols
        from public.layout_floors where layout_id = p_layout;

      insert into public.layout_cells (
        layout_id, company_id, floor, row_idx, col_idx, kind, label,
        accessible, blocked, unusable, seat_class
      )
      select v_replacement, company_id, floor, row_idx, col_idx, kind, label,
             accessible, blocked, unusable, seat_class
        from public.layout_cells where layout_id = p_layout;
    elsif p_replacement is null then
      raise exception 'REPLACEMENT_REQUIRED: reasigne las unidades antes de eliminar';
    else
      select * into v_target
        from public.seat_layouts
       where id = p_replacement and company_id = v_company and id <> p_layout;
      if not found then raise exception 'REPLACEMENT_INVALID: la disposición nueva no pertenece a esta empresa'; end if;
    end if;

    if not exists (
      select 1 from public.seat_layout_capacity
       where layout_id = v_replacement and seats > 0
    ) then
      raise exception 'REPLACEMENT_EMPTY: la disposición nueva no tiene asientos utilizables';
    end if;

    update public.vehicles
       set layout_id = v_replacement
     where company_id = v_company and layout_id = p_layout;
    get diagnostics v_reassigned = row_count;
  elsif p_replacement is not null or p_create_copy then
    raise exception 'NO_ASSIGNED_VEHICLES: no hace falta una disposición de reemplazo';
  end if;

  v_has_history := v_source.locked_at is not null
    or exists (select 1 from public.trips where layout_id = p_layout);

  if v_has_history then
    if v_reassigned = 0 then
      raise exception 'LAYOUT_USED_BY_TRIPS: la disposición se conserva porque hay viajes históricos asociados';
    end if;
    return jsonb_build_object(
      'deleted', false,
      'replacement_id', v_replacement,
      'reassigned_vehicles', v_reassigned,
      'retained_for_history', true
    );
  end if;

  delete from public.seat_layouts
   where id = p_layout and company_id = v_company;

  return jsonb_build_object(
    'deleted', true,
    'replacement_id', v_replacement,
    'reassigned_vehicles', v_reassigned,
    'retained_for_history', false
  );
end $$;

revoke all on function public.delete_seat_layout(uuid, uuid, boolean) from public, anon;
grant execute on function public.delete_seat_layout(uuid, uuid, boolean) to authenticated;
