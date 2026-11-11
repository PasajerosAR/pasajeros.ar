import { describe, expect, it } from 'vitest';
import {
  addFloor, capacity, cellAt, fromDbRows, newDraft, paint, removeFloor, renumber, resizeFloor,
  summary, toDbRows, updateSeat, validate
} from './seatGrid';

// Combi tipo: fila 0 = conductor + puerta; filas 1-3 = 2 asientos + pasillo + 2 asientos
function combi() {
  let d = newDraft(4, 5);
  d = paint(d, 1, 0, 0, 'driver');
  d = paint(d, 1, 0, 4, 'door');
  for (let r = 1; r < 4; r++) {
    for (const c of [0, 1, 3, 4]) d = paint(d, 1, r, c, 'seat');
    d = paint(d, 1, r, 2, 'aisle');
  }
  return renumber(d);
}

describe('editor de asientos', () => {
  it('numera en orden de lectura y calcula la capacidad desde la grilla', () => {
    const d = combi();
    expect(capacity(d)).toBe(12);
    expect(cellAt(d, 1, 1, 0)?.label).toBe('1');
    expect(cellAt(d, 1, 1, 4)?.label).toBe('4');
    expect(cellAt(d, 1, 3, 4)?.label).toBe('12');
  });

  it('un asiento no utilizable no cuenta en la capacidad', () => {
    const d = updateSeat(combi(), 1, 3, 4, { unusable: true });
    expect(capacity(d)).toBe(11);
    expect(summary(d)).toMatchObject({ seats: 11, unusable: 1, blocked: 0 });
  });

  it('al dejar de ser asiento se borran numero y marcas', () => {
    let d = updateSeat(combi(), 1, 1, 0, { accessible: true });
    d = paint(d, 1, 1, 0, 'empty');
    const c = cellAt(d, 1, 1, 0)!;
    expect(c).toMatchObject({ kind: 'empty', label: null, accessible: false });
  });

  it('updateSeat ignora celdas que no son asientos', () => {
    const d = updateSeat(combi(), 1, 0, 0, { label: 'X', accessible: true });
    expect(cellAt(d, 1, 0, 0)).toMatchObject({ kind: 'driver', label: null, accessible: false });
  });

  it('detecta numeros repetidos, faltantes y disposicion sin asientos', () => {
    expect(validate(newDraft(2, 2))).toEqual(['La disposición no tiene asientos.']);
    const dup = updateSeat(combi(), 1, 3, 4, { label: '1' });
    expect(validate(dup).join(' ')).toContain('El número 1 está repetido 2 veces');
    const missing = updateSeat(combi(), 1, 1, 0, { label: '  ' });
    expect(validate(missing).join(' ')).toContain('asiento sin número');
    expect(validate(combi())).toEqual([]);
  });

  it('permite numeracion manual distinta de la automatica', () => {
    const d = updateSeat(combi(), 1, 1, 0, { label: 'V1' });
    expect(validate(d)).toEqual([]);
    expect(cellAt(d, 1, 1, 0)?.label).toBe('V1');
  });

  it('renumber omite celdas que no son asientos y respeta el orden por piso', () => {
    let d = addFloor(combi());
    d = paint(d, 2, 0, 0, 'seat');
    d = paint(d, 2, 0, 1, 'seat');
    d = renumber(d);
    expect(cellAt(d, 2, 0, 0)?.label).toBe('13');
    expect(cellAt(d, 2, 0, 1)?.label).toBe('14');
    expect(capacity(d)).toBe(14);
  });

  it('agrega y quita el segundo piso; nunca deja menos de un piso ni mas de dos', () => {
    let d = addFloor(newDraft(3, 3));
    expect(d.floors.map((f) => f.floor)).toEqual([1, 2]);
    expect(addFloor(d).floors).toHaveLength(2);
    d = removeFloor(d, 2);
    expect(d.floors).toHaveLength(1);
    expect(d.cells.every((c) => c.floor === 1)).toBe(true);
    expect(removeFloor(d, 1).floors).toHaveLength(1);
  });

  it('resize conserva lo que entra, rellena lo nuevo y descarta lo que sobra', () => {
    let d = paint(newDraft(2, 2), 1, 1, 1, 'seat');
    d = resizeFloor(d, 1, 3, 3);
    expect(d.cells).toHaveLength(9);
    expect(cellAt(d, 1, 1, 1)?.kind).toBe('seat');
    expect(cellAt(d, 1, 2, 2)?.kind).toBe('empty');
    d = resizeFloor(d, 1, 1, 1);
    expect(d.cells).toHaveLength(1);
    expect(cellAt(d, 1, 1, 1)).toBeUndefined();
  });

  it('limita filas y columnas a los maximos', () => {
    const d = resizeFloor(newDraft(2, 2), 1, 999, 999);
    expect(d.floors[0]).toEqual({ floor: 1, rows: 30, cols: 12 });
  });

  it('ida y vuelta con las filas de la base de datos conserva la disposicion', () => {
    let d = updateSeat(combi(), 1, 2, 3, { accessible: true, blocked: true });
    d = updateSeat(d, 1, 3, 4, { unusable: true });
    const rows = toDbRows(d, 'L1', 'C1');
    expect(rows.floors).toEqual([{ layout_id: 'L1', company_id: 'C1', floor: 1, rows: 4, cols: 5 }]);
    expect(rows.cells).toHaveLength(20);
    const back = fromDbRows(
      rows.floors.map((f) => ({ floor: f.floor, rows: f.rows, cols: f.cols })),
      rows.cells.map((c) => ({
        floor: c.floor, row_idx: c.row_idx, col_idx: c.col_idx, kind: c.kind as never,
        label: c.label, accessible: c.accessible, blocked: c.blocked, unusable: c.unusable
      }))
    );
    expect(back).toEqual(d);
  });

  it('toDbRows solo guarda numero en asientos', () => {
    const d = combi();
    const rows = toDbRows(d, 'L', 'C').cells;
    expect(rows.filter((r) => r.kind !== 'seat').every((r) => r.label === null)).toBe(true);
    expect(rows.filter((r) => r.kind === 'seat').every((r) => r.label !== null)).toBe(true);
  });
});
