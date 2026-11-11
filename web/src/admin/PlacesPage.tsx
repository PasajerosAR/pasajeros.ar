import { useState, type FormEvent } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { Loading, Notice } from '../ui';
import type { Locality } from '../lib/types';

// Localidades: lo que el pasajero elige como origen y destino. Las administra la plataforma para que no haya duplicados.
export function PlacesPage() {
  const [name, setName] = useState('');
  const [province, setProvince] = useState('');
  const [editing, setEditing] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);
  const places = useQuery(async () => must(await supabase.from('places').select('*').order('name')) as Locality[], []);
  const used = useQuery(async () => must(await supabase.from('route_stops').select('place_id')) as { place_id: string | null }[], []);
  const useCount = (id: string) => (used.data ?? []).filter((s) => s.place_id === id).length;

  const reset = () => { setName(''); setProvince(''); setEditing(null); };
  const save = async (e: FormEvent) => {
    e.preventDefault();
    const row = { name: name.trim(), province: province.trim() || null };
    const { error } = editing ? await supabase.from('places').update(row).eq('id', editing) : await supabase.from('places').insert(row);
    if (error) {
      setMsg({ kind: 'error', text: error.code === '23505' ? 'Esa localidad ya existe.' : friendly(error) });
      return;
    }
    setMsg({ kind: 'ok', text: editing ? 'Localidad actualizada.' : 'Localidad agregada.' });
    reset(); places.reload();
  };
  const remove = async (p: Locality) => {
    const { error } = await supabase.from('places').delete().eq('id', p.id);
    if (error) setMsg({ kind: 'error', text: 'No se puede borrar: hay paradas que usan esta localidad.' }); else places.reload();
  };

  return (
    <>
      <h1>Localidades</h1>
      <p className="muted">Son los lugares que el pasajero elige como origen y destino. Cada parada de un recorrido pertenece a una localidad; una localidad intermedia aparece como lugar por donde el servicio pasa.</p>
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}
      <form className="card stack" onSubmit={save}>
        <h2>{editing ? 'Editar localidad' : 'Nueva localidad'}</h2>
        <div className="row" style={{ alignItems: 'flex-end' }}>
          <label>Nombre<input value={name} onChange={(e) => setName(e.target.value)} required placeholder="Paraná" /></label>
          <label>Provincia<input value={province} onChange={(e) => setProvince(e.target.value)} placeholder="Entre Ríos" /></label>
          <button type="submit" style={{ flex: '0 0 auto' }}>{editing ? 'Guardar' : 'Agregar'}</button>
          {editing && <button type="button" className="secondary" style={{ flex: '0 0 auto' }} onClick={reset}>Cancelar</button>}
        </div>
      </form>
      <div className="card table-wrap">
        {places.loading ? <Loading /> : (
          <table>
            <thead><tr><th>Localidad</th><th>Provincia</th><th>Paradas</th><th /></tr></thead>
            <tbody>
              {(places.data ?? []).length === 0 && <tr><td colSpan={4} className="muted">Todavía no hay localidades. Cargá las de tus recorridos.</td></tr>}
              {(places.data ?? []).map((p) => (
                <tr key={p.id}>
                  <td><b>{p.name}</b></td><td>{p.province ?? '-'}</td><td>{useCount(p.id)}</td>
                  <td><div className="row">
                    <button className="secondary" onClick={() => { setEditing(p.id); setName(p.name); setProvince(p.province ?? ''); }}>Editar</button>
                    <button className="danger" disabled={useCount(p.id) > 0} onClick={() => remove(p)}>Borrar</button>
                  </div></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
