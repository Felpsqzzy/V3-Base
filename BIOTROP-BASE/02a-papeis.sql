-- =====================================================================================
-- BIOTROP - migration 0002a: identidade da sessao, funcoes de papel e privilegios
--   Depende de 01-base.sql. Idempotente. PostgreSQL 15.
--   Este arquivo NAO cria policy nenhuma: ele prepara o vocabulario que as policies
--   de 02b vao usar e liga os GRANTs que a secao 18 da base deixou preparados.
-- =====================================================================================

-- =====================================================================================
-- 1. QUEM E O USUARIO DA SESSAO
--   A identidade vem de um GUC (app.usuario_id), nao de um role do Postgres por pessoa.
--   Motivo: quem autentica e o Microsoft Entra ID, do lado da aplicacao. Criar 200 roles
--   significaria manter no banco uma copia do diretorio da empresa - provisionar,
--   desativar e trocar senha em dois lugares - e ainda abrir um pool de conexao por
--   pessoa. A aplicacao valida o token, resolve o core.usuario.id e executa
--   SET LOCAL app.usuario_id = '<uuid>' na transacao antes de qualquer query.
--   SET LOCAL e essencial: morre no fim da transacao, entao conexao devolvida ao pool
--   nunca carrega a identidade de quem usou antes.
-- =====================================================================================
CREATE OR REPLACE FUNCTION app.usuario_atual() RETURNS uuid
LANGUAGE plpgsql STABLE AS $$
DECLARE v_id uuid;
BEGIN
  -- o segundo argumento true evita erro quando o GUC nunca foi definido
  v_id := nullif(current_setting('app.usuario_id', true), '')::uuid;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'Sessao sem identidade: a aplicacao precisa executar SET LOCAL app.usuario_id antes da query'
      USING HINT = 'SET LOCAL app.usuario_id = ''<uuid do core.usuario>''',
            ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v_id;
END $$;
COMMENT ON FUNCTION app.usuario_atual() IS 'Id do usuario da sessao, lido do GUC app.usuario_id. Falha alto e claro se o GUC nao estiver definido: query sem identidade nao pode passar silenciosamente por uma policy.';

-- =====================================================================================
-- 2. FUNCOES QUE AS POLICIES VAO CHAMAR
--   Todas STABLE (mesmo resultado dentro da query, entao o planejador chama uma vez)
--   e todas SECURITY DEFINER com search_path fixo. O SECURITY DEFINER aqui nao e
--   conveniencia: sem ele, a policy de core.usuario chamaria uma funcao que le
--   core.usuario e o Postgres entraria em recursao infinita de policy.
--   Cada uma le apenas a propria linha do usuario da sessao - nao vaza dado de terceiro.
-- =====================================================================================
CREATE OR REPLACE FUNCTION app.tem_perfil(p_perfis text[]) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1
      FROM core.usuario u
     WHERE u.id = app.usuario_atual()
       AND u.ativo
       AND NOT u.bloqueado
       AND u.perfil_id = ANY (p_perfis)
  );
$$;
COMMENT ON FUNCTION app.tem_perfil(text[]) IS 'Verdadeiro se o usuario da sessao esta ativo, nao bloqueado e tem um dos perfis informados (admin, gestor, pcm, almoxarife, lider, tecnico, viewer). Inclui a checagem de ativo/bloqueado de proposito: bloquear alguem na tela precisa cortar o acesso na mesma hora, sem depender de a policy lembrar de somar duas condicoes.';

CREATE OR REPLACE FUNCTION app.eh_admin() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, pg_temp AS $$
  SELECT app.tem_perfil(ARRAY['admin']);
$$;
COMMENT ON FUNCTION app.eh_admin() IS 'Somente o perfil admin (o perfil fixo de sistema). Nao inclui gestor: gestor tem a mesma amplitude na operacao, mas quem precisa dos dois escreve app.tem_perfil(ARRAY[''admin'',''gestor'']) na propria policy, para ficar visivel na leitura que aquela tabela tambem abre para gestor.';

-- ATENCAO A ORDEM (correcao do FURO 7): app.usuario_ativo() passou a ser DEFINIDA
-- ANTES de app.grupos_que_lidero(), porque agora e chamada por ela. Funcao
-- LANGUAGE sql tem o corpo analisado no momento do CREATE (check_function_bodies),
-- entao deixar usuario_ativo() depois faria 02a falhar num banco novo com
-- "function app.usuario_ativo() does not exist". Nao reordene de volta.
CREATE OR REPLACE FUNCTION app.usuario_ativo() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1
      FROM core.usuario u
     WHERE u.id = app.usuario_atual()
       AND u.ativo
       AND NOT u.bloqueado
  );
$$;
COMMENT ON FUNCTION app.usuario_ativo() IS 'Verdadeiro se o id da sessao corresponde a um usuario existente, ativo e nao bloqueado. Porta de entrada de toda policy: um uuid qualquer no GUC nao vira acesso.';

