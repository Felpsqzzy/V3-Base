const { Pool } = require('pg');
const bcrypt = require('bcryptjs');
const { createSession, setSessionCookie, sendJson, sameOrigin } = require('../_auth');

let pool;
const attempts = new Map();
const WINDOW_MS = 15 * 60 * 1000;
const LOCK_MS = 30 * 60 * 1000;
const MAX_FAILURES = 5;

function db() {
  const connectionString = process.env.NEON_DATABASE_URL || process.env.DATABASE_URL;
  if (!connectionString) throw new Error('Banco não configurado.');
  if (!pool) {
    pool = new Pool({
      connectionString,
      max: 5,
      connectionTimeoutMillis: 10000,
      idleTimeoutMillis: 10000,
      ssl: { rejectUnauthorized: false }
    });
  }
  return pool;
}

function clientIp(req) {
  const forwarded = String(req.headers['x-forwarded-for'] || '').split(',')[0].trim();
  return (forwarded || String(req.socket?.remoteAddress || 'unknown')).slice(0, 120);
}

function rateKey(email, ip) {
  return email + '|' + ip;
}

function blocked(key) {
  const item = attempts.get(key);
  if (!item) return false;
  const now = Date.now();
  if (item.lockedUntil > now) return true;
  if (now - item.first > WINDOW_MS) {
    attempts.delete(key);
    return false;
  }
  return item.failures >= MAX_FAILURES;
}

function failure(key) {
  const now = Date.now();
  const item = attempts.get(key);
  if (!item || now - item.first > WINDOW_MS) {
    attempts.set(key, { first: now, failures: 1, lockedUntil: 0 });
    return;
  }
  item.failures += 1;
  if (item.failures >= MAX_FAILURES) item.lockedUntil = now + LOCK_MS;
}

function success(key) {
  attempts.delete(key);
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') return sendJson(res, 405, { ok: false, erro: 'Método não permitido.' });
  if (!sameOrigin(req)) return sendJson(res, 403, { ok: false, erro: 'Origem não autorizada.' });

  let client;
  let transactionOpen = false;

  try {
    const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});
    const email = String(body.email || '').trim().toLowerCase();
    const senha = String(body.senha || '');
    if (!email || !senha || email.length > 254 || senha.length > 1024) {
      return sendJson(res, 400, { ok: false, erro: 'Informe e-mail e senha válidos.' });
    }

    const key = rateKey(email, clientIp(req));
    if (blocked(key)) {
      res.setHeader('Retry-After', String(Math.ceil(LOCK_MS / 1000)));
      return sendJson(res, 429, { ok: false, erro: 'Muitas tentativas. Aguarde alguns minutos e tente novamente.' });
    }

    client = await db().connect();
    await client.query('BEGIN');
    transactionOpen = true;

    const r = await client.query(
      `SELECT u.id, u.nome, u.email::text AS email, u.senha_hash, u.perfil_id, u.time, u.telefone,
              u.ativo, u.bloqueado, u.motivo_bloqueio,
              a.ativo AS autorizado
         FROM core.usuario u
         LEFT JOIN core.email_autorizado a ON a.email = u.email
        WHERE lower(u.email::text) = lower($1)
        LIMIT 1`,
      [email]
    );

    if (!r.rowCount) {
      await client.query(
        `INSERT INTO core.login_evento (email, sucesso, motivo) VALUES ($1::citext, false, 'usuario inexistente')`,
        [email]
      );
      await client.query('COMMIT');
      transactionOpen = false;
      failure(key);
      return sendJson(res, 401, { ok: false, erro: 'E-mail ou senha inválidos.' });
    }

    const user = r.rows[0];
    if (user.autorizado !== true || user.ativo !== true || user.bloqueado === true) {
      await client.query(
        `INSERT INTO core.login_evento (email, usuario_id, sucesso, motivo) VALUES ($1::citext, $2, false, $3)`,
        [email, user.id, user.bloqueado ? 'usuario bloqueado' : (user.ativo !== true ? 'usuario inativo' : 'e-mail não autorizado')]
      );
      await client.query('COMMIT');
      transactionOpen = false;
      failure(key);
      return sendJson(res, 403, { ok: false, erro: 'Acesso não autorizado para este usuário.' });
    }

    if (!user.senha_hash || !(await bcrypt.compare(senha, user.senha_hash))) {
      await client.query(
        `INSERT INTO core.login_evento (email, usuario_id, sucesso, motivo) VALUES ($1::citext, $2, false, 'senha inválida')`,
        [email, user.id]
      );
      await client.query('COMMIT');
      transactionOpen = false;
      failure(key);
      return sendJson(res, 401, { ok: false, erro: 'E-mail ou senha inválidos.' });
    }

    await client.query('UPDATE core.usuario SET ultimo_login_em = now() WHERE id = $1', [user.id]);
    await client.query(
      `INSERT INTO core.login_evento (email, usuario_id, sucesso, motivo) VALUES ($1::citext, $2, true, 'login local')`,
      [email, user.id]
    );
    await client.query('COMMIT');
    transactionOpen = false;

    success(key);

    const appUser = {
      id: user.id,
      nome: user.nome,
      usuario: user.email,
      email: user.email,
      perfilId: user.perfil_id,
      time: user.time || '',
      telefone: user.telefone || '',
      ativo: true,
      auth: true
    };

    const token = createSession(appUser);
    setSessionCookie(res, token);
    return sendJson(res, 200, { ok: true, usuario: appUser });
  } catch (err) {
    if (transactionOpen && client) {
      try { await client.query('ROLLBACK'); } catch (_) {}
    }
    console.error('[BIOTROP AUTH] falha interna', { code: err?.code || 'UNKNOWN' });
    return sendJson(res, 500, {
      ok: false,
      erro: 'Não foi possível autenticar agora. Tente novamente em instantes.'
    });
  } finally {
    if (client) client.release();
  }
};
