import { useEffect, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { Loading, Notice } from '../ui';
import { useAuth } from '../auth/AuthProvider';
import {
  addFloor, cellAt, fromDbRows, newDraft, paint, removeFloor, renumber, resizeFloor, summary, toDbRows,
  updateSeat, validate, type Cell, type CellKind, type DbCell, type DbFloor, type LayoutDraft
} from '../lib/seatGrid';

const TOOLS: [CellKind | 'select', string][] = [
  ['select', 'Seleccionar asiento'], ['seat', 'Asiento'], ['aisle', 'Pasillo'], ['empty', 'Vacío'],
  ['driver', 'Conductor'], ['door', 'Puerta'], ['trunk', 'Baúl'], ['toilet', 'Baño'], ['stairs', 'Escalera']
];
const TAG: Partial<Record<CellKind, string>> = { aisle: 'Pasillo', driver: 'Conductor', door: 'Puerta', trunk: 'Baúl', toilet: 'Baño', stairs: 'Escalera' };

export function LayoutEditorPage() {
  const { id = 'nueva' } = useParams();
  const isNew = id === 'nueva';
  const nav = useNavigate();
  const { profile } = useAuth();
  const canEdit = profile?.role === 'company_admin';

  const [loading, setLoading] = useState(!isNew);
  const [name, setName] = useState('');
  const [version, setVersion] = useState(1);
  const [locked, setLocked] = useState(false);
  const [draft, setDraft] = useState<LayoutDraft>(() => renumber(newDraft(5, 5)));
  const [floor, setFloor] = useState(1);
  const [tool, setTool] = useState<CellKind | 'select'>('seat');
  const [auto, setAuto] = useState(true);
  const [selected, setSelected] = useState<{ floor: number; row: number; col: number } | null>(null);
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok' | 'warn'; text: string } | null>(null);
  const [saving, setSaving] = useState(false);
  const dragging = useRef(false);

  useEffect(() => {
    if (isNew) return;
    let alive = true;
    (async () => {
      const [l, f, c] = await Promise.all([
        supabase.from('seat_layouts').select('name,version,locked_at').eq('id', id).maybeSingle(),
        supabase.from('layout_floors').select('floor,rows,cols').eq('layout_id', id),
        supabase.from('layout_cells').select('floor,row_idx,col_idx,kind,label,accessible,blocked,unusable').eq('layout_id', id)
      ]);
      if (!alive) return;
      if (l.error || f.error || c.error || !l.data) { setMsg({ kind: 'error', text: friendly(l.error ?? f.error ?? c.error ?? 'No se encontró la disposición.') }); setLoading(false); return; }
      setName(l.data.name); setVersion(l.data.version); setLocked(Boolean(l.data.locked_at));
      setDraft(fromDbRows(f.data as DbFloor[], c.data as DbCell[]));
      setLoading(false);
    })();
    return () => { alive = false; };
  }, [id, isNew]);

  const apply = (next: LayoutDraft) => setDraft(auto ? renumber(next) : next);
  const dims = draft.floors.find((f) => f.floor === floor) ?? draft.floors[0];
  const sel: Cell | undefined = selected ? cellAt(draft, selected.floor, selected.row, selected.col) : undefined;
  const sum = summary(draft);

  const touch = (row: number, col: number) => {
    if (!canEdit) return;
    if (tool === 'select') { setSelected({ floor, row, col }); return; }
    apply(paint(draft, floor, row, col, tool));
    setSelected(null);
  };

  const save = async () => {
    const errors = validate(draft);
    if (!name.trim()) errors.unshift('Falta el nombre de la disposición.');
    if (errors.length) { setMsg({ kind: 'error', text: errors.join(' ') }); return; }
    setSaving(true);
    const rows = toDbRows(draft, '', '');
    const { data, error } = await supabase.rpc('save_layout', {
      p_layout: isNew ? null : id, p_name: name,
      p_floors: rows.floors.map((f) => ({ floor: f.floor, rows: f.rows, cols: f.cols })),
      p_cells: rows.cells.map((c) => ({ floor: c.floor, row_idx: c.row_idx, col_idx: c.col_idx, kind: c.kind, label: c.label, accessible: c.accessible, blocked: c.blocked, unusable: c.unusable }))
    });
    setSaving(false);
    if (error) { setMsg({ kind: 'error', text: friendly(error) }); return; }
    const newId = data as string;
    if (newId !== id) {
      nav(`/admin/disposiciones/${newId}`, { replace: true });
      return;
    }
    setMsg({ kind: 'ok', text: 'Disposición guardada.' });
  };

  if (loading) return <Loading />;

  return (
    <>
      <div className="row" style={{ alignItems: 'center' }}>
        <h1>{isNew ? 'Nueva disposición' : `${name} - versión ${version}`}</h1>
        {canEdit && <button onClick={save} disabled={saving}>{saving ? 'Guardando...' : locked ? 'Guardar como versión nueva' : 'Guardar'}</button>}
      </div>
      {locked && <Notice kind="warn">Esta disposición está en uso por viajes. Al guardar se crea una versión nueva y esta queda sin cambios. Después asignala a los vehículos desde Flota.</Notice>}
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}

      <div className="editor">
        {canEdit && (
          <section className="card tools" aria-label="Herramientas">
            <h2>Herramientas</h2>
            {TOOLS.map(([k, label]) => (
              <button key={k} className={tool === k ? 'on' : ''} aria-pressed={tool === k} onClick={() => setTool(k)}>{label}</button>
            ))}
            <label>Nombre<input value={name} onChange={(e) => setName(e.target.value)} placeholder="Ej: Combi 19" /></label>
            <div className="row">
              <label>Filas<input type="number" min={1} max={30} value={dims.rows} onChange={(e) => apply(resizeFloor(draft, floor, Number(e.target.value) || 1, dims.cols))} /></label>
              <label>Columnas<input type="number" min={1} max={12} value={dims.cols} onChange={(e) => apply(resizeFloor(draft, floor, dims.rows, Number(e.target.value) || 1))} /></label>
            </div>
            <label style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
              <input type="checkbox" style={{ width: 20, minHeight: 20 }} checked={auto} onChange={(e) => { setAuto(e.target.checked); if (e.target.checked) setDraft(renumber(draft)); }} />
              Numerar automáticamente
            </label>
            {!auto && <button className="secondary" onClick={() => setDraft(renumber(draft))}>Renumerar ahora</button>}
          </section>
        )}

        <section className="card" style={{ flex: '999 1 420px', minWidth: 0 }} aria-label="Plano">
          <div className="row" style={{ alignItems: 'center' }}>
            <div role="tablist" aria-label="Pisos" style={{ display: 'flex', gap: 6, flex: '1 1 auto' }}>
              {draft.floors.map((f) => (
                <button key={f.floor} role="tab" aria-selected={f.floor === floor} className={f.floor === floor ? '' : 'secondary'} onClick={() => { setFloor(f.floor); setSelected(null); }}>Piso {f.floor}</button>
              ))}
              {canEdit && draft.floors.length < 2 && <button className="secondary" onClick={() => { apply(addFloor(draft)); setFloor(2); }}>+ Agregar piso</button>}
              {canEdit && draft.floors.length === 2 && floor === 2 && <button className="danger" onClick={() => { apply(removeFloor(draft, 2)); setFloor(1); }}>Quitar piso 2</button>}
            </div>
          </div>
          <div className="grid-box" onMouseUp={() => { dragging.current = false; }} onMouseLeave={() => { dragging.current = false; }}>
            <div className="grid" style={{ gridTemplateColumns: `repeat(${dims.cols}, minmax(0, 1fr))` }}>
              {draft.cells.filter((c) => c.floor === floor).map((c) => {
                const classes = ['cell', c.kind, c.kind === 'seat' && c.accessible ? 'accessible' : '', c.kind === 'seat' && c.blocked ? 'blocked' : '',
                  c.kind === 'seat' && c.unusable ? 'unusable' : '', selected && selected.floor === floor && selected.row === c.row && selected.col === c.col ? 'selected' : ''].join(' ');
                return (
                  <button key={`${c.row}-${c.col}`} className={classes}
                    aria-label={`Fila ${c.row + 1}, columna ${c.col + 1}: ${c.kind === 'seat' ? `asiento ${c.label ?? 'sin número'}` : TAG[c.kind] ?? 'vacío'}`}
                    onMouseDown={() => { dragging.current = true; touch(c.row, c.col); }}
                    onMouseEnter={() => { if (dragging.current && tool !== 'select') touch(c.row, c.col); }}>
                    {c.kind === 'seat' ? c.label ?? '?' : ''}
                    <small>{c.kind === 'seat' ? [c.accessible && 'Acc.', c.blocked && 'Bloq.', c.unusable && 'No útil'].filter(Boolean).join(' ') : TAG[c.kind] ?? ''}</small>
                  </button>
                );
              })}
            </div>
          </div>
          <p className="muted">Frente del vehículo arriba. Elegí una herramienta y hacé clic o arrastrá sobre la grilla.</p>
        </section>

        <div className="side">
          <section className="card">
            <h2>Resumen</h2>
            <div style={{ fontSize: 32, fontWeight: 700 }}>{sum.seats} <span className="muted">asientos</span></div>
            <p className="muted">Calculado desde la grilla. {sum.accessible} accesibles, {sum.blocked} bloqueados, {sum.unusable} no utilizables.</p>
          </section>
          {canEdit && (
            <section className="card stack" aria-label="Asiento seleccionado">
              <h2>Asiento seleccionado</h2>
              {sel && sel.kind === 'seat' ? (
                <>
                  <label>Número o etiqueta<input value={sel.label ?? ''} onChange={(e) => setDraft(updateSeat(draft, sel.floor, sel.row, sel.col, { label: e.target.value }))} /></label>
                  {(['accessible', 'blocked', 'unusable'] as const).map((k) => (
                    <label key={k} style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
                      <input type="checkbox" style={{ width: 20, minHeight: 20 }} checked={sel[k]} onChange={(e) => setDraft(updateSeat(draft, sel.floor, sel.row, sel.col, { [k]: e.target.checked }))} />
                      {k === 'accessible' ? 'Accesible (movilidad reducida)' : k === 'blocked' ? 'Bloqueado por la empresa' : 'No utilizable'}
                    </label>
                  ))}
                  {auto && <p className="muted">Con numeración automática, el número se vuelve a calcular al editar la grilla. Desmarcala para usar números propios.</p>}
                </>
              ) : <p className="muted">Usá la herramienta "Seleccionar asiento" y tocá un asiento para editarlo.</p>}
            </section>
          )}
        </div>
      </div>
    </>
  );
}
