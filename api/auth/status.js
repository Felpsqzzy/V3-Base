const { Pool } = require('pg');
const { sendJson } = require('../_auth');

let pool;
function getPool() {
  const connectionString = process.env.NEON_DATABASE_URL || process.env.DATABASE_URL;
  if (!connectionString) return null;
  if (!pool) pool = new Pool({
    connectionString,
    max: 2,
    ssl: { rejectUnauthorized: false }
  });
  return pool;
}

module.exports = async function handler(req, res) {
  if (req.method !== 'GET') return sendJson(res, 405, { ok: false, erro: 'Método não permitido.' });

  const config = {
    database_url: Boolean(process.env.NEON_DATABASE_URL || process.env.DATABASE_URL),
    session_secret: Boolean(process.env.SESSION_SECRET && process.env.SESSION_SECRET.length >= 32),
    login_local_ativo: process.env.LOGIN_LOCAL_ATIVO === 'true'
  };

  if (!config.database_url) {
    return sendJson(res, 503, { ok:false, etapa:'configuracao', config, erro:'Banco não configurado no ambiente de execução.' });
  }
  if (!config.session_secret) {
    return sendJson(res, 503, { ok:false, etapa:'configuracao', config, erro:'SESSION_SECRET ausente ou inválido.' });
  }
  if (!config.login_local_ativo) {
    return sendJson(res, 403, { ok:false, etapa:'login', config, erro:'LOGIN_LOCAL_ATIVO não está habilitado neste ambiente.' });
  }

  const client = getPool();
  try {
    await client.query('SELECT 1');
    const check = await client.query(`
      SELECT
        to_regclass('core.usuario') IS NOT NULL AS usuario_ok,
        to_regclass('core.email_autorizado') IS NOT NULL AS autorizacao_ok,
        to_regclass('core.login_evento') IS NOT NULL AS login_evento_ok
    `);
    return sendJson(res, 200, { ok:true, etapa:'pronto', config, banco:check.rows[0] });
  } catch (err) {
    console.error('[BIOTROP AUTH STATUS] falha interna', { code: err?.code || 'UNKNOWN' });
    return sendJson(res, 503, { ok:false, etapa:'postgresql', config, erro:'PostgreSQL indisponível ou schema ainda não aplicado.' });
  }
};
