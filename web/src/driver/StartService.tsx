import { useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { Loading, todayLocal } from '../ui';
import { DAY_TYPES, DAY_TYPE_LABEL, dayTypeOf, type DayType } from '../lib/dayType';
import { WINDOW_MINUTES, minutesToDeparture, nearestDeparture, needsReason } from '../lib/startWindow';
import { formatSpan } from '../lib/punctuality';
import type { Route, Service, ServiceDeparture, Vehicle } from '../lib/types';

const UNAVAILABLE = ['maintenance', 'out_of_service', 'retired'];
const LAST_VEHICLE = 'transporte.lastVehicle';
const readLast = () => { try { return localStorage.getItem(LAST_VEHICLE) ?? ''; } catch { return ''; } };

// El conductor declara qué servicio va a hacer: número, tipo de día, sentido, salida y unidad.
export function StartService() {
  const nav = useNavigate();
  const now = useMemo(() => new Date(), []);
  const [code, setCode] = useState('');
  const [dayType, setDayType] = useState<DayType>(() => dayTypeOf(new Date()));
  const [routePick, setRoutePick] = useState<string | null>(null);
  const [depPick, setDepPick] = useState<string | null>(null);
  const [vehicleId, setVehicleId] = useState(readLast);
  const [reason, setReason] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const services = useQuery(async () => must(await supabase.from('services').select('id,code,active').eq('active', true).order('code')) as Service[], []);
  const routes = useQuery(async () => must(await supabase.from('routes').select('id,name')) as Pick<Route, 'id' | 'name'>[], []);
  const vehicles = useQuery(async () => must(await supabase.from('vehicles').select('id,internal_number,plate,status').order('internal_number')) as Pick<Vehicle, 'id' | 'internal_number' | 'plate' | 'status'>[], []);
  const service = (services.data ?? []).find((s) => s.code.toLowerCase() === code.trim().toLowerCase()) ?? null;
  const deps = useQuery(async () => service
    ? must(await supabase.from('service_departures').select('*').eq('service_id', service.id).eq('active', true).order('departure_time')) as ServiceDeparture[]
    : [], [service?.id]);
  // último viaje del día de este conductor: se sugiere el sentido contrario
  const last = useQuery(async () => must(await supabase.from('trips').select('service_id,service_departures(route_id)')
    .eq('status', 'completed').eq('service_date', todayLocal()).order('ended_at', { ascending: false }).limit(1).maybeSingle()) as unknown as
    { service_id: string; service_departures: { route_id: string } | null } | null, []);

  const forType = (deps.data ?? []).filter((d) => d.day_types.includes(dayType));
  const routeIds = [...new Set(forType.map((d) => d.route_id))];
  const suggested = last.data && service && last.data.service_id === service.id
    ? routeIds.find((r) => r !== last.data?.service_departures?.route_id) : undefined;
  const sentido = routePick && routeIds.includes(routePick) ? routePick : suggested ?? routeIds[0] ?? null;
  const options = forType.filter((d) => d.route_id === sentido);
  const picked = options.find((d) => d.id === depPick) ?? nearestDeparture(options, now);
  const minutes = picked ? minutesToDeparture(picked.departure_time, now) : 0;
  const forced = picked ? needsReason(minutes) : false;
  const routeName = (id: string | null) => routes.data?.find((r) => r.id === id)?.name ?? '-';
  const freeVehicles = (vehicles.data ?? []).filter((v) => !UNAVAILABLE.includes(v.status));
  const ready = !!(service && picked && vehicleId && (!forced || reason.trim().length >= 3));

  const invert = () => {
    const i = routeIds.indexOf(sentido ?? '');
    setRoutePick(routeIds[(i + 1) % routeIds.length]); setDepPick(null);
  };

  const start = async () => {
    if (!service || !picked) return;
    setBusy(true); setError(null);
    const { data, error: e } = await supabase.rpc('start_service', {
      p_service: service.id, p_departure: picked.id, p_day_type: dayType, p_vehicle: vehicleId, p_reason: forced ? reason.trim() : null
    });
    setBusy(false);
    if (e) { setError(friendly(e)); return; }
    try { localStorage.setItem(LAST_VEHICLE, vehicleId); } catch { /* sin almacenamiento: no pasa nada */ }
    nav(`/conductor/viaje/${(data as { id: string }).id}`);
  };

  return (
    <div className="driver-app">
      <div className="row" style={{ alignItems: 'center' }}>
        <Link to="/conductor"><button style={{ minHeight: 48 }}>Volver</button></Link>
        <h1 style={{ fontSize: 20, flex: '1 1 140px' }}>Iniciar servicio</h1>
      </div>
      {error && <div className="notice error" role="alert">{error}</div>}
      {services.loading ? <Loading /> : (
        <>
          <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
            <span className="muted">Número de servicio</span>
            <input value={code} onChange={(e) => { setCode(e.target.value); setRoutePick(null); setDepPick(null); }} inputMode="numeric" list="service-codes" placeholder="214" autoComplete="off" />
            <datalist id="service-codes">{(services.data ?? []).map((s) => <option key={s.id} value={s.code} />)}</datalist>
          </label>
          {code.trim() && !service && <div className="notice warn">No hay un servicio activo con el número {code.trim()}.</div>}

          <div>
            <div className="muted" style={{ marginBottom: 6 }}>Tipo de día</div>
            <div className="seg" role="group" aria-label="Tipo de día">
              {DAY_TYPES.map((t) => (
                <button key={t} type="button" className={t === dayType ? 'primary' : ''} aria-pressed={t === dayType}
                  onClick={() => { setDayType(t); setRoutePick(null); setDepPick(null); }}>{DAY_TYPE_LABEL[t]}</button>
              ))}
            </div>
          </div>

          {service && (deps.loading ? <Loading /> : forType.length === 0 ? (
            <div className="notice warn">El servicio {service.code} no tiene salidas para {DAY_TYPE_LABEL[dayType].toLowerCase()}. Probá con otro tipo de día.</div>
          ) : (
            <>
              <div className="panel">
                <div className="muted">Sentido</div>
                <div style={{ fontSize: 18, fontWeight: 700, margin: '4px 0 8px' }}>{routeName(sentido)}</div>
                {routeIds.length > 1 && <button type="button" style={{ width: '100%' }} onClick={invert}>Invertir sentido</button>}
                {suggested && sentido === suggested && <div className="muted" style={{ marginTop: 6 }}>Sugerido: el contrario al viaje que acabás de terminar.</div>}
              </div>

              <div>
                <div className="muted" style={{ marginBottom: 6 }}>Salida</div>
                <div className="seg" role="group" aria-label="Salida">
                  {options.map((d) => {
                    const m = minutesToDeparture(d.departure_time, now);
                    return (
                      <button key={d.id} type="button" className={d.id === picked?.id ? 'primary' : ''} aria-pressed={d.id === picked?.id} onClick={() => setDepPick(d.id)}>
                        {d.departure_time.slice(0, 5)}
                        <span style={{ display: 'block', fontSize: 12, fontWeight: 500 }}>{m === 0 ? 'ahora' : m > 0 ? `en ${formatSpan(m)}` : `hace ${formatSpan(-m)}`}</span>
                      </button>
                    );
                  })}
                </div>
              </div>

              {forced && (
                <div className="notice warn">
                  Esta salida está fuera de horario (más de {WINDOW_MINUTES} minutos). Para iniciarla escribí el motivo; queda registrado.
                  <input style={{ width: '100%', marginTop: 8, boxSizing: 'border-box' }} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Motivo" aria-label="Motivo del inicio fuera de horario" />
                </div>
              )}

              <label style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                <span className="muted">Unidad</span>
                <select value={vehicleId} onChange={(e) => setVehicleId(e.target.value)}>
                  <option value="">Elegir...</option>
                  {freeVehicles.map((v) => <option key={v.id} value={v.id}>Interno {v.internal_number} ({v.plate})</option>)}
                </select>
              </label>

              <button className="primary big" disabled={!ready || busy} onClick={start}>Iniciar viaje</button>
            </>
          ))}
        </>
      )}
    </div>
  );
}
