// Logica pura del editor de disposicion de asientos (sin React ni red), para poder probarla.

export type CellKind = 'seat' | 'aisle' | 'empty' | 'driver' | 'door' | 'stairs' | 'toilet' | 'trunk';

export interface Cell {
  floor: number;
  row: number;
  col: number;
  kind: CellKind;
  label: string | null;
  accessible: boolean;
  blocked: boolean;
  unusable: boolean;
}

export interface FloorDims {
  floor: number;
  rows: number;
  cols: number;
}

export interface LayoutDraft {
  floors: FloorDims[];
  cells: Cell[];
}

export const MAX_ROWS = 30;
export const MAX_COLS = 12;

const blank = (floor: number, row: number, col: number): Cell => ({
  floor, row, col, kind: 'empty', label: null, accessible: false, blocked: false, unusable: false
});

export function emptyFloor(floor: number, rows: number, cols: number): { dims: FloorDims; cells: Cell[] } {
  const cells: Cell[] = [];
  for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) cells.push(blank(floor, r, c));
  return { dims: { floor, rows, cols }, cells };
}

export function newDraft(rows = 5, cols = 5): LayoutDraft {
  const f = emptyFloor(1, rows, cols);
  return { floors: [f.dims], cells: f.cells };
}

export function cellAt(d: LayoutDraft, floor: number, row: number, col: number): Cell | undefined {
  return d.cells.find((c) => c.floor === floor && c.row === row && c.col === col);
}

/** Cambia el tipo de una celda. Si deja de ser asiento se borran numero y marcas. */
export function paint(d: LayoutDraft, floor: number, row: number, col: number, kind: CellKind): LayoutDraft {
  return {
    ...d,
    cells: d.cells.map((c) => {
      if (c.floor !== floor || c.row !== row || c.col !== col) return c;
      if (kind === 'seat') return { ...c, kind };
      return { ...c, kind, label: null, accessible: false, blocked: false, unusable: false };
    })
  };
}

export function updateSeat(
  d: LayoutDraft, floor: number, row: number, col: number,
  patch: Partial<Pick<Cell, 'label' | 'accessible' | 'blocked' | 'unusable'>>
): LayoutDraft {
  return {
    ...d,
    cells: d.cells.map((c) =>
      c.floor === floor && c.row === row && c.col === col && c.kind === 'seat' ? { ...c, ...patch } : c)
  };
}

/** Cambia filas y columnas de un piso: conserva lo que entra y rellena con celdas vacias. */
export function resizeFloor(d: LayoutDraft, floor: number, rows: number, cols: number): LayoutDraft {
  const r = Math.min(Math.max(rows, 1), MAX_ROWS);
  const c = Math.min(Math.max(cols, 1), MAX_COLS);
  const kept = d.cells.filter((x) => x.floor !== floor || (x.row < r && x.col < c));
  for (let i = 0; i < r; i++) {
    for (let j = 0; j < c; j++) {
      if (!kept.some((x) => x.floor === floor && x.row === i && x.col === j)) kept.push(blank(floor, i, j));
    }
  }
  const floors = d.floors.some((f) => f.floor === floor)
    ? d.floors.map((f) => (f.floor === floor ? { floor, rows: r, cols: c } : f))
    : [...d.floors, { floor, rows: r, cols: c }];
  return { floors: floors.sort((a, b) => a.floor - b.floor), cells: sortCells(kept) };
}

export function addFloor(d: LayoutDraft): LayoutDraft {
  if (d.floors.length >= 2) return d;
  const base = d.floors[0];
  return resizeFloor(d, 2, base.rows, base.cols);
}

export function removeFloor(d: LayoutDraft, floor: number): LayoutDraft {
  if (d.floors.length <= 1) return d;
  return { floors: d.floors.filter((f) => f.floor !== floor), cells: d.cells.filter((c) => c.floor !== floor) };
}

function sortCells(cells: Cell[]): Cell[] {
  return [...cells].sort((a, b) => a.floor - b.floor || a.row - b.row || a.col - b.col);
}

/** Numera todos los asientos en orden de lectura (piso, fila, columna). */
export function renumber(d: LayoutDraft): LayoutDraft {
  let n = 0;
  const numbered = sortCells(d.cells).map((c) => (c.kind === 'seat' ? { ...c, label: String(++n) } : c));
  return { ...d, cells: numbered };
}

/** Capacidad real: asientos que no estan marcados como no utilizables. */
export function capacity(d: LayoutDraft): number {
  return d.cells.filter((c) => c.kind === 'seat' && !c.unusable).length;
}

export function summary(d: LayoutDraft) {
  const seats = d.cells.filter((c) => c.kind === 'seat');
  return {
    seats: capacity(d),
    accessible: seats.filter((c) => c.accessible).length,
    blocked: seats.filter((c) => c.blocked).length,
    unusable: seats.filter((c) => c.unusable).length
  };
}

/** Devuelve la lista de problemas que impiden guardar. Vacia si esta bien. */
export function validate(d: LayoutDraft): string[] {
  const errors: string[] = [];
  const seats = d.cells.filter((c) => c.kind === 'seat');
  if (seats.length === 0) errors.push('La disposición no tiene asientos.');
  const seen = new Map<string, number>();
  for (const s of seats) {
    const label = (s.label ?? '').trim();
    if (!label) { errors.push(`Hay un asiento sin número (piso ${s.floor}, fila ${s.row + 1}, columna ${s.col + 1}).`); continue; }
    seen.set(label, (seen.get(label) ?? 0) + 1);
  }
  for (const [label, n] of seen) if (n > 1) errors.push(`El número ${label} está repetido ${n} veces.`);
  return errors;
}

/** Filas listas para insertar en la base. */
export function toDbRows(d: LayoutDraft, layoutId: string, companyId: string) {
  return {
    floors: d.floors.map((f) => ({ layout_id: layoutId, company_id: companyId, floor: f.floor, rows: f.rows, cols: f.cols })),
    cells: d.cells.map((c) => ({
      layout_id: layoutId, company_id: companyId, floor: c.floor, row_idx: c.row, col_idx: c.col,
      kind: c.kind, label: c.kind === 'seat' ? (c.label ?? '').trim() || null : null,
      accessible: c.accessible, blocked: c.blocked, unusable: c.unusable
    }))
  };
}

export interface DbFloor { floor: number; rows: number; cols: number }
export interface DbCell {
  floor: number; row_idx: number; col_idx: number; kind: CellKind; label: string | null;
  accessible: boolean; blocked: boolean; unusable: boolean;
}

export function fromDbRows(floors: DbFloor[], cells: DbCell[]): LayoutDraft {
  const draft: LayoutDraft = { floors: [...floors].sort((a, b) => a.floor - b.floor), cells: [] };
  for (const f of draft.floors) draft.cells.push(...emptyFloor(f.floor, f.rows, f.cols).cells);
  for (const c of cells) {
    const target = draft.cells.find((x) => x.floor === c.floor && x.row === c.row_idx && x.col === c.col_idx);
    if (target) Object.assign(target, {
      kind: c.kind, label: c.label, accessible: c.accessible, blocked: c.blocked, unusable: c.unusable
    });
  }
  return draft;
}