-- =====================================================================================
-- CORRECAO DO FURO 7 - QUEM FOI BLOQUEADO PARA DE LIDERAR NA MESMA HORA
--   O furo: esta funcao conferia apenas core.grupo.ativo e o casamento de
--   responsavel_id, e NUNCA o estado de quem estava na sessao. Como ela e a raiz de
--   todo o escopo de lideranca - app.eh_do_meu_grupo() (02c) e app.lidero_usuario()
--   (02e) apenas a envolvem -, um lider desligado (ativo = false) ou bloqueado
--   (bloqueado = true) continuava sendo devolvido como responsavel dos grupos dele.
--   Consequencia pratica: atribuicao_sel e as policies matricula_*/progresso_*/
--   tentativa_*/liberacao_*/conclusao_* de 02e, mais sci_sel e scm_sel de 02c, tinham
--   um ramo "ou e do meu grupo" que passava para quem a tela ja havia bloqueado - ele
--   seguia lendo matricula, nota, progresso e solicitacao de compra da equipe inteira.
--   Bloquear alguem tem de cortar o acesso na hora, sem depender de cada policy
--   lembrar de somar app.usuario_ativo() em cada ramo.
--   A partir daqui: sem usuario ativo e nao bloqueado o conjunto volta VAZIO, e todo
--   ramo de escopo derivado dele fica falso por consequencia.
-- =====================================================================================
CREATE OR REPLACE FUNCTION app.grupos_que_lidero() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, pg_temp AS $$
  SELECT g.id
    FROM core.grupo g
   -- FURO 7: a condicao de sessao vem primeiro de proposito. app.usuario_ativo() e
   -- STABLE e nao depende da linha, entao o planejador a avalia uma vez, como filtro
   -- constante: quem esta inativo ou bloqueado nao chega nem a varrer core.grupo.
   WHERE app.usuario_ativo()
     AND g.ativo
     AND g.responsavel_id = app.usuario_atual();
$$;
COMMENT ON FUNCTION app.grupos_que_lidero() IS 'Grupos em que o usuario da sessao e o responsavel direto (core.grupo.responsavel_id). E a base da visao do lider e da aprovacao de SCM: quem aprova e o responsavel do grupo de quem pediu. Desde a correcao do FURO 7 exige app.usuario_ativo(): lider inativo ou bloqueado devolve conjunto vazio, e com isso app.eh_do_meu_grupo e app.lidero_usuario ficam falsas sem que cada policy precise repetir a condicao. Devolve conjunto vazio para quem nao lidera nada - use com IN/EXISTS, nao com = .';

-- =====================================================================================
-- 3. ROLES
--   biotrop_app    - a aplicacao. Escreve o que o fluxo pede e nao ve gabarito.
--   biotrop_ro     - leitura para relatorio e conferencia.
--   biotrop_worker - a rotina de entrega de e-mail da VM (correcao do FURO 5).
--   O nome da role de leitura e biotrop_ro porque a secao 18 de 01-base.sql ja concede
--   privilegio para esse nome exato; criar biotrop_leitura deixaria aquele bloco morto.
--   Nenhuma das tres e superuser nem dona das tabelas: dono e superuser ignoram RLS, e
--   uma policy que o cliente pula nao e uma policy. Senha e definida fora do DDL
--   (ALTER ROLE ... PASSWORD, ou pg_hba/Entra na VM), para nao ficar em arquivo versionado.
--
--   POR QUE EXISTE UMA TERCEIRA ROLE (FURO 5):
--   a rotina que entrega core.email_fila via Microsoft Graph roda na VM, agendada, SEM
--   usuario logado - nao ha token do Entra ID e portanto nao ha SET LOCAL app.usuario_id.
--   Ela conectava como biotrop_app e travava, porque um "UPDATE ... WHERE status =
--   'pendente'" nao aplica so a policy de UPDATE: o comando LE as linhas existentes,
--   entao o PostgreSQL aplica tambem as policies de SELECT da tabela. A de SELECT era
--   pol_email_fila_select USING (app.eh_admin()), que numa sessao sem GUC nem devolve
--   false - app.usuario_atual() levanta insufficient_privilege. Resultado: zero e-mail
--   entregue, ou erro seco no log da VM, e a fila crescendo em silencio.
--   Dar identidade de admin para a rotina resolveria e seria a escolha errada: uma conta
--   de servico com poder de admin no banco e exatamente o que nao se quer numa VM com
--   agendador. A rotina ganha uma role propria, cujo universo inteiro e a fila de
--   e-mail, e as policies dela vem em 02b amarradas por TO biotrop_worker.
-- =====================================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'biotrop_app') THEN
    CREATE ROLE biotrop_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'biotrop_ro') THEN
    CREATE ROLE biotrop_ro  LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
  -- FURO 5: role da rotina de e-mail. Criada aqui, e nao em 02b, porque as policies
  -- de 02b usam "TO biotrop_worker" e CREATE POLICY exige que a role ja exista.
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'biotrop_worker') THEN
    CREATE ROLE biotrop_worker LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
  END IF;
