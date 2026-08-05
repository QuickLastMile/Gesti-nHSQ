import test from 'node:test';
import assert from 'node:assert/strict';
import { planCleanup } from './cleanup-evidencias.mjs';

test('conserva el documento vigente y elimina versiones anteriores', () => {
  const result = planCleanup({
    documents: [
      { id: 1, pregunta_id: 'DOC_SOAT', storage_path: 'documentos/123/SOAT_v1.pdf', subido_en: '2026-01-01T00:00:00Z' },
      { id: 2, pregunta_id: 'DOC_SOAT', storage_path: 'documentos/123/SOAT_v2.pdf', subido_en: '2026-06-01T00:00:00Z' },
      { id: 3, pregunta_id: 'DOC_TECNOMECANICA', storage_path: 'documentos/123/TECNO_v1.jpg', subido_en: '2026-02-01T00:00:00Z' },
    ],
    protectedPaths: ['documentos/123/SOAT_v2.pdf'],
  });
  assert.deepEqual(result.paths, ['documentos/123/SOAT_v1.pdf']);
  assert.equal(result.replacedDocumentCount, 1);
});

test('elimina evidencia diaria vencida sin tocar documentos', () => {
  const result = planCleanup({
    oldDaily: [
      { id: 10, pregunta_id: 'LIM_010', storage_path: '123/2025-01-01/limpieza.jpg' },
      { id: 11, pregunta_id: 'DOC_SOAT', storage_path: 'documentos/123/SOAT.pdf' },
    ],
  });
  assert.deepEqual(result.paths, ['123/2025-01-01/limpieza.jpg']);
  assert.equal(result.dailyCount, 1);
});

test('nunca elimina una ruta protegida aunque aparezca en un registro antiguo', () => {
  const result = planCleanup({
    documents: [
      { id: 20, pregunta_id: 'DOC_LICENCIA_TRANSITO', storage_path: 'documentos/123/licencia-vigente.jpg', subido_en: '2026-01-01T00:00:00Z' },
      { id: 21, pregunta_id: 'DOC_LICENCIA_TRANSITO', storage_path: 'documentos/123/licencia-nueva.jpg', subido_en: '2026-02-01T00:00:00Z' },
    ],
    protectedPaths: ['documentos/123/licencia-vigente.jpg'],
  });
  assert.deepEqual(result.paths, []);
});

