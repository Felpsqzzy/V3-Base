const { Pool } = require('pg');
const { readCookie, verifySession, sendJson } = require('../_auth');

const ALLOWED = new Set(['sci', 'scm', 'utility_meters', 'utility_readings']);
let pool;

function getPool() {
  if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL não configurado.');
  if (!pool) {
    pool = new Pool({
      connectionString: process.env.DATABASE_URL,
      max: 10,
      idleTimeoutMillis: 30000,
      connectionTimeoutMillis: 8000,
      ssl: process.env.DATABASE_SSL === 'true' ? { rejectUnauthorized: false } : undefined
    });
  }
  return pool;
}

function sessionFrom(req) {
  const raw = readCookie(req, 'biotrop_session');
  return verifySession(raw);
}

function validNamespace(value) {
  return typeof value === 'string' && ALLOWED.has(value);
}

function parseBody(req) {
  if (!req.body) return {};
  if (typeof req.body === 'string') return JSON.parse(req.body);
  return req.body;
}

function isoOrNull(value) {
  if (!value) return null;
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

async function withTransaction(fn, session) {
  const client = await getPool().connect();
  try {
    await client.query('BEGIN');
    await client.query("select set_config('app.usuario_id', $1, true)", [String(session.sub)]);
    await client.query("select set_config('app.usuario_email', $1, true)", [String(session.email || '')]);
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    try { await client.query('ROLLBACK'); } catch (_) {}
    throw error;
  } finally {
    client.release();
  }
}

function publicRow(row) {
  return {
    id: row.id,
    namespace: row.namespace,
    recordId: row.record_id,
    payload: row.payload,
    deleted: row.deleted,
    version: Number(row.version),
    updatedBy: row.updated_by,
    updatedAt: row.updated_at,
    createdAt: row.created_at
  };
}

module.exports = async function handler(req, res) {
  const session = sessionFrom(req);
  if (!session) return sendJson(res, 401, { ok: false, erro: 'Sessão não autenticada.' });

  const method = String(req.method || 'GET').toUpperCase();

  try {
    if (method === 'GET') {
      const namespace = String(req.query?.namespace || '').trim();
      const since = isoOrNull(req.query?.since);
      if (!validNamespace(namespace)) return sendJson(res, 400, { ok: false, erro: 'Namespace inválido.' });

      const rows = await withTransaction(async client => {
        const args = [namespace];
        let sql = `
          SELECT id, namespace, record_id, payload, deleted, version, updated_by, updated_at, created_at
            FROM app.sync_registro
           WHERE namespace = $1`;
        if (since) {
          args.push(since);
          sql += ` AND updated_at >= $2`;
        }
        sql += ' ORDER BY updated_at ASC, version ASC';
        const result = await client.query(sql, args);
        return result.rows.map(publicRow);
      }, session);

      res.setHeader('Cache-Control', 'no-store');
      return sendJson(res, 200, { ok: true, namespace, rows });
    }

    if (method === 'POST' || method === 'PUT') {
      const body = parseBody(req);
      const namespace = String(body.namespace || '').trim();
      const recordId = String(body.recordId || '').trim();
      const deleted = body.deleted === true;
      const payload = body.payload == null ? {} : body.payload;
      const expectedVersion = body.expectedVersion == null || body.expectedVersion === ''
        ? null
        : Number(body.expectedVersion);

      if (!validNamespace(namespace)) return sendJson(res, 400, { ok: false, erro: 'Namespace inválido.' });
      if (!recordId || recordId.length > 300) return sendJson(res, 400, { ok: false, erro: 'Identificador do registro inválido.' });
      if (payload === null || typeof payload !== 'object') return sendJson(res, 400, { ok: false, erro: 'Payload inválido.' });
      if (expectedVersion !== null && (!Number.isInteger(expectedVersion) || expectedVersion < 0)) {
        return sendJson(res, 400, { ok: false, erro: 'Versão esperada inválida.' });
      }

      const row = await withTransaction(async client => {
        const currentResult = await client.query(
          `SELECT id, namespace, record_id, payload, deleted, version, updated_by, updated_at, created_at
             FROM app.sync_registro
            WHERE namespace = $1 AND record_id = $2
            FOR UPDATE`,
          [namespace, recordId]
        );
        const current = currentResult.rows[0] || null;
        if (current && expectedVersion !== null && Number(current.version) !== expectedVersion) {
          const error = new Error('CONFLICT');
          error.statusCode = 409;
          error.current = publicRow(current);
          throw error;
        }

        if (!current) {
          if (expectedVersion !== null && expectedVersion !== 0) {
            const error = new Error('CONFLICT');
            error.statusCode = 409;
            error.current = null;
            throw error;
          }
          const insert = await client.query(
            `INSERT INTO app.sync_registro
              (namespace, record_id, payload, deleted, version, updated_by, updated_at)
             VALUES ($1, $2, $3::jsonb, $4, 1, $5, now())
             RETURNING id, namespace, record_id, payload, deleted, version, updated_by, updated_at, created_at`,
            [namespace, recordId, JSON.stringify(payload), deleted, String(session.sub)]
          );
          return publicRow(insert.rows[0]);
        }

        const update = await client.query(
          `UPDATE app.sync_registro
              SET payload = $3::jsonb,
                  deleted = $4,
                  version = version + 1,
                  updated_by = $5,
                  updated_at = now()
            WHERE namespace = $1 AND record_id = $2
          RETURNING id, namespace, record_id, payload, deleted, version, updated_by, updated_at, created_at`,
          [namespace, recordId, JSON.stringify(payload), deleted, String(session.sub)]
        );
        return publicRow(update.rows[0]);
      }, session);

      return sendJson(res, 200, { ok: true, row });
    }

    return sendJson(res, 405, { ok: false, erro: 'Método não permitido.' });
  } catch (error) {
    if (error && error.statusCode === 409) {
      return sendJson(res, 409, { ok: false, conflito: true, erro: 'O registro foi alterado por outro usuário.', row: error.current || null });
    }
    console.error('[BIOTROP DATA SYNC]', error);
    const configured = Boolean(process.env.DATABASE_URL);
    return sendJson(res, configured ? 500 : 503, {
      ok: false,
      erro: configured ? 'Falha ao acessar o PostgreSQL.' : 'PostgreSQL ainda não está configurado.',
      code: configured ? 'DB_ERROR' : 'DB_NOT_CONFIGURED'
    });
  }
};
