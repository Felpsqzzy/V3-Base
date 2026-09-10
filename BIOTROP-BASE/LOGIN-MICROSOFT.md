# Login corporativo Microsoft (Entra ID) — Biotrop Manutenção

Guia de implantação do login da plataforma de manutenção industrial. Base de dados:
`migrations/0001_base.sql` (arquivo `01-base.sql` desta pasta). Todo nome de tabela, coluna e
função citado aqui existe lá — nada foi inventado.

**O que a base já entrega para o login (conferido no arquivo):**

| Objeto | Para que serve no login |
|---|---|
| `core.usuario` | pessoa; tem `email citext UNIQUE`, `entra_object_id uuid UNIQUE`, `senha_hash`, `perfil_id`, `grupo_id`, `ativo`, `bloqueado`, `motivo_bloqueio`, `ultimo_login_em` |
| `core.email_autorizado` | lista de liberação: `email` (PK), `ativo`, `perfil_padrao`, `grupo_padrao`, `motivo`, `revogado_em` |
| `core.pode_autenticar(citext)` | função `STABLE` que devolve `(permitido, motivo, usuario_id)` — ponto único da regra |
| `app.vw_login_permitido` | estado de acesso de cada e-mail liberado, para a tela de gestão e para diagnóstico |
| `core.login_evento` | log de tentativa com `sucesso`, `motivo`, `ip`, `user_agent` (append-only para a aplicação) |
| `app.vw_usuario` | linha completa: perfil, `permissoes jsonb`, grupo, responsável direto |
| `core.perfil` / `core.perfil_permissao` | RBAC; `perfil` fixo `admin` protegido por trigger |
| GUC `app.usuario_id` e `app.usuario_email` | lidos por `core.fn_auditar()`, `almox.fn_sci_transicao()` e `almox.fn_scm_transicao()` |

**O que a base NÃO tem:** nenhuma `CREATE POLICY`. RLS entra na migration `0002`. Mesmo assim o
`SET LOCAL` é obrigatório **hoje**, porque sem ele a auditoria e o histórico de SCI/SCM ficam sem
autor (seção 9).

---

## 1. Decisões, resumidas

| Decisão | Escolha | Motivo |
|---|---|---|
| Fluxo OAuth | **Authorization Code + PKCE**, cliente confidencial (`Web`) | o code é trocado no servidor; token nunca passa pela URL nem pelo navegador |
| Onde o `id_token` é validado | **só no servidor** | o navegador não tem como validar assinatura de forma confiável |
| Sessão do app | cookie `httpOnly` assinado (HMAC-SHA256), sem token da Microsoft dentro | cookie roubado por XSS não vale nada se não for legível por JS; e não vira credencial do Graph |
| Autoridade sobre bloqueio | **o banco, a cada request** | bloquear alguém tem efeito no próximo clique, sem esperar a sessão expirar |
| Quem pode entrar | `core.email_autorizado.ativo` **e** usuário não bloqueado/inativo | ter conta Biotrop não é autorização |
| Provisionamento | no primeiro acesso, com `perfil_padrao` da liberação | ninguém cadastra usuário duas vezes |
| Logout padrão | **local** (mata o cookie do app) | logout federado tira a pessoa do Outlook e do Teams no mesmo navegador |
| Senha local | atrás de flag, desligada em produção | saída de emergência da fase 1, não caminho paralelo permanente |

---

## 2. O que pedir para a TI

### 2.1 Pré-requisito que trava tudo: DNS + TLS

O Entra ID aceita `http://` **apenas** em `localhost`. Para a VM Azure, o redirect URI tem que ser
`https://` com nome DNS e certificado válido. Sem isso o login corporativo não funciona fora da
máquina do desenvolvedor.

