-- =====================================================================================
-- BIOTROP - migration 0002f: ajustes de objetos que nasceram em 01-base.sql
--   Depende de 01, 02a, 02b, 02c, 02d e 02e. Idempotente. PostgreSQL 15.
--   Ultima da fila de aplicacao: 01, 02a, 02b, 02c, 02d, 02e, 02f.
--
--   POR QUE ESTE ARQUIVO EXISTE:
--   01-base.sql ja foi aplicada. Migration aplicada nao se reescreve - se ela mudar,
--   dois bancos que rodaram "a mesma" migration deixam de ser o mesmo banco e o
--   historico de core.migration passa a mentir. Toda correcao em objeto de 01 entra
--   aqui, com CREATE OR REPLACE, e fica auditavel como uma mudanca datada.
--
--   O que este arquivo corrige:
--     FURO 4 - lms.corrigir_tentativa() era SECURITY DEFINER sem conferir o dono da
--              matricula. Roda como dona das tabelas, entao ignora o RLS de lms (que
--              nao tem FORCE, justamente por causa dela), recebia a matricula por
--              parametro e nao checava nada: qualquer usuario autenticado chamava a
--              funcao com o uuid da matricula de um colega e gravava tentativa, nota,
--              conclusao e comprovante no nome dele - inclusive gastando ou esgotando
--              as tentativas alheias, o que bloqueia a matricula do outro.  (secao 1)
--     FURO 1 - nenhuma view do schema app tinha security_invoker, exceto as quatro de
--              utilidades. View sem essa opcao le as tabelas com o direito do DONO,
--              entao as 137 policies de 02b a 02e nao eram avaliadas para quem consulta
--              pelas telas: app.vw_lms_matricula devolvia nota e progresso de todo
--              mundo e app.vw_usuario devolvia o diretorio inteiro.  (secao 2)
--     Apoio ao FURO 3 - 02a passou a conceder UPDATE por COLUNA em lms.matricula
--              (bloqueada, bloqueada_em e tentativas_liberadas ficaram fora, senao o
--              aluno se dava tentativa infinita). lms.liberar_matricula() nao era
--              SECURITY DEFINER e quebraria com esse corte: passa a ser, com checagem
--              de admin e de assinatura dentro do corpo.  (secao 4)
-- =====================================================================================

-- =====================================================================================
-- 1. lms.corrigir_tentativa: a matricula tem de ser do usuario da sessao
--   A funcao continua SECURITY DEFINER, e por um motivo que nao da para contornar: a
--   role da aplicacao nao tem SELECT na coluna lms.questao_opcao.correta (02a), entao
--   a correcao SO pode acontecer como dona da tabela. O que faltava era o passo que
--   toda funcao SECURITY DEFINER precisa ter: reautorizar por conta propria o que o
--   RLS deixou de fazer. Foram acrescentados, logo depois do SELECT ... FOR UPDATE da
--   matricula e ANTES de qualquer escrita:
--     a) identidade obrigatoria (app.usuario_atual() falha alto se o GUC nao veio);
--     b) usuario ativo e nao bloqueado, para a funcao nao ser um caminho paralelo de
--        acesso de quem foi desligado;
--     c) m.usuario_id = usuario da sessao, ou perfil admin;
--     d) a excecao de admin fica REGISTRADA em core.auditoria - corrigir a prova de
--        outra pessoa e ato legitimo de suporte, mas nao pode ser silencioso.
--   O resto do corpo e identico ao de 01-base.sql, de proposito: esta migration corrige
--   a autorizacao, nao a regra de correcao.
-- =====================================================================================
CREATE OR REPLACE FUNCTION lms.corrigir_tentativa(
  p_matricula uuid,
  p_respostas jsonb
) RETURNS jsonb
-- search_path fixo e obrigatorio em SECURITY DEFINER. public entra porque as
-- extensoes (pgcrypto, de onde vem gen_random_bytes do codigo do comprovante)
-- sao instaladas nele; no PostgreSQL 15 o public ja nao aceita criacao por
-- qualquer role, entao nao e porta de entrada.
LANGUAGE plpgsql SECURITY DEFINER SET search_path = lms, core, public, pg_temp AS $$
DECLARE
  m           lms.matricula;
  v           lms.versao;
  t           lms.treinamento;
  v_aval      lms.avaliacao;
  q           record;
  v_dadas     uuid[];
  v_certas    uuid[];
  v_ok        boolean;
  v_peso_tot  numeric(10,2) := 0;
  v_peso_ok   numeric(10,2) := 0;
  v_nota      numeric(5,2);
  v_num       smallint;
  v_limite    smallint;
  v_aprovado  boolean;
  v_tent      lms.tentativa;
  v_pend      integer;
  v_codigo    text;
  v_calc      jsonb := '[]'::jsonb;
  -- FURO 4: identidade da sessao e a flag da excecao de admin
  v_sessao    uuid;
  v_admin     boolean := false;
