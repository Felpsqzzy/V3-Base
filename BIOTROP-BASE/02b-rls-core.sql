-- =====================================================================================
-- BIOTROP - migration 0002b: RLS do schema core
--   Depende de 01-base.sql e 02a-papeis.sql. Idempotente. PostgreSQL 15.
--   Usa app.usuario_atual(), app.usuario_ativo(), app.tem_perfil(text[]), app.eh_admin()
--   e app.grupos_que_lidero() - nenhuma policy repete subconsulta de perfil.
--
--   Regras desta migration:
--     leitura      - cada um le o proprio cadastro; responsavel de grupo le quem esta
--                    nos grupos dele; gestor e admin leem tudo.
--     escrita      - usuario, perfil, permissao, perfil_permissao e email_autorizado
--                    somente admin.
--     append-only  - auditoria e login_evento: INSERT sim, UPDATE/DELETE nunca.
--     fila de mail - a aplicacao enfileira e marca entrega; nenhum usuario le a fila.
--
--   FORCE ROW LEVEL SECURITY entra apenas em auditoria e login_evento: ali a regra vale
--   inclusive para o dono das tabelas (log que o dono reescreve nao e log). Nas outras o
--   dono continua fora do RLS de proposito, porque e ele que roda o deploy e a importacao
--   do schema mig, sem identidade de usuario na sessao. Superuser ignora RLS sempre -
--   por isso as roles biotrop_app e biotrop_ro sao NOSUPERUSER NOBYPASSRLS em 02a.
--
--   CREATE POLICY nao tem IF NOT EXISTS: cada policy vem com DROP POLICY IF EXISTS antes,
--   para o arquivo poder ser reaplicado.
-- =====================================================================================

-- =====================================================================================
-- 1. core.usuario
--   Escrita e so de admin. Consequencia: provisionamento no primeiro acesso e
--   ultimo_login_em nao passam por aqui.
--
--   CORRECAO DO FURO 9: isto estava escrito como "consequencia conhecida e aceita",
--   com a funcao SECURITY DEFINER "a ser criada com o fluxo de login". Ela nunca foi
--   criada, e sem ela o sistema nao tinha primeiro acesso nenhum - nem para o primeiro
--   admin, que por definicao nao pode ser cadastrado por um admin. A funcao existe
--   agora: core.provisionar_acesso(), na secao 9.1 deste arquivo. As policies abaixo
--   ficam como estao de proposito - a excecao do primeiro acesso e um caminho unico,
--   nomeado e auditado, e nao um afrouxamento da regra de quem edita cadastro.
--   Preferencias de tela (tema, notificacoes) continuam de fora: quando entrarem, o
--   lugar e uma policy propria de UPDATE amarrada a id = app.usuario_atual() com GRANT
--   por coluna, nunca alargar pol_usuario_update.
-- =====================================================================================
ALTER TABLE core.usuario ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pol_usuario_select ON core.usuario;
CREATE POLICY pol_usuario_select ON core.usuario FOR SELECT
  USING (
    app.usuario_ativo()
    AND (
      id = app.usuario_atual()                        -- o proprio cadastro
      OR app.tem_perfil(ARRAY['admin','gestor'])      -- visao total
      OR grupo_id IN (SELECT app.grupos_que_lidero()) -- quem esta nos meus grupos
    )
  );

DROP POLICY IF EXISTS pol_usuario_insert ON core.usuario;
CREATE POLICY pol_usuario_insert ON core.usuario FOR INSERT
  WITH CHECK (app.eh_admin());

DROP POLICY IF EXISTS pol_usuario_update ON core.usuario;
CREATE POLICY pol_usuario_update ON core.usuario FOR UPDATE
  USING (app.eh_admin())
  WITH CHECK (app.eh_admin());   -- sem WITH CHECK, admin poderia gravar linha que nao veria

DROP POLICY IF EXISTS pol_usuario_delete ON core.usuario;
CREATE POLICY pol_usuario_delete ON core.usuario FOR DELETE
  USING (app.eh_admin());

-- =====================================================================================
-- 2. core.grupo
--   Todo usuario ativo le a lista de grupos: e ela que preenche seletor de time, alvo de
--   treinamento e nome do aprovador. Estrutura organizacional nao e dado sensivel.
--   Mexer no grupo (e portanto no responsavel que aprova SCM) e admin ou gestor.
-- =====================================================================================
ALTER TABLE core.grupo ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pol_grupo_select ON core.grupo;
CREATE POLICY pol_grupo_select ON core.grupo FOR SELECT
  USING (app.usuario_ativo());

