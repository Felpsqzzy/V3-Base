const { Pool } = require('pg');
const { readCookie, verifySession, sendJson } = require('./_auth');

const ALLOWED = new Set(['sci', 'scm', 'utility_meters', 'utility_readings']);
let pool;

function getPool() {
  if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL não configurado.');
  if (!pool) {
    pool = new Pool({
      connectionString: process.env.DATABASE_URL,
      max: 4,
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 8000,
      ssl: process.env.DATABASE_SSL === 'true' ? { rejectUnauthorized: false } : undefined
    });
  }
  return pool;
}

function currentSession(req) {
  return verifySession(readCookie(req, 'biotrop_session'));
}

function validNamespace(value) {
  return typeof value === 'string' && ALLOWED.has(value);
}

function writeEvent(res, event, payload) {
  res.write(`event: ${event}\n`);
  res.write(`data: ${JSON.stringify(payload)}\n\n`);
}

module.exports = async function handler(req, res) {
  const session = currentSession(req);
  if (!session) return sendJson(res, 401, { ok: false, erro: 'Sessão não autenticada.' });

  const namespace = String(req.query?.namespace || '').trim();
  if (!validNamespace(namespace)) {
    return sendJson(res, 400, { ok: false, erro: 'Namespace inválido.' });
  }

  const method = String(req.method || 'GET').toUpperCase();
  if (method !== 'GET') return sendJson(res, 405, { ok: false, erro: 'Método não permitido.' });

  const sinceRaw = req.query?.since ? new Date(req.query.since) : null;
  let since = sinceRaw && !Number.isNaN(sinceRaw.getTime()) ? sinceRaw.toISOString() : new Date(0).toISOString();

  res.statusCode = 200;
  res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
  res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no');
  res.flushHeaders?.();

  writeEvent(res, 'ready', { ok: true, namespace, connectedAt: new Date().toISOString() });

  const startedAt = Date.now();
  const maxLifetime = 8500;
  let closed = false;
  let timer;

  const cleanup = () => {
    if (closed) return;
    closed = true;
    clearTimeout(timer);
    clearInterval(interval);
  };

  req.on('close', cleanup);

  const check = async () => {
    if (closed) return;
    try {
      const client = await getPool().connect();
      try {
        await client.query("select set_config('app.usuario_id', $1, true)", [String(session.sub)]);
        await client.query("select set_config('app.usuario_email', $1, true)", [String(session.email || '')]);
        const result = await client.query(
          `SELECT id, namespace, record_id, payload, deleted, version, updated_by, updated_at, created_at
             FROM app.sync_registro
            WHERE namespace = $1 AND updated_at > $2
            ORDER BY updated_at ASC, version ASC`,
          [namespace, since]
        );

        for (const row of result.rows) {
          writeEvent(res, 'change', {
            id: row.id,
            namespace: row.namespace,
            recordId: row.record_id,
            payload: row.payload,
            deleted: row.deleted,
            version: Number(row.version),
            updatedBy: row.updated_by,
            updatedAt: row.updated_at,
            createdAt: row.created_at
          });
          since = new Date(row.updated_at).toISOString();
        }
      } finally {
        client.release();
      }

      writeEvent(res, 'heartbeat', { at: new Date().toISOString() });
      if (Date.now() - startedAt >= maxLifetime) {
        writeEvent(res, 'reconnect', { afterMs: 250 });
        cleanup();
        res.end();
      }
    } catch (error) {
      writeEvent(res, 'error', { message: 'Falha temporária ao consultar PostgreSQL.' });
      cleanup();
      res.end();
    }
  };

  const interval = setInterval(check, 1500);
  timer = setTimeout(() => {
    cleanup();
    res.end();
  }, maxLifetime + 250);

  await check();
};