END $$;

-- Conferencia: se alguma das tres voltar como superuser ou com BYPASSRLS, as policies
-- de 02b nao valem nada. A checagem para o deploy em vez de descobrir isso em auditoria.
DO $$
DECLARE v_role text;
BEGIN
  SELECT string_agg(rolname, ', ') INTO v_role
    FROM pg_roles
   WHERE rolname IN ('biotrop_app', 'biotrop_ro', 'biotrop_worker')
     AND (rolsuper OR rolbypassrls);
  IF v_role IS NOT NULL THEN
    RAISE EXCEPTION 'Role de cliente com superuser ou BYPASSRLS: % - RLS nao seria aplicado', v_role;
  END IF;
END $$;

-- 3.1 aplicacao ----------------------------------------------------------------------
GRANT USAGE ON SCHEMA core, almox, util, lms, pcm, app TO biotrop_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core, almox, util, pcm TO biotrop_app;
GRANT SELECT ON ALL TABLES IN SCHEMA app TO biotrop_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA core, almox, util, lms, pcm TO biotrop_app;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA core, almox, util, lms, pcm, app TO biotrop_app;

-- Auditoria e log de login sao append-only: quem reescreve o log apaga o proprio rastro.
REVOKE UPDATE, DELETE ON core.auditoria    FROM biotrop_app;
REVOKE UPDATE, DELETE ON core.login_evento FROM biotrop_app;

-- O schema mig fica fora da aplicacao: a importacao roda pelo dono do banco, uma vez.
REVOKE ALL ON SCHEMA mig FROM biotrop_app;

-- CORRECAO DO FURO 6 (parte 1 de 2) - REVOGAR O SCHEMA NAO REVOGA AS TABELAS.
--   O REVOKE acima tira o USAGE do schema, o que hoje ja basta para "SELECT * FROM
--   mig.dump" falhar. Mas o privilegio de TABELA concedido pela secao 18 de
--   01-base.sql (GRANT SELECT ON ALL TABLES IN SCHEMA ... mig) CONTINUA na ACL de cada
--   tabela: ele nao foi apagado, so ficou inutilizavel enquanto falta o USAGE. Um
--   unico "GRANT USAGE ON SCHEMA mig" futuro - num script de suporte, num deploy
--   apressado - devolve a leitura do export inteiro do localStorage sem que ninguem
--   escreva uma linha nova de GRANT em tabela e sem deixar rastro de intencao.
--   Privilegio que sobra e armadilha: aqui ele e apagado de verdade.
REVOKE ALL ON ALL TABLES    IN SCHEMA mig FROM biotrop_app;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA mig FROM biotrop_app;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA mig FROM biotrop_app;

-- LMS tabela por tabela, porque lms.questao_opcao e a excecao
GRANT SELECT, INSERT, UPDATE, DELETE ON lms.treinamento, lms.versao, lms.aula,
  lms.avaliacao, lms.questao, lms.atribuicao, lms.matricula, lms.progresso_aula,
  lms.tentativa, lms.tentativa_resposta, lms.liberacao, lms.conclusao TO biotrop_app;

-- =====================================================================================
-- 3.2 ONDE A REGRA E POR COLUNA, O GRANT TAMBEM TEM DE SER POR COLUNA
--   CORRECAO (revisao adversarial, furos 3 e 10).
--
--   O problema: RLS filtra LINHA, nunca COLUNA. Uma policy de UPDATE cujo texto
--   pressupoe "esta coluna nao muda" nao pressupoe nada - ela so descreve QUAIS linhas
--   o comando alcanca, e dentro da linha alcancada o UPDATE pode reescrever qualquer
--   coluna para a qual a role tenha privilegio. E privilegio de TABELA sempre vence
--   privilegio de COLUNA: um unico "GRANT UPDATE ON tabela" apaga, em silencio, todo
--   "GRANT UPDATE (col) ON tabela" concedido antes ou depois.
--
--   Por que os blocos abaixo ficam AQUI e nao apenas em 02b/02c/02e: os GRANTs amplos
--   das linhas acima (e os da secao 18 de 01-base.sql) sao amplos de proposito, mas nao
--   podem ser a ULTIMA palavra. Este arquivo se declara idempotente; reaplicar 02a
--   sozinho - coisa que se faz para recriar uma role ou conferir privilegio - restaurava
--   o UPDATE de tabela inteira e derrubava as restricoes de coluna de 02b, sem erro
--   nenhum no log. Corrigindo no proprio 02a, qualquer ordem de reexecucao (02a, ou
--   02a+02b, ou os cinco arquivos) termina com a mesma matriz de privilegio.
--
--   Ordem obrigatoria em cada bloco: REVOKE de tabela primeiro, GRANT de coluna depois.
-- =====================================================================================

