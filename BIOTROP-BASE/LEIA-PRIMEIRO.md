# Base de dados e infraestrutura — BIOTROP Manutenção

Esta pasta é o que falta para sair do HTML local e publicar na VM Azure com
login corporativo. Nada aqui foi executado contra um banco real — foi escrito
contra o schema conferido linha por linha e revisado adversarialmente. **O
primeiro `psql` é o teste que falta.**

## Ordem de aplicação

Aplique nesta ordem, sempre com `-v ON_ERROR_STOP=1`. Cada arquivo é
idempotente: rodar duas vezes não quebra.

```bash
export DATABASE_URL="postgres://usuario:senha@localhost:5432/biotrop"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 01-base.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 02a-papeis.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 02b-rls-core.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 02c-rls-almox.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 02d-rls-util.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 02e-rls-lms.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 02f-ajustes-base.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 02g-fechamento.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f servidor-email/enfileirar.sql
```

A ordem não é estética: `02a` cria as *roles* que as policies de `02b` em
diante referenciam em `TO biotrop_app`, e `CREATE POLICY` exige que a role
já exista.

| Arquivo | O que faz |
|---|---|
| `01-base.sql` | 7 schemas, 49 tabelas, 36 funções, 23 triggers, 23 views, seeds. É a migration 0001 |
| `02a-papeis.sql` | roles `biotrop_app`, `biotrop_ro`, `biotrop_worker`, GRANTs (inclusive **por coluna**) e funções de sessão |
| `02b..02e` | Row Level Security, um arquivo por schema — 137 policies |
| `02f-ajustes-base.sql` | `security_invoker` nas 22 views de `app` e funções recriadas com conferência de dono |
| `02g-fechamento.sql` | itens da SCM herdam a policy da mãe, `login_evento` com FORCE, RLS em `pcm` e `mig`, e conferência que **para o deploy** |
| `servidor-email/enfileirar.sql` | gatilhos que enfileiram e-mail + `core.parametro` |

## Documentos

| Arquivo | Para quem |
|---|---|
| `LOGIN-MICROSOFT.md` | você e o Gustavo — registro no Entra ID, PKCE, validação do token, allowlist |
| `EMAIL-MICROSOFT-GRAPH.md` | você e o Gustavo — permissão de aplicativo, conta remetente, fila |
| `DEPLOY-VM-AZURE-E-BACKUP.md` | chamado para a TI, nginx, systemd, `deploy.sh`, `pg_dump`, rollback |
| `TELAS-POR-PERFIL.md` | a matriz de permissões e o roteiro de teste perfil por perfil que o Plinio pediu |
| `servidor-email/README.md` | instalar e operar o worker que envia |

## O caminho da autenticação, em três passos

A ordem importa e é fácil errar:

1. **Validar o token** do Entra ID no servidor (assinatura via JWKS, `iss`,
   `aud`, `nonce`, `exp`). Nunca confiar no e-mail que o cliente manda.
2. **`core.provisionar_acesso(email)`** — confere `core.email_autorizado`,
   cria o usuário com o `perfil_padrao` no primeiro acesso e registra em
   `core.login_evento`. Devolve o `id`, ou erro se o e-mail não está liberado
   ou o usuário está bloqueado.
3. **`SET LOCAL app.usuario_id = '<id>'`** em cada transação. É disso que todo
   o RLS depende: sem esse `SET`, as funções de escopo lançam erro em vez de
   liberar tudo.

Ter conta Biotrop não basta: o e-mail precisa estar em `core.email_autorizado`.
Era o pedido do Gustavo.

## Duas coisas de segurança para não deixar passar

**`Mail.Send` de aplicativo envia como qualquer caixa do tenant.** Pedir para a
TI aplicar a *Application Access Policy* limitando o aplicativo à caixa de
comunicação. O comando está em `servidor-email/README.md`. Sem ela, vazar o
`client secret` é vazar a capacidade de mandar e-mail como qualquer pessoa da
empresa.

**RLS filtra LINHA, nunca COLUNA.** Foi assim que o revisor achou o furo do
aluno se dando tentativas infinitas: a policy escolhia a linha certa (a
matrícula dele) e o `GRANT UPDATE` de tabela inteira deixava ele escrever
qualquer coluna, inclusive `tentativas_liberadas`. A correção é `GRANT UPDATE
(colunas)`, e `02a` tem um bloco `DO` que **para o deploy** se alguém devolver
`UPDATE` de tabela — porque privilégio de tabela sempre vence privilégio de
coluna.

