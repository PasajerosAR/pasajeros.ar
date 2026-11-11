import { Link } from 'react-router-dom';
import { supabase } from '../lib/supabase';
import { must, useQuery } from '../lib/useQuery';
import { Loading, Notice } from '../ui';
import { useAuth } from '../auth/AuthProvider';
import type { SeatLayout } from '../lib/types';

export function LayoutsPage() {
  const { profile } = useAuth();
  const canEdit = profile?.role === 'company_admin';
  const layouts = useQuery(async () => must(await supabase.from('seat_layouts').select('*').order('name').order('version', { ascending: false })) as SeatLayout[], []);
  const caps = useQuery(async () => must(await supabase.from('seat_layout_capacity').select('layout_id,seats')) as { layout_id: string; seats: number }[], []);
  const seatsOf = (id: string) => caps.data?.find((c) => c.layout_id === id)?.seats ?? 0;

  return (
    <>
      <div className="row" style={{ alignItems: 'center' }}>
        <h1>Disposiciones de asientos</h1>
        {canEdit && <Link to="/admin/disposiciones/nueva"><button>Nueva disposición</button></Link>}
      </div>
      {layouts.error && <Notice>{layouts.error}</Notice>}
      <div className="card table-wrap">
        {layouts.loading ? <Loading /> : (
          <table>
            <thead><tr><th>Nombre</th><th>Versión</th><th>Asientos</th><th>Estado</th><th /></tr></thead>
            <tbody>
              {(layouts.data ?? []).length === 0 && <tr><td colSpan={5} className="muted">Todavía no hay disposiciones. Creá una para cada tipo de vehículo.</td></tr>}
              {(layouts.data ?? []).map((l) => (
                <tr key={l.id}>
                  <td><b>{l.name}</b></td>
                  <td>v{l.version}</td>
                  <td>{seatsOf(l.id)}</td>
                  <td>{l.locked_at ? <span className="pill warn">En uso: editar crea una versión nueva</span> : <span className="pill ok">Editable</span>}</td>
                  <td><Link to={`/admin/disposiciones/${l.id}`}><button className="secondary">{canEdit ? 'Abrir' : 'Ver'}</button></Link></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
