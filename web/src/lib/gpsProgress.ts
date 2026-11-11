// Puntualidad en ruta calculada con el GPS.
// El horario a cumplir es el de la carga del servicio: salida programada + minutes_from_start de cada parada.
// La posicion del vehiculo se ubica sobre el recorrido; el horario programado en ese punto, comparado con la
// hora actual, da el adelanto (+) o el atraso (-) en minutos. No se proyectan horas estimadas.
import { meters, type LatLng } from './routePath';

export interface LiveStop { id: string; name: string; lat: number; lng: number; minutes_from_start: number; dwell_minutes: number }

export const AT_STOP_M = 40;     // a menos de esta distancia de una parada se considera "en la parada"
export const OFF_ROUTE_M = 500;  // a mas de esta distancia del recorrido no se calcula la puntualidad

// Metros acumulados a lo largo del recorrido, en cada vertice.
export function cumulative(path: LatLng[]): number[] {
  const c = [0];
  for (let i = 1; i < path.length; i++) c.push(c[i - 1] + meters(path[i - 1], path[i]));
  return c;
}

// Proyecta p sobre el segmento a-b (plano local, suficiente para tramos cortos). t va de 0 a 1.
function onSegment(a: LatLng, b: LatLng, p: LatLng): { t: number; dist: number } {
  const k = Math.cos((a[0] * Math.PI) / 180);
  const bx = (b[1] - a[1]) * k, by = b[0] - a[0];
  const px = (p[1] - a[1]) * k, py = p[0] - a[0];
  const len2 = bx * bx + by * by;
  const t = len2 === 0 ? 0 : Math.max(0, Math.min(1, (px * bx + py * by) / len2));
  const q: LatLng = [a[0] + by * t, a[1] + (bx * t) / k];
  return { t, dist: meters(q, p) };
}

export interface Projection { along: number; off: number; seg: number }

// Punto del recorrido mas cercano a p: metros recorridos (along), distancia al recorrido (off) y tramo (seg).
// fromSeg evita mirar tramos anteriores (sirve para ubicar las paradas en orden).
export function project(path: LatLng[], cum: number[], p: LatLng, fromSeg = 0): Projection {
  let best: Projection = { along: 0, off: Infinity, seg: fromSeg };
  for (let i = fromSeg; i < path.length - 1; i++) {
    const { t, dist } = onSegment(path[i], path[i + 1], p);
    if (dist < best.off) best = { along: cum[i] + t * (cum[i + 1] - cum[i]), off: dist, seg: i };
  }
  return best;
}

// Metros recorridos en que cae cada parada (en el orden dado).
export function stopsAlong(path: LatLng[], cum: number[], stops: LiveStop[]): number[] {
  let seg = 0;
  return stops.map((s) => {
    const pr = project(path, cum, [s.lat, s.lng], seg);
    seg = pr.seg;
    return pr.along;
  });
}

// Minuto (contado desde la salida programada) en que el servicio deberia estar en el punto `along`.
// En una parada vale cualquier momento dentro de su permanencia; entre paradas se interpola por distancia.
export function scheduledOffset(stops: LiveStop[], A: number[], along: number, nowOffset: number): number {
  const n = stops.length;
  const arr = (i: number) => stops[i].minutes_from_start;
  const dep = (i: number) => (i === n - 1 ? arr(i) : Math.min(arr(i) + stops[i].dwell_minutes, arr(i + 1)));
  for (let i = 0; i < n; i++) {
    if (Math.abs(along - A[i]) <= AT_STOP_M) return Math.min(Math.max(nowOffset, arr(i)), dep(i));
  }
  if (along <= A[0]) return arr(0);
  if (along >= A[n - 1]) return arr(n - 1);
  let i = 0;
  while (i < n - 2 && along >= A[i + 1]) i++;
  const span = A[i + 1] - A[i];
  const f = span <= 0 ? 0 : (along - A[i]) / span;
  return dep(i) + f * (arr(i + 1) - dep(i));
}

// Indice de la proxima parada que todavia no se alcanzo; null si ya llego a la ultima.
export function nextStopIndex(A: number[], along: number): number | null {
  for (let i = 0; i < A.length; i++) if (A[i] - AT_STOP_M > along) return i;
  return null;
}

export interface LiveResult {
  mins: number | null;       // positivo = adelanto, negativo = atraso; null si el vehiculo esta fuera del recorrido
  nextIndex: number | null;  // indice en `stops` de la proxima parada; null = llego al destino
  offRoute: boolean;
}

export function liveProgress(path: LatLng[], stops: LiveStop[], scheduled: Date, now: Date, pos: LatLng): LiveResult {
  const cum = cumulative(path);
  const A = stopsAlong(path, cum, stops);
  const pr = project(path, cum, pos);
  const nowOffset = (now.getTime() - scheduled.getTime()) / 60000;
  const nextIndex = nextStopIndex(A, pr.along);
  if (pr.off > OFF_ROUTE_M) return { mins: null, nextIndex, offRoute: true };
  const mins = Math.round(scheduledOffset(stops, A, pr.along, nowOffset) - nowOffset) || 0; // `|| 0` evita -0
  return { mins, nextIndex, offRoute: false };
}
