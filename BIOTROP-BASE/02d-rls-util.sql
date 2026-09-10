-- =====================================================================================
-- BIOTROP - migration 0002d: RLS do schema util (medidores e leituras)
--   Depende de 01-base.sql e 02a-papeis.sql. Idempotente. PostgreSQL 15.
--   Usa app.tem_perfil / app.usuario_atual de 02a - nenhuma subconsulta a core.usuario
--   e repetida aqui. app.tem_perfil ja exige usuario ativo e nao bloqueado, por isso
--   as policies abaixo nao somam essa condicao de novo.
--
--   Regra de negocio desta etapa:
--     tecnico     - le medidor ATIVO, insere leitura, e nunca edita nem apaga leitura
--     pcm         - le e escreve medidor e leitura, inativa medidor, trata desvio
--     gestor/admin- tudo
--     viewer      - nada de utilidades
--     lider/almoxarife - nada de utilidades (nao ha regra de negocio que peca)
--   Quem nao casa com nenhuma policy nao recebe erro: recebe zero linha. E o que
--   queremos para viewer - a tela fica vazia em vez de vazar dado com aviso.
-- =====================================================================================

-- =====================================================================================
-- 1. O TRIGGER DE LEITURA PRECISA VER A SERIE INTEIRA
--   util.fn_leitura_preparar calcula leitura_anterior lendo util.leitura. Rodando com
--   os direitos de quem chama, sob RLS, o tecnico calcularia a leitura anterior olhando
--   apenas as proprias leituras - e o consumo sairia errado sem erro nenhum, que e o
--   pior tipo de defeito. SECURITY DEFINER faz o trigger ler a serie completa (e
--   gravar mig.ocorrencia na importacao, schema que a aplicacao nao alcanca).
--   search_path fixo e obrigatorio em SECURITY DEFINER.
-- =====================================================================================
ALTER FUNCTION util.fn_leitura_preparar() SECURITY DEFINER;
ALTER FUNCTION util.fn_leitura_preparar() SET search_path = util, mig, pg_temp;

-- =====================================================================================
-- 2. util.medidor
--   ENABLE sem FORCE: o dono do banco e o caminho da importacao (mig.importar_medidores
--   nao e SECURITY DEFINER e roda pelo dono, sem identidade de sessao). Forcar aqui
--   quebraria a carga. A aplicacao nao entra como dono - conecta como biotrop_app.
-- =====================================================================================
ALTER TABLE util.medidor ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_medidor_sel_app ON util.medidor;
CREATE POLICY p_medidor_sel_app ON util.medidor
  FOR SELECT TO biotrop_app
  USING (
       app.tem_perfil(ARRAY['admin', 'gestor', 'pcm'])
    -- o tecnico so ve o que pode apontar: medidor inativo desaparece da tela dele
    OR (app.tem_perfil(ARRAY['tecnico']) AND ativo)
  );

DROP POLICY IF EXISTS p_medidor_sel_ro ON util.medidor;
CREATE POLICY p_medidor_sel_ro ON util.medidor
  FOR SELECT TO biotrop_ro USING (true);

DROP POLICY IF EXISTS p_medidor_ins ON util.medidor;
CREATE POLICY p_medidor_ins ON util.medidor
  FOR INSERT TO biotrop_app
  WITH CHECK (app.tem_perfil(ARRAY['admin', 'gestor', 'pcm']));

-- Inativar medidor e UPDATE de ativo, e e ato do PCM. Por isso pcm entra no UPDATE
-- e nao no DELETE: o historico de consumo tem que continuar no banco.
DROP POLICY IF EXISTS p_medidor_upd ON util.medidor;
CREATE POLICY p_medidor_upd ON util.medidor
  FOR UPDATE TO biotrop_app
  USING      (app.tem_perfil(ARRAY['admin', 'gestor', 'pcm']))
  WITH CHECK (app.tem_perfil(ARRAY['admin', 'gestor', 'pcm']));

DROP POLICY IF EXISTS p_medidor_del ON util.medidor;
CREATE POLICY p_medidor_del ON util.medidor
  FOR DELETE TO biotrop_app
  USING (app.tem_perfil(ARRAY['admin']));

