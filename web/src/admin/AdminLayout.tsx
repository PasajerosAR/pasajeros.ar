import { NavLink, Outlet } from 'react-router-dom';
import { useAuth } from '../auth/AuthProvider';

const PLATFORM_LINKS: [string, string, boolean][] = [
  ['/admin', 'Empresas', true],
  ['/admin/recorridos', 'Catálogo de recorridos', false],
  ['/admin/localidades', 'Localidades', false]
];
const LINKS: [string, string, boolean][] = [
  ['/admin', 'Operación del día', true],
  ['/admin/servicios', 'Servicios', false],
  ['/admin/recorridos', 'Recorridos', false],
  ['/admin/vehiculos', 'Flota', false],
  ['/admin/disposiciones', 'Disposiciones de asientos', false],
  ['/admin/conductores', 'Conductores', false]
];

export function AdminLayout() {
  const { profile, signOut } = useAuth();
  const platform = profile?.role === 'platform_admin';
  return (
    <div className="admin">
      <nav aria-label="Menú del panel">
        <div className="who">{profile?.full_name}<br />{platform ? 'Administración general' : profile?.role === 'support' ? 'Atención al cliente (solo lectura)' : 'Administrador'}</div>
        {(platform ? PLATFORM_LINKS : LINKS).map(([to, label, end]) => (
          <NavLink key={to} to={to} end={end} className={({ isActive }) => (isActive ? 'active' : '')}>{label}</NavLink>
        ))}
        <a href="#salir" onClick={(e) => { e.preventDefault(); void signOut(); }}>Salir</a>
      </nav>
      <main><Outlet /></main>
    </div>
  );
}