BEGIN
  -- FURO 4 - CHECAGEM DE DONO.
  -- app.usuario_atual() falha com insufficient_privilege se a aplicacao esqueceu o
  -- SET LOCAL app.usuario_id: funcao SECURITY DEFINER sem identidade nao pode seguir,
  -- porque aqui dentro nao existe RLS para segurar nada depois.
  v_sessao := app.usuario_atual();
  -- Desligado ou bloqueado nao corrige prova nem a propria: sem esta linha a funcao
  -- seria um caminho de acesso paralelo, imune ao bloqueio feito na tela.
  IF NOT app.usuario_ativo() THEN
    RAISE EXCEPTION 'Usuario inativo ou bloqueado nao pode enviar avaliacao'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO m FROM lms.matricula WHERE id = p_matricula FOR UPDATE;
  IF m.id IS NULL THEN RAISE EXCEPTION 'Matricula inexistente'; END IF;

  -- A matricula tem de ser do usuario da sessao. Antes desta checagem, bastava chamar
  -- a funcao com o uuid da matricula de um colega para gravar tentativa, nota,
  -- conclusao e comprovante no nome dele - ou queimar as tentativas dele ate bloquear.
  -- A funcao roda como dona das tabelas, entao o RLS de lms (sem FORCE) nao filtra
  -- nada aqui: a autorizacao e responsabilidade dela mesma.
  IF m.usuario_id IS DISTINCT FROM v_sessao THEN
    v_admin := app.eh_admin();
    IF NOT v_admin THEN
      RAISE EXCEPTION 'Esta matricula nao e sua: a avaliacao so pode ser enviada pelo dono da matricula'
        USING ERRCODE = 'insufficient_privilege',
              HINT    = 'Se for suporte lancando por outra pessoa, use uma conta admin - o lancamento fica registrado em core.auditoria.';
    END IF;
    -- Excecao explicita e REGISTRADA: suporte precisa poder lancar por alguem que nao
    -- consegue enviar (aba fechada, sessao caida), mas isso nao pode ser silencioso.
    -- core.auditoria e append-only e com FORCE (02b), entao nem o admin apaga a linha.
    INSERT INTO core.auditoria (tabela, registro_id, operacao, antes, depois, ator_email)
    VALUES ('lms.corrigir_tentativa', m.id::text, 'U',
            jsonb_build_object('matricula_id', m.id, 'dono_id', m.usuario_id),
            jsonb_build_object('executado_por', v_sessao,
                               'motivo', 'admin corrigindo tentativa de outro usuario'),
            nullif(current_setting('app.usuario_email', true), '')::citext);
  END IF;

  IF m.bloqueada THEN
    RAISE EXCEPTION 'Matricula bloqueada por limite de tentativas. Solicite liberacao ao administrador.';
  END IF;
  IF EXISTS (SELECT 1 FROM lms.conclusao c WHERE c.matricula_id = m.id) THEN
    RAISE EXCEPTION 'Treinamento ja concluido';
  END IF;

  SELECT * INTO v FROM lms.versao      WHERE id = m.versao_id;
  SELECT * INTO t FROM lms.treinamento WHERE id = m.treinamento_id;
  SELECT * INTO v_aval FROM lms.avaliacao WHERE versao_id = m.versao_id;
  IF v_aval.id IS NULL THEN RAISE EXCEPTION 'Esta versao nao tem avaliacao'; END IF;

  -- Aula obrigatoria pendente impede a prova.
  SELECT count(*) INTO v_pend
    FROM lms.aula a
    LEFT JOIN lms.progresso_aula p ON p.aula_id = a.id AND p.matricula_id = m.id
   WHERE a.versao_id = m.versao_id AND a.obrigatoria AND p.concluido_em IS NULL;
  IF v_pend > 0 THEN
    RAISE EXCEPTION 'Faltam % aula(s) obrigatoria(s) antes da avaliacao', v_pend;
  END IF;

  v_limite := v.tentativas_maximas + m.tentativas_liberadas;
  SELECT coalesce(max(numero), 0)::smallint + 1 INTO v_num FROM lms.tentativa WHERE matricula_id = m.id;
  IF v_num > v_limite THEN
    RAISE EXCEPTION 'Limite de % tentativas atingido', v_limite;
  END IF;

  FOR q IN SELECT * FROM lms.questao WHERE avaliacao_id = v_aval.id ORDER BY posicao LOOP
    v_peso_tot := v_peso_tot + q.peso;

    -- Aceita tanto ["op1","op2"] (multipla) quanto "op1" (unica), que e como
    -- as duas telas mandam hoje. Ordenar as duas listas permite comparar por
    -- igualdade de array, sem laco de comparacao.
    SELECT coalesce(array_agg(el::uuid ORDER BY el::uuid), '{}'::uuid[]) INTO v_dadas
      FROM jsonb_array_elements_text(
             CASE
               WHEN jsonb_typeof(p_respostas -> q.id::text) = 'array' THEN p_respostas -> q.id::text
               WHEN p_respostas ? q.id::text THEN jsonb_build_array(p_respostas ->> q.id::text)
               ELSE '[]'::jsonb
             END) AS el;

    SELECT coalesce(array_agg(o.id ORDER BY o.id), '{}'::uuid[]) INTO v_certas
      FROM lms.questao_opcao o
     WHERE o.questao_id = q.id AND o.correta;

    -- Questao cadastrada sem nenhuma alternativa correta nunca conta ponto:
    -- comparar "nada marcado" com "nenhuma correta" daria acerto de graca.
    v_ok := (cardinality(v_certas) > 0 AND v_dadas = v_certas);
    IF v_ok THEN v_peso_ok := v_peso_ok + q.peso; END IF;

    v_calc := v_calc || jsonb_build_array(
      jsonb_build_object('questao_id', q.id, 'opcoes', to_jsonb(v_dadas), 'correta', v_ok));
  END LOOP;

  v_nota     := CASE WHEN v_peso_tot > 0 THEN round((v_peso_ok / v_peso_tot) * 100, 2) ELSE 0 END;
  v_aprovado := v_nota >= v.nota_corte;

  INSERT INTO lms.tentativa (matricula_id, avaliacao_id, numero, nota, aprovado)
  VALUES (m.id, v_aval.id, v_num, v_nota, v_aprovado)
  RETURNING * INTO v_tent;

  INSERT INTO lms.tentativa_resposta (tentativa_id, questao_id, opcoes, correta)
  SELECT v_tent.id,
         (r ->> 'questao_id')::uuid,
         coalesce((SELECT array_agg(o::uuid) FROM jsonb_array_elements_text(r -> 'opcoes') AS o), '{}'::uuid[]),
         (r ->> 'correta')::boolean
    FROM jsonb_array_elements(v_calc) AS r;

  IF v_aprovado THEN
    v_codigo := 'BT-' || upper(encode(gen_random_bytes(5), 'hex'));
    INSERT INTO lms.conclusao (matricula_id, codigo_comprovante, aproveitamento, valido_ate, evidencia)
    VALUES (m.id, v_codigo, v_nota,
            CASE WHEN t.validade_meses IS NULL THEN NULL
                 ELSE now() + make_interval(months => t.validade_meses::int) END,
            'automatica');
    UPDATE lms.matricula
       SET status = 'concluida', concluido_em = now()
     WHERE id = m.id;
  ELSIF v_num >= v_limite THEN
    UPDATE lms.matricula
       SET status = 'reprovada', bloqueada = true, bloqueada_em = now()
     WHERE id = m.id;
  ELSE
    UPDATE lms.matricula
       SET status = 'aguardando_avaliacao'
     WHERE id = m.id;
  END IF;

  RETURN jsonb_build_object(
    'tentativa',        v_num,
    'nota',             v_nota,
    'aprovado',         v_aprovado,
    'nota_corte',       v.nota_corte,
    'tentativas_restantes', greatest(0, v_limite - v_num),
    'bloqueada',        (NOT v_aprovado AND v_num >= v_limite),
    'comprovante',      v_codigo
  );