DROP POLICY IF EXISTS pol_grupo_insert ON core.grupo;
CREATE POLICY pol_grupo_insert ON core.grupo FOR INSERT
  WITH CHECK (app.tem_perfil(ARRAY['admin','gestor']));

DROP POLICY IF EXISTS pol_grupo_update ON core.grupo;
CREATE POLICY pol_grupo_update ON core.grupo FOR UPDATE
  USING (app.tem_perfil(ARRAY['admin','gestor']))
  WITH CHECK (app.tem_perfil(ARRAY['admin','gestor']));

DROP POLICY IF EXISTS pol_grupo_delete ON core.grupo;
CREATE POLICY pol_grupo_delete ON core.grupo FOR DELETE
  USING (app.eh_admin());   -- apagar grupo desliga aprovador: so admin

-- =====================================================================================
-- 3. core.perfil, core.permissao, core.perfil_permissao
--   Catalogo de acesso: leitura aberta a usuario ativo (a tela precisa saber o que o
--   proprio perfil permite), escrita exclusiva de admin. As triggers tg_perfil_fixo e
--   tg_perfil_permissao_fixo continuam protegendo o perfil admin ate do proprio admin.
-- =====================================================================================
ALTER TABLE core.perfil           ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.permissao        ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.perfil_permissao ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pol_perfil_select ON core.perfil;
CREATE POLICY pol_perfil_select ON core.perfil FOR SELECT
  USING (app.usuario_ativo());

DROP POLICY IF EXISTS pol_perfil_insert ON core.perfil;
CREATE POLICY pol_perfil_insert ON core.perfil FOR INSERT
  WITH CHECK (app.eh_admin());

DROP POLICY IF EXISTS pol_perfil_update ON core.perfil;
CREATE POLICY pol_perfil_update ON core.perfil FOR UPDATE
  USING (app.eh_admin()) WITH CHECK (app.eh_admin());

DROP POLICY IF EXISTS pol_perfil_delete ON core.perfil;
CREATE POLICY pol_perfil_delete ON core.perfil FOR DELETE
  USING (app.eh_admin());

DROP POLICY IF EXISTS pol_permissao_select ON core.permissao;
CREATE POLICY pol_permissao_select ON core.permissao FOR SELECT
  USING (app.usuario_ativo());

DROP POLICY IF EXISTS pol_permissao_insert ON core.permissao;
CREATE POLICY pol_permissao_insert ON core.permissao FOR INSERT
  WITH CHECK (app.eh_admin());

DROP POLICY IF EXISTS pol_permissao_update ON core.permissao;
CREATE POLICY pol_permissao_update ON core.permissao FOR UPDATE
  USING (app.eh_admin()) WITH CHECK (app.eh_admin());

DROP POLICY IF EXISTS pol_permissao_delete ON core.permissao;
CREATE POLICY pol_permissao_delete ON core.permissao FOR DELETE
  USING (app.eh_admin());

DROP POLICY IF EXISTS pol_perfil_permissao_select ON core.perfil_permissao;
CREATE POLICY pol_perfil_permissao_select ON core.perfil_permissao FOR SELECT
  USING (app.usuario_ativo());

DROP POLICY IF EXISTS pol_perfil_permissao_insert ON core.perfil_permissao;
CREATE POLICY pol_perfil_permissao_insert ON core.perfil_permissao FOR INSERT
  WITH CHECK (app.eh_admin());

DROP POLICY IF EXISTS pol_perfil_permissao_update ON core.perfil_permissao;
CREATE POLICY pol_perfil_permissao_update ON core.perfil_permissao FOR UPDATE
  USING (app.eh_admin()) WITH CHECK (app.eh_admin());

DROP POLICY IF EXISTS pol_perfil_permissao_delete ON core.perfil_permissao;
CREATE POLICY pol_perfil_permissao_delete ON core.perfil_permissao FOR DELETE
  USING (app.eh_admin());

-- =====================================================================================
-- 4. core.email_autorizado
--   E a porta de entrada do sistema: quem le a lista sabe quem pode entrar, e quem
--   escreve nela concede acesso. Leitura de admin e gestor, escrita so de admin.
-- =====================================================================================
ALTER TABLE core.email_autorizado ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pol_email_autorizado_select ON core.email_autorizado;
CREATE POLICY pol_email_autorizado_select ON core.email_autorizado FOR SELECT
  USING (app.tem_perfil(ARRAY['admin','gestor']));