-- 3.2.1 core.email_fila --------------------------------------------------------------
-- Furo 10. A rotina de entrega (Microsoft Graph) precisa marcar o resultado do envio,
-- e a policy pol_email_fila_update de 02b nao exige identidade justamente por isso.
-- Com UPDATE de tabela inteira, essa mesma rotina - e qualquer SQL que use a role da
-- aplicacao - podia reescrever destinatario, assunto e corpo_html de uma mensagem
-- pendente: a fila deixaria de ser prova do que o sistema avisou e passaria a ser um
-- canal de envio de texto arbitrario assinado pela conta corporativa.
REVOKE UPDATE ON core.email_fila FROM biotrop_app;
GRANT  UPDATE (status, tentativas, erro, graph_message_id, enviado_em)
  ON core.email_fila TO biotrop_app;

-- 3.2.2 lms.matricula ----------------------------------------------------------------
-- Furo 3. matricula_upd_propria (02e) precisa deixar o ALUNO atualizar a PROPRIA
-- matricula, porque lms.registrar_progresso() nao e SECURITY DEFINER e grava status e
-- iniciado_em com a identidade de quem estuda. Com UPDATE de tabela inteira, a mesma
-- linha permitia "UPDATE lms.matricula SET tentativas_liberadas = 99 WHERE id = <a
-- minha>": tentativa infinita na avaliacao, porque o limite que lms.corrigir_tentativa
-- confere e versao.tentativas_maximas + matricula.tentativas_liberadas. Pelo mesmo
-- caminho o aluno saia do bloqueio (bloqueada/bloqueada_em) ou trocaria de versao.
-- Ficam de fora do GRANT, portanto imutaveis para a aplicacao:
--   id, origem_id, criado_em          - identidade da linha;
--   usuario_id                        - e a premissa das duas policies de UPDATE;
--   treinamento_id, versao_id         - trocar a versao zera o cotejo de progresso;
--   bloqueada, bloqueada_em,
--   tentativas_liberadas              - so por lms.liberar_matricula(), que 02f torna
--                                       SECURITY DEFINER com checagem de admin.
-- status continua concedido porque registrar_progresso depende dele; um status
-- 'concluida' forjado nao gera comprovante (lms.conclusao tem policy propria e
-- vw_lms_conformidade decide por codigo_comprovante, nao por status).
REVOKE UPDATE ON lms.matricula FROM biotrop_app;
GRANT  UPDATE (status, iniciado_em, concluido_em, prazo_em, obrigatoria,
               atribuicao_id, atualizado_em)
  ON lms.matricula TO biotrop_app;

-- 3.2.3 almox.scm --------------------------------------------------------------------
-- Mesma classe de furo nas policies de 02c: scm_upd_aprovacao, scm_upd_tratativa e
-- scm_upd_gestao se apoiam em "solicitante_id IS DISTINCT FROM app.usuario_atual()"
-- (ninguem decide a propria compra) e essa negacao vale sobre a linha ANTIGA - nada na
-- policy impede que o mesmo UPDATE reescreva a identidade do solicitante e transfira a
-- solicitacao para um terceiro, apagando de quem era a compra.
-- Ficam fora do GRANT: id, origem_id, codigo, criado_em (identidade da linha) e
-- solicitante_id, solicitante_nome, solicitante_email, solicitante_time (autoria).
-- aprovador_id, aprovador_email e aprovador_origem CONTINUAM concedidos de proposito:
-- ali a amarra certa e de policy, nao de privilegio - 02c passou a exigir
-- app.scm_aprovador_valido(solicitante_id, aprovador_id) nos WITH CHECK, o que barra o
-- solicitante apontando um colega combinado e ao mesmo tempo permite o unico caso
-- legitimo de troca (admin/gestor destravando SCM cujo responsavel de grupo saiu).
-- Cortar por coluna aqui mataria esse caso legitimo sem fechar nada a mais.
REVOKE UPDATE ON almox.scm FROM biotrop_app;
GRANT  UPDATE (time_solicitante, tipo_solicitacao, capex_projeto, camm, urgencia,
               centro_custo_id, numero_om, tipo_fornecedor, nome_fornecedor,
               tipo_pedido, descricao_uso, status,
               aprovador_id, aprovador_email, aprovador_origem,
               decidido_por_id, decidido_em,
               observacao_lider, observacao_almoxarife, numero_processo_me,
               atualizado_em)
  ON almox.scm TO biotrop_app;

-- 3.2.4 almox.sci --------------------------------------------------------------------
-- sci_upd_fila e sci_upd_gestao dependem de solicitante_id para negar que alguem trate
-- a propria SCI, e sci_upd_solicitante devolve a linha para a fila supondo que ela
-- continua sendo a mesma solicitacao. familia_id define quais campos dinamicos existem
-- (almox.familia_campo): trocar familia depois de preenchido deixaria almox.sci_valor_campo
-- apontando para campo de outra familia, e o formulario mostraria valor no rotulo errado.
-- campos_originais e a carga bruta importada do localStorage - evidencia, nao dado de tela.
REVOKE UPDATE ON almox.sci FROM biotrop_app;
GRANT  UPDATE (link, marcas_homologadas, observacoes, foto_anexo_id, status,
               numero_solicitacao_cadastro, codigo_item, observacao_almoxarife,
               aviso_solicitante_em, aviso_solicitante_lido, atualizado_em)
  ON almox.sci TO biotrop_app;