Pedido: nome DNS interno/externo para a VM (proposta: `manutencao.biotrop.com.br`) e certificado
(Let's Encrypt ou CA corporativa). Enquanto não existir, o desenvolvimento roda em
`http://localhost:3000` e a senha local (seção 11) sustenta a VM.

### 2.2 Registro de aplicativo — campos exatos

Portal: **Microsoft Entra ID → App registrations → New registration**.

| Campo | Valor a pedir |
|---|---|
| Name | `Biotrop Manutencao - Web` |
| Supported account types | **Accounts in this organizational directory only (Single tenant)** |
| Redirect URI — plataforma | **Web** (não SPA, não Mobile) |
| Redirect URI 1 (produção) | `https://manutencao.biotrop.com.br/auth/callback` |
| Redirect URI 2 (desenvolvimento) | `http://localhost:3000/auth/callback` |
| Front-channel logout URL | `https://manutencao.biotrop.com.br/auth/logout/front` |
| Post-logout redirect URI | `https://manutencao.biotrop.com.br/login?saiu=1` |
| Implicit grant — Access tokens | **desmarcado** |
| Implicit grant — ID tokens | **desmarcado** |

Plataforma **Web** e não **SPA**: o `code` é resgatado no servidor com `client_secret`. Se marcarem
SPA, o Entra aplica regras de cliente público e a troca com segredo é recusada.

Os dois "Implicit grant" desmarcados: com Authorization Code + PKCE eles são inúteis, e marcados
transformam a aplicação em alvo de ataque de resposta implícita (seção 3).

### 2.3 Permissões de API (mínimo real)

**API permissions → Microsoft Graph → Delegated:**

- `openid`
- `profile`
- `email`

É isso. **Não pedir** `User.Read.All`, `Directory.Read.All`, `Group.Read.All`, `GroupMember.Read.All`
nem `User.ReadBasic.All`. O nome e o e-mail vêm do próprio `id_token`; grupo, perfil e permissão
vivem em `core.grupo`, `core.perfil` e `core.perfil_permissao` — não no AD.

Se o tenant tiver consentimento de usuário desabilitado (comum), pedir **Grant admin consent**
para esses três escopos. Sem isso o primeiro login de cada pessoa para numa tela de consentimento
que ela não tem permissão de aceitar.

### 2.4 Claims opcionais

**Token configuration → Add optional claim → ID:**

| Claim | Por que |
|---|---|
| `email` | o claim `email` não vem por padrão em todo tenant; sem ele sobra só `preferred_username` |
| `login_hint` | permite logout sem tela de "escolha a conta" (seção 10) |

`family_name` e `given_name` já vêm com `profile`. **Não pedir claim de grupos** (`groups`): infla o
token e duplica informação que já está em `core.grupo`.

### 2.5 Segredo

**Certificates & secrets → New client secret**, validade 24 meses, descrição
`VM Azure - manutencao`. O valor aparece **uma vez**.

Combinar com a TI:

- o valor vai para o arquivo de ambiente da VM (`/etc/biotrop/manutencao.env`, modo `600`), nunca
  para o repositório;
- a data de expiração entra no calendário de quem mantém a plataforma — quando o segredo expira, o
  login para para todo mundo de uma vez, sem aviso prévio da aplicação;
- rotação: cria-se o segredo novo antes de apagar o velho, os dois convivem, troca-se a variável e
  reinicia-se o serviço.

Se a TI preferir certificado em vez de segredo, melhor ainda (não expira em segredo vazado por log),
mas exige `client_assertion` assinada — mais peça para a fase 1 manter. Segredo resolve.

### 2.6 O que a TI precisa devolver por escrito

```
TENANT_ID   = 00000000-0000-0000-0000-000000000000
CLIENT_ID   = 00000000-0000-0000-0000-000000000000
CLIENT_SECRET = <valor do segredo>
Expiração do segredo = AAAA-MM-DD
Domínios de e-mail válidos = biotrop.com.br (+ outros, se houver)
Admin consent concedido para openid/profile/email = sim/não
```

### 2.7 Registro separado para o e-mail (Microsoft Graph)

O envio de e-mail (`core.email_fila` → Graph) é **outro registro de aplicativo**:
`Biotrop Manutencao - Graph Mailer`, com permissão de **Application** `Mail.Send` e
**ApplicationAccessPolicy restringindo a caixa `manutencao@biotrop.com.br`**.

Motivo: `Mail.Send` de aplicação, sem policy, permite enviar como qualquer caixa do tenant.
Misturar isso no registro do login significaria que o segredo do site também é o segredo de enviar
e-mail como qualquer pessoa da Biotrop. Dois registros, dois segredos, dois raios de dano.
Detalhes no guia de e-mail.

---

## 3. Authorization Code + PKCE, e por que não implicit

### O fluxo

```
navegador                    aplicação (VM)                 Entra ID
   |                              |                             |
   |  GET /auth/login             |                             |
   |----------------------------->|                             |
   |                              | gera state, nonce,          |
   |                              | code_verifier               |
   |                              | grava os 3 em cookie        |
   |                              | assinado de 10 min          |
   |  302 -> /authorize?...       |                             |
   |     code_challenge=S256      |                             |
   |<-----------------------------|                             |
   |  autentica (senha + MFA)                                   |
   |----------------------------------------------------------->|
   |  302 /auth/callback?code=...&state=...                     |
   |<-----------------------------------------------------------|
   |  GET /auth/callback          |                             |
   |----------------------------->|                             |
   |                              | POST /token (server-to-     |
   |                              | server): code +             |
   |                              | code_verifier +             |
   |                              | client_secret               |
   |                              |---------------------------->|
   |                              |  id_token                   |
   |                              |<----------------------------|
   |                              | valida assinatura (JWKS),   |
   |                              | iss, aud, tid, nonce, exp   |
   |                              | consulta core.pode_autenticar
   |                              | grava core.login_evento     |
   |  302 / + Set-Cookie bt_sessao|                             |
   |<-----------------------------|                             |
```

### Por que PKCE mesmo tendo `client_secret`

O `code` viaja pela barra de endereços do navegador e fica no histórico, no log do proxy e no
`Referer`. Quem capturar o `code` sozinho não consegue nada: o `/token` exige o `code_verifier`,
que nunca saiu do servidor. E quem tiver só o `code_verifier` também não consegue nada: falta o
`client_secret`.

- `client_secret` prova **qual aplicação** está resgatando.
- `code_verifier` prova que é **a mesma sessão** que iniciou o login.

São defesas contra coisas diferentes. Usar as duas custa 4 linhas de código.

### Por que não implicit (`response_type=id_token token`)

1. O token chega no **fragmento da URL** (`#id_token=...`). Fragmento fica no histórico do
   navegador, é lido por qualquer script da página e vaza em extensão de navegador.
2. Não existe autenticação do cliente: qualquer um que conheça o `client_id` monta a mesma
   requisição.
3. Sem `code`, sem troca server-to-server: o token vira responsabilidade do front, e aí ele acaba
   no `localStorage` — que é exatamente o problema do qual esta plataforma está saindo.
4. O implicit flow está **obsoleto** para aplicações novas (OAuth 2.0 Security BCP). A Microsoft
   documenta Authorization Code + PKCE como o caminho para web app e para SPA.

Deixe os dois checkboxes de implicit grant **desmarcados** no registro (seção 2.2). Se estiverem
marcados, alguém consegue pedir `response_mode=fragment` e receber token no navegador mesmo que a
sua aplicação nunca faça isso.

---

## 4. Ambiente na VM

`/etc/biotrop/manutencao.env` (modo `600`, dono do serviço):

```bash
NODE_ENV=production
PORT=3000
APP_BASE_URL=https://manutencao.biotrop.com.br

# Entra ID - registro "Biotrop Manutencao - Web"
ENTRA_TENANT_ID=00000000-0000-0000-0000-000000000000
ENTRA_CLIENT_ID=00000000-0000-0000-0000-000000000000
ENTRA_CLIENT_SECRET=cole-aqui-o-valor-do-segredo
ENTRA_DOMINIOS_PERMITIDOS=biotrop.com.br

# Sessao: openssl rand -base64 48
SESSAO_SEGREDO=troque-por-48-bytes-aleatorios
SESSAO_HORAS=10

# Banco
DATABASE_URL=postgres://biotrop_app_login:senha@localhost:5432/biotrop

# Saida de emergencia da fase 1 (seção 11). Em producao: false.
LOGIN_LOCAL_ATIVO=false
```

`SESSAO_HORAS=10` cobre o turno com folga. Trocar `SESSAO_SEGREDO` invalida todas as sessões — é o
"desconectar todo mundo" de emergência, sem tabela de sessão.

O `01-base.sql` cria a role `biotrop_app` como `NOLOGIN` (é a role de privilégio). A connection
string usa um usuário que herda dela:

```sql
-- rodar uma vez, fora da migration (tem senha dentro)
CREATE USER biotrop_app_login WITH PASSWORD 'senha-forte-aqui' IN ROLE biotrop_app;
```

### Arquivos

```
src/
  auth/
    entra.js       # descoberta OIDC, JWKS, validacao do id_token
    sessao.js      # assinar/verificar o cookie
    rotas.js       # /auth/login, /auth/callback, /auth/logout, /auth/login-local
    autorizacao.js # consulta ao banco: pode entrar? provisiona? loga evento?
  middleware/
    sessao.js      # exigeSessao, exigePermissao
  db/
    index.js       # pool + comUsuario() (o SET LOCAL)
```

### Dependências

```bash
npm install express@4.19.2 cookie-parser@1.4.6 pg@8.11.5 jose@5.2.4 bcryptjs@2.4.3
```

`jose` faz a validação de JWT com JWKS remoto e cache de chave. `bcryptjs` em vez de `bcrypt`
nativo porque a VM da fase 1 faz `git pull` + build manual e não tem toolchain de compilação C
garantida.

---

## 5. `src/auth/entra.js` — descoberta, JWKS e validação do `id_token`

```js
'use strict';
const crypto = require('node:crypto');
const { createRemoteJWKSet, jwtVerify } = require('jose');

const TENANT = process.env.ENTRA_TENANT_ID;
const CLIENT_ID = process.env.ENTRA_CLIENT_ID;
const CLIENT_SECRET = process.env.ENTRA_CLIENT_SECRET;
const BASE = process.env.APP_BASE_URL.replace(/\/+$/, '');
const REDIRECT_URI = `${BASE}/auth/callback`;

// Issuer esperado, fixado no tenant. Endpoint v2.0.
const ISSUER = `https://login.microsoftonline.com/${TENANT}/v2.0`;
const AUTORIZA = `https://login.microsoftonline.com/${TENANT}/oauth2/v2.0/authorize`;
const TOKEN = `https://login.microsoftonline.com/${TENANT}/oauth2/v2.0/token`;
const FIM_SESSAO = `https://login.microsoftonline.com/${TENANT}/oauth2/v2.0/logout`;
const JWKS_URL = new URL(`https://login.microsoftonline.com/${TENANT}/discovery/v2.0/keys`);

// Uma instancia para o processo: faz cache das chaves e busca de novo sozinha
// quando aparece um kid desconhecido (rotacao de chave da Microsoft).
const JWKS = createRemoteJWKSet(JWKS_URL, {
  cacheMaxAge: 12 * 60 * 60 * 1000,
  cooldownDuration: 30 * 1000,
});

const DOMINIOS = (process.env.ENTRA_DOMINIOS_PERMITIDOS || '')
  .split(',').map((d) => d.trim().toLowerCase()).filter(Boolean);

const b64url = (buf) => buf.toString('base64url');

function gerarPkce() {
  const verifier = b64url(crypto.randomBytes(32));
  const challenge = b64url(crypto.createHash('sha256').update(verifier).digest());
  return { verifier, challenge };
}

function urlDeAutorizacao({ state, nonce, challenge }) {
  const q = new URLSearchParams({
    client_id: CLIENT_ID,
    response_type: 'code',
    redirect_uri: REDIRECT_URI,
    response_mode: 'query',
    scope: 'openid profile email',
    state,
    nonce,
    code_challenge: challenge,
    code_challenge_method: 'S256',
    prompt: 'select_account',
  });
  return `${AUTORIZA}?${q.toString()}`;
}

// Troca do code pelo token. Server-to-server: o segredo nao sai da VM.
async function trocarCodePorToken({ code, verifier }) {
  const corpo = new URLSearchParams({
    client_id: CLIENT_ID,
    client_secret: CLIENT_SECRET,
    grant_type: 'authorization_code',
    code,
    redirect_uri: REDIRECT_URI,
    code_verifier: verifier,
    scope: 'openid profile email',
  });

  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), 10000);
  let resp;
  try {
    resp = await fetch(TOKEN, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: corpo,
      signal: ctrl.signal,
    });
  } finally {
    clearTimeout(t);
  }

  const dados = await resp.json().catch(() => ({}));
  if (!resp.ok) {
    // error_description da Microsoft traz o codigo AADSTSxxxxx, que e o que
    // resolve o problema. Vai para o log do servidor, nao para a tela.
    const e = new Error(`token endpoint ${resp.status}: ${dados.error || 'erro'} ${dados.error_description || ''}`);
    e.publico = 'Nao foi possivel concluir o login com a conta Microsoft.';
    throw e;
  }
  return dados; // { id_token, access_token, expires_in, ... }
}

// Validacao do id_token. Ordem importa: assinatura antes de qualquer claim.
async function validarIdToken({ idToken, nonce }) {
  const { payload, protectedHeader } = await jwtVerify(idToken, JWKS, {
    algorithms: ['RS256'],   // nunca o alg do header: alg=none e HS256 ficam de fora
    issuer: ISSUER,          // trava o tenant
    audience: CLIENT_ID,     // token emitido para ESTA aplicacao
    clockTolerance: 60,      // 60s de folga de relogio da VM
    maxTokenAge: '10 minutes',
  });

  // jwtVerify ja cobriu assinatura, iss, aud, exp, nbf e iat.
  if (protectedHeader.alg !== 'RS256') throw erro('alg inesperado');
  if (payload.nonce !== nonce) throw erro('nonce divergente');
  if (payload.tid !== TENANT) throw erro('tenant divergente');
  if (!payload.oid) throw erro('token sem oid');

  const email = String(payload.email || payload.preferred_username || '').trim().toLowerCase();
  if (!email.includes('@')) throw erro('token sem e-mail utilizavel');

  // Conta de convidado do tenant (#EXT#) nao entra: quem entra e quadro Biotrop.
  if (email.includes('#ext#')) throw erro('conta de convidado nao permitida');

  const dominio = email.split('@')[1];
  if (DOMINIOS.length && !DOMINIOS.includes(dominio)) throw erro(`dominio nao permitido: ${dominio}`);

  return {
    email,                                  // citext no banco: caixa nao importa, normalizamos igual
    oid: payload.oid,                        // -> core.usuario.entra_object_id
    nome: (payload.name || '').trim() || email.split('@')[0],
    loginHint: payload.login_hint || null,   // -> logout sem tela de escolher conta
  };
}

function erro(msg) {
  const e = new Error(msg);
  e.publico = 'Nao foi possivel concluir o login com a conta Microsoft.';
  e.recusa = true;
  return e;
}

