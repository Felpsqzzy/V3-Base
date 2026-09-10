# Telas por perfil — Biotrop Manutenção

Especificação de menu, tela, ação permitida e **o que barra no banco**. Base de dados:
`migrations/0001_base.sql` (arquivo `01-base.sql` desta pasta, 3.554 linhas). Todo schema, tabela,
coluna, enum, função e view citado aqui existe lá — o que não existe está marcado como
**`0002`** e vem com o SQL completo na seção 10.

**O que a base já entrega:**

| Objeto | Papel na autorização |
|---|---|
| `core.permissao` | catálogo de 8 permissões (`area.permissao`) |
| `core.perfil` (7 linhas) | `admin`, `gestor`, `pcm`, `almoxarife`, `lider`, `tecnico`, `viewer`; `admin` é `fixo` e protegido por `tg_perfil_fixo` |
| `core.perfil_permissao` | 30 vínculos já semeados |
| `app.vw_perfil_permissoes` | permissões em `jsonb` no formato que a tela consome |
| `app.vw_usuario` | perfil + permissões + grupo + **responsável direto** resolvidos |
| `app.vw_aprovador_de` | quem aprova a SCM de cada pessoa (grupo → exceção → ninguém) |
| GUC `app.usuario_id` / `app.usuario_email` | já lidos por `core.fn_auditar()`, `almox.fn_sci_transicao()`, `almox.fn_scm_transicao()` |
| `GRANT SELECT (id, questao_id, posicao, texto) ON lms.questao_opcao` | gabarito fora do alcance da aplicação |

**O que a base NÃO tem, e por isso está nesta especificação** (os quatro itens abaixo foram
escritos olhando só a `0001`; leia junto com a **seção 3.1**, que diz quais deles os arquivos
`02a`–`02e` já resolveram e quais continuam abertos na seção 14):

1. **Zero `CREATE POLICY`.** — *resolvido:* `02b`–`02e` criam a RLS de `core`, `almox`, `util` e `lms`. Hoje `biotrop_app` lê e escreve qualquer linha de `core`, `almox`,
   `util` e `pcm`. Menu escondido é decoração: com a connection string da VM, um `SELECT * FROM almox.scm`
   devolve tudo. A seção 10 traz a RLS completa.
2. **As views de `app` são do dono do banco e não usam `security_invoker`** — *resolvido só em
   utilidades* (`02d` virou 4 views); as de SCI, SCM e LMS continuam abertas: item 2 da seção 14. Então hoje elas
   *ignoram* qualquer RLS que venha depois. Sem virar `security_invoker = true` nas views que a
   interface usa, a `0002` não protegeria nada no caminho real da tela (seção 10.4).
3. **`lms.corrigir_tentativa(uuid, jsonb)` e `lms.registrar_progresso(...)` aceitam qualquer
   `matricula_id`.** Nada dentro delas confere se a matrícula é de quem está chamando: hoje o
   técnico que trocar o uuid no corpo do POST responde a avaliação de outra pessoa e gera o
   comprovante dela (`lms.conclusao`). — *`registrar_progresso` resolvido* (não é `SECURITY
   DEFINER`, então roda sob `progresso_ins`, que amarra ao dono da matrícula); **`corrigir_tentativa`
   continua aberta**: item 1 da seção 14, com o SQL da correção.
4. **8 permissões não cobrem as telas que existem.** Não há chave para treinamentos, para gestão
   de acesso, para gestão de medidores nem para tratativa de desvio. `pcm` e `viewer` nasceram
   com quase nada (`0001` fez isso de propósito, para não chutar acesso). A `0002` acrescenta 9
   chaves e completa os dois perfis — **continua aberto**: item 3 da seção 14, com o `INSERT` pronto.

---

## 1. As três camadas, e qual delas vale

| Camada | Onde | O que resolve | O que NÃO resolve |
|---|---|---|---|
| Menu | front-end, lendo `app.vw_usuario.permissoes` | a pessoa não vê o que não usa | nada de segurança: `curl` na rota ignora o menu |
| Rota | middleware `exigePermissao()` (ver `LOGIN-MICROSOFT.md`, seção 8) | bloqueia a rota inteira por permissão | não sabe *qual linha* a pessoa pode ver ou mudar |
| **Banco** | `GRANT`, `CHECK`, trigger e **RLS** | linha por linha, coluna por coluna, transição por transição | nada — é a última palavra |

A regra deste documento: **toda linha de "NÃO PODE" tem um objeto de banco correspondente.**
Onde não tem, está escrito que não tem, e está em Pendências (seção 14).

Contrato de sessão, obrigatório em toda transação (já é o padrão dos triggers da `0001`):

```sql
BEGIN;
  SELECT set_config('app.usuario_id',    $1, true),
         set_config('app.usuario_email', $2, true);
  -- ... consultas da requisição ...
COMMIT;
```

Sem esse `set_config`, `core.sessao_usuario()` volta `NULL` e **toda policy nega**. É falha
fechada de propósito: rota que esquece o `SET LOCAL` devolve lista vazia e erro de permissão no
`INSERT`, não devolve o banco inteiro.

---

## 2. Os 7 perfis

| Perfil (`core.perfil.id`) | Nome na tela | Quem é | Fixo |
|---|---|---|---|
| `admin` | Administrador | quem mantém a plataforma; único que gere acesso e libera tentativa de avaliação | sim (`tg_perfil_fixo`) |
| `gestor` | Gestor | coordenação da manutenção: mesma amplitude operacional do admin, sem gerir acesso | não |
| `pcm` | PCM | planejamento: lista mestre de apontamentos, desvios, medidores, OS (etapa posterior) | não |
| `almoxarife` | Almoxarife | tratativa de SCI e SCM, famílias de item | não |
| `lider` | Responsável de grupo | aprova a SCM da equipe e acompanha treinamento do grupo | não |
| `tecnico` | Técnico | abre solicitação, aponta consumo, faz treinamento | não |
| `viewer` | Visualização | lê listas, não escreve nada | não |

### 2.1 A distinção que mais importa: perfil `lider` ≠ responsável de grupo

São duas coisas diferentes e o sistema usa as duas:

| | O que é | Onde vive | O que dá |
|---|---|---|---|
| Perfil `lider` | permissão | `core.usuario.perfil_id` | **direito** de aprovar SCM (`almoxarifado.scm_aprovacao`) e de abrir a visão de treinamentos do grupo |
| Responsável de grupo | fato do cadastro | `core.grupo.responsavel_id` | **escopo**: de quem ele aprova e quem ele enxerga |

Consequências práticas, todas verificáveis no banco:

- Quem tem perfil `lider` e **não** é `responsavel_id` de grupo nenhum abre "Aprovações SCM" e vê
  fila vazia — `almox.scm.aprovador_email` nunca vai ser o e-mail dele.
- Quem tem perfil `gestor` e **é** `responsavel_id` de um grupo **recebe** as SCM daquele grupo,
  porque `app.vw_aprovador_de` resolve pelo grupo, não pelo perfil.
- Grupo sem responsável gera SCM com `aprovador_origem = 'nenhum'` e `aprovador_email IS NULL`:
  ninguém aprova. `app.vw_saude_operacional.grupos_sem_responsavel` conta isso, e é item de
  checagem do dia da virada.

```sql
-- quem aprova quem, hoje
SELECT usuario_nome, grupo_nome, aprovador_nome, origem
  FROM app.vw_aprovador_de ORDER BY origem, grupo_nome;

-- os 11 grupos e o responsável direto de cada um
SELECT g.nome AS grupo, u.nome AS responsavel, u.email
  FROM core.grupo g LEFT JOIN core.usuario u ON u.id = g.responsavel_id
 WHERE g.ativo ORDER BY g.nome;
```

O aprovador é **congelado** em `almox.scm.aprovador_email` no INSERT (comentário da coluna na
`0001`): trocar o responsável do grupo amanhã não move a solicitação que já está na fila de quem
estava analisando.

---

## 3. Menu completo, e quem vê cada item

Almoxarifado é **um único menu** com 7 itens, como ficou definido na reunião. Utilidades tem **3
itens de menu** (não são abas — ver logo abaixo da tabela). O técnico vê **5 itens** no total.

| # | Menu / item | Permissão que abre | admin | gestor | pcm | almoxarife | lider | tecnico | viewer |
|---|---|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| 1 | **Início** | login válido | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 2 | **Almoxarifado** → Nova solicitação (SCI) | `almoxarifado.acesso` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| 3 | **Almoxarifado** → Minhas solicitações | `almoxarifado.acesso` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| 4 | **Almoxarifado** → Solicitações (SCI) | `almoxarifado.solicitacoes` ou `relatorio.leitura` `0002` | ✅ | ✅ | 👁 | ✅ | 👁 | — | 👁 |
| 5 | **Almoxarifado** → Nova compra (SCM) | `almoxarifado.scm_acesso` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| 6 | **Almoxarifado** → Gestão de SCM | `almoxarifado.scm_gestao` ou `relatorio.leitura` `0002` | ✅ | ✅ | 👁 | ✅ | — | — | 👁 |
| 7 | **Almoxarifado** → Aprovações SCM | `almoxarifado.scm_aprovacao` | ✅ | ✅ | — | — | ✅ | — | — |
| 8 | **Almoxarifado** → Famílias de itens | `almoxarifado.familias` | ✅ | ✅ | — | ✅ | — | — | — |
| 9 | **Utilidades** → Novo apontamento (Apontar consumo) | `utilidades.apontar` `0002` | ✅ | ✅ | ✅ | — | ✅ | ✅ | — |
| 10 | **Utilidades** → Apontamentos | `utilidades.desvios` `0002` ou `relatorio.leitura` `0002` | ✅ | ✅ | ✅ | — | 👁 | — | 👁 |
| 11 | **Utilidades** → Gestão de medidores | `utilidades.medidores` `0002` | ✅ | ✅ | ✅ | — | — | — | — |
| 12 | **Treinamentos** → Meus treinamentos | `treinamentos.acesso` `0002` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| 13 | **Treinamentos** → Visão geral de treinamentos | `treinamentos.visao_grupo` `0002` | ✅ | ✅ | — | — | ✅ | — | — |
| 14 | **Treinamentos** → Gestão de treinamentos | `treinamentos.gestao` `0002` | ✅ | ✅ | — | — | — | — | — |
| 15 | **PCM** (etapa posterior) | `pcm.acesso` | ✅ | ✅ | ✅ | — | ✅ | — | — |
| 16 | **Administração** → Usuários / Perfis / Grupos / E-mails autorizados | `acesso.gestao` `0002` | ✅ | — | — | — | — | — | — |
| 17 | **Administração** → Auditoria, Saúde operacional, Fila de e-mail | `acesso.auditoria` `0002` | ✅ | ✅ | ✅ | — | — | — | — |
| 18 | **Meu perfil** | login válido | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