COMMENT ON POLICY p_medidor_del ON util.medidor IS 'Apagar medidor e excecao de admin: a regra operacional e inativar (util.medidor.ativo), porque apagar levaria a serie de consumo da planta junto.';

-- =====================================================================================
-- 3. util.leitura
--   Apontamento gravado nao volta atras pela mao de quem apontou: nao existe policy de
--   UPDATE nem de DELETE para tecnico. Correcao e decisao do PCM, e sai auditada pelo
--   trigger tg_audit_leitura de 01-base.
--   ENABLE sem FORCE pelo mesmo motivo do medidor (mig.importar_leituras roda pelo dono).
-- =====================================================================================
ALTER TABLE util.leitura ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_leitura_sel_pcm ON util.leitura;
CREATE POLICY p_leitura_sel_pcm ON util.leitura
  FOR SELECT TO biotrop_app
  USING (app.tem_perfil(ARRAY['admin', 'gestor', 'pcm']));

-- O tecnico ve as leituras que ele mesmo lancou. Nao e conforto de tela: sem uma
-- policy de SELECT que alcance a linha nova, INSERT ... RETURNING falha.
DROP POLICY IF EXISTS p_leitura_sel_propria ON util.leitura;
CREATE POLICY p_leitura_sel_propria ON util.leitura
  FOR SELECT TO biotrop_app
  USING (
    app.tem_perfil(ARRAY['tecnico'])
    AND responsavel_id = app.usuario_atual()
  );

DROP POLICY IF EXISTS p_leitura_sel_ro ON util.leitura;
CREATE POLICY p_leitura_sel_ro ON util.leitura
  FOR SELECT TO biotrop_ro USING (true);

-- WITH CHECK e o que sustenta esta policy: sem ele o INSERT passaria qualquer linha,
-- inclusive apontamento assinado no nome de outra pessoa ou em medidor inativo.
DROP POLICY IF EXISTS p_leitura_ins_tecnico ON util.leitura;
CREATE POLICY p_leitura_ins_tecnico ON util.leitura
  FOR INSERT TO biotrop_app
  WITH CHECK (
    app.tem_perfil(ARRAY['tecnico'])
    AND responsavel_id = app.usuario_atual()
    AND EXISTS (
      SELECT 1 FROM util.medidor m
       WHERE m.id = medidor_id
         AND m.ativo
    )
  );

-- PCM/gestor/admin lancam tambem no nome de terceiro (apontamento recebido no papel,
-- acerto de fechamento), por isso aqui responsavel_id nao e amarrado a sessao.
DROP POLICY IF EXISTS p_leitura_ins_pcm ON util.leitura;
CREATE POLICY p_leitura_ins_pcm ON util.leitura
  FOR INSERT TO biotrop_app
  WITH CHECK (app.tem_perfil(ARRAY['admin', 'gestor', 'pcm']));

DROP POLICY IF EXISTS p_leitura_upd_pcm ON util.leitura;
CREATE POLICY p_leitura_upd_pcm ON util.leitura
  FOR UPDATE TO biotrop_app
  USING      (app.tem_perfil(ARRAY['admin', 'gestor', 'pcm']))
  WITH CHECK (app.tem_perfil(ARRAY['admin', 'gestor', 'pcm']));

COMMENT ON POLICY p_leitura_upd_pcm ON util.leitura IS 'Correcao de leitura e do PCM. O tecnico nao tem policy de UPDATE: leitura gravada e evidencia, e mexer nela sem rastro apagaria o erro junto com o dado.';

-- Apagar apontamento derruba a base de comparacao das leituras seguintes do medidor.
-- Fica com admin/gestor; o PCM corrige por UPDATE, que a auditoria registra.
DROP POLICY IF EXISTS p_leitura_del ON util.leitura;
CREATE POLICY p_leitura_del ON util.leitura
  FOR DELETE TO biotrop_app
  USING (app.tem_perfil(ARRAY['admin', 'gestor']));

