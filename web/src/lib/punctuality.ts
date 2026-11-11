// Puntualidad respecto del horario programado.
// Convencion del documento: positivo = adelanto (o faltan N min), 0 = en horario, negativo = atraso.

export function punctualityMinutes(scheduled: Date, actual: Date): number {
  return Math.round((scheduled.getTime() - actual.getTime()) / 60000);
}

export type PunctualityState = 'early' | 'on_time' | 'late';

export function punctualityState(minutes: number): PunctualityState {
  if (minutes > 0) return 'early';
  if (minutes < 0) return 'late';
  return 'on_time';
}

// 5 -> "5 minutos"; 90 -> "1 h 30 min"
export function formatSpan(n: number): string {
  if (n < 60) return `${n} ${n === 1 ? 'minuto' : 'minutos'}`;
  const h = Math.floor(n / 60);
  const m = n % 60;
  return m ? `${h} h ${m} min` : `${h} h`;
}

export function formatPunctuality(minutes: number, beforeDeparture: boolean): string {
  if (minutes === 0) return 'En horario';
  const span = formatSpan(Math.abs(minutes));
  if (minutes > 0) return beforeDeparture ? `Faltan ${span}` : `${span} de adelanto`;
  return `${span} de atraso`;
}

export function formatSigned(minutes: number): string {
  return minutes > 0 ? `+${minutes}` : String(minutes);
}
