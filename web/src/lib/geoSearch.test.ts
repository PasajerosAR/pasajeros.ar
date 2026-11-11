import { describe, expect, it } from 'vitest';
import { intersectionQuery, parseIntersection } from './geoSearch';

describe('búsqueda de esquinas', () => {
  it('reconoce las formas habituales de escribir una esquina', () => {
    expect(parseIntersection('Corrientes y Rosario del Tala')).toEqual(['Corrientes', 'Rosario del Tala']);
    expect(parseIntersection('Corrientes esquina Rosario del Tala')).toEqual(['Corrientes', 'Rosario del Tala']);
    expect(parseIntersection('Corrientes & Urquiza')).toEqual(['Corrientes', 'Urquiza']);
    expect(parseIntersection('Esq. Corrientes y Urquiza')).toEqual(['Corrientes', 'Urquiza']);
  });
  it('no confunde un lugar común con una esquina', () => {
    expect(parseIntersection('Terminal de Paraná')).toBeNull();
    expect(parseIntersection('Yerba Mate')).toBeNull();
    expect(parseIntersection('Avenida Ramírez 123')).toBeNull();
  });
  it('arma la consulta con el área alrededor del mapa', () => {
    const q = intersectionQuery('Corrientes', 'Urquiza', -31.73, -60.52);
    expect(q).toContain('["name"~"Corrientes",i]');
    expect(q).toContain('node(w.a)(w.b)');
  });
});
