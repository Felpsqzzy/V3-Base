# E-mail por Microsoft Graph — Biotrop Manutenção

Guia de implantação do envio de e-mail da plataforma de manutenção industrial. Base de dados:
`migrations/0001_base.sql` (arquivo `01-base.sql` desta pasta). Todo nome de tabela, coluna, tipo e
função citado aqui existe lá — nada foi inventado. Complementa a seção 2.7 do `LOGIN-MICROSOFT.md`,
que é onde o registro de aplicativo separado foi decidido.

**O que a base já entrega para o e-mail (conferido no arquivo):**

| Objeto | Para que serve |
|---|---|
| `core.email_fila` | a caixa de saída: `destinatario citext`, `copia citext[]`, `remetente citext DEFAULT 'manutencao@biotrop.com.br'`, `assunto`, `corpo_html`, `referencia_tabela`, `referencia_id`, `motivo`, `status`, `tentativas smallint`, `erro`, `graph_message_id`, `criado_em`, `enviado_em` |
| `core.email_status` | enum `('pendente','enviando','enviado','erro','cancelado')` — o `enviando` existe justamente para o worker marcar o que já pegou |
| `ix_email_fila_pendente` | índice parcial em `criado_em WHERE status = 'pendente'` — a query do worker não varre a tabela |
| `app.vw_email_fila_pendente` | o que falta enviar, para humano olhar (não traz `corpo_html`) |
| `core.rotina_execucao` | `(rotina, inicio, fim, sucesso, detalhe)` — cada rodada do worker registra aqui |
| `almox.fn_sci_transicao()` | **já enfileira** o aviso de revisão do solicitante, com `motivo = 'sci_revisao_solicitante'` |
| `almox.fn_scm_transicao()` | **já enfileira** o aviso ao aprovador na criação, com `motivo = 'scm_pendente_aprovacao'` |
| `app.vw_sci` / `app.vw_scm` | linha completa da solicitação, com `status_rotulo` — é daqui que os templates leem os dados |
| `app.vw_aprovador_de` | quem aprova a solicitação de cada pessoa (responsável do grupo → exceção → ninguém) |
| `app.vw_saude_operacional` | já expõe `emails_pendentes` e `emails_com_erro` em uma linha |

**O que a base NÃO tem:** o worker (é código, está aqui), nenhuma `CREATE POLICY` de RLS (migration
`0002`), e nenhum mecanismo de liga/desliga por motivo — quem decide qual motivo sai da fila é o
worker, pela variável `EMAIL_MOTIVOS_ATIVOS` (seção 7).

**Atenção desde já:** o gatilho da SCM **já grava** a linha na fila. "Não ligar o e-mail da SCM" não
é deixar de escrever código — é não deixar o worker entregar aquele motivo. Seção 7.4 mostra
exatamente como, e o que acontece com as linhas que ficam paradas.

---

## 1. Decisões, resumidas

| Decisão | Escolha | Motivo |
|---|---|---|
| Tipo de permissão | **Application** `Mail.Send` (client credentials) | o envio roda em cron, sem ninguém logado; token delegado exige usuário e expira calado |
| Raio de dano | registro de aplicativo **separado** do login + `ApplicationAccessPolicy` na caixa | `Mail.Send` de aplicação sem policy envia como qualquer caixa do tenant |
| Remetente | **shared mailbox** `manutencao@biotrop.com.br` | sem licença, sem senha, login bloqueado, e a resposta do técnico cai onde mais de uma pessoa lê |
| Transporte | `POST /v1.0/users/{remetente}/sendMail` | uma chamada, `202 Accepted`; rascunho + send só quando precisar do id da mensagem |
| Confiabilidade | fila no banco (`core.email_fila`) + worker | o gatilho grava a intenção na mesma transação do fato; Graph fora do ar atrasa, não perde |
| Agendamento | `systemd timer` a cada 5 min, uma instância | volume real é dezenas por dia; não precisa de daemon nem de fila externa |
| Concorrência | `FOR UPDATE SKIP LOCKED` + `pg_try_advisory_lock` | duas rodadas sobrepostas não mandam o mesmo e-mail duas vezes |
| Retry | 5 tentativas, backoff exponencial, respeita `Retry-After` | 429 e 503 são normais; erro de payload não melhora com repetição |
| Texto do e-mail | template em Node, `corpo_html` do banco como fallback | mudar texto de e-mail é o que mais muda e o que menos deveria exigir migration + `psql` na VM |
| Escopo de produto (fase 1) | **um** e-mail ligado: SCI em revisão do solicitante | é a única transição em que o sistema espera ação de quem não abre o sistema todo dia |
| Dependências novas | nenhuma além do `pg` que já existe | Node 20 LTS tem `fetch` global; VM faz `git pull` + build manual |

---

## 2. `Mail.Send` como permissão de aplicativo

### 2.1 Application, não Delegated

São dois modelos diferentes de "quem está enviando":

| | **Application** (o que usamos) | **Delegated** |
|---|---|---|
| Fluxo de token | `client_credentials` | Authorization Code / OBO |
| Precisa de usuário logado | não | sim, sempre |
| Identidade do envio | a caixa que o app escolhe | a pessoa que autorizou |
| Consentimento | admin, uma vez | por usuário (ou admin consent) |
| Vida do acesso | segredo/certificado do app | `refresh_token`, sujeito a expiração, troca de senha, MFA e Conditional Access |
| Escopo do dano | todas as caixas do tenant, até a policy | a caixa daquela pessoa |

O worker roda por `systemd timer`, às 3h da manhã inclusive, sem sessão de ninguém. Para usar
permissão delegada eu precisaria de um `refresh_token` guardado na VM, e ele **para de funcionar sem
avisar**: a pessoa troca a senha, o Conditional Access passa a exigir MFA, a conta sai de uma
licença — e o efeito visível é `core.email_fila` enchendo de `status = 'pendente'` enquanto ninguém
recebe aviso de revisão. Já vi esse modo de falha: o e-mail volta a funcionar quando alguém percebe
que parou, e "alguém percebe" costuma levar uma semana.

Tem um segundo motivo, e ele é de produto: o e-mail **precisa** sair de `manutencao@biotrop.com.br`,
não da pessoa que clicou. Quem devolveu a SCI para revisão foi o almoxarife, mas o aviso é do
sistema. Com permissão delegada o remetente é a pessoa, os Itens Enviados de cada almoxarife enchem
de aviso automático, e a resposta do técnico vai para a caixa pessoal de quem estava de plantão
naquele dia.

Terceiro motivo, prático: o registro do login (`Biotrop Manutencao - Web`) pede hoje só
`openid profile email`. Adicionar `Mail.Send` delegado ali faria a tela de consentimento do primeiro
acesso dizer "enviar e-mail como você" para **todo mundo** que loga. Isso gera pergunta na TI e
desconfiança no usuário, para nada.

**Não use ROPC** (`grant_type=password`) como atalho para "delegado sem interação". Guarda senha em
arquivo, quebra com MFA, e o Entra ID pode ter o fluxo desabilitado por política. É o pior dos dois
mundos.

### 2.2 O que a permissão de aplicativo custa

`Mail.Send` de aplicação, sem restrição, significa: **o segredo desse app envia e-mail como qualquer
caixa do tenant** — diretoria, RH, financeiro. Não é exagero de manual de segurança, é literalmente
o que a chamada `POST /users/{qualquer-um}/sendMail` faz.

Duas consequências que definem o desenho:

1. **Registro separado do login.** É o que a seção 2.7 do `LOGIN-MICROSOFT.md` já fixou:
   `Biotrop Manutencao - Graph Mailer`, segredo próprio. Se o segredo do site vazar, ninguém manda
   e-mail como o CFO; se o segredo do mailer vazar, ninguém entra no sistema.
2. **`ApplicationAccessPolicy` restringindo à caixa.** Sem ela, a única coisa entre o `.env` da VM e
   a caixa da diretoria é o código do worker estar correto.

### 2.3 Registro no Entra ID — passos exatos

Para a TI, no portal do Entra ID:

```
Entra ID > Registros de aplicativo > Novo registro
  Nome ............... Biotrop Manutencao - Graph Mailer
  Tipos de conta ..... Somente contas neste diretorio organizacional (single tenant)
  URI de redirecionamento ... NENHUM (nao ha login neste app)

Permissoes de API > Adicionar permissao > Microsoft Graph
  > Permissoes de APLICATIVO  (nao "delegadas")
  > Mail > Mail.Send
  > Conceder consentimento do administrador   <- sem isso o token vem sem roles

Certificados e segredos > Novo segredo do cliente
  Descricao .......... mailer-manutencao
  Validade ........... 24 meses
  (copiar o VALOR na hora; depois so aparece o Id)
```

Confira que ficou **só** `Mail.Send`, tipo Aplicativo, com consentimento concedido. Se aparecer
`Mail.ReadWrite` ou `Mail.Send` delegado, remova: o worker não lê caixa nenhuma.

O que a TI devolve por escrito:

```
GRAPH_TENANT_ID  = ....................................
GRAPH_CLIENT_ID  = .................................... (do Graph Mailer, NAO do Web)
GRAPH_CLIENT_SECRET = ................................. (valor, nao o Id)
Vencimento do segredo = __/__/____
Caixa remetente = manutencao@biotrop.com.br  (shared mailbox? sim/nao)
ApplicationAccessPolicy aplicada = sim/nao
Test-ApplicationAccessPolicy na caixa remetente = Granted
Test-ApplicationAccessPolicy em uma caixa qualquer = Denied
```

A linha do vencimento não é burocracia: quando o segredo expira, o sintoma é
`AADSTS7000222` no `detalhe` de `core.rotina_execucao` e a fila parando de andar. Anote a data no
calendário junto com o segredo do login, que vence separado.

### 2.4 `ApplicationAccessPolicy` — a trava que importa

Roda no Exchange Online PowerShell, uma vez, pela TI:

```powershell
Connect-ExchangeOnline -UserPrincipalName ti@biotrop.com.br

# 1. grupo de seguranca com as caixas que o app pode usar (hoje: uma)
New-DistributionGroup -Name "Graph Mailer - Caixas Permitidas" `
  -Alias graph-mailer-caixas `
  -Type Security `
  -Members manutencao@biotrop.com.br

# 2. o app so alcanca quem esta no grupo
New-ApplicationAccessPolicy `
  -AppId 00000000-0000-0000-0000-000000000000 `
  -PolicyScopeGroupId graph-mailer-caixas@biotrop.com.br `
  -AccessRight RestrictAccess `
  -Description "Mailer da plataforma de manutencao: somente manutencao@biotrop.com.br"

# 3. provar que funciona (pode levar ate 30 min para propagar)
Test-ApplicationAccessPolicy -Identity manutencao@biotrop.com.br `
  -AppId 00000000-0000-0000-0000-000000000000
# AccessCheckResult : Granted

Test-ApplicationAccessPolicy -Identity felipe.vieira@biotrop.com.br `
  -AppId 00000000-0000-0000-0000-000000000000
# AccessCheckResult : Denied
```

Os dois `Test-` são o aceite. `Granted` na caixa do sistema e `Denied` em uma caixa pessoal qualquer:
é isso que separa "o worker manda e-mail" de "o `.env` da VM é a chave do correio da empresa".

Usar um **grupo** no `-PolicyScopeGroupId`, e não a caixa direto, é o que permite acrescentar amanhã
uma caixa (por exemplo `pcm@biotrop.com.br`) com um `Add-DistributionGroupMember`, sem tocar em
policy.

Se a TI já trabalha com o modelo novo (**RBAC for Applications** do Exchange Online), o equivalente é
uma atribuição de papel com escopo — mesma ideia, sintaxe outra:

```powershell
New-ServicePrincipal -AppId 00000000-0000-0000-0000-000000000000 `
  -ObjectId <object-id-do-service-principal-no-entra> `
  -DisplayName "Biotrop Graph Mailer"