## O que foi revisado, e o que isso significa

O schema foi escrito por um agente, julgado por três com lentes diferentes
(correção relacional, regras de negócio, operação real), e depois atacado por
revisores adversariais instruídos a **refutar** que funciona. Acharam 12 furos
reais — entre eles views devolvendo nota e diretório de todo mundo, dois
técnicos aprovando a SCM um do outro, aluno se dando tentativas infinitas e a
rotina de e-mail travada. Todos corrigidos.

Depois disso, conferi a cobertura de RLS tabela por tabela e achei **dois furos
que a revisão não tinha pego** — os dois no `02g`:

- **Tabela filha sem RLS anula a policy da mãe.** `almox.scm` tinha RLS, mas
  `scm_item`, `scm_anexo` e `scm_link` não. Um `SELECT * FROM almox.scm_item`
  devolvia código, descrição, quantidade e marca de **todas** as compras da
  empresa, porque a policy que protege a linha está na mãe e o `SELECT` nem
  passa por ela.
- **`core.login_evento` sem RLS.** O comentário do `02b` promete que o `FORCE`
  entra ali; nenhum `FORCE` foi aplicado e a tabela não tinha nem RLS simples.
  Qualquer usuário lia quando cada pessoa entrou, de qual IP e com qual
  navegador.

**O que NÃO foi feito:** a reverificação final (tentar furar de novo depois das
correções, e checar se a correção travou algum fluxo) foi lançada três vezes e
os agentes travaram nas três. Não há segunda passada adversarial sobre o estado
atual.

Isso aumenta a confiança, mas não substitui execução. **Antes de publicar:**

```bash
# 1. banco descartável, para provar que a ordem aplica limpa
createdb biotrop_teste
# rodar os 9 psql acima contra biotrop_teste
```

O passo 1 já é a maior parte da verificação: o `02a` e o `02g` têm blocos `DO`
que **abortam** se o `GRANT` por coluna tiver voltado a ser por tabela, se
alguma view de `app` estiver sem `security_invoker`, ou se aparecer tabela sem
RLS fora da lista de catálogo.

```bash
# 2. tabelas sem RLS — devem sobrar apenas as 12 de catálogo/infraestrutura
psql biotrop_teste -c "
  SELECT n.nspname||'.'||c.relname AS tabela
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relkind = 'r' AND n.nspname IN ('core','almox','util','lms','pcm','mig')
     AND NOT c.relrowsecurity
   ORDER BY 1;"
```

Esperado exatamente estas 12, e nenhuma outra — são catálogo e infraestrutura,
que todo usuário autenticado lê e cuja escrita é barrada por `GRANT`:

```
almox.centro_custo   almox.familia    almox.familia_campo
core.migration       core.perfil      core.permissao       core.rotina_execucao
core.sequencia       lms.aula         lms.avaliacao        lms.questao
lms.treinamento
```

`lms.questao_opcao` (o gabarito) também aparece sem RLS: é decisão consciente
— ele é protegido por privilégio de **coluna** no `02a`, e ligar RLS ali sem
cuidado quebraria a função de correção, que roda como dona. O `02g` imprime um
`NOTICE` explicando isso no deploy.

```bash
# 3. o furo 13 está fechado?
psql biotrop_teste -c "
  SET LOCAL app.usuario_id = '<uuid de um técnico>';
  SELECT (SELECT count(*) FROM almox.scm) AS compras_visiveis,
         (SELECT count(*) FROM almox.scm_item) AS itens_visiveis;"
# os dois números têm de ser coerentes: itens só das compras que ele vê

# 4. o roteiro de teste por perfil de TELAS-POR-PERFIL.md
```

## Situação

| Item | Estado |
|---|---|
| Schema, regras, seeds, migração do localStorage | escrito e revisado |
| RLS (149 policies) | escrito; 12 furos da revisão + 2 achados na conferência de cobertura, todos corrigidos |
| Reverificação adversarial do estado final | **não feita** — os agentes travaram nas três tentativas |
| Login Microsoft | documentado, com código de exemplo — **falta o registro no Entra** |
| E-mail por Graph | worker e gatilhos escritos — **falta a permissão de aplicativo** |
| Deploy na VM | runbook escrito — **falta o chamado para a TI** |
| Execução contra Postgres real | **não feita** — é o passo 1 acima |
