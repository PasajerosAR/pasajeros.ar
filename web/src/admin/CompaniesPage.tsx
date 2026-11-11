import { useState, type FormEvent } from 'react';
import { supabase } from '../lib/supabase';
import { friendly } from '../lib/errors';
import { must, useQuery } from '../lib/useQuery';
import { Loading, Notice } from '../ui';
import type { Company } from '../lib/types';

const EMPTY = { company_name: '', full_name: '', email: '', password: '' };

// Panel de la plataforma: alta de empresas y de su primer administrador.
export function CompaniesPage() {
  const [form, setForm] = useState(EMPTY);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ kind: 'error' | 'ok'; text: string } | null>(null);
  const companies = useQuery(async () => must(await supabase.from('companies').select('*').order('name')) as Company[], []);

  const create = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    const { error, data } = await supabase.functions.invoke('create-company-admin', { body: form });
    setBusy(false);
    const serverError = (data as { error?: string } | null)?.error;
    if (error || serverError) { setMsg({ kind: 'error', text: serverError ?? friendly(error) }); return; }
    setMsg({ kind: 'ok', text: 'Empresa creada. Pasale al administrador su correo y la contraseña inicial.' });
    setForm(EMPTY); companies.reload();
  };

  const toggle = async (c: Company) => {
    const { error } = await supabase.from('companies').update({ active: !c.active }).eq('id', c.id);
    if (error) setMsg({ kind: 'error', text: friendly(error) }); else companies.reload();
  };

  const set = (k: keyof typeof EMPTY) => (e: { target: { value: string } }) => setForm({ ...form, [k]: e.target.value });

  return (
    <>
      <h1>Empresas</h1>
      {msg && <Notice kind={msg.kind}>{msg.text}</Notice>}
      <form className="card stack" onSubmit={create}>
        <h2>Nueva empresa</h2>
        <div className="row">
          <label>Nombre de la empresa<input value={form.company_name} onChange={set('company_name')} required /></label>
          <label>Administrador: nombre completo<input value={form.full_name} onChange={set('full_name')} required /></label>
        </div>
        <div className="row">
          <label>Correo<input type="email" value={form.email} onChange={set('email')} required /></label>
          <label>Contraseña inicial<input type="text" minLength={8} value={form.password} onChange={set('password')} required /></label>
        </div>
        <button type="submit" disabled={busy} style={{ alignSelf: 'flex-start' }}>Crear empresa</button>
      </form>
      <div className="card table-wrap">
        {companies.loading ? <Loading /> : (
          <table>
            <thead><tr><th>Empresa</th><th>Alta</th><th>Estado</th><th /></tr></thead>
            <tbody>
              {(companies.data ?? []).length === 0 && <tr><td colSpan={4} className="muted">Todavía no hay empresas.</td></tr>}
              {(companies.data ?? []).map((c) => (
                <tr key={c.id}>
                  <td><b>{c.name}</b></td>
                  <td>{new Date(c.created_at).toLocaleDateString('es-AR')}</td>
                  <td>{c.active ? <span className="pill ok">Activa</span> : <span className="pill warn">Suspendida</span>}</td>
                  <td><button className="secondary" onClick={() => toggle(c)}>{c.active ? 'Suspender' : 'Activar'}</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