module.exports = {
  gerarPkce, urlDeAutorizacao, trocarCodePorToken, validarIdToken,
  FIM_SESSAO, REDIRECT_URI, ISSUER, b64url,
};
```

### O que cada validação impede

| Verificação | O que impede se faltar |
|---|---|
| assinatura via JWKS (`RS256`) | token forjado: qualquer um monta um JSON dizendo ser o admin |
| `algorithms: ['RS256']` | `alg: none` (assinatura vazia) e `alg: HS256` assinado com o `client_secret`, que a aplicação conhece |
| `issuer` fixo no tenant | token legítimo de **outro** tenant Microsoft valendo como login Biotrop |
| `audience = client_id` | token emitido para outra aplicação (ex: um app de teste de terceiros) sendo reaproveitado aqui |
| `nonce` | replay: token capturado numa sessão anterior injetado numa nova |
| `exp` / `nbf` / `iat` + `maxTokenAge` | token antigo válido para sempre |
| `tid` | conta pessoal/outro diretório passando pelo mesmo endpoint |
| domínio do e-mail | conta externa convidada no tenant entrando como se fosse funcionário |
| `state` (seção 7) | CSRF de login: alguém força a vítima a logar numa conta controlada pelo atacante |

`jwtVerify` do `jose` já faz assinatura, `iss`, `aud`, `exp`, `nbf` e `iat` na mesma chamada. O que
ele **não** faz e você tem que fazer: `nonce`, `tid` e a regra de domínio. Por isso estão explícitos.

**Nunca** use `jwt.decode()` / `decodeJwt()` para extrair o e-mail. Decodificar não valida nada: é
`base64` de um JSON que veio pela rede.

---

## 6. `src/auth/sessao.js` — cookie `httpOnly` assinado

O cookie guarda **identidade**, não autorização. Perfil, permissões e bloqueio são lidos do banco em
cada request (seção 9). Consequência prática: `UPDATE core.usuario SET bloqueado = true` derruba a
pessoa no próximo clique, sem tabela de sessão e sem esperar a expiração.

```js
'use strict';
const crypto = require('node:crypto');

const SEGREDO = process.env.SESSAO_SEGREDO;
if (!SEGREDO || SEGREDO.length < 32) {
  throw new Error('SESSAO_SEGREDO ausente ou curto (use openssl rand -base64 48)');
}
const HORAS = Number(process.env.SESSAO_HORAS || 10);
const PROD = process.env.NODE_ENV === 'production';

const COOKIE_SESSAO = 'bt_sessao';
const COOKIE_OAUTH = 'bt_oauth';

function hmac(texto) {
  return crypto.createHmac('sha256', SEGREDO).update(texto).digest('base64url');
}

function assinar(dados) {
  const corpo = Buffer.from(JSON.stringify(dados)).toString('base64url');
  return `${corpo}.${hmac(corpo)}`;
}

function verificar(valor) {
  if (typeof valor !== 'string' || !valor.includes('.')) return null;
  const [corpo, assinatura] = valor.split('.', 2);
  const esperada = Buffer.from(hmac(corpo));
  const recebida = Buffer.from(assinatura || '');
  // timingSafeEqual exige mesmo tamanho; comparar antes evita o throw.
  if (esperada.length !== recebida.length) return null;
  if (!crypto.timingSafeEqual(esperada, recebida)) return null;
  try {
    const dados = JSON.parse(Buffer.from(corpo, 'base64url').toString('utf8'));
    if (!dados.exp || dados.exp < Math.floor(Date.now() / 1000)) return null;
    return dados;
  } catch {
    return null;
  }
}

const OPCOES_BASE = {
  httpOnly: true,   // JS da pagina nao le: XSS nao rouba a sessao
  secure: PROD,     // so por https em producao; false no localhost para dev funcionar
  sameSite: 'lax',  // Lax, nao Strict: o retorno da Microsoft e navegacao GET de outro site
  path: '/',
};

function gravarSessao(res, { usuarioId, email, via, loginHint }) {
  const agora = Math.floor(Date.now() / 1000);
  const dados = {
    sub: usuarioId,
    email,
    via,                 // 'entra' | 'senha'
    lh: loginHint || null,
    iat: agora,
    exp: agora + HORAS * 3600,
  };
  res.cookie(COOKIE_SESSAO, assinar(dados), { ...OPCOES_BASE, maxAge: HORAS * 3600 * 1000 });
  return dados;
}

function lerSessao(req) {
  return verificar(req.cookies?.[COOKIE_SESSAO]);
}

function limparSessao(res) {
  res.clearCookie(COOKIE_SESSAO, OPCOES_BASE);
}

// Estado do fluxo OAuth (state, nonce, code_verifier). Cookie proprio, 10 minutos,
// apagado no callback. Nao vai junto da sessao porque tem vida e finalidade diferentes.
function gravarOauth(res, dados) {
  res.cookie(COOKIE_OAUTH, assinar({ ...dados, exp: Math.floor(Date.now() / 1000) + 600 }),
    { ...OPCOES_BASE, maxAge: 600 * 1000 });
}
function lerOauth(req) { return verificar(req.cookies?.[COOKIE_OAUTH]); }
function limparOauth(res) { res.clearCookie(COOKIE_OAUTH, OPCOES_BASE); }

module.exports = {
  gravarSessao, lerSessao, limparSessao,
  gravarOauth, lerOauth, limparOauth,
  COOKIE_SESSAO, COOKIE_OAUTH,
};
```

Três detalhes que dão trabalho quando errados:

- **`sameSite: 'lax'` e não `'strict'`.** O `/auth/callback` é uma navegação vinda de
  `login.microsoftonline.com`. Com `Strict`, o cookie `bt_oauth` não é enviado e o callback falha
  com "state ausente" — o erro mais comum nesta integração.
- **`secure: PROD`.** Em `http://localhost` um cookie `Secure` é descartado silenciosamente pelo
  navegador. Em produção ele é obrigatório.
- **`timingSafeEqual` com checagem de tamanho antes.** A função lança exceção se os buffers têm
  tamanhos diferentes, e um `catch` genérico transformaria isso em "cookie válido" em algum refactor
  futuro.

Nada de token da Microsoft dentro do cookie. O `id_token` é usado, validado e descartado; o
`access_token` do Graph não é nem guardado, porque a aplicação não chama Graph em nome do usuário.

---

## 7. `src/auth/autorizacao.js` — a decisão no banco

Toda a regra de quem entra está em `core.pode_autenticar(citext)`. A aplicação não reimplementa isso.
O que ela adiciona é: buscar o `perfil_padrao` da liberação, provisionar no primeiro acesso, amarrar
o `oid` e gravar `core.login_evento`.

### 7.1 A consulta de autorização

```sql
-- $1 = e-mail extraido do id_token JA VALIDADO
SELECT c.permitido,
       c.motivo,
       c.usuario_id,
       (a.email IS NOT NULL)  AS tem_liberacao,
       a.ativo                AS liberacao_ativa,
       a.perfil_padrao,
       a.grupo_padrao,
       u.nome                 AS usuario_nome,
       u.perfil_id,
       u.ativo                AS usuario_ativo,
       u.bloqueado,
       u.motivo_bloqueio,
       u.entra_object_id
  FROM core.pode_autenticar($1::citext) c
  LEFT JOIN core.email_autorizado a ON a.email = $1::citext
  LEFT JOIN core.usuario          u ON u.email = $1::citext;
```

`core.pode_autenticar` é `RETURNS TABLE` construída sobre `(SELECT p_email) LEFT JOIN ...`, então
devolve **sempre exatamente uma linha**, mesmo para e-mail que não existe em lugar nenhum. Não trate
`rowCount = 0` como "não autorizado": se vier zero linha, algo está errado na conexão, não no acesso.

`app.vw_login_permitido` existe e é ótima para a tela de gestão de acesso e para diagnóstico, mas
**não serve para o callback**: ela parte de `core.email_autorizado`, então um e-mail não liberado
simplesmente não aparece — você perderia a diferença entre "não autorizado" e "erro de query".

### 7.2 Código

