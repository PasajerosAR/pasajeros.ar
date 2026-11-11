import { describe, expect, it } from 'vitest';
import { liveProgress, type LiveStop } from './gpsProgress';
import type { LatLng } from './routePath';

const at = (hh: number, mm: number, ss = 0) => new Date(2026, 10, 14, hh, mm, ss);

// Recorrido recto sobre un meridiano: 0,01 grados de latitud son unos 1.112 m.
const A: LatLng = [-31.70, -60.5], B: LatLng = [-31.71, -60.5], C: LatLng = [-31.72, -60.5];
const path: LatLng[] = [A, B, C];
const mk = (dwellB = 0): LiveStop[] => [
  { id: 'a', name: 'Salida', lat: A[0], lng: A[1], minutes_from_start: 0, dwell_minutes: 0 },
  { id: 'b', name: 'Rectorado UNL', lat: B[0], lng: B[1], minutes_from_start: 10, dwell_minutes: dwellB },
  { id: 'c', name: 'Destino', lat: C[0], lng: C[1], minutes_from_start: 20, dwell_minutes: 0 }
];
const prog = at(23, 30); // salida programada 23:30; la parada B es a las 23:40

describe('puntualidad por GPS (positivo = adelanto, negativo = atraso)', () => {
  it('en la parada a la hora programada = 0', () => {
    expect(liveProgress(path, mk(), prog, at(23, 40), B).mins).toBe(0);
  });
  it('llega a la parada 4 minutos antes = +4', () => {
    expect(liveProgress(path, mk(), prog, at(23, 36), B).mins).toBe(4);
  });
  it('llega a la parada 2 minutos tarde = -2', () => {
    expect(liveProgress(path, mk(), prog, at(23, 42), B).mins).toBe(-2);
  });
  it('a mitad de tramo se compara con el horario interpolado (23:35)', () => {
    const mid: LatLng = [-31.705, -60.5];
    expect(liveProgress(path, mk(), prog, at(23, 35), mid).mins).toBe(0);
    expect(liveProgress(path, mk(), prog, at(23, 34), mid).mins).toBe(1);
    expect(liveProgress(path, mk(), prog, at(23, 38), mid).mins).toBe(-3);
  });
  it('parado en la parada de salida pasada la hora: el atraso crece', () => {
    expect(liveProgress(path, mk(), prog, at(23, 32), A).mins).toBe(-2);
    expect(liveProgress(path, mk(), prog, at(23, 37), A).mins).toBe(-7);
  });
  it('la permanencia en la parada no cuenta como atraso', () => {
    expect(liveProgress(path, mk(3), prog, at(23, 42), B).mins).toBe(0); // 23:40 a 23:43 es su permanencia
    expect(liveProgress(path, mk(3), prog, at(23, 44), B).mins).toBe(-1);
  });
  it('fuera del recorrido no calcula puntualidad', () => {
    const r = liveProgress(path, mk(), prog, at(23, 40), [-31.705, -60.48]);
    expect(r.offRoute).toBe(true);
    expect(r.mins).toBeNull();
  });
  it('próxima parada según la posición: nunca es la que ya se pasó', () => {
    expect(liveProgress(path, mk(), prog, at(23, 31), A).nextIndex).toBe(1);
    expect(liveProgress(path, mk(), prog, at(23, 35), [-31.705, -60.5]).nextIndex).toBe(1);
    expect(liveProgress(path, mk(), prog, at(23, 45), [-31.715, -60.5]).nextIndex).toBe(2);
    expect(liveProgress(path, mk(), prog, at(23, 50), C).nextIndex).toBeNull(); // llegó al destino
  });
});
