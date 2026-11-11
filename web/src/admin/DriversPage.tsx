import { useState, type FormEvent } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { Loading, Notice } from '../ui';
import { useAuth } from '../auth/AuthProvider';
import type { Profile } from '../lib/types';

const EMPTY = { full_name: '', email: '', password: '', dni: '', phone: '' };

export function DriversPage() {
  const { profile } = useAuth();
  const canEdit = profile?.role === 'company_admin';
  const [form, setForm] = useState(EMPTY);
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);
  const [busy, setBusy] = useState(false);

  const drivers = useQuery(async () => must(await supabase.from('profiles').select('*').eq('role', 'driver').order('full_name')) as Profile[], []);

  const create = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    const { error, data } = await supabase.functions.invoke('create-driver', { body: form });
    setBusy(false);
    const serverError = (data as { error?: string } | null)?.error;
    if (error || serverError) { setMsg({ kind: 'error', text: serverError ?? friendly(error) }); return; }
    setMsg({ kind: 'ok', text: 'Conductor creado. Pasale el correo y la contraseña inicial.' });
    setForm(EMPTY); drivers.reload();
  };

  const toggle = async (d: Profile) => {
    const { error } = await supabase.from('profiles').update({ active: !d.active }).eq('id', d.id);
    if (error) setMsg({ kind: 'error', text: friendly(error) }); else drivers.reload();
  };

  const set = (k: keyof typeof EMPTY) => (e: { target: { value: string } }) => setForm({ ...form, [k]: e.target.value });

  return (
    <>
      <h1>Conductores</h1>
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}
      {canEdit && (
        <form className="card stack" onSubmit={create}>
          <h2>Agregar conductor</h2>
          <div className="row">
            <label>Nombre y apellido<input value={form.full_name} onChange={set('full_name')} required /></label>
            <label>DNI<input value={form.dni} onChange={set('dni')} inputMode="numeric" /></label>
            <label>Teléfono<input value={form.phone} onChange={set('phone')} inputMode="tel" /></label>
          </div>
          <div className="row">
            <label>Correo (usuario)<input type="email" value={form.email} onChange={set('email')} required /></label>
            <label>Contraseña inicial<input type="text" minLength={8} value={form.password} onChange={set('password')} required /></label>
            <button type="submit" disabled={busy}>{busy ? 'Creando...' : 'Crear conductor'}</button>
          </div>
        </form>
      )}
      <div className="card table-wrap">
        {drivers.loading ? <Loading /> : (
          <table>
            <thead><tr><th>Nombre</th><th>DNI</th><th>Teléfono</th><th>Estado</th><th /></tr></thead>
            <tbody>
              {(drivers.data ?? []).length === 0 && <tr><td colSpan={5} className="muted">Todavía no hay conductores.</td></tr>}
              {(drivers.data ?? []).map((d) => (
                <tr key={d.id}>
                  <td><b>{d.full_name}</b></td><td>{d.dni ?? '-'}</td><td>{d.phone ?? '-'}</td>
                  <td>{d.active ? <span className="pill ok">Activo</span> : <span className="pill warn">Inactivo</span>}</td>
                  <td>{canEdit && <button className="secondary" onClick={() => toggle(d)}>{d.active ? 'Desactivar' : 'Activar'}</button>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
