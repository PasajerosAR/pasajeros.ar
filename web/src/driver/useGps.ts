import { useEffect, useState } from 'react';
import type { LatLng } from '../lib/routePath';

export interface GpsState { pos: LatLng | null; error: 'denied' | 'unavailable' | null }

// Posición del teléfono mientras `active`. Solo se usa en pantalla para calcular la puntualidad: no se guarda.
export function useGps(active: boolean): GpsState {
  const [state, setState] = useState<GpsState>({ pos: null, error: null });
  useEffect(() => {
    if (!active) return;
    if (!('geolocation' in navigator)) { setState({ pos: null, error: 'unavailable' }); return; }
    const id = navigator.geolocation.watchPosition(
      (p) => setState({ pos: [p.coords.latitude, p.coords.longitude], error: null }),
      (e) => setState((s) => ({ pos: s.pos, error: e.code === e.PERMISSION_DENIED ? 'denied' : 'unavailable' })),
      { enableHighAccuracy: true, maximumAge: 5000, timeout: 20000 }
    );
    return () => navigator.geolocation.clearWatch(id);
  }, [active]);
  return state;
}
