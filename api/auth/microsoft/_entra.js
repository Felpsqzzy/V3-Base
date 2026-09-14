const crypto = require('node:crypto');
const { ConfidentialClientApplication } = require('@azure/msal-node');

function required(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Variável ${name} não configurada.`);
  return value;
}

function baseUrl(req) {
  return process.env.APP_BASE_URL || `${req.headers['x-forwarded-proto'] || 'https'}://${req.headers.host}`;
}

function redirectUri(req) {
  return `${baseUrl(req).replace(/\/$/, '')}/api/auth/microsoft/callback`;
}

function msalClient() {
  return new ConfidentialClientApplication({
    auth: {
      clientId: required('ENTRA_CLIENT_ID'),
      authority: `https://login.microsoftonline.com/${required('ENTRA_TENANT_ID')}`,
      clientSecret: required('ENTRA_CLIENT_SECRET')
    }
  });
}

function randomState() {
  return crypto.randomBytes(32).toString('base64url');
}

function createPkce() {
  const verifier = crypto.randomBytes(48).toString('base64url');
  const challenge = crypto.createHash('sha256').update(verifier).digest('base64url');
  return { verifier, challenge };
}

function sign(value) {
  const secret = required('SESSION_SECRET');
  return crypto.createHmac('sha256', secret).update(value).digest('base64url');
}

function encodeState(data) {
  const payload = Buffer.from(JSON.stringify(data)).toString('base64url');
  return `${payload}.${sign(payload)}`;
}

function decodeState(raw) {
  if (!raw || !raw.includes('.')) return null;
  const [payload, signature] = raw.split('.');
  const expected = sign(payload);
  const a = Buffer.from(signature);
  const b = Buffer.from(expected);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  try {
    const data = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    if (!data?.state || !data?.verifier || !data?.nonce || !data?.exp) return null;
    if (Date.now() > Number(data.exp)) return null;
    return data;
  } catch (_) {
    return null;
  }
}

function setOAuthCookie(res, value, maxAge = 600) {
  const secure = process.env.NODE_ENV === 'production' ? ' Secure;' : '';
  res.setHeader('Set-Cookie', `biotrop_oauth=${encodeURIComponent(value)}; Path=/; HttpOnly; SameSite=Lax;${secure} Max-Age=${maxAge}`);
}

function clearOAuthCookie(res) {
  const secure = process.env.NODE_ENV === 'production' ? ' Secure;' : '';
  res.setHeader('Set-Cookie', `biotrop_oauth=; Path=/; HttpOnly; SameSite=Lax;${secure} Max-Age=0`);
}

function readCookie(req, name) {
  const header = req.headers.cookie || '';
  for (const part of header.split(';')) {
    const [key, ...rest] = part.trim().split('=');
    if (key === name) return decodeURIComponent(rest.join('='));
  }
  return null;
}

function redirectError(res, code) {
  res.statusCode = 302;
  res.setHeader('Location', `/?login=erro&motivo=${encodeURIComponent(code)}`);
  res.end();
}

module.exports = {
  required,
  baseUrl,
  redirectUri,
  msalClient,
  randomState,
  createPkce,
  encodeState,
  decodeState,
  setOAuthCookie,
  clearOAuthCookie,
  readCookie,
  redirectError
};
