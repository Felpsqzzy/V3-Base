-- =====================================================================================
-- BIOTROP - migration 0002c: RLS do schema almox (SCI, SCM, itens e familias)
--   Depende de 01-base.sql e 02a-papeis.sql. Idempotente. PostgreSQL 15.
--   Regra geral: uma policy por comando. USING filtra o que a linha JA e; WITH CHECK
--   valida o que a linha VAI SER. INSERT so tem WITH CHECK - e o esquecimento classico
--   que deixa qualquer um gravar linha com solicitante de outra pessoa.
-- =====================================================================================

-- =====================================================================================
-- 1. TRES AUXILIARES DE ALMOX
--   O que 02a nao tem: a SCI e a SCM nao guardam grupo, guardam solicitante_id. A visao
--   do lider sai de core.usuario.grupo_id do solicitante, e repetir esse EXISTS em 15
--   policies e onde nascem as divergencias. SECURITY DEFINER porque core.usuario tem
--   policy propria e a decisao aqui nao pode depender do que o chamador consegue ver.
-- =====================================================================================
-- FURO 7: o "AND app.usuario_ativo()" aqui e cinto e suspensorio, nao redundancia
-- inutil. A correcao de raiz esta em app.grupos_que_lidero() (02a), que agora devolve
-- conjunto vazio para quem esta inativo ou bloqueado - e isso por si so ja torna o
-- EXISTS abaixo falso. A condicao fica explicita porque esta funcao e o vocabulario
-- que 15 policies de almox usam: se alguem um dia reescrever grupos_que_lidero() sem
-- a checagem de sessao, o corte de acesso de quem foi bloqueado nao pode desaparecer
-- em silencio junto. Custo zero no plano: app.usuario_ativo() e STABLE.
CREATE OR REPLACE FUNCTION app.eh_do_meu_grupo(p_usuario_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, pg_temp AS $$
  SELECT app.usuario_ativo()
     AND EXISTS (
    SELECT 1 FROM core.usuario u
     WHERE u.id = p_usuario_id
       AND u.grupo_id IN (SELECT g FROM app.grupos_que_lidero() g)
  );
$$;
COMMENT ON FUNCTION app.eh_do_meu_grupo(uuid) IS 'Verdadeiro se o usuario informado pertence a um grupo em que a sessao e o responsavel direto. Base da visao e da aprovacao do lider: a solicitacao nao tem grupo, quem tem grupo e o solicitante. Desde a correcao do FURO 7 exige app.usuario_ativo(): lider bloqueado ou desligado deixa de ver e de aprovar a SCI/SCM da equipe na mesma hora.';

-- FURO 7 tambem aqui. O ramo de perfil ja estava protegido, porque app.tem_perfil()
-- confere ativo e nao bloqueado; o ramo do PROPRIO solicitante nao conferia nada alem
-- do casamento de id. Sem app.usuario_ativo(), alguem bloqueado continuava editando a
-- propria SCI e os valores de campo dela enquanto a solicitacao estivesse na janela -
-- ou seja, o bloqueio na tela nao chegava a parar de fato quem estava com uma
-- solicitacao em aberto.
CREATE OR REPLACE FUNCTION app.sci_editavel(p_sci_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = almox, core, pg_temp AS $$
  SELECT app.usuario_ativo()
     AND EXISTS (
    SELECT 1 FROM almox.sci s
     WHERE s.id = p_sci_id
       AND ( (s.solicitante_id = app.usuario_atual()
              AND s.status IN ('pendente_aprovacao', 'revisao_solicitante'))
          OR app.tem_perfil(ARRAY['admin', 'gestor', 'almoxarife', 'pcm']) )
  );
$$;
COMMENT ON FUNCTION app.sci_editavel(uuid) IS 'Diz se a SCI pai aceita escrita agora. Usada pelas tabelas filhas (valores de campo) para que elas sigam exatamente a janela da solicitacao: o tecnico mexe enquanto esta montando ou corrigindo, nunca depois de a fila assumir.';

-- FURO 7, mesmo motivo de app.sci_editavel: o ramo do proprio solicitante nao olhava
-- o estado da sessao, e itens, anexos e links da SCM seguiam editaveis por quem tinha
-- sido bloqueado.
CREATE OR REPLACE FUNCTION app.scm_editavel(p_scm_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = almox, core, pg_temp AS $$
  SELECT app.usuario_ativo()
     AND EXISTS (
    SELECT 1 FROM almox.scm s
     WHERE s.id = p_scm_id
       AND ( (s.solicitante_id = app.usuario_atual()
              AND s.status IN ('pendente_aprovacao_lider', 'revisao_solicitada'))
          OR app.tem_perfil(ARRAY['admin', 'gestor'])
          OR (app.tem_perfil(ARRAY['almoxarife', 'pcm'])
              AND s.status IN ('aprovada', 'em_tratativa')) )
  );
$$;
COMMENT ON FUNCTION app.scm_editavel(uuid) IS 'Mesma ideia para a SCM: itens, anexos e links so mudam na janela em que a propria SCM muda. Almoxarife e PCM entram depois de aprovada - antes disso a lista de itens e o que o lider esta analisando.';

-- =====================================================================================
-- 1.1 QUEM PODE SER APROVADOR, E QUEM PODE APROVAR AGORA   (correcao do FURO 2)
--   O furo: aprovador_id nao era amarrado em NENHUM WITH CHECK, e scm_upd_aprovacao
--   aceitava "aprovador_id = app.usuario_atual()" sem exigir perfil nem vinculo de
--   grupo. Com isso o tecnico A abria a SCM apontando o tecnico B como aprovador e B
--   aprovava - dois tecnicos aprovando a compra um do outro, sem lider no caminho.
--   A partir daqui a autoridade de aprovacao nao vem mais do que a aplicacao escreveu
--   na coluna: vem do cadastro (core.grupo.responsavel_id) ou do perfil admin/gestor.
-- =====================================================================================

-- Quem PODE FIGURAR como aprovador desta SCM. Olha o perfil e o grupo da PESSOA
-- APONTADA, nao os da sessao - por isso nao serve app.tem_perfil(), que fala sempre do
-- usuario da sessao. SECURITY DEFINER porque core.usuario e core.grupo tem policy
-- propria e esta decisao nao pode encolher conforme o que o chamador consegue ver.
CREATE OR REPLACE FUNCTION app.scm_aprovador_valido(p_solicitante_id uuid, p_aprovador_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, pg_temp AS $$
  SELECT CASE
    -- Sem aprovador apontado a linha nao concede aprovacao a ninguem. E como nasce a
    -- SCM de quem esta em grupo sem responsavel (origem 'excecao'/'nenhum' em
    -- app.vw_aprovador_de): ela so avanca por responsavel de grupo ou por admin/gestor.
    WHEN p_aprovador_id IS NULL THEN true
    -- Ninguem aprova a propria compra, nem se a aplicacao mandar a linha assim.
    WHEN p_aprovador_id = p_solicitante_id THEN false
    ELSE EXISTS (
      SELECT 1
        FROM core.usuario a
       WHERE a.id = p_aprovador_id
         AND a.ativo AND NOT a.bloqueado
         AND ( -- gestao aprova qualquer solicitacao, por definicao do perfil
               a.perfil_id IN ('admin', 'gestor')
               -- ou e o responsavel direto do grupo de quem pediu: a regra do negocio
            OR EXISTS (SELECT 1
                         FROM core.usuario s
                         JOIN core.grupo   g ON g.id = s.grupo_id AND g.ativo
                        WHERE s.id = p_solicitante_id
                          AND g.responsavel_id = a.id) ) )
  END;
$$;
COMMENT ON FUNCTION app.scm_aprovador_valido(uuid, uuid) IS 'Definicao unica de quem pode figurar como aprovador de uma SCM: o responsavel direto do grupo do solicitante, ou admin/gestor, sempre ativo e nao bloqueado, e nunca o proprio solicitante. Usada nos WITH CHECK de INSERT e UPDATE de almox.scm (FURO 2).';

-- Quem pode DECIDIR a SCM nesta sessao. Exige as tres coisas que faltavam: vinculo
-- (grupo ou gestao), que nao seja o proprio solicitante, e que o aprovador congelado
-- na linha ainda seja um aprovador legitimo. Consequencia assumida: se o responsavel
-- do grupo trocar, a fila passa para o novo responsavel - o antigo deixa de decidir, e
-- admin/gestor destravam o que ficou no meio do caminho. Congelar aprovador_email
-- continua servindo de rotulo e de destinatario do aviso, nao de permissao.
CREATE OR REPLACE FUNCTION app.scm_pode_aprovar(p_solicitante_id uuid, p_aprovador_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, pg_temp AS $$
  SELECT app.usuario_ativo()
     -- ninguem decide a propria solicitacao
     AND p_solicitante_id IS DISTINCT FROM app.usuario_atual()
     -- viewer e perfil de leitura: nao decide nada, mesmo que alguem o aponte
     AND NOT app.tem_perfil(ARRAY['viewer'])
     AND ( app.tem_perfil(ARRAY['admin', 'gestor'])
        OR ( app.eh_do_meu_grupo(p_solicitante_id)
             AND app.scm_aprovador_valido(p_solicitante_id, app.usuario_atual()) )
        OR ( p_aprovador_id = app.usuario_atual()
             AND app.scm_aprovador_valido(p_solicitante_id, p_aprovador_id) ) );
$$;
COMMENT ON FUNCTION app.scm_pode_aprovar(uuid, uuid) IS 'Verdadeiro se o usuario da sessao pode decidir a SCM de p_solicitante_id cujo aprovador congelado e p_aprovador_id. Substitui a condicao antiga "aprovador_id = app.usuario_atual()", que aceitava qualquer pessoa apontada na coluna - inclusive outro tecnico (FURO 2).';

GRANT EXECUTE ON FUNCTION app.eh_do_meu_grupo(uuid), app.sci_editavel(uuid),
  app.scm_editavel(uuid), app.scm_aprovador_valido(uuid, uuid),
  app.scm_pode_aprovar(uuid, uuid) TO biotrop_app, biotrop_ro;

-- =====================================================================================
-- 2. FAMILIAS, CAMPOS E CENTROS DE CUSTO
--   Leitura para qualquer usuario ativo (sem elas o formulario da SCI nao se monta).
--   Escrita so almoxarife e admin. Sem FORCE: as listas sao semeadas pelo dono do banco
--   (secao 15 da base e a importacao do mig), e forcar aqui pararia o deploy.
-- =====================================================================================
DO $$
DECLARE v_tab text;
BEGIN
  FOREACH v_tab IN ARRAY ARRAY['familia', 'familia_campo', 'centro_custo'] LOOP
    EXECUTE format('ALTER TABLE almox.%I ENABLE ROW LEVEL SECURITY', v_tab);
    EXECUTE format('DROP POLICY IF EXISTS %I ON almox.%I', v_tab || '_sel', v_tab);
    EXECUTE format('CREATE POLICY %I ON almox.%I FOR SELECT USING (app.usuario_ativo())',
                   v_tab || '_sel', v_tab);
    EXECUTE format('DROP POLICY IF EXISTS %I ON almox.%I', v_tab || '_ins', v_tab);
    EXECUTE format('CREATE POLICY %I ON almox.%I FOR INSERT
                      WITH CHECK (app.tem_perfil(ARRAY[''almoxarife'', ''admin'']))',
                   v_tab || '_ins', v_tab);
    EXECUTE format('DROP POLICY IF EXISTS %I ON almox.%I', v_tab || '_upd', v_tab);
    EXECUTE format('CREATE POLICY %I ON almox.%I FOR UPDATE
                      USING      (app.tem_perfil(ARRAY[''almoxarife'', ''admin'']))
                      WITH CHECK (app.tem_perfil(ARRAY[''almoxarife'', ''admin'']))',
                   v_tab || '_upd', v_tab);
    -- Apagar e diferente de escrever: SCI e SCM antigas apontam para estas linhas.
    -- DELETE fica com o admin; o caminho normal continua sendo marcar ativo = false.
    EXECUTE format('DROP POLICY IF EXISTS %I ON almox.%I', v_tab || '_del', v_tab);
    EXECUTE format('CREATE POLICY %I ON almox.%I FOR DELETE USING (app.eh_admin())',
                   v_tab || '_del', v_tab);
  END LOOP;
END $$;

-- =====================================================================================
-- 3. SCI
--   FORCE porque a SCI e o registro que precisa valer tambem para o dono do banco.
--   Consequencia operacional assumida: a importacao do mig roda em transacao com
--   SET LOCAL app.usuario_id = '<uuid de um admin>' - o admin passa pelas policies de
--   INSERT abaixo e o historico continua nascendo com autor.
-- =====================================================================================
ALTER TABLE almox.sci ENABLE ROW LEVEL SECURITY;
ALTER TABLE almox.sci FORCE  ROW LEVEL SECURITY;

-- Tecnico ve a dele; lider ve as do grupo dele; fila e gestao veem tudo.
DROP POLICY IF EXISTS sci_sel ON almox.sci;
CREATE POLICY sci_sel ON almox.sci FOR SELECT USING (
  app.usuario_ativo()
  AND ( app.tem_perfil(ARRAY['admin', 'gestor', 'pcm', 'almoxarife', 'viewer'])
     OR solicitante_id = app.usuario_atual()
     OR app.eh_do_meu_grupo(solicitante_id) )
);

-- Abrir SCI e por conta propria e sempre no primeiro status: sem WITH CHECK aqui
-- qualquer perfil gravaria solicitacao no nome de outro e ja em cadastrado.
DROP POLICY IF EXISTS sci_ins ON almox.sci;
CREATE POLICY sci_ins ON almox.sci FOR INSERT WITH CHECK (
  app.tem_perfil(ARRAY['admin', 'gestor'])
  OR ( app.usuario_ativo()
       AND solicitante_id = app.usuario_atual()
       AND status = 'pendente_aprovacao' )
);

-- Reenvio do solicitante: so na janela de revisao, e so devolvendo para a fila.
DROP POLICY IF EXISTS sci_upd_solicitante ON almox.sci;
CREATE POLICY sci_upd_solicitante ON almox.sci FOR UPDATE
  USING      ( solicitante_id = app.usuario_atual()
               AND app.usuario_ativo()
               AND status = 'revisao_solicitante' )
  WITH CHECK ( solicitante_id = app.usuario_atual()
               AND status IN ('revisao_solicitante', 'pendente_aprovacao') );

-- Fila do almoxarifado e PCM: muda status da SCI, menos na propria solicitacao.
-- A negacao esta no USING e no WITH CHECK, nao so no trigger: policy nao se esquece.
DROP POLICY IF EXISTS sci_upd_fila ON almox.sci;
CREATE POLICY sci_upd_fila ON almox.sci FOR UPDATE
  USING      ( app.tem_perfil(ARRAY['almoxarife', 'pcm'])
               AND solicitante_id IS DISTINCT FROM app.usuario_atual() )
  WITH CHECK ( app.tem_perfil(ARRAY['almoxarife', 'pcm'])
               AND solicitante_id IS DISTINCT FROM app.usuario_atual() );

DROP POLICY IF EXISTS sci_upd_gestao ON almox.sci;
CREATE POLICY sci_upd_gestao ON almox.sci FOR UPDATE
  USING      ( app.tem_perfil(ARRAY['admin', 'gestor'])
               AND solicitante_id IS DISTINCT FROM app.usuario_atual() )
  WITH CHECK ( app.tem_perfil(ARRAY['admin', 'gestor'])
               AND solicitante_id IS DISTINCT FROM app.usuario_atual() );

DROP POLICY IF EXISTS sci_del ON almox.sci;
CREATE POLICY sci_del ON almox.sci FOR DELETE USING (app.eh_admin());

-- 3.1 valores dos campos dinamicos ---------------------------------------------------
-- SELECT por EXISTS na SCI: a subconsulta tambem obedece a policy de almox.sci, entao
-- filho visivel se e somente se o pai e visivel - uma regra, nao duas.
ALTER TABLE almox.sci_valor_campo ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sci_valor_sel ON almox.sci_valor_campo;
CREATE POLICY sci_valor_sel ON almox.sci_valor_campo FOR SELECT USING (EXISTS (SELECT 1 FROM almox.sci s WHERE s.id = sci_id));
DROP POLICY IF EXISTS sci_valor_ins ON almox.sci_valor_campo;
CREATE POLICY sci_valor_ins ON almox.sci_valor_campo FOR INSERT WITH CHECK (app.sci_editavel(sci_id));
DROP POLICY IF EXISTS sci_valor_upd ON almox.sci_valor_campo;
CREATE POLICY sci_valor_upd ON almox.sci_valor_campo FOR UPDATE USING (app.sci_editavel(sci_id)) WITH CHECK (app.sci_editavel(sci_id));
DROP POLICY IF EXISTS sci_valor_del ON almox.sci_valor_campo;
CREATE POLICY sci_valor_del ON almox.sci_valor_campo FOR DELETE USING (app.sci_editavel(sci_id));

-- 3.2 historico ----------------------------------------------------------------------
-- Append-only por ausencia de policy: sem policy de UPDATE e de DELETE, RLS nega.
-- FORCE para que nem o dono reescreva a timeline. O INSERT vem do trigger
-- almox.fn_sci_transicao(), que roda como o chamador - por isso precisa de policy.
ALTER TABLE almox.sci_historico ENABLE ROW LEVEL SECURITY;
ALTER TABLE almox.sci_historico FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sci_hist_sel ON almox.sci_historico;
CREATE POLICY sci_hist_sel ON almox.sci_historico FOR SELECT USING (EXISTS (SELECT 1 FROM almox.sci s WHERE s.id = sci_id));
DROP POLICY IF EXISTS sci_hist_ins ON almox.sci_historico;
CREATE POLICY sci_hist_ins ON almox.sci_historico FOR INSERT WITH CHECK (app.usuario_ativo());

-- =====================================================================================
-- 4. SCM
--   O aprovador fica congelado na linha (aprovador_id/aprovador_email). A policy aceita
--   os dois caminhos: o aprovador congelado e o responsavel atual do grupo de quem
--   pediu - troca de lider no meio do fluxo nao pode esconder a solicitacao.
-- =====================================================================================
ALTER TABLE almox.scm ENABLE ROW LEVEL SECURITY;
ALTER TABLE almox.scm FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS scm_sel ON almox.scm;
CREATE POLICY scm_sel ON almox.scm FOR SELECT USING (
  app.usuario_ativo()
  AND ( app.tem_perfil(ARRAY['admin', 'gestor', 'pcm', 'almoxarife', 'viewer'])
     OR solicitante_id = app.usuario_atual()
     OR aprovador_id   = app.usuario_atual()
     OR app.eh_do_meu_grupo(solicitante_id) )
);

DROP POLICY IF EXISTS scm_ins ON almox.scm;
CREATE POLICY scm_ins ON almox.scm FOR INSERT WITH CHECK (
  -- quem pode gravar a linha
  ( app.tem_perfil(ARRAY['admin', 'gestor'])
    OR ( app.usuario_ativo()
         AND solicitante_id = app.usuario_atual()
         AND status = 'pendente_aprovacao_lider' ) )
  AND (
    -- Importacao do historico: roda com SET LOCAL app.usuario_id de um admin e traz
    -- aprovador e decisao como estavam no localStorage, gente que hoje pode nem ser
    -- mais responsavel de grupo. Fica fora das duas amarras abaixo, e SO com origem_id
    -- preenchido e perfil admin - a role da aplicacao nao compra essa isencao.
    ( origem_id IS NOT NULL AND app.eh_admin() )
    OR (
      -- FURO 2: o aprovador da linha tem de ser o responsavel direto do grupo de quem
      -- pediu (ou admin/gestor) e nunca o proprio solicitante. Sem isto, quem abre a
      -- SCM escolhia o proprio aprovador - era so apontar um colega tecnico.
      app.scm_aprovador_valido(solicitante_id, aprovador_id)
      -- FURO 8: solicitacao nao nasce decidida. As colunas da decisao entram vazias e
      -- so quem decide as escreve (ver trigger tg_scm_decisao_imutavel).
      AND decidido_por_id IS NULL
      AND decidido_em IS NULL
      AND nullif(btrim(observacao_lider), '') IS NULL
    )
  )
);

-- Solicitante corrige o que o lider devolveu e reenvia para a aprovacao.
DROP POLICY IF EXISTS scm_upd_solicitante ON almox.scm;
CREATE POLICY scm_upd_solicitante ON almox.scm FOR UPDATE
  USING      ( solicitante_id = app.usuario_atual()
               AND app.usuario_ativo()
               AND status = 'revisao_solicitada' )
  WITH CHECK ( solicitante_id = app.usuario_atual()
               AND status IN ('revisao_solicitada', 'pendente_aprovacao_lider')
               -- FURO 2: o reenvio nao troca o aprovador por um colega de confianca.
               -- Sem esta linha o tecnico reprovado reapontava aprovador_id e voltava
               -- a solicitacao para a fila de quem ele quisesse.
               AND app.scm_aprovador_valido(solicitante_id, aprovador_id)
               -- FURO 8: o solicitante nao assina decisao nenhuma. Quando a linha
               -- volta para pendente_aprovacao_lider, o trigger
               -- almox.fn_scm_decisao_imutavel() zera a decisao anterior; as tres
               -- colunas chegam aqui nulas e ele nao consegue preenche-las.
               AND decidido_por_id IS DISTINCT FROM app.usuario_atual() );

-- Aprovacao do lider. FURO 2: a condicao antiga aceitava "aprovador_id =
-- app.usuario_atual()" isolado, isto e, bastava ESTAR APONTADO na coluna para poder
-- decidir - e quem apontava era o solicitante, no INSERT. Agora quem decide precisa
-- passar por app.scm_pode_aprovar(): perfil admin/gestor, ou ser o responsavel direto
-- do grupo de quem pediu; nunca o proprio solicitante; nunca viewer; e o aprovador
-- congelado na linha tambem tem de ser um aprovador legitimo.
-- O WITH CHECK repete a condicao porque WITH CHECK e o que vale sobre a linha NOVA:
-- so no USING, um UPDATE que mexesse em solicitante_id/aprovador_id escaparia.
DROP POLICY IF EXISTS scm_upd_aprovacao ON almox.scm;
CREATE POLICY scm_upd_aprovacao ON almox.scm FOR UPDATE
  USING      ( status = 'pendente_aprovacao_lider'
               AND app.scm_pode_aprovar(solicitante_id, aprovador_id) )
  WITH CHECK ( solicitante_id IS DISTINCT FROM app.usuario_atual()
               AND status IN ('aprovada', 'reprovada', 'revisao_solicitada')
               AND app.scm_pode_aprovar(solicitante_id, aprovador_id)
               -- FURO 8: a decisao sai assinada por quem esta decidindo, e com hora.
               -- decidido_em e reescrito com now() pelo trigger, entao aqui basta
               -- exigir que nao venha nulo.
               AND decidido_por_id = app.usuario_atual()
               AND decidido_em IS NOT NULL );

-- Almoxarife e PCM tratam o que ja foi aprovado. Nao alcancam
-- pendente_aprovacao_lider: aprovar e do responsavel do grupo, nao da fila.
-- FURO 8: a fila nao mexe na decisao. Ela nao pode aparecer como quem decidiu
-- (segregacao de funcao: quem aprovou a compra nao e quem a executa) e nao pode
-- esvaziar a assinatura da linha. A imutabilidade do trio decidido_por_id/decidido_em/
-- observacao_lider e do trigger - policy nao ve OLD, so ve a linha nova.
DROP POLICY IF EXISTS scm_upd_tratativa ON almox.scm;
CREATE POLICY scm_upd_tratativa ON almox.scm FOR UPDATE
  USING      ( app.tem_perfil(ARRAY['almoxarife', 'pcm'])
               AND status IN ('aprovada', 'em_tratativa')
               AND solicitante_id IS DISTINCT FROM app.usuario_atual() )
  WITH CHECK ( app.tem_perfil(ARRAY['almoxarife', 'pcm'])
               AND status IN ('aprovada', 'em_tratativa', 'concluida')
               AND solicitante_id IS DISTINCT FROM app.usuario_atual()
               AND decidido_por_id IS DISTINCT FROM app.usuario_atual()
               -- historico importado nao tem quem decidiu; o backlog migrado precisa
               -- continuar andando na fila
               AND ( origem_id IS NOT NULL
                  OR (decidido_por_id IS NOT NULL AND decidido_em IS NOT NULL) ) );

-- FURO 8: gestao corrige a solicitacao, mas nao reescreve nem apaga a decisao de
-- outra pessoa. Aqui a policy garante que a assinatura nao desaparece; quem decidiu
-- fica travado pelo trigger. Admin/gestor tambem podem SER quem decide - nesse caso o
-- trigger exige decidido_por_id = usuario da sessao, como para qualquer lider.
DROP POLICY IF EXISTS scm_upd_gestao ON almox.scm;
CREATE POLICY scm_upd_gestao ON almox.scm FOR UPDATE
  USING      ( app.tem_perfil(ARRAY['admin', 'gestor'])
               AND solicitante_id IS DISTINCT FROM app.usuario_atual() )
  WITH CHECK ( app.tem_perfil(ARRAY['admin', 'gestor'])
               AND solicitante_id IS DISTINCT FROM app.usuario_atual()
               -- linha importada carrega aprovador e decisao legados: fica fora das
               -- duas amarras, como no INSERT
               AND ( origem_id IS NOT NULL
                  OR ( -- FURO 2 tambem no caminho da gestao: nem admin/gestor
                       -- redirecionam a aprovacao para um terceiro qualquer
                       app.scm_aprovador_valido(solicitante_id, aprovador_id)
                       AND ( status NOT IN ('aprovada', 'reprovada', 'revisao_solicitada',
                                            'em_tratativa', 'concluida')
                          OR (decidido_por_id IS NOT NULL AND decidido_em IS NOT NULL) ) ) ) );

DROP POLICY IF EXISTS scm_del ON almox.scm;
CREATE POLICY scm_del ON almox.scm FOR DELETE USING (app.eh_admin());

-- 4.0 A DECISAO E IMUTAVEL   (correcao do FURO 8) ------------------------------------
--   O furo: scm_upd_tratativa e scm_upd_gestao nao prendiam decidido_por_id,
--   decidido_em nem observacao_lider. O almoxarife podia gravar uma aprovacao no nome
--   do lider, reescrever a devolutiva depois do fato ou antedatar a decisao - e esse
--   trio e exatamente a resposta de auditoria para "quem aprovou essa compra?".
--
--   Por que trigger e nao policy: WITH CHECK so ve a linha NOVA. Nao existe OLD numa
--   policy, entao "esta coluna nao mudou" e indizivel ali.
--   Por que trigger e nao GRANT por coluna: privilegio e por ROLE, e a role e uma so
--   (biotrop_app) para todas as pessoas. Revogar UPDATE(decidido_por_id) da aplicacao
--   tiraria a coluna tambem do lider legitimo, que precisa escrever uma vez.
--
--   Trigger na migration de RLS, e nao em 01-base.sql: 01 ja foi aplicada, migration
--   aplicada nao se reescreve. Ele nasce BEFORE UPDATE e antes de tg_touch_scm na
--   ordem alfabetica, o que nao muda nada porque as colunas nao se cruzam.
CREATE OR REPLACE FUNCTION almox.fn_scm_decisao_imutavel() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_sessao uuid;
BEGIN
  v_sessao := nullif(current_setting('app.usuario_id', true), '')::uuid;

  -- Reimportacao do historico pelo dono do banco: o upsert de mig.importar_scm
  -- reescreve observacao_lider de linha antiga e nao tem como assinar a decisao de
  -- 2023. Sai antes das amarras, e so quando a linha veio de fora, continua com o
  -- mesmo origem_id e quem executa NAO e uma role de cliente. O schema mig ja e
  -- inacessivel a biotrop_app, entao esta porta nao existe para a aplicacao.
  IF NEW.origem_id IS NOT NULL
     AND OLD.origem_id IS NOT DISTINCT FROM NEW.origem_id
     AND current_user NOT IN ('biotrop_app', 'biotrop_ro') THEN
    RETURN NEW;
  END IF;

  -- 1) Volta para a fila do lider (devolucao ao solicitante que foi reenviada, ou
  --    reabertura pela gestao): a decisao anterior e APAGADA aqui, pelo banco. E o
  --    unico caminho em que o trio muda sem ser uma decisao nova - e quem apaga nao e
  --    o solicitante: ele nao escreve nessas colunas em nenhuma hipotese.
  IF NEW.status = 'pendente_aprovacao_lider'
     AND OLD.status IS DISTINCT FROM 'pendente_aprovacao_lider' THEN
    NEW.decidido_por_id  := NULL;
    NEW.decidido_em      := NULL;
    NEW.observacao_lider := NULL;
    RETURN NEW;
  END IF;

  -- 2) Decisao ja gravada: congelada. Nem a fila, nem a gestao, nem o proprio lider
  --    reescrevem quem decidiu, quando decidiu e a devolutiva. Para decidir de novo,
  --    a SCM volta para pendente_aprovacao_lider (caso 1) e a decisao renasce limpa.
  IF OLD.decidido_por_id IS NOT NULL OR OLD.decidido_em IS NOT NULL THEN
    IF NEW.decidido_por_id     IS DISTINCT FROM OLD.decidido_por_id
       OR NEW.decidido_em      IS DISTINCT FROM OLD.decidido_em
       OR NEW.observacao_lider IS DISTINCT FROM OLD.observacao_lider THEN
      RAISE EXCEPTION
        'Decisao da SCM % ja registrada (por % em %): decidido_por_id, decidido_em e observacao_lider sao imutaveis. Para decidir de novo, devolva a SCM para pendente_aprovacao_lider.',
        OLD.codigo, OLD.decidido_por_id, OLD.decidido_em
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN NEW;
  END IF;

  -- 3) Decisao nascendo agora: so quem esta na sessao assina, e a hora e do servidor.
  --    Compara com OLD para nao atrapalhar quem apenas edita outras colunas de uma
  --    linha importada que ja veio com devolutiva e sem decidido_por_id.
  IF NEW.decidido_por_id     IS DISTINCT FROM OLD.decidido_por_id
     OR NEW.decidido_em      IS DISTINCT FROM OLD.decidido_em
     OR NEW.observacao_lider IS DISTINCT FROM OLD.observacao_lider THEN
    IF v_sessao IS NULL THEN
      RAISE EXCEPTION 'Decisao de SCM sem identidade de sessao: a aplicacao precisa executar SET LOCAL app.usuario_id antes do UPDATE'
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NEW.decidido_por_id IS DISTINCT FROM v_sessao THEN
      RAISE EXCEPTION
        'A decisao da SCM % tem de ser assinada por quem esta decidindo: decidido_por_id deveria ser %, veio %',
        NEW.codigo, v_sessao, NEW.decidido_por_id
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    -- data da decisao e do relogio do servidor, nunca do payload da tela
    NEW.decidido_em := now();
  END IF;

  RETURN NEW;
END $$;
COMMENT ON FUNCTION almox.fn_scm_decisao_imutavel() IS 'FURO 8: prende decidido_por_id, decidido_em e observacao_lider. A decisao sai assinada por quem esta na sessao, com hora do servidor, e depois de gravada e imutavel - so volta a ser gravavel se a SCM retornar para pendente_aprovacao_lider, e nesse caminho o proprio trigger limpa as tres colunas. Policy nao alcanca isso porque WITH CHECK nao ve OLD.';

DROP TRIGGER IF EXISTS tg_scm_decisao_imutavel ON almox.scm;
CREATE TRIGGER tg_scm_decisao_imutavel BEFORE UPDATE ON almox.scm
  FOR EACH ROW EXECUTE FUNCTION almox.fn_scm_decisao_imutavel();

-- 4.1 itens, anexos e links ----------------------------------------------------------
-- As tres tabelas filhas tem exatamente a mesma regra (visivel com o pai, gravavel na
-- janela do pai). Escrever em laco em vez de copiar 12 policies evita a copia que um dia
-- fica com a condicao velha - o motivo classico de uma tabela filha vazar sozinha.
DO $$
DECLARE v_tab text;
BEGIN
  FOREACH v_tab IN ARRAY ARRAY['scm_item', 'scm_anexo', 'scm_link'] LOOP
    EXECUTE format('ALTER TABLE almox.%I ENABLE ROW LEVEL SECURITY', v_tab);
    EXECUTE format('DROP POLICY IF EXISTS %I ON almox.%I', v_tab || '_sel', v_tab);
    EXECUTE format('CREATE POLICY %I ON almox.%I FOR SELECT
                      USING (EXISTS (SELECT 1 FROM almox.scm s WHERE s.id = scm_id))',
                   v_tab || '_sel', v_tab);
    EXECUTE format('DROP POLICY IF EXISTS %I ON almox.%I', v_tab || '_ins', v_tab);
    EXECUTE format('CREATE POLICY %I ON almox.%I FOR INSERT
                      WITH CHECK (app.scm_editavel(scm_id))', v_tab || '_ins', v_tab);
    EXECUTE format('DROP POLICY IF EXISTS %I ON almox.%I', v_tab || '_upd', v_tab);
    EXECUTE format('CREATE POLICY %I ON almox.%I FOR UPDATE
                      USING (app.scm_editavel(scm_id))
                      WITH CHECK (app.scm_editavel(scm_id))', v_tab || '_upd', v_tab);
    EXECUTE format('DROP POLICY IF EXISTS %I ON almox.%I', v_tab || '_del', v_tab);
    EXECUTE format('CREATE POLICY %I ON almox.%I FOR DELETE
                      USING (app.scm_editavel(scm_id))', v_tab || '_del', v_tab);
  END LOOP;
END $$;

-- 4.2 historico da aprovacao ---------------------------------------------------------
-- E a resposta para "quem aprovou essa compra?": append-only e com FORCE, porque um
-- log que o dono edita nao responde nada.
ALTER TABLE almox.scm_historico ENABLE ROW LEVEL SECURITY;
ALTER TABLE almox.scm_historico FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS scm_hist_sel ON almox.scm_historico;
CREATE POLICY scm_hist_sel ON almox.scm_historico FOR SELECT USING (EXISTS (SELECT 1 FROM almox.scm s WHERE s.id = scm_id));
DROP POLICY IF EXISTS scm_hist_ins ON almox.scm_historico;
CREATE POLICY scm_hist_ins ON almox.scm_historico FOR INSERT WITH CHECK (app.usuario_ativo());

-- =====================================================================================
-- 5. CONFERENCIA
--   Uma tabela de almox sem RLS ligado e um vazamento silencioso: para o deploy.
-- =====================================================================================
DO $$
DECLARE v_falta text;
BEGIN
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO v_falta
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'almox' AND c.relkind = 'r' AND NOT c.relrowsecurity;
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION 'Tabela de almox sem RLS habilitado: %', v_falta;
  END IF;
END $$;

-- =====================================================================================
-- 6. REGISTRO DESTA MIGRATION
-- =====================================================================================
INSERT INTO core.migration (versao, nome, observacao) VALUES
  ('0002c', 'rls-almox',
   'RLS de almox: SCI e SCM com policy por comando, tecnico so na propria solicitacao (reenvio apenas em revisao do solicitante), lider no grupo que lidera, almoxarife/PCM na fila sem alcancar a aprovacao do lider, ninguem decide a propria solicitacao (no USING e no WITH CHECK), familias e centros de custo com escrita de almoxarife e admin. FORCE em sci, scm e nos dois historicos - a importacao do mig precisa rodar com SET LOCAL app.usuario_id de um admin. Correcoes da revisao adversarial: FURO 2 - aprovador_id amarrado por app.scm_aprovador_valido() nos WITH CHECK de INSERT/UPDATE (so responsavel direto do grupo do solicitante ou admin/gestor, nunca o proprio solicitante) e aprovacao passando por app.scm_pode_aprovar() em vez de aceitar quem estiver apontado na coluna; FURO 7 - app.eh_do_meu_grupo, app.sci_editavel e app.scm_editavel passaram a exigir app.usuario_ativo(): o ramo de perfil ja estava coberto por app.tem_perfil, mas os ramos de lideranca e de proprio solicitante nao olhavam o estado da sessao, e quem era bloqueado seguia lendo a fila da equipe e editando a propria solicitacao; FURO 8 - trigger tg_scm_decisao_imutavel congela decidido_por_id, decidido_em e observacao_lider, exige assinatura do usuario da sessao e hora do servidor, e as policies de tratativa e gestao deixaram de aceitar linha com a assinatura da decisao esvaziada ou apontando quem nao decidiu.')
ON CONFLICT (versao) DO NOTHING;
