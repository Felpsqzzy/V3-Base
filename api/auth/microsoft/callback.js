const { Pool } = require('pg');
const {
  msalClient,
  redirectUri,
  decodeState,
  clearOAuthCookie,
  readCookie,
  redirectError
} = require('./_entra');
const { createSession, setSessionCookie } = require('../_auth');

let pool;
function db() {
  if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL não configurado.');
  if (!pool) {
    pool = new Pool({
      connectionString: process.env.DATABASE_URL,
      max: 5,
      ssl: process.env.DATABASE_SSL === 'true' ? { rejectUnauthorized: false } : undefined
    });
  }
  return pool;
}

function safeText(value) {
  return String(value || '').trim().slice(0, 200);
}

module.exports = async function handler(req, res) {
  if (req.method !== 'GET') return redirectError(res, 'metodo_invalido');

  const { code, state, error } = req.query || {};
  if (error) return redirectError(res, `microsoft_${safeText(error)}`);

  const savedRaw = readCookie(req, 'biotrop_oauth');
  const saved = decodeState(savedRaw);
  if (!saved || !state || state !== saved.state || !code) {
    return redirectError(res, 'sessao_microsoft_expirada');
  }

  try {
    const tokenResponse = await msalClient().acquireTokenByCode({
      code: String(code),
      scopes: ['openid', 'profile', 'email'],
      redirectUri: redirectUri(req),
      codeVerifier: saved.verifier,
      nonce: saved.nonce
    });

    const claims = tokenResponse?.idTokenClaims || {};
    if (claims.nonce && claims.nonce !== saved.nonce) {
      return redirectError(res, 'nonce_invalido');
    }

    const tenantId = String(claims.tid || '');
    const objectId = String(claims.oid || '');
    const email = String(claims.email || claims.preferred_username || tokenResponse?.account?.username || '').trim().toLowerCase();
    const nome = String(claims.name || tokenResponse?.account?.name || email.split('@')[0]).trim();

    if (!tenantId || tenantId !== String(process.env.ENTRA_TENANT_ID)) return redirectError(res, 'tenant_nao_autorizado');
    if (!objectId || !email) return redirectError(res, 'dados_microsoft_incompletos');

    const client = await db().connect();
    try {
      await client.query('BEGIN');

      const auth = await client.query(
        `SELECT email, ativo, perfil_padrao, grupo_padrao
           FROM core.email_autorizado
          WHERE email = $1::citext
          LIMIT 1`,
        [email]
      );

      if (!auth.rowCount || auth.rows[0].ativo !== true) {
        await client.query(
          `INSERT INTO core.login_evento (email, sucesso, motivo) VALUES ($1::citext, false, 'e-mail Microsoft não autorizado')`,
          [email]
        );
        await client.query('COMMIT');
        return redirectError(res, 'email_nao_autorizado');
      }

      let result = await client.query(
        `SELECT id, nome, email::text AS email, perfil_id, time, telefone, ativo, bloqueado
           FROM core.usuario
          WHERE email = $1::citext
          LIMIT 1`,
        [email]
      );

      let user;
      if (!result.rowCount) {
        const perfil = auth.rows[0].perfil_padrao || 'tecnico';
        const inserted = await client.query(
          `INSERT INTO core.usuario
             (nome, email, entra_object_id, perfil_id, grupo_id, ativo, bloqueado)
           VALUES ($1, $2::citext, $3::uuid, $4, $5::uuid, true, false)
           RETURNING id, nome, email::text AS email, perfil_id, time, telefone, ativo, bloqueado`,
          [nome, email, objectId, perfil, auth.rows[0].grupo_padrao]
        );
        user = inserted.rows[0];
      } else {
        user = result.rows[0];
        if (user.bloqueado || user.ativo !== true) {
          await client.query(
            `INSERT INTO core.login_evento (email, usuario_id, sucesso, motivo) VALUES ($1::citext, $2, false, $3)`,
            [email, user.id, user.bloqueado ? 'usuario bloqueado' : 'usuario inativo']
          );
          await client.query('COMMIT');
          return redirectError(res, 'usuario_bloqueado');
        }
        await client.query(
          `UPDATE core.usuario
              SET nome = $1,
                  entra_object_id = $2::uuid,
                  ultimo_login_em = now()
            WHERE id = $3`,
          [nome, objectId, user.id]
        );
      }

      await client.query(
        `UPDATE core.usuario SET ultimo_login_em = now() WHERE id = $1`,
        [user.id]
      );
      await client.query(
        `INSERT INTO core.login_evento (email, usuario_id, sucesso, motivo) VALUES ($1::citext, $2, true, 'login Microsoft Entra')`,
        [email, user.id]
      );
      await client.query('COMMIT');

      const appUser = {
        id: user.id,
        nome: user.nome || nome,
        usuario: user.email || email,
        email: user.email || email,
        perfilId: user.perfil_id || auth.rows[0].perfil_padrao || 'tecnico',
        time: user.time || '',
        telefone: user.telefone || '',
        ativo: true,
        auth: true,
        authSource: 'microsoft'
      };

      clearOAuthCookie(res);
      setSessionCookie(res, createSession(appUser));
      res.statusCode = 302;
      res.setHeader('Location', '/?login=ok');
      res.end();
    } catch (err) {
      await client.query('ROLLBACK');
      throw err;
    } finally {
      client.release();
    }
  } catch (err) {
    console.error('[BIOTROP ENTRA CALLBACK]', err);
    redirectError(res, 'falha_autenticacao_microsoft');
  }
};