New-ManagementScope -Name "Caixa manutencao" `
  -RecipientRestrictionFilter "PrimarySmtpAddress -eq 'manutencao@biotrop.com.br'"

New-ManagementRoleAssignment -Role "Application Mail.Send" `
  -App 00000000-0000-0000-0000-000000000000 `
  -CustomResourceScope "Caixa manutencao"
```

Escolha **um** dos dois modelos. Os dois ao mesmo tempo funcionam, mas quando o envio começar a dar
`403` ninguém vai lembrar de checar os dois lugares.

---

## 3. A conta remetente

O `01-base.sql` já fixou o remetente no schema:

```sql
remetente  citext  NOT NULL DEFAULT 'manutencao@biotrop.com.br'
```

O `DEFAULT` está na coluna, então cada linha da fila carrega de qual caixa ela sai. Trocar a caixa
amanhã é `ALTER TABLE ... SET DEFAULT` na `0002`, sem reescrever gatilho nenhum, e as linhas antigas
continuam dizendo por onde saíram.

### 3.1 Usuário licenciado ou shared mailbox

| | **Usuário licenciado** | **Shared mailbox** |
|---|---|---|
| Licença Exchange | consome uma (custo mensal) | não consome |
| Senha | existe — é superfície de ataque | não existe |
| Login interativo | possível (precisa ser bloqueado à mão) | não se aplica |
| MFA / Conditional Access | precisa exceção, ou o app quebra | não entra na conversa |
| `Mail.Send` de aplicação | funciona | funciona igual |
| Quem lê a resposta | quem tiver a senha | qualquer pessoa com permissão, ao mesmo tempo |
| Itens Enviados | na caixa da conta | na caixa compartilhada, visível para o time |
| Limite de envio | 10.000 destinatários/dia | 10.000 destinatários/dia |

Do ponto de vista do Graph, as duas são idênticas: `POST /users/manutencao@biotrop.com.br/sendMail`
funciona nos dois casos, e o `ApplicationAccessPolicy` restringe do mesmo jeito. A diferença é
operacional.

**Decisão: shared mailbox.** Motivos, na ordem em que importam:

1. **Não tem senha.** Uma conta de serviço com senha é uma conta que alguém vai reaproveitar para
   entrar em algum lugar, e que aparece nos relatórios de "conta sem MFA" da TI para sempre.
2. **A resposta cai em lugar útil.** Esse é o ponto que costuma passar batido: o e-mail de revisão
   pede uma ação, e a reação natural do técnico é **responder o e-mail**. Se ninguém lê a caixa, a
   resposta morre — e do lado dele parece que ele já respondeu. Shared mailbox permite dar acesso ao
   almoxarifado e ao PCM, sem senha compartilhada.
3. **Não consome licença.** Argumento fraco tecnicamente, mas é o que faz a TI aprovar rápido.

O que pedir para a TI:

```powershell
New-Mailbox -Shared -Name "Manutencao Biotrop" `
  -DisplayName "Manutencao Biotrop" `
  -Alias manutencao -PrimarySmtpAddress manutencao@biotrop.com.br

# quem le a caixa (mesmas pessoas do almoxarifado/PCM)
Add-MailboxPermission -Identity manutencao@biotrop.com.br `
  -User felipe.vieira@biotrop.com.br -AccessRights FullAccess -InheritanceType All

# entra no grupo da policy da secao 2.4
Add-DistributionGroupMember -Identity graph-mailer-caixas@biotrop.com.br `
  -Member manutencao@biotrop.com.br
```

Se a caixa já existe como usuário licenciado, converter é `Set-Mailbox -Identity manutencao@... -Type Shared`
e depois remover a licença — mas confirme antes que o `Test-ApplicationAccessPolicy` continua
`Granted`, porque a conversão mexe no objeto.

### 3.2 Reply-To: para onde vai a resposta

O `sendMail` aceita `replyTo` e o worker usa. Duas configurações defensáveis:

- `GRAPH_REPLY_TO=manutencao@biotrop.com.br` — a resposta volta para a própria caixa compartilhada.
  É o padrão, e funciona **se** alguém abrir a caixa.
- `GRAPH_REPLY_TO=` (vazio) — sem `replyTo`, a resposta vai para o remetente, que é a mesma caixa.
  Igual, com uma linha menos no JSON.

O que **não** fazer é apontar `replyTo` para a pessoa que causou a transição (o almoxarife que
devolveu a SCI). Parece atencioso e é uma armadilha: o técnico responde para uma pessoa específica,
que pode estar de folga, e a solicitação fica parada num e-mail que ninguém mais vê. O texto do
template resolve isso melhor que o cabeçalho — ele manda a pessoa abrir a solicitação no sistema
(seção 9.2), que é o único lugar onde a revisão realmente acontece.

### 3.3 Itens enviados

O worker manda `saveToSentItems: true`. Com o `sendMail` feito em
`/users/manutencao@biotrop.com.br/sendMail`, a cópia cai nos **Itens Enviados dessa própria caixa** —
que é exatamente o que se quer: quem tem acesso à caixa compartilhada vê o que o sistema mandou, sem
precisar de acesso ao banco.

Custo: a caixa cresce. Com dezenas de mensagens por dia é irrelevante por anos. Se um dia incomodar,
`saveToSentItems: false` e a única prova de envio passa a ser `core.email_fila.enviado_em` — o que
funciona, mas tira do almoxarifado a capacidade de conferir o texto exato que a pessoa recebeu.
Mantenha `true` na fase 1.

---

## 4. Token: `client_credentials`

### 4.1 A chamada, na mão

Antes de escrever código, prove que o registro funciona:

```bash
curl -s -X POST \
  "https://login.microsoftonline.com/$GRAPH_TENANT_ID/oauth2/v2.0/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "client_id=$GRAPH_CLIENT_ID" \
  --data-urlencode "client_secret=$GRAPH_CLIENT_SECRET" \
  --data-urlencode "scope=https://graph.microsoft.com/.default" \
  --data-urlencode "grant_type=client_credentials" | jq '{token_type, expires_in}'
```

```json
{
  "token_type": "Bearer",
  "expires_in": 3599
}
```

Três detalhes que economizam meia hora:

- **O `scope` é `https://graph.microsoft.com/.default`**, não `Mail.Send`. No fluxo de aplicação não
  se pede permissão por chamada: pede-se "tudo que já foi consentido para este app". Mandar
  `scope=Mail.Send` devolve `AADSTS70011: The provided value for the input parameter 'scope' is not valid`.
- **Não vem `refresh_token`**, e está certo. Em `client_credentials` o próprio segredo é a
  credencial: quando o token vence, pede-se outro. Código que procura `refresh_token` aqui está
  procurando um bug.
- **O endpoint é `login.microsoftonline.com`**, não `graph.microsoft.com`. Um é quem dá o crachá, o
  outro é quem confere.

Confira que o token tem a permissão, colando o `access_token` em `jwt.ms` (ou decodificando o payload):
tem que aparecer `"roles": ["Mail.Send"]`. Se vier `"roles"` ausente, o **consentimento de
administrador não foi concedido** — o token é válido e o `sendMail` vai dar `403` sem explicar.

### 4.2 `src/email/graph.js` — token com cache

Node 20 LTS tem `fetch` global. Nenhuma dependência nova.

```js
'use strict';

const TENANT   = process.env.GRAPH_TENANT_ID;
const CLIENT   = process.env.GRAPH_CLIENT_ID;
const SEGREDO  = process.env.GRAPH_CLIENT_SECRET;
const TOKEN_URL = `https://login.microsoftonline.com/${TENANT}/oauth2/v2.0/token`;
const GRAPH_URL = 'https://graph.microsoft.com/v1.0';

// Margem de 5 min: token com 40s de vida sobrando nao vale a chamada, porque o
// sendMail pode levar alguns segundos e o 401 no meio do lote custa mais caro.
const MARGEM_MS = 5 * 60 * 1000;

let cache = null;      // { token, expiraEm }
let emVoo = null;      // Promise em andamento (single-flight)

class ErroGraph extends Error {
  constructor(mensagem, { status, codigo, requestId, retryAfterMs, transitorio }) {
    super(mensagem);
    this.name = 'ErroGraph';
    this.status = status ?? null;
    this.codigo = codigo ?? null;
    this.requestId = requestId ?? null;
    this.retryAfterMs = retryAfterMs ?? null;
    this.transitorio = Boolean(transitorio);
  }
}

async function buscarToken() {
  const corpo = new URLSearchParams({
    client_id: CLIENT,
    client_secret: SEGREDO,
    scope: 'https://graph.microsoft.com/.default',
    grant_type: 'client_credentials',
  });

  const r = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: corpo,
    signal: AbortSignal.timeout(15000),
  });

  const j = await r.json().catch(() => ({}));

  if (!r.ok) {
    // O corpo do erro do Entra traz error_description com o codigo AADSTS.
    // Vale registrar inteiro: e a diferenca entre "segredo errado" e "tenant errado".
    throw new ErroGraph(`token: ${j.error || r.status} ${j.error_description || ''}`.trim(), {
      status: r.status,
      codigo: j.error || null,
      // 5xx no proprio Entra acontece e passa. 400 nao passa: segredo/tenant errado.
      transitorio: r.status >= 500 || r.status === 429,
    });
  }

  return {
    token: j.access_token,
    expiraEm: Date.now() + Number(j.expires_in || 3600) * 1000 - MARGEM_MS,
  };
}

/**
 * Devolve um token valido. Single-flight: se o lote tem 25 mensagens e o token
 * vence no meio, as chamadas simultaneas esperam a MESMA renovacao em vez de
 * pedirem 25 tokens (o Entra tambem tem throttling).
 */
async function token() {
  if (cache && Date.now() < cache.expiraEm) return cache.token;
  if (emVoo) return emVoo;

  emVoo = buscarToken()
    .then((novo) => { cache = novo; return novo.token; })
    .finally(() => { emVoo = null; });

  return emVoo;
}

function invalidarToken() { cache = null; }

module.exports = { token, invalidarToken, ErroGraph, GRAPH_URL };
```

### 4.3 Os erros `AADSTS` que você vai ver

| Código | O que é de verdade | O que fazer |
|---|---|---|
| `AADSTS7000215` | `Invalid client secret provided` — quase sempre colaram o **Id** do segredo, não o **valor** | pegar o valor; se já fechou a tela do portal, gerar outro |
| `AADSTS7000222` | segredo **expirado** | gerar novo segredo, atualizar o `.env`, `systemctl restart` |
| `AADSTS700016` | `Application not found in the directory` — `client_id` de outro tenant, ou trocado com o do login | conferir se é o `client_id` do **Graph Mailer** |
| `AADSTS900023` | `Specified tenant identifier is neither a valid DNS name, nor a valid external domain` | `GRAPH_TENANT_ID` vazio no `.env` (a URL virou `.../undefined/oauth2/...`) |
| `AADSTS70011` | `scope is not valid` | usar `https://graph.microsoft.com/.default` |
| `AADSTS500011` | `The resource principal named X was not found` | escrita errada do scope (`graph.microsoft.com/.default` sem o `https://`) |

Token OK e `sendMail` respondendo `403` é o par clássico: **falta admin consent** (sem `roles` no
token) ou a `ApplicationAccessPolicy` está barrando a caixa. `Test-ApplicationAccessPolicy` responde
qual dos dois em dez segundos.

---

## 5. `sendMail`

### 5.1 A chamada