```js
'use strict';
const { pool } = require('../db');

const SQL_AUTORIZACAO = `
SELECT c.permitido, c.motivo, c.usuario_id,
       (a.email IS NOT NULL) AS tem_liberacao,
       a.ativo               AS liberacao_ativa,
       a.perfil_padrao, a.grupo_padrao,
       u.nome AS usuario_nome, u.perfil_id, u.ativo AS usuario_ativo,
       u.bloqueado, u.motivo_bloqueio, u.entra_object_id
  FROM core.pode_autenticar($1::citext) c
  LEFT JOIN core.email_autorizado a ON a.email = $1::citext
  LEFT JOIN core.usuario          u ON u.email = $1::citext`;

async function registrarEvento(cli, { email, usuarioId, sucesso, motivo, req }) {
  await cli.query(
    `INSERT INTO core.login_evento (email, usuario_id, sucesso, motivo, ip, user_agent)
     VALUES ($1::citext, $2, $3, $4, nullif($5, '')::inet, $6)`,
    [email, usuarioId || null, sucesso, motivo,
     ipDoRequest(req), (req.get('user-agent') || '').slice(0, 400)]
  );
}

function ipDoRequest(req) {
  // Atras do nginx da VM: X-Forwarded-For, primeiro endereco. Sem proxy: req.ip.
  const xff = (req.get('x-forwarded-for') || '').split(',')[0].trim();
  const ip = xff || req.ip || '';
  return ip.replace(/^::ffff:/, '');   // inet do Postgres nao aceita IPv4 mapeado
}

/**
 * Decide o acesso, provisiona no primeiro login e registra o evento.
 * Retorna { ok: true, usuario } ou { ok: false, motivo, codigo }.
 */
async function autorizarEntrada({ email, oid, nome, req }) {
  const cli = await pool.connect();
  try {
    await cli.query('BEGIN');
    // A aplicacao age como ela mesma neste momento: quem esta entrando ainda nao
    // tem identidade confirmada. Auditoria do provisionamento sai como sistema.
    await cli.query(`SELECT set_config('app.usuario_email', $1, true)`, ['login@sistema']);

    const { rows } = await cli.query(SQL_AUTORIZACAO, [email]);
    const r = rows[0];

    if (!r.tem_liberacao) {
      await registrarEvento(cli, { email, sucesso: false, motivo: 'e-mail nao consta na lista de autorizados', req });
      await cli.query('COMMIT');
      return { ok: false, codigo: 'nao_autorizado', motivo: r.motivo };
    }
    if (!r.permitido) {
      // motivo vem pronto de core.pode_autenticar: 'autorizacao revogada',
      // 'bloqueado: <motivo>' ou 'usuario inativo'.
      await registrarEvento(cli, { email, usuarioId: r.usuario_id, sucesso: false, motivo: r.motivo, req });
      await cli.query('COMMIT');
      const codigo = r.bloqueado ? 'bloqueado' : (r.usuario_ativo === false ? 'inativo' : 'revogado');
      return { ok: false, codigo, motivo: r.motivo };
    }

    // oid divergente: a conta do AD foi recriada, ou alguem esta reaproveitando
    // um e-mail. Nao entra no automatico - exige decisao de administrador.
    if (oid && r.entra_object_id && r.entra_object_id !== oid) {
      await registrarEvento(cli, {
        email, usuarioId: r.usuario_id, sucesso: false,
        motivo: `oid do Entra divergente (cadastrado ${r.entra_object_id}, recebido ${oid})`, req,
      });
      await cli.query('COMMIT');
      return { ok: false, codigo: 'oid_divergente', motivo: 'vinculo com a conta Microsoft nao confere' };
    }

    let usuarioId = r.usuario_id;

    if (!usuarioId) {
      // Primeiro acesso: cria a pessoa com o perfil da liberacao.
      // Sem perfil_padrao cai em 'viewer' (nenhuma permissao no seed): a pessoa
      // entra, ve o basico e o administrador ajusta. Chutar 'tecnico' seria dar
      // acesso que ninguem liberou.
      const ins = await cli.query(
        `INSERT INTO core.usuario (nome, email, entra_object_id, perfil_id, grupo_id, ultimo_login_em)
         VALUES ($1, $2::citext, $3::uuid, coalesce($4, 'viewer'), $5::uuid, now())
         RETURNING id, perfil_id`,
        [nome, email, oid, r.perfil_padrao, r.grupo_padrao]
      );
      usuarioId = ins.rows[0].id;
      await registrarEvento(cli, {
        email, usuarioId, sucesso: true,
        motivo: `primeiro acesso - usuario criado com perfil ${ins.rows[0].perfil_id}`, req,
      });
    } else {
      // Amarra o oid na primeira entrada por Entra ID de um usuario que veio da
      // migracao (entra_object_id nulo).
      await cli.query(
        `UPDATE core.usuario
            SET entra_object_id = coalesce(entra_object_id, $2::uuid),
                nome            = coalesce(nullif(btrim($3), ''), nome),
                ultimo_login_em = now()
          WHERE id = $1`,
        [usuarioId, oid, nome]
      );
      await registrarEvento(cli, { email, usuarioId, sucesso: true, motivo: 'ok', req });
    }

    await cli.query('COMMIT');
    return { ok: true, usuario: { id: usuarioId, email } };
  } catch (e) {
    await cli.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    cli.release();
  }
}

module.exports = { autorizarEntrada, registrarEvento, ipDoRequest, SQL_AUTORIZACAO };
```

### 7.3 Usuário bloqueado, inativo e não autorizado

| Situação no banco | `core.pode_autenticar` | O que a pessoa vê | O que fica registrado |
|---|---|---|---|
| e-mail não está em `core.email_autorizado` | `permitido = false`, motivo `e-mail nao consta na lista de autorizados` | "Sua conta Microsoft foi autenticada, mas o acesso à plataforma não está liberado. Procure o administrador." | `core.login_evento` com `sucesso = false` e o motivo |
| `email_autorizado.ativo = false` | `permitido = false`, `autorizacao revogada` | mesma tela | idem |
| `usuario.bloqueado = true` | `permitido = false`, `bloqueado: <motivo_bloqueio>` | "Acesso bloqueado. Procure o administrador." (o `motivo_bloqueio` **não** vai para a tela) | idem, com o motivo completo |
| `usuario.ativo = false` | `permitido = false`, `usuario inativo` | "Acesso inativo." | idem |
| liberado, usuário ainda não existe | `permitido = true`, `usuario_id IS NULL` | entra; usuário criado com `perfil_padrao` | evento de sucesso com `primeiro acesso` |

O bloqueio é decidido **depois** da autenticação Microsoft, de propósito: assim o log tem o e-mail
real de quem tentou. E o `motivo_bloqueio` fica no log do servidor e na tela do administrador, não na
tela de quem tentou entrar — motivo de bloqueio costuma ser assunto de RH.

Bloquear alguém agora:

```sql
-- ck_usuario_bloqueio exige o motivo: bloquear sem justificar nao passa
UPDATE core.usuario
   SET bloqueado = true, motivo_bloqueio = 'afastamento - solicitado por RH em 2026-09-09'
 WHERE email = 'pessoa@biotrop.com.br';
```

Isso já derruba a sessão ativa no próximo request (seção 9). Revogar de verdade o acesso, para a
pessoa nem chegar a autenticar:

```sql
UPDATE core.email_autorizado
   SET ativo = false, revogado_em = now(), motivo = 'desligamento'
 WHERE email = 'pessoa@biotrop.com.br';
```

---

## 8. `src/auth/rotas.js` — `/auth/login` e `/auth/callback`

```js
'use strict';
const crypto = require('node:crypto');
const express = require('express');
const entra = require('./entra');
const sessao = require('./sessao');
const { autorizarEntrada } = require('./autorizacao');

const router = express.Router();

// ---------------------------------------------------------------- inicio
router.get('/auth/login', (req, res) => {
  const state = entra.b64url(crypto.randomBytes(24));
  const nonce = entra.b64url(crypto.randomBytes(24));
  const { verifier, challenge } = entra.gerarPkce();

  // Para onde voltar depois do login. So caminho interno: um "retorno" com
  // host externo transformaria o /auth/login em redirecionador aberto.
  const bruto = String(req.query.retorno || '/');
  const retorno = /^\/(?!\/)[A-Za-z0-9\-._~/?#[\]@!$&'()*+,;=%]*$/.test(bruto) ? bruto : '/';

  sessao.gravarOauth(res, { state, nonce, verifier, retorno });
  res.redirect(302, entra.urlDeAutorizacao({ state, nonce, challenge }));
});

// ---------------------------------------------------------------- retorno
router.get('/auth/callback', async (req, res) => {
  const est = sessao.lerOauth(req);
  sessao.limparOauth(res);   // uso unico: nao reaproveita state/nonce/verifier

  // Erro devolvido pelo proprio Entra (consentimento negado, MFA cancelado...)
  if (req.query.error) {
    console.warn('[login] entra recusou:', req.query.error, req.query.error_description);
    return res.redirect(302, '/login?erro=microsoft');
  }
  if (!est) {
    // Tipicamente: cookie expirado (>10 min na tela da Microsoft), ou SameSite=Strict.
    return res.redirect(302, '/login?erro=sessao_expirada');
  }
  const code = typeof req.query.code === 'string' ? req.query.code : '';
  const stateRecebido = typeof req.query.state === 'string' ? req.query.state : '';
  if (!code || !stateRecebido) return res.redirect(302, '/login?erro=resposta_incompleta');

  // Comparacao de state em tempo constante.
  const a = Buffer.from(est.state);
  const b = Buffer.from(stateRecebido);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
    console.warn('[login] state divergente - possivel CSRF de login');
    return res.redirect(302, '/login?erro=state');
  }

  try {
    const tokens = await entra.trocarCodePorToken({ code, verifier: est.verifier });
    if (!tokens.id_token) throw new Error('resposta sem id_token');

    // O e-mail sai DAQUI e de nenhum outro lugar.
    const identidade = await entra.validarIdToken({ idToken: tokens.id_token, nonce: est.nonce });

    const r = await autorizarEntrada({ ...identidade, req });
    if (!r.ok) {
      console.warn('[login] recusado:', identidade.email, r.codigo, r.motivo);
      return res.redirect(302, `/login?erro=${encodeURIComponent(r.codigo)}`);
    }

    sessao.gravarSessao(res, {
      usuarioId: r.usuario.id,
      email: identidade.email,
      via: 'entra',
      loginHint: identidade.loginHint,
    });
    return res.redirect(302, est.retorno || '/');
  } catch (e) {
    // Nao logar o id_token nem o code: um e credencial, o outro e reutilizavel
    // por segundos. Loga o que resolve: mensagem e codigo AADSTS.
    console.error('[login] falha no callback:', e.message);
    return res.redirect(302, '/login?erro=falha');
  }
});

module.exports = router;
```

### Mensagens da tela `/login`

O parâmetro `erro` é um código, nunca o texto do banco. A tela traduz:

