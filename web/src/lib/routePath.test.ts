import { describe, expect, it } from 'vitest';
import { buildWaypoints, meters, nearestSegment, parseOsrm, sortVia, thin } from './routePath';

const stops = [
  { lat: '-31.73', lng: '-60.52' }, // 0 Paraná
  { lat: '-31.70', lng: '-60.30' }, // 1 intermedia
  { lat: '-31.63', lng: '-60.70' }  // 2 Santa Fe
];

describe('trazado por calles', () => {
  it('ordena paradas y puntos de paso', () => {
    const wp = buildWaypoints(stops, [{ seg: 1, lat: -31.66, lng: -60.5 }, { seg: 0, lat: -31.71, lng: -60.4 }]);
    expect(wp).toEqual([[-31.73, -60.52], [-31.71, -60.4], [-31.7, -60.3], [-31.66, -60.5], [-31.63, -60.7]]);
  });
  it('no traza si falta ubicar una parada', () => {
    expect(buildWaypoints([stops[0], { lat: '', lng: '' }, stops[2]], [])).toBeNull();
    expect(buildWaypoints([stops[0]], [])).toBeNull();
  });
  it('asigna el punto nuevo al tramo que menos desvío agrega', () => {
    expect(nearestSegment(stops, [-31.71, -60.4])).toBe(0);
    expect(nearestSegment(stops, [-31.66, -60.5])).toBe(1);
  });
  it('ordena varios puntos de un mismo tramo según el avance', () => {
    const v = sortVia(stops, [{ seg: 0, lat: -31.7, lng: -60.35 }, { seg: 0, lat: -31.72, lng: -60.45 }]);
    expect(v.map((x) => x.lng)).toEqual([-60.45, -60.35]);
  });
  it('distancia aproximada: 0.01 grados de latitud ≈ 1.1 km', () => {
    expect(Math.round(meters([-31.73, -60.52], [-31.72, -60.52]))).toBeGreaterThan(1050);
    expect(Math.round(meters([-31.73, -60.52], [-31.72, -60.52]))).toBeLessThan(1150);
  });
  it('quita puntos casi repetidos pero conserva extremos', () => {
    const p: [number, number][] = [[-31.73, -60.52], [-31.730001, -60.520001], [-31.72, -60.52], [-31.7200001, -60.52], [-31.71, -60.52]];
    expect(thin(p)).toEqual([[-31.73, -60.52], [-31.72, -60.52], [-31.71, -60.52]]);
  });
  it('lee la respuesta de OSRM (lng,lat -> lat,lng) y falla si no hay camino', () => {
    expect(parseOsrm({ code: 'Ok', routes: [{ geometry: { coordinates: [[-60.52, -31.73], [-60.3, -31.7]] } }] })).toEqual([[-31.73, -60.52], [-31.7, -60.3]]);
    expect(() => parseOsrm({ code: 'NoRoute', message: 'Impossible route' })).toThrow('Impossible route');
  });
});
