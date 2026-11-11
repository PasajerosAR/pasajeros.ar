import { useEffect, useRef, useState } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { Loading, Notice } from '../ui';
import { useAuth } from '../auth/AuthProvider';
import type { Company, Locality, Route, RouteStop } from '../lib/types';
import { buildWaypoints, nearestSegment, routeByStreets, sortVia, type LatLng, type Via } from '../lib/routePath';
import { StopMap } from './StopMap';

interface StopForm { name: string; lat: string; lng: string; place_id: string }
const blankStop = (): StopForm => ({ name: '', lat: '', lng: '', place_id: '' });
const blankStops = (): StopForm[] => [blankStop(), blankStop()];
type Trace = 'idle' | 'tracing' | 'ok' | 'error';

// El catalogo de recorridos lo administra la plataforma; las empresas solo lo consultan.
export function RoutesPage() {
  const { profile } = useAuth();
  const canEdit = profile?.role === 'platform_admin';
  const [editing, setEditing] = useState<string | null>(null); // id o 'nuevo'
  const [name, setName] = useState('');
  const [companyId, setCompanyId] = useState('');
  const [stops, setStops] = useState<StopForm[]>(blankStops());
  const [sel, setSel] = useState<number | null>(0);
  const [via, setVia] = useState<Via[]>([]);
  const [path, setPath] = useState<LatLng[] | null>(null);
  const [trace, setTrace] = useState<Trace>('idle');
  const [mode, setMode] = useState<'stop' | 'via'>('stop');
  const [retryN, setRetryN] = useState(0);
  const tracedKey = useRef('');   // trazado ya calculado (o cargado) para estas paradas y puntos de paso
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);

  const routes = useQuery(async () => must(await supabase.from('routes').select('*').order('name')) as Route[], []);
  const companies = useQuery(async () => canEdit ? must(await supabase.from('companies').select('*').order('name')) as Company[] : [], [canEdit]);
  const companyName = (id: string | null) => companies.data?.find((c) => c.id === id)?.name ?? 'Sin asignar';
  const places = useQuery(async () => must(await supabase.from('places').select('*').order('name')) as Locality[], []);
  const placeName = (id: string | null) => places.data?.find((p) => p.id === id)?.name ?? null;
  const allStops = useQuery(async () => must(await supabase.from('route_stops').select('*').order('position')) as RouteStop[], []);
  const stopsOf = (id: string) => (allStops.data ?? []).filter((s) => s.route_id === id);

  const open = (r: Route | null) => {
    setMsg(null);
    setMode('stop');
    if (!r) {
      setEditing('nuevo'); setName(''); setCompanyId(''); setStops(blankStops()); setSel(0);
      setVia([]); setPath(null); setTrace('idle'); tracedKey.current = ''; return;
    }
    const loaded = stopsOf(r.id).map((s) => ({ name: s.name, lat: s.lat?.toString() ?? '', lng: s.lng?.toString() ?? '', place_id: s.place_id ?? '' }));
    setEditing(r.id); setName(r.name); setCompanyId(r.company_id ?? ''); setSel(0);
    setStops(loaded); setVia(r.via ?? []); setPath(r.path); setTrace(r.path ? 'ok' : 'idle');
    tracedKey.current = r.path ? JSON.stringify(buildWaypoints(loaded, r.via ?? [])) : '';
  };

  // Traza por calles cada vez que cambian las paradas o los puntos de paso (con una pausa para no consultar en cada arrastre).
  const waypoints = buildWaypoints(stops, via);
  const wpKey = JSON.stringify(waypoints);
  useEffect(() => {
    if (!editing || !canEdit) return;
    if (!waypoints) { setPath(null); setTrace('idle'); return; }
    if (wpKey === tracedKey.current) return;
    setTrace('tracing');
    let cancelled = false;
    const t = setTimeout(async () => {
      try {
        const p = await routeByStreets(waypoints);
        if (cancelled) return;
        tracedKey.current = wpKey; setPath(p); setTrace('ok');
      } catch { if (!cancelled) { setPath(null); setTrace('error'); } }
    }, 900);
    return () => { cancelled = true; clearTimeout(t); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [wpKey, editing, retryN]);

  const retrace = () => { tracedKey.current = ''; setRetryN((n) => n + 1); };

  const save = async () => {
    const clean = stops.filter((s) => s.name.trim()).map((s) => ({ name: s.name, lat: s.lat.trim(), lng: s.lng.trim(), place_id: s.place_id }));
    if (trace === 'tracing') { setMsg({ kind: 'error', text: 'Esperá un momento: se está trazando el recorrido por las calles.' }); return; }
    const { error } = await supabase.rpc('save_route', {
      p_route: editing === 'nuevo' ? null : editing, p_name: name, p_active: true, p_stops: clean, p_company: companyId || null,
      p_path: trace === 'ok' ? path : null, p_via: via
    });
    if (error) { setMsg({ kind: 'error', text: friendly(error) }); return; }
    setMsg({ kind: 'ok', text: 'Recorrido guardado.' });
    setEditing(null); routes.reload(); allStops.reload();
  };

  // Los puntos de paso se guardan por tramo; si se quita una parada, se descartan para no dejar tramos mal asignados.
  const addVia = (lat: number, lng: number) => setVia(sortVia(stops, [...via, { seg: nearestSegment(stops, [lat, lng]), lat, lng }]));
  const moveVia = (i: number, lat: number, lng: number) => setVia(sortVia(stops, via.map((v, j) => (j === i ? { ...v, lat, lng } : v))));
  const removeVia = (i: number) => setVia(via.filter((_, j) => j !== i));
  const patch = (i: number, p: Partial<StopForm>) => setStops(stops.map((s, j) => (j === i ? { ...s, ...p } : s)));

  return (
    <>
      <div className="row" style={{ alignItems: 'center' }}>
        <h1>Recorridos</h1>
        {canEdit && <button onClick={() => open(null)}>Nuevo recorrido</button>}
      </div>
      {!canEdit && <p className="muted">Estos son los recorridos de tu empresa; los carga la plataforma. Si necesitás uno nuevo o una correccion, pedilo al administrador general.</p>}
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}

      {editing && (
        <section className="card stack" aria-label="Editar recorrido">
          <h2>{editing === 'nuevo' ? 'Nuevo recorrido' : 'Editar recorrido'}</h2>
          <label>Empresa dueña del recorrido
            <select value={companyId} onChange={(e) => setCompanyId(e.target.value)} required>
              <option value="">Elegir empresa...</option>
              {(companies.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
          </label>
          <label>Nombre<input value={name} onChange={(e) => setName(e.target.value)} placeholder="Paraná - Santa Fe" /></label>
          <div className="table-wrap">
            <table>
              <thead><tr><th>#</th><th>Parada</th><th>Localidad</th><th>Latitud</th><th>Longitud</th><th /></tr></thead>
              <tbody>
                {stops.map((s, i) => (
                  <tr key={i} className={sel === i ? 'sel-row' : ''} onClick={() => setSel(i)}>
                    <td>{i + 1}</td>
                    <td>
                      <input aria-label={`Parada ${i + 1}`} value={s.name} onChange={(e) => patch(i, { name: e.target.value })} />
                      <span className="muted" style={{ fontSize: 12 }}>{i === 0 ? 'Origen' : i === stops.length - 1 ? 'Destino' : 'Intermedia: el servicio pasa por acá'}</span>
                    </td>
                    <td>
                      <select aria-label={`Localidad de la parada ${i + 1}`} value={s.place_id} onChange={(e) => patch(i, { place_id: e.target.value })}>
                        <option value="">Elegir...</option>
                        {(places.data ?? []).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
                      </select>
                    </td>
                    <td><input aria-label="Latitud" inputMode="decimal" value={s.lat} onChange={(e) => patch(i, { lat: e.target.value })} placeholder="-31.7333" /></td>
                    <td><input aria-label="Longitud" inputMode="decimal" value={s.lng} onChange={(e) => patch(i, { lng: e.target.value })} placeholder="-60.5236" /></td>
                    <td><button type="button" className="danger" disabled={stops.length <= 2} onClick={() => { setStops(stops.filter((_, j) => j !== i)); setVia([]); setSel(null); }}>Quitar</button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="row" style={{ alignItems: 'center' }}>
            <button type="button" className={mode === 'stop' ? '' : 'secondary'} aria-pressed={mode === 'stop'} onClick={() => setMode('stop')}>Ubicar paradas</button>
            <button type="button" className={mode === 'via' ? '' : 'secondary'} aria-pressed={mode === 'via'} onClick={() => setMode('via')}>Agregar puntos de paso</button>
            {via.length > 0 && <button type="button" className="secondary" onClick={() => setVia([])}>{via.length === 1 ? "Quitar el punto de paso" : `Quitar los ${via.length} puntos de paso`}</button>}
            <span className="muted" style={{ flex: '1 1 200px' }} role="status">
              {trace === 'tracing' ? 'Trazando por las calles...' : trace === 'ok' ? 'Recorrido trazado por las calles.'
                : trace === 'error' ? 'No se pudo trazar. Se guardará sin trazado; podés reintentar.' : waypoints ? '' : 'Ubicá todas las paradas para trazar el recorrido.'}
            </span>
            {trace === 'error' && <button type="button" className="secondary" onClick={retrace}>Reintentar trazado</button>}
          </div>
          <StopMap stops={stops} selected={sel} onPick={(i, lat, lng) => patch(i, { lat: String(lat), lng: String(lng) })}
            path={path} via={via} mode={mode} onAddVia={addVia} onMoveVia={moveVia} onRemoveVia={removeVia} />
          <div className="row">
            <button className="secondary" onClick={() => { setStops([...stops, blankStop()]); setSel(stops.length); }}>Agregar parada</button>
            <button onClick={save}>Guardar recorrido</button>
            <button className="secondary" onClick={() => setEditing(null)}>Cancelar</button>
          </div>
          <p className="muted">La primera parada es el origen y la última el destino; las del medio son lugares por donde el servicio pasa. Si el camino calculado no es el que hace la combi, agregá puntos de paso para forzarlo. El recorrido es exclusivo de la empresa elegida. Los tiempos entre paradas los define la empresa en sus servicios. Si ya hay servicios con este recorrido, solo se pueden corregir nombres, localidades y coordenadas.</p>
        </section>
      )}

      <div className="card table-wrap">
        {routes.loading ? <Loading /> : (
          <table>
            <thead><tr><th>Recorrido</th>{canEdit && <th>Empresa</th>}<th>Origen → destino</th><th>Paradas</th><th /></tr></thead>
            <tbody>
              {(routes.data ?? []).length === 0 && <tr><td colSpan={5} className="muted">Todavía no hay recorridos.</td></tr>}
              {(routes.data ?? []).map((r) => (
                <tr key={r.id}>
                  <td><b>{r.name}</b></td>
                  {canEdit && <td>{r.company_id ? companyName(r.company_id) : <span className="pill warn">Sin asignar</span>}</td>}
                  <td>{r.origin_place_id ? `${placeName(r.origin_place_id) ?? '-'} → ${placeName(r.destination_place_id) ?? '-'}` : <span className="pill warn">Falta localidad</span>}</td>
                  <td>{stopsOf(r.id).map((s) => s.name).join(' > ')}</td>
                  <td>{canEdit && <button className="secondary" onClick={() => open(r)}>Editar</button>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