```js
const MENSAGENS = {
  nao_autorizado:   'Sua conta Microsoft foi autenticada, mas o acesso a plataforma nao esta liberado. Procure o administrador da manutencao.',
  revogado:         'Seu acesso a plataforma foi revogado. Procure o administrador da manutencao.',
  bloqueado:        'Acesso bloqueado. Procure o administrador da manutencao.',
  inativo:          'Seu cadastro esta inativo. Procure o administrador da manutencao.',
  oid_divergente:   'O vinculo com a conta Microsoft nao confere. Procure o administrador da manutencao.',
  sessao_expirada:  'A tentativa de login expirou. Tente novamente.',
  state:            'A tentativa de login nao pode ser concluida. Tente novamente.',
  microsoft:        'O login pela conta Microsoft foi interrompido.',
  falha:            'Nao foi possivel concluir o login. Se persistir, procure o administrador.',
};
```

Nenhuma delas diz se o e-mail existe, se está bloqueado ou se nunca foi liberado — quem está de fora
não precisa dessa informação, e ela é a mesma para todos os casos "procure o administrador". O
detalhe que resolve fica em `core.login_evento` e no log do servidor.

### Montagem no `app.js`

```js
'use strict';
const express = require('express');
const cookieParser = require('cookie-parser');
const rotasAuth = require('./auth/rotas');
const { exigeSessao, exigePermissao } = require('./middleware/sessao');

const app = express();
app.set('trust proxy', 1);          // nginx da VM na frente
app.disable('x-powered-by');
app.use(express.json({ limit: '2mb' }));
app.use(cookieParser());

app.use(rotasAuth);                 // rotas publicas de login
app.get('/login', (req, res) => res.render('login', { erro: req.query.erro }));
app.get('/saude', (req, res) => res.json({ ok: true }));

app.use(exigeSessao);               // daqui para baixo, tudo exige sessao

app.get('/api/eu', (req, res) => res.json(req.usuario));
app.post('/api/scm/:id/aprovar',
  exigePermissao('almoxarifado.scm_aprovacao'),
  require('./scm/aprovar'));

app.listen(Number(process.env.PORT || 3000));
```

A ordem importa: `exigeSessao` entra **depois** das rotas públicas (`/auth/*`, `/login`, `/saude`) e
**antes** de tudo o mais. Assim uma rota nova nasce protegida por padrão — o contrário de proteger
rota por rota e esquecer uma.

---

## 9. `SET LOCAL app.usuario_id` — o elo entre a sessão e o banco

### Quem consome esses dois GUCs hoje

| Função no `01-base.sql` | Lê | Se vier nulo |
|---|---|---|
| `core.fn_auditar()` (linha 216) | `app.usuario_email` | `core.auditoria.ator_email` fica `NULL`: a trilha registra a mudança sem dizer quem fez |
| `almox.fn_sci_transicao()` (linhas 760-761) | `app.usuario_email` e `app.usuario_id` | `almox.sci_historico.por_usuario_id` e `por_nome` ficam nulos: a timeline da SCI perde o autor |
| `almox.fn_scm_transicao()` (linhas 928-929) | `app.usuario_email` e `app.usuario_id` | idem em `almox.scm_historico` |

As três leem com `current_setting('app.usuario_id', true)` — o `true` é `missing_ok`, então **não dá
erro**: simplesmente grava nulo. É por isso que esse esquecimento passa despercebido até alguém
perguntar "quem mudou essa SCM?".

RLS (migration `0002`) vai ler exatamente o mesmo `app.usuario_id`. Quando as policies existirem, o
GUC ausente deixa de ser perda de rastro e passa a ser "a consulta não devolve nada".

### `src/db/index.js`

```js
'use strict';
const { Pool } = require('pg');

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 10,
  idleTimeoutMillis: 30000,
  application_name: 'biotrop-manutencao',
});

/**
 * Abre transacao, declara quem e o usuario e roda o trabalho.
 * TODA escrita da aplicacao passa por aqui.
 */
async function comUsuario(usuario, trabalho) {
  const cli = await pool.connect();
  try {
    await cli.query('BEGIN');

    // set_config(nome, valor, is_local=true) e o SET LOCAL parametrizavel.
    // "SET LOCAL app.usuario_id = $1" NAO funciona: SET nao aceita bind
    // parameter. Concatenar o uuid na string seria injecao de SQL.
    await cli.query(
      `SELECT set_config('app.usuario_id', $1, true),
              set_config('app.usuario_email', $2, true)`,
      [usuario.id, usuario.email]
    );

    const r = await trabalho(cli);
    await cli.query('COMMIT');
    return r;
  } catch (e) {
    await cli.query('ROLLBACK').catch(() => {});
    throw e;
  } finally {
    cli.release();   // is_local=true: o COMMIT/ROLLBACK ja limpou os GUCs
  }
}

module.exports = { pool, comUsuario };
```

Uso:

```js
// POST /api/scm/:id/aprovar
module.exports = async function aprovar(req, res, next) {
  try {
    const scm = await comUsuario(req.usuario, async (cli) => {
      // ck_scm_decisao_registrada exige decidido_por_id e decidido_em junto com
      // o status 'aprovada'. E o WHERE confere que quem clicou e o aprovador
      // congelado da solicitacao: permissao no perfil nao autoriza aprovar
      // a compra de outra equipe.
      const { rows } = await cli.query(
        `UPDATE almox.scm
            SET status           = 'aprovada',
                decidido_por_id  = $2::uuid,
                decidido_em      = now(),
                observacao_lider = nullif(btrim($3), '')
          WHERE id = $1::uuid
            AND status = 'pendente_aprovacao_lider'
            AND aprovador_email = $4::citext
        RETURNING id, codigo, status, decidido_em`,
        [req.params.id, req.usuario.id, req.body?.observacao || '', req.usuario.email]
      );
      if (!rows[0]) { const e = new Error('scm nao pendente ou nao e sua para aprovar'); e.status = 409; throw e; }
      return rows[0];
    });
    res.json(scm);
  } catch (e) { next(e); }
};
```

O `UPDATE` dispara `almox.fn_scm_transicao()`, que lê o `app.usuario_id` definido três linhas acima,
grava `almox.scm_historico` com o autor certo e enfileira o e-mail em `core.email_fila` — tudo na
mesma transação. Se o `COMMIT` falhar, não sobra histórico órfão nem e-mail de aprovação que não
aconteceu.

Repare que a autorização tem duas camadas e as duas são necessárias:
`exigePermissao('almoxarifado.scm_aprovacao')` diz que o perfil pode aprovar SCM; o
`AND aprovador_email = $4` diz que **esta** SCM é dele. Sem a segunda, qualquer líder aprova a compra
de qualquer outro grupo. Quando o RLS entrar na `0002`, essa segunda camada vira policy e o `AND`
passa a ser redundante — mas até lá ele é a única coisa que separa as equipes.

### Os quatro erros clássicos

1. **`SET LOCAL` fora de transação.** Sem `BEGIN`, o Postgres emite
   `WARNING: SET LOCAL can only be used in transaction blocks` e **ignora** o valor. O `pg` não
   transforma isso em exceção. Resultado: auditoria anônima, e ninguém percebe.
2. **`SET` em vez de `SET LOCAL`.** Com pool de conexões, o valor sobrevive ao `release()` e a
   próxima requisição — de **outra pessoa** — herda o `app.usuario_id` de quem usou a conexão antes.
   Com RLS ligado, isso é vazamento de dado entre usuários. Use sempre `is_local = true`.
3. **Conexão diferente.** `pool.query(...)` pega qualquer conexão livre. Se o `set_config` foi numa e
   o `UPDATE` em outra, o trigger não vê nada. Sempre o mesmo `cli`.
4. **Interpolar o uuid na string SQL.** `SET LOCAL app.usuario_id = '${req.query.id}'` é injeção de
   SQL direta. `set_config` com bind parameter resolve, e o `id` vem do cookie assinado, não da URL.

Verificação de um minuto, depois de aprovar uma SCM pela tela:

```sql
SELECT h.para, h.por_nome, h.por_usuario_id, h.em
  FROM almox.scm_historico h
 ORDER BY h.em DESC LIMIT 5;

SELECT a.tabela, a.operacao, a.ator, a.ator_email, a.em
  FROM core.auditoria a
 ORDER BY a.em DESC LIMIT 5;
```

`por_nome` e `ator_email` preenchidos: o `SET LOCAL` está no lugar. Nulos: a rota não passou por
`comUsuario`.

### `src/middleware/sessao.js`

