import { Navigate, Route, Routes } from 'react-router-dom';
import { useAuth } from './auth/AuthProvider';
import { Login } from './auth/Login';
import { configured } from './lib/supabase';
import { Loading, Notice } from './ui';
import { AdminLayout } from './admin/AdminLayout';
import { TripsPage } from './admin/TripsPage';
import { VehiclesPage } from './admin/VehiclesPage';
import { LayoutsPage } from './admin/LayoutsPage';
import { LayoutEditorPage } from './admin/LayoutEditorPage';
import { RoutesPage } from './admin/RoutesPage';
import { ServicesPage } from './admin/ServicesPage';
import { PlacesPage } from './admin/PlacesPage';
import { CompaniesPage } from './admin/CompaniesPage';
import { DriversPage } from './admin/DriversPage';
import { StartService } from './driver/StartService';
import { DriverHome } from './driver/DriverHome';
import { TripScreen } from './driver/TripScreen';

export function App() {
  const { loading, session, profile, signOut } = useAuth();

  if (!configured) {
    return (
      <div className="center">
        <h1>Falta configurar Supabase</h1>
        <Notice kind="warn">Copiá <code>.env.example</code> a <code>.env.local</code> y completá VITE_SUPABASE_URL y VITE_SUPABASE_ANON_KEY.</Notice>
      </div>
    );
  }
  if (loading) return <div className="center"><Loading /></div>;
  if (!session) return <Login />;
  if (!profile || !profile.active) {
    return (
      <div className="center">
        <Notice>Tu usuario no tiene un perfil activo. Pedile al administrador de tu empresa que lo habilite.</Notice>
        <button className="secondary" onClick={signOut}>Salir</button>
      </div>
    );
  }
  if (profile.role === 'platform_admin') {
    return (
      <Routes>
        <Route path="/admin" element={<AdminLayout />}>
          <Route index element={<CompaniesPage />} />
          <Route path="recorridos" element={<RoutesPage />} />
          <Route path="localidades" element={<PlacesPage />} />
        </Route>
        <Route path="*" element={<Navigate to="/admin" replace />} />
      </Routes>
    );
  }

  if (profile.role === 'driver') {
    return (
      <Routes>
        <Route path="/conductor" element={<DriverHome />} />
        <Route path="/conductor/iniciar" element={<StartService />} />
        <Route path="/conductor/viaje/:id" element={<TripScreen />} />
        <Route path="*" element={<Navigate to="/conductor" replace />} />
      </Routes>
    );
  }

  return (
    <Routes>
      <Route path="/admin" element={<AdminLayout />}>
        <Route index element={<TripsPage />} />
        <Route path="vehiculos" element={<VehiclesPage />} />
        <Route path="disposiciones" element={<LayoutsPage />} />
        <Route path="disposiciones/:id" element={<LayoutEditorPage />} />
        <Route path="recorridos" element={<RoutesPage />} />
        <Route path="servicios" element={<ServicesPage />} />
        <Route path="conductores" element={<DriversPage />} />
      </Route>
      <Route path="*" element={<Navigate to="/admin" replace />} />
    </Routes>
  );
}