```bash
TOKEN=$(curl -s -X POST "https://login.microsoftonline.com/$GRAPH_TENANT_ID/oauth2/v2.0/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "client_id=$GRAPH_CLIENT_ID" \
  --data-urlencode "client_secret=$GRAPH_CLIENT_SECRET" \
  --data-urlencode "scope=https://graph.microsoft.com/.default" \
  --data-urlencode "grant_type=client_credentials" | jq -r .access_token)

curl -i -X POST \
  "https://graph.microsoft.com/v1.0/users/manutencao@biotrop.com.br/sendMail" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "client-request-id: 11111111-2222-3333-4444-555555555555" \
  -d '{
    "message": {
      "subject": "Teste do mailer da plataforma de manutencao",
      "body": { "contentType": "HTML", "content": "<p>Se este e-mail chegou, o registro Graph Mailer esta correto.</p>" },
      "toRecipients": [ { "emailAddress": { "address": "felipe.vieira@biotrop.com.br" } } ],
      "replyTo": [ { "emailAddress": { "address": "manutencao@biotrop.com.br" } } ]
    },
    "saveToSentItems": true
  }'
```

Resposta esperada:

```
HTTP/1.1 202 Accepted
request-id: 8f4c0f10-1e0c-4d1a-9a0e-1b8f6d2a77c1
client-request-id: 11111111-2222-3333-4444-555555555555
```

O `-i` no `curl` não é enfeite: **o corpo da resposta é vazio**. Sem os cabeçalhos você não tem nada
para conferir.

### 5.2 `202 Accepted` não traz id de mensagem — e a coluna `graph_message_id`

`sendMail` é assíncrono: `202` significa "aceitei e vou entregar", não "entreguei", e **não devolve o
`id` da mensagem**. A base tem `core.email_fila.graph_message_id`, e a pergunta honesta é o que
gravar ali.

O que o worker grava: o **`client-request-id` que nós mesmos geramos** (um uuid por tentativa,
enviado no cabeçalho e devolvido pelo Graph), com o `request-id` do Graph ao lado quando ele vier:

```
graph_message_id = 'crid:11111111-2222-3333-4444-555555555555 rid:8f4c0f10-1e0c-4d1a-9a0e-1b8f6d2a77c1'
```

Motivo: é exatamente esse par que o suporte da Microsoft pede quando você abre ticket de "mensagem
aceita e não entregue", e é o que permite achar a mensagem no *message trace* do Exchange. Um `id` de
mensagem que não existe seria mais bonito e menos útil.

Se um dia for necessário o `id` real (por exemplo, para anexar o e-mail à solicitação), o caminho é
rascunho + envio, duas chamadas:

```bash
# 1. cria o rascunho e devolve o id
ID=$(curl -s -X POST "https://graph.microsoft.com/v1.0/users/manutencao@biotrop.com.br/messages" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{ "subject": "...", "body": {"contentType":"HTML","content":"<p>...</p>"},
        "toRecipients":[{"emailAddress":{"address":"destino@biotrop.com.br"}}] }' | jq -r .id)

# 2. envia
curl -i -X POST "https://graph.microsoft.com/v1.0/users/manutencao@biotrop.com.br/messages/$ID/send" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Length: 0"
```

Custo: duas chamadas por e-mail (dobra o consumo de quota) e uma janela em que existe rascunho na
caixa sem e-mail enviado — se o processo morrer entre 1 e 2, sobra rascunho órfão para alguém limpar.
Para um aviso de revisão de SCI isso não se paga. Fica documentado para quando pagar.

### 5.3 `src/email/graph.js` — a função de envio

Acrescente ao mesmo arquivo da seção 4.2 (o `require` sobe para o topo, junto com os outros):

```js
const { randomUUID } = require('crypto');

function retryAfterMs(r) {
  const h = r.headers.get('retry-after');
  if (!h) return null;
  const seg = Number(h);
  if (Number.isFinite(seg)) return Math.max(0, seg * 1000);
  const data = Date.parse(h);                       // Retry-After tambem pode vir como data HTTP
  return Number.isNaN(data) ? null : Math.max(0, data - Date.now());
}

/**
 * Envia uma mensagem pela caixa remetente. Devolve o par de ids de rastreio.
 * Lanca ErroGraph com transitorio=true quando repetir tem chance de funcionar.
 */
async function enviarEmail({ remetente, para, copia = [], assunto, html, replyTo }) {
  const clientRequestId = randomUUID();

  const mensagem = {
    message: {
      subject: assunto,
      body: { contentType: 'HTML', content: html },
      toRecipients: [{ emailAddress: { address: para } }],
      ...(copia.length ? { ccRecipients: copia.map((e) => ({ emailAddress: { address: e } })) } : {}),
      ...(replyTo ? { replyTo: [{ emailAddress: { address: replyTo } }] } : {}),
    },
    saveToSentItems: true,
  };

  const url = `${GRAPH_URL}/users/${encodeURIComponent(remetente)}/sendMail`;

  let r;
  try {
    r = await fetch(url, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${await token()}`,
        'Content-Type': 'application/json',
        'client-request-id': clientRequestId,
        'return-client-request-id': 'true',
      },
      body: JSON.stringify(mensagem),
      signal: AbortSignal.timeout(30000),
    });
  } catch (e) {
    // DNS, TCP, TLS, timeout: nada disso e culpa da mensagem.
    throw new ErroGraph(`rede: ${e.name}: ${e.message}`, { transitorio: true });
  }

  const requestId = r.headers.get('request-id');

  if (r.status === 202) {
    return { clientRequestId, requestId };
  }

  const texto = await r.text().catch(() => '');
  let codigo = null;
  try { codigo = JSON.parse(texto)?.error?.code || null; } catch { /* corpo nao-JSON */ }

  if (r.status === 401) {
    // Token revogado, segredo trocado, ou expirou apesar da margem.
    // Descarta o cache: a proxima tentativa pega token novo.
    invalidarToken();
    throw new ErroGraph(`401 ${codigo || 'nao autorizado'}: ${texto.slice(0, 300)}`, {
      status: 401, codigo, requestId, transitorio: true,
    });
  }

  const transitorio = r.status === 429 || r.status === 408 || r.status >= 500;

  throw new ErroGraph(`${r.status} ${codigo || ''}: ${texto.slice(0, 500)}`.trim(), {
    status: r.status,
    codigo,
    requestId,
    retryAfterMs: retryAfterMs(r),
    transitorio,
  });
}

module.exports = { token, invalidarToken, enviarEmail, ErroGraph, GRAPH_URL };
```

### 5.4 Tabela de erros: o que cada status significa aqui

| Status | `error.code` típico | Causa real | Worker faz |
|---|---|---|---|
| `202` | — | aceito | `status = 'enviado'`, grava `enviado_em` e os ids |
| `400` | `ErrorInvalidRecipients` | e-mail do destinatário inválido (usuário digitou errado no cadastro) | **permanente** → `status = 'erro'` |
| `400` | `RequestBodyRead` / `BadRequest` | JSON malformado — bug nosso, não do Graph | **permanente** → `status = 'erro'` |
| `401` | `InvalidAuthenticationToken` | token expirado/revogado | descarta cache, **transitório** |
| `403` | `ErrorAccessDenied` | `ApplicationAccessPolicy` barrando, ou falta admin consent | **permanente** → `status = 'erro'` (repetir 5x não conserta configuração) |
| `403` | `ErrorSendAsDenied` | app não pode enviar como essa caixa | **permanente** |
| `404` | `ResourceNotFound` / `ErrorInvalidUser` | a caixa `remetente` não existe (typo no `.env` ou no `DEFAULT` da coluna) | **permanente** |
| `413` | — | corpo acima de 4 MB (não acontece com nossos templates, aconteceria com anexo) | **permanente** |
| `429` | `ApplicationThrottled` | throttling | **transitório**, respeita `Retry-After` |
| `503` / `504` | `ServiceUnavailable` | Exchange Online instável, manutenção | **transitório** |
| `500` | `ErrorInternalServerError` | idem | **transitório** |

A distinção permanente/transitório é a decisão que mais importa no worker: um `403` de configuração
tentado 5 vezes com backoff só transforma um problema claro (`erro` na fila, visível em
`app.vw_saude_operacional`) em um problema lento.

---

## 6. Limites e retry

### 6.1 Os números que valem

| Limite | Valor | Onde aperta |
|---|---|---|
| Destinatários por dia, por caixa | 10.000 | irrelevante (dezenas/dia) |
| Mensagens por minuto, por caixa | 30 | é o que define a pausa entre envios |
| Destinatários por mensagem | 500 | irrelevante: 1 destinatário + cc eventual |
| Requisições Graph por caixa | ~10.000 por 10 min | irrelevante |
| Requisições concorrentes por caixa | 4 | por isso o worker é **sequencial** |
| Tamanho da mensagem | 4 MB no `sendMail` | templates têm ~2 KB |

O volume real da Biotrop na fase 1: a SCI entra em revisão do solicitante algumas vezes por dia.
Estamos duas ordens de grandeza abaixo de qualquer limite. **Por isso o worker não precisa ser
rápido — precisa ser previsível.** A configuração abaixo é deliberadamente lenta:

```
EMAIL_LOTE=25        # mensagens por rodada
EMAIL_PAUSA_MS=2000  # entre uma e outra -> 30/min no pior caso, exatamente no limite
```

Cron a cada 5 minutos com lote de 25 dá teto de 300 e-mails/hora. Se a fila passar disso, o problema
não é throughput: é um gatilho disparando o que não devia, e você quer que isso **acumule visível** em
`app.vw_email_fila_pendente` em vez de ser despejado na caixa de todo mundo.

### 6.2 Retry: como e quantas vezes

```
tentativa 1 -> falhou (transitorio) -> volta para 'pendente', tentativas = 1
tentativa 2 -> espera  2s + jitter
tentativa 3 -> espera  8s + jitter
tentativa 4 -> espera 32s + jitter
tentativa 5 -> espera 128s + jitter
falhou a 5a -> status = 'erro', coluna erro preenchida, para de tentar
```

Regras:

- **`Retry-After` manda.** Se o Graph disse quanto esperar, o backoff calculado é ignorado. Ele sabe
  quanto de quota falta; nós não.
- **Backoff com jitter** (`base * 4^n` + 0–1000 ms aleatório). Com um worker sequencial o jitter quase
  não importa, mas custa uma linha e evita sincronia se um dia houver dois.
- **`tentativas` é `smallint NOT NULL DEFAULT 0`** na base — o contador já existe, não precisa de
  tabela de tentativas.
- **5 tentativas** cobre janela de instabilidade de minutos. Além disso, o certo é um humano olhar.
- Erro **permanente** não gasta tentativa: vai direto para `status = 'erro'`.

A espera **não** é feita dormindo dentro da rodada. Uma rodada que falha devolve a linha para
`'pendente'` e a próxima execução do timer (5 min) já é o intervalo. O `EMAIL_ESPERA_BASE_MS` só
serve para o caso de o `Retry-After` pedir alguns segundos dentro do lote atual.

### 6.3 O que nunca é retry

Repetir e-mail é diferente de repetir qualquer outra chamada: **`202` significa entregue mesmo que a
gravação no banco falhe depois**. Se o worker recebe `202` e o `UPDATE ... SET status = 'enviado'`
morre (conexão caiu), a linha fica em `'enviando'` — e na próxima rodada seria reenviada, gerando
e-mail duplicado.

Duas defesas, as duas no código da seção 8:

1. A gravação do sucesso usa a **mesma conexão** que fez o claim, em transação curta, imediatamente
   após o `202`. A janela é de milissegundos.
2. Linha em `'enviando'` na inicialização **não volta para `'pendente'` automaticamente**: vai para
   `'erro'` com `erro = 'interrompido durante o envio - conferir Itens Enviados antes de reenviar'`.

A segunda regra é a que importa. Preferi um e-mail que talvez precise de reenvio manual (e que está
listado em `core.email_fila WHERE status = 'erro'`) a um e-mail que talvez chegue duas vezes. Aviso
duplicado de "sua solicitação precisa de revisão" faz a pessoa achar que devolveram duas vezes, e
a caixa compartilhada tem os Itens Enviados para conferir em 5 segundos qual dos dois casos é.

---

## 7. Produto: um e-mail, e só

A reunião fechou **um** e-mail para a fase 1:

> Quando a SCI entra em **Aguardando revisão do solicitante**, avisar o solicitante.

### 7.1 O quadro de motivos

O `motivo` de `core.email_fila` é o identificador do aviso. O comentário da coluna, no próprio
`01-base.sql`, já diz para que ele serve:

> *"Por que este e-mail existe (ex: sci_revisao_solicitante). Serve para nao disparar aviso que
> ninguem pediu: na SCI a unica notificacao acordada e a de revisao do solicitante."*

| `motivo` | Quando o banco grava | Para quem | Fase 1 |
|---|---|---|---|
| `sci_revisao_solicitante` | `almox.sci.status` → `revisao_solicitante` | solicitante da SCI | **ligado** |
| `scm_pendente_aprovacao` | `INSERT` em `almox.scm` (com `aprovador_email`) | responsável do grupo | **preparado, desligado** |

Nada mais. Não existe outro `INSERT INTO core.email_fila` no arquivo — confira com
`grep -n "email_fila" 01-base.sql` e você acha exatamente estes dois, nas linhas 785 e 947.

### 7.2 Por que este e-mail, e não outro

A pergunta certa não é "essa transição é importante?". Todas são. A pergunta é: **quem precisa agir e
essa pessoa abre o sistema por conta própria?**

`revisao_solicitante` é a única transição da SCI que passa nas duas:

- **A ação é de quem não é do almoxarifado.** Só o solicitante pode corrigir o que foi pedido. O
  `01-base.sql` chega a garantir isso por constraint — `ck_sci_motivo_na_revisao` obriga
  `observacao_almoxarife` preenchido nesse status, ou seja, existe um pedido concreto endereçado a
  uma pessoa concreta.
- **Essa pessoa é um técnico de manutenção.** Ele abre o sistema quando precisa pedir algo, não para
  conferir se pediram algo dele. Sem aviso, a SCI fica em `revisao_solicitante` até alguém cruzar com
  ele no corredor. `app.vw_sci.dias_aberta` existe justamente porque isso acontecia.

E tem o efeito colateral que o campo `aviso_solicitante_lido` na tabela já antecipava: o fluxo
**para** ali. Não é uma notificação informativa, é o desbloqueio de uma solicitação parada.

### 7.3 Por que os outros ficaram de fora

O que foi considerado e recusado, com o motivo de cada um:

| Aviso considerado | Por que ficou fora |
|---|---|
| SCI criada → almoxarifado | **o almoxarifado olha o sistema todo dia.** A fila de trabalho deles é a tela; e-mail seria uma segunda fila, pior, sem status e sem ordem |
| SCI → `em_compra` / `aguardando_cadastro` | ninguém precisa agir; é acompanhamento. Quem quer saber abre `app.vw_sci` e vê `status_rotulo` |
| SCI → `cadastrado` | é a boa notícia, e o solicitante descobre quando vai usar o item. Junto com os dois de cima daria **4 e-mails por SCI** |
| SCI → `reprovada` | discutido: parece merecer aviso. Mas reprovação vem conversada — o almoxarife fala com o técnico antes de reprovar. E-mail chegaria depois da conversa |
| SCM aprovada / reprovada → solicitante | quem enviou a SCM acompanha, porque está esperando material. Fica para a fase 2, junto com a tela de "minhas solicitações" |
| Medidor sem leitura no mês | `app.vw_saude_operacional.medidores_sem_leitura_recente` já mostra, e o dono da rotina é uma pessoa só |
| Treinamento vencido (LMS) | `app.vw_lms_conformidade` cobre; e-mail de treinamento vencido em massa é a receita mais rápida de virar regra do Outlook |
| Matrícula bloqueada por tentativas | `app.vw_lms_bloqueada` é a fila do administrador — ele abre a tela para liberar |

O raciocínio único por trás de todos: **cada e-mail a mais reduz a chance de o único importante ser
lido.** Aviso que ninguém precisa agir vira ruído; ruído vira regra de "mover para pasta"; e no dia em
que o aviso de revisão chegar, ele cai na pasta junto com o resto. Um e-mail que sempre pede ação é um
e-mail que continua sendo aberto no segundo ano de operação.

O outro motivo é de manutenção: cada aviso ligado é um texto para escrever, um caso de teste, e uma
pessoa perguntando por que recebeu. Com uma pessoa mantendo a plataforma, esse custo é real.

### 7.4 O aviso da SCM: preparado, desligado

**Estado atual do banco.** `almox.fn_scm_transicao()` já grava a linha na fila, no `INSERT` da SCM
(linha 947 do `01-base.sql`):

```sql
IF NEW.aprovador_email IS NOT NULL THEN
  INSERT INTO core.email_fila (destinatario, assunto, corpo_html, referencia_tabela, referencia_id, motivo)
  VALUES (NEW.aprovador_email,
          NEW.codigo || ' - nova solicitacao de compra aguardando sua aprovacao',
          ...,
          'almox.scm', NEW.id::text, 'scm_pendente_aprovacao');
