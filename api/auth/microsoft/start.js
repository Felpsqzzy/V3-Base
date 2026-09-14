const {
  msalClient,
  redirectUri,
  randomState,
  createPkce,
  encodeState,
  setOAuthCookie,
  redirectError
} = require('./_entra');

module.exports = async function handler(req, res) {
  if (req.method !== 'GET') return redirectError(res, 'metodo_invalido');
  try {
    const state = randomState();
    const nonce = randomState();
    const { verifier, challenge } = createPkce();
    const authUrl = await msalClient().getAuthCodeUrl({
      scopes: ['openid', 'profile', 'email'],
      redirectUri: redirectUri(req),
      responseMode: 'query',
      state,
      nonce,
      codeChallenge: challenge,
      codeChallengeMethod: 'S256'
    });

    const cookie = encodeState({
      state,
      nonce,
      verifier,
      exp: Date.now() + 10 * 60 * 1000
    });
    setOAuthCookie(res, cookie);
    res.statusCode = 302;
    res.setHeader('Location', authUrl);
    res.end();
  } catch (err) {
    console.error('[BIOTROP ENTRA START]', err);
    redirectError(res, 'configuracao_microsoft');
  }
};