✅ escreve · 👁 só lê · — não vê o item

**Menu do técnico, os 5 itens exatos:** Início · Treinamentos · Apontar consumo · Nova
solicitação · Minhas solicitações. Ele não vê "Solicitações (SCI)", não vê "Apontamentos", não vê
"Gestão de medidores". Os itens 5 ("Nova compra") e 3 ("Minhas solicitações") ficam **dentro** de
"Nova solicitação"/"Minhas solicitações" como abas SCI/SCM da mesma tela, para o técnico continuar
com 5 entradas no menu.

**Vocabulário:** a tela chama-se **"Apontar consumo"**. Não existe "apontar horímetro" em lugar
nenhum da interface — horímetro é um dos quatro valores de `util.medidor_tipo`, junto com água,
gás e energia, e a única diferença é que ele exige foto (`util.fn_leitura_preparar()`).

**Utilidades não tem abas.** São três **itens de menu**, na ordem: Apontar consumo, Apontamentos,
Gestão de medidores. A lista mestre e a gestão de medidores saíram de dentro da tela de
apontamento e viraram entradas próprias, cada uma com a sua permissão e a sua policy.

### 3.1 Nota de numeração — a RLS já foi escrita

A versão anterior deste texto prometia a RLS numa "seção 10". Ela **existe e está implantada**,
repartida em cinco arquivos desta pasta, e é a eles que as seções por perfil abaixo se referem:

| Arquivo | O que entrega |
|---|---|
| `02a-papeis.sql` | `app.usuario_atual()`, `app.tem_perfil()`, `app.eh_admin()`, `app.grupos_que_lidero()`, `app.usuario_ativo()`; roles `biotrop_app` / `biotrop_ro`; GRANTs; negação de coluna do gabarito |
| `02b-rls-core.sql` | policies de `core` (usuário, grupo, perfil, permissão, e-mails autorizados, login, auditoria, fila de e-mail, anexo) |
| `02c-rls-almox.sql` | `app.eh_do_meu_grupo()`, `app.sci_editavel()`, `app.scm_editavel()`; policies de SCI, SCM, filhas e famílias |
| `02d-rls-util.sql` | policies de medidor, leitura e tratativa de desvio; `security_invoker` nas 4 views de utilidades |
| `02e-rls-lms.sql` | `app.lidero_usuario()`, `app.lms_dono_matricula()`; policies das 13 tabelas de `lms` |

Pendências que **continuam abertas** depois desses cinco arquivos estão na seção 14 — inclusive
duas graves (`lms.corrigir_tentativa` e as views de `app` sem `security_invoker` fora de
utilidades). Nada nas seções por perfil promete proteção que não esteja num desses arquivos.

### 3.2 Onde o menu semeado e a RLS implantada discordam

`core.perfil_permissao` foi semeado na `0001` com 8 chaves; a RLS foi escrita em `02b`–`02e`
depois. Em cinco pontos os dois não dizem a mesma coisa. Menu que abre tela vazia, ou tela que
abre e nega no `INSERT`, é bug de produto, não de segurança — mas precisa de decisão:

| Ponto | O menu (permissão semeada) diz | A policy implantada faz | Correção sugerida |
|---|---|---|---|
| Apontar consumo, perfil `lider` | `lider` tem `utilidades.acesso`, então vê o item | `p_leitura_ins_tecnico` exige perfil `tecnico`; `p_leitura_ins_pcm` exige admin/gestor/pcm. `lider` grava nada | tirar `utilidades.acesso` de `lider`, **ou** somar `'lider'` ao array de `p_leitura_ins_tecnico` |
| Apontamentos, `lider` e `viewer` (👁 na tabela da seção 3) | leem a lista mestre | `p_leitura_sel_pcm` = admin/gestor/pcm; `p_leitura_sel_propria` = técnico, só as dele. `lider` e `viewer` recebem **lista vazia** | manter a policy e tirar o 👁 da tabela; relatório amplo é caminho de `biotrop_ro` |
| Auditoria, perfil `pcm` | item 17 do menu abre para `pcm` | `pol_auditoria_select` = admin/gestor | tirar `pcm` do item 17 |
| Fila de e-mail, `gestor` e `pcm` | item 17 do menu abre para os dois | `pol_email_fila_select` = **só admin** (corpo de e-mail carrega dado de terceiro) | manter a policy; Fila de e-mail é item exclusivo de admin |
| Famílias de itens, perfil `gestor` | `gestor` tem `almoxarifado.familias`, então vê e edita | `familia_ins/upd` (laço de `02c`, seção 2) = `ARRAY['almoxarife','admin']`. Gestor **lê** a família e falha ao salvar | somar `'gestor'` ao array daquele laço — é a leitura mais provável da regra, já que gestor tem o resto do almoxarifado |

Enquanto não houver decisão, vale a policy: o banco é a última palavra, como diz a seção 1. As
seções por perfil abaixo descrevem **o comportamento real de hoje**, não o do menu semeado.

---

## 4. Os status da SCI, rótulo por rótulo

`almox.sci_status` tem **6 valores**. A tela mostra **7 rótulos** — o sétimo, "Aberto", não é
status de banco:

| Rótulo na tela | Valor em `almox.sci_status` | Quem move para lá | Policy que permite |
|---|---|---|---|
| Aberto | *não existe no enum* | ninguém: é o rascunho do formulário, antes de enviar. Vive no navegador e nunca chega ao banco | — |
| Pendente de Aprovação | `pendente_aprovacao` | o solicitante, no `INSERT` | `sci_ins` (exige `status = 'pendente_aprovacao'` e `solicitante_id = app.usuario_atual()`) |
| Aguardando Revisão do Solicitante | `revisao_solicitante` | almoxarife/PCM devolvendo, com observação obrigatória | `sci_upd_fila` + `CHECK ck_sci_motivo_na_revisao` |
| Em Compra | `em_compra` | almoxarife/PCM | `sci_upd_fila` |
| Aguardando Cadastro de Item | `aguardando_cadastro` | almoxarife/PCM | `sci_upd_fila` |
| Cadastrado | `cadastrado` | almoxarife/PCM, com `codigo_item` preenchido | `sci_upd_fila` + `CHECK ck_sci_codigo_item_no_cadastrado` |
| Rejeitada | `reprovada` | almoxarife/PCM | `sci_upd_fila` |

Dois avisos que economizam retrabalho:

1. **"Rejeitada" na tela é `reprovada` no banco.** O rótulo é livre; o valor do enum não é. Não
   escreva `'rejeitada'` em nenhum `WHERE` — o Postgres devolve erro de valor inválido para o tipo.
2. Se o negócio quiser o rascunho **persistido**, aí "Aberto" vira valor de enum:
   `ALTER TYPE almox.sci_status ADD VALUE 'aberto' BEFORE 'pendente_aprovacao';` — e nesse caso
   `sci_ins` precisa aceitar `status IN ('aberto','pendente_aprovacao')` e a fila do almoxarifado
   precisa **excluir** `'aberto'` do filtro, senão rascunho de outra pessoa aparece como trabalho.
   Enquanto isso não for decidido, o rascunho fica no navegador e "Aberto" não existe no banco.

O e-mail automático sai em **uma** transição só: `revisao_solicitante`
(`almox.fn_sci_transicao()`). O histórico, esse, é gravado em toda transição, por trigger — a tela
não tem como mudar status sem deixar rastro em `almox.sci_historico`.

---

## 5. Administrador (`admin`)

Único perfil `fixo` (`core.perfil.fixo = true`, protegido por `tg_perfil_fixo`) e único que
`app.eh_admin()` reconhece. É o perfil de quem mantém a plataforma, não o de quem tem pressa.

| Item de menu | O que a tela mostra |
|---|---|
| Início | painéis de tudo: fila de SCI, SCM por status, desvios abertos, treinamento vencido |
| Almoxarifado (7 itens) | todas as SCI e SCM da planta, de qualquer grupo |
| Utilidades (3 itens) | todos os medidores (ativos e inativos), a série completa de leituras, todos os desvios |
| Treinamentos (3 itens) | conteúdo, rascunhos, matrículas, notas e comprovantes de todo mundo |
| Administração → Usuários / Perfis / Grupos / E-mails autorizados | o cadastro inteiro |
| Administração → Auditoria / Saúde operacional / Fila de e-mail | `core.auditoria`, `app.vw_saude_operacional`, `core.email_fila` |
| Meu perfil | dados próprios, tema, preferência de notificação |

**Pode:**

- criar, editar e desativar usuário, grupo, perfil e permissão — `pol_usuario_insert/update/delete`,
  `pol_grupo_*`, `pol_perfil_*`, `pol_permissao_*`, `pol_perfil_permissao_*`, todos com `app.eh_admin()`;
- liberar e revogar e-mail autorizado — `pol_email_autorizado_*`. No `INSERT` a liberação sai
  assinada: `WITH CHECK (app.eh_admin() AND liberado_por = app.usuario_atual())`;
- mexer em qualquer SCI e qualquer SCM de terceiro — `sci_upd_gestao`, `scm_upd_gestao`;
- apagar SCI, SCM, medidor, família, anexo, matrícula e comprovante — todos os `*_del` com
  `app.eh_admin()`;
- **desbloquear matrícula** que esgotou as 3 tentativas — `lms.liberar_matricula()` grava em
  `lms.liberacao`, cuja policy `liberacao_ins` exige `app.eh_admin() AND liberado_por = app.usuario_atual()`;
- lançar conclusão manual de treinamento (curso presencial, certificado externo) — `conclusao_ins`
  exige, junto, perfil admin, `evidencia = 'manual'` e `registrado_por = app.usuario_atual()`;
- ler a fila de e-mail — `pol_email_fila_select` é o único lugar do sistema com `app.eh_admin()` puro
  na leitura, porque corpo de e-mail carrega dado de terceiro.

**Não pode:**