END IF;
```

O destinatário é o `aprovador_email` **congelado** na criação, que veio de `app.vw_aprovador_de`:
responsável direto do grupo → `email_lider_excecao` → ninguém. Se o grupo está sem responsável, a
coluna fica nula e nem linha de fila existe — é por isso que
`app.vw_saude_operacional.grupos_sem_responsavel` é a primeira coisa a zerar antes de ligar este
aviso.

**Como fica desligado.** Não se mexe no gatilho. Quem decide o que sai da fila é o worker, por
allowlist:

```bash
# /etc/biotrop/manutencao.env
EMAIL_MOTIVOS_ATIVOS=sci_revisao_solicitante
```

Motivo não listado **não é enviado nem fica pendente para sempre**: o worker marca
`status = 'cancelado'` com o carimbo no `erro`:

```
status = 'cancelado'
erro   = 'motivo nao habilitado: scm_pendente_aprovacao'
```

Fica assim, e não como `'pendente'` esquecido, por uma razão de operação: `emails_pendentes` em
`app.vw_saude_operacional` precisa significar **"tem e-mail para sair e não saiu"**. Se as linhas da
SCM ficassem pendentes, esse número cresceria todo dia e o indicador que avisa que o Graph caiu
deixaria de avisar nada.

**Como ligar, no dia em que decidirem ligar:**

```bash
# 1. checar que todo grupo tem responsavel (senao o aviso simplesmente nao existe)
psql "$DATABASE_URL" -c "select * from app.vw_aprovador_de where origem = 'nenhum' order by grupo_nome, usuario_nome;"

# 2. checar quantos ficariam pendentes agora
psql "$DATABASE_URL" -c "select count(*) from almox.scm where status = 'pendente_aprovacao_lider';"

# 3. ligar o motivo
sudo sed -i 's/^EMAIL_MOTIVOS_ATIVOS=.*/EMAIL_MOTIVOS_ATIVOS=sci_revisao_solicitante,scm_pendente_aprovacao/' \
  /etc/biotrop/manutencao.env
sudo systemctl restart biotrop-email.timer
```

O template já existe em `src/email/templates.js` (seção 9.3) e já é testado com `EMAIL_DRY_RUN=1`.
Ligar é uma variável de ambiente, não um deploy de código.

**O passado não é reenviado.** As linhas canceladas ficam canceladas: ligar o aviso não deve despejar
um e-mail de aprovação para cada SCM que já estava na fila há semanas — o líder receberia dezenas de
avisos de coisas que ele já viu na tela, e a primeira impressão do aviso novo seria "isso aqui manda
spam". Se em algum caso específico for desejado reenviar, é explícito e datado:

```sql
-- reabrir SOMENTE as canceladas por motivo desligado, das SCM ainda pendentes,
-- criadas nos ultimos 7 dias. Confira o SELECT antes de rodar o UPDATE.
SELECT f.id, f.destinatario, f.assunto, f.criado_em
  FROM core.email_fila f
  JOIN almox.scm s ON s.id::text = f.referencia_id
 WHERE f.motivo = 'scm_pendente_aprovacao'
   AND f.status = 'cancelado'
   AND f.erro LIKE 'motivo nao habilitado%'
   AND s.status = 'pendente_aprovacao_lider'
   AND f.criado_em >= now() - interval '7 days';

UPDATE core.email_fila f
   SET status = 'pendente', erro = NULL, tentativas = 0
  FROM almox.scm s
 WHERE s.id::text = f.referencia_id
   AND f.motivo = 'scm_pendente_aprovacao'
   AND f.status = 'cancelado'
   AND f.erro LIKE 'motivo nao habilitado%'
   AND s.status = 'pendente_aprovacao_lider'
   AND f.criado_em >= now() - interval '7 days';
```

O `JOIN` com `almox.scm` é o que impede o pior caso: reenviar "aguardando sua aprovação" de uma SCM
que já foi aprovada semana passada.

### 7.5 `core.usuario.notificacoes` não silencia este e-mail

A base tem `core.usuario.notificacoes boolean NOT NULL DEFAULT true`, importado do localStorage
(`mig.importar_usuarios` copia o valor). A tentação é usar como opt-out geral.

**Decisão: o aviso de revisão de SCI ignora essa coluna.** Ele não é comunicado, é o desbloqueio de
uma solicitação que a própria pessoa abriu e que está parada esperando ela. Alguém que desmarcou
"notificações" há dois anos numa tela de preferências não escolheu abandonar as próprias
solicitações.

A coluna continua servindo para o que vier depois — os avisos de acompanhamento da fase 2, esses sim
opcionais. Se um dia a decisão mudar, o lugar de aplicar é o worker (seção 8.5), com um `JOIN` em
`core.usuario` no carregamento dos dados, e não o gatilho: gatilho que consulta preferência do
usuário faz a preferência de hoje decidir o histórico de amanhã.

---

## 8. O worker

### 8.1 Arquivos

```
src/
  email/
    graph.js       # token client_credentials + sendMail  (secoes 4 e 5)
    templates.js   # assunto e corpo por motivo, em portugues  (secao 9)
    worker.js      # consome core.email_fila
bin/
  enviar-emails.js # entrypoint chamado pelo systemd timer
```

Nenhuma dependência nova: `pg` já está no projeto (`LOGIN-MICROSOFT.md`, seção 4) e `fetch` é global
no Node 20.

### 8.2 Ambiente

Acrescente ao `/etc/biotrop/manutencao.env` (modo `600`) que o login já criou:

> Os caminhos deste guia seguem o `LOGIN-MICROSOFT.md`: env em `/etc/biotrop/manutencao.env`, código
> em `/opt/biotrop/manutencao`. O `DEPLOY-VM-AZURE-E-BACKUP.md` usa `/etc/biotrop/app.env` e
> `/opt/biotrop/app`. **São o mesmo arquivo e o mesmo diretório** — escolha um par de nomes antes de
> criar a VM e troque nos três documentos, senão o `EnvironmentFile` do systemd aponta para o vazio e
> o worker sobe sem `GRAPH_CLIENT_SECRET`.

```bash
# Entra ID - registro "Biotrop Manutencao - Graph Mailer" (NAO e o do login)
GRAPH_TENANT_ID=00000000-0000-0000-0000-000000000000
GRAPH_CLIENT_ID=00000000-0000-0000-0000-000000000000
GRAPH_CLIENT_SECRET=cole-aqui-o-valor-do-segredo
GRAPH_REMETENTE=manutencao@biotrop.com.br
GRAPH_REPLY_TO=manutencao@biotrop.com.br

# Quais motivos o worker entrega. Motivo fora desta lista e cancelado com carimbo.
# Fase 1: so o aviso de revisao da SCI (secao 7).
EMAIL_MOTIVOS_ATIVOS=sci_revisao_solicitante

# Ritmo
EMAIL_LOTE=25
EMAIL_PAUSA_MS=2000
EMAIL_TENTATIVAS_MAX=5
EMAIL_ESPERA_BASE_MS=2000

# 1 = nao chama o Graph, imprime o que enviaria e nao altera a fila
EMAIL_DRY_RUN=0