END $$;
COMMENT ON FUNCTION lms.corrigir_tentativa(uuid, jsonb) IS 'Corrige a avaliacao DENTRO do banco. E SECURITY DEFINER porque a role da aplicacao nao tem permissao de ler a coluna do gabarito: o navegador manda as respostas e recebe apenas nota, aprovacao e tentativas restantes. Aplica tambem o bloqueio ao esgotar as tentativas. Desde 0002f confere que a matricula e do usuario da sessao (FURO 4): sendo SECURITY DEFINER ela passa por cima do RLS de lms, entao a checagem de dono e dela mesma. Admin e a unica excecao, e cada uso dessa excecao vira linha em core.auditoria.';

-- O GRANT sobrevive ao CREATE OR REPLACE (mesma funcao, mesma identidade), mas fica
-- repetido para que aplicar 02f num banco novo nao dependa da ordem dos arquivos.
GRANT EXECUTE ON FUNCTION lms.corrigir_tentativa(uuid, jsonb) TO biotrop_app;

-- =====================================================================================
-- 2. FURO 1: TODAS AS VIEWS DE app.* PASSAM A SER FILTRADAS PELA SESSAO
--
--   O problema: no PostgreSQL a view executa, por padrao, com os direitos de quem a
--   CRIOU (o dono do banco), e nao de quem a consulta. As policies de 02b a 02e sao
--   avaliadas na leitura das TABELAS; quando essa leitura acontece por conta do dono,
--   nao ha policy a avaliar. Com as 137 policies no lugar e RLS confirmada ligada pelos
--   blocos de conferencia de cada arquivo, o efeito pratico era este:
--     - app.vw_lms_matricula devolvia nota, melhor_nota, progresso e comprovante de
--       TODO MUNDO para qualquer pessoa que abrisse a tela de treinamentos;
--     - app.vw_usuario devolvia o diretorio inteiro (nome, e-mail, telefone, perfil,
--       grupo, responsavel) para um tecnico que, na tabela core.usuario, alcanca apenas
--       a propria linha por pol_usuario_select;
--     - app.vw_sci e app.vw_scm mostravam solicitacao de qualquer area, e
--       app.vw_util_desvio/vw_leitura_historico so escapavam porque 02d as tratou;
--     - o perfil viewer, que le app.* por GRANT, via tudo.
--   As telas leem as views, nao as tabelas. Enquanto as views rodassem como o dono, o
--   conjunto de policies era decoracao.
--
--   O mecanismo era conhecido: 02d-rls-util.sql, secao 5, faz exatamente isto nas quatro
--   views de utilidades, com o comentario explicando o motivo. Faltou nas outras dezoito.
--
--   POR QUE ALTER VIEW E NAO CREATE OR REPLACE VIEW COM O CORPO REPETIDO:
--   security_invoker e opcao de armazenamento da view, e ALTER VIEW ... SET liga a opcao
--   sem tocar na definicao. Copiar os corpos para ca criaria uma SEGUNDA redacao de cada
--   consulta (vw_util_desvio e vw_lms_matricula tem quase 60 linhas cada) e a proxima
--   correcao entraria em uma das duas - foi por esse motivo que 02d ja se recusou a
--   reescrever o corpo de vw_util_desvio fora de 01-base.
--
--   VIEW ANINHADA PRECISA DA OPCAO EM TODOS OS NIVEIS: vw_sci_fila_almoxarifado le
--   vw_sci; vw_scm_fila_aprovacao le vw_scm; vw_lms_conformidade, vw_lms_visao_lider e
--   vw_lms_bloqueada leem vw_lms_matricula; vw_usuario le vw_perfil_permissoes; e
--   vw_saude_operacional le quatro views. Bastaria UMA sem security_invoker para o nivel
--   de baixo voltar a ler as tabelas como dono - por isso a lista e completa e a
--   conferencia da secao 2.7 e feita por catalogo, nao pela lista escrita a mao.
-- =====================================================================================