| Não pode | O que barra |
|---|---|
| aprovar ou reprovar a própria SCM | `scm_upd_aprovacao` e `scm_upd_gestao`: `solicitante_id IS DISTINCT FROM app.usuario_atual()`. Ser admin não muda isso |
| mudar status da própria SCI | `sci_upd_gestao`, mesma condição. Como solicitante ele só reenvia na revisão, por `sci_upd_solicitante` |
| apagar ou editar linha de `core.auditoria` e `core.login_evento` | `FORCE ROW LEVEL SECURITY` **sem policy de UPDATE/DELETE** + `REVOKE UPDATE, DELETE` em `02a`. E `02b` tem um `DO` de conferência que **derruba o deploy** se alguém criar essa policy depois |
| apagar o perfil `admin` ou tirar permissão dele | `tg_perfil_fixo` e `tg_perfil_permissao_fixo` da `0001` — trigger, não policy: nem o próprio admin passa |
| ler a coluna do gabarito (`lms.questao_opcao.correta`) | `REVOKE SELECT ON lms.questao_opcao` + `GRANT SELECT (id, questao_id, posicao, texto)`. É privilégio de coluna da role `biotrop_app`; perfil de aplicação não tem como contornar |
| gravar progresso de aula no lugar de outra pessoa | `progresso_ins` só aceita `app.lms_dono_matricula(matricula_id) = app.usuario_atual()`. Não existe policy de escrita de progresso para admin nenhum |
| inserir tentativa de avaliação direto na tabela | `lms.tentativa` tem RLS ligado e **nenhuma** policy de `INSERT`. Só entra por `lms.corrigir_tentativa()` |
| apagar leitura de utilidade sem rastro | `p_leitura_del` permite (admin/gestor), mas `tg_audit_leitura` registra em `core.auditoria`, que é append-only |

**Falha fechada:** rota administrativa que esqueça o `SET LOCAL app.usuario_id` não vira acesso de
admin — `app.usuario_atual()` levanta exceção e a transação inteira morre.

---

## 6. Gestor (`gestor`)

Mesma amplitude operacional do admin, **sem gerir acesso**. A diferença é exatamente uma linha de
código: `app.eh_admin()` não devolve verdadeiro para `gestor`; onde a policy escreve
`app.tem_perfil(ARRAY['admin','gestor'])`, ele entra.

| Item de menu | O que a tela mostra |
|---|---|
| Início | os mesmos painéis do admin |
| Almoxarifado (7 itens) | todas as SCI e SCM, com tratativa e aprovação |
| Utilidades (3 itens) | medidores, leituras e desvios, com escrita |
| Treinamentos (3 itens) | conteúdo, rascunho, atribuição e acompanhamento de todo mundo |
| Administração → Auditoria / Saúde operacional | `core.auditoria` e `app.vw_saude_operacional` |
| Meu perfil | dados próprios |

**Pode:**

- tudo o que o almoxarife e o PCM fazem na SCI e na SCM, em qualquer status — `sci_upd_gestao`,
  `scm_upd_gestao` (sem restrição de status, diferente de `scm_upd_tratativa`);
- aprovar SCM de qualquer grupo — `scm_upd_aprovacao` aceita quem é o aprovador congelado **ou**
  responsável do grupo do solicitante; se o gestor for `responsavel_id` de um grupo, ele recebe a
  fila daquele grupo por `app.vw_aprovador_de`, pelo grupo e não pelo perfil;
- criar e editar grupo, inclusive **trocar o responsável direto** — `pol_grupo_insert/update` com
  `app.tem_perfil(ARRAY['admin','gestor'])`. É a alavanca mais pesada que o gestor tem: mexer em
  `core.grupo.responsavel_id` redireciona a aprovação de SCM das solicitações **futuras**;
- publicar, arquivar e editar treinamento e ver **rascunho** — `versao_sel` libera rascunho só para
  admin/gestor; qualquer outro perfil enxerga apenas `publicada` e `arquivada`;
- atribuir treinamento a usuário ou grupo — `atribuicao_ins`, com `criado_por` assinado;
- ler auditoria — `pol_auditoria_select` = admin/gestor;
- corrigir e apagar leitura de utilidade — `p_leitura_upd_pcm`, `p_leitura_del`.

**Não pode:**

| Não pode | O que barra |
|---|---|
| criar, editar ou desativar usuário | `pol_usuario_insert/update/delete` exigem `app.eh_admin()`. Ele **lê** todo mundo (`pol_usuario_select` inclui gestor), mas o `UPDATE` volta 0 linhas |
| liberar e-mail autorizado (conceder acesso ao sistema) | `pol_email_autorizado_insert/update/delete` = `app.eh_admin()`. Ele lê a lista, não escreve nela |
| criar perfil ou mover permissão entre perfis | `pol_perfil_*` e `pol_perfil_permissao_*` = `app.eh_admin()` |
| desbloquear matrícula reprovada 3 vezes | `liberacao_ins` = `app.eh_admin()`. `lms.liberar_matricula()` **não** é `SECURITY DEFINER`: roda sob RLS e falha no `INSERT` da liberação, antes de desbloquear |
| lançar conclusão manual de treinamento | `conclusao_ins` = `app.eh_admin()` |
| ler a fila de e-mail | `pol_email_fila_select` = `app.eh_admin()`. O item "Fila de e-mail" não é dele |
| aprovar a própria SCM ou mexer na própria SCI | `solicitante_id IS DISTINCT FROM app.usuario_atual()` em `scm_upd_aprovacao`, `scm_upd_gestao` e `sci_upd_gestao` |
| apagar SCI, SCM, medidor, família, anexo ou comprovante | todos os `*_del` correspondentes exigem `app.eh_admin()` |
| gravar progresso ou tentativa de outra pessoa | `progresso_ins` amarra ao dono da matrícula; `lms.tentativa` não tem policy de escrita |
| criar ou editar família de itens e campo dinâmico | `familia_ins/upd` e `familia_campo_ins/upd` = `ARRAY['almoxarife','admin']`. É a divergência 5 da seção 3.2 — hoje a tela abre e o salvar falha |

---

## 7. PCM (`pcm`)

O perfil com o maior desencontro entre menu e banco. A `0001` semeou **uma** permissão para ele
(`pcm.acesso`) de propósito, para não chutar acesso; a `02c`/`02d`, escritas depois, deram a ele
alcance largo em SCI, SCM e utilidades. Resultado de hoje: **o banco deixa, o menu não abre.**
Sem as chaves de `0002` (`utilidades.apontar`, `utilidades.desvios`, `utilidades.medidores`,
`almoxarifado.solicitacoes`), o PCM entra e vê Início, PCM e Meu perfil.

| Item de menu | O que a tela mostra | Precisa de |
|---|---|---|
| Início | fila de SCI, desvios abertos, medidores sem leitura no mês | login |
| Almoxarifado → Solicitações (SCI) | todas as SCI, com tratativa | `almoxarifado.solicitacoes` `0002` |
| Almoxarifado → Gestão de SCM | SCM aprovadas e em tratativa | `almoxarifado.scm_gestao` `0002` |
| Utilidades → Apontar consumo | todos os medidores, inclusive lançando no nome de terceiro | `utilidades.apontar` `0002` |
| Utilidades → Apontamentos | lista mestre com filtros (medidor, tipo, período, responsável, desvio) e tratativa de desvio | `utilidades.desvios` `0002` |
| Utilidades → Gestão de medidores | cadastro, edição e inativação de medidor | `utilidades.medidores` `0002` |
| PCM | etapa posterior (`pcm.os` e correlatas já existem na `0001`) | `pcm.acesso` (semeada) |
| Meu perfil | dados próprios | login |

**Pode (no banco, hoje):**

- mover a SCI por todo o fluxo, de `pendente_aprovacao` a `cadastrado` ou `reprovada` —
  `sci_upd_fila` (`app.tem_perfil(ARRAY['almoxarife','pcm'])`);
- tratar SCM **já aprovada** — `scm_upd_tratativa`: `USING status IN ('aprovada','em_tratativa')`,
  `WITH CHECK status IN ('aprovada','em_tratativa','concluida')`. É o caminho de `em_tratativa` e
  de `concluida`, e apenas ele;
- editar item, anexo e link da SCM depois de aprovada — `app.scm_editavel()` abre para
  almoxarife/PCM em `aprovada` e `em_tratativa`;
- cadastrar, editar e **inativar** medidor — `p_medidor_ins`, `p_medidor_upd`
  (`ARRAY['admin','gestor','pcm']`). Inativar é `UPDATE ativo = false`, não `DELETE`, para a série
  de consumo continuar no banco;
- lançar leitura no nome de terceiro (apontamento recebido no papel, acerto de fechamento) —
  `p_leitura_ins_pcm` não amarra `responsavel_id` à sessão, diferente da policy do técnico;
- corrigir leitura errada — `p_leitura_upd_pcm`, e a correção sai auditada por `tg_audit_leitura`;
- ler a série completa de leituras e o desvio de qualquer medidor — `p_leitura_sel_pcm` e
  `app.vw_util_desvio`, que já é `security_invoker`;
- registrar e concluir tratativa de desvio — `p_tratativa_ins/upd`, com
  `situacao = 'aberto' OR analisado_por = app.usuario_atual()`: quem analisa assina a análise.

**Não pode:**

| Não pode | O que barra |
|---|---|
| **aprovar SCM** | `scm_upd_tratativa` exige `status IN ('aprovada','em_tratativa')` no `USING`: a SCM em `pendente_aprovacao_lider` está fora do alcance dele. Aprovar é do responsável do grupo, não da fila |
| mexer em SCM antes da aprovação (inclusive nos itens) | mesma condição, mais `app.scm_editavel()` nas filhas: em `pendente_aprovacao_lider` a lista de itens é o que o líder está analisando |
| mudar status da **própria** SCI, nem da própria SCM | `solicitante_id IS DISTINCT FROM app.usuario_atual()` em `sci_upd_fila` e `scm_upd_tratativa` |
| apagar leitura | `p_leitura_del` = `ARRAY['admin','gestor']`. Apagar apontamento derruba a base de comparação das leituras seguintes; a correção do PCM é `UPDATE` |
| apagar medidor | `p_medidor_del` = admin |
| apagar tratativa de desvio | `p_tratativa_del` = admin, e a tabela está com `FORCE` |
| assinar a análise de desvio com o nome de outro | `WITH CHECK ... analisado_por = app.usuario_atual()` em `p_tratativa_ins/upd`, somado ao `CHECK ck_tratativa_analise` da `0001` |
| criar ou editar família de itens | `familia_ins/upd` = `ARRAY['almoxarife','admin']` |
| ler auditoria e fila de e-mail | `pol_auditoria_select` = admin/gestor; `pol_email_fila_select` = admin (divergências 3 e 4 da seção 3.2) |
| ler a lista de e-mails autorizados | `pol_email_autorizado_select` = admin/gestor |
| ver treinamento de terceiro | `matricula_sel` não inclui `pcm`: ele vê apenas a matrícula dele. "Visão geral de treinamentos" não é item dele |
| ver rascunho de treinamento | `versao_sel` libera `rascunho` só para admin/gestor |

---

## 8. Almoxarife (`almoxarife`)

O dono da fila do almoxarifado. Tem 5 das 8 permissões semeadas e nenhuma em utilidades.

