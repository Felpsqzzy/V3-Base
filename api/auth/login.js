const { Pool } = require('pg');
const bcrypt = require('bcryptjs');
const { createSession, setSessionCookie, sendJson } = require('../_auth');

let pool;
function db() {
  if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL não configurado.');
  if (!pool) {
    pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 5, ssl: process.env.DATABASE_SSL === 'true' ? { rejectUnauthorized: false } : undefined });
  }
  return pool;
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') return sendJson(res, 405, { ok: false, erro: 'Método não permitido.' });
  try {
    const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});
    const email = String(body.email || '').trim().toLowerCase();
    const senha = String(body.senha || '');
    if (!email || !senha) return sendJson(res, 400, { ok: false, erro: 'Informe e-mail e senha.' });

    // Login local PostgreSQL permanece ativo.
    // LOGIN_LOCAL_ATIVO=false não bloqueia mais o login local; Microsoft Entra
    // pode coexistir como método adicional de autenticação.
    const client = await db().connect();
    try {
      await client.query('BEGIN');
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
        return sendJson(res, 401, { ok: false, erro: 'E-mail ou senha inválidos.' });
      }

      const user = r.rows[0];
      if (user.autorizado !== true || user.ativo !== true || user.bloqueado === true) {
        await client.query(
          `INSERT INTO core.login_evento (email, usuario_id, sucesso, motivo) VALUES ($1::citext, $2, false, $3)`,
          [email, user.id, user.bloqueado ? 'usuario bloqueado' : (user.ativo !== true ? 'usuario inativo' : 'e-mail não autorizado')]
        );
        await client.query('COMMIT');
        return sendJson(res, 403, { ok: false, erro: 'Acesso não autorizado para este usuário.' });
      }

      if (!user.senha_hash || !(await bcrypt.compare(senha, user.senha_hash))) {
        await client.query(
          `INSERT INTO core.login_evento (email, usuario_id, sucesso, motivo) VALUES ($1::citext, $2, false, 'senha inválida')`,
          [email, user.id]
        );
        await client.query('COMMIT');
        return sendJson(res, 401, { ok: false, erro: 'E-mail ou senha inválidos.' });
      }

      await client.query(
        `UPDATE core.usuario SET ultimo_login_em = now() WHERE id = $1`,
        [user.id]
      );
      await client.query(
        `INSERT INTO core.login_evento (email, usuario_id, sucesso, motivo) VALUES ($1::citext, $2, true, 'login local')`,
        [email, user.id]
      );
      await client.query('COMMIT');

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
      setSessionCookie(res, createSession(appUser));
      return sendJson(res, 200, { ok: true, usuario: appUser });
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    } finally {
      client.release();
    }
  } catch (err) {
    console.error('[BIOTROP PostgreSQL AUTH]', err);
    return sendJson(res, 500, { ok: false, erro: 'Falha ao acessar o PostgreSQL.' });
  }
};
