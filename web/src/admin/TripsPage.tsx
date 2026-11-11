import { useState } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { Loading, Notice, formatTime, todayLocal } from '../ui';
import { useAuth } from '../auth/AuthProvider';
import { INCIDENT_LABEL, STATUS_LABEL, type IncidentKind, type Profile, type TripStatus, type Vehicle } from '../lib/types';
import { DAY_TYPES, DAY_TYPE_LABEL, dayTypeOf, type DayType } from '../lib/dayType';

interface IncidentRow {
  id: string; kind: IncidentKind; note: string | null; created_at: string;
  trips: { services: { code: string } | null } | null; profiles: { full_name: string } | null;
}

interface TripRow {
  id: string; status: TripStatus; scheduled_departure: string; vehicle_id: string | null; driver_id: string | null;
  started_at: string | null; started_manually: boolean; day_type: DayType;
  services: { code: string } | null;
  service_departures: { routes: { name: string } | null } | null;
}

export function TripsPage() {
  const { profile } = useAuth();
  const canEdit = profile?.role === 'company_admin';
  const [date, setDate] = useState(todayLocal());
  const [typeOverride, setTypeOverride] = useState<DayType | null>(null);
  const dayType = typeOverride ?? dayTypeOf(new Date(`${date}T12:00:00`));
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);

  const trips = useQuery(async () => must(await supabase.from('trips')
    .select('id,status,scheduled_departure,vehicle_id,driver_id,started_at,started_manually,day_type,services(code),service_departures(routes(name))')
    .eq('service_date', date).order('scheduled_departure')) as unknown as TripRow[], [date]);
  const incidents = useQuery(async () => {
    const from = new Date(`${date}T00:00:00`), to = new Date(from.getTime() + 24 * 3600 * 1000);
    return must(await supabase.from('incidents').select('id,kind,note,created_at,trips(services(code)),profiles(full_name)')
      .gte('created_at', from.toISOString()).lt('created_at', to.toISOString()).order('created_at', { ascending: false })) as unknown as IncidentRow[];
  }, [date]);
  const vehicles = useQuery(async () => must(await supabase.from('vehicles').select('*').order('internal_number')) as Vehicle[], []);
  const drivers = useQuery(async () => must(await supabase.from('profiles').select('*').eq('role', 'driver').eq('active', true).order('full_name')) as Profile[], []);

  const run = async (fn: () => PromiseLike<{ error: { message: string } | null }>, ok: string) => {
    const { error } = await fn();
    if (error) setMsg({ kind: 'error', text: friendly(error) });
    else { setMsg({ kind: 'ok', text: ok }); trips.reload(); }
  };

  const generate = () => run(() => supabase.rpc('generate_trips', { p_date: date, p_day_type: dayType }), `Viajes generados para ${DAY_TYPE_LABEL[dayType].toLowerCase()}.`);
  const assign = (id: string, patch: { vehicle_id?: string | null; driver_id?: string | null }) =>
    run(() => supabase.from('trips').update(patch).eq('id', id), 'Asignación guardada.');
  const startManually = (id: string) => {
    const reason = window.prompt('Motivo del inicio manual (queda registrado):');
    if (reason === null) return;
    void run(() => supabase.rpc('admin_start_trip', { p_trip: id, p_reason: reason }), 'Viaje iniciado manualmente.');
  };
  const cancel = (id: string) => {
    if (!window.confirm('¿Cancelar este viaje?')) return;
    void run(() => supabase.from('trips').update({ status: 'cancelled' }).eq('id', id), 'Viaje cancelado.');
  };

  const now = Date.now();
  const alerts = (trips.data ?? []).filter((t) => t.status === 'scheduled' && new Date(t.scheduled_departure).getTime() < now);

  return (
    <>
      <h1>Operación del día</h1>
      <div className="row">
        <label style={{ flex: '0 0 200px' }}>Fecha<input type="date" value={date} onChange={(e) => { setDate(e.target.value); setTypeOverride(null); }} /></label>
        {canEdit && (
          <label style={{ flex: '0 0 200px' }}>Tipo de día
            <select value={dayType} onChange={(e) => setTypeOverride(e.target.value as DayType)}>
              {DAY_TYPES.map((d) => <option key={d} value={d}>{DAY_TYPE_LABEL[d]}</option>)}
            </select>
          </label>
        )}
        {canEdit && <button onClick={generate}>Generar viajes del día</button>}
      </div>
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}
      {trips.error && <Notice>{trips.error}</Notice>}
      {alerts.length > 0 && (
        <Notice kind="warn">{alerts.length === 1 ? '1 servicio no inició' : `${alerts.length} servicios no iniciaron`} pasada la hora programada: {alerts.map((a) => a.services?.code).join(', ')}.</Notice>
      )}
      <div className="card table-wrap">
        {trips.loading ? <Loading /> : (
          <table>
            <thead><tr><th>Servicio</th><th>Recorrido</th><th>Salida</th><th>Estado</th><th>Vehículo</th><th>Conductor</th><th /></tr></thead>
            <tbody>
              {(trips.data ?? []).length === 0 && <tr><td colSpan={7} className="muted">No hay viajes para esta fecha. Generá los viajes del día desde los servicios activos.</td></tr>}
              {(trips.data ?? []).map((t) => {
                const editable = canEdit && t.status === 'scheduled';
                return (
                  <tr key={t.id}>
                    <td><b>{t.services?.code}</b><br /><span className="muted" style={{ fontSize: 12 }}>{DAY_TYPE_LABEL[t.day_type]}</span></td>
                    <td>{t.service_departures?.routes?.name}</td>
                    <td>{formatTime(t.scheduled_departure)}</td>
                    <td>
                      <span className={`pill ${t.status === 'in_progress' ? 'info' : t.status === 'completed' ? 'ok' : t.status === 'cancelled' ? 'bad' : 'warn'}`}>{STATUS_LABEL[t.status]}</span>
                      {t.started_manually && <span className="muted"> (manual)</span>}
                    </td>
                    <td>
                      <select aria-label="Vehículo" disabled={!editable} value={t.vehicle_id ?? ''} onChange={(e) => assign(t.id, { vehicle_id: e.target.value || null })}>
                        <option value="">Sin asignar</option>
                        {(vehicles.data ?? []).map((v) => <option key={v.id} value={v.id}>Interno {v.internal_number} ({v.plate})</option>)}
                      </select>
                    </td>
                    <td>
                      <select aria-label="Conductor" disabled={!editable} value={t.driver_id ?? ''} onChange={(e) => assign(t.id, { driver_id: e.target.value || null })}>
                        <option value="">Sin asignar</option>
                        {(drivers.data ?? []).map((d) => <option key={d.id} value={d.id}>{d.full_name}</option>)}
                      </select>
                    </td>
                    <td>
                      {editable && (
                        <div className="row">
                          <button className="secondary" disabled={!t.vehicle_id} onClick={() => startManually(t.id)}>Iniciar manual</button>
                          <button className="danger" onClick={() => cancel(t.id)}>Cancelar</button>
                        </div>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </div>
      {(incidents.data ?? []).length > 0 && (
        <div className="card table-wrap">
          <h2>Incidencias del día</h2>
          <table>
            <thead><tr><th>Hora</th><th>Servicio</th><th>Conductor</th><th>Tipo</th><th>Detalle</th></tr></thead>
            <tbody>
              {(incidents.data ?? []).map((i) => (
                <tr key={i.id}>
                  <td>{formatTime(i.created_at)}</td><td><b>{i.trips?.services?.code}</b></td><td>{i.profiles?.full_name}</td>
                  <td>{INCIDENT_LABEL[i.kind]}</td><td>{i.note ?? '-'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