| Item de menu | O que a tela mostra |
|---|---|
| Início | fila de SCI por status, SCM aprovadas esperando tratativa |
| Almoxarifado → Nova solicitação (SCI) | formulário com família e campos dinâmicos |
| Almoxarifado → Minhas solicitações | as SCI e as SCM que **ele** abriu |
| Almoxarifado → Solicitações (SCI) | **todas** as SCI, com a tratativa completa: status, observação, `codigo_item`, `numero_solicitacao_cadastro` |
| Almoxarifado → Nova compra (SCM) | formulário de SCM, itens, anexos e links |
| Almoxarifado → Gestão de SCM | SCM aprovadas e em tratativa, com `numero_processo_me` |
| Almoxarifado → Famílias de itens | famílias, campos dinâmicos e centros de custo |
| Treinamentos → Meus treinamentos | os treinamentos dele |
| Meu perfil | dados próprios |

**Pode:**

- ver toda SCI e toda SCM da planta — `sci_sel` e `scm_sel` incluem `almoxarife` na lista de
  perfis com visão total;
- devolver SCI para revisão do solicitante, com observação — `sci_upd_fila`; a observação é
  **obrigatória** por `CHECK ck_sci_motivo_na_revisao`, e a transição dispara o único e-mail
  automático do fluxo de SCI (`almox.fn_sci_transicao()`);
- fechar SCI em `cadastrado` — `sci_upd_fila` mais `CHECK ck_sci_codigo_item_no_cadastrado`, que
  exige `codigo_item` preenchido: fechar sem o código do ERP tira a razão de existir da solicitação;
- tratar SCM aprovada até `concluida` — `scm_upd_tratativa`;
- criar e editar família, campo dinâmico e centro de custo — `familia_ins/upd`,
  `familia_campo_ins/upd`, `centro_custo_ins/upd` (`ARRAY['almoxarife','admin']`);
- abrir a própria SCI e a própria SCM como qualquer um — `sci_ins`, `scm_ins`.

**Não pode:**

| Não pode | O que barra |
|---|---|
| **aprovar SCM** | não tem `almoxarifado.scm_aprovacao`, e `scm_upd_tratativa` não alcança `pendente_aprovacao_lider` |
| tratar a **própria** SCI ou a própria SCM | `solicitante_id IS DISTINCT FROM app.usuario_atual()` nas duas policies de tratativa. Ele abre uma SCI e ela vai para a fila de outro almoxarife — ou fica parada, e isso é intencional |
| apagar família em uso | `familia_del` = admin. O caminho normal é `ativo = false`, porque SCI e SCM antigas apontam para a linha |
| apagar SCI ou SCM | `sci_del`, `scm_del` = `app.eh_admin()` |
| entrar em utilidades | não tem `utilidades.acesso`; e no banco `p_medidor_sel_app`, `p_leitura_sel_*` e `p_tratativa_sel` não listam `almoxarife`: mesmo com a rota aberta, a lista vem vazia e o `INSERT` de leitura é recusado |
| ver treinamento de terceiro | `matricula_sel` não inclui `almoxarife` |
| ler auditoria, fila de e-mail ou e-mails autorizados | `pol_auditoria_select`, `pol_email_fila_select`, `pol_email_autorizado_select` |
| editar cadastro de usuário ou grupo | `pol_usuario_*` = admin; `pol_grupo_insert/update` = admin/gestor |

---

## 9. Responsável de grupo (perfil `lider`)

Leia a seção 2.1 antes desta. O perfil `lider` dá o **direito**; `core.grupo.responsavel_id` dá o
**escopo**. Quem tem o perfil e não é responsável de grupo nenhum abre as telas e vê fila vazia —
`app.grupos_que_lidero()` devolve conjunto vazio e todo `IN (...)` fica falso.

| Item de menu | O que a tela mostra |
|---|---|
| Início | SCM esperando a decisão dele, treinamento vencido da equipe |
| Almoxarifado → Nova solicitação (SCI) | formulário próprio |
| Almoxarifado → Minhas solicitações | as SCI e SCM que ele abriu |
| Almoxarifado → Solicitações (SCI) | as SCI **do grupo dele**, leitura |
| Almoxarifado → Nova compra (SCM) | formulário próprio |
| Almoxarifado → **Aprovações SCM** | fila de `pendente_aprovacao_lider` em que ele é o aprovador — `app.vw_scm_fila_aprovacao` |
| Treinamentos → Meus treinamentos | os dele |
| Treinamentos → **Visão geral de treinamentos** | matrícula, progresso, nota e comprovante de **cada liderado** — `app.vw_lms_visao_lider` |
| Meu perfil | dados próprios |

**Pode:**

- **aprovar, reprovar ou devolver para revisão** a SCM de quem está no grupo dele —
  `scm_upd_aprovacao`, com quatro condições no mesmo lugar: `status = 'pendente_aprovacao_lider'`,
  `solicitante_id IS DISTINCT FROM app.usuario_atual()`, `aprovador_id = app.usuario_atual() OR app.eh_do_meu_grupo(solicitante_id)`,
  e no `WITH CHECK` `decidido_por_id = app.usuario_atual()`: a decisão sai assinada ou não sai;
- receber a SCM mesmo se o responsável do grupo mudou no meio do caminho — a policy aceita o
  aprovador **congelado** na linha *ou* o responsável atual do grupo do solicitante;
- ler as SCI e as SCM de quem ele lidera — `sci_sel` / `scm_sel`, ramo
  `app.eh_do_meu_grupo(solicitante_id)`;
- ler o cadastro dos liderados — `pol_usuario_select`, ramo
  `grupo_id IN (SELECT app.grupos_que_lidero())`; e os anexos que eles enviaram, por
  `pol_anexo_select`;
- acompanhar treinamento da equipe — `matricula_sel`, `progresso_sel`, `tentativa_sel`,
  `conclusao_sel` e `liberacao_sel` têm todos o ramo `app.lidero_usuario(...)`. É a base de banco
  do item "Visão geral de treinamentos", restrito a ele, ao gestor e ao admin;
- abrir a própria SCI e a própria SCM, como qualquer usuário ativo.

**Não pode:**

| Não pode | O que barra |
|---|---|
| **aprovar a própria SCM** | `scm_upd_aprovacao`: `solicitante_id IS DISTINCT FROM app.usuario_atual()` no `USING` **e** no `WITH CHECK`. A dele sobe para o responsável do grupo dele — e se ele for o responsável do próprio grupo, ninguém do fluxo normal aprova: sobra gestor/admin por `scm_upd_gestao`. Está na seção 14 |
| aprovar SCM de outro grupo | `app.eh_do_meu_grupo(solicitante_id)` falso e `aprovador_id` diferente dele: o `USING` não casa e o `UPDATE` afeta 0 linhas |
| decidir SCM que já saiu de `pendente_aprovacao_lider` | `USING status = 'pendente_aprovacao_lider'`. Depois de aprovada, quem mexe é almoxarife/PCM |
| tratar SCI (mudar status, preencher `codigo_item`) | `sci_upd_fila` = `ARRAY['almoxarife','pcm']`; `sci_upd_gestao` = admin/gestor. Em "Solicitações (SCI)" ele **lê** as do grupo e não salva nada |
| ver SCI ou SCM de grupo que não é dele | `sci_sel` / `scm_sel`: `lider` não está na lista de perfis com visão total |
| apontar consumo | `p_leitura_ins_tecnico` exige perfil `tecnico`; `p_leitura_ins_pcm` exige admin/gestor/pcm. É a divergência 1 da seção 3.2 |
| ver a lista mestre de apontamentos ou os medidores | `p_leitura_sel_pcm`, `p_leitura_sel_propria` e `p_medidor_sel_app` não listam `lider`: lista vazia (divergência 2) |
| lançar progresso, nota ou comprovante do liderado | `progresso_ins/upd` = só o dono da matrícula; `lms.tentativa` sem policy de escrita; `conclusao_ins` = admin. Acompanhamento se lê, não se preenche |
| desbloquear matrícula reprovada do liderado | `liberacao_ins` = `app.eh_admin()` |
| ver rascunho de treinamento | `versao_sel` libera `rascunho` para admin/gestor |
| editar usuário, grupo ou responsável do grupo | `pol_usuario_update` = admin; `pol_grupo_update` = admin/gestor |

---

## 10. Técnico (`tecnico`)

**Cinco itens no menu, exatamente:** Início · Treinamentos · Apontar consumo · Nova solicitação ·
Minhas solicitações.

| Item de menu | O que a tela mostra |
|---|---|
| Início | o que ele deve: treinamento pendente, solicitação devolvida para revisão |
| Treinamentos | os treinamentos dele — aula, avaliação, nota, comprovante |
| Apontar consumo | só os medidores **ativos**, com a leitura anterior e o consumo calculado; horímetro pede foto |
| Nova solicitação | formulário de SCI e de SCM (a "Nova compra" chega a ele por dentro desta tela) |
| Minhas solicitações | **as SCI e as SCM que ele abriu**, com status, histórico e o que o almoxarife pediu para corrigir |
| Meu perfil | dados próprios |

**Pode:**

- abrir SCI — `sci_ins`, que amarra `solicitante_id = app.usuario_atual()` **e**
  `status = 'pendente_aprovacao'`: não dá para gravar solicitação no nome de outro nem nascer já
  em `cadastrado`;
- abrir SCM — `scm_ins`, mesma amarração com `status = 'pendente_aprovacao_lider'`. O aprovador é
  resolvido e congelado na linha pelo trigger, pelo responsável do grupo dele;
- ver, em "Minhas solicitações", as duas coisas: `sci_sel` e `scm_sel` pelo ramo
  `solicitante_id = app.usuario_atual()`. São duas consultas, uma regra;
- **corrigir e reenviar** o que foi devolvido:
  - SCI em `revisao_solicitante` → `sci_upd_solicitante`, com
    `WITH CHECK status IN ('revisao_solicitante','pendente_aprovacao')`: só volta para a fila, não
    pula para `em_compra`;
  - SCM em `revisao_solicitada` → `scm_upd_solicitante`, com
    `WITH CHECK status IN ('revisao_solicitada','pendente_aprovacao_lider')`;
  - itens, anexos e campos dinâmicos acompanham a mesma janela: `app.sci_editavel()` e
    `app.scm_editavel()` só abrem para o solicitante nesses dois status;
- apontar consumo — `p_leitura_ins_tecnico`, que exige três coisas juntas: perfil `tecnico`,
  `responsavel_id = app.usuario_atual()` e `EXISTS (medidor ativo)`;
- ver as leituras que **ele** lançou — `p_leitura_sel_propria`. Não é conforto de tela: sem uma
  policy de `SELECT` que alcance a linha nova, `INSERT ... RETURNING` falharia;