-- =====================================================================================
-- 4. util.desvio_tratativa
--   A analise do desvio (situacao, nota, quem analisou) e conclusao do PCM sobre o
--   trabalho de outra pessoa. Leitura de pcm/gestor/admin, escrita assinada por quem
--   analisa, DELETE so admin.
--
--   CORRECAO DO FURO 11 (revisao adversarial): O FORCE QUE ESTAVA AQUI FOI RETIRADO.
--
--   O que o FORCE fazia de errado nesta tabela em especifico: FORCE ROW LEVEL SECURITY
--   e a unica clausula que sujeita o DONO da tabela as policies. E as cinco policies
--   desta secao sao todas com clausula TO (biotrop_app ou biotrop_ro) - nenhuma alcanca
--   o dono. Policy que nao alcanca a role nao e avaliada para ela, e RLS sem nenhuma
--   policy permissiva aplicavel nega tudo. O resultado nao era "tabela mais segura",
--   era tabela inacessivel para o dono:
--     - SELECT devolvia ZERO LINHA, sem erro. E o pior caso: um pg_dump rodado pelo
--       dono exportava util.desvio_tratativa VAZIA e o backup ficava verde. Perder a
--       analise do PCM em silencio e pior do que nao ter FORCE;
--     - INSERT, UPDATE e DELETE ficavam impossiveis para o dono - nao havia caminho de
--       correcao de dado nem para a proxima migration que precisasse tocar a tabela.
--
--   Por que a escolha foi TIRAR o FORCE e nao acrescentar policy que alcance o dono:
--     1) FORCE so muda o comportamento do DONO. A ameaca que este arquivo trata e a
--        role da aplicacao, que nao e dona e e NOBYPASSRLS (02a para o deploy se nao
--        for) - as cinco policies TO biotrop_app/biotrop_ro ja resolvem isso por
--        inteiro, com ou sem FORCE. Nesta tabela o FORCE nao fechava nada;
--     2) desvio_tratativa NAO e append-only: ela tem policy de UPDATE e de DELETE. Nas
--        tabelas onde o FORCE ganha o seu salario (core.auditoria, core.login_evento,
--        almox.sci_historico, almox.scm_historico) o valor vem da AUSENCIA de policy de
--        UPDATE/DELETE: com FORCE, nem o dono reescreve o log. Aqui nao existe essa
--        imutabilidade a proteger;
--     3) a alternativa "policy que alcance o dono" seria uma policy sem TO gateada por
--        current_user NOT IN ('biotrop_app','biotrop_ro'). Ela deixaria o dono com
--        acesso total - ou seja, o mesmo efeito pratico de nao ter FORCE - mas com um
--        gatilho a mais: uma terceira role de cliente criada no futuro e esquecida
--        naquela lista ganharia acesso total a tabela. Menos peca, menos furo.
--
--   NO FORCE explicito em vez de apagar a linha: 02d se declara idempotente e pode ja
--   ter sido aplicada com o FORCE ligado. Sem este comando, reaplicar o arquivo deixaria
--   o banco com o furo e o arquivo dizendo que ele nao existe mais.
-- =====================================================================================
ALTER TABLE util.desvio_tratativa ENABLE ROW LEVEL SECURITY;
ALTER TABLE util.desvio_tratativa NO FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_tratativa_sel ON util.desvio_tratativa;
CREATE POLICY p_tratativa_sel ON util.desvio_tratativa
  FOR SELECT TO biotrop_app
  USING (app.tem_perfil(ARRAY['admin', 'gestor', 'pcm']));

DROP POLICY IF EXISTS p_tratativa_sel_ro ON util.desvio_tratativa;
CREATE POLICY p_tratativa_sel_ro ON util.desvio_tratativa
  FOR SELECT TO biotrop_ro USING (true);

-- Quem analisa assina a propria analise: analisado_por tem que ser a sessao.
-- O CHECK ck_tratativa_analise da base ja exige analisado_por/analisado_em quando a
-- situacao sai de 'aberto'; a policy garante que esse nome nao seja o de outro.
DROP POLICY IF EXISTS p_tratativa_ins ON util.desvio_tratativa;
CREATE POLICY p_tratativa_ins ON util.desvio_tratativa
  FOR INSERT TO biotrop_app
  WITH CHECK (
    app.tem_perfil(ARRAY['admin', 'gestor', 'pcm'])
    AND (situacao = 'aberto' OR analisado_por = app.usuario_atual())
  );

DROP POLICY IF EXISTS p_tratativa_upd ON util.desvio_tratativa;
CREATE POLICY p_tratativa_upd ON util.desvio_tratativa
  FOR UPDATE TO biotrop_app
  USING      (app.tem_perfil(ARRAY['admin', 'gestor', 'pcm']))
  WITH CHECK (
    app.tem_perfil(ARRAY['admin', 'gestor', 'pcm'])
    AND (situacao = 'aberto' OR analisado_por = app.usuario_atual())
  );