-- 3.2.5 conferencia ------------------------------------------------------------------
-- Um REVOKE que nao pegou, ou um GRANT amplo reintroduzido em migration futura, devolve
-- o furo sem deixar rastro. Aqui o deploy para: se a role ainda tiver UPDATE de TABELA
-- em qualquer das quatro, o privilegio de coluna acima esta anulado.
DO $$
DECLARE v_erro text;
BEGIN
  SELECT string_agg(format('%s.%s', t.schemaname, t.tablename), ', ')
    INTO v_erro
    -- casts explicitos: literal em VALUES entra como "unknown" e format() nao resolve
    FROM (VALUES ('core'::text, 'email_fila'::text), ('lms', 'matricula'),
                 ('almox', 'scm'), ('almox', 'sci')) AS t(schemaname, tablename)
   WHERE has_table_privilege('biotrop_app',
           format('%I.%I', t.schemaname, t.tablename), 'UPDATE');
  IF v_erro IS NOT NULL THEN
    RAISE EXCEPTION 'biotrop_app ainda tem UPDATE de tabela inteira em: % - privilegio de tabela anula o privilegio de coluna', v_erro;
  END IF;
END $$;

-- =====================================================================================
-- 3.3 biotrop_worker - A ROTINA DE E-MAIL, E SO ELA   (correcao do FURO 5)
--   Menor privilegio levado a serio: esta role nao tem USAGE em almox, util, lms, pcm
--   nem mig, e nao tem SELECT em nenhuma outra tabela de core. O universo dela e
--   core.email_fila.
--   Uma ressalva dita em voz alta, para ninguem confiar em mais do que existe: no
--   PostgreSQL o EXECUTE de funcao e concedido a PUBLIC por padrao, e REVOKE de uma
--   role nao apaga o que foi concedido a PUBLIC. Portanto esta role AINDA consegue
--   chamar funcao de core/app - inclusive app.usuario_atual(), que sem GUC apenas
--   levanta excecao. Isso e inofensivo porque as funcoes que decidem acesso leem
--   core.usuario pelo id da SESSAO (que aqui nao existe) e as SECURITY DEFINER
--   sensiveis tem o EXECUTE tirado de PUBLIC no ponto onde sao criadas - e o caso de
--   core.provisionar_acesso, em 02b. Nao adicione SECURITY DEFINER nova sem fazer o
--   mesmo: senao a conta de servico da VM ganha o poder dela de graca.
--
--   SELECT por COLUNA, nao por tabela: a rotina precisa de destinatario, copia,
--   remetente, assunto e corpo_html para montar a mensagem no Graph, e de status,
--   tentativas e criado_em para escolher a proxima e fazer backoff. Nao precisa de
--   referencia_tabela, referencia_id, motivo, erro, graph_message_id nem enviado_em -
--   entao nao recebe. Se um dia a fila ganhar coluna com dado de terceiro, a role nova
--   nao a enxerga por omissao, que e o comportamento que se quer de conta de servico.
--   Quais LINHAS ela alcanca e assunto de RLS (pol_email_fila_worker_* em 02b): SELECT
--   e UPDATE apenas de 'pendente' e 'enviando'. Mensagem ja entregue sai do alcance
--   dela, e portanto nao da para reler o corpo do que ja foi enviado.
--
--   UPDATE apenas das colunas de status de envio, pelo motivo de sempre: RLS filtra
--   LINHA, nunca COLUNA. Sem este corte, a mesma rotina que entrega poderia reescrever
--   destinatario, assunto e corpo_html de uma mensagem pendente - a fila deixaria de
--   ser prova do que o sistema avisou e viraria um canal de texto arbitrario assinado
--   pela conta corporativa. Ordem obrigatoria: REVOKE de tabela primeiro (derruba
--   qualquer privilegio amplo herdado), GRANT de coluna depois.
-- =====================================================================================
GRANT USAGE ON SCHEMA core TO biotrop_worker;

REVOKE ALL ON ALL TABLES    IN SCHEMA core, almox, util, lms, pcm, app, mig FROM biotrop_worker;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA core, almox, util, lms, pcm, app      FROM biotrop_worker;
REVOKE ALL ON SCHEMA almox, util, lms, pcm, app, mig FROM biotrop_worker;

GRANT SELECT (id, destinatario, copia, remetente, assunto, corpo_html,
              status, tentativas, criado_em)
  ON core.email_fila TO biotrop_worker;
GRANT UPDATE (status, tentativas, erro, graph_message_id, enviado_em)
  ON core.email_fila TO biotrop_worker;

