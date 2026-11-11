import { describe, expect, it } from 'vitest';
import { dayTypeOf, dayTypesText } from './dayType';
import { minutesToDeparture, nearestDeparture, needsReason } from './startWindow';
import { nextScheduledStop } from './tripProgress';

const at = (hh: number, mm: number) => new Date(2026, 10, 14, hh, mm, 0);

describe('tipo de día', () => {
  it('lunes a viernes = hábil, sábado, domingo', () => {
    expect(dayTypeOf(new Date(2026, 10, 16))).toBe('weekday'); // lunes
    expect(dayTypeOf(new Date(2026, 10, 20))).toBe('weekday'); // viernes
    expect(dayTypeOf(new Date(2026, 10, 14))).toBe('saturday');
    expect(dayTypeOf(new Date(2026, 10, 15))).toBe('sunday');
  });
  it('texto en orden fijo', () => {
    expect(dayTypesText(['holiday', 'weekday'])).toBe('Día hábil, Feriado');
  });
});

describe('ventana de inicio', () => {
  it('minutos hasta la salida: faltan (+) o pasaron (-)', () => {
    expect(minutesToDeparture('18:00:00', at(17, 50))).toBe(10);
    expect(minutesToDeparture('18:00', at(18, 20))).toBe(-20);
  });
  it('pide motivo si se pasa de 45 minutos hacia cualquier lado', () => {
    expect(needsReason(45)).toBe(false);
    expect(needsReason(-45)).toBe(false);
    expect(needsReason(46)).toBe(true);
    expect(needsReason(-46)).toBe(true);
  });
  it('sugiere la salida más cercana', () => {
    const deps = [{ departure_time: '06:00:00' }, { departure_time: '12:00:00' }, { departure_time: '18:00:00' }];
    expect(nearestDeparture(deps, at(11, 0))?.departure_time).toBe('12:00:00');
    expect(nearestDeparture(deps, at(16, 0))?.departure_time).toBe('18:00:00');
    expect(nearestDeparture([], at(11, 0))).toBeNull();
  });
});

describe('próxima parada por reloj (solo horarios programados)', () => {
  const stops = [
    { id: 'a', name: 'Paraná', position: 1, minutes_from_start: 0, dwell_minutes: 0 },
    { id: 'b', name: 'Colonia Avellaneda', position: 2, minutes_from_start: 20, dwell_minutes: 2 },
    { id: 'c', name: 'Santa Fe', position: 3, minutes_from_start: 100, dwell_minutes: 0 }
  ];
  it('antes de salir ya muestra la primera parada con su horario programado', () => {
    const n = nextScheduledStop(stops, at(18, 0), at(17, 49));
    expect(n?.stop.name).toBe('Colonia Avellaneda');
    expect(n?.scheduled).toEqual(at(18, 20));
  });
  it('pasa a la siguiente cuando se cumple el horario programado', () => {
    expect(nextScheduledStop(stops, at(18, 0), at(18, 19))?.stop.name).toBe('Colonia Avellaneda');
    expect(nextScheduledStop(stops, at(18, 0), at(18, 30))?.stop.name).toBe('Santa Fe');
  });
  it('pasados todos los horarios queda la última parada (no decide si llegó: eso lo marca el GPS)', () => {
    expect(nextScheduledStop(stops, at(18, 0), at(20, 0))?.stop.name).toBe('Santa Fe');
  });
  it('sin tiempos cargados no inventa horarios', () => {
    expect(nextScheduledStop([], at(18, 0), at(18, 5))).toBeNull();
  });
});