# Conexao propria do worker (role restrita da secao 8.3)
EMAIL_DATABASE_URL=postgres://biotrop_mailer_login:senha@localhost:5432/biotrop
```

`GRAPH_REMETENTE` existe além do `DEFAULT` da coluna porque a fila pode ter linha antiga com outra
caixa: o worker usa `f.remetente` da linha e cai no `GRAPH_REMETENTE` só quando a linha vem sem
valor.

### 8.3 A role do banco: o worker não é a aplicação

O worker não precisa de nada além da fila. Rodar com a connection string da aplicação seria dar a um
processo de cron o direito de apagar SCI.

```sql
-- rodar uma vez, fora da migration (tem senha dentro)
CREATE ROLE biotrop_mailer NOLOGIN;

GRANT USAGE ON SCHEMA core, app, almox TO biotrop_mailer;

-- a fila: le e atualiza status/tentativas/erro/ids. Nao insere (quem insere e o gatilho).
GRANT SELECT, UPDATE ON core.email_fila TO biotrop_mailer;

-- log da rodada
GRANT SELECT, INSERT, UPDATE ON core.rotina_execucao TO biotrop_mailer;
GRANT USAGE, SELECT ON SEQUENCE core.rotina_execucao_id_seq TO biotrop_mailer;

-- dados dos templates (somente leitura, e somente as views)
GRANT SELECT ON app.vw_sci, app.vw_sci_campos, app.vw_scm, app.vw_scm_itens,
                app.vw_email_fila_pendente TO biotrop_mailer;

CREATE USER biotrop_mailer_login WITH PASSWORD 'senha-forte-aqui' IN ROLE biotrop_mailer;
```

Repare no que **não** foi concedido: `INSERT` na fila (o worker não inventa e-mail), `DELETE` em nada
(fila é histórico de envio), e nenhum acesso a `lms.questao_opcao`, `core.usuario` ou `core.auditoria`.
Se o `.env` da VM vazar, o pior que essa credencial faz é marcar e-mail como enviado.

O `USAGE ON SCHEMA almox` está ali porque as views de `app` chamam funções de rótulo
(`almox.sci_status_rotulo`, `almox.scm_status_rotulo`). O `GRANT SELECT`, no entanto, foi dado
**somente nas views**. No Postgres, o acesso às tabelas referenciadas por uma view é resolvido com os
privilégios do **dono da view** (as views do `01-base.sql` não usam `security_invoker`), então o
worker lê `app.vw_sci` e não alcança `almox.sci` direto:

```sql
-- conferindo, conectado como biotrop_mailer_login
SELECT count(*) FROM app.vw_sci;    -- funciona
SELECT count(*) FROM almox.sci;     -- ERROR: permission denied for table sci
```

### 8.4 Claim: como duas rodadas não mandam o mesmo e-mail

Três mecanismos, cada um resolvendo um problema diferente:

**1. `pg_try_advisory_lock` — uma rodada por vez.** O timer roda a cada 5 minutos; uma rodada lenta
(Graph devagar, lote cheio) pode ainda estar viva quando a próxima começa. A segunda pega o lock,
recebe `false` e sai com código 0, sem erro e sem log de alarme.

**2. `FOR UPDATE SKIP LOCKED` com `LIMIT 1` — uma linha por vez.** O claim pega **uma** mensagem,
marca `status = 'enviando'` e só então chama o Graph. Poderia pegar as 25 de uma vez e economizar
round-trips, mas aí um crash no meio do lote deixaria 25 linhas em dúvida em vez de uma. Round-trip
em `localhost` custa microssegundos; e-mail duplicado custa credibilidade.

**3. Recuperação de `'enviando'` na inicialização.** Como o lock garante uma instância, qualquer linha
em `'enviando'` no começo da rodada é resto de processo morto. Vai para `'erro'` com carimbo, não para
`'pendente'` (a razão está na seção 6.3).

```sql
-- o claim, exatamente como o worker executa
WITH alvo AS (
  SELECT id
    FROM core.email_fila
   WHERE status = 'pendente'
   ORDER BY criado_em          -- usa ix_email_fila_pendente
   LIMIT 1
   FOR UPDATE SKIP LOCKED
)
UPDATE core.email_fila f
   SET status = 'enviando'
  FROM alvo
 WHERE f.id = alvo.id
RETURNING f.id, f.destinatario, f.copia, f.remetente, f.assunto, f.corpo_html,
          f.referencia_tabela, f.referencia_id, f.motivo, f.tentativas;
```

### 8.5 `src/email/worker.js`

```js
'use strict';
const { Pool } = require('pg');
const { enviarEmail, ErroGraph } = require('./graph');
const { montarMensagem } = require('./templates');

const ROTINA = 'email.enviar_fila';

// Numero fixo do advisory lock deste worker. E o unico advisory lock do projeto;
// se algum dia entrar outro, documente o numero aqui do lado.
const LOCK = 981001;

const LOTE           = Number(process.env.EMAIL_LOTE || 25);
const PAUSA_MS       = Number(process.env.EMAIL_PAUSA_MS || 2000);
const TENTATIVAS_MAX = Number(process.env.EMAIL_TENTATIVAS_MAX || 5);
const ESPERA_BASE_MS = Number(process.env.EMAIL_ESPERA_BASE_MS || 2000);
const REMETENTE      = process.env.GRAPH_REMETENTE || 'manutencao@biotrop.com.br';
const REPLY_TO       = process.env.GRAPH_REPLY_TO || null;
const DRY_RUN        = process.env.EMAIL_DRY_RUN === '1';

const MOTIVOS_ATIVOS = new Set(
  String(process.env.EMAIL_MOTIVOS_ATIVOS || '')
    .split(',').map((s) => s.trim()).filter(Boolean)
);

const pool = new Pool({
  connectionString: process.env.EMAIL_DATABASE_URL,
  max: 2,
  application_name: 'biotrop-email-worker',
});

const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

// base * 4^n + jitter. n = tentativas ja feitas.
function esperaBackoff(tentativas) {
  return ESPERA_BASE_MS * Math.pow(4, Math.max(0, tentativas - 1)) + Math.floor(Math.random() * 1000);
}

const SQL_CLAIM = `
  WITH alvo AS (
    SELECT id FROM core.email_fila
     WHERE status = 'pendente'
     ORDER BY criado_em
     LIMIT 1
     FOR UPDATE SKIP LOCKED
  )
  UPDATE core.email_fila f
     SET status = 'enviando'
    FROM alvo
   WHERE f.id = alvo.id
  RETURNING f.id, f.destinatario, f.copia, f.remetente, f.assunto, f.corpo_html,
            f.referencia_tabela, f.referencia_id, f.motivo, f.tentativas`;

async function rodar() {
  const cli = await pool.connect();
  const contagem = { enviados: 0, cancelados: 0, reagendados: 0, erros: 0, orfaos: 0 };
  let execucaoId = null;

  try {
    // 1. uma rodada por vez
    const { rows: [lock] } = await cli.query('SELECT pg_try_advisory_lock($1) AS ok', [LOCK]);
    if (!lock.ok) {
      console.log('[email] outra rodada em andamento - saindo');
      return 0;
    }

    // 2. ensaio nao registra rodada nem altera a fila - so imprime
    if (DRY_RUN) {
      await ensaio(cli);
      return 0;
    }

    // 3. abre o log da rodada. Rodada que morre no meio fica com fim IS NULL,
    //    e isso e detectavel (secao 10.2).
    const { rows: [exec] } = await cli.query(
      `INSERT INTO core.rotina_execucao (rotina) VALUES ($1) RETURNING id`, [ROTINA]
    );
    execucaoId = exec.id;

    // 4. resto de processo morto: com o lock, 'enviando' aqui e sempre orfao
    const orfaos = await cli.query(
      `UPDATE core.email_fila
          SET status = 'erro',
              erro   = 'interrompido durante o envio - conferir Itens Enviados antes de reenviar'
        WHERE status = 'enviando'
       RETURNING id`
    );
    contagem.orfaos = orfaos.rowCount;
    for (const o of orfaos.rows) console.warn('[email] orfao em enviando:', o.id);

    // 5. o lote
    for (let i = 0; i < LOTE; i++) {
      const { rows: [fila] } = await cli.query(SQL_CLAIM);
      if (!fila) break;                          // fila vazia

      if (!MOTIVOS_ATIVOS.has(fila.motivo)) {
        await cli.query(
          `UPDATE core.email_fila SET status = 'cancelado', erro = $2 WHERE id = $1`,
          [fila.id, `motivo nao habilitado: ${fila.motivo}`]
        );
        contagem.cancelados++;
        continue;                                 // nao gasta pausa: nao houve chamada
      }

      try {
        const msg = await montarMensagem(cli, fila);

        const { clientRequestId, requestId } = await enviarEmail({
          remetente: fila.remetente || REMETENTE,
          para: fila.destinatario,
          copia: fila.copia || [],
          assunto: msg.assunto,
          html: msg.html,
          replyTo: REPLY_TO,
        });

        // Mesma conexao, imediatamente apos o 202: a janela de duplicata e minima.
        await cli.query(
          `UPDATE core.email_fila
              SET status = 'enviado', enviado_em = now(), erro = NULL,
                  tentativas = tentativas + 1, graph_message_id = $2
            WHERE id = $1`,
          [fila.id, `crid:${clientRequestId}${requestId ? ` rid:${requestId}` : ''}`]
        );
        contagem.enviados++;
        console.log(`[email] enviado ${fila.motivo} -> ${fila.destinatario} (${fila.id})`);
      } catch (e) {
        const tentativas = fila.tentativas + 1;
        const transitorio = e instanceof ErroGraph ? e.transitorio : false;
        const podeRepetir = transitorio && tentativas < TENTATIVAS_MAX;
        const detalhe = `${new Date().toISOString()} t${tentativas}: ${e.message}`.slice(0, 4000);

        await cli.query(
          `UPDATE core.email_fila
              SET status = $3::core.email_status, tentativas = $2, erro = $4
            WHERE id = $1`,
          [fila.id, tentativas, podeRepetir ? 'pendente' : 'erro', detalhe]
        );

        if (podeRepetir) { contagem.reagendados++; } else { contagem.erros++; }
        console.error(`[email] falha ${fila.id} (${podeRepetir ? 'reagendado' : 'erro final'}):`, e.message);

        // Retry-After manda; senao, o backoff. Espera curta so faz sentido dentro do lote.
        const espera = e instanceof ErroGraph && e.retryAfterMs != null
          ? e.retryAfterMs
          : (podeRepetir ? esperaBackoff(tentativas) : 0);

        if (espera > 0 && espera <= 60000) {
          await dormir(espera);
        } else if (espera > 60000) {
          console.warn(`[email] espera de ${Math.round(espera / 1000)}s - encerrando a rodada, o timer retoma`);
          break;
        }
        continue;
      }

      await dormir(PAUSA_MS);
    }

    return 0;
  } finally {
    if (execucaoId !== null) {
      const detalhe = `enviados: ${contagem.enviados}, cancelados: ${contagem.cancelados}, `
        + `reagendados: ${contagem.reagendados}, erros: ${contagem.erros}, orfaos: ${contagem.orfaos}`;
      await cli.query(
        `UPDATE core.rotina_execucao SET fim = now(), sucesso = $2, detalhe = $3 WHERE id = $1`,
        [execucaoId, contagem.erros === 0, detalhe]
      ).catch((e) => console.error('[email] nao gravou rotina_execucao:', e.message));
      console.log(`[email] ${detalhe}`);
    }
    // Sessao encerra: o advisory lock cai junto. pg_advisory_unlock explicito
    // seria redundante e, com pool, poderia soltar na conexao errada.
    cli.release();
    await pool.end();
  }
}

