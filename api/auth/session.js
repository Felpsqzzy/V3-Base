const { Pool } = require('pg');
const { verifySession, readCookie, sendJson, clearSessionCookie, setSessionCookie, createSession, sameOrigin } = require('../_auth');

let pool;
function db() {
  const connectionString = process.env.NEON_DATABASE_URL || process.env.DATABASE_URL;
  if (!connectionString) throw new Error('Banco não configurado.');
  if (!pool) pool = new Pool({
    connectionString,
    max: 5,
    ssl: { rejectUnauthorized: false }
  });
  return pool;
}

module.exports = async function handler(req, res) {
  if (req.method === 'DELETE' || (req.method === 'POST' && req.query.logout === '1')) {
    if (!sameOrigin(req)) return sendJson(res, 403, { ok: false, erro: 'Origem não autorizada.' });
    clearSessionCookie(res);
    return sendJson(res, 200, { ok: true });
  }

  if (req.method !== 'GET') return sendJson(res, 405, { ok: false, erro: 'Método não permitido.' });

  try {
    const session = verifySession(readCookie(req, 'biotrop_session'));
    if (!session) {
      clearSessionCookie(res);
      return sendJson(res, 401, { ok: false });
    }

    const c = await db().connect();
    try {
      const r = await c.query(
        `SELECT u.id,u.nome,u.email::text AS email,u.perfil_id,u.time,u.telefone,u.ativo,u.bloqueado,
                a.ativo AS autorizado
           FROM core.usuario u
           LEFT JOIN core.email_autorizado a ON a.email=u.email
          WHERE u.id=$1
          LIMIT 1`,
        [session.sub]
      );
      if (!r.rowCount || r.rows[0].ativo !== true || r.rows[0].bloqueado === true || r.rows[0].autorizado !== true) {
        clearSessionCookie(res);
        return sendJson(res, 401, { ok: false });
      }

      const x = r.rows[0];
      const user = {
        id:x.id,nome:x.nome,usuario:x.email,email:x.email,perfilId:x.perfil_id,
        time:x.time||'',telefone:x.telefone||'',ativo:true,auth:true
      };
      setSessionCookie(res, createSession(user));
      return sendJson(res, 200, { ok:true, usuario:user });
    } finally {
      c.release();
    }
  } catch (err) {
    console.error('[BIOTROP SESSION] falha interna', { code: err?.code || 'UNKNOWN' });
    return sendJson(res, 500, { ok:false, erro:'Falha ao consultar a sessão.' });
  }
};