- estudar e responder avaliação — `progresso_ins/upd` (dono da matrícula) e
  `lms.corrigir_tentativa()`, que corrige dentro do banco e devolve só nota, aprovação e
  tentativas restantes;
- atualizar a própria matrícula (iniciar, marcar em andamento) — `matricula_upd_propria`, com
  `NOT bloqueada` no `USING` **e** no `WITH CHECK`.

**Não pode:**

| Não pode | O que barra |
|---|---|
| ver SCI ou SCM de outra pessoa | `sci_sel` / `scm_sel`: `tecnico` não está na lista de visão total e não lidera grupo. Ele vê a dele e ponto |
| mudar o status da própria SCI fora da janela de revisão | `sci_upd_solicitante` tem `USING status = 'revisao_solicitante'`. Em qualquer outro status o `UPDATE` afeta 0 linhas |
| se aprovar a própria SCM | `scm_upd_aprovacao` exige `solicitante_id IS DISTINCT FROM app.usuario_atual()`; e ele não tem `almoxarifado.scm_aprovacao` |
| gravar solicitação no nome de outro | `WITH CHECK solicitante_id = app.usuario_atual()` em `sci_ins` e `scm_ins` |
| **editar ou apagar apontamento** já lançado | não existe policy de `UPDATE` nem de `DELETE` de `util.leitura` para `tecnico`. Leitura gravada é evidência; correção é do PCM, e sai auditada por `tg_audit_leitura` |
| apontar em medidor inativo | `EXISTS (SELECT 1 FROM util.medidor m WHERE m.id = medidor_id AND m.ativo)` no `WITH CHECK`. O medidor inativo também desaparece da tela dele, por `p_medidor_sel_app` |
| apontar no nome de outro | `responsavel_id = app.usuario_atual()` no mesmo `WITH CHECK` |
| ver a lista mestre de apontamentos ou a gestão de medidores | não tem as chaves de menu; e `p_leitura_sel_pcm` / `p_medidor_upd` não listam `tecnico` |
| ver o gabarito da avaliação | `REVOKE SELECT ON lms.questao_opcao` mais `GRANT SELECT (id, questao_id, posicao, texto)`. O gabarito não chega ao navegador nem por `select *` |
| se aprovar num treinamento | `lms.tentativa` e `lms.tentativa_resposta` têm RLS ligado e **nenhuma** policy de escrita: `INSERT` com nota 100 é recusado. Nota só nasce dentro de `lms.corrigir_tentativa()` |
| destravar a própria matrícula depois de 3 tentativas | `matricula_upd_propria` exige `NOT bloqueada` — a linha bloqueada sai do `USING` dele. Desbloqueio é `lms.liberar_matricula()`, e `liberacao_ins` = admin |
| gerar comprovante de conclusão para si | `conclusao_ins` = admin com `evidencia = 'manual'`. A automática nasce dentro de `corrigir_tentativa()`, pelo dono do banco |
| ver treinamento de colega | `matricula_sel`, `progresso_sel`, `tentativa_sel`, `conclusao_sel`: os três ramos de cada uma são admin/gestor, dono, ou líder do dono |
| ver rascunho de treinamento | `versao_sel` |

**Uma ressalva honesta:** hoje o técnico que trocar o `matricula_id` no corpo do POST de
`lms.corrigir_tentativa()` responde a avaliação de outra pessoa, porque a função é
`SECURITY DEFINER` e não confere o dono. RLS não alcança função `SECURITY DEFINER`. É o item 1 da
seção 14, com o SQL da correção.

---

## 11. Visualização (`viewer`)

Perfil de leitura. Na `0001` ele nasceu **sem nenhuma linha** em `core.perfil_permissao` — de
propósito, para não chutar acesso. Então hoje, na tela, ele vê Início, Meus treinamentos e Meu
perfil, e nada mais, até a `0002` semear as chaves de leitura.

| Item de menu | O que a tela mostra |
|---|---|
| Início | painéis de leitura |
| Almoxarifado → Solicitações (SCI) | todas as SCI, **sem** nenhum botão de ação — depende de `relatorio.leitura` `0002` |
| Almoxarifado → Gestão de SCM | todas as SCM, só leitura — depende de `relatorio.leitura` `0002` |
| Treinamentos → Meus treinamentos | os dele |
| Meu perfil | dados próprios |

**Pode:**

- ler toda SCI e toda SCM — `sci_sel` e `scm_sel` incluem `viewer` na lista de perfis com visão
  total. Isso já vale **hoje**, no banco: o que falta é a chave que abre a tela;
- ler a lista de grupos, perfis e permissões — `pol_grupo_select`, `pol_perfil_select`,
  `pol_permissao_select` e `pol_perfil_permissao_select`, todos com `app.usuario_ativo()`;
- ler o conteúdo publicado de treinamento e a própria matrícula — `treinamento_sel`, `aula_sel`,
  `versao_sel` (só `publicada` e `arquivada`) e `matricula_sel` pelo ramo do dono;
- abrir a própria SCI e a própria SCM: `sci_ins` e `scm_ins` aceitam **qualquer usuário ativo** que
  assine a linha. Se o negócio não quiser isso, a correção é somar
  `AND NOT app.tem_perfil(ARRAY['viewer'])` às duas policies — item 4 da seção 14.

**Não pode:**

| Não pode | O que barra |
|---|---|
| tratar SCI ou SCM de terceiro | `sci_upd_fila`, `sci_upd_gestao`, `scm_upd_tratativa`, `scm_upd_gestao` e `scm_upd_aprovacao` não listam `viewer` em nenhum ramo |
| ver, apontar ou corrigir utilidades | `p_medidor_sel_app`, `p_leitura_sel_pcm`, `p_leitura_sel_propria` e `p_tratativa_sel` não listam `viewer`: a tela, se aberta, vem vazia, e todo `INSERT` é recusado |
| criar ou editar família, medidor, grupo, usuário ou perfil | todas as policies de escrita desses objetos pedem perfil nomeado, e `viewer` não aparece em nenhuma |
| ver treinamento de terceiro | `matricula_sel` — só o dele |
| ler auditoria, fila de e-mail ou e-mails autorizados | `pol_auditoria_select`, `pol_email_fila_select`, `pol_email_autorizado_select` |
| ver o cadastro de outro usuário | `pol_usuario_select`: só a própria linha, porque não é admin/gestor e não lidera grupo |

---

## 12. Matriz de permissões

Ação por ação, com o objeto de banco que decide. `S` = pode, `—` = não pode, `L` = só leitura.
Onde a coluna do perfil discorda do menu semeado, a seção 3.2 já explicou por quê: **a policy é
que vale**.

| Ação | admin | gestor | pcm | almoxarife | lider | tecnico | viewer | Objeto de banco que decide |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|---|
| Abrir SCI | S | S | S | S | S | S | S | `sci_ins` (assina a linha, status inicial) |
| Ver todas as SCI | S | S | S | S | L do grupo | L própria | L | `sci_sel` |
| Tratar SCI (status, `codigo_item`) | S | S | S | S | — | — | — | `sci_upd_fila`, `sci_upd_gestao` |
| Reenviar SCI devolvida | própria | própria | própria | própria | própria | própria | própria | `sci_upd_solicitante` |
| Apagar SCI | S | — | — | — | — | — | — | `sci_del` |
| Abrir SCM | S | S | S | S | S | S | S | `scm_ins` |
| Ver todas as SCM | S | S | S | S | L do grupo | L própria | L | `scm_sel` |
| **Aprovar / reprovar SCM** | S | S | — | — | **S do grupo** | — | — | `scm_upd_aprovacao` (+ `scm_upd_gestao`) |
| Tratar SCM aprovada → concluída | S | S | S | S | — | — | — | `scm_upd_tratativa`, `scm_upd_gestao` |
| Editar itens/anexos da SCM | janela | janela | após aprovada | após aprovada | — | própria em revisão | — | `app.scm_editavel()` |
| Apagar SCM | S | — | — | — | — | — | — | `scm_del` |
| Criar/editar família e campo dinâmico | S | — | — | S | — | — | — | `familia_ins/upd`, `familia_campo_ins/upd` |
| Apagar família | S | — | — | — | — | — | — | `familia_del` |
| Apontar consumo | S | S | S | — | — | S | — | `p_leitura_ins_pcm`, `p_leitura_ins_tecnico` |
| Apontar no nome de terceiro | S | S | S | — | — | — | — | `p_leitura_ins_pcm` (não amarra `responsavel_id`) |
| Ver a série completa de leituras | S | S | S | — | — | próprias | — | `p_leitura_sel_pcm`, `p_leitura_sel_propria` |
| Corrigir leitura | S | S | S | — | — | — | — | `p_leitura_upd_pcm` |
| Apagar leitura | S | S | — | — | — | — | — | `p_leitura_del` |
| Cadastrar / inativar medidor | S | S | S | — | — | — | — | `p_medidor_ins`, `p_medidor_upd` |
| Apagar medidor | S | — | — | — | — | — | — | `p_medidor_del` |
| Tratar desvio | S | S | S | — | — | — | — | `p_tratativa_ins/upd` (assina `analisado_por`) |
| Criar / publicar treinamento | S | S | — | — | — | — | — | `treinamento_*`, `versao_*` |
| Ver rascunho de versão | S | S | — | — | — | — | — | `versao_sel` |
| Atribuir treinamento a grupo/usuário | S | S | — | — | — | — | — | `atribuicao_ins/upd` |
| Ver treinamento de terceiro | S | S | — | — | **do grupo** | — | — | `matricula_sel`, `progresso_sel`, `tentativa_sel`, `conclusao_sel` |
| Gravar progresso de aula | própria | própria | própria | própria | própria | própria | própria | `progresso_ins/upd` (dono da matrícula) |
| Registrar nota de avaliação | — | — | — | — | — | — | — | `lms.tentativa` sem policy de escrita; só `lms.corrigir_tentativa()` |
| Ler o gabarito | — | — | — | — | — | — | — | privilégio de coluna em `lms.questao_opcao` |
| Desbloquear matrícula (4ª tentativa) | S | — | — | — | — | — | — | `liberacao_ins` |
| Lançar conclusão manual | S | — | — | — | — | — | — | `conclusao_ins` |
| Criar / editar / desativar usuário | S | — | — | — | — | — | — | `pol_usuario_insert/update/delete` |
| Criar / editar grupo e responsável | S | S | — | — | — | — | — | `pol_grupo_insert/update` |
| Criar perfil / mover permissão | S | — | — | — | — | — | — | `pol_perfil_*`, `pol_perfil_permissao_*` |
| Liberar e-mail autorizado | S | — | — | — | — | — | — | `pol_email_autorizado_insert` |
| Ler e-mails autorizados | S | S | — | — | — | — | — | `pol_email_autorizado_select` |
| Ler auditoria | S | S | — | — | — | — | — | `pol_auditoria_select` |
| Ler fila de e-mail | S | — | — | — | — | — | — | `pol_email_fila_select` |
| Editar ou apagar auditoria / login | — | — | — | — | — | — | — | `FORCE` + sem policy + `REVOKE` (nem o admin) |
| Aprovar a própria SCM | — | — | — | — | — | — | — | `solicitante_id IS DISTINCT FROM app.usuario_atual()` |
| Tratar a própria SCI | — | — | — | — | — | — | — | mesma condição em `sci_upd_fila` / `sci_upd_gestao` |