DROP POLICY IF EXISTS pol_email_autorizado_insert ON core.email_autorizado;
CREATE POLICY pol_email_autorizado_insert ON core.email_autorizado FOR INSERT
  WITH CHECK (app.eh_admin() AND liberado_por = app.usuario_atual());  -- liberacao tem dono

DROP POLICY IF EXISTS pol_email_autorizado_update ON core.email_autorizado;
CREATE POLICY pol_email_autorizado_update ON core.email_autorizado FOR UPDATE
  USING (app.eh_admin()) WITH CHECK (app.eh_admin());

DROP POLICY IF EXISTS pol_email_autorizado_delete ON core.email_autorizado;
CREATE POLICY pol_email_autorizado_delete ON core.email_autorizado FOR DELETE
  USING (app.eh_admin());   -- na pratica se revoga com ativo = false; DELETE e excecao

-- =====================================================================================
-- 5. core.login_evento  (append-only)
--   O INSERT nao exige identidade: a tentativa de login e gravada justamente quando
--   ainda nao existe app.usuario_id, inclusive nas recusas. Nao ha policy de UPDATE nem
--   de DELETE - com FORCE, nem o dono reescreve o log de acesso.
-- =====================================================================================
ALTER TABLE core.login_evento ENABLE  ROW LEVEL SECURITY;
ALTER TABLE core.login_evento FORCE   ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pol_login_evento_select ON core.login_evento;
CREATE POLICY pol_login_evento_select ON core.login_evento FOR SELECT
  USING (app.tem_perfil(ARRAY['admin','gestor']));

DROP POLICY IF EXISTS pol_login_evento_insert ON core.login_evento;
CREATE POLICY pol_login_evento_insert ON core.login_evento FOR INSERT
  WITH CHECK (true);

-- =====================================================================================
-- 6. core.auditoria  (append-only, nem para admin)
--   core.fn_auditar() e trigger comum, roda como quem executou o comando: por isso o
--   INSERT e liberado a qualquer sessao. Leitura de admin e gestor. Sem policy de UPDATE
--   e DELETE, e com FORCE, ninguem apaga o proprio rastro - so um superuser fora da
--   aplicacao, o que ja e um evento de infraestrutura (ex: expurgo por retencao).
-- =====================================================================================
ALTER TABLE core.auditoria ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.auditoria FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pol_auditoria_select ON core.auditoria;
CREATE POLICY pol_auditoria_select ON core.auditoria FOR SELECT
  USING (app.tem_perfil(ARRAY['admin','gestor']));

DROP POLICY IF EXISTS pol_auditoria_insert ON core.auditoria;
CREATE POLICY pol_auditoria_insert ON core.auditoria FOR INSERT
  WITH CHECK (true);

-- =====================================================================================
-- 7. core.email_fila
--   Corpo de e-mail contem dado de terceiro: nenhum perfil operacional le a fila.
--   A aplicacao enfileira (sempre como pendente, nunca ja marcada como enviada) e a
--   rotina de entrega avanca o status. O UPDATE nao exige identidade porque a rotina da
--   VM roda sem usuario logado; para ela nao poder reescrever assunto e corpo, o
--   privilegio de UPDATE e cortado para as colunas de entrega - RLS nao filtra coluna.
--
--   CORRECAO (furo 10): o mesmo corte passou a existir em 02a, secao 3.2.1. Ele sozinho
--   aqui nao bastava: 02a concede UPDATE em ALL TABLES IN SCHEMA core e se declara
--   idempotente, entao reaplicar 02a sozinho devolvia o UPDATE de tabela inteira - e
--   privilegio de tabela anula privilegio de coluna - sem tocar em policy nenhuma, sem
--   erro e sem rastro. A repeticao e deliberada: cada arquivo termina com a matriz de
--   privilegio correta, em qualquer ordem de reexecucao. Nao remova por parecer redundante.
--
--   CORRECAO DO FURO 5 - A ROTINA DE ENTREGA ESTAVA TRAVADA, NAO SO SEM POLICY.
--   O texto acima dizia que "o UPDATE nao exige identidade porque a rotina da VM roda
--   sem usuario logado". Isso descrevia pol_email_fila_update e ignorava o resto do
--   comando: um "UPDATE core.email_fila SET status='enviando' WHERE status='pendente'"
--   LE as linhas existentes para encontra-las, e o PostgreSQL aplica nesse caso tambem
--   as policies de SELECT da tabela, alem da de UPDATE. A de SELECT era
--   USING (app.eh_admin()) para todas as roles; numa sessao sem GUC ela nao devolve
--   nem false - app.eh_admin() chama app.usuario_atual(), que levanta
--   insufficient_privilege de proposito. Como policies permissivas sao combinadas com
--   OR e a ordem de avaliacao nao e garantida, a excecao vazava para o comando: a
--   rotina nao entregava nada e a fila crescia calada.
--   Duas mudancas resolvem, e as duas sao necessarias:
--     1) as policies da aplicacao passam a ser amarradas por TO (biotrop_app,
--        biotrop_ro). Policy com TO so e avaliada para aquelas roles, entao a sessao da
--        rotina deixa de tropecar numa condicao escrita para quem tem identidade;
--     2) a rotina ganha policies proprias, TO biotrop_worker, com o par SELECT+UPDATE
--        que o comando realmente exige.
--   Sem o item 1 o item 2 nao resolveria: a policy de SELECT antiga continuaria sendo
--   avaliada para a role nova e continuaria estourando.
-- =====================================================================================
ALTER TABLE core.email_fila ENABLE ROW LEVEL SECURITY;

