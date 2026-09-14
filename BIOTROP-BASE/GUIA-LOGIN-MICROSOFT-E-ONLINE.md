# Biotrop Manutenção — Login Microsoft + publicação multiusuário

## 1. O que ficou no projeto

O login por e-mail/senha continua existindo.

Foi adicionada uma segunda opção: **Entrar com Microsoft**.

O fluxo é:

```text
Navegador
   ↓
Vercel /api/auth/microsoft/start
   ↓
Microsoft Entra ID
   ↓
Vercel /api/auth/microsoft/callback
   ↓
PostgreSQL
   ↓
core.email_autorizado
   ↓
core.usuario
   ↓
sessão da aplicação
```

O navegador não recebe `DATABASE_URL` nem `ENTRA_CLIENT_SECRET`.

## 2. Criar o App Registration no Microsoft Entra

No Microsoft Entra admin center:

**Identity → Applications → App registrations → New registration**

Use:

- Name: `Biotrop Manutencao - Web`
- Supported account types: `Accounts in this organizational directory only`
- Platform: `Web`
- Redirect URI de produção:
  `https://v3-base.vercel.app/api/auth/microsoft/callback`

Para desenvolvimento local, adicione também:

`http://localhost:3000/api/auth/microsoft/callback`

Crie um **Client Secret** e guarde o valor somente no Vercel.

Permissões mínimas:

- `openid`
- `profile`
- `email`

A documentação Microsoft recomenda o fluxo Authorization Code para aplicações Web; para clientes confidenciais o segredo fica no servidor e o redirect URI precisa coincidir com o cadastrado. Veja também a documentação de validação OIDC/JWKS da Microsoft.

## 3. Variáveis do Vercel

Em **Project → Settings → Environment Variables**, adicionar para Production:

```env
DATABASE_URL=postgresql://...
DATABASE_SSL=true
SESSION_SECRET=uma-chave-aleatoria-com-mais-de-32-caracteres
LOGIN_LOCAL_ATIVO=true
ENTRA_TENANT_ID=...
ENTRA_CLIENT_ID=...
ENTRA_CLIENT_SECRET=...
APP_BASE_URL=https://v3-base.vercel.app
```

Depois de salvar as variáveis, faça um novo deploy. Variáveis de ambiente alteradas passam a valer em novos deployments.

## 4. Liberar pessoas no PostgreSQL

O Microsoft Entra autentica a identidade. O PostgreSQL decide se a pessoa pode usar o sistema.

Cada e-mail precisa existir em `core.email_autorizado` e estar ativo.

Exemplo:

```sql
INSERT INTO core.email_autorizado (email, ativo, perfil_padrao, motivo)
VALUES ('nome@biotrop.com.br', true, 'tecnico', 'Liberado pela TI');
```

O `perfil_padrao` deve existir em `core.perfil`.

No primeiro login Microsoft, se o usuário ainda não existir em `core.usuario`, o sistema cria a conta usando o perfil/grupo padrão da autorização.

## 5. Login local continua funcionando

Enquanto:

```env
LOGIN_LOCAL_ATIVO=true
```

A opção antiga de e-mail + senha continua funcionando.

Depois de validar o Microsoft para os usuários corporativos, pode-se mudar para:

```env
LOGIN_LOCAL_ATIVO=false
```

Isso fecha a senha local para produção corporativa.

## 6. O que ainda falta para todos trabalharem ao mesmo tempo

O login Microsoft não torna, sozinho, o sistema multiusuário.

Ainda é necessário:

1. **PostgreSQL real acessível pela aplicação** — não apenas os arquivos SQL no GitHub.
2. **Migrar as gravações do HTML/localStorage para API + PostgreSQL** em cada módulo.
3. **Migrar as leituras dos módulos para PostgreSQL**, para que um usuário veja o que outro gravou.
4. **Controle de concorrência** (`updated_at`, versão ou bloqueio) para impedir que uma edição sobrescreva silenciosamente a de outra pessoa.
5. **Atualização em tempo real** para telas que precisam refletir mudanças imediatamente. Pode ser polling curto ou WebSocket/recurso equivalente; não precisa ser Supabase.
6. **Upload centralizado** de fotos/anexos para não ficar preso ao `localStorage` do navegador.
7. **Backups do PostgreSQL** e rotina de restauração testada.
8. **Domínio corporativo + HTTPS** e registro de redirect URI de produção no Entra.

A base PostgreSQL do projeto já foi desenhada com RBAC, auditoria, `core.email_autorizado`, `core.usuario`, eventos de login e RLS. O que falta é fazer o front-end usar essa base como fonte de verdade em todos os fluxos.