Três linhas dessa matriz não têm nenhum `S` em nenhuma coluna, e é assim de propósito: registrar
nota, ler gabarito e reescrever log de acesso não são atos de gente logada — são atos do banco, ou
não acontecem.

---

## 13. Roteiro de teste, perfil por perfil

O teste é feito **no banco**, conectado como `biotrop_app` — não pela tela. Testar pela tela prova
que o menu está escondido; testar por `psql` prova que a policy existe. Toda checagem segue a
mesma forma:

```sql
-- 1) conecte como a role da aplicação, NUNCA como dono do banco nem superuser
--    (dono ignora RLS onde não há FORCE; passaria em tudo e não provaria nada)
psql "host=... dbname=biotrop user=biotrop_app"

-- 2) vire a pessoa que você quer testar
BEGIN;
  SET LOCAL app.usuario_id    = '<uuid do usuário de teste>';
  SET LOCAL app.usuario_email = '<email dele>';
  -- ... a ação do roteiro ...
ROLLBACK;   -- ROLLBACK, não COMMIT: o roteiro não deve sujar a base
```

Antes de começar, tenha os uuids à mão:

```sql
SELECT u.id, u.nome, u.email, u.perfil_id, g.nome AS grupo,
       (u.id = g.responsavel_id) AS eh_responsavel
  FROM core.usuario u LEFT JOIN core.grupo g ON g.id = u.grupo_id
 WHERE u.ativo ORDER BY u.perfil_id, u.nome;
```

**Como ler o resultado.** `UPDATE 0` é policy negando por `USING` — a linha nem foi vista.
`ERROR: new row violates row-level security policy` é `WITH CHECK` negando o valor que você tentou
gravar. `ERROR: permission denied for table/column` é `GRANT`, não RLS. Os três são "passou",
quando o roteiro espera negação; o que **não** pode acontecer é `UPDATE 1` numa linha que a pessoa
não deveria alcançar.

### 13.0 Antes dos perfis: três checagens de estrutura

| Ação | Resultado esperado | Como saber que passou |
|---|---|---|
| `SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('core','almox','util','lms') AND c.relkind='r' AND NOT c.relrowsecurity;` | zero linhas | qualquer nome que apareça é tabela aberta a qualquer linha |
| `SELECT rolname, rolsuper, rolbypassrls FROM pg_roles WHERE rolname IN ('biotrop_app','biotrop_ro');` | `f` nas duas colunas, nas duas roles | `rolbypassrls = t` anula todas as policies deste documento |
| abrir transação **sem** `SET LOCAL app.usuario_id` e rodar `SELECT count(*) FROM almox.scm;` | `ERROR: ... Sessao sem identidade` (de `app.usuario_atual()`) | falha fechada: rota que esquece o `SET LOCAL` não vaza nada |

### 13.1 Administrador

| Ação | Resultado esperado | Como saber que passou |
|---|---|---|
| `INSERT INTO core.usuario (nome, email, perfil_id) VALUES ('Teste','teste@biotrop.com.br','tecnico');` | `INSERT 0 1` | é o único perfil em que este insert passa |
| `UPDATE almox.sci SET status='em_compra' WHERE codigo='SCI-0001';` (SCI de outro) | `UPDATE 1` | `sci_upd_gestao` |
| `UPDATE almox.scm SET status='aprovada', decidido_por_id=app.usuario_atual() WHERE solicitante_id = app.usuario_atual();` (a própria) | `UPDATE 0` | ser admin não aprova a própria compra |
| `DELETE FROM core.auditoria WHERE true;` | `ERROR: permission denied` | `REVOKE DELETE` de `02a` |
| `UPDATE core.login_evento SET sucesso = true WHERE true;` | `ERROR: permission denied` | log de acesso é append-only até para admin |
| `SELECT correta FROM lms.questao_opcao LIMIT 1;` | `ERROR: permission denied for column correta` | privilégio de coluna, não RLS |
| `DELETE FROM core.perfil WHERE id='admin';` | `ERROR` do `tg_perfil_fixo` | trigger, e vale para o próprio admin |
| `SELECT count(*) FROM core.email_fila;` | número > 0 | único perfil que lê a fila |
| `INSERT INTO lms.liberacao (matricula_id, tentativas_extra, motivo, liberado_por) VALUES ('<matrícula bloqueada>',1,'reteste', app.usuario_atual());` | `INSERT 0 1` | `liberacao_ins` |

### 13.2 Gestor

| Ação | Resultado esperado | Como saber que passou |
|---|---|---|
| `SELECT count(*) FROM almox.sci;` e `FROM almox.scm;` | total da planta | `sci_sel` / `scm_sel` com visão total |
| `UPDATE almox.scm SET status='concluida' WHERE codigo='<SCM em tratativa de outro>';` | `UPDATE 1` | `scm_upd_gestao` não tem restrição de status |
| `UPDATE core.usuario SET ativo=false WHERE email='<alguém>';` | `UPDATE 0` | `pol_usuario_update` = `app.eh_admin()`; ele **lê** e não escreve |
| `INSERT INTO core.email_autorizado (email, liberado_por) VALUES ('x@biotrop.com.br', app.usuario_atual());` | `ERROR: new row violates row-level security policy` | conceder acesso é só de admin |
| `SELECT count(*) FROM core.email_fila;` | `0` | `pol_email_fila_select` = admin. Zero linhas, sem erro: é a policy, não o `GRANT` |
| `SELECT count(*) FROM core.auditoria;` | número > 0 | `pol_auditoria_select` inclui gestor |
| `UPDATE core.grupo SET responsavel_id='<uuid>' WHERE codigo='g-mecanica';` | `UPDATE 1` | `pol_grupo_update`; confira depois em `app.vw_aprovador_de` |
| `SELECT count(*) FROM lms.versao WHERE status='rascunho';` | número > 0 | `versao_sel` libera rascunho para gestor |
| `INSERT INTO lms.liberacao (...) VALUES (..., app.usuario_atual());` | violação de RLS | desbloqueio é de admin |
| `UPDATE almox.familia SET nome='X' WHERE codigo='<qualquer>';` | `UPDATE 0` | divergência 5 da seção 3.2 — hoje gestor não escreve família |

### 13.3 PCM

| Ação | Resultado esperado | Como saber que passou |
|---|---|---|
| `UPDATE almox.sci SET status='aguardando_cadastro' WHERE codigo='<SCI de outro>';` | `UPDATE 1` | `sci_upd_fila` |
| `UPDATE almox.scm SET status='aprovada', decidido_por_id=app.usuario_atual() WHERE status='pendente_aprovacao_lider';` | `UPDATE 0` | **PCM não aprova SCM** — o `USING` de `scm_upd_tratativa` exige `aprovada`/`em_tratativa` |
| `UPDATE almox.scm SET status='em_tratativa' WHERE status='aprovada' AND solicitante_id <> app.usuario_atual();` | `UPDATE 1` | `scm_upd_tratativa` |
| `INSERT INTO util.leitura (medidor_id, valor, responsavel_id, lido_em) VALUES ('<medidor>', 100, '<uuid de um técnico>', now());` | `INSERT 0 1` | `p_leitura_ins_pcm` permite lançar no nome de terceiro |
| `UPDATE util.leitura SET valor = 101 WHERE id='<leitura de outro>';` | `UPDATE 1` **e** nova linha em `core.auditoria` | `p_leitura_upd_pcm` + `tg_audit_leitura` |
| `DELETE FROM util.leitura WHERE id='<qualquer>';` | `DELETE 0` | `p_leitura_del` = admin/gestor |
| `UPDATE util.medidor SET ativo=false WHERE codigo='<medidor>';` | `UPDATE 1` | inativar é `UPDATE`, é do PCM |
| `DELETE FROM util.medidor WHERE codigo='<medidor>';` | `DELETE 0` | `p_medidor_del` = admin |
| `INSERT INTO util.desvio_tratativa (leitura_id, tipo, situacao, analisado_por, analisado_em, nota) VALUES (..., 'resolvido', '<uuid de outra pessoa>', now(), 'ok');` | violação de RLS | `analisado_por = app.usuario_atual()`: quem analisa assina |
| `SELECT count(*) FROM lms.matricula;` | só as dele | `matricula_sel` não inclui `pcm` |
| `SELECT count(*) FROM core.auditoria;` | `0` | divergência 3 da seção 3.2 |

### 13.4 Almoxarife

| Ação | Resultado esperado | Como saber que passou |
|---|---|---|
| `UPDATE almox.sci SET status='revisao_solicitante' WHERE codigo='<SCI de outro>';` **sem** observação | `ERROR` do `CHECK ck_sci_motivo_na_revisao` | devolver sem dizer o que corrigir não passa |
| a mesma com `observacao_almoxarife='faltou a folha de dados'` | `UPDATE 1` **e** uma linha nova em `core.email_fila` com `motivo='sci_revisao_solicitante'` | `sci_upd_fila` + `almox.fn_sci_transicao()` |
| `UPDATE almox.sci SET status='cadastrado', codigo_item=NULL WHERE codigo='<SCI de outro>';` | `ERROR` do `CHECK ck_sci_codigo_item_no_cadastrado` | fechar sem código do ERP não passa |
| `UPDATE almox.sci SET status='em_compra' WHERE solicitante_id = app.usuario_atual();` | `UPDATE 0` | ninguém trata a própria solicitação |
| `INSERT INTO almox.familia (codigo, nome) VALUES ('f-teste','Teste');` | `INSERT 0 1` | `familia_ins` = almoxarife/admin |
| `DELETE FROM almox.familia WHERE codigo='f-teste';` | `DELETE 0` | `familia_del` = admin; o caminho é `ativo=false` |
| `UPDATE almox.scm SET status='aprovada', decidido_por_id=app.usuario_atual() WHERE status='pendente_aprovacao_lider';` | `UPDATE 0` | almoxarife não aprova |
| `INSERT INTO almox.scm_item (scm_id, descricao, quantidade) VALUES ('<SCM em pendente_aprovacao_lider>','x',1);` | violação de RLS | `app.scm_editavel()`: antes da aprovação a lista de itens é do líder |
| `SELECT count(*) FROM util.leitura;` | `0` | utilidades não é dele |
| `SELECT count(*) FROM lms.matricula;` | só as dele | `matricula_sel` |

