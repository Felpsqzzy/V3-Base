const crypto = require('node:crypto');

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
  const payload = base64url(JSON.stringify({
    sub: user.id,
    email: user.email,
    nome: user.nome,
    perfilId: user.perfilId,
    iat: Math.floor(Date.now() / 1000)
  }));
  return payload + '.' + sign(payload);
}

function verifySession(raw) {
  if (!raw || raw.indexOf('.') < 1) return null;
  const parts = raw.split('.');
  const payload = parts.shift();
  const signature = parts.join('.');
  const expected = sign(payload);
  const a = Buffer.from(signature);
  const b = Buffer.from(expected);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  try {
    const data = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    if (!data || !data.sub || !data.email) return null;
    if (data.iat && Date.now() / 1000 - Number(data.iat) > 10 * 60 * 60) return null;
    return data;
  } catch (_) {
    return null;
  }
}

function readCookie(req, name) {
  const header = req.headers.cookie || '';
  for (const part of header.split(';')) {
    const [key, ...rest] = part.trim().split('=');
    if (key === name) return decodeURIComponent(rest.join('='));
  }
  return null;
}

function setSessionCookie(res, token) {
  res.setHeader('Set-Cookie', `biotrop_session=${encodeURIComponent(token)}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=36000`);
}

function clearSessionCookie(res) {
  res.setHeader('Set-Cookie', 'biotrop_session=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0');
}

function sendJson(res, status, body) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.end(JSON.stringify(body));
}

module.exports = {
  createSession,
  verifySession,
  readCookie,
  setSessionCookie,
  clearSessionCookie,
  sendJson
};
