import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { errorCode, friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { Loading, formatTime } from '../ui';
import { formatPunctuality, formatSigned, punctualityMinutes, punctualityState } from '../lib/punctuality';
import { INCIDENT_LABEL, STATUS_LABEL, type CountResult, type IncidentKind, type RouteStop, type TripStatus } from '../lib/types';
import { DAY_TYPE_LABEL, type DayType } from '../lib/dayType';
import { nextScheduledStop, type TimedStop } from '../lib/tripProgress';
import { liveProgress, type LiveStop } from '../lib/gpsProgress';
import type { LatLng } from '../lib/routePath';
import { useGps } from './useGps';
import { RouteMap } from './RouteMap';

interface TripDetail {
  id: string; service_id: string; day_type: DayType | null; status: TripStatus; scheduled_departure: string; started_at: string | null; ended_at: string | null; layout_id: string | null;
  services: { code: string } | null;
  service_departures: { route_id: string; routes: { name: string; path: [number, number][] | null } | null } | null;
  vehicles: { internal_number: string } | null;
}

export function TripScreen() {
  const { id = '' } = useParams();
  const [now, setNow] = useState(() => new Date());
  const [error, setError] = useState<string | null>(null);
  const [warn, setWarn] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [qty, setQty] = useState(1);
  const [stopId, setStopId] = useState('');
  const [showMap, setShowMap] = useState(false);
  const [incOpen, setIncOpen] = useState(false);
  const [incKind, setIncKind] = useState<IncidentKind>('traffic');
  const [incNote, setIncNote] = useState('');
  const [counts, setCounts] = useState<{ onboard: number; capacity: number } | null>(null);

  useEffect(() => { const t = setInterval(() => setNow(new Date()), 15_000); return () => clearInterval(t); }, []);

  const trip = useQuery(async () => must(await supabase.from('trips')
    .select('id,service_id,day_type,status,scheduled_departure,started_at,ended_at,layout_id,services(code),service_departures(route_id,routes(name,path)),vehicles(internal_number)')
    .eq('id', id).maybeSingle()) as unknown as TripDetail | null, [id]);
  const routeId = trip.data?.service_departures?.route_id;
  const stops = useQuery(async () => routeId
    ? must(await supabase.from('route_stops').select('*').eq('route_id', routeId).order('position')) as RouteStop[]
    : [], [routeId]);

  const serviceId = trip.data?.service_id;
  const times = useQuery(async () => serviceId
    ? must(await supabase.from('service_stops').select('route_stop_id,minutes_from_start,dwell_minutes').eq('service_id', serviceId)) as
      { route_stop_id: string; minutes_from_start: number; dwell_minutes: number }[]
    : [], [serviceId]);

  const t = trip.data;
  const gps = useGps(t?.status === 'in_progress');
  const layoutId = t?.layout_id;
  const refreshCounts = async () => {
    if (!t) return;
    const [o, c] = await Promise.all([
      supabase.rpc('trip_onboard', { p_trip: t.id }),
      layoutId ? supabase.from('seat_layout_capacity').select('seats').eq('layout_id', layoutId).maybeSingle() : Promise.resolve({ data: null, error: null })
    ]);
    setCounts({ onboard: Number(o.data ?? 0), capacity: Number((c.data as { seats: number } | null)?.seats ?? 0) });
  };
  useEffect(() => { void refreshCounts(); /* eslint-disable-next-line react-hooks/exhaustive-deps */ }, [t?.id, t?.status, layoutId]);
  useEffect(() => { if (!stopId && stops.data?.length) setStopId(stops.data[0].id); }, [stops.data, stopId]);

  const act = async (fn: () => PromiseLike<{ error: { message: string } | null }>) => {
    setBusy(true); setError(null); setWarn(null);
    const { error: e } = await fn();
    setBusy(false);
    if (e) { setError(friendly(e)); return false; }
    return true;
  };

  const start = async () => { if (await act(() => supabase.rpc('start_trip', { p_trip: id }))) trip.reload(); };

  const finish = async (force = false) => {
    setBusy(true); setError(null);
    const { error: e } = await supabase.rpc('end_trip', { p_trip: id, p_force: force });
    setBusy(false);
    if (!e) { trip.reload(); return; }
    if (errorCode(e) === 'ONBOARD_REMAINING') {
      if (window.confirm(`${friendly(e)}. Finalizar el viaje igual?`)) void finish(true);
    } else setError(friendly(e));
  };

  const sendIncident = async () => {
    if (await act(() => supabase.rpc('report_incident', { p_trip: id, p_kind: incKind, p_note: incNote.trim() || null }))) {
      setIncOpen(false); setIncNote(''); setWarn('Incidencia informada.');
    }
  };

  const register = async (kind: 'board' | 'alight') => {
    setBusy(true); setError(null); setWarn(null);
    const event = crypto.randomUUID();           // se reutiliza en el reintento: el servidor no lo cuenta dos veces
    const call = () => supabase.rpc('register_count', { p_trip: id, p_kind: kind, p_quantity: qty, p_stop: stopId || null, p_event: event });
    let res = await call();
    if (res.error && errorCode(res.error) === null) res = await call();   // fallo de red: un reintento
    setBusy(false);
    if (res.error) { setError(friendly(res.error)); return; }
    const r = res.data as CountResult;
    setCounts({ onboard: r.onboard, capacity: r.capacity });
    if (r.over_capacity) setWarn(`Atención: hay ${r.onboard} a bordo y la capacidad es ${r.capacity}.`);
    setQty(1);
  };

  if (trip.loading) return <div className="driver-app"><Loading /></div>;
  if (!t) return <div className="driver-app"><div className="notice error">No se encontró el viaje.</div><Link to="/conductor"><button style={{ width: '100%' }}>Volver</button></Link></div>;

  const scheduledAt = new Date(t.scheduled_departure);
  const beforeDeparture = now.getTime() < scheduledAt.getTime();
  const inTrip = t.status === 'in_progress';

  // Horarios a cumplir: los de la carga del servicio (salida programada + minutos de cada parada).
  const timed: TimedStop[] = (stops.data ?? []).flatMap((s) => {
    const x = times.data?.find((y) => y.route_stop_id === s.id);
    return x ? [{ id: s.id, name: s.name, position: s.position, minutes_from_start: x.minutes_from_start, dwell_minutes: x.dwell_minutes }] : [];
  });
  const liveStops: LiveStop[] = (stops.data ?? []).flatMap((s) => {
    const x = times.data?.find((y) => y.route_stop_id === s.id);
    return x && s.lat !== null && s.lng !== null
      ? [{ id: s.id, name: s.name, lat: s.lat, lng: s.lng, minutes_from_start: x.minutes_from_start, dwell_minutes: x.dwell_minutes }] : [];
  });
  const savedPath = t.service_departures?.routes?.path;
  const line: LatLng[] | null = savedPath && savedPath.length > 1 ? savedPath : liveStops.length > 1 ? liveStops.map((s) => [s.lat, s.lng] as LatLng) : null;

  // En ruta, el adelanto o atraso lo marca solo el GPS. La hora en que el chofer se conectó no cuenta.
  const live = inTrip && !beforeDeparture && gps.pos && line && liveStops.length > 1
    ? liveProgress(line, liveStops, scheduledAt, now, gps.pos) : null;
  const mins: number | null = inTrip && !beforeDeparture ? (live?.mins ?? null) : punctualityMinutes(scheduledAt, now);
  const state = mins === null ? null : punctualityState(mins);
  const dataReady = !stops.loading && !times.loading;
  const gpsMessage = !dataReady ? 'Cargando...'
    : !line || liveStops.length < 2 ? 'Faltan paradas con ubicación y horario'
    : gps.error === 'denied' ? 'Activá el permiso de ubicación'
    : live?.offRoute ? 'Fuera del recorrido'
    : gps.pos ? '' : gps.error ? 'Sin señal GPS' : 'Buscando señal GPS...';

  // Próxima parada: con GPS manda la posición; sin GPS (o antes de salir) el reloj. Siempre con horario programado.
  let next: { id: string; name: string; scheduled: Date } | null = null;
  let arrived = false;
  if (inTrip && timed.length > 1) {
    const clock = nextScheduledStop(timed, scheduledAt, now);
    if (live && !live.offRoute) {
      if (live.nextIndex === null) arrived = true;
      else {
        const ls = liveStops[live.nextIndex];
        const tm = timed.find((x) => x.id === ls.id);
        if (tm) next = { id: tm.id, name: tm.name, scheduled: new Date(scheduledAt.getTime() + tm.minutes_from_start * 60000) };
      }
    }
    if (!arrived && !next && clock) next = { id: clock.stop.id, name: clock.stop.name, scheduled: clock.scheduled };
  }
  const hm = (d: Date) => formatTime(d.toISOString());
  const free = counts ? Math.max(counts.capacity - counts.onboard, 0) : 0;

  return (
    <div className="driver-app">
      <div className="row" style={{ alignItems: 'center' }}>
        <Link to="/conductor"><button style={{ minHeight: 48 }} aria-label="Volver a mis servicios">Volver</button></Link>
        <div style={{ flex: '1 1 160px' }}>
          <h1 style={{ fontSize: 18 }}>Servicio {t.services?.code} - {t.service_departures?.routes?.name}</h1>
          <span className="muted">Unidad {t.vehicles?.internal_number ?? 'sin asignar'} - {STATUS_LABEL[t.status]}{t.day_type ? ` - ${DAY_TYPE_LABEL[t.day_type]}` : ''}</span>
        </div>
      </div>

      {error && <div className="notice error" role="alert">{error}</div>}
      {warn && <div className="notice warn" role="status">{warn}</div>}

      {(t.status === 'scheduled' || inTrip) && (
        <div className="panel" style={{ display: 'flex', justifyContent: 'space-between', gap: 12, alignItems: 'center' }}>
          <div>
            <div className="muted">{inTrip && !beforeDeparture ? 'Puntualidad' : 'Para la salida'}</div>
            <div className={`num ${state === 'late' ? 'late' : state === 'early' ? 'early' : ''}`}>{mins === null ? '-' : formatSigned(mins)}</div>
            <div>{mins === null ? gpsMessage : formatPunctuality(mins, beforeDeparture)}</div>
          </div>
          <div className="muted" style={{ textAlign: 'right', lineHeight: 1.7 }}>
            Programada <b style={{ color: '#fff' }}>{formatTime(t.scheduled_departure)}</b>
            {t.started_at && <><br />Se conectó <b style={{ color: '#fff' }}>{formatTime(t.started_at)}</b></>}
          </div>
        </div>
      )}

      {inTrip && (arrived || next) && (
        <div className="panel">
          {arrived ? <div>Llegaste al destino. Finalizá el viaje.</div> : next && (
            <>
              <div className="muted">Próxima parada</div>
              <div style={{ fontSize: 20, fontWeight: 700 }}>{next.name}</div>
              <div className="muted">Prog. <b style={{ color: '#fff' }}>{hm(next.scheduled)}</b></div>
            </>
          )}
        </div>
      )}

      {t.status === 'scheduled' && (
        <button className="primary big" disabled={busy || !t.vehicles} onClick={start}>Iniciar viaje</button>
      )}
      {t.status === 'scheduled' && !t.vehicles && <div className="notice warn">Todavía no tiene vehículo asignado. Avisale al administrador.</div>}

      {t.status === 'in_progress' && (
        <>
          <div className="grid4">
            <div className="panel"><b>{counts?.onboard ?? '-'}</b><span className="muted">A bordo</span></div>
            <div className="panel"><b>{counts && counts.capacity > 0 ? free : '-'}</b><span className="muted">Libres</span></div>
            <div className="panel"><b>{counts?.capacity || '-'}</b><span className="muted">Capacidad</span></div>
          </div>

          <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            <span className="muted">Parada actual</span>
            <select value={stopId} onChange={(e) => setStopId(e.target.value)}>
              {(stops.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.position}. {s.name}</option>)}
            </select>
          </label>

          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <button aria-label="Menos personas" style={{ width: 64 }} disabled={qty <= 1} onClick={() => setQty(qty - 1)}>-</button>
            <div style={{ flex: 1, textAlign: 'center', fontSize: 32, fontWeight: 800 }} aria-live="polite">{qty}</div>
            <button aria-label="Más personas" style={{ width: 64 }} onClick={() => setQty(qty + 1)}>+</button>
          </div>

          <div style={{ display: 'flex', gap: 10 }}>
            <button className="big" style={{ flex: 1 }} disabled={busy} onClick={() => register('alight')}>Bajan</button>
            <button className="primary big" style={{ flex: 1 }} disabled={busy} onClick={() => register('board')}>Suben</button>
          </div>

          <div style={{ display: 'flex', gap: 10 }}>
            <button style={{ flex: 1 }} aria-pressed={showMap} onClick={() => setShowMap(!showMap)}>{showMap ? 'Ocultar mapa' : 'Mapa'}</button>
            <button style={{ flex: 1 }} aria-pressed={incOpen} onClick={() => setIncOpen(!incOpen)}>Incidencia</button>
          </div>

          {showMap && <RouteMap stops={stops.data ?? []} path={t.service_departures?.routes?.path ?? null} highlightId={next?.id ?? null} />}

          {incOpen && (
            <div className="panel" style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
              <div className="seg" role="group" aria-label="Tipo de incidencia">
                {(Object.keys(INCIDENT_LABEL) as IncidentKind[]).map((k) => (
                  <button key={k} type="button" className={k === incKind ? 'primary' : ''} aria-pressed={k === incKind} onClick={() => setIncKind(k)}>{INCIDENT_LABEL[k]}</button>
                ))}
              </div>
              <input value={incNote} onChange={(e) => setIncNote(e.target.value)} placeholder={incKind === 'other' ? 'Detalle (obligatorio)' : 'Detalle (opcional)'} aria-label="Detalle de la incidencia" />
              <button className="primary" disabled={busy || (incKind === 'other' && incNote.trim().length < 3)} onClick={sendIncident}>Informar</button>
            </div>
          )}

          <button className="stop" disabled={busy} onClick={() => finish(false)}>Finalizar viaje</button>
        </>
      )}

      {t.status === 'completed' && <div className="panel">Viaje finalizado a las {t.ended_at ? formatTime(t.ended_at) : '-'}.</div>}
    </div>
  );
}
