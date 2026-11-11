// Búsqueda de lugares: direcciones y puntos con Nominatim, y esquinas ("Corrientes y Rosario del Tala") con Overpass.
// Ambos servicios son públicos de OpenStreetMap: uso liviano, una búsqueda por clic.

export interface Place { display_name: string; lat: string; lon: string }

// "Corrientes y Rosario del Tala" -> ['Corrientes', 'Rosario del Tala']; si no parece una esquina, null.
export function parseIntersection(q: string): [string, string] | null {
  const parts = q.trim().split(/\s+(?:y|e|esq\.?|esquina|con|&|\/)\s+/i).map((p) => p.replace(/^(?:esquina|esq\.?)\s+/i, '').trim()).filter(Boolean);
  return parts.length === 2 ? [parts[0], parts[1]] : null;
}

const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\"]/g, '\\$&');

export function intersectionQuery(a: string, b: string, lat: number, lng: number, d = 0.12): string {
  const box = `${lat - d},${lng - d},${lat + d},${lng + d}`;
  return `[out:json][timeout:20];` +
    `way["highway"]["name"~"${esc(a)}",i](${box})->.a;` +
    `way["highway"]["name"~"${esc(b)}",i](${box})->.b;` +
    `node(w.a)(w.b);out;`;
}

// Esquinas cercanas al centro dado (el mapa que está viendo la persona).
export async function findIntersections(a: string, b: string, lat: number, lng: number): Promise<Place[]> {
  const r = await fetch('https://overpass-api.de/api/interpreter', { method: 'POST', body: 'data=' + encodeURIComponent(intersectionQuery(a, b, lat, lng)) });
  if (!r.ok) throw new Error('overpass');
  const data = (await r.json()) as { elements: { lat: number; lon: number }[] };
  // varias calles homónimas o cruces dobles: se descartan puntos casi repetidos
  const out: Place[] = [];
  for (const n of data.elements) {
    if (out.some((p) => Math.abs(Number(p.lat) - n.lat) < 0.0003 && Math.abs(Number(p.lon) - n.lon) < 0.0003)) continue;
    out.push({ display_name: `Esquina de ${a} y ${b} (${n.lat.toFixed(5)}, ${n.lon.toFixed(5)})`, lat: String(n.lat), lon: String(n.lon) });
  }
  return out.slice(0, 5);
}

export async function searchPlaces(q: string): Promise<Place[]> {
  const r = await fetch(`https://nominatim.openstreetmap.org/search?format=json&limit=5&countrycodes=ar&accept-language=es&q=${encodeURIComponent(q)}`);
  if (!r.ok) throw new Error('nominatim');
  return (await r.json()) as Place[];
}
