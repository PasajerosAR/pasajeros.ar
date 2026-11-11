import { useState, type FormEvent } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { Loading, Notice } from '../ui';
import { useAuth } from '../auth/AuthProvider';
import { VEHICLE_STATUS_LABEL, type SeatLayout, type Vehicle, type VehicleStatus } from '../lib/types';

const EMPTY = { kind: 'combi', internal_number: '', plate: '', brand: '', model: '', year: '', layout_id: '' };

export function VehiclesPage() {
  const { profile } = useAuth();
  const canEdit = profile?.role === 'company_admin';
  const [form, setForm] = useState(EMPTY);
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);

  const vehicles = useQuery(async () => must(await supabase.from('vehicles').select('*').order('internal_number')) as Vehicle[], []);
  const layouts = useQuery(async () => must(await supabase.from('seat_layouts').select('*').order('name').order('version', { ascending: false })) as SeatLayout[], []);

  const create = async (e: FormEvent) => {
    e.preventDefault();
    const { error } = await supabase.from('vehicles').insert({
      company_id: profile!.company_id, kind: form.kind, internal_number: form.internal_number.trim(),
      plate: form.plate.trim().toUpperCase(), brand: form.brand.trim() || null, model: form.model.trim() || null,
      year: form.year ? Number(form.year) : null, layout_id: form.layout_id || null
    });
    if (error) setMsg({ kind: 'error', text: friendly(error) });
    else { setMsg({ kind: 'ok', text: 'Vehículo agregado.' }); setForm(EMPTY); vehicles.reload(); }
  };

  const update = async (id: string, patch: { status?: VehicleStatus; layout_id?: string | null }) => {
    const { error } = await supabase.from('vehicles').update(patch).eq('id', id);
    if (error) setMsg({ kind: 'error', text: friendly(error) });
    else { setMsg({ kind: 'ok', text: 'Cambios guardados.' }); vehicles.reload(); }
  };

  const set = (k: keyof typeof EMPTY) => (e: { target: { value: string } }) => setForm({ ...form, [k]: e.target.value });

  return (
    <>
      <h1>Flota</h1>
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}
      {canEdit && (
        <form className="card stack" onSubmit={create}>
          <h2>Agregar vehículo</h2>
          <div className="row">
            <label>Tipo<select value={form.kind} onChange={set('kind')}><option value="combi">Combi</option><option value="colectivo">Colectivo</option></select></label>
            <label>Número de interno<input value={form.internal_number} onChange={set('internal_number')} required /></label>
            <label>Patente<input value={form.plate} onChange={set('plate')} required /></label>
          </div>
          <div className="row">
            <label>Marca<input value={form.brand} onChange={set('brand')} /></label>
            <label>Modelo<input value={form.model} onChange={set('model')} /></label>
            <label>Ano<input type="number" min={1980} max={2100} value={form.year} onChange={set('year')} /></label>
            <label>Disposición de asientos
              <select value={form.layout_id} onChange={set('layout_id')}>
                <option value="">Definir después</option>
                {(layouts.data ?? []).map((l) => <option key={l.id} value={l.id}>{l.name} (v{l.version})</option>)}
              </select>
            </label>
            <button type="submit">Agregar</button>
          </div>
        </form>
      )}
      <div className="card table-wrap">
        {vehicles.loading ? <Loading /> : (
          <table>
            <thead><tr><th>Interno</th><th>Tipo</th><th>Patente</th><th>Marca y modelo</th><th>Estado</th><th>Disposición</th></tr></thead>
            <tbody>
              {(vehicles.data ?? []).length === 0 && <tr><td colSpan={6} className="muted">Todavía no hay vehículos.</td></tr>}
              {(vehicles.data ?? []).map((v) => (
                <tr key={v.id}>
                  <td><b>{v.internal_number}</b></td>
                  <td>{v.kind === 'combi' ? 'Combi' : 'Colectivo'}</td>
                  <td>{v.plate}</td>
                  <td>{[v.brand, v.model, v.year].filter(Boolean).join(' ') || '-'}</td>
                  <td>
                    <select aria-label="Estado" disabled={!canEdit} value={v.status} onChange={(e) => update(v.id, { status: e.target.value as VehicleStatus })}>
                      {Object.entries(VEHICLE_STATUS_LABEL).map(([k, l]) => <option key={k} value={k}>{l}</option>)}
                    </select>
                  </td>
                  <td>
                    <select aria-label="Disposición" disabled={!canEdit} value={v.layout_id ?? ''} onChange={(e) => update(v.id, { layout_id: e.target.value || null })}>
                      <option value="">Sin definir</option>
                      {(layouts.data ?? []).map((l) => <option key={l.id} value={l.id}>{l.name} (v{l.version})</option>)}
                    </select>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
        <p className="muted">Cambiar la disposición de un vehículo no modifica los viajes que ya la tienen asignada: cada viaje conserva la disposición que tenía al asignarle el vehículo.</p>
      </div>
    </>
  );
}
