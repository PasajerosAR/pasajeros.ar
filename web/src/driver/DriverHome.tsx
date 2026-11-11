import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { useAuth } from '../auth/AuthProvider';
import { Loading, formatTime, todayLocal } from '../ui';
import { formatPunctuality, punctualityMinutes } from '../lib/punctuality';
import { STATUS_LABEL, type Shift, type TripStatus } from '../lib/types';

interface TripRow {
  id: string; status: TripStatus; scheduled_departure: string;
  vehicles: { internal_number: string } | null;
  services: { code: string } | null;
  service_departures: { routes: { name: string } | null } | null;
}

// Franjas fijas por ahora (manana, tarde, noche); deben ser configurables por empresa en una etapa siguiente.
const band = (iso: string) => { const h = new Date(iso).getHours(); return h < 12 ? 'Mañana' : h < 20 ? 'Tarde' : 'Noche'; };

export function DriverHome() {
  const { profile, signOut } = useAuth();
  const [now, setNow] = useState(() => new Date());
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => { const t = setInterval(() => setNow(new Date()), 30_000); return () => clearInterval(t); }, []);

  const shift = useQuery(async () => must(await supabase.from('shifts').select('*').is('ended_at', null).maybeSingle()) as Shift | null, []);
  const trips = useQuery(async () => must(await supabase.from('trips')
    .select('id,status,scheduled_departure,vehicles(internal_number),services(code),service_departures(routes(name))')
    .eq('service_date', todayLocal()).order('scheduled_departure')) as unknown as TripRow[], []);

  const toggleShift = async () => {
    setBusy(true); setError(null);
    const { error: e } = await supabase.rpc(shift.data ? 'end_shift' : 'start_shift');
    setBusy(false);
    if (e) setError(friendly(e)); else shift.reload();
  };

  const groups = ['Mañana', 'Tarde', 'Noche'].map((b) => ({ b, items: (trips.data ?? []).filter((t) => band(t.scheduled_departure) === b) })).filter((g) => g.items.length);

  return (
    <div className="driver-app">
      <div className="row" style={{ alignItems: 'center' }}>
        <div><h1 style={{ fontSize: 20 }}>Hola, {profile?.full_name.split(' ')[0]}</h1><span className="muted">{now.toLocaleDateString('es-AR', { weekday: 'long', day: 'numeric', month: 'long' })}</span></div>
        <button onClick={signOut} style={{ minHeight: 44, fontSize: 14 }}>Salir</button>
      </div>

      {error && <div className="notice error" role="alert">{error}</div>}

      <div className="panel">
        {shift.loading ? <Loading /> : (
          <>
            <div className="muted">Jornada</div>
            <div style={{ fontSize: 18, fontWeight: 700, margin: '4px 0 10px' }}>{shift.data ? `Abierta desde las ${formatTime(shift.data.started_at)}` : 'Sin iniciar'}</div>
            <button className={shift.data ? '' : 'primary'} style={{ width: '100%' }} disabled={busy} onClick={toggleShift}>{shift.data ? 'Cerrar jornada' : 'Iniciar jornada'}</button>
          </>
        )}
      </div>

      <Link to="/conductor/iniciar"><button className="primary big" style={{ width: '100%' }} disabled={!shift.data}>Iniciar servicio</button></Link>
      {!shift.loading && !shift.data && <div className="muted" style={{ marginTop: -6 }}>Iniciá la jornada para poder iniciar un servicio.</div>}

      {trips.error && <div className="notice error">{trips.error}</div>}
      {trips.loading && <Loading />}
      {!trips.loading && (trips.data ?? []).length === 0 && <div className="panel muted">No tenés servicios asignados para hoy.</div>}

      {groups.map((g) => (
        <section key={g.b} aria-label={g.b} style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <h2 style={{ margin: '4px 0 0' }}>{g.b}</h2>
          {g.items.map((t) => {
            const mins = punctualityMinutes(new Date(t.scheduled_departure), now);
            return (
              <Link key={t.id} to={`/conductor/viaje/${t.id}`} style={{ textDecoration: 'none', color: 'inherit' }}>
                <div className="panel" style={{ display: 'flex', justifyContent: 'space-between', gap: 8 }}>
                  <div>
                    <div style={{ fontSize: 18, fontWeight: 700 }}>Servicio {t.services?.code} - {formatTime(t.scheduled_departure)}</div>
                    <div className="muted">{t.service_departures?.routes?.name} - Unidad {t.vehicles?.internal_number ?? 'sin asignar'}</div>
                  </div>
                  <div style={{ textAlign: 'right' }}>
                    <div style={{ fontWeight: 700 }}>{STATUS_LABEL[t.status]}</div>
                    {t.status === 'scheduled' && <div className={mins < 0 ? 'late' : 'early'}>{formatPunctuality(mins, mins >= 0)}</div>}
                  </div>
                </div>
              </Link>
            );
          })}
        </section>
      ))}
    </div>
  );
}