/** DRY_RUN: le a fila, monta o e-mail, imprime. Nao chama Graph, nao altera status. */
async function ensaio(cli) {
  const { rows } = await cli.query(
    `SELECT id, destinatario, copia, remetente, assunto, corpo_html,
            referencia_tabela, referencia_id, motivo, tentativas, status
       FROM core.email_fila
      WHERE status IN ('pendente', 'erro')
      ORDER BY criado_em
      LIMIT $1`, [LOTE]
  );
  console.log(`[email] ENSAIO - ${rows.length} linha(s), motivos ativos: ${[...MOTIVOS_ATIVOS].join(', ') || '(nenhum)'}`);
  for (const f of rows) {
    const ativo = MOTIVOS_ATIVOS.has(f.motivo);
    const msg = await montarMensagem(cli, f);
    console.log('-'.repeat(72));
    console.log(`motivo ......: ${f.motivo} ${ativo ? '[ATIVO]' : '[DESLIGADO - seria cancelado]'}`);
    console.log(`status ......: ${f.status}  tentativas: ${f.tentativas}`);
    console.log(`de ..........: ${f.remetente || REMETENTE}`);
    console.log(`para ........: ${f.destinatario}${(f.copia || []).length ? ' cc: ' + f.copia.join(', ') : ''}`);
    console.log(`assunto .....: ${msg.assunto}`);
    console.log(`template ....: ${msg.origem}`);
    console.log(msg.html);
  }
}

module.exports = { rodar };
```

### 8.6 `bin/enviar-emails.js`

```js
#!/usr/bin/env node
'use strict';
require('../src/email/worker')
  .rodar()
  .then((codigo) => process.exit(codigo || 0))
  .catch((e) => {
    // Falha fora do laco (banco inacessivel, env faltando): sai !=0 para o
    // systemd registrar e para o `systemctl status` mostrar.
    console.error('[email] rodada abortada:', e.stack || e.message);
    process.exit(1);
  });
```

### 8.7 systemd: service + timer

`/etc/systemd/system/biotrop-email.service`:

```ini
[Unit]
Description=Biotrop Manutencao - envio da fila de e-mail via Microsoft Graph
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=oneshot
User=biotrop
WorkingDirectory=/opt/biotrop/manutencao
EnvironmentFile=/etc/biotrop/manutencao.env
ExecStart=/usr/bin/node bin/enviar-emails.js
TimeoutStartSec=300
# Endurecimento: o worker so precisa de rede e do socket do Postgres.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
```

`/etc/systemd/system/biotrop-email.timer`:

```ini
[Unit]
Description=Roda a fila de e-mail a cada 5 minutos

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now biotrop-email.timer