-- Conferencia. Dois erros silenciosos que este bloco impede de sair do deploy:
--   1) privilegio de TABELA sobrevivendo e anulando o privilegio de COLUNA acima;
--   2) a role alcancando qualquer tabela que nao seja core.email_fila - o que
--      transformaria a conta de servico da VM em leitora do banco.
DO $$
DECLARE v_erro text;
BEGIN
  IF has_table_privilege('biotrop_worker', 'core.email_fila', 'UPDATE')
     OR has_table_privilege('biotrop_worker', 'core.email_fila', 'SELECT') THEN
    RAISE EXCEPTION 'biotrop_worker tem SELECT/UPDATE de TABELA em core.email_fila - privilegio de tabela anula o privilegio de coluna e devolveria o acesso a destinatario, assunto e corpo_html';
  END IF;

  SELECT string_agg(format('%s.%s', table_schema, table_name), ', ')
    INTO v_erro
    FROM information_schema.table_privileges
   WHERE grantee = 'biotrop_worker'
     AND NOT (table_schema = 'core' AND table_name = 'email_fila');
  IF v_erro IS NOT NULL THEN
    RAISE EXCEPTION 'biotrop_worker recebeu privilegio fora de core.email_fila: % - a rotina de e-mail nao tem motivo para alcancar outra tabela', v_erro;
  END IF;
END $$;

-- =====================================================================================
-- 4. A NEGACAO DO GABARITO
--   lms.questao_opcao.correta e o gabarito. A aplicacao pode montar e editar a questao,
--   mas nao pode LER a resposta certa: um "select *" numa tela de aluno mandaria o
--   gabarito para o navegador, onde qualquer aba de rede o mostra.
--   Ordem importa: REVOKE de tabela primeiro (derruba qualquer SELECT amplo herdado do
--   GRANT ... ON ALL TABLES), depois GRANT coluna a coluna. Privilegio de coluna nao
--   sobrevive a um privilegio de tabela existente.
--   lms.corrigir_tentativa(uuid, jsonb) e SECURITY DEFINER: roda como dona da tabela,
--   entao continua lendo a coluna correta e devolve so nota, aprovacao e tentativas
--   restantes. Corrigir avaliacao e ato do banco, nao do navegador.
-- =====================================================================================
REVOKE SELECT ON lms.questao_opcao FROM biotrop_app;
GRANT  SELECT (id, questao_id, posicao, texto) ON lms.questao_opcao TO biotrop_app;
GRANT  INSERT, UPDATE, DELETE ON lms.questao_opcao TO biotrop_app;
GRANT  EXECUTE ON FUNCTION lms.corrigir_tentativa(uuid, jsonb) TO biotrop_app;

-- 4.1 leitura ------------------------------------------------------------------------
-- CORRECAO DO FURO 6 (parte 2 de 2) - mig SAI DA ROLE DE RELATORIO.
--   Estas duas linhas concediam USAGE em mig e SELECT em ALL TABLES IN SCHEMA mig para
--   biotrop_ro, repetindo a secao 18 de 01-base.sql. mig.dump guarda o export bruto do
--   localStorage: usuarios com e-mail e cargo, todas as SCI e SCM, leituras e o modulo
--   de treinamentos inteiro - nota e reprovacao de cada pessoa - em jsonb, numa tabela
--   sem policy nenhuma. Quem recebia a role de relatorio para "ver indicadores" lia,
--   por essa porta, o banco antigo completo, sem passar por uma linha de RLS: o dado
--   que 02b a 02e passam cinco arquivos protegendo na forma normalizada estava aberto
--   na forma crua, no mesmo cluster.
--   Nao ha meio-termo aqui (um "SELECT so em vw_conferencia", por exemplo): a view le
--   mig.dump e core.usuario como DONA (ver 02f e 02g) justamente para o confronto de
--   quantidade sair certo, entao concede-la a biotrop_ro seria conceder o conteudo por
--   tabela interposta. Relatorio nao tem nada a fazer no schema da virada: mig existe
--   por semanas, e conferido pelo dono do banco e cai inteiro depois do aceite
--   (DROP SCHEMA mig CASCADE, passo 7 de 01-base).
GRANT USAGE ON SCHEMA core, almox, util, lms, pcm, app TO biotrop_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA core, almox, util, pcm, app TO biotrop_ro;