REVOKE UPDATE ON core.email_fila FROM biotrop_app;
GRANT  UPDATE (status, tentativas, erro, graph_message_id, enviado_em)
  ON core.email_fila TO biotrop_app;

-- 7.1 a aplicacao --------------------------------------------------------------------
-- Nenhum perfil operacional le a fila; admin le para suporte. biotrop_ro entra no
-- SELECT porque a role de relatorio tambem opera com SET LOCAL app.usuario_id e
-- perderia esse acesso se a policy fosse so de biotrop_app.
DROP POLICY IF EXISTS pol_email_fila_select ON core.email_fila;
CREATE POLICY pol_email_fila_select ON core.email_fila FOR SELECT
  TO biotrop_app, biotrop_ro
  USING (app.eh_admin());

DROP POLICY IF EXISTS pol_email_fila_insert ON core.email_fila;
CREATE POLICY pol_email_fila_insert ON core.email_fila FOR INSERT
  TO biotrop_app
  WITH CHECK (status = 'pendente' AND enviado_em IS NULL AND graph_message_id IS NULL);

-- A aplicacao continua podendo avancar o status (cancelar um aviso, por exemplo).
-- Ela tem identidade, mas esta policy nao a exige: quem limita o que ela reescreve
-- e o privilegio de coluna logo acima, nao esta condicao.
DROP POLICY IF EXISTS pol_email_fila_update ON core.email_fila;
CREATE POLICY pol_email_fila_update ON core.email_fila FOR UPDATE
  TO biotrop_app
  USING (status IN ('pendente','enviando'))
  WITH CHECK (status IN ('enviando','enviado','erro','cancelado'));

-- 7.2 a rotina de entrega (FURO 5) ---------------------------------------------------
-- O par abaixo e o minimo que o comando da rotina exige, e nada alem disso.
-- Note que NENHUMA das duas chama funcao de identidade: essa sessao nao tem GUC, e e
-- justamente por isso que ela existe. A autorizacao aqui vem de a role ser
-- biotrop_worker e de a linha estar em transito.
DROP POLICY IF EXISTS pol_email_fila_worker_select ON core.email_fila;
CREATE POLICY pol_email_fila_worker_select ON core.email_fila FOR SELECT
  TO biotrop_worker
  -- So o que ainda esta em transito. Mensagem enviada, com erro ou cancelada sai do
  -- alcance da rotina: ela nao tem por que reler o corpo do que ja foi entregue, e
  -- assim a fila entregue deixa de ser uma copia legivel por conta de servico.
  USING (status IN ('pendente','enviando'));

DROP POLICY IF EXISTS pol_email_fila_worker_update ON core.email_fila;
CREATE POLICY pol_email_fila_worker_update ON core.email_fila FOR UPDATE
  TO biotrop_worker
  -- USING = quais linhas ela alcanca (as em transito, iguais ao SELECT acima, senao o
  -- proprio WHERE do comando volta vazio). WITH CHECK = em que estado pode deixar.
  -- 'pendente' fica fora do WITH CHECK de proposito: a rotina avanca a fila, nao
  -- ressuscita mensagem para reenvio - reenfileirar e ato da aplicacao.
  USING      (status IN ('pendente','enviando'))
  WITH CHECK (status IN ('enviando','enviado','erro','cancelado'));