### 13.5 Responsável de grupo (`lider`)

Use **dois** usuários: um `lider` que é `responsavel_id` de um grupo, e um `tecnico` daquele grupo.

| Ação | Resultado esperado | Como saber que passou |
|---|---|---|
| como técnico do grupo: `INSERT INTO almox.scm (...) VALUES (..., app.usuario_atual(), 'pendente_aprovacao_lider');` | `INSERT 0 1`, e a linha nasce com `aprovador_email` = e-mail do líder | trigger de resolução do aprovador + `scm_ins` |
| como líder: `SELECT count(*) FROM app.vw_scm_fila_aprovacao;` | ≥ 1, incluindo a SCM acima | `scm_sel` pelo ramo `aprovador_id` / `eh_do_meu_grupo` |
| `UPDATE almox.scm SET status='aprovada', decidido_por_id=app.usuario_atual() WHERE id='<a SCM do liderado>';` | `UPDATE 1` | `scm_upd_aprovacao` |
| a mesma, com `decidido_por_id` de outra pessoa | violação de RLS | a decisão sai assinada ou não sai |
| `UPDATE almox.scm SET status='aprovada', decidido_por_id=app.usuario_atual() WHERE solicitante_id = app.usuario_atual();` | `UPDATE 0` | não aprova a própria |
| `UPDATE almox.scm SET status='aprovada', decidido_por_id=app.usuario_atual() WHERE id='<SCM de outro grupo>';` | `UPDATE 0` | escopo vem de `core.grupo.responsavel_id` |
| `SELECT count(*) FROM almox.sci;` | só as do grupo dele e as dele | `sci_sel`, ramo `eh_do_meu_grupo` |
| `UPDATE almox.sci SET status='em_compra' WHERE id='<SCI do liderado>';` | `UPDATE 0` | ele lê a SCI do grupo, não trata |
| `SELECT count(*) FROM lms.matricula;` | as dele **e** as dos liderados | `matricula_sel`, ramo `app.lidero_usuario` |
| `UPDATE lms.progresso_aula SET concluida=true WHERE matricula_id='<do liderado>';` | `UPDATE 0` | acompanhamento se lê, não se preenche |
| `INSERT INTO util.leitura (...) VALUES (..., app.usuario_atual(), now());` | violação de RLS | divergência 1 da seção 3.2 |
| **líder sem grupo:** `SELECT count(*) FROM app.vw_scm_fila_aprovacao;` | `0` | perfil dá direito; responsabilidade dá escopo (seção 2.1) |

### 13.6 Técnico

| Ação | Resultado esperado | Como saber que passou |
|---|---|---|
| `INSERT INTO almox.sci (familia_id, solicitante_id, solicitante_nome, status) VALUES ('<familia>', app.usuario_atual(), 'Teste', 'pendente_aprovacao');` | `INSERT 0 1` com `codigo` `SCI-nnnn` preenchido pelo trigger | `sci_ins` |
| o mesmo com `status='cadastrado'` | violação de RLS | não nasce pronta |
| o mesmo com `solicitante_id` de outra pessoa | violação de RLS | não abre no nome de outro |
| `SELECT count(*) FROM almox.sci;` + `SELECT count(*) FROM almox.scm;` | só as dele, nos dois | é o que "Minhas solicitações" mostra: SCI **e** SCM dele |
| `UPDATE almox.sci SET status='pendente_aprovacao' WHERE id='<a dele, em revisao_solicitante>';` | `UPDATE 1` | `sci_upd_solicitante` |
| `UPDATE almox.sci SET status='em_compra' WHERE id='<a dele, em revisao_solicitante>';` | violação de RLS | o `WITH CHECK` só aceita voltar para a fila |
| `UPDATE almox.sci SET status='pendente_aprovacao' WHERE id='<a dele, já em em_compra>';` | `UPDATE 0` | fora da janela de revisão |
| `INSERT INTO util.leitura (medidor_id, valor, responsavel_id, lido_em) VALUES ('<medidor ativo>', 123, app.usuario_atual(), now());` | `INSERT 0 1`, com `consumo` e `leitura_anterior` calculados | `p_leitura_ins_tecnico` + `util.fn_leitura_preparar()` |
| o mesmo em medidor com `ativo=false` | violação de RLS | `EXISTS (... AND m.ativo)` |
| o mesmo com `responsavel_id` de outra pessoa | violação de RLS | apontamento assinado |
| `UPDATE util.leitura SET valor=999 WHERE responsavel_id = app.usuario_atual();` | `UPDATE 0` | não existe policy de `UPDATE` para técnico |
| `DELETE FROM util.leitura WHERE responsavel_id = app.usuario_atual();` | `DELETE 0` | nem de `DELETE` |
| `SELECT count(*) FROM util.medidor;` | só os ativos | `p_medidor_sel_app` |
| `INSERT INTO lms.tentativa (matricula_id, numero, nota, aprovado) VALUES ('<a dele>', 1, 100, true);` | violação de RLS | `lms.tentativa` sem policy de escrita — ninguém se aprova |
| `SELECT lms.corrigir_tentativa('<matrícula dele>', '<respostas>');` | devolve `nota`, `aprovado`, `tentativas_restantes` | caminho legítimo da avaliação |
| `SELECT lms.corrigir_tentativa('<matrícula de OUTRA pessoa>', '<respostas>');` | **hoje responde e grava** | é o furo do item 1 da seção 14. Depois da correção, tem de voltar `ERROR: Matricula de outro usuario` |
| `SELECT correta FROM lms.questao_opcao LIMIT 1;` | `ERROR: permission denied for column correta` | gabarito fora do alcance |
| `UPDATE lms.matricula SET bloqueada=false WHERE usuario_id = app.usuario_atual();` | `UPDATE 0` na linha bloqueada | `matricula_upd_propria` exige `NOT bloqueada` |

### 13.7 Visualização (`viewer`)

| Ação | Resultado esperado | Como saber que passou |
|---|---|---|
| `SELECT count(*) FROM almox.sci;` e `FROM almox.scm;` | total da planta | `viewer` está na lista de visão total das duas |
| `UPDATE almox.sci SET status='em_compra' WHERE codigo='<qualquer>';` | `UPDATE 0` | nenhuma policy de escrita de SCI lista `viewer` |
| `UPDATE almox.scm SET status='aprovada', decidido_por_id=app.usuario_atual() WHERE codigo='<qualquer>';` | `UPDATE 0` | idem |
| `SELECT count(*) FROM util.leitura;` e `FROM util.medidor;` | `0` nos dois | utilidades não lista `viewer` |
| `INSERT INTO util.leitura (...);` | violação de RLS | nem para lançar |
| `SELECT count(*) FROM core.usuario;` | `1` (ele mesmo) | `pol_usuario_select`, ramo do próprio cadastro |
| `SELECT count(*) FROM core.auditoria;` e `FROM core.email_fila;` | `0` nos dois | policies de admin/gestor |
| `SELECT count(*) FROM lms.versao WHERE status='rascunho';` | `0` | `versao_sel` |
| `INSERT INTO almox.sci (..., app.usuario_atual(), 'pendente_aprovacao');` | **hoje passa** | é o item 4 da seção 14: decida se viewer abre solicitação |

### 13.8 Usuário desativado ou bloqueado

Vale para qualquer perfil, e é o teste que mais gente esquece:

| Ação | Resultado esperado | Como saber que passou |
|---|---|---|
| `UPDATE core.usuario SET ativo=false WHERE id='<alvo>';` (como admin), depois virar o alvo e `SELECT count(*) FROM almox.sci;` | `0`, e `INSERT` recusado | `app.usuario_ativo()` e `app.tem_perfil()` já conferem `ativo` e `bloqueado`: desativar na tela corta o acesso na mesma transação, sem esperar novo login |
| virar o alvo desativado e `SELECT count(*) FROM core.grupo;` | `0` | `pol_grupo_select` = `app.usuario_ativo()` |
| `SET LOCAL app.usuario_id = '00000000-0000-0000-0000-000000000000';` e `SELECT count(*) FROM almox.scm;` | `0` | uuid qualquer no GUC não vira acesso |

---

## 14. Pendências — o que este documento promete e o banco ainda não cumpre

Em ordem de risco. Os itens 1 e 2 são os que fazem a diferença entre ter RLS e ter RLS que
funciona no caminho real da tela.

### 14.1 `lms.corrigir_tentativa()` não confere o dono da matrícula (grave)

A função é `SECURITY DEFINER`: roda como dona das tabelas e **RLS não se aplica a ela**. Ela
recebe `p_matricula` e acredita. Hoje, quem trocar o uuid no corpo do POST responde a avaliação de
outra pessoa, grava a nota dela e gera o comprovante dela.

Como é `CREATE OR REPLACE`, a correção é republicar a função de `01-base.sql` com este bloco
inserido logo depois do `BEGIN` do corpo:

```sql
-- Quem chama só corrige a propria matricula. RLS nao alcanca SECURITY DEFINER:
-- a checagem tem de estar escrita aqui dentro.
IF (SELECT m.usuario_id FROM lms.matricula m WHERE m.id = p_matricula)
     IS DISTINCT FROM app.usuario_atual() THEN
  RAISE EXCEPTION 'Matricula de outro usuario' USING ERRCODE = '42501';
END IF;
```

Teste que fecha o item: linha "matrícula de OUTRA pessoa" em 13.6 tem de virar erro.

### 14.2 As views de `app` fora de utilidades ainda ignoram a RLS (grave)

`02d` virou `security_invoker = true` em quatro views (`vw_medidor_apontavel`, `vw_medidor_painel`,
`vw_leitura_historico`, `vw_util_desvio`). As de SCI, SCM e LMS **não**: são do dono do banco e,
sem `security_invoker`, filtram nada. A tela que lê `app.vw_scm` em vez de `almox.scm` devolve a
planta inteira para um técnico.

```sql
-- Views de dado operacional: passam a ser filtradas pelas policies da sessao.
ALTER VIEW app.vw_sci                   SET (security_invoker = true);
ALTER VIEW app.vw_sci_campos            SET (security_invoker = true);
ALTER VIEW app.vw_sci_fila_almoxarifado SET (security_invoker = true);
ALTER VIEW app.vw_sci_pendencia_dado    SET (security_invoker = true);
ALTER VIEW app.vw_scm                   SET (security_invoker = true);
ALTER VIEW app.vw_scm_itens             SET (security_invoker = true);
ALTER VIEW app.vw_scm_fila_aprovacao    SET (security_invoker = true);
ALTER VIEW app.vw_lms_matricula         SET (security_invoker = true);
ALTER VIEW app.vw_lms_conformidade      SET (security_invoker = true);
ALTER VIEW app.vw_lms_visao_lider       SET (security_invoker = true);
ALTER VIEW app.vw_lms_bloqueada         SET (security_invoker = true);
```