-- REVOKE explicito, e nao apenas a ausencia do GRANT acima: 01-base.sql JA foi
-- aplicada e 02a se declara idempotente. Num banco que ja rodou a versao anterior
-- destas linhas, tirar mig da lista nao desfaz nada - o privilegio esta gravado na ACL
-- e continuaria valendo em silencio. Estes REVOKEs sao o que efetivamente fecha o
-- schema, em banco novo e em banco existente.
REVOKE ALL ON ALL TABLES    IN SCHEMA mig FROM biotrop_ro;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA mig FROM biotrop_ro;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA mig FROM biotrop_ro;
REVOKE ALL ON SCHEMA mig FROM biotrop_ro;
-- PUBLIC tambem: EXECUTE de funcao nasce concedido a PUBLIC no PostgreSQL, e as
-- funcoes mig.importar_* escrevem em core, almox, util e lms. Elas nao sao SECURITY
-- DEFINER (rodam com o direito de quem chama), entao PUBLIC executando-as nao ganha
-- poder novo - mas sem USAGE no schema nem da para chama-las, e deixar o EXECUTE
-- pendurado em PUBLIC e o tipo de sobra que a proxima concessao de USAGE transforma em
-- furo. A porta legitima da importacao passa a ser app.mig_importar_dump (02g).
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA mig FROM PUBLIC;
REVOKE ALL ON SCHEMA mig FROM PUBLIC;
GRANT SELECT ON lms.treinamento, lms.versao, lms.aula, lms.avaliacao, lms.questao,
  lms.atribuicao, lms.matricula, lms.progresso_aula, lms.tentativa,
  lms.tentativa_resposta, lms.liberacao, lms.conclusao TO biotrop_ro;
REVOKE SELECT ON lms.questao_opcao FROM biotrop_ro;
GRANT  SELECT (id, questao_id, posicao, texto) ON lms.questao_opcao TO biotrop_ro;
GRANT  EXECUTE ON FUNCTION app.usuario_atual(), app.tem_perfil(text[]), app.eh_admin(),
  app.grupos_que_lidero(), app.usuario_ativo() TO biotrop_ro;

-- 4.2 objetos futuros ----------------------------------------------------------------
-- Para ninguem descobrir tabela sem GRANT depois do proximo deploy. lms fica de fora
-- de proposito: tabela nova de avaliacao entra na mao, decidindo coluna por coluna.
--
-- CORRECAO DO FURO 12 - pcm SAI DA LISTA DE TABELAS FUTURAS, PELO MESMO MOTIVO DE lms.
--   ALTER DEFAULT PRIVILEGES e uma promessa feita a uma tabela que ainda nao existe:
--   ela nasce concedida. Numa tabela de core/almox/util isso e seguro porque aquelas
--   migrations trazem policy junto e as conferencias de 02b a 02e param o deploy se
--   faltar RLS. pcm e o oposto: o modulo e etapa posterior, ninguem escreveu a regra
--   dele ainda, e a promessa fazia com que a primeira tabela criada por quem for
--   especificar o modulo (pcm.apontamento_hora, pcm.checklist, o que vier) chegasse
--   com CRUD completo para a aplicacao e RLS desligado - gravavel por QUALQUER usuario
--   logado, inclusive viewer, no dia em que a tabela nasce. Tabela de modulo nao
--   especificado entra na mao, com a policy escrita na mesma migration.
--   O corte e o remedio principal; a checagem de RLS em 4.3 e a rede de seguranca,
--   porque privilegio tambem chega por GRANT escrito na mao.
ALTER DEFAULT PRIVILEGES IN SCHEMA core, almox, util
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO biotrop_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA app
  GRANT SELECT ON TABLES TO biotrop_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA core, almox, util, lms, pcm
  GRANT USAGE, SELECT ON SEQUENCES TO biotrop_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA core, almox, util, app
  GRANT SELECT ON TABLES TO biotrop_ro;

-- Tirar pcm da lista acima nao desfaz a promessa que uma aplicacao anterior de 02a ja
-- gravou em pg_default_acl - default privilege nao se apaga por omissao, exatamente
-- como privilegio de tabela. O REVOKE abaixo e o que realmente cancela a promessa, em
-- banco novo e em banco que ja rodou a versao anterior deste arquivo.
-- SEQUENCES continuam concedidas: sequence nao guarda dado de ninguem, e uma tabela
-- futura de pcm sem USAGE na propria sequence quebraria o INSERT do admin sem fechar
-- nada. O que se corta e o acesso ao DADO.
ALTER DEFAULT PRIVILEGES IN SCHEMA pcm
  REVOKE SELECT, INSERT, UPDATE, DELETE ON TABLES FROM biotrop_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA pcm
  REVOKE SELECT ON TABLES FROM biotrop_ro;
-- mig nunca teve default privilege e nao ganha agora: registrado para nao voltar por
-- simetria numa leitura distraida da lista acima (FURO 6).

