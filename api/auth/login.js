const { Pool } = require('pg');
const bcrypt = require('bcryptjs');
const { createSession, setSessionCookie, sendJson } = require('../_auth');

let pool;
function db() {
  const connectionString = process.env.NEON_DATABASE_URL || process.env.DATABASE_URL;
  if (!connectionString) throw new Error('NEON_DATABASE_URL/DATABASE_URL não configurado.');
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

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') return sendJson(res, 405, { ok: false, erro: 'Método não permitido.' });

  let client;
  let transactionOpen = false;

  try {
    const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});
    const email = String(body.email || '').trim().toLowerCase();
    const senha = String(body.senha || '');
    if (!email || !senha) return sendJson(res, 400, { ok: false, erro: 'Informe e-mail e senha.' });

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
      return sendJson(res, 403, { ok: false, erro: 'Acesso não autorizado para este usuário.' });
    }

    if (!user.senha_hash || !(await bcrypt.compare(senha, user.senha_hash))) {
      await client.query(
        `INSERT INTO core.login_evento (email, usuario_id, sucesso, motivo) VALUES ($1::citext, $2, false, 'senha inválida')`,
        [email, user.id]
      );
      await client.query('COMMIT');
      transactionOpen = false;
      return sendJson(res, 401, { ok: false, erro: 'E-mail ou senha inválidos.' });
    }

    await client.query(`UPDATE core.usuario SET ultimo_login_em = now() WHERE id = $1`, [user.id]);
    await client.query(
      `INSERT INTO core.login_evento (email, usuario_id, sucesso, motivo) VALUES ($1::citext, $2, true, 'login local')`,
      [email, user.id]
    );
    await client.query('COMMIT');
    transactionOpen = false;

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

    try {
      const token = createSession(appUser);
      setSessionCookie(res, token);
    } catch (sessionErr) {
      console.error('[BIOTROP SESSION]', sessionErr);
      return sendJson(res, 500, {
        ok: false,
        erro: 'A sessão do servidor não está configurada. Verifique SESSION_SECRET no ambiente Production.'
      });
    }

    return sendJson(res, 200, { ok: true, usuario: appUser });
  } catch (err) {
    if (transactionOpen && client) {
      try { await client.query('ROLLBACK'); } catch (_) { }
    }
    console.error('[BIOTROP PostgreSQL AUTH]', err);

    const message = String(err?.message || '');
    const code = String(err?.code || '');
    const errno = String(err?.errno || '');

    if (/NEON_DATABASE_URL|DATABASE_URL/i.test(message)) {
      return sendJson(res, 500, { ok: false, erro: 'NEON_DATABASE_URL/DATABASE_URL não está configurado no ambiente Production.' });
    }
    if (/relation .* does not exist|column .* does not exist/i.test(message)) {
      return sendJson(res, 500, { ok: false, erro: 'O banco não está com a estrutura necessária para o login.' });
    }

    // Diagnóstico controlado: não retorna senha, DATABASE_URL ou stack trace.
    const detalhe = [code, errno, message]
      .filter(Boolean)
      .join(' | ')
      .replace(/postgres(?:ql)?:\/\/[^\s]+/gi, '[DATABASE_URL ocultada]')
      .slice(0, 300);

    return sendJson(res, 500, {
      ok: false,
      erro: `Falha ao acessar o PostgreSQL.${detalhe ? ` ${detalhe}` : ''}`
    });
  } finally {
    if (client) client.release();
  }
};