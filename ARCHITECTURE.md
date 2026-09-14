# V3-Base · Arquitetura

## Regra principal

> O navegador mostra os dados. A API controla os dados. O PostgreSQL guarda os dados.

## Produção online

```text
GitHub
  ↓
Vercel
  ├── Frontend Biotrop
  └── API Node.js
        ↓
   Neon PostgreSQL
        ↓
 PC · Notebook · Celular · Tablet
```

O PostgreSQL/Neon é a fonte oficial. `localStorage` pode existir somente como cache de interface e camada de transição; não é a autoridade dos dados.

## Multiusuário

```text
Usuário → Autenticação → Perfil → Permissões → API → PostgreSQL
```

As regras de autorização são verificadas no backend. Alterar JavaScript no navegador não concede permissão administrativa.

## Realtime

As escritas passam pela API. O endpoint `/api/realtime` entrega eventos SSE para as telas conectadas. Em ambientes serverless, a conexão é curta e se reconecta automaticamente; o fallback é polling periódico. Para a futura rede interna com processo Node persistente, a mesma camada pode evoluir para WebSocket/`LISTEN/NOTIFY` sem mudar o modelo de dados.

## Neon Preview

Cada Pull Request cria uma branch Neon `preview/pr-<numero>-<branch>`, aplica o schema/migrations e executa um health check. Ao fechar o PR, a branch é removida. A branch `production` permanece reservada para os dados oficiais.

## Banco

As migrations atuais são executadas nesta ordem:

1. `BIOTROP-BASE/01-base.sql`
2. `BIOTROP-BASE/02a-papeis.sql`
3. `BIOTROP-BASE/02b-rls-core.sql`
4. `BIOTROP-BASE/02c-rls-almox.sql`
5. `BIOTROP-BASE/02d-rls-util.sql`
6. `BIOTROP-BASE/02e-rls-lms.sql`
7. `BIOTROP-BASE/02f-ajustes-base.sql`
8. `BIOTROP-BASE/02g-fechamento.sql`
9. `BIOTROP-BASE/03-sync.sql`

Comandos:

```bash
npm install
npm run db:migrate
npm run db:check
```

O runner usa `psql`, portanto o PostgreSQL client precisa estar instalado no ambiente.

## Futura rede interna

```text
GitHub
  ↓
checkout/clone
  ↓
Servidor interno Biotrop
  ├── Frontend
  └── Backend Node.js
        ↓
   PostgreSQL/Neon
```

A aplicação usa `DATABASE_URL`, `SESSION_SECRET` e demais configurações por variáveis de ambiente. Não existem credenciais reais no código do repositório.

O backend permanece desacoplado do Vercel para que o mesmo projeto possa ser instalado no servidor interno. Se a política futura exigir banco totalmente interno, a aplicação continua usando PostgreSQL e a migração fica concentrada na conexão e no ambiente, não no frontend.