-- 4.3 conferencia dos dois schemas que a revisao adversarial pegou abertos ------------
-- FURO 6 e FURO 12. Os dois furos tem a mesma forma: privilegio amplo sobrevivendo ao
-- arquivo que devia te-lo cortado. Um REVOKE que nao pegou, ou um GRANT reintroduzido
-- em migration futura, devolve o acesso sem erro e sem rastro - e a descoberta viraria
-- achado de auditoria, nao linha de log. O deploy para aqui.
DO $$
DECLARE v_erro text;
BEGIN
  -- 1) mig e do dono do banco, e de mais ninguem. Vale para as tres roles de cliente
  --    de uma vez: qualquer privilegio em qualquer objeto de mig e furo.
  SELECT string_agg(DISTINCT format('%s -> %s.%s', grantee, table_schema, table_name), ', ')
    INTO v_erro
    FROM information_schema.table_privileges
   WHERE table_schema = 'mig'
     AND grantee IN ('biotrop_app', 'biotrop_ro', 'biotrop_worker', 'PUBLIC');
  IF v_erro IS NOT NULL THEN
    RAISE EXCEPTION 'Role de cliente com privilegio em mig: % - mig.dump guarda o export bruto do localStorage (usuarios, solicitacoes, leituras e treinamentos de todo mundo) e o acesso e exclusivo do dono do banco', v_erro;
  END IF;

  SELECT string_agg(r.rolname, ', ')
    INTO v_erro
    FROM pg_roles r
   WHERE r.rolname IN ('biotrop_app', 'biotrop_ro', 'biotrop_worker')
     AND has_schema_privilege(r.rolname, 'mig', 'USAGE');
  IF v_erro IS NOT NULL THEN
    RAISE EXCEPTION 'Role de cliente com USAGE no schema mig: % - a importacao roda pelo dono, e pela aplicacao so por app.mig_importar_dump (02g)', v_erro;
  END IF;

  -- 2) pcm nao pode ter tabela sem RLS ligado. Esta e a checagem que sobrevive a
  --    qualquer GRANT futuro: mesmo que alguem devolva o privilegio amplo, tabela sem
  --    policy nao passa daqui. As policies estao em 02g; a ordem de aplicacao coloca
  --    02a ANTES, entao num banco novo esta checagem so pode ser feita sobre as
  --    tabelas que 01-base criou - e elas ainda nao tem RLS neste ponto.
  --    Por isso ela roda condicionada: se 0002g ja foi registrada, exige RLS em tudo.
  --    Assim o primeiro deploy passa e todo deploy posterior (inclusive a reaplicacao
  --    isolada de 02a, que e o caminho pelo qual os furos 3 e 10 voltavam) confere.
  IF EXISTS (SELECT 1 FROM core.migration WHERE versao = '0002g') THEN
    SELECT string_agg(c.relname, ', ' ORDER BY c.relname)
      INTO v_erro
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'pcm'
       AND c.relkind IN ('r', 'p')
       AND NOT c.relrowsecurity;
    IF v_erro IS NOT NULL THEN
      RAISE EXCEPTION 'Tabela de pcm sem RLS habilitado: % - o modulo e etapa posterior, mas a aplicacao ja alcanca o schema; tabela nova de pcm entra com policy na mesma migration (ver 02g, secao 3)', v_erro;
    END IF;
  END IF;
END $$;

-- =====================================================================================
-- 5. REGISTRO DESTA MIGRATION
-- =====================================================================================
INSERT INTO core.migration (versao, nome, observacao) VALUES
  ('0002a', 'papeis',
   'Identidade da sessao por GUC app.usuario_id, funcoes app.usuario_atual/tem_perfil/eh_admin/grupos_que_lidero/usuario_ativo, roles biotrop_app e biotrop_ro com privilegios e negacao de leitura do gabarito em lms.questao_opcao. UPDATE de tabela inteira substituido por UPDATE de coluna em core.email_fila, lms.matricula, almox.scm e almox.sci, porque RLS filtra linha e nao coluna e privilegio de tabela anula privilegio de coluna. FURO 7: app.grupos_que_lidero() passa a exigir app.usuario_ativo(), entao lider inativo ou bloqueado deixa de liderar na hora e app.eh_do_meu_grupo (02c) e app.lidero_usuario (02e) ficam falsas por consequencia; usuario_ativo foi movida para ANTES dela porque o corpo de funcao LANGUAGE sql e validado no CREATE. FURO 5: role biotrop_worker para a rotina de entrega de e-mail da VM, que roda sem usuario logado, com SELECT por coluna e UPDATE apenas das colunas de status de envio em core.email_fila e nada mais no banco. FURO 6: o schema mig sai das duas roles de cliente - o REVOKE de SCHEMA que ja existia nao apagava o privilegio de TABELA vindo da secao 18 de 01-base, e biotrop_ro ainda tinha USAGE + SELECT em ALL TABLES, ou seja, o export bruto do localStorage (mig.dump) inteiro para quem tem perfil de relatorio; agora ha REVOKE de tabela, sequence, funcao, schema e PUBLIC, e as policies e a porta admin ficam em 02g. FURO 12: pcm sai do ALTER DEFAULT PRIVILEGES de TABLES (fica so SEQUENCES), pelo mesmo motivo de lms - tabela de modulo nao especificado nascia com CRUD para a aplicacao e sem RLS -, com ALTER DEFAULT PRIVILEGES ... REVOKE para cancelar a promessa ja gravada em pg_default_acl. Secao 4.3 nova: bloco DO que barra o deploy se qualquer role de cliente tiver privilegio ou USAGE em mig, ou se existir tabela em pcm sem RLS ligado. Sem policy: as policies entram em 02b a 02g.')
ON CONFLICT (versao) DO NOTHING;
