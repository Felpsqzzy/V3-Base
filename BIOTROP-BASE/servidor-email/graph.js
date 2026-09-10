/**
 * Microsoft Graph — token de aplicativo e envio de e-mail.
 *
 * Fluxo client_credentials: o servidor se autentica como APLICATIVO, não
 * como pessoa. É o que permite mandar e-mail sem ninguém logado, o que é
 * exatamente o caso de uma rotina que roda de madrugada.
 *
 * Permissão necessária no registro do aplicativo (Entra ID):
 *   Mail.Send  —  tipo APLICATIVO (não delegada), com consentimento do
 *                 administrador concedido.
 *
 * Cuidado que vale escrever: Mail.Send de aplicativo permite enviar como
 * QUALQUER caixa do tenant. Peça para a TI aplicar uma Application Access
 * Policy limitando o aplicativo à caixa de comunicação
 * (manutencao@biotrop.com.br). Sem essa política, um vazamento da chave
 * permite enviar e-mail como qualquer pessoa da empresa.
 */

const TOKEN_URL = (tenant) => `https://login.microsoftonline.com/${tenant}/oauth2/v2.0/token`;
const GRAPH = "https://graph.microsoft.com/v1.0";

let cache = { token: null, expiraEm: 0 };

/**
 * Token de aplicativo, com cache.
 *
 * O token vale ~1h. Pedir um novo a cada e-mail funciona, mas gasta
 * chamada e cria ponto de falha desnecessário; renovamos 5 min antes de
 * expirar.
 */
async function obterToken(cfg) {
  const agora = Date.now();
  if (cache.token && agora < cache.expiraEm - 300000) return cache.token;

  const corpo = new URLSearchParams({
    client_id: cfg.clientId,
    client_secret: cfg.clientSecret,
    scope: "https://graph.microsoft.com/.default",
    grant_type: "client_credentials",
  });

  const r = await fetch(TOKEN_URL(cfg.tenantId), {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: corpo,
  });

  const dados = await r.json().catch(() => ({}));
  if (!r.ok) {
    // A mensagem do Entra é específica e vale propagar: "AADSTS7000215"
    // é segredo errado, "AADSTS700016" é aplicativo não encontrado.
    throw new Error(
      `Falha ao obter token (${r.status}): ${dados.error || ""} ${dados.error_description || ""}`.trim()
    );
  }

  cache = { token: dados.access_token, expiraEm: agora + (dados.expires_in || 3600) * 1000 };
  return cache.token;
}

/**
 * Envia uma mensagem.
 *
 * saveToSentItems fica true de propósito: sem isso não existe rastro do
 * que a plataforma mandou, e a primeira pergunta quando alguém diz "não
 * recebi" é justamente se saiu.
 */
async function enviarEmail(cfg, msg) {
  const token = await obterToken(cfg);

  const destinatarios = (lista) =>
    (lista || [])
      .map((e) => String(e).trim())
      .filter(Boolean)
      .map((e) => ({ emailAddress: { address: e } }));

  const payload = {
    message: {
      subject: msg.assunto,
      body: { contentType: msg.html ? "HTML" : "Text", content: msg.html || msg.texto },
      toRecipients: destinatarios([msg.para]),
      ccRecipients: destinatarios(msg.cc),
      // Responder o aviso não deve virar conversa numa caixa que ninguém
      // lê. Aponta para quem pode resolver.
      replyTo: msg.responderPara ? destinatarios([msg.responderPara]) : undefined,
    },
    saveToSentItems: true,
  };

  const r = await fetch(`${GRAPH}/users/${encodeURIComponent(cfg.remetente)}/sendMail`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });

  if (r.status === 202) return { ok: true };

  const erro = await r.text().catch(() => "");
  // 403 aqui quase sempre é a Application Access Policy barrando a caixa,
  // ou o consentimento de administrador que não foi concedido.
  return {
    ok: false,
    status: r.status,
    // Repetir faz sentido em 429 (limite) e 5xx (instabilidade); em 4xx o
    // problema é a mensagem ou a permissão, e repetir só gera ruído.
    repetir: r.status === 429 || r.status >= 500,
    erro: `Graph ${r.status}: ${erro.slice(0, 500)}`,
  };
}

module.exports = { obterToken, enviarEmail };
