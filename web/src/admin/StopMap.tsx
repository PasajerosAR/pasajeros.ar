import { useEffect, useRef, useState } from 'react';
import L from 'leaflet';
import 'leaflet/dist/leaflet.css';
import type { LatLng, Via } from '../lib/routePath';
import { findIntersections, parseIntersection, searchPlaces, type Place } from '../lib/geoSearch';

export interface MapStop { name: string; lat: string; lng: string }
interface Props {
  stops: MapStop[];
  selected: number | null;
  onPick: (i: number, lat: number, lng: number) => void;
  path: LatLng[] | null;          // trazado por calles (si está calculado)
  via: Via[];                     // puntos de paso
  mode: 'stop' | 'via';           // qué hace un clic en el mapa
  onAddVia: (lat: number, lng: number) => void;
  onMoveVia: (i: number, lat: number, lng: number) => void;
  onRemoveVia: (i: number) => void;
}

const num = (s: string) => (s.trim() === '' || Number.isNaN(Number(s)) ? null : Number(s));
const round = (n: number) => Math.round(n * 1e6) / 1e6;
const ARGENTINA: L.LatLngTuple = [-31.7333, -60.5236]; // Paraná, vista inicial

// Mapa de OpenStreetMap: clic para ubicar la parada elegida, arrastrar para ajustarla.
export function StopMap({ stops, selected, onPick, path, via, mode, onAddVia, onMoveVia, onRemoveVia }: Props) {
  const el = useRef<HTMLDivElement>(null);
  const map = useRef<L.Map | null>(null);
  const layer = useRef<L.LayerGroup | null>(null);
  const latest = useRef({ selected, onPick, mode, onAddVia });
  latest.current = { selected, onPick, mode, onAddVia };
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<Place[]>([]);
  const [searchMsg, setSearchMsg] = useState<string | null>(null);

  useEffect(() => {
    if (!el.current || map.current) return;
    const m = L.map(el.current).setView(ARGENTINA, 11);
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19, attribution: '© colaboradores de <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
    }).addTo(m);
    layer.current = L.layerGroup().addTo(m);
    m.on('click', (e: L.LeafletMouseEvent) => {
      const { selected: sel, onPick: pick, mode: md, onAddVia: addVia } = latest.current;
      if (md === 'via') addVia(round(e.latlng.lat), round(e.latlng.lng));
      else if (sel !== null) pick(sel, round(e.latlng.lat), round(e.latlng.lng));
    });
    map.current = m;
    return () => { m.remove(); map.current = null; };
  }, []);

  // Redibuja marcadores y línea cada vez que cambian las paradas o la selección.
  useEffect(() => {
    const m = map.current, g = layer.current;
    if (!m || !g) return;
    g.clearLayers();
    const pts: L.LatLngTuple[] = [];
    stops.forEach((s, i) => {
      const lat = num(s.lat), lng = num(s.lng);
      if (lat === null || lng === null) return;
      pts.push([lat, lng]);
      const icon = L.divIcon({ className: '', html: `<div class="pin${i === selected ? ' sel' : ''}">${i + 1}</div>`, iconSize: [28, 28], iconAnchor: [14, 14] });
      const mk = L.marker([lat, lng], { icon, draggable: true, title: s.name || `Parada ${i + 1}` }).addTo(g);
      mk.on('dragend', () => { const p = mk.getLatLng(); latest.current.onPick(i, round(p.lat), round(p.lng)); });
    });
    // línea por calles si está trazada; si no, recta punteada entre paradas
    if (path && path.length > 1) L.polyline(path, { color: '#0f5b8a', weight: 4, opacity: 0.8 }).addTo(g);
    else if (pts.length > 1) L.polyline(pts, { color: '#0f5b8a', weight: 2, opacity: 0.6, dashArray: '6 8' }).addTo(g);
    via.forEach((v, i) => {
      const icon = L.divIcon({ className: '', html: '<div class="viapin"></div>', iconSize: [16, 16], iconAnchor: [8, 8] });
      const mk = L.marker([v.lat, v.lng], { icon, draggable: true, title: 'Punto de paso: arrastrá para mover, doble clic para quitar' }).addTo(g);
      mk.on('dragend', () => { const p = mk.getLatLng(); onMoveVia(i, round(p.lat), round(p.lng)); });
      mk.on('dblclick', (ev) => { L.DomEvent.stop(ev); onRemoveVia(i); });
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [stops, selected, path, via]);

  // Ajusta la vista solo al abrir (con paradas ya cargadas) para no mover el mapa mientras se edita.
  useEffect(() => {
    const m = map.current;
    if (!m) return;
    const pts = stops.map((s) => [num(s.lat), num(s.lng)] as const).filter((p): p is readonly [number, number] => p[0] !== null && p[1] !== null);
    if (pts.length) m.fitBounds(L.latLngBounds(pts.map((p) => [p[0], p[1]] as L.LatLngTuple)).pad(0.2), { maxZoom: 15 });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const search = async () => {
    if (!query.trim()) return;
    setSearchMsg('Buscando...'); setResults([]);
    try {
      const corner = parseIntersection(query);
      let data: Place[] = [];
      if (corner) {
        const c = map.current?.getCenter();
        data = await findIntersections(corner[0], corner[1], c?.lat ?? -31.7333, c?.lng ?? -60.5236);
      }
      if (!data.length) data = await searchPlaces(query);
      setResults(data);
      setSearchMsg(data.length ? null : corner ? 'No se encontró esa esquina cerca de lo que muestra el mapa. Acercá o movés el mapa a la ciudad y probá de nuevo, o hacé clic directo.' : 'No se encontró ese lugar.');
    } catch { setSearchMsg('No se pudo buscar. Probá de nuevo o ubicá el punto a mano en el mapa.'); }
  };

  const go = (r: { lat: string; lon: string }) => {
    const lat = round(Number(r.lat)), lng = round(Number(r.lon));
    map.current?.setView([lat, lng], 16);
    if (selected !== null) onPick(selected, lat, lng);
    setResults([]);
  };

  return (
    <div className="stack" style={{ gap: 8 }}>
      <div className="row" style={{ alignItems: 'flex-end' }}>
        <label>Buscar lugar
          <input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Terminal de Paraná, o Corrientes y Urquiza"
            onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); void search(); } }} />
        </label>
        <button type="button" className="secondary" onClick={() => void search()}>Buscar</button>
      </div>
      {searchMsg && <p className="muted" style={{ margin: 0 }}>{searchMsg}</p>}
      {results.length > 0 && (
        <ul style={{ margin: 0, padding: 0, listStyle: 'none', display: 'flex', flexDirection: 'column', gap: 4 }}>
          {results.map((r) => <li key={r.display_name}><button type="button" className="secondary" style={{ width: '100%', textAlign: 'left' }} onClick={() => go(r)}>{r.display_name}</button></li>)}
        </ul>
      )}
      <p className="muted" style={{ margin: 0 }}>
        {mode === 'via' ? 'Hacé clic en el mapa para agregar un punto de paso (arrastralo para moverlo, doble clic para quitarlo).'
          : selected === null ? 'Elegí una parada de la lista y hacé clic en el mapa para ubicarla.' : `Ubicando la parada ${selected + 1}: hacé clic en el mapa o arrastrá su marcador.`}
      </p>
      <div ref={el} className="stopmap" role="application" aria-label="Mapa para ubicar paradas" />
    </div>
  );
}
