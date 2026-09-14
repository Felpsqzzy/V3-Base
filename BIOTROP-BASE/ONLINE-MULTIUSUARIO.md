# Biotrop V3-Base — Online e multiusuário

## Objetivo

Deixar a plataforma disponível para vários funcionários ao mesmo tempo, com uma base PostgreSQL central e sincronização automática dos módulos compartilhados.

A arquitetura é:

```text
Navegador
   ↓
Vercel / API Node
   ↓
PostgreSQL central
   ↓
Dados compartilhados
```

Não há Supabase nesta arquitetura.

## O que já está implementado no código

- autenticação local por PostgreSQL;
- Microsoft Entra ID como segunda opção de login;
- sessão HTTP assinada;
- API `/api/data` para dados compartilhados;
- tabela `app.sync_registro` com `version` para concorrência;
- detecção de conflito com HTTP 409;
- sincronização de SCI, SCM e Utilidades;
- polling automático de 3 segundos para refletir alterações de outros usuários;
- `/api/health` para verificar se o PostgreSQL está conectado;
- localStorage mantido apenas como cache/fallback temporário.

## O que precisa ser executado no PostgreSQL

Depois das migrações existentes, execute:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 03-sync.sql
```

A ordem completa é:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 01-base.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 02a-papeis.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 02b-rls-core.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 02c-rls-almox.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 02d-rls-util.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 02e-rls-lms.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 02f-ajustes-base.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 02g-fechamento.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f 03-sync.sql
```

## Variáveis do Vercel

Configure no ambiente de produção:

```env
DATABASE_URL=postgresql://usuario:senha@host:5432/biotrop
DATABASE_SSL=true
SESSION_SECRET=chave-aleatoria-com-no-minimo-32-caracteres
LOGIN_LOCAL_ATIVO=true
APP_BASE_URL=https://v3-base.vercel.app
```

Para Microsoft Entra, também configure as variáveis documentadas em `LOGIN-MICROSOFT.md`.

## Teste da conexão

Abra:

`https://v3-base.vercel.app/api/health`

O resultado esperado quando o banco estiver realmente conectado é:

```json
{
  "ok": true,
  "databaseConfigured": true,
  "databaseConnected": true,
  "realtimeMode": "polling-3s"
}
```

## Comportamento dos usuários

- Cada funcionário possui a sua própria sessão.
- O banco é a fonte central dos registros sincronizados.
- Alterações feitas por um usuário são enviadas à API e gravadas no PostgreSQL.
- Os outros navegadores consultam alterações novas a cada 3 segundos.
- Se duas pessoas alterarem o mesmo registro, a API usa `version` para detectar o conflito.
- O modo de recuperação local continua disponível enquanto o PostgreSQL não estiver configurado, mas esse modo não é multiusuário.

## Limite atual

A sincronização pronta cobre `sci`, `scm`, `utility_meters` e `utility_readings`. Usuários, perfis e permissões continuam sob o controle do banco de autenticação. Novos módulos podem ser migrados para namespaces adicionais sem voltar a usar Supabase.