-- 2.1 acesso -------------------------------------------------------------------------
ALTER VIEW app.vw_perfil_permissoes      SET (security_invoker = true);
ALTER VIEW app.vw_usuario                SET (security_invoker = true);
ALTER VIEW app.vw_aprovador_de           SET (security_invoker = true);
ALTER VIEW app.vw_login_permitido        SET (security_invoker = true);

-- 2.2 almoxarifado - SCI -------------------------------------------------------------
ALTER VIEW app.vw_sci                    SET (security_invoker = true);
ALTER VIEW app.vw_sci_campos             SET (security_invoker = true);
ALTER VIEW app.vw_sci_fila_almoxarifado  SET (security_invoker = true);
ALTER VIEW app.vw_sci_pendencia_dado     SET (security_invoker = true);

-- 2.3 almoxarifado - SCM -------------------------------------------------------------
ALTER VIEW app.vw_scm                    SET (security_invoker = true);
ALTER VIEW app.vw_scm_itens              SET (security_invoker = true);
ALTER VIEW app.vw_scm_fila_aprovacao     SET (security_invoker = true);

-- 2.4 utilidades (ja feitas em 02d secao 5; repetidas para este arquivo ser completo) -
ALTER VIEW app.vw_medidor_apontavel      SET (security_invoker = true);
ALTER VIEW app.vw_medidor_painel         SET (security_invoker = true);
ALTER VIEW app.vw_leitura_historico      SET (security_invoker = true);
ALTER VIEW app.vw_util_desvio            SET (security_invoker = true);

