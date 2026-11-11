// Trazado de un recorrido por calles: paradas + puntos de paso -> línea que sigue las calles (OSRM, datos de OpenStreetMap).

export type LatLng = [number, number]; // [lat, lng]
export interface Via { seg: number; lat: number; lng: number } // punto de paso entre la parada seg y la seg+1
interface StopLike { lat: string; lng: string }

const num = (s: string) => (s.trim() === '' || Number.isNaN(Number(s)) ? null : Number(s));

export function stopCoords(stops: StopLike[]): (LatLng | null)[] {
  return stops.map((s) => { const a = num(s.lat), b = num(s.lng); return a === null || b === null ? null : [a, b]; });
}

// Orden de paso: parada 1, sus puntos de paso, parada 2, ... Devuelve null si falta ubicar alguna parada.
export function buildWaypoints(stops: StopLike[], via: Via[]): LatLng[] | null {
  const pts = stopCoords(stops);
  if (pts.length < 2 || pts.some((p) => p === null)) return null;
  const out: LatLng[] = [];
  pts.forEach((p, i) => {
    out.push(p as LatLng);
    via.filter((v) => v.seg === i).forEach((v) => out.push([v.lat, v.lng]));
  });
  return out;
}

const R = 6371000;
export function meters(a: LatLng, b: LatLng): number {
  const rad = Math.PI / 180;
  const dLat = (b[0] - a[0]) * rad, dLng = (b[1] - a[1]) * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a[0] * rad) * Math.cos(b[0] * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

// A qué tramo (entre paradas consecutivas) pertenece un punto nuevo: el que menos desvío agrega.
export function nearestSegment(stops: StopLike[], p: LatLng): number {
  const pts = stopCoords(stops);
  let best = 0, bestCost = Infinity;
  for (let i = 0; i < pts.length - 1; i++) {
    const a = pts[i], b = pts[i + 1];
    if (!a || !b) continue;
    const cost = meters(a, p) + meters(p, b) - meters(a, b);
    if (cost < bestCost) { bestCost = cost; best = i; }
  }
  return best;
}

// Ordena los puntos de paso de un mismo tramo por su avance de la parada inicial a la final.
export function sortVia(stops: StopLike[], via: Via[]): Via[] {
  const pts = stopCoords(stops);
  const t = (v: Via) => {
    const a = pts[v.seg], b = pts[v.seg + 1];
    if (!a || !b) return 0;
    const dx = b[1] - a[1], dy = b[0] - a[0];
    const len = dx * dx + dy * dy;
    return len === 0 ? 0 : ((v.lng - a[1]) * dx + (v.lat - a[0]) * dy) / len;
  };
  return [...via].sort((x, y) => x.seg - y.seg || t(x) - t(y));
}

// Quita puntos casi repetidos para que el trazado guardado sea liviano (mínimo `min` metros entre puntos).
export function thin(path: LatLng[], min = 4): LatLng[] {
  if (path.length <= 2) return path;
  const out: LatLng[] = [path[0]];
  for (let i = 1; i < path.length - 1; i++) if (meters(out[out.length - 1], path[i]) >= min) out.push(path[i]);
  out.push(path[path.length - 1]);
  return out;
}

export function parseOsrm(data: unknown): LatLng[] {
  const d = data as { code?: string; message?: string; routes?: { geometry?: { coordinates?: number[][] } }[] };
  if (d.code !== 'Ok' || !d.routes?.[0]?.geometry?.coordinates?.length) throw new Error(d.message ?? 'Sin camino entre las paradas');
  return thin(d.routes[0].geometry.coordinates.map(([lng, lat]) => [Math.round(lat * 1e5) / 1e5, Math.round(lng * 1e5) / 1e5] as LatLng));
}

export async function routeByStreets(points: LatLng[]): Promise<LatLng[]> {
  if (points.length > 90) throw new Error('Demasiados puntos para trazar');
  const coords = points.map(([lat, lng]) => `${lng},${lat}`).join(';');
  const r = await fetch(`https://router.project-osrm.org/route/v1/driving/${coords}?overview=full&geometries=geojson`);
  const data = await r.json().catch(() => ({}));
  return parseOsrm(data);
}
