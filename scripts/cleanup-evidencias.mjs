const DOC_IDS = new Set(['DOC_SOAT', 'DOC_TECNOMECANICA', 'DOC_LICENCIA_TRANSITO']);
const PAGE_SIZE = 1000;
const DELETE_BATCH = 100;

function required(name) {
  const value = String(process.env[name] || '').trim();
  if (!value) throw new Error(`Falta la variable ${name}.`);
  return value.replace(/\/$/, '');
}

function chunks(items, size) {
  const result = [];
  for (let i = 0; i < items.length; i += size) result.push(items.slice(i, i + size));
  return result;
}

function decodedPath(path) {
  return String(path || '').split('/').map((part) => {
    try { return decodeURIComponent(part); } catch (_) { return part; }
  }).join('/').replace(/^\/+/, '');
}

function pathFromUrl(value) {
  if (!value) return '';
  try {
    const pathname = new URL(value).pathname;
    const marker = '/evidencias/';
    const pos = pathname.indexOf(marker);
    return pos < 0 ? '' : decodedPath(pathname.slice(pos + marker.length));
  } catch (_) {
    return '';
  }
}

function docGroup(row) {
  const path = decodedPath(row.storage_path);
  const parts = path.split('/');
  if (parts[0] !== 'documentos' || !parts[1] || !DOC_IDS.has(row.pregunta_id)) return '';
  return `${parts[1]}|${row.pregunta_id}`;
}

export function planCleanup({ oldDaily = [], documents = [], protectedPaths = [] }) {
  const protectedSet = new Set(protectedPaths.map(decodedPath).filter(Boolean));
  const keepPaths = new Set(protectedSet);
  const groups = new Map();

  for (const row of documents) {
    const group = docGroup(row);
    const path = decodedPath(row.storage_path);
    if (!group || !path) continue;
    if (!groups.has(group)) groups.set(group, []);
    groups.get(group).push({ ...row, normalized_path: path });
  }

  for (const rows of groups.values()) {
    rows.sort((a, b) => String(b.subido_en || '').localeCompare(String(a.subido_en || '')) || Number(b.id) - Number(a.id));
    if (rows[0]) keepPaths.add(rows[0].normalized_path);
  }

  const candidates = [];
  for (const row of oldDaily) {
    const path = decodedPath(row.storage_path);
    if (path && !DOC_IDS.has(row.pregunta_id)) candidates.push({ ...row, normalized_path: path, reason: 'retencion_diaria' });
  }
  for (const rows of groups.values()) {
    for (const row of rows.slice(1)) {
      if (!keepPaths.has(row.normalized_path)) candidates.push({ ...row, reason: 'documento_reemplazado' });
    }
  }

  const byPath = new Map();
  for (const row of candidates) {
    if (keepPaths.has(row.normalized_path)) continue;
    if (!byPath.has(row.normalized_path)) byPath.set(row.normalized_path, []);
    byPath.get(row.normalized_path).push(row);
  }

  return {
    paths: [...byPath.keys()],
    rows: [...byPath.values()].flat(),
    dailyCount: candidates.filter((row) => row.reason === 'retencion_diaria' && !keepPaths.has(row.normalized_path)).length,
    replacedDocumentCount: candidates.filter((row) => row.reason === 'documento_reemplazado' && !keepPaths.has(row.normalized_path)).length,
    protectedCount: keepPaths.size,
  };
}

async function request(url, options = {}) {
  const response = await fetch(url, options);
  if (!response.ok) {
    const detail = await response.text().catch(() => '');
    throw new Error(`${options.method || 'GET'} ${url}: ${response.status} ${detail.slice(0, 500)}`);
  }
  if (response.status === 204) return null;
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

async function fetchAll(base, key, table, params) {
  const rows = [];
  for (let offset = 0; ; offset += PAGE_SIZE) {
    const query = new URLSearchParams(params);
    query.set('limit', String(PAGE_SIZE));
    query.set('offset', String(offset));
    const page = await request(`${base}/rest/v1/${table}?${query}`, {
      headers: { apikey: key, Authorization: `Bearer ${key}` },
    });
    rows.push(...page);
    if (page.length < PAGE_SIZE) return rows;
  }
}

async function deleteObjects(base, key, paths) {
  for (const batch of chunks(paths, DELETE_BATCH)) {
    await request(`${base}/storage/v1/object/evidencias`, {
      method: 'DELETE',
      headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ prefixes: batch }),
    });
  }
}

async function deleteRows(base, key, ids) {
  for (const batch of chunks(ids, DELETE_BATCH)) {
    await request(`${base}/rest/v1/evidencias?id=in.(${batch.join(',')})`, {
      method: 'DELETE',
      headers: { apikey: key, Authorization: `Bearer ${key}`, Prefer: 'return=minimal' },
    });
  }
}

async function main() {
  const base = required('SUPABASE_URL');
  const key = String(process.env.SUPABASE_SECRET_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
  if (!key) throw new Error('Falta la variable SUPABASE_SECRET_KEY.');
  const retentionDays = Math.max(1, Number(process.env.EVIDENCE_RETENTION_DAYS || 365));
  const dryRun = String(process.env.CLEANUP_DRY_RUN || 'true').toLowerCase() !== 'false';
  const cutoff = new Date(Date.now() - retentionDays * 86400000).toISOString();
  const docFilter = [...DOC_IDS].join(',');

  const [oldDaily, documents, collaborators] = await Promise.all([
    fetchAll(base, key, 'evidencias', {
      select: 'id,pregunta_id,storage_path,subido_en',
      subido_en: `lt.${cutoff}`,
      pregunta_id: `not.in.(${docFilter})`,
      storage_path: 'not.is.null',
      order: 'subido_en.asc',
    }),
    fetchAll(base, key, 'evidencias', {
      select: 'id,pregunta_id,storage_path,subido_en',
      pregunta_id: `in.(${docFilter})`,
      storage_path: 'not.is.null',
      order: 'subido_en.asc',
    }),
    fetchAll(base, key, 'colaboradores', {
      select: 'soat_url,tecnomecanica_url,licencia_url',
    }),
  ]);

  const protectedPaths = collaborators.flatMap((row) => [row.soat_url, row.tecnomecanica_url, row.licencia_url]).map(pathFromUrl).filter(Boolean);
  const plan = planCleanup({ oldDaily, documents, protectedPaths });
  const summary = {
    mode: dryRun ? 'SIMULACION' : 'EJECUCION',
    retentionDays,
    cutoff,
    dailyEvidenceRows: plan.dailyCount,
    replacedDocumentRows: plan.replacedDocumentCount,
    objectsToDelete: plan.paths.length,
    protectedPaths: plan.protectedCount,
  };
  console.log(JSON.stringify(summary, null, 2));

  if (dryRun || !plan.paths.length) return;
  await deleteObjects(base, key, plan.paths);
  await deleteRows(base, key, plan.rows.map((row) => row.id));
  console.log(`Limpieza completada: ${plan.paths.length} archivo(s) y ${plan.rows.length} referencia(s).`);
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1].replace(/\\/g, '/')}`).href) {
  main().catch((error) => { console.error(error); process.exitCode = 1; });
}
