// Próxima parada según el reloj, solo con los horarios programados de la carga del servicio.
// Se usa antes de salir o si no hay GPS. No proyecta horas estimadas: el adelanto o atraso lo marca el GPS.
export interface TimedStop { id: string; name: string; position: number; minutes_from_start: number; dwell_minutes: number }

const addMin = (d: Date, m: number) => new Date(d.getTime() + m * 60000);

// Primera parada (sin contar la de salida) cuyo horario programado todavía no pasó; si ya pasaron todos, la última.
export function nextScheduledStop(stops: TimedStop[], scheduled: Date, now: Date): { stop: TimedStop; scheduled: Date } | null {
  const ordered = [...stops].sort((a, b) => a.position - b.position).slice(1);
  if (ordered.length === 0) return null;
  const at = (s: TimedStop) => addMin(scheduled, s.minutes_from_start);
  const stop = ordered.find((s) => at(s).getTime() > now.getTime()) ?? ordered[ordered.length - 1];
  return { stop, scheduled: at(stop) };
}