COMMENT ON POLICY pol_email_fila_worker_update ON core.email_fila IS 'UPDATE da rotina de entrega (biotrop_worker), que roda na VM sem usuario logado. Vem em par com pol_email_fila_worker_select porque UPDATE com WHERE le as linhas e por isso tambem passa pelas policies de SELECT - era esse o furo 5. Quais COLUNAS ela pode reescrever nao se decide aqui e sim no GRANT por coluna de 02a secao 3.3: status, tentativas, erro, graph_message_id e enviado_em.';

-- Sem policy de DELETE: mensagem entregue e comprovante de aviso, fica na fila.

-- Conferencia do furo 5: policy de core.email_fila sem clausula TO volta a ser
-- avaliada para TODAS as roles, inclusive a da rotina - e uma condicao de identidade
-- avaliada sem identidade nao devolve false, levanta excecao e trava a entrega.
DO $$
DECLARE v_erro text;
BEGIN
  SELECT string_agg(policyname, ', ' ORDER BY policyname) INTO v_erro
    FROM pg_policies
   WHERE schemaname = 'core' AND tablename = 'email_fila'
     AND (roles IS NULL OR roles = '{public}');
  IF v_erro IS NOT NULL THEN
    RAISE EXCEPTION 'Policy de core.email_fila sem TO explicito: % - ela seria avaliada para biotrop_worker e app.usuario_atual() levantaria excecao na rotina de entrega', v_erro;
  END IF;
END $$;

-- =====================================================================================
-- 8. core.anexo
--   Cada um ve o que enviou; o responsavel ve o que a equipe dele enviou; gestor e admin
--   veem tudo. O INSERT exige criado_por = usuario da sessao, entao a aplicacao precisa
--   informar o criador (core.anexo_de_dataurl aceita NULL, mas aqui NULL e recusado:
--   binario sem dono nao da para auditar). Sem UPDATE: anexo e imutavel, corrigir e
--   enviar outro. DELETE so de admin.
-- =====================================================================================
ALTER TABLE core.anexo ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pol_anexo_select ON core.anexo;
CREATE POLICY pol_anexo_select ON core.anexo FOR SELECT
  USING (
    app.usuario_ativo()
    AND (
      criado_por = app.usuario_atual()
      OR app.tem_perfil(ARRAY['admin','gestor'])
      OR EXISTS (
        SELECT 1 FROM core.usuario u
         WHERE u.id = anexo.criado_por
           AND u.grupo_id IN (SELECT app.grupos_que_lidero())
      )
    )
  );

DROP POLICY IF EXISTS pol_anexo_insert ON core.anexo;
CREATE POLICY pol_anexo_insert ON core.anexo FOR INSERT
  WITH CHECK (app.usuario_ativo() AND criado_por = app.usuario_atual());

DROP POLICY IF EXISTS pol_anexo_delete ON core.anexo;
CREATE POLICY pol_anexo_delete ON core.anexo FOR DELETE
  USING (app.eh_admin());

-- =====================================================================================
-- 9. O LOGIN PRECISA CONSULTAR ANTES DE EXISTIR IDENTIDADE
--   core.pode_autenticar() le core.email_autorizado e core.usuario, e e chamada no
--   momento em que ainda nao ha app.usuario_id - com as policies acima ela passaria a
--   falhar com "Sessao sem identidade". Vira SECURITY DEFINER: roda como dona das
--   tabelas, e a dona nao esta sob FORCE nessas duas. A funcao devolve apenas
--   permitido/motivo/usuario_id do e-mail perguntado, entao nao vaza cadastro.
-- =====================================================================================
ALTER FUNCTION core.pode_autenticar(citext) SECURITY DEFINER;
ALTER FUNCTION core.pode_autenticar(citext) SET search_path = core, pg_temp;