```js
'use strict';
const { pool } = require('../db');
const sessao = require('../auth/sessao');

// app.vw_usuario ja resolve perfil, permissoes jsonb, grupo e responsavel direto.
const SQL_EU = `
SELECT id, nome, email, ativo, bloqueado, perfil_id, perfil_nome,
       grupo_id, grupo_nome, responsavel_id, responsavel_email,
       coalesce(permissoes, '{}'::jsonb) AS permissoes
  FROM app.vw_usuario
 WHERE id = $1::uuid`;

async function exigeSessao(req, res, next) {
  const s = sessao.lerSessao(req);
  if (!s) return recusar(req, res, 401, 'sessao ausente ou expirada');

  try {
    // O banco e a autoridade a cada request: bloqueio e troca de perfil valem
    // no proximo clique, sem esperar o cookie expirar.
    const { rows } = await pool.query(SQL_EU, [s.sub]);
    const u = rows[0];

    if (!u)            { sessao.limparSessao(res); return recusar(req, res, 401, 'usuario nao existe mais'); }
    if (u.bloqueado)   { sessao.limparSessao(res); return recusar(req, res, 403, 'usuario bloqueado'); }
    if (!u.ativo)      { sessao.limparSessao(res); return recusar(req, res, 403, 'usuario inativo'); }
    // Cookie assinado com o e-mail de antes de uma troca de e-mail no cadastro.
    if (String(u.email).toLowerCase() !== String(s.email).toLowerCase()) {
      sessao.limparSessao(res);
      return recusar(req, res, 401, 'e-mail da sessao divergente');
    }

    req.usuario = u;      // { id, email, perfil_id, permissoes, grupo_id, ... }
    req.via = s.via;      // 'entra' | 'senha'
    return next();
  } catch (e) { return next(e); }
}

function exigePermissao(chave) {
  const [area, nome] = chave.split('.');   // ex: 'almoxarifado.scm_aprovacao'
  return (req, res, next) => {
    // app.vw_perfil_permissoes devolve { almoxarifado: { scm_aprovacao: true }, ... };
    // permissao ausente = nao concedida.
    if (req.usuario?.permissoes?.[area]?.[nome] === true) return next();
    return recusar(req, res, 403, `sem permissao ${chave}`);
  };
}

function recusar(req, res, codigo, motivo) {
  if (req.path.startsWith('/api/') || req.get('accept')?.includes('application/json')) {
    return res.status(codigo).json({ erro: motivo });
  }
  const retorno = encodeURIComponent(req.originalUrl);
  return res.redirect(302, codigo === 401
    ? `/auth/login?retorno=${retorno}`
    : '/login?erro=sem_permissao');
}

module.exports = { exigeSessao, exigePermissao };
```

Custo: uma consulta por request numa view com join por chave primária. Em troca, não existe tabela de
sessão para manter e revogar acesso é um `UPDATE` em `core.usuario`.

### Nota sobre RLS (migration 0002)

Duas coisas que a `0002` vai precisar e que dependem de como a role é usada hoje:

- `biotrop_app` **não pode ser dona** das tabelas nem ter `BYPASSRLS`. Dono de tabela ignora policy,
  a menos que a tabela tenha `FORCE ROW LEVEL SECURITY`. Rode as migrations com o dono do banco e
  deixe a aplicação com a role sem posse — que é como o `01-base.sql` já está desenhado (roles
  `NOLOGIN` de privilégio, `GRANT` explícito por tabela).
- As policies devem usar `nullif(current_setting('app.usuario_id', true), '')::uuid`, o mesmo padrão
  já usado pelos triggers. GUC vazio virando `''::uuid` dá erro de sintaxe de uuid em produção.

### Ruído de auditoria no login (achado)

`UPDATE core.usuario SET ultimo_login_em = now()` altera a linha, então `tg_audit_usuario` grava uma
linha em `core.auditoria` com a pessoa inteira em `antes`/`depois` a cada login. Alguns logins por
pessoa por dia: é ruído, não problema — `core.login_evento` já é o registro próprio de login. Se
incomodar, a `0002` resolve com uma guarda na função:

```sql
-- dentro de core.fn_auditar(), no ramo UPDATE, antes do INSERT:
IF to_jsonb(OLD) - 'ultimo_login_em' - 'atualizado_em'
   = to_jsonb(NEW) - 'ultimo_login_em' - 'atualizado_em' THEN
  RETURN NEW;   -- mudou so o carimbo de login: nao e alteracao de cadastro
END IF;
```

---

## 10. Logout

Dois logouts diferentes, e a diferença importa para quem usa a plataforma:

| | O que faz | Quando usar |
|---|---|---|
| **Local** (padrão do botão "Sair") | apaga o cookie `bt_sessao` | uso normal: a pessoa sai da plataforma e continua no Outlook e no Teams |
| **Federado** (`end_session_endpoint`) | apaga o cookie **e** encerra a sessão Microsoft naquele navegador | computador compartilhado do chão de fábrica |

Fazer logout federado por padrão gera reclamação legítima: clicar "Sair" da plataforma de manutenção
derruba o Outlook da pessoa. Então o botão faz local, e existe uma opção explícita para o federado.

```js
// src/auth/rotas.js (continuacao)

// POST, nao GET: logout por GET e acionavel por <img src="/auth/logout">
// em qualquer site ou e-mail, derrubando a sessao da pessoa sem ela pedir.
router.post('/auth/logout', (req, res) => {
  const s = sessao.lerSessao(req);
  sessao.limparSessao(res);

  if (req.body?.microsoft !== 'sim') {
    return res.redirect(302, '/login?saiu=1');
  }

  const q = new URLSearchParams({
    post_logout_redirect_uri: `${process.env.APP_BASE_URL.replace(/\/+$/, '')}/login?saiu=1`,
  });
  // logout_hint vem do claim opcional login_hint (secao 2.4): evita a tela
  // "escolha a conta para sair" quando ha varias contas no navegador.
  if (s?.lh) q.set('logout_hint', s.lh);
  return res.redirect(302, `${entra.FIM_SESSAO}?${q.toString()}`);
});

// Front-channel logout: a Microsoft chama esta URL num iframe quando a pessoa
// sai por outro aplicativo do tenant. Sem estado no servidor, so limpa o cookie.
router.get('/auth/logout/front', (req, res) => {
  sessao.limparSessao(res);
  res.set('Cache-Control', 'no-store');
  res.status(200).end();
});
```

Formulário do botão (POST, com o cookie `SameSite=Lax` sendo enviado porque é same-site):

```html
<form method="post" action="/auth/logout">
  <button type="submit">Sair</button>
  <label><input type="checkbox" name="microsoft" value="sim"> sair também da conta Microsoft</label>
</form>
```

`post_logout_redirect_uri` tem que estar cadastrado no registro do aplicativo (seção 2.2), senão o
Entra ignora e deixa a pessoa na tela genérica da Microsoft.

O cookie apagado encerra o acesso de fato: não existe token da Microsoft guardado no servidor para
continuar valendo, e o `access_token` do Graph não foi persistido.

---

## 11. Conviver com o login local por senha na transição

### Por que existe

Fase 1: VM Azure, `git pull` + build manual, uma pessoa mantendo. Enquanto DNS, certificado e
registro no Entra não estiverem prontos (seção 2.1), o site precisa subir e alguém precisa entrar.
Depois disso a senha local continua sendo a saída para "o Entra está fora" ou "o segredo expirou no
sábado".

O `01-base.sql` já deixou o terreno certo: `core.usuario.senha_hash` existe, é `NULL` para todo
mundo, e `mig.importar_usuarios()` **não traz** a senha em texto que estava no `localStorage`. Ou
seja: hoje ninguém consegue entrar por senha nem se a flag estiver ligada. É preciso criar o hash na
mão, para uma conta específica.

### A rota

```js
// src/auth/rotas.js (continuacao)
const bcrypt = require('bcryptjs');
const { pool } = require('../db');
const { registrarEvento, ipDoRequest, SQL_AUTORIZACAO } = require('./autorizacao');

const LOCAL_ATIVO = process.env.LOGIN_LOCAL_ATIVO === 'true';

router.post('/auth/login-local', async (req, res) => {
  if (!LOCAL_ATIVO) return res.status(404).json({ erro: 'nao disponivel' });

  const email = String(req.body?.email || '').trim().toLowerCase();
  const senha = String(req.body?.senha || '');
  if (!email.includes('@') || senha.length < 8) {
    return res.status(400).json({ erro: 'informe e-mail e senha' });
  }

  const cli = await pool.connect();
  try {
    await cli.query('BEGIN');
    await cli.query(`SELECT set_config('app.usuario_email', $1, true)`, ['login@sistema']);

    // Freio de forca bruta lendo o proprio log: 5 falhas em 15 min por e-mail.
    // Usa o indice ix_login_evento_email (email, em DESC) que a base ja tem.
    const { rows: [t] } = await cli.query(
      `SELECT count(*)::int AS falhas
         FROM core.login_evento
        WHERE email = $1::citext AND NOT sucesso AND em > now() - interval '15 minutes'`,
      [email]
    );
    if (t.falhas >= 5) {
      await registrarEvento(cli, { email, sucesso: false, motivo: 'bloqueio temporario por tentativas', req });
      await cli.query('COMMIT');
      return res.status(429).json({ erro: 'muitas tentativas, aguarde 15 minutos' });
    }

    const { rows: [r] } = await cli.query(SQL_AUTORIZACAO, [email]);
    const { rows: [h] } = await cli.query(
      `SELECT senha_hash FROM core.usuario WHERE email = $1::citext`, [email]
    );

    // Uma unica mensagem para e-mail inexistente, sem senha local e senha errada:
    // nao entregamos quem tem cadastro. O motivo real vai para o log.
    const generico = { erro: 'e-mail ou senha invalidos' };

    if (!h?.senha_hash) {
      await registrarEvento(cli, { email, usuarioId: r.usuario_id, sucesso: false, motivo: 'senha local: sem hash cadastrado', req });
      await cli.query('COMMIT');
      return res.status(401).json(generico);
    }
    if (!(await bcrypt.compare(senha, h.senha_hash))) {
      await registrarEvento(cli, { email, usuarioId: r.usuario_id, sucesso: false, motivo: 'senha local: senha incorreta', req });
      await cli.query('COMMIT');
      return res.status(401).json(generico);
    }
    // A senha nao dispensa a regra de acesso: core.pode_autenticar manda igual.
    if (!r.permitido) {
      await registrarEvento(cli, { email, usuarioId: r.usuario_id, sucesso: false, motivo: `senha local: ${r.motivo}`, req });
      await cli.query('COMMIT');
      return res.status(403).json({ erro: 'acesso nao liberado' });
    }

    await cli.query(`UPDATE core.usuario SET ultimo_login_em = now() WHERE id = $1`, [r.usuario_id]);
    await registrarEvento(cli, { email, usuarioId: r.usuario_id, sucesso: true, motivo: 'senha local', req });
    await cli.query('COMMIT');

    sessao.gravarSessao(res, { usuarioId: r.usuario_id, email, via: 'senha', loginHint: null });
    return res.json({ ok: true });
  } catch (e) {
    await cli.query('ROLLBACK').catch(() => {});
    console.error('[login-local]', e.message);
    return res.status(500).json({ erro: 'falha no login' });
  } finally {
    cli.release();
  }
});
```

