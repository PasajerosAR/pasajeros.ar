import { useEffect, useRef } from 'react';
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';

interface Props {
  stops: { id: string; name: string; lat: number | null; lng: number | null }[];
  path: [number, number][] | null;
  highlightId?: string | null;
  height?: number;
}

// Mapa de solo lectura: recorrido por calles, paradas numeradas y la próxima parada resaltada.
export function RouteMap({ stops, path, highlightId, height = 280 }: Props) {
  const el = useRef<HTMLDivElement>(null);
  const map = useRef<L.Map | null>(null);

  useEffect(() => {
    if (!el.current) return;
    const m = L.map(el.current, { zoomControl: true }).setView([-31.7333, -60.5236], 11);
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '&copy; colaboradores de OpenStreetMap' }).addTo(m);
    map.current = m;
    return () => { m.remove(); map.current = null; };
  }, []);

  useEffect(() => {
    const m = map.current;
    if (!m) return;
    const g = L.layerGroup().addTo(m);
    const pts: L.LatLngTuple[] = [];
    stops.forEach((s, i) => {
      if (s.lat === null || s.lng === null) return;
      pts.push([s.lat, s.lng]);
      const active = s.id === highlightId;
      L.marker([s.lat, s.lng], {
        title: s.name, interactive: false,
        icon: L.divIcon({ className: '', iconSize: [28, 28], iconAnchor: [14, 14], html: `<div class="map-pin${active ? ' active' : ''}">${i + 1}</div>` })
      }).addTo(g);
    });
    const line: L.LatLngTuple[] = path && path.length > 1 ? path : pts;
    if (line.length > 1) L.polyline(line, { color: '#2f7fc1', weight: 4, opacity: 0.85, dashArray: path && path.length > 1 ? undefined : '6 8' }).addTo(g);
    const all = [...line, ...pts];
    if (all.length) m.fitBounds(L.latLngBounds(all), { padding: [24, 24], maxZoom: 16 });
    return () => { g.remove(); };
  }, [stops, path, highlightId]);

  return <div ref={el} className="map" style={{ height }} aria-label="Mapa del recorrido" />;
}
