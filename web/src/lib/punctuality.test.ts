import { describe, expect, it } from 'vitest';
import { formatPunctuality, formatSigned, punctualityMinutes, punctualityState } from './punctuality';

const at = (hh: number, mm: number) => new Date(2026, 10, 14, hh, mm, 0);

describe('puntualidad (positivo = adelanto, negativo = atraso)', () => {
  it('antes de la salida faltan minutos: 17:55 con salida 18:00 = +5', () => {
    expect(punctualityMinutes(at(18, 0), at(17, 55))).toBe(5);
  });

  it('salida real a las 18:02 con programada 18:00 = -2 (atraso)', () => {
    expect(punctualityMinutes(at(18, 0), at(18, 2))).toBe(-2);
  });

  it('salida real a las 17:57 = +3 (adelanto); en punto = 0', () => {
    expect(punctualityMinutes(at(18, 0), at(17, 57))).toBe(3);
    expect(punctualityMinutes(at(18, 0), at(18, 0))).toBe(0);
  });

  it('redondea al minuto mas cercano', () => {
    expect(punctualityMinutes(at(18, 0), new Date(2026, 10, 14, 18, 1, 40))).toBe(-2);
    expect(punctualityMinutes(at(18, 0), new Date(2026, 10, 14, 18, 1, 10))).toBe(-1);
  });

  it('estados y textos', () => {
    expect(punctualityState(5)).toBe('early');
    expect(punctualityState(0)).toBe('on_time');
    expect(punctualityState(-2)).toBe('late');
    expect(formatPunctuality(5, true)).toBe('Faltan 5 minutos');
    expect(formatPunctuality(1, true)).toBe('Faltan 1 minuto');
    expect(formatPunctuality(3, false)).toBe('3 minutos de adelanto');
    expect(formatPunctuality(-2, false)).toBe('2 minutos de atraso');
    expect(formatPunctuality(0, false)).toBe('En horario');
    expect(formatPunctuality(687, true)).toBe('Faltan 11 h 27 min');
    expect(formatPunctuality(120, true)).toBe('Faltan 2 h');
    expect(formatPunctuality(-75, false)).toBe('1 h 15 min de atraso');
    expect(formatSigned(3)).toBe('+3');
    expect(formatSigned(-2)).toBe('-2');
    expect(formatSigned(0)).toBe('0');
  });
});