Pontos de desenho:

- **Mesma sessão, mesmo cookie.** Quem entra por senha ganha o mesmo `bt_sessao`; só o campo `via`
  muda. Nenhum outro pedaço da aplicação precisa saber como a pessoa entrou.
- **Mesma regra de acesso.** A senha autentica; `core.pode_autenticar` autoriza. Senha local não é
  atalho para furar `core.email_autorizado` nem bloqueio.
- **`404` quando desligado.** Não `403`: rota que não existe não convida a tentar.
- **Rate limit no log que já existe.** `core.login_evento` é append-only para a aplicação
  (`REVOKE UPDATE, DELETE`, seção 18 do `01-base.sql`), então quem estiver tentando não consegue
  limpar o próprio rastro pela aplicação.

### Criar uma senha local (operação manual, consciente)

```bash
# na VM, gera o hash sem gravar a senha em arquivo nem no historico do shell
read -rsp 'senha: ' S; echo
node -e 'const b=require("bcryptjs");console.log(b.hashSync(process.argv[1],12))' "$S"; unset S
```

```sql
-- cole o hash gerado
UPDATE core.usuario
   SET senha_hash = '$2a$12$...'
 WHERE email = 'felipe.vieira@biotrop.com.br';
```

### Desligar quando o Entra estiver no ar

```bash
# 1. na VM
sed -i 's/^LOGIN_LOCAL_ATIVO=true/LOGIN_LOCAL_ATIVO=false/' /etc/biotrop/manutencao.env
systemctl restart biotrop-manutencao
```

```sql
-- 2. quem ainda tem senha local (deve voltar vazio depois do passo 3)
SELECT email, perfil_id, ultimo_login_em
  FROM core.usuario
 WHERE senha_hash IS NOT NULL
 ORDER BY email;

-- 3. apaga os hashes: a partir daqui a unica porta e o Entra ID
UPDATE core.usuario SET senha_hash = NULL WHERE senha_hash IS NOT NULL;
```

```sql
-- 4. conferir que ninguem mais entra por senha
SELECT em, email, sucesso, motivo
  FROM core.login_evento
 WHERE motivo LIKE 'senha local%'
 ORDER BY em DESC
 LIMIT 20;
```

Enquanto a flag estiver ligada em produção, a tela de login mostra o botão Microsoft em primeiro
plano e a senha atrás de um "outras formas de entrar". A porta de emergência não pode parecer o
caminho normal.

---

## 12. O que NÃO fazer

### 1. Não confiar em e-mail vindo do cliente

O e-mail que decide o acesso sai de **um lugar só**: o `payload` de um `id_token` cuja assinatura foi
verificada contra o JWKS do tenant. Nunca de:

```js
// TODAS erradas
const email = req.body.email;                  // POST /auth/entrar { email: 'admin@biotrop.com.br' }
const email = req.query.email;                 // ?email=...
const email = req.get('x-usuario');            // header inventado pelo front
const email = JSON.parse(atob(idToken.split('.')[1])).email;   // decode sem verify
const email = req.cookies.email;               // cookie nao assinado
```

A quarta é a mais perigosa porque *parece* certa: o JWT está ali, o campo é o certo, e funciona nos
testes. Só que qualquer pessoa monta um JWT com `email: "felipe.vieira@biotrop.com.br"` — que é o
admin semeado em `core.email_autorizado` no `01-base.sql` — e entra como administrador. Assinatura
não conferida é o mesmo que não ter assinatura.

Mesmo raciocínio para `usuario_id`: o `SET LOCAL app.usuario_id` recebe `req.usuario.id`, que veio do
cookie assinado e foi reconferido no banco — nunca um id que chegou no corpo ou na URL.

### 2. Não aceitar qualquer conta do tenant

`tid` correto significa "é uma conta Biotrop", não "pode usar a plataforma de manutenção". O tenant
tem RH, comercial, agrônomos, estagiários e contas de serviço. A porta é `core.email_autorizado`:

```js
// errado: autenticou, entrou
const identidade = await entra.validarIdToken({ idToken, nonce });
sessao.gravarSessao(res, { usuarioId: '???', email: identidade.email, via: 'entra' });

// certo: autenticou, agora o banco decide
const r = await autorizarEntrada({ ...identidade, req });
if (!r.ok) return res.redirect(302, `/login?erro=${r.codigo}`);
```

Também errado, e tentador: provisionar automaticamente com `perfil_padrao = 'tecnico'` para qualquer
e-mail `@biotrop.com.br` que apareça, "para não ficar liberando um por um". Isso dá acesso a SCI, SCM
e apontamento de utilidades para o tenant inteiro. Liberar acesso é um `INSERT`:

```sql
INSERT INTO core.email_autorizado (email, perfil_padrao, grupo_padrao, motivo, liberado_por)
VALUES ('novo.tecnico@biotrop.com.br', 'tecnico',
        (SELECT id FROM core.grupo WHERE codigo = 'g-mecanica'),
        'admissao 09/2026 - solicitado pela coordenacao',
        (SELECT id FROM core.usuario WHERE email = 'felipe.vieira@biotrop.com.br'))
ON CONFLICT (email) DO NOTHING;
```

E contas de convidado (`#EXT#`) ficam de fora por regra explícita em `validarIdToken`.

### 3. Não guardar segredo no front

Nada disso vai para o bundle, nem para uma variável com prefixo público (`NEXT_PUBLIC_`, `VITE_`,
`REACT_APP_`), nem para `window.__CONFIG__`, nem para o repositório:

- `ENTRA_CLIENT_SECRET`
- `SESSAO_SEGREDO`
- `DATABASE_URL`
- qualquer credencial do Graph do registro de e-mail

O `client_id`, o `tenant_id` e o redirect URI são públicos por natureza (aparecem na URL do
`/authorize`). O **segredo** não: ele existe justamente para provar que quem resgata o `code` é o
servidor. Segredo no front é segredo publicado.

Checagem antes de subir:

```bash
grep -rniE 'client_secret|SESSAO_SEGREDO|DATABASE_URL|postgres://' \
  --include='*.js' --include='*.jsx' --include='*.ts' --include='*.tsx' \
  --include='*.html' --include='*.json' \
  public/ src/client/ dist/ 2>/dev/null

git ls-files | grep -E '\.env($|\.)' || echo 'nenhum .env versionado - ok'
```

Se um segredo já foi commitado: rotacione no portal do Entra. Apagar do histórico do git não desfaz o
vazamento; trocar o valor desfaz.

### 4. Não usar implicit, nem sequer deixá-lo habilitado

`response_type=id_token`, `response_type=token`, `response_mode=fragment`, "ID tokens" marcado no
registro. Seção 3.

### 5. Não deixar a validação frouxa

| Nunca | Por que |
|---|---|
| `jwtVerify` sem `algorithms` | aceita o `alg` do header: `none` e `HS256` assinado com o `client_secret` |
| `issuer` com wildcard ou `common` | token de outro tenant vale como login Biotrop |
| sem `audience` | token emitido para outro app é reaproveitado |
| ignorar `nonce` | replay de token capturado |
| `clockTolerance` grande (horas) | token expirado continua valendo; se o relógio da VM está errado, conserte o relógio (`timedatectl`) |
| buscar o JWKS a cada request sem cache | a Microsoft passa a limitar a taxa e o login cai inteiro |
| fixar a chave pública em arquivo | a Microsoft rotaciona chave e o login para sem ninguém ter mexido em nada |

### 6. Não usar o `access_token` do Graph como sessão

O `access_token` que vem junto no `/token` serve para chamar o Graph. Não é a sessão da aplicação, não
vai para cookie, não vai para o front. Nesta arquitetura ele é simplesmente descartado — a aplicação
não chama Graph em nome do usuário.

### 7. Não logar credencial

`id_token`, `access_token`, `code`, `code_verifier`, `client_secret` e senha ficam fora de
`console.log`, fora de Application Insights e fora de mensagem de erro na tela. Log útil: e-mail,
código do resultado (`bloqueado`, `nao_autorizado`), `AADSTSxxxxx`.

### 8. Não gravar sem `SET LOCAL`

Rota que escreve em `almox.sci`, `almox.scm`, `util.leitura`, `lms.*` ou `core.usuario` sem passar por
`comUsuario()` produz histórico e auditoria sem autor — e, depois da migration `0002`, consulta vazia.
Seção 9.

### 9. Não deixar rota nova fora do `exigeSessao`

`app.use(exigeSessao)` antes das rotas de negócio (seção 8). Proteger rota por rota é a forma
garantida de esquecer uma.

---

## 13. Aceite: os testes que fecham a entrega

### 13.1 Antes de tocar no código