**Três views ficam de fora, de propósito:**

| View | Por que continua do dono |
|---|---|
| `app.vw_login_permitido` | é consultada **antes** de existir `app.usuario_id`; com `security_invoker` o login nunca completaria |
| `app.vw_usuario` | é o que monta o menu no primeiro instante da sessão, junto com o provisionamento; virar invoker aqui exige o mesmo cuidado que `core.pode_autenticar()` recebeu em `02b` |
| `app.vw_perfil_permissoes` | catálogo de permissão do próprio perfil; as tabelas de baixo já são `app.usuario_ativo()` |

`app.vw_aprovador_de` e `app.vw_saude_operacional` são **decisão**: com invoker, o líder passa a
ver só o próprio grupo (bom para a tela dele, ruim para o painel de admin). Se as duas coisas forem
necessárias, o caminho é duas views — uma para o painel, do dono, e uma para a tela do líder,
invoker.

### 14.3 Faltam as chaves de permissão das telas que existem

`core.permissao` tem 8 chaves; o menu da seção 3 usa 17 itens. Sem estas 9, PCM e Visualização
entram e não veem quase nada, e Treinamentos não tem chave nenhuma:

```sql
INSERT INTO core.permissao (chave, area, rotulo, descricao, posicao) VALUES
  ('utilidades.apontar',     'utilidades',   'Apontar consumo',        'Lanca leitura de medidor.',                        9),
  ('utilidades.desvios',     'utilidades',   'Apontamentos e desvios', 'Lista mestre de apontamentos e tratativa de desvio.', 10),
  ('utilidades.medidores',   'utilidades',   'Gerir medidores',        'Cadastra, edita e inativa medidor.',               11),
  ('treinamentos.acesso',    'treinamentos', 'Meus treinamentos',      'Estuda e responde avaliacao.',                     12),
  ('treinamentos.visao_grupo','treinamentos','Visao geral de treinamentos', 'Acompanha o treinamento dos liderados.',      13),
  ('treinamentos.gestao',    'treinamentos', 'Gerir treinamentos',     'Cria, publica e atribui treinamento.',             14),
  ('acesso.gestao',          'acesso',       'Gerir acesso',           'Usuarios, perfis, grupos e e-mails autorizados.',  15),
  ('acesso.auditoria',       'acesso',       'Auditoria',              'Le auditoria e saude operacional.',                16),
  ('relatorio.leitura',      'relatorio',    'Leitura de relatorio',   'Le listas sem poder escrever.',                    17)
ON CONFLICT (chave) DO NOTHING;

-- Vinculos que faltam, coerentes com as policies de 02b-02e (e nao com o menu semeado):
INSERT INTO core.perfil_permissao (perfil_id, permissao_chave)
SELECT p.perfil_id, p.chave FROM (VALUES
  ('admin','utilidades.apontar'),      ('admin','utilidades.desvios'),
  ('admin','utilidades.medidores'),    ('admin','treinamentos.acesso'),
  ('admin','treinamentos.visao_grupo'),('admin','treinamentos.gestao'),
  ('admin','acesso.gestao'),           ('admin','acesso.auditoria'),
  ('admin','relatorio.leitura'),
  ('gestor','utilidades.apontar'),     ('gestor','utilidades.desvios'),
  ('gestor','utilidades.medidores'),   ('gestor','treinamentos.acesso'),
  ('gestor','treinamentos.visao_grupo'),('gestor','treinamentos.gestao'),
  ('gestor','acesso.auditoria'),       ('gestor','relatorio.leitura'),
  ('pcm','almoxarifado.acesso'),       ('pcm','almoxarifado.solicitacoes'),
  ('pcm','almoxarifado.scm_acesso'),   ('pcm','almoxarifado.scm_gestao'),
  ('pcm','utilidades.acesso'),         ('pcm','utilidades.apontar'),
  ('pcm','utilidades.desvios'),        ('pcm','utilidades.medidores'),
  ('pcm','treinamentos.acesso'),       ('pcm','relatorio.leitura'),
  ('almoxarife','treinamentos.acesso'),
  ('lider','treinamentos.acesso'),     ('lider','treinamentos.visao_grupo'),
  ('tecnico','utilidades.apontar'),    ('tecnico','treinamentos.acesso'),
  ('viewer','treinamentos.acesso'),    ('viewer','relatorio.leitura')
) AS p(perfil_id, chave)
ON CONFLICT DO NOTHING;
```

Note o que **não** está aí: `lider` não recebe `utilidades.apontar` e `viewer` não recebe
`utilidades.desvios`, porque a RLS de `02d` não os deixa apontar nem ler apontamento (divergências
1 e 2 da seção 3.2). Se o negócio quiser o contrário, muda-se a policy — não a chave.

### 14.4 As cinco divergências da seção 3.2 ainda são decisão de negócio

| # | Decisão | Se a resposta for "sim, pode" |
|---|---|---|
| 1 | `lider` aponta consumo? | somar `'lider'` ao array de `p_leitura_ins_tecnico` em `02d` |
| 2 | `lider` e `viewer` leem a lista mestre de apontamentos? | somar os dois ao array de `p_leitura_sel_pcm` |
| 3 | `pcm` lê auditoria? | somar `'pcm'` a `pol_auditoria_select` |
| 4 | `gestor` lê a fila de e-mail? | somar `'gestor'` a `pol_email_fila_select` — lembrando que corpo de e-mail carrega dado de terceiro |
| 5 | `gestor` edita família de itens? | somar `'gestor'` ao array do laço da seção 2 de `02c` (a mais provável das cinco) |

Cada uma é uma linha de `02b`/`02c`/`02d`, e cada uma tem uma linha correspondente no roteiro da
seção 13 que muda de "nega" para "permite".

### 14.5 `viewer` (e qualquer usuário ativo) consegue abrir SCI e SCM

`sci_ins` e `scm_ins` aceitam qualquer usuário ativo que assine a linha com o próprio id. Para o
técnico isso é o fluxo; para o perfil de leitura, provavelmente não é. Se não for:

```sql
-- acrescentar ao ramo do solicitante nas duas policies (02c):
AND NOT app.tem_perfil(ARRAY['viewer'])
```

### 14.6 A SCM do responsável de grupo não tem quem aprove no fluxo normal

`scm_upd_aprovacao` proíbe aprovar a própria — corretamente. Consequência: quando o solicitante é
o responsável do próprio grupo, a SCM dele fica em `pendente_aprovacao_lider` sem aprovador
possível pelo fluxo, e só sai por `scm_upd_gestao` (gestor ou admin). Mesma coisa para grupo **sem**
responsável: a SCM nasce com `aprovador_origem = 'nenhum'` e `aprovador_email IS NULL`.

Três saídas, em ordem de preferência: (a) cadastrar um aprovador substituto por grupo e ensinar
`app.vw_aprovador_de` a usá-lo; (b) escalar para o responsável da área acima; (c) assumir que
gestor/admin aprovam esses casos, e então **a tela precisa dizer isso**, senão a solicitação fica
parada sem ninguém saber. Enquanto não houver decisão, monitore:

```sql
SELECT codigo, solicitante_nome, criado_em
  FROM almox.scm
 WHERE status = 'pendente_aprovacao_lider' AND aprovador_email IS NULL
 ORDER BY criado_em;

SELECT grupos_sem_responsavel FROM app.vw_saude_operacional;
```

### 14.7 A RLS não desenha a máquina de estados da SCI

`sci_upd_fila` autoriza almoxarife e PCM a mudar o status — **para qualquer valor do enum**,
inclusive de `cadastrado` de volta para `pendente_aprovacao`. As transições legais estão hoje só na
tela. O histórico registra o pulo (`almox.sci_historico`), o que dá auditoria mas não prevenção.
Se isso incomodar, o lugar da regra é um trigger `BEFORE UPDATE` com a tabela de transições
permitidas — não uma policy, porque policy não vê o valor antigo e o novo na mesma expressão de
`WITH CHECK`.

### 14.8 "Aberto" na SCI: decidir se persiste

Ver seção 4, aviso 2. Enquanto for rascunho de navegador, não existe no banco e não precisa de
policy. No dia em que virar valor de enum, precisa das duas coisas: aceitar em `sci_ins` e ser
excluído do filtro da fila do almoxarifado.

### 14.9 Operacional: `FORCE` em `almox.sci`, `almox.scm` e `util.desvio_tratativa`

Com `FORCE`, nem o dono do banco escapa da policy. A importação de `mig` precisa rodar dentro de
uma transação com `SET LOCAL app.usuario_id = '<uuid de um admin>'`, senão o `INSERT` da carga é
recusado — está comentado em `02c`, e é o tipo de detalhe que só aparece no dia da virada. As
tabelas de `util.medidor` e `util.leitura` ficaram **sem** `FORCE` exatamente para a carga passar.

---

## 15. Checklist do dia da virada

Sete linhas, na ordem. Se qualquer uma falhar, pare.

| # | Checagem | Passou quando |
|---|---|---|
| 1 | `01-base.sql` e depois `02a` → `02b` → `02c` → `02d` → `02e`, nesta ordem | `SELECT versao, nome FROM core.migration ORDER BY versao;` lista `0001`, `0002a`…`0002e` |
| 2 | a aplicação conecta como `biotrop_app`, **não** como dono | `SELECT current_user;` na conexão do pool devolve `biotrop_app` |
| 3 | nenhuma role da aplicação com `SUPERUSER`/`BYPASSRLS` | checagem 2 de 13.0 |
| 4 | nenhuma tabela de `core`/`almox`/`util`/`lms` sem RLS | checagem 1 de 13.0 |
| 5 | toda rota abre transação com `SET LOCAL app.usuario_id` | checagem 3 de 13.0 devolve erro, e nenhuma tela em branco no smoke test |
| 6 | itens 14.1 e 14.2 aplicados | `SELECT relname FROM pg_class WHERE relkind='v' AND reloptions::text LIKE '%security_invoker%';` lista as 15 views; e o teste da matrícula de terceiro em 13.6 dá erro |
| 7 | grupos sem responsável resolvidos | `SELECT grupos_sem_responsavel FROM app.vw_saude_operacional;` devolve `0` |

O roteiro da seção 13, rodado inteiro, leva algo entre 40 e 60 minutos com os uuids já
levantados. É o único jeito de dizer "o perfil X não pode Y" e estar certo.
