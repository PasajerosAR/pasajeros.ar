// Las funciones del servidor devuelven errores como "CODIGO: mensaje en espanol".
export function friendly(err: unknown): string {
  const raw = typeof err === 'object' && err && 'message' in err ? String((err as { message: unknown }).message) : String(err);
  const m = raw.match(/^[A-Z_]{4,}:\s*(.+)$/s);
  if (m) return m[1];
  if (raw.includes('row-level security')) return 'No tenés permiso para hacer esto.';
  if (raw.includes('duplicate key')) return 'Ya existe un registro con esos datos.';
  if (/^[A-Z_]{4,}$/.test(raw)) return CODES[raw] ?? raw;
  return raw;
}

const CODES: Record<string, string> = {
  FORBIDDEN: 'No tenés permiso para hacer esto.',
  NOT_FOUND: 'No se encontró el registro.',
  NO_OPEN_SHIFT: 'Iniciá la jornada primero.',
  INVALID_QUANTITY: 'La cantidad no es válida.',
  REASON_REQUIRED: 'Indicá el motivo.'
};

export function errorCode(err: unknown): string | null {
  const raw = typeof err === 'object' && err && 'message' in err ? String((err as { message: unknown }).message) : '';
  const m = raw.match(/^([A-Z_]{4,})/);
  return m ? m[1] : null;
}
