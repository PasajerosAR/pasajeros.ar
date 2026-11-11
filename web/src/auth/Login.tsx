import { useState, type FormEvent } from 'react';
import { useAuth } from './AuthProvider';
import { Notice } from '../ui';

export function Login() {
  const { signIn } = useAuth();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setBusy(true);
    setError(await signIn(email.trim(), password));
    setBusy(false);
  };

  return (
    <form className="center" onSubmit={submit}>
      <h1>Ingresar</h1>
      {error && <Notice>{error}</Notice>}
      <label>Correo<input type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} required /></label>
      <label>Contraseña<input type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required /></label>
      <button type="submit" disabled={busy}>{busy ? 'Ingresando...' : 'Ingresar'}</button>
    </form>
  );
}
