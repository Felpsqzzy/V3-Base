const crypto = require('node:crypto');

const SESSION_COOKIE = 'biotrop_session';
const SESSION_TTL_SECONDS = 8 * 60 * 60;
const ISSUER = 'biotrop-manutencao';

function secret() {
  const value = process.env.SESSION_SECRET;
  if (!value || value.length < 32) {
    throw new Error('SESSION_SECRET não configurado ou muito curto.');
  }
  return value;
}

function base64url(value) {
  return Buffer.from(value).toString('base64url');
}

function sign(value) {
  return crypto.createHmac('sha256', secret()).update(value).digest('base64url');
}

function createSession(user) {
  const now = Math.floor(Date.now() / 1000);
  const payload = base64url(JSON.stringify({
    iss: ISSUER,
    sub: String(user.id),
    email: String(user.email || '').trim().toLowerCase(),
    nome: String(user.nome || '').slice(0, 160),
    perfilId: String(user.perfilId || ''),
    iat: now,
    exp: now + SESSION_TTL_SECONDS
  }));
  return payload + '.' + sign(payload);
}

function verifySession(raw) {
  if (!raw || raw.length > 8192 || raw.indexOf('.') < 1) return null;
  const parts = raw.split('.');
  if (parts.length !== 2) return null;
  const payload = parts[0];
  const signature = parts[1];
  const expected = sign(payload);
  let a, b;
  try {
    a = Buffer.from(signature, 'base64url');
    b = Buffer.from(expected, 'base64url');
  } catch (_) {
    return null;
  }
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;

  try {
    const data = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    const now = Math.floor(Date.now() / 1000);
    if (!data || data.iss !== ISSUER || !data.sub || !data.email) return null;
    if (!Number.isInteger(Number(data.iat)) || !Number.isInteger(Number(data.exp))) return null;
    if (Number(data.iat) > now + 60 || Number(data.exp) <= now) return null;
    if (Number(data.exp) - Number(data.iat) > SESSION_TTL_SECONDS) return null;
    return data;
  } catch (_) {
    return null;
  }
}

function readCookie(req, name) {
  const header = req.headers.cookie || '';
  for (const part of header.split(';')) {
    const [key, ...rest] = part.trim().split('=');
    if (key === name) {
      try { return decodeURIComponent(rest.join('=')); } catch (_) { return null; }
    }
  }
  return null;
}

function setSessionCookie(res, token) {
  res.setHeader(
    'Set-Cookie',
    SESSION_COOKIE + '=' + encodeURIComponent(token) +
    '; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=' + SESSION_TTL_SECONDS
  );
}

function clearSessionCookie(res) {
  res.setHeader(
    'Set-Cookie',
    SESSION_COOKIE + '=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0'
  );
}

function sameOrigin(req) {
  const origin = req.headers.origin;
  if (!origin) return true;
  const proto = req.headers['x-forwarded-proto'] || 'https';
  const host = req.headers.host;
  if (!host) return false;
  try {
    return new URL(origin).origin === proto + '://' + host;
  } catch (_) {
    return false;
  }
}

function sendJson(res, status, body) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.end(JSON.stringify(body));
}

module.exports = {
  createSession,
  verifySession,
  readCookie,
  setSessionCookie,
  clearSessionCookie,
  sameOrigin,
  sendJson
};