-- =====================================================================================
-- 9.1 O PRIMEIRO ACESSO   (correcao do FURO 9)
--   O furo: pol_usuario_insert e pol_usuario_update exigem app.eh_admin(), e no
--   primeiro login de uma pessoa nao existe app.usuario_id nenhum para setar - a linha
--   de core.usuario que daria identidade a sessao e exatamente a que ainda nao existe.
--   app.eh_admin() nem devolve false nesse ponto: ela chama app.usuario_atual(), que
--   levanta insufficient_privilege. Ou seja, o INSERT nao era "negado", era impossivel.
--   Ao mesmo tempo core.email_autorizado.perfil_padrao existe unicamente para
--   provisionar no primeiro acesso (esta escrito no COMMENT dela em 01-base.sql) e
--   nenhum caminho do sistema chegava a ler essa coluna: a coluna era decorativa, e a
--   unica forma de alguem novo entrar era um admin criar a linha na mao antes -
--   inclusive para o PRIMEIRO admin, que ninguem pode criar. O log tambem ficava pelo
--   caminho: sem uma funcao que rode antes da identidade, nada gravava a tentativa de
--   login em core.login_evento no momento em que ela acontece, que e justamente o
--   momento das recusas que se quer investigar.
--
--   A saida e uma funcao SECURITY DEFINER, porque e o unico jeito de escrever em
--   core.usuario sem ter identidade: ela roda como DONA das tabelas, e core.usuario
--   esta com ENABLE e nao com FORCE, entao a dona nao e filtrada pelas policies acima.
--   core.login_evento tem FORCE, mas pol_login_evento_insert e WITH CHECK (true) de
--   proposito (secao 5) - append-only sem exigir identidade e o que permite registrar
--   a recusa de quem nunca chegou a ter uma.
--
--   O QUE AMARRA ESTA FUNCAO, para SECURITY DEFINER nao virar porta dos fundos:
--     a) ela nao recebe perfil por parametro. O perfil vem de
--        core.email_autorizado.perfil_padrao, e so; quem escreve naquela tabela e
--        admin (pol_email_autorizado_insert). Escalada de privilegio no primeiro
--        acesso exigiria antes um admin liberando o e-mail com aquele perfil;
--     b) a decisao de deixar entrar continua sendo de core.pode_autenticar() - ponto
--        unico da regra. Bloqueado, inativo, nao autorizado ou autorizacao revogada
--        nao passa, e o motivo fica no log;
--     c) ON CONFLICT (email) DO UPDATE nao toca em perfil_id nem em grupo_id: dois
--        logins simultaneos (duas abas) nao viram duas linhas nem trocam o perfil de
--        quem ja existe. Reprovisionar alguem que ja existe e impossivel por aqui;
--     d) entra_object_id so e gravado se ainda estiver vazio, e um oid do Entra ja
--        amarrado a OUTRO e-mail e recusado - senao uma conta do diretorio poderia ser
--        pendurada em duas contas Biotrop;
--     e) o EXECUTE e tirado de PUBLIC. Funcao SECURITY DEFINER nasce executavel por
--        todo mundo no PostgreSQL; sem o REVOKE abaixo, biotrop_ro e biotrop_worker
--        criariam usuario.
--
--   Recusa devolve NULL em vez de excecao, e de proposito: excecao aborta a transacao
--   e levaria embora o INSERT em core.login_evento - a recusa que mais interessa
--   registrar seria a que nao ficaria registrada. Quem chamou, ao receber NULL,
--   pergunta o motivo legivel a core.pode_autenticar(email), que ja e SECURITY DEFINER.
-- =====================================================================================
CREATE OR REPLACE FUNCTION core.provisionar_acesso(
  p_email      citext,
  p_nome       text  DEFAULT NULL,   -- displayName do token, so para a linha nova
  p_entra_oid  uuid  DEFAULT NULL,   -- oid do token, amarra a conta do AD a esta linha
  p_ip         inet  DEFAULT NULL,
  p_user_agent text  DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, pg_temp AS $$
DECLARE
  v_pode   record;
  v_aut    core.email_autorizado;
  v_usu    core.usuario;
  v_perfil text;
  v_novo   boolean := false;
BEGIN
  IF p_email IS NULL OR position('@' in p_email::text) < 2 THEN
    RAISE EXCEPTION 'E-mail invalido para provisionamento de acesso'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- (b) a regra de quem entra nao e reescrita aqui: e a mesma de 01-base.sql.
  SELECT * INTO v_pode FROM core.pode_autenticar(p_email);

  IF NOT coalesce(v_pode.permitido, false) THEN
    INSERT INTO core.login_evento (email, usuario_id, sucesso, motivo, ip, user_agent)
    VALUES (p_email, v_pode.usuario_id, false,
            coalesce(v_pode.motivo, 'acesso recusado'), p_ip, p_user_agent);
    RETURN NULL;   -- sem excecao, senao o log acima ia embora com o rollback
  END IF;

  -- (d) um oid do Entra ID vale para uma pessoa. Se ele ja esta em outra linha, o token
  -- nao corresponde a este e-mail e a tentativa e um evento de seguranca, nao um login.
  IF p_entra_oid IS NOT NULL
     AND EXISTS (SELECT 1 FROM core.usuario u
                  WHERE u.entra_object_id = p_entra_oid AND u.email <> p_email) THEN
    INSERT INTO core.login_evento (email, usuario_id, sucesso, motivo, ip, user_agent)
    VALUES (p_email, NULL, false,
            'entra_object_id do token ja pertence a outro usuario', p_ip, p_user_agent);
    RETURN NULL;
  END IF;

  SELECT * INTO v_usu FROM core.usuario WHERE email = p_email;

  IF v_usu.id IS NULL THEN
    -- PRIMEIRO ACESSO. A autorizacao tem de estar ativa neste instante: pode_autenticar
    -- ja disse sim, esta leitura e para pegar perfil_padrao e grupo_padrao.
    SELECT * INTO v_aut FROM core.email_autorizado WHERE email = p_email AND ativo;
    IF v_aut.email IS NULL THEN
      INSERT INTO core.login_evento (email, usuario_id, sucesso, motivo, ip, user_agent)
      VALUES (p_email, NULL, false,
              'autorizacao ausente ou revogada no momento do provisionamento',
              p_ip, p_user_agent);
      RETURN NULL;
    END IF;

    -- (a) o perfil vem do cadastro, nunca do chamador. Sem perfil_padrao definido, ou
    -- com um perfil desativado desde a liberacao, cai em viewer - menor privilegio.
    -- Nunca em admin: perfil sem indicacao explicita nao pode virar acesso total.
    SELECT p.id INTO v_perfil
      FROM core.perfil p
     WHERE p.id = v_aut.perfil_padrao AND p.ativo;
    v_perfil := coalesce(v_perfil, 'viewer');

    -- (c) ON CONFLICT cobre a corrida de dois logins simultaneos do mesmo e-mail e
    -- NAO reescreve perfil_id nem grupo_id: quem ja existe nao e reprovisionado.
    INSERT INTO core.usuario (nome, email, entra_object_id, perfil_id, grupo_id,
                              ultimo_login_em)
    VALUES (coalesce(nullif(btrim(p_nome), ''), split_part(p_email::text, '@', 1)),
            p_email, p_entra_oid, v_perfil, v_aut.grupo_padrao, now())
    ON CONFLICT (email) DO UPDATE
      -- "usuario." aqui e a linha que JA existia; EXCLUDED. e a que tentou entrar.
      -- Em ON CONFLICT a tabela alvo se referencia pelo nome simples, sem schema.
      SET ultimo_login_em = now(),
          entra_object_id = coalesce(usuario.entra_object_id, EXCLUDED.entra_object_id)
    RETURNING * INTO v_usu;

    v_novo := (v_usu.criado_em = v_usu.ultimo_login_em);
  ELSE
    -- Acesso seguinte. ultimo_login_em tambem passava por pol_usuario_update e portanto
    -- tambem exigia admin - a data de ultimo login nunca era gravada. Fica aqui.
    UPDATE core.usuario
       SET ultimo_login_em = now(),
           entra_object_id = coalesce(entra_object_id, p_entra_oid)
     WHERE id = v_usu.id
    RETURNING * INTO v_usu;
  END IF;

  INSERT INTO core.login_evento (email, usuario_id, sucesso, motivo, ip, user_agent)
  VALUES (p_email, v_usu.id, true,
          CASE WHEN v_novo
               THEN 'primeiro acesso: usuario provisionado com perfil ' || v_usu.perfil_id
               ELSE 'ok' END,
          p_ip, p_user_agent);

  RETURN v_usu.id;
END $$;
COMMENT ON FUNCTION core.provisionar_acesso(citext, text, uuid, inet, text) IS 'Caminho unico do primeiro acesso (FURO 9). A aplicacao chama logo depois de validar o token do Entra ID e ANTES de SET LOCAL app.usuario_id - nesse instante nao existe identidade, e as policies de core.usuario exigem admin, entao um usuario novo era impossivel de criar e core.email_autorizado.perfil_padrao nunca era lido por ninguem. SECURITY DEFINER porque roda sem identidade; o perfil vem sempre de email_autorizado.perfil_padrao (e cai em viewer se ele estiver vazio ou desativado), nunca de parametro. Devolve o core.usuario.id para o SET LOCAL, ou NULL quando o acesso e recusado - e em ambos os casos grava a tentativa em core.login_evento. Recusa devolve NULL em vez de excecao para o registro do log nao ir embora no rollback: o motivo legivel se obtem em core.pode_autenticar(email).';

-- (e) SECURITY DEFINER nasce com EXECUTE para PUBLIC. Sem este REVOKE, a role de
-- leitura e a rotina de e-mail provisionariam usuario - inclusive um admin, se houver
-- e-mail autorizado com perfil_padrao 'admin' esperando.
REVOKE ALL ON FUNCTION core.provisionar_acesso(citext, text, uuid, inet, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.provisionar_acesso(citext, text, uuid, inet, text)
  TO biotrop_app;

-- core.pode_autenticar tem o mesmo problema, e virou SECURITY DEFINER na secao 9 logo
-- acima: fechar uma e deixar a outra aberta a PUBLIC seria trocar um furo de lugar.
-- Ela devolve apenas permitido/motivo/usuario_id do e-mail perguntado, mas "quem existe
-- e esta bloqueado" ja e informacao de diretorio.
REVOKE ALL ON FUNCTION core.pode_autenticar(citext) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION core.pode_autenticar(citext) TO biotrop_app;

-- =====================================================================================
-- 10. CONFERENCIA
--   Uma tabela do escopo sem RLS habilitado significa tabela aberta: para o deploy aqui,
--   em vez de a falha aparecer numa auditoria depois.
-- =====================================================================================
DO $$
DECLARE v_falta text;
BEGIN
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO v_falta
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'core'
     AND c.relname IN ('usuario','grupo','perfil','permissao','perfil_permissao',
                       'email_autorizado','login_evento','email_fila','auditoria','anexo')
     AND NOT c.relrowsecurity;
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION 'Tabelas de core sem RLS habilitado: %', v_falta;
  END IF;
END $$;

-- Auditoria e login_evento nao podem ganhar policy de UPDATE/DELETE por descuido futuro.
DO $$
DECLARE v_erro text;
BEGIN
  SELECT string_agg(tablename || '.' || policyname, ', ') INTO v_erro
    FROM pg_policies
   WHERE schemaname = 'core'
     AND tablename IN ('auditoria','login_evento')
     AND cmd IN ('UPDATE','DELETE','ALL');
  IF v_erro IS NOT NULL THEN
    RAISE EXCEPTION 'Tabela append-only com policy de escrita destrutiva: %', v_erro;
  END IF;
END $$;

-- =====================================================================================
-- 11. REGISTRO DESTA MIGRATION
-- =====================================================================================
INSERT INTO core.migration (versao, nome, observacao) VALUES
  ('0002b', 'rls-core',
   'RLS do schema core: usuario, grupo, perfil, permissao, perfil_permissao, email_autorizado, login_evento, email_fila, auditoria e anexo. Leitura propria + responsavel de grupo + gestor/admin; escrita de acesso so admin; auditoria e login_evento append-only com FORCE; email_fila fechada para usuario e com UPDATE limitado as colunas de entrega; core.pode_autenticar virou SECURITY DEFINER para o login funcionar antes de existir identidade. FURO 9: core.provisionar_acesso(citext,...) cria o caminho do primeiro acesso, que nao existia - le core.email_autorizado.perfil_padrao (coluna que nenhum caminho lia), cria o usuario, grava ultimo_login_em, registra sucesso e recusa em core.login_evento e devolve o id para o SET LOCAL; EXECUTE tirado de PUBLIC nela e em core.pode_autenticar. FURO 5: as policies de core.email_fila passaram a ter TO explicito (biotrop_app/biotrop_ro) e a rotina de entrega ganhou o par pol_email_fila_worker_select/update TO biotrop_worker - UPDATE com WHERE le as linhas e por isso tambem passa pelas policies de SELECT, e a de SELECT antiga, com app.eh_admin(), levantava excecao na sessao sem identidade da VM.')
ON CONFLICT (versao) DO NOTHING;