```sql
-- as pecas do login existem?
SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'core' AND proname = 'pode_autenticar';

-- quem esta liberado hoje, e quem entra de fato
SELECT email, autorizacao_ativa, usuario_id, bloqueado, permitido, motivo
  FROM app.vw_login_permitido
 ORDER BY email;

-- a regra respondendo caso a caso
SELECT * FROM core.pode_autenticar('felipe.vieira@biotrop.com.br');
SELECT * FROM core.pode_autenticar('nao.existe@biotrop.com.br');
```

O terceiro `SELECT` tem que devolver **uma linha** com `permitido = false` e motivo
`e-mail nao consta na lista de autorizados`. Se devolver zero linhas, a query do callback está
errada, não o acesso.

### 13.2 A URL do `/authorize` está certa

```bash
curl -si 'http://localhost:3000/auth/login' | grep -i '^location:'
```

Confirme na URL: `response_type=code`, `code_challenge_method=S256`, `code_challenge=` presente,
`response_mode=query`, `scope=openid profile email`, `nonce=`, `state=`, e o `redirect_uri` idêntico
ao cadastrado no portal (barra final, `http` vs `https`, maiúsculas — tudo conta; divergência
devolve `AADSTS50011`).

E confirme o que **não** pode estar lá: `response_type=id_token`, `response_type=token`,
`response_mode=fragment`, `client_secret`.

```bash
# os dois cookies do fluxo
curl -si 'http://localhost:3000/auth/login' | grep -i '^set-cookie:'
# esperado: bt_oauth=...; Max-Age=600; Path=/; HttpOnly; SameSite=Lax
```

### 13.3 Login completo, no navegador

1. `https://manutencao.biotrop.com.br/` sem cookie → redireciona para `/auth/login?retorno=%2F`.
2. Autentica na Microsoft (senha + MFA).
3. Volta em `/auth/callback?code=...&state=...` e cai em `/`.
4. DevTools → Application → Cookies: `bt_sessao` com `HttpOnly` marcado, `Secure` marcado,
   `SameSite=Lax`. `bt_oauth` já não existe.
5. Console do navegador: `document.cookie` **não** mostra `bt_sessao` (é a prova do `httpOnly`).
6. Barra de endereços: nenhum `#id_token=` nem `#access_token=`.

```sql
SELECT em, email, sucesso, motivo, ip FROM core.login_evento ORDER BY em DESC LIMIT 5;
SELECT email, entra_object_id, ultimo_login_em, perfil_id FROM core.usuario WHERE email = 'seu.email@biotrop.com.br';
```

`entra_object_id` preenchido: o vínculo com a conta do AD foi feito.

### 13.4 Recusa

```sql
-- bloqueado
UPDATE core.usuario SET bloqueado = true, motivo_bloqueio = 'teste de aceite'
 WHERE email = 'teste@biotrop.com.br';
```

Login → tela "Acesso bloqueado", e `core.login_evento` com `sucesso = false` e
`motivo = 'bloqueado: teste de aceite'`. Com a sessão já aberta em outra aba, o próximo clique cai
para `/login` — é o teste da revogação imediata da seção 9.

```sql
UPDATE core.usuario SET bloqueado = false, motivo_bloqueio = NULL WHERE email = 'teste@biotrop.com.br';

-- autorizacao revogada
UPDATE core.email_autorizado SET ativo = false, revogado_em = now() WHERE email = 'teste@biotrop.com.br';
-- login -> 'autorizacao revogada'
UPDATE core.email_autorizado SET ativo = true, revogado_em = NULL WHERE email = 'teste@biotrop.com.br';
```

E o teste do e-mail forjado, que é o que fecha o item 1 da seção 12:

```bash
# tem que responder 404 (rota nao existe) - nunca 200
curl -si -X POST http://localhost:3000/auth/entrar \
  -H 'content-type: application/json' \
  -d '{"email":"felipe.vieira@biotrop.com.br"}' | head -1

# cookie inventado tem que ser recusado
curl -si http://localhost:3000/api/eu \
  -H 'Cookie: bt_sessao=eyJzdWIiOiJmYWtlIn0.assinatura-invalida' | head -1
# esperado: HTTP/1.1 401
```

### 13.5 O `SET LOCAL` funcionando

Aprove ou mude uma SCM pela tela e confira o autor:

```sql
SELECT h.em, h.de, h.para, h.por_nome, h.por_usuario_id
  FROM almox.scm_historico h ORDER BY h.em DESC LIMIT 3;

SELECT a.em, a.tabela, a.operacao, a.ator, a.ator_email
  FROM core.auditoria a ORDER BY a.em DESC LIMIT 3;
```

`por_nome` e `ator_email` preenchidos = passou por `comUsuario()`. Nulos = a rota escreveu por fora.

### 13.6 Logout

```bash
curl -si -X POST http://localhost:3000/auth/logout -H 'Cookie: bt_sessao=<valor real>' | grep -iE '^(location|set-cookie):'
# esperado: Set-Cookie: bt_sessao=; Expires=Thu, 01 Jan 1970...  e Location: /login?saiu=1
```

Depois: `GET /api/eu` com o cookie antigo tem que dar `401`.

### 13.7 Checklist final

- [ ] DNS + certificado da VM prontos (seção 2.1)
- [ ] Registro `Biotrop Manutencao - Web`, single tenant, plataforma **Web**
- [ ] Redirect URIs: VM (`https`) e `http://localhost:3000/auth/callback`
- [ ] Post-logout redirect URI cadastrado
- [ ] Implicit grant: os dois checkboxes **desmarcados**
- [ ] Permissões delegadas: só `openid`, `profile`, `email` — com admin consent se o tenant exigir
- [ ] Claims opcionais no ID token: `email` e `login_hint`
- [ ] Segredo no `/etc/biotrop/manutencao.env` modo `600`, expiração no calendário
- [ ] `SESSAO_SEGREDO` com 48 bytes aleatórios, diferente do de desenvolvimento
- [ ] `grep` de segredo no bundle limpo (seção 12.3)
- [ ] `core.email_autorizado` revisada antes de abrir o acesso
- [ ] Responsável apontado em `core.grupo` (`SELECT * FROM app.vw_aprovador_de WHERE origem = 'nenhum'`)
- [ ] `LOGIN_LOCAL_ATIVO=false` e `core.usuario.senha_hash` todo nulo
- [ ] Testes 13.2 a 13.6 executados

---

## 14. "Não consigo logar" — roteiro de diagnóstico

Comece sempre pelo banco: a resposta está em duas queries.

```sql
-- 1. o e-mail entra hoje?
SELECT * FROM core.pode_autenticar('pessoa@biotrop.com.br');

-- 2. o que aconteceu nas ultimas tentativas dele
SELECT em, sucesso, motivo, ip, user_agent
  FROM core.login_evento
 WHERE email = 'pessoa@biotrop.com.br'
 ORDER BY em DESC LIMIT 10;
```

| Sintoma | Causa provável | Onde arrumar |
|---|---|---|
| `login_evento` com `e-mail nao consta na lista de autorizados` | falta liberar | `INSERT` em `core.email_autorizado` (seção 12.2) |
| `login_evento` com `bloqueado: ...` | bloqueio proposital | `core.usuario.bloqueado` |
| `login_evento` com `oid do Entra divergente` | conta do AD recriada | `UPDATE core.usuario SET entra_object_id = NULL WHERE email = '...'` e pedir novo login |
| nenhuma linha em `login_evento` | não chegou ao banco: parou no Entra ou no callback | log do serviço, código `AADSTS` |
| `AADSTS50011` (redirect URI mismatch) | URI do portal diferente da enviada | comparar caractere por caractere com o `curl` de 13.2 |
| `AADSTS7000215` (invalid client secret) | segredo errado ou **expirado** | Certificates & secrets; criar novo e trocar a variável |
| `AADSTS65001` (consent required) | consentimento de usuário desabilitado no tenant | pedir admin consent para `openid profile email` |
| `AADSTS700016` (application not found) | `client_id` ou `tenant_id` trocados | `ENTRA_CLIENT_ID` / `ENTRA_TENANT_ID` |
| `/login?erro=sessao_expirada` sempre | cookie `bt_oauth` não volta | `sameSite` está `strict` (use `lax`), ou `secure: true` em `http://localhost` |
| `/login?erro=state` | duas abas iniciando login ao mesmo tempo, ou cookie sobrescrito | orientar a usar uma aba; conferir `path: '/'` do cookie |
| falha só na VM, funciona no localhost | relógio da VM fora de hora → `exp`/`nbf` do token | `timedatectl status` e sincronizar NTP |
| "entrou mas não vê nada" | provisionado com `viewer` (sem `perfil_padrao`) | `UPDATE core.usuario SET perfil_id = 'tecnico' ...` e corrigir `perfil_padrao` na liberação |

Quem entrou sem perfil útil aparece em uma query:

```sql
SELECT u.email, u.perfil_id, u.criado_em, u.ultimo_login_em
  FROM core.usuario u
 WHERE u.perfil_id = 'viewer' AND u.ultimo_login_em IS NOT NULL
 ORDER BY u.ultimo_login_em DESC;

-- e as liberacoes sem perfil definido, que causam isso
SELECT email, motivo, liberado_em FROM core.email_autorizado
 WHERE ativo AND perfil_padrao IS NULL;
```

Panorama de acesso, para a reunião com a TI:

```sql
SELECT date_trunc('day', em) AS dia,
       count(*) FILTER (WHERE sucesso)     AS ok,
       count(*) FILTER (WHERE NOT sucesso) AS recusados
  FROM core.login_evento
 WHERE em > now() - interval '30 days'
 GROUP BY 1 ORDER BY 1 DESC;
```