-- 2.5 treinamentos -------------------------------------------------------------------
ALTER VIEW app.vw_lms_matricula          SET (security_invoker = true);
ALTER VIEW app.vw_lms_conformidade       SET (security_invoker = true);
ALTER VIEW app.vw_lms_visao_lider        SET (security_invoker = true);
ALTER VIEW app.vw_lms_bloqueada          SET (security_invoker = true);

-- 2.6 operacao -----------------------------------------------------------------------
ALTER VIEW app.vw_email_fila_pendente    SET (security_invoker = true);
ALTER VIEW app.vw_estoque_saldo          SET (security_invoker = true);
ALTER VIEW app.vw_saude_operacional      SET (security_invoker = true);

-- mig.vw_conferencia fica FORA, de proposito. O schema mig e revogado de biotrop_app
-- (02a), existe para o aceite da virada e e conferido pelo dono do banco; contar
-- core.usuario e almox.sci sob a identidade de quem consulta transformaria o confronto
-- "no dump x no banco" em numero errado, que num aceite e pior que numero nenhum. O
-- schema inteiro cai depois da virada (DROP SCHEMA mig CASCADE, passo 7 de 01-base).

-- CONSEQUENCIA ASSUMIDA, PARA NAO VIRAR SURPRESA NO PRIMEIRO RELATORIO:
-- security_invoker vale para QUALQUER role, biotrop_ro incluida. As policies de core,
-- almox e lms nao restringem role (nao tem clausula TO), entao elas passam a ser
-- avaliadas tambem nas consultas de relatorio - e todas chamam app.usuario_atual(),
-- que levanta excecao quando o GUC nao esta definido. Consulta de conferencia por
-- biotrop_ro precisa, a partir daqui, abrir a transacao com
--   SET LOCAL app.usuario_id = '<uuid de um admin>';
-- exatamente como a importacao do mig ja faz (02c, secao 3). Em util o efeito e mais
-- forte e ja existia desde 02d: as 17 policies daquele arquivo sao TO biotrop_app,
-- portanto biotrop_ro nao tem policy permissiva ali e le zero linha - relatorio de
-- utilidades sai pelo dono do banco. Nao contorne isso com BYPASSRLS na role de
-- leitura: 02a para o deploy se biotrop_ro tiver BYPASSRLS, e com razao.

-- Efeito registrado no comentario das duas views que a revisao citou por nome, para
-- quem ler o catalogo amanha nao precisar deduzir.
COMMENT ON VIEW app.vw_usuario IS 'Linha completa do usuario para a tela de cadastro e para o app decidir menu: perfil, permissoes, grupo e responsavel direto, tudo resolvido. Com security_invoker (0002f) obedece pol_usuario_select: cada um ve a propria linha, o responsavel de grupo ve quem esta nos grupos dele, gestor e admin veem todas. responsavel_nome e responsavel_email podem vir nulos para quem nao alcanca a linha do proprio lider - para esse dado use app.meu_aprovador().';
COMMENT ON VIEW app.vw_lms_matricula IS 'Uma linha por matricula com colaborador, time, grupo/cargo, versao, progresso e comprovante. Percentual segue a regra da tela: aulas obrigatorias valem 90% quando existe avaliacao, e a avaliacao fecha os 10% restantes. Com security_invoker (0002f) obedece matricula_sel: a pessoa ve as matriculas dela, o responsavel direto as dos liderados, gestor e admin todas - nota e progresso de terceiro deixaram de sair por esta view.';

