# Envio de e-mail — Microsoft Graph

Quem envia é este worker, na VM, consumindo `core.email_fila`. A aplicação
nunca chama o Graph direto: ela enfileira e segue. Se o Graph estiver fora,
o aviso espera; a ação do usuário não.

## O que pedir para a TI (Gustavo)

Um registro de aplicativo no Entra ID, com:

| Item | Valor |
|---|---|
| Nome | `BIOTROP - Plataforma de Manutenção` |
| Permissão | **`Mail.Send`** — tipo **Aplicativo**, não Delegada |
| Consentimento | do administrador, **concedido** |
| Credencial | um *client secret* (anotar validade; o padrão do Entra expira) |
| Caixa remetente | `manutencao@biotrop.com.br` (criar se não existir) |

E um pedido que costuma passar batido, mas é o mais importante:

> **Application Access Policy** limitando este aplicativo à caixa
> `manutencao@biotrop.com.br`.

Sem essa política, `Mail.Send` de aplicativo permite enviar **como qualquer
caixa do tenant**. Um vazamento do secret viraria capacidade de mandar e-mail
como qualquer pessoa da empresa. Com a política, o secret vale para uma caixa
só.

Comando que a TI roda (Exchange Online PowerShell):

```powershell
New-ApplicationAccessPolicy `
  -AppId <ENTRA_CLIENT_ID> `
  -PolicyScopeGroupId manutencao@biotrop.com.br `
  -AccessRight RestrictAccess `
  -Description "BIOTROP Manutencao - envia so pela caixa de comunicacao"
```

Devolver para você: `ENTRA_TENANT_ID`, `ENTRA_CLIENT_ID`, `ENTRA_CLIENT_SECRET`.

## Instalar na VM

```bash
sudo mkdir -p /opt/biotrop/servidor-email
sudo chown biotrop: /opt/biotrop/servidor-email
cd /opt/biotrop/servidor-email
# copiar os arquivos desta pasta
npm install --omit=dev
cp .env.example .env
chmod 600 .env          # o secret está aqui dentro
nano .env
```

Aplicar os gatilhos no banco, depois de `01-base.sql` e do RLS:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f enfileirar.sql
```

## Testar antes de ligar

Nesta ordem — ela separa problema de permissão de problema de SQL:

```bash
set -a; . ./.env; set +a

node teste.js token                              # 1. tenant, client e secret
node teste.js envio felipe.vieira@biotrop.com.br # 2. permissão e caixa
node worker.js --uma-vez                         # 3. a fila de verdade
```

Se o passo 1 falhar, é credencial. Se o 2 falhar com **403**, é a Application
Access Policy ou o consentimento de administrador — não é o seu código. Se o 3
não achar nada, é porque a fila está vazia: devolva uma SCI para revisão do
solicitante e rode de novo.

## Ligar como serviço

```bash
sudo cp biotrop-email.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now biotrop-email
sudo journalctl -u biotrop-email -f
```

Alternativa por cron, se preferir não ter processo residente:

```cron
*/5 * * * * cd /opt/biotrop/servidor-email && set -a && . ./.env && set +a && /usr/bin/node worker.js --uma-vez >> /var/log/biotrop-email.log 2>&1
```

O serviço é melhor: reinicia sozinho e o intervalo é configurável sem editar
crontab. O cron é aceitável se a VM já tem uma rotina e você quer um lugar só.

## Quais avisos existem, e por quê só um está ligado

Fica em dado, não em código (`core.parametro`) — ligar um aviso é `UPDATE`,
não deploy.

| Gatilho | Estado | Avisa | Por quê |
|---|---|---|---|
| `sci_revisao_solicitante` | **ligado** | o solicitante | É o único caso em que a pendência é da pessoa e ela não descobre sozinha |
| `scm_aprovacao_lider` | desligado | responsável do grupo | Decisão da reunião: quem aprova acompanha a fila no sistema |
| `treinamento_concluido` | desligado | colaborador + responsável | Pedido na reunião, mas falta decidir se o comprovante vai anexado |

Ligar:

```sql
UPDATE core.parametro SET valor = 'true', alterado_em = now()
 WHERE chave = 'email.gatilho.scm_aprovacao_lider';
```

Nada mais precisa ser reiniciado: o gatilho lê o parâmetro a cada disparo.

## Operar

```sql
-- a rotina rodou?
SELECT executado_em, sucesso, detalhe FROM core.rotina_execucao
 WHERE rotina = 'email_worker' ORDER BY executado_em DESC LIMIT 5;

-- algo preso?
SELECT status, count(*) FROM core.email_fila GROUP BY status;

-- o que falhou, e por quê
SELECT referencia AS codigo, destinatario, tentativas, erro
  FROM core.email_fila WHERE status = 'erro' ORDER BY criado_em DESC;

-- reenviar o que deu erro depois de corrigir a causa
UPDATE core.email_fila
   SET status = 'pendente', tentativas = 0, erro = NULL, proxima_tentativa_em = NULL
 WHERE status = 'erro';
```

## Decisões que valem saber

**Fila, não envio direto.** Devolver uma SCI para revisão não pode levar três
segundos porque o Graph está lento, e o aviso não pode se perder se ele estiver
fora. A fila resolve os dois, e ainda deixa registro de tentativa e erro.

**`FOR UPDATE SKIP LOCKED` no `SELECT`.** Sem isso, duas instâncias do worker —
ou um restart no meio de um lote — mandam o mesmo e-mail duas vezes. Com
`SKIP LOCKED`, cada instância pega linhas diferentes.

**Repetir só o que vale repetir.** `429` e `5xx` são instabilidade: espera
exponencial de 1, 2, 4, 8, 16 minutos. `4xx` é mensagem ou permissão errada —
repetir não conserta e só gera ruído no log. Depois de 5 tentativas, vira
`erro` e para.

**Destinatário vazio não aborta a ação.** A SCI tem de ser devolvida mesmo que
o cadastro esteja sem e-mail. Mas o caso entra na fila como
`sem_destinatario`, com o motivo — porque "não chegou e-mail" sem rastro é o
pior defeito para investigar depois. Na tela de administração isso aparece como
indicador próprio.

**`saveToSentItems: true`.** A primeira pergunta quando alguém diz "não recebi"
é se saiu. Sem cópia em Itens Enviados, não há como responder.

## Enquanto não há servidor

A versão local (`BIOTROP-Manutencao-LOCAL.html`) tem a mesma fila, em
**Administração › Caixa de saída**, com os mesmos gatilhos. Lá nada sai
sozinho — não há servidor. A mensagem fica pronta e você despacha por
"Abrir no e-mail" (monta `mailto:`) ou baixando o **`.eml`**, que abre no
Outlook como rascunho preenchido. É a ponte até este worker entrar no ar.
