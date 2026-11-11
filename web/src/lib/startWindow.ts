// Ventana para iniciar una salida: hasta 45 minutos antes o después del horario programado.
// Fuera de la ventana se exige un motivo (igual que public.start_service en la base).
export const WINDOW_MINUTES = 45;

// Minutos que faltan para la salida (positivo) o que pasaron desde ella (negativo). `hhmm` = "08:15" o "08:15:00".
export function minutesToDeparture(hhmm: string, now: Date): number {
  const [h, m] = hhmm.split(':').map(Number);
  const sched = new Date(now.getFullYear(), now.getMonth(), now.getDate(), h, m, 0);
  return Math.round((sched.getTime() - now.getTime()) / 60000);
}

export const needsReason = (minutes: number): boolean => Math.abs(minutes) > WINDOW_MINUTES;

// Salida sugerida: la más cercana en el tiempo (antes o después) entre las del sentido elegido.
export function nearestDeparture<T extends { departure_time: string }>(deps: T[], now: Date): T | null {
  let best: T | null = null, bestAbs = Infinity;
  for (const d of deps) {
    const a = Math.abs(minutesToDeparture(d.departure_time, now));
    if (a < bestAbs) { bestAbs = a; best = d; }
  }
  return best;
}