-- 2.7 conferencia --------------------------------------------------------------------
-- Por catalogo e nao por lista: view criada em migration futura sem a opcao para o
-- deploy aqui, em vez de vazar em silencio ate a proxima auditoria.
DO $$
DECLARE v_falta text;
BEGIN
  SELECT string_agg(format('%s.%s', n.nspname, c.relname), ', ' ORDER BY c.relname)
    INTO v_falta
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'app'
     AND c.relkind = 'v'
     AND NOT coalesce('security_invoker=true' = ANY (c.reloptions), false);
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION 'View de app sem security_invoker: % - view sem essa opcao le as tabelas como o DONO e ignora todas as policies', v_falta;
  END IF;
END $$;


-- =====================================================================================
-- 3. AS DUAS LEITURAS LEGITIMAS QUE DEPENDIAM DO DIREITO DO DONO
--   Fechar as views derruba, junto, duas leituras que eram legitimas e so funcionavam
--   porque a view rodava como dona. Cada uma volta como funcao SECURITY DEFINER de
--   escopo estreito - porta declarada, com dono e com comentario - em vez de manter uma
--   view inteira aberta. search_path fixo nas duas: SECURITY DEFINER sem search_path
--   fixo e convite a captura de nome, e a conferencia da secao 5 cobra isso.
-- =====================================================================================