DROP POLICY IF EXISTS p_tratativa_del ON util.desvio_tratativa;
CREATE POLICY p_tratativa_del ON util.desvio_tratativa
  FOR DELETE TO biotrop_app
  USING (app.tem_perfil(ARRAY['admin']));

-- =====================================================================================
-- 5. AS VIEWS DE UTILIDADES PRECISAM OBEDECER A RLS
--   View no PostgreSQL 15 roda, por padrao, com os direitos do DONO: a RLS das tabelas
--   de baixo simplesmente nao e aplicada. Sem os ALTER abaixo, todo este arquivo seria
--   decorativo para quem consulta pelas telas - inclusive o viewer, que le app.* por
--   GRANT. security_invoker = true faz a view ser filtrada pelas policies da sessao.
--   E por aqui, e nao por GRANT, que "viewer nao ve nada de utilidades" se sustenta.
-- =====================================================================================
ALTER VIEW app.vw_medidor_apontavel  SET (security_invoker = true);
ALTER VIEW app.vw_medidor_painel     SET (security_invoker = true);
ALTER VIEW app.vw_leitura_historico  SET (security_invoker = true);
ALTER VIEW app.vw_util_desvio        SET (security_invoker = true);

-- app.vw_util_desvio: com security_invoker, pcm/gestor/admin veem a deteccao completa
-- com a tratativa; viewer, lider e almoxarife veem zero linha. O tecnico, que precisa
-- ler as proprias leituras (secao 3), ainda alcanca o desvio das linhas dele - sem
-- nota nem situacao, que ficam na tabela fechada da secao 4. Fechar tambem isso e uma
-- condicao no corpo da view (WHERE app.tem_perfil(ARRAY['pcm','gestor','admin'])),
-- que pertence a 01-base: nao reescrevo o corpo dela aqui para nao criar duas versoes
-- da mesma deteccao.
COMMENT ON VIEW app.vw_util_desvio IS 'Deteccao de desvio para o PCM, uma linha por (leitura, tipo de desvio). Filtrada pela RLS de util.leitura e util.desvio_tratativa (security_invoker): a leitura completa e de pcm, gestor e admin.';

-- Conferencia: RLS ligada de fato nas tres tabelas. Um ENABLE que nao pegou e pior
-- que nenhum, porque a policy existe no catalogo e da a impressao de estar valendo.
DO $$
DECLARE v_falta text;
BEGIN
  SELECT string_agg(format('%s.%s', n.nspname, c.relname), ', ')
    INTO v_falta
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'util'
     AND c.relkind = 'r'
     AND NOT c.relrowsecurity;
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION 'Tabela do schema util sem RLS: % - policy no catalogo sem RLS ligada nao protege nada', v_falta;
  END IF;
END $$;

-- =====================================================================================
-- 6. REGISTRO DESTA MIGRATION
-- =====================================================================================
INSERT INTO core.migration (versao, nome, observacao) VALUES
  ('0002d', 'rls-util',
   'RLS de util.medidor, util.leitura e util.desvio_tratativa: tecnico le medidor ativo e insere leitura sem poder editar ou apagar, pcm le/escreve e inativa medidor, gestor/admin tudo, viewer nada. FURO 11: o FORCE de desvio_tratativa foi retirado (NO FORCE) - as cinco policies da tabela sao TO biotrop_app/biotrop_ro, entao com FORCE o dono ficava sem nenhuma policy aplicavel: zero linha no SELECT (pg_dump do dono exportava a tabela vazia, em silencio) e nenhum INSERT possivel. FORCE so sujeita o dono, e a ameaca aqui e a role da aplicacao, que ja e NOBYPASSRLS e coberta pelas policies; a tabela tambem nao e append-only, entao nao havia imutabilidade a proteger. Views app.vw_medidor_apontavel/painel, vw_leitura_historico e vw_util_desvio passam a security_invoker, e util.fn_leitura_preparar vira SECURITY DEFINER para calcular leitura_anterior sobre a serie completa.')
ON CONFLICT (versao) DO NOTHING;