systemctl list-timers biotrop-email.timer      # quando roda a proxima
sudo systemctl start biotrop-email.service     # rodar agora, na mao
journalctl -u biotrop-email.service -n 50 --no-pager
```

`Type=oneshot` com timer, e não um daemon com `setInterval`: processo que nasce e morre a cada 5
minutos não acumula vazamento de memória, não precisa de `systemd` reiniciando nada, e o
`journalctl` fica com uma entrada por rodada — que é como se investiga "por que o e-mail das 14h não
saiu".

`Persistent=true` faz a rodada perdida (VM reiniciada, timer parado) acontecer assim que o timer
volta. `TimeoutStartSec=300` é maior que o pior lote possível (25 × 2s de pausa + latência) com folga:
se estourar, o problema não é lentidão, é travamento — e `systemd` mata.

---

## 9. Templates em português

### 9.1 De onde vem o texto

Os gatilhos do `01-base.sql` já montam um `corpo_html` por concatenação de strings em SQL. Funciona,
e é o que garante que a intenção de enviar nasce na mesma transação do fato. Mas mudar o texto por
ali significa: escrever migration, subir na VM, rodar `psql`. Texto de e-mail é a coisa que mais muda
na vida de um sistema ("põe o número da OM no assunto", "tira o link, ninguém clica").

**Decisão: o texto final é montado em Node, a partir de `referencia_tabela` + `referencia_id`.**
O `corpo_html` do banco é o **fallback**: motivo sem template em Node sai com o corpo que o gatilho
escreveu, dentro do mesmo envelope visual. Assim um motivo novo já avisa algo antes de alguém escrever
template, e nenhum e-mail deixa de sair porque o template não existe.

Consequência boa de quebra: o escape de HTML passa a acontecer em Node, com uma função só, em vez de
depender de concatenação em PL/pgSQL (o problema está na seção 9.5).

### 9.2 O aviso de revisão da SCI

O que a pessoa recebe:

```
De .......: Manutencao Biotrop <manutencao@biotrop.com.br>
Assunto ..: SCI-0007 - sua solicitacao de cadastro precisa de revisao

  Sua solicitacao precisa de revisao

  Ola, Joao.
  O almoxarifado devolveu a SCI-0007 para revisao. Enquanto ela estiver nesse
  status, nao avanca para compra.

  ┌ O que precisa ser corrigido ─────────────────────────────────┐
  │ Falta a marca homologada e a foto do item. A medida informada │
  │ (1/2") nao confere com a descricao.                          │
  └──────────────────────────────────────────────────────────────┘

  Solicitacao ...: SCI-0007
  Familia .......: Tubos e conexoes
  Aberta em .....: 03/09/2026 (6 dias)
  Situacao ......: Aguardando revisao do solicitante

  O que voce preencheu
  Medida ..........: 1/2"
  Material ........: Aco inox 304
  Aplicacao .......: Linha de agua do CAMM 2

  [ Abrir a solicitacao ]

  Corrija pelo sistema: responder este e-mail nao altera a solicitacao.
  Mensagem automatica da plataforma de manutencao - Biotrop.
```

O texto foi escrito com três restrições:

1. **A devolutiva do almoxarife aparece em destaque, não no meio do parágrafo.** É a única informação
   que a pessoa precisa ler. O `01-base.sql` garante por `ck_sci_motivo_na_revisao` que ela existe.
2. **Diz o que acontece se ela não fizer nada** ("não avança para compra"). Aviso que não explica a
   consequência é ignorado.
3. **Diz que responder o e-mail não resolve.** A resposta chega na caixa compartilhada e alguém lê,
   mas a correção só entra pelo formulário — e a pessoa que responde por e-mail acha, de boa-fé, que
   já resolveu.

### 9.3 O aviso de aprovação da SCM (preparado, desligado)

Mesmo template pronto, sem estar na allowlist (seção 7.4):

```
De .......: Manutencao Biotrop <manutencao@biotrop.com.br>
Assunto ..: SCM-0031 - solicitacao de compra aguardando sua aprovacao

  Aprovacao de compra pendente

  Ola, Carlos.
  Joao Silva (Mecanica) enviou a SCM-0031 e ela esta aguardando sua aprovacao
  como responsavel do grupo.

  Solicitacao ...: SCM-0031
  Urgencia ......: Alta
  CAMM ..........: CAMM 2
  Centro de custo: Manutencao Industrial
  OM ............: 4512
  Itens .........: 3 (quantidade total 14)

  Uso pretendido
  Reposicao de vedacao da bomba 2 da linha de envase, parada prevista sabado.

  Itens
  1. 100234  Anel oring 40x3 NBR .......... 6 un
  2. 100871  Retentor 45x62x8 ............. 4 un
  3. 101002  Graxa alimenticia 500g ....... 4 un

  [ Abrir a fila de aprovacao ]

  Mensagem automatica da plataforma de manutencao - Biotrop.
```

Dois cuidados que o template já traz:

- Diz **por que** é com ele ("como responsável do grupo"), porque o aprovador foi resolvido por
  `app.vw_aprovador_de` e ele pode não saber que é o responsável cadastrado.
- Traz os itens no corpo. Aprovação de compra com 3 itens se resolve lendo o e-mail; forçar o clique
  para ver o que está sendo comprado é o que faz aprovação demorar dois dias.

### 9.4 `src/email/templates.js`

```js
'use strict';

const APP_BASE_URL = process.env.APP_BASE_URL || 'https://manutencao.biotrop.com.br';

/** Escape de HTML. Toda interpolacao de dado do banco passa por aqui. */
function esc(v) {
  if (v === null || v === undefined) return '';
  return String(v)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function data(d) {
  if (!d) return '';
  return new Date(d).toLocaleDateString('pt-BR', { timeZone: 'America/Sao_Paulo' });
}

function numero(n) {
  if (n === null || n === undefined) return '';
  const x = Number(n);
  return Number.isInteger(x) ? String(x) : x.toFixed(3).replace(/0+$/, '').replace(/\.$/, '');
}

/** "Joao Carlos da Silva" -> "Joao". Nome vazio devolve '' e o cumprimento fica so "Ola." */
function primeiroNome(nome) {
  return esc(String(nome || '').trim().split(/\s+/)[0] || '');
}

function cumprimento(nome) {
  const n = primeiroNome(nome);
  return n ? `<p>Ola, ${n}.</p>` : '<p>Ola.</p>';
}

/**
 * Envelope visual. CSS inline e tabela de 600px porque o Outlook desktop
 * ignora <style> em muitas versoes e nao respeita flex/grid.
 */
function envelope({ titulo, blocos }) {
  return `<!-- biotrop-manutencao -->
<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%"
       style="background:#f4f5f7;margin:0;padding:24px 0;">
  <tr><td align="center">
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" width="600"
           style="width:600px;max-width:100%;background:#ffffff;border:1px solid #e1e4e8;border-radius:6px;
                  font-family:Segoe UI,Arial,sans-serif;color:#24292e;">
      <tr><td style="padding:20px 28px;border-bottom:3px solid #0b6b3a;">
        <div style="font-size:13px;letter-spacing:.08em;text-transform:uppercase;color:#0b6b3a;font-weight:600;">
          Biotrop &middot; Manutencao
        </div>
        <div style="font-size:20px;font-weight:600;margin-top:6px;">${esc(titulo)}</div>
      </td></tr>
      <tr><td style="padding:24px 28px;font-size:15px;line-height:1.55;">
        ${blocos.join('\n        ')}
      </td></tr>
      <tr><td style="padding:16px 28px;border-top:1px solid #e1e4e8;font-size:12px;color:#6a737d;">
        Mensagem automatica da plataforma de manutencao &mdash; Biotrop.
      </td></tr>
    </table>
  </td></tr>
</table>`;
}

function destaque(rotulo, texto) {
  return `<div style="margin:18px 0;padding:14px 16px;background:#fff8e1;border-left:4px solid #f0ad00;">
          <div style="font-size:12px;font-weight:600;text-transform:uppercase;color:#8a6100;margin-bottom:6px;">${esc(rotulo)}</div>
          <div style="white-space:pre-wrap;">${esc(texto)}</div>
        </div>`;
}

function ficha(pares) {
  const linhas = pares
    .filter(([, v]) => v !== null && v !== undefined && String(v).trim() !== '')
    .map(([k, v]) => `<tr>
            <td style="padding:3px 12px 3px 0;color:#6a737d;white-space:nowrap;vertical-align:top;">${esc(k)}</td>
            <td style="padding:3px 0;font-weight:600;">${esc(v)}</td>
          </tr>`);
  if (!linhas.length) return '';
  return `<table role="presentation" cellpadding="0" cellspacing="0" border="0"
               style="margin:16px 0;font-size:14px;">${linhas.join('')}</table>`;
}

function botao(texto, url) {
  return `<div style="margin:24px 0 8px;">
          <a href="${esc(url)}"
             style="display:inline-block;padding:11px 22px;background:#0b6b3a;color:#ffffff;
                    text-decoration:none;border-radius:4px;font-weight:600;font-size:15px;">${esc(texto)}</a>
        </div>
        <div style="font-size:12px;color:#6a737d;">Se o botao nao abrir, use: ${esc(url)}</div>`;
}

// ---------------------------------------------------------------------------
// Um template por motivo. carregar() devolve null quando o dado nao existe mais
// (solicitacao apagada): ai o worker cai no corpo_html do banco.
// ---------------------------------------------------------------------------
const TEMPLATES = {

  sci_revisao_solicitante: {
    async carregar(cli, fila) {
      const { rows: [sci] } = await cli.query(
        `SELECT codigo, status_rotulo, familia_nome, solicitante_nome, observacoes,
                observacao_almoxarife, criado_em, dias_aberta
           FROM app.vw_sci WHERE id = $1::uuid`, [fila.referencia_id]
      );
      if (!sci) return null;
      const { rows: campos } = await cli.query(
        `SELECT rotulo, valor FROM app.vw_sci_campos
          WHERE sci_id = $1::uuid AND nullif(btrim(valor), '') IS NOT NULL
          ORDER BY posicao`, [fila.referencia_id]
      );
      return { sci, campos };
    },

    assunto: ({ sci }) => `${sci.codigo} - sua solicitacao de cadastro precisa de revisao`,

    html: ({ sci, campos }, fila) => envelope({
      titulo: 'Sua solicitacao precisa de revisao',
      blocos: [
        cumprimento(sci.solicitante_nome),
        `<p>O almoxarifado devolveu a <b>${esc(sci.codigo)}</b> para revisao.
          Enquanto ela estiver nesse status, <b>nao avanca para compra</b>.</p>`,
        destaque('O que precisa ser corrigido', sci.observacao_almoxarife || '(sem observacao registrada)'),
        ficha([
          ['Solicitacao', sci.codigo],
          ['Familia', sci.familia_nome],
          ['Aberta em', `${data(sci.criado_em)} (${sci.dias_aberta} dias)`],
          ['Situacao', sci.status_rotulo],
        ]),
        campos.length
          ? `<div style="font-size:13px;font-weight:600;text-transform:uppercase;color:#6a737d;margin-top:20px;">O que voce preencheu</div>`
            + ficha(campos.map((c) => [c.rotulo, c.valor]))
          : '',
        botao('Abrir a solicitacao', `${APP_BASE_URL}/almoxarifado/sci/${fila.referencia_id}`),
        `<p style="margin-top:20px;font-size:13px;color:#6a737d;">
          Corrija pelo sistema: responder este e-mail nao altera a solicitacao.</p>`,
      ],
    }),
  },

  // Preparado. Nao entra na allowlist da fase 1 (secao 7.4).
  scm_pendente_aprovacao: {
    async carregar(cli, fila) {
      const { rows: [scm] } = await cli.query(
        `SELECT codigo, status_rotulo, urgencia_rotulo, camm, centro_custo, numero_om,
                time_solicitante, solicitante_nome, descricao_uso,
                itens, quantidade_total, criado_em
           FROM app.vw_scm WHERE id = $1::uuid`, [fila.referencia_id]
      );
      if (!scm) return null;
      const { rows: itens } = await cli.query(
        `SELECT posicao, codigo_sistema, descricao, quantidade
           FROM app.vw_scm_itens WHERE scm_id = $1::uuid ORDER BY posicao`, [fila.referencia_id]
      );
      return { scm, itens };
    },

    assunto: ({ scm }) => `${scm.codigo} - solicitacao de compra aguardando sua aprovacao`,

    html: ({ scm, itens }, fila) => envelope({
      titulo: 'Aprovacao de compra pendente',
      blocos: [
        // Sem nome no cumprimento de proposito: aprovador_email e congelado na
        // criacao, e resolver o nome hoje pode saudar quem nao e mais o responsavel.
        `<p>Ola.</p>`,
        `<p><b>${esc(scm.solicitante_nome)}</b> (${esc(scm.time_solicitante)}) enviou a
          <b>${esc(scm.codigo)}</b> e ela esta aguardando sua aprovacao como responsavel do grupo.</p>`,
        ficha([
          ['Solicitacao', scm.codigo],
          ['Urgencia', scm.urgencia_rotulo],
          ['CAMM', scm.camm],
          ['Centro de custo', scm.centro_custo],
          ['OM', scm.numero_om],
          ['Itens', `${scm.itens} (quantidade total ${numero(scm.quantidade_total)})`],
          ['Enviada em', data(scm.criado_em)],
        ]),
        scm.descricao_uso
          ? `<div style="font-size:13px;font-weight:600;text-transform:uppercase;color:#6a737d;margin-top:20px;">Uso pretendido</div>
             <p style="white-space:pre-wrap;">${esc(scm.descricao_uso)}</p>`
          : '',
        itens.length
          ? `<div style="font-size:13px;font-weight:600;text-transform:uppercase;color:#6a737d;margin-top:20px;">Itens</div>`
            + `<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:10px 0;font-size:14px;">`
            + itens.map((i) => `<tr>
                  <td style="padding:4px 8px 4px 0;color:#6a737d;">${esc(i.posicao)}.</td>
                  <td style="padding:4px 8px 4px 0;font-family:Consolas,monospace;">${esc(i.codigo_sistema)}</td>
                  <td style="padding:4px 8px 4px 0;">${esc(i.descricao || '')}</td>
                  <td style="padding:4px 0;text-align:right;font-weight:600;white-space:nowrap;">${esc(numero(i.quantidade))}</td>
                </tr>`).join('')
            + `</table>`
          : '',
        botao('Abrir a fila de aprovacao', `${APP_BASE_URL}/almoxarifado/scm/${fila.referencia_id}`),
      ],
    }),
  },
};

/**
 * Monta assunto e html da linha da fila.
 * Ordem: template do motivo -> corpo_html do banco dentro do envelope.
 */
async function montarMensagem(cli, fila) {
  const t = TEMPLATES[fila.motivo];

  if (t) {
    try {
      const dados = await t.carregar(cli, fila);
      if (dados) {
        return {
          assunto: t.assunto(dados, fila),
          html: t.html(dados, fila),
          origem: `template:${fila.motivo}`,
        };
      }
      console.warn(`[email] ${fila.id}: referencia ${fila.referencia_tabela}/${fila.referencia_id} nao encontrada - usando corpo_html`);
    } catch (e) {
      // Template quebrado nao pode impedir o aviso de sair.
      console.error(`[email] ${fila.id}: template ${fila.motivo} falhou (${e.message}) - usando corpo_html`);
    }
  }

  return {
    assunto: fila.assunto,
    html: envelope({ titulo: fila.assunto, blocos: [fila.corpo_html] }),
    origem: t ? 'fallback:corpo_html' : 'corpo_html (sem template)',
  };
}

module.exports = { montarMensagem, envelope, esc };
```

Três escolhas do arquivo que valem explicação:

- **O link usa `fila.referencia_id`**, que os gatilhos já gravam como `NEW.id::text`. O template não
  precisa trazer o `id` da view, e a referência do e-mail é sempre a mesma que está na linha da fila —
  se um dia divergirem, é bug na fila, não no texto.
- **Template que estoura exceção cai no fallback**, não derruba o e-mail. Um `null` inesperado num
  campo novo não pode ser a razão de um técnico não ficar sabendo que a solicitação dele voltou.
- **`esc()` em tudo que vem do banco.** Não é paranoia de biblioteca: `observacao_almoxarife`,
  `descricao_uso` e a descrição de item são texto livre, e medida em polegada com `"` já é suficiente
  para quebrar atributo HTML (seção 9.5).

As rotas `/almoxarifado/sci/:id` e `/almoxarifado/scm/:id` precisam existir no app e estar atrás do
`exigeSessao` do `LOGIN-MICROSOFT.md`: quem clica sem sessão é levado ao login do Entra e volta para a
solicitação depois de autenticar.

### 9.5 Achado: o `corpo_html` do banco sai sem escape

Em `almox.fn_sci_transicao()` (linha 785 do `01-base.sql`) o corpo é concatenado direto:

```sql
'<p>A solicitacao <b>' || NEW.codigo || '</b> foi devolvida para revisao.</p>'
  '<p><b>O que o almoxarifado pediu:</b><br>' || coalesce(NEW.observacao_almoxarife, '(sem observacao)') || '</p>'
```

`observacao_almoxarife` é texto digitado por pessoa. Duas consequências reais:

1. **Quebra visual, e é o caso comum.** Uma observação com `&` ou com medida em polegada
   (`1/2" <-> 3/4"`) gera HTML inválido; `<` come o resto da frase em vários clientes de e-mail.
   O almoxarife escreve `medida < 1/2"` e a pessoa recebe um e-mail truncado exatamente na parte que
   importa.
2. **Injeção de HTML no corpo do e-mail.** Quem escreve a observação é usuário autenticado do tenant,
   então o risco é baixo — mas nada impede uma observação com `<a href="...">` e um link para fora.

Com a decisão da seção 9.1 isso **não afeta** o aviso da SCI hoje: o template em Node remonta o corpo
a partir de `app.vw_sci` e passa tudo por `esc()`. O `corpo_html` do banco só é usado no fallback. Mas
o fallback existe, então vale corrigir na origem. Fica para a `0002`:

```sql
-- migrations/0002_html_escape_email.sql  (trecho)
CREATE OR REPLACE FUNCTION core.html_escape(p text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT replace(replace(replace(replace(replace(
           p, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;');
$$;
COMMENT ON FUNCTION core.html_escape(text) IS 'Escape de HTML para o corpo_html de core.email_fila. Texto digitado por usuario (observacao do almoxarife) nunca entra no e-mail sem passar por aqui.';
```

E, no mesmo arquivo, o `CREATE OR REPLACE FUNCTION almox.fn_sci_transicao()` inteiro reescrito com as
duas interpolações envolvidas:

```sql
'<p>A solicitacao <b>' || core.html_escape(NEW.codigo) || '</b> foi devolvida para revisao.</p>' ||
'<p><b>O que o almoxarifado pediu:</b><br>' ||
  core.html_escape(coalesce(NEW.observacao_almoxarife, '(sem observacao)')) || '</p>'
```

O mesmo vale para `almox.fn_scm_transicao()`, que interpola `solicitante_nome`, `time_solicitante` e
`descricao_uso`. Como a migration é forward-only, o arquivo `0002` traz as duas funções completas —
`CREATE OR REPLACE` de função é a forma normal de mudar regra sem tocar em dado.

---

## 10. Operação

### 10.1 As quatro perguntas do dia

```sql
-- 1. o e-mail esta saindo?
SELECT emails_pendentes, emails_com_erro FROM app.vw_saude_operacional;

-- 2. o que esta parado, e desde quando
SELECT * FROM app.vw_email_fila_pendente;

-- 3. as ultimas rodadas do worker
SELECT inicio, fim, sucesso, detalhe
  FROM core.rotina_execucao
 WHERE rotina = 'email.enviar_fila'
 ORDER BY inicio DESC
 LIMIT 10;

-- 4. o que falhou de vez, com o erro
SELECT criado_em, motivo, destinatario, tentativas, erro
  FROM core.email_fila
 WHERE status = 'erro'
 ORDER BY criado_em DESC;
```

Como ler o cruzamento das duas primeiras, que é o que o comentário da tabela no `01-base.sql` já
antecipava:

| `emails_pendentes` | `emails_com_erro` | Diagnóstico |
|---|---|---|
| 0 | 0 | ou está tudo certo, ou nenhum gatilho disparou — confira `almox.sci_historico` |
| cresce | 0 | o worker não está rodando (timer parado, VM sem rede, banco recusando a role) |
| 0 | > 0 | o worker roda e o Graph recusa: segredo expirado, policy, destinatário inválido |
| cresce | > 0 | Graph fora do ar há mais tempo que as 5 tentativas |

Fila vazia **e** e-mail não chegando é problema na aplicação (o gatilho não rodou). Fila cheia é
problema no envio. São duas investigações diferentes e o indicador separa as duas sem abrir a VM.

### 10.2 Rodada que morreu no meio

```sql
-- rodada aberta ha mais de 10 min = processo morto sem gravar o fim
SELECT id, inicio, now() - inicio AS ha
  FROM core.rotina_execucao
 WHERE rotina = 'email.enviar_fila' AND fim IS NULL AND inicio < now() - interval '10 minutes'
 ORDER BY inicio DESC;
```

Isso não trava nada — o advisory lock morre com a sessão, então a rodada seguinte entra normal. É só
diagnóstico, e casa com as linhas marcadas como `interrompido durante o envio` na fila.

### 10.3 Reprocessar um e-mail que falhou

Depois de corrigir a causa (segredo novo, policy aplicada, e-mail do usuário arrumado em
`core.usuario`):

```sql
-- confira o que vai voltar para a fila ANTES
SELECT id, motivo, destinatario, tentativas, left(erro, 120) AS erro
  FROM core.email_fila
 WHERE status = 'erro' AND motivo = 'sci_revisao_solicitante'
   AND criado_em >= now() - interval '2 days';

-- reagenda: zera tentativas porque a causa mudou
UPDATE core.email_fila
   SET status = 'pendente', tentativas = 0, erro = NULL
 WHERE status = 'erro' AND motivo = 'sci_revisao_solicitante'
   AND criado_em >= now() - interval '2 days';
```

`sudo systemctl start biotrop-email.service` roda na hora, sem esperar os 5 minutos.

**Antes de reprocessar linha com `erro = 'interrompido durante o envio...'`**, abra os Itens Enviados
de `manutencao@biotrop.com.br` e confira se a mensagem saiu. É para isso que a cópia existe.

### 10.4 Cancelar um e-mail que não deve mais sair

Caso real: a SCI foi devolvida por engano e o almoxarife já corrigiu o status antes dos 5 minutos.

```sql
UPDATE core.email_fila
   SET status = 'cancelado', erro = 'cancelado manualmente: devolucao revertida antes do envio'
 WHERE id = '...'::uuid AND status = 'pendente';
```

O `AND status = 'pendente'` evita o pior caso: cancelar uma linha que o worker acabou de marcar como
`'enviando'` e já entregou, ficando com um `cancelado` no banco para um e-mail que a pessoa recebeu.

### 10.5 Ensaio sem enviar nada

Serve para revisar texto de template e para conferir o aviso da SCM antes de ligar:

```bash
sudo -u biotrop env $(grep -v '^#' /etc/biotrop/manutencao.env | xargs) \
  EMAIL_DRY_RUN=1 node /opt/biotrop/manutencao/bin/enviar-emails.js
```

Imprime motivo, se está ativo, assunto, template usado e o HTML — sem chamar o Graph e sem alterar a
fila. Para inspecionar o layout, redirecione para arquivo e abra no navegador:

```bash
... EMAIL_DRY_RUN=1 node bin/enviar-emails.js > /tmp/ensaio.html
```

Navegador não é Outlook, mas pega 90% dos erros de layout. O outro teste, o que vale, é a seção 12.

### 10.6 Segredo vencendo

```sql
-- sintoma: AADSTS7000222 no detalhe das rodadas
SELECT inicio, detalhe FROM core.rotina_execucao
 WHERE rotina = 'email.enviar_fila' AND sucesso = false
 ORDER BY inicio DESC LIMIT 5;
```

Troca sem downtime perceptível (a fila espera):

```bash
sudo sed -i 's|^GRAPH_CLIENT_SECRET=.*|GRAPH_CLIENT_SECRET=novo-valor|' /etc/biotrop/manutencao.env
sudo systemctl start biotrop-email.service   # a proxima rodada ja pega token novo
```

Não precisa reiniciar a aplicação web: o segredo do Graph só é lido pelo worker.

---

## 11. O que NÃO fazer

### 1. Não enviar e-mail direto do gatilho

A tentação é `pg_net`, `plpython` ou um `COPY ... TO PROGRAM` no `almox.fn_sci_transicao()`. O que
acontece: a transação da tela passa a depender da latência do Graph, um `403` derruba a devolutiva da
SCI (o almoxarife não consegue devolver porque o e-mail falhou), e o `ROLLBACK` não desfaz o e-mail
que já saiu. A fila existe justamente para separar "o fato aconteceu" de "o aviso saiu". O comentário
da tabela no `01-base.sql` diz isso em uma linha: *"Se o Graph estiver fora, a mensagem espera na fila
em vez de se perder."*

### 2. Não usar permissão delegada nem ROPC para o worker

Seção 2.1. O sintoma da escolha errada aparece semanas depois, na forma de fila crescendo em silêncio.

### 3. Não deixar `Mail.Send` de aplicação sem `ApplicationAccessPolicy`

Sem a policy, o `.env` da VM envia e-mail como qualquer pessoa da Biotrop. `Test-ApplicationAccessPolicy`
respondendo `Denied` para uma caixa pessoal é item de aceite, não item de checklist opcional.

### 4. Não misturar o registro do login com o do e-mail

Dois registros, dois segredos, dois raios de dano. Já está fixado na seção 2.7 do `LOGIN-MICROSOFT.md`;
repito aqui porque na hora do aperto ("o segredo do login já está no `.env`, é só reusar") a tentação é
real.

### 5. Não ligar motivo novo sem passar pelo ensaio

`EMAIL_MOTIVOS_ATIVOS` é uma linha de `.env`, e é exatamente por isso que dá para errar rápido. Um
motivo ligado sem `EMAIL_DRY_RUN=1` antes pode significar dezenas de e-mails de uma vez para um líder
que nunca recebeu nada do sistema. Seção 7.4 tem a ordem: conferir responsável de grupo, contar o que
sairia, ensaiar, ligar.

### 6. Não gravar o `access_token` em log, banco ou `core.rotina_execucao`

O `detalhe` da rotina é texto livre e é lido por qualquer um com `biotrop_ro`. O worker registra
contagens e mensagem de erro; o `error_description` do Entra pode ser gravado (não contém segredo),
mas o token e o `client_secret`, nunca. Se precisar depurar token, use `jwt.ms` no seu terminal e não
copie para lugar nenhum.

### 7. Não reenviar sem olhar os Itens Enviados

Vale para linha em `'enviando'` órfã e para qualquer `UPDATE ... SET status = 'pendente'` feito à mão.
`202` do Graph significa entregue; a fila só sabe o que conseguiu gravar depois.

### 8. Não transformar a fila em fila de tudo

`core.email_fila` é caixa de saída de e-mail. Não é fila de job, não é agendador, não é notificação
push. No dia em que aparecer "avisar no Teams", a resposta é uma tabela nova (ou uma coluna `canal`
com um `CHECK`) numa migration, decidido de propósito — não um `motivo` que o worker não sabe entregar
e que fica pendente para sempre.

### 9. Não apagar linha da fila

Nenhum `GRANT DELETE` foi dado à role do worker, de propósito. A fila é o registro de que o aviso saiu,
quando e para quem — é o que responde "eu nunca fui avisado". Limpeza, se um dia precisar, é uma
rotina datada (`DELETE ... WHERE status = 'enviado' AND enviado_em < now() - interval '2 years'`) e
uma decisão consciente, não faxina.

---

## 12. Aceite: os testes que fecham a entrega

### 12.1 Antes de tocar no código

```bash
# 1. token sai e tem a permissao
curl -s -X POST "https://login.microsoftonline.com/$GRAPH_TENANT_ID/oauth2/v2.0/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "client_id=$GRAPH_CLIENT_ID" \
  --data-urlencode "client_secret=$GRAPH_CLIENT_SECRET" \
  --data-urlencode "scope=https://graph.microsoft.com/.default" \
  --data-urlencode "grant_type=client_credentials" \
  | jq -r .access_token | cut -d. -f2 | base64 -d 2>/dev/null | jq '{aud, roles, app_displayname}'
```

Esperado: `"aud": "https://graph.microsoft.com"` e `"roles": ["Mail.Send"]`. Sem `roles`, falta admin
consent — pare aqui.

```powershell
# 2. a policy restringe de verdade
Test-ApplicationAccessPolicy -Identity manutencao@biotrop.com.br -AppId $appId   # Granted
Test-ApplicationAccessPolicy -Identity felipe.vieira@biotrop.com.br -AppId $appId # Denied
```

```bash
# 3. sendMail de teste chega (secao 5.1) e a copia aparece nos Itens Enviados da caixa
```

### 12.2 O caminho completo, no banco

Com o app rodando e logado como almoxarife, devolva uma SCI de teste para revisão pela tela. Depois:

```sql
-- a linha entrou na fila, com o motivo certo e o destinatario certo
SELECT motivo, destinatario, assunto, status, criado_em
  FROM core.email_fila
 ORDER BY criado_em DESC LIMIT 1;
-- motivo: sci_revisao_solicitante | status: pendente

-- e o historico registrou a transicao com autor (prova que o SET LOCAL funcionou)
SELECT de, para, por_nome, nota, em
  FROM almox.sci_historico
 WHERE sci_id = '...'::uuid ORDER BY em DESC LIMIT 1;
```

```bash
sudo systemctl start biotrop-email.service
journalctl -u biotrop-email.service -n 20 --no-pager
```

```sql
-- enviado, com carimbo e ids de rastreio
SELECT status, tentativas, enviado_em, graph_message_id, erro
  FROM core.email_fila ORDER BY criado_em DESC LIMIT 1;
-- status: enviado | tentativas: 1 | erro: NULL | graph_message_id: crid:... rid:...
```

O e-mail chega na caixa do solicitante de teste, com a devolutiva em destaque e o botão abrindo a
solicitação depois do login do Entra.

### 12.3 Os testes que provam as decisões, não o caminho feliz

| Teste | Como | Esperado |
|---|---|---|
| Motivo desligado não sai | criar uma SCM com `aprovador_email` preenchido, rodar o worker | linha vira `cancelado` com `erro = 'motivo nao habilitado: scm_pendente_aprovacao'`, e nenhum e-mail chega ao líder |
| Duas rodadas não duplicam | `systemctl start biotrop-email.service` duas vezes seguidas | a segunda loga `outra rodada em andamento - saindo`, ou não acha nada para enviar |
| Destinatário inválido não fica em loop | inserir e-mail de teste com destinatário `nao-existe@biotrop.com.br` na fila (via SQL, como admin) | `400 ErrorInvalidRecipients` → `status = 'erro'` na **primeira** tentativa, `tentativas = 1` |
| Segredo errado não perde e-mail | trocar `GRAPH_CLIENT_SECRET` por lixo, rodar, devolver o certo, rodar | primeira rodada: `pendente` com `tentativas = 1`; segunda: `enviado`. Nada perdido |
| Graph fora não trava a tela | com segredo errado, devolver uma SCI para revisão pela tela | a devolutiva grava normal; só o e-mail espera |
| Escape do texto | devolver uma SCI com observação `medida < 1/2" & vazamento` | o e-mail mostra o texto **literal**, sem cortar em `<` |
| Fila não aceita `INSERT` do worker | `psql` com `biotrop_mailer_login` e `INSERT INTO core.email_fila ...` | `ERROR: permission denied for table email_fila` |
| Ensaio não altera nada | rodar com `EMAIL_DRY_RUN=1` com fila cheia | imprime tudo; `status` de todas as linhas continua `pendente` |

O quarto e o quinto são os que interessam de verdade: eles são o motivo de existir uma fila em vez de
um `fetch` dentro do gatilho.

### 12.4 O que fica pendente para depois da fase 1

- **RLS (`0002`).** Hoje a role do worker vê a fila inteira. Com uma instância e uma pessoa mantendo,
  isso é aceitável; com RLS, a fila passa a ser filtrável por origem.
- **`core.html_escape`** e as duas funções de gatilho reescritas (seção 9.5).
- **Bounce / não-entrega.** `202` não é entrega. Hoje a evidência de problema é o técnico dizendo que
  não recebeu. Ler `Mail.Read` da caixa para capturar NDR exigiria outra permissão de aplicação — e
  seria uma decisão nova, não um detalhe de implementação.
- **Coluna de claim.** Se um dia houver dois workers, `'enviando'` precisa de `reivindicado_em` para
  distinguir órfão de em andamento. Com um worker e advisory lock, não precisa.
- **Avisos da fase 2** (SCM decidida, acompanhamento de SCI): já cabem no desenho — gatilho grava com
  `motivo` novo, template em Node, motivo entra na allowlist. Nenhuma mudança estrutural.