-- 3.1 "quem aprova a minha SCM" ------------------------------------------------------
-- app.vw_aprovador_de resolve o aprovador lendo core.usuario DUAS vezes: a pessoa e o
-- responsavel do grupo dela. Sob pol_usuario_select o tecnico nao alcanca a linha do
-- proprio lider (o responsavel costuma estar em outro grupo), entao a view passaria a
-- devolver aprovador_email nulo exatamente para quem precisa do dado ao abrir a SCM.
-- Esta funcao devolve APENAS a linha do usuario da sessao: nao e diretorio, e o proprio
-- dado de quem chama.
CREATE OR REPLACE FUNCTION app.meu_aprovador()
RETURNS TABLE (aprovador_id uuid, aprovador_nome text, aprovador_email citext, origem text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, pg_temp AS $$
  SELECT resp.id,
         CASE
           WHEN resp.id IS NOT NULL AND resp.ativo THEN resp.nome
           WHEN u.email_lider_excecao IS NOT NULL  THEN u.email_lider_excecao::text
         END,
         CASE
           WHEN resp.id IS NOT NULL AND resp.ativo THEN resp.email
           WHEN u.email_lider_excecao IS NOT NULL  THEN u.email_lider_excecao
         END,
         CASE
           WHEN resp.id IS NOT NULL AND resp.ativo THEN 'grupo'
           WHEN u.email_lider_excecao IS NOT NULL  THEN 'excecao'
           ELSE 'nenhum'
         END
    FROM core.usuario u
    LEFT JOIN core.grupo   g    ON g.id = u.grupo_id AND g.ativo
    LEFT JOIN core.usuario resp ON resp.id = g.responsavel_id
   WHERE u.id = app.usuario_atual();
$$;
COMMENT ON FUNCTION app.meu_aprovador() IS 'Aprovador do usuario da SESSAO, com a mesma ordem de app.vw_aprovador_de (responsavel do grupo, depois e-mail de lider por excecao, depois nenhum). Existe porque a view, agora com security_invoker, nao alcanca a linha do lider para quem nao o lidera. Devolve uma unica linha - a de quem esta logado - e por isso nao vira listagem de terceiros.';

REVOKE ALL ON FUNCTION app.meu_aprovador() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.meu_aprovador() TO biotrop_app, biotrop_ro;

-- 3.2 a fila de e-mail para a rotina de entrega --------------------------------------
-- app.vw_email_fila_pendente era a unica leitura possivel da fila sem identidade: a
-- tabela tem pol_email_fila_select = app.eh_admin(), e app.eh_admin() chama
-- app.usuario_atual(), que LEVANTA EXCECAO quando o GUC nao esta definido. Com a view
-- obedecendo a policy, a rotina do Microsoft Graph - que roda na VM, sem usuario
-- logado - deixaria de conseguir ler o que enviar e a fila cresceria calada; o furo 1
-- seria fechado criando uma falha operacional silenciosa, que e o pior tipo de troca.
-- A porta agora e nomeada e inclui corpo_html e copia, que a view nunca incluiu (e sem
-- corpo nao ha e-mail a enviar). Nao muda status: a rotina avanca o status pelo UPDATE
-- de coluna de 02a, que pol_email_fila_update aceita sem exigir identidade.
CREATE OR REPLACE FUNCTION app.email_fila_proximos(p_limite integer DEFAULT 50)
RETURNS TABLE (id uuid, destinatario citext, copia citext[], remetente citext,
               assunto text, corpo_html text, motivo text,
               referencia_tabela text, referencia_id text,
               tentativas smallint, criado_em timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, pg_temp AS $$
  SELECT f.id, f.destinatario, f.copia, f.remetente, f.assunto, f.corpo_html, f.motivo,
         f.referencia_tabela, f.referencia_id, f.tentativas, f.criado_em
    FROM core.email_fila f
   WHERE f.status = 'pendente'
   ORDER BY f.criado_em
   LIMIT greatest(1, least(coalesce(p_limite, 50), 500));
$$;
COMMENT ON FUNCTION app.email_fila_proximos(integer) IS 'Lote de mensagens pendentes para a rotina de entrega via Microsoft Graph, com corpo e copia. SECURITY DEFINER porque a rotina roda na VM sem app.usuario_id e a policy de core.email_fila exige admin. Porta unica e declarada: devolve somente o que esta pendente, com teto de 500 por chamada, e nao alcanca mensagem ja enviada.';

REVOKE ALL ON FUNCTION app.email_fila_proximos(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.email_fila_proximos(integer) TO biotrop_app;

COMMENT ON VIEW app.vw_email_fila_pendente IS 'O que a rotina do Microsoft Graph precisa enviar, sem corpo e sem copia. Com security_invoker (0002f) a leitura e de admin, servindo ao diagnostico na tela ("fila vazia com e-mail nao chegando" x "fila cheia"). A rotina de entrega usa app.email_fila_proximos(), que e a porta com corpo.';


-- =====================================================================================
-- 4. APOIO AO FURO 3: lms.liberar_matricula() VIRA SECURITY DEFINER
--   02a, secao 3.2.2, tirou bloqueada, bloqueada_em e tentativas_liberadas do GRANT de
--   UPDATE da aplicacao. E o que impede o aluno de se dar tentativa infinita: a policy
--   matricula_upd_propria escolhe a LINHA que ele alcanca (a dele) e nao diz nada sobre
--   QUAIS COLUNAS ele reescreve, entao com UPDATE de tabela inteira um
--   "SET tentativas_liberadas = 99" na propria matricula passava por ela.
--   Consequencia do corte: lms.liberar_matricula(), que nao era SECURITY DEFINER, roda
--   com o privilegio de quem chama e passaria a falhar por permissao de coluna -
--   inclusive para o admin. Ou seja, o corte fecharia o abuso e quebraria junto a unica
--   forma legitima de desbloquear alguem. Aqui ela passa a rodar como a dona da tabela.
--   Rodando como dona, ela deixa de ser filtrada pela RLS (lms nao tem FORCE, por
--   decisao registrada em 02e), portanto as duas garantias que eram das policies
--   precisam estar DENTRO do corpo, explicitas:
--     1) app.eh_admin()               - liberar excecao e ato de admin (era
--                                       matricula_upd_gestao + liberacao_ins);
--     2) p_por = app.usuario_atual()  - a excecao sai assinada por quem esta na sessao e
--                                       nao no nome de um terceiro (era o WITH CHECK de
--                                       liberacao_ins). Liberar sem assinar transforma
--                                       lms.liberacao em enfeite.
--   O corpo e o mesmo de 01-base.sql secao 13.5, com essas checagens no inicio.
-- =====================================================================================
CREATE OR REPLACE FUNCTION lms.liberar_matricula(
  p_matricula uuid,
  p_motivo    text,
  p_por       uuid,
  p_extra     smallint DEFAULT 1
) RETURNS lms.matricula
LANGUAGE plpgsql SECURITY DEFINER SET search_path = lms, core, pg_temp AS $$
DECLARE m lms.matricula;
BEGIN
  -- Sem estas duas checagens a funcao seria o furo 3 de volta com outro nome: qualquer
  -- sessao chamaria lms.liberar_matricula(<a minha>, 'porque eu quero', <eu>, 99) e a
  -- funcao, rodando como dona, escreveria tentativas_liberadas sem policy nenhuma no
  -- caminho. A autorizacao e responsabilidade dela mesma.
  IF NOT app.eh_admin() THEN
    RAISE EXCEPTION 'Liberar tentativa de matricula e exclusivo do perfil admin'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_por IS DISTINCT FROM app.usuario_atual() THEN
    RAISE EXCEPTION 'A liberacao precisa sair assinada por quem esta na sessao'
      USING HINT    = 'informe p_por = o usuario logado',
            ERRCODE = 'insufficient_privilege';
  END IF;

  IF nullif(btrim(coalesce(p_motivo, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Informe o motivo da liberacao';
  END IF;

  INSERT INTO lms.liberacao (matricula_id, tentativas_extra, motivo, liberado_por)
  VALUES (p_matricula, p_extra, p_motivo, p_por);

  UPDATE lms.matricula
     SET bloqueada            = false,
         bloqueada_em         = NULL,
         tentativas_liberadas = tentativas_liberadas + p_extra,
         status               = CASE WHEN status = 'reprovada'
                                     THEN 'aguardando_avaliacao'::lms.matricula_status
                                     ELSE status END
   WHERE id = p_matricula
  RETURNING * INTO m;

  IF m.id IS NULL THEN RAISE EXCEPTION 'Matricula inexistente'; END IF;
  RETURN m;
END $$;
COMMENT ON FUNCTION lms.liberar_matricula(uuid, text, uuid, smallint) IS 'Unico caminho para desbloquear matricula e conceder tentativa extra. SECURITY DEFINER desde 0002f porque a aplicacao deixou de ter UPDATE nas colunas bloqueada, bloqueada_em e tentativas_liberadas - o corte de 02a que impede o aluno de se dar tentativa infinita (FURO 3). Confere perfil admin e assinatura do usuario da sessao dentro do corpo, ja que rodando como dona ela nao passa pelas policies de lms.';

REVOKE ALL ON FUNCTION lms.liberar_matricula(uuid, text, uuid, smallint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION lms.liberar_matricula(uuid, text, uuid, smallint) TO biotrop_app;


-- =====================================================================================
-- 5. CONFERENCIA
--   Toda funcao SECURITY DEFINER do escopo tem de ter search_path fixo. Sem isso, a
--   correcao acima nao vale nada: bastaria criar um schema temporario com uma tabela
--   chamada matricula. A checagem para o deploy em vez de virar achado de auditoria.
-- =====================================================================================
DO $$
DECLARE v_falta text;
BEGIN
  SELECT string_agg(n.nspname || '.' || p.proname, ', ' ORDER BY n.nspname || '.' || p.proname)
    INTO v_falta
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('core', 'app', 'almox', 'util', 'lms')
     AND p.prosecdef
     AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(p.proconfig, '{}'::text[])) c
                      WHERE c LIKE 'search\_path=%');
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION 'Funcao SECURITY DEFINER sem search_path fixo: %', v_falta;
  END IF;
END $$;

-- =====================================================================================
-- 6. REGISTRO DESTA MIGRATION
-- =====================================================================================
INSERT INTO core.migration (versao, nome, observacao) VALUES
  ('0002f', 'ajustes-base',
   'Correcao de objeto criado em 01-base.sql, feita em arquivo novo porque migration aplicada nao se reescreve. FURO 4: lms.corrigir_tentativa() passa a exigir identidade de sessao, usuario ativo e que a matricula seja do proprio usuario; admin e excecao unica e registrada em core.auditoria. FURO 1: as 22 views do schema app passam a security_invoker, entao as policies de 02b a 02e valem tambem para quem le pelas telas - vw_usuario deixa de devolver o diretorio inteiro e vw_lms_matricula deixa de devolver nota e progresso de terceiros; mig.vw_conferencia fica de fora de proposito. Duas portas SECURITY DEFINER de escopo estreito repoem o que era legitimo e dependia do direito do dono: app.meu_aprovador() (o proprio aprovador, uma linha) e app.email_fila_proximos() (fila pendente com corpo, para a rotina do Graph que roda sem identidade). Apoio ao FURO 3: lms.liberar_matricula() vira SECURITY DEFINER com checagem de admin e de assinatura no corpo, porque 02a passou a conceder UPDATE por coluna em lms.matricula. Inclui conferencia de security_invoker em toda view de app e de search_path fixo em toda funcao SECURITY DEFINER de core, app, almox e lms.')
ON CONFLICT (versao) DO NOTHING;
