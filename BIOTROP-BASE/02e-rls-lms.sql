-- =====================================================================================
-- BIOTROP - migration 0002e: RLS do schema lms (treinamentos)
--   Depende de 01-base.sql e 02a-papeis.sql. Idempotente. PostgreSQL 15.
--   Regras que este arquivo implementa:
--     1) cada pessoa le e escreve o PROPRIO progresso; nunca o de outra;
--     2) responsavel direto de grupo LE (nunca escreve) matricula, progresso,
--        tentativa e conclusao de quem esta nos grupos dele;
--     3) conteudo (treinamento, versao, aula, avaliacao, questao, opcao) todos leem,
--        so admin e gestor escrevem;
--     4) nota nao se digita: lms.tentativa, lms.tentativa_resposta e a conclusao
--        automatica nao tem policy de escrita nenhuma - entram apenas por
--        lms.corrigir_tentativa(), que e SECURITY DEFINER;
--     5) desbloquear matricula que esgotou as tentativas e so admin.
--
--   FURO 4 - O LIMITE DESTE ARQUIVO, DITO EM VOZ ALTA:
--   lms.corrigir_tentativa() e SECURITY DEFINER e passa por cima de TODAS as policies
--   abaixo. A regra 1 ("cada pessoa escreve o proprio progresso") so vale de verdade
--   porque 02f-ajustes-base.sql recria essa funcao conferindo, DENTRO dela, que a
--   matricula recebida por parametro pertence ao usuario da sessao - antes disso ela
--   aceitava o uuid da matricula de qualquer colega e gravava tentativa, nota,
--   conclusao e comprovante no nome do outro. Aplicar 02e sem 02f deixa o furo aberto:
--   a ordem de aplicacao termina em 02f, nao em 02e.
--
--   POR QUE NENHUM FORCE ROW LEVEL SECURITY AQUI:
--   o dono das tabelas e quem roda a importacao do mig (mig.importar_* escreve em
--   praticamente todo o schema lms), a reconciliacao noturna e a correcao
--   SECURITY DEFINER. Com FORCE, essas tres rotinas passariam a ser filtradas pela
--   identidade de quem chamou e quebrariam - inclusive a leitura do gabarito dentro
--   de lms.corrigir_tentativa(). O dono nao e uma porta de entrada do cliente:
--   biotrop_app e biotrop_ro sao NOSUPERUSER, NOBYPASSRLS e nao possuem as tabelas,
--   entao para elas o RLS abaixo vale integralmente.
-- =====================================================================================

-- =====================================================================================
-- 1. DUAS FUNCOES DE APOIO
--   O vocabulario de 02a resolve perfil e lideranca de grupo; falta traduzir
--   "esta pessoa esta em um grupo meu" e "de quem e esta matricula". Ambas
--   SECURITY DEFINER de proposito: se a policy de lms lesse core.usuario e
--   lms.matricula direto, o RLS dessas tabelas seria aplicado dentro da subconsulta
--   e a visao do lider encolheria em silencio, sem erro nenhum para investigar.
-- =====================================================================================
-- CORRECAO DO FURO 7 - A LIDERANCA CAI JUNTO COM O BLOQUEIO.
-- Esta funcao herdava o furo de app.grupos_que_lidero() (02a), que conferia apenas
-- core.grupo.ativo e nunca o estado de quem estava na sessao. Com isso o ramo
-- "OR app.lidero_usuario(...)" de matricula_sel, progresso_sel, tentativa_sel,
-- liberacao_sel e conclusao_sel entregava matricula, nota, progresso e comprovante da
-- equipe inteira para um lider que ja havia sido desligado ou bloqueado - dado de
-- terceiro saindo para quem a tela dizia estar sem acesso.
-- A raiz esta corrigida em 02a; a condicao e repetida aqui de proposito, para o corte
-- nao depender de a raiz continuar como esta. app.usuario_ativo() e STABLE, entao a
-- repeticao nao custa plano.
CREATE OR REPLACE FUNCTION app.lidero_usuario(p_usuario uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, pg_temp AS $$
  SELECT app.usuario_ativo()
     AND EXISTS (
    SELECT 1
      FROM core.usuario u
     WHERE u.id = p_usuario
       AND u.grupo_id IN (SELECT app.grupos_que_lidero())
  );
$$;
COMMENT ON FUNCTION app.lidero_usuario(uuid) IS 'Verdadeiro se a pessoa informada esta em um grupo cujo responsavel direto e o usuario da sessao. Falso (nao erro) para NULL e para quem nao lidera nada. Desde a correcao do FURO 7 exige app.usuario_ativo(): lider inativo ou bloqueado nao le mais matricula, progresso, tentativa nem comprovante de liderado.';

CREATE OR REPLACE FUNCTION app.lms_dono_matricula(p_matricula uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = lms, pg_temp AS $$
  SELECT m.usuario_id FROM lms.matricula m WHERE m.id = p_matricula;
$$;
COMMENT ON FUNCTION app.lms_dono_matricula(uuid) IS 'Usuario dono da matricula. E o eixo das policies das tabelas filhas (progresso, tentativa, liberacao, conclusao), que nao guardam usuario_id.';

GRANT EXECUTE ON FUNCTION app.lidero_usuario(uuid), app.lms_dono_matricula(uuid)
  TO biotrop_app, biotrop_ro;

-- =====================================================================================
-- 2. REEXECUCAO LIMPA
--   CREATE POLICY nao tem IF NOT EXISTS. Em vez de repetir DROP POLICY IF EXISTS
--   linha a linha, o schema lms e zerado de policies antes de recriar: rodar este
--   arquivo duas vezes tem o mesmo efeito de rodar uma.
-- =====================================================================================
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT tablename, policyname FROM pg_policies WHERE schemaname = 'lms' LOOP
    EXECUTE format('DROP POLICY %I ON lms.%I', r.policyname, r.tablename);
  END LOOP;
END $$;

-- =====================================================================================
-- 3. CONTEUDO: TODOS LEEM, ADMIN E GESTOR ESCREVEM
--   Cinco tabelas com a mesma regra, geradas em laco para nao existirem cinco
--   redacoes ligeiramente diferentes da mesma frase.
--   lms.questao_opcao entra aqui: RLS filtra LINHA, nao COLUNA, portanto quem
--   esconde o gabarito e o privilegio de coluna de 02a (a role da aplicacao tem
--   SELECT em id, questao_id, posicao, texto e nao em correta). A policy de leitura
--   ampla aqui nao afrouxa isso - sem o privilegio de coluna, "select correta"
--   continua sendo erro de permissao.
-- =====================================================================================
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['treinamento', 'aula', 'avaliacao', 'questao', 'questao_opcao'] LOOP
    EXECUTE format('ALTER TABLE lms.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format($f$CREATE POLICY %1$s_sel ON lms.%1$I FOR SELECT
                        USING (app.usuario_ativo())$f$, t);
    EXECUTE format($f$CREATE POLICY %1$s_ins ON lms.%1$I FOR INSERT
                        WITH CHECK (app.tem_perfil(ARRAY['admin','gestor']))$f$, t);
    EXECUTE format($f$CREATE POLICY %1$s_upd ON lms.%1$I FOR UPDATE
                        USING      (app.tem_perfil(ARRAY['admin','gestor']))
                        WITH CHECK (app.tem_perfil(ARRAY['admin','gestor']))$f$, t);
    EXECUTE format($f$CREATE POLICY %1$s_del ON lms.%1$I FOR DELETE
                        USING (app.tem_perfil(ARRAY['admin','gestor']))$f$, t);
  END LOOP;
END $$;

-- 3.1 versao: rascunho nao vaza -------------------------------------------------------
ALTER TABLE lms.versao ENABLE ROW LEVEL SECURITY;

-- Versao em rascunho e material sendo escrito; publicada e arquivada sao historico
-- que quem estudou precisa continuar lendo.
CREATE POLICY versao_sel ON lms.versao FOR SELECT
  USING (app.tem_perfil(ARRAY['admin','gestor'])
         OR (app.usuario_ativo() AND status <> 'rascunho'));

CREATE POLICY versao_ins ON lms.versao FOR INSERT
  WITH CHECK (app.tem_perfil(ARRAY['admin','gestor']));

CREATE POLICY versao_upd ON lms.versao FOR UPDATE
  USING      (app.tem_perfil(ARRAY['admin','gestor']))
  WITH CHECK (app.tem_perfil(ARRAY['admin','gestor']));

CREATE POLICY versao_del ON lms.versao FOR DELETE
  USING (app.tem_perfil(ARRAY['admin','gestor']));

-- =====================================================================================
-- 4. ATRIBUICAO: QUEM DEVE FAZER
--   Le: admin e gestor tudo; a pessoa a atribuicao nominal dela; o lider as
--   atribuicoes dos grupos que ele responde. Escreve: admin e gestor.
-- =====================================================================================
ALTER TABLE lms.atribuicao ENABLE ROW LEVEL SECURITY;

-- FURO 7 nesta policy, nos DOIS ramos que nao eram de perfil:
--   "usuario_id = app.usuario_atual()" olhava so o casamento de id, entao quem foi
--   bloqueado continuava lendo as proprias atribuicoes - o bloqueio nao chegava a
--   apagar a tela dele;
--   "grupo_id IN (SELECT app.grupos_que_lidero())" vinha da funcao furada de 02a e
--   entregava as atribuicoes do grupo a um lider ja desligado.
-- O segundo ramo esta corrigido na raiz (02a); o primeiro precisa da condicao aqui,
-- porque nenhuma funcao intermediaria participa dele.
CREATE POLICY atribuicao_sel ON lms.atribuicao FOR SELECT
  USING (app.tem_perfil(ARRAY['admin','gestor'])
         OR (app.usuario_ativo() AND usuario_id = app.usuario_atual())
         OR grupo_id IN (SELECT app.grupos_que_lidero()));

CREATE POLICY atribuicao_ins ON lms.atribuicao FOR INSERT
  WITH CHECK (app.tem_perfil(ARRAY['admin','gestor'])
              AND (criado_por IS NULL OR criado_por = app.usuario_atual()));

CREATE POLICY atribuicao_upd ON lms.atribuicao FOR UPDATE
  USING      (app.tem_perfil(ARRAY['admin','gestor']))
  WITH CHECK (app.tem_perfil(ARRAY['admin','gestor']));

CREATE POLICY atribuicao_del ON lms.atribuicao FOR DELETE
  USING (app.tem_perfil(ARRAY['admin','gestor']));

-- =====================================================================================
-- 5. MATRICULA
--   Le: a propria, a de quem esta em grupo meu, e admin/gestor tudo.
--   Escreve: a pessoa atualiza a PROPRIA matricula porque
--   lms.registrar_progresso() nao e SECURITY DEFINER - ela mesma faz o
--   UPDATE de status e iniciado_em com a identidade de quem esta estudando.
--   O par USING/WITH CHECK com NOT bloqueada e o que segura o abuso: a pessoa nao
--   toca em linha bloqueada (USING falha) e nao pode gravar uma linha desbloqueada
--   nem bloqueada por conta propria (WITH CHECK). Desbloquear e ato de admin, via
--   lms.liberar_matricula().
--   Criar matricula e de admin/gestor. A reconciliacao (lms.sincronizar_matriculas)
--   roda pelo dono na rotina noturna e, quando disparada por trigger, vem de uma
--   escrita em core.usuario ou lms.atribuicao - que ja e escrita de admin/gestor.
--
--   CORRECAO (furo 3) - O QUE ESTAS DUAS POLICIES NAO FAZEM:
--   matricula_upd_propria escolhe a LINHA que o aluno alcanca; ela nao diz nada sobre
--   QUAIS COLUNAS daquela linha ele pode reescrever. Com o GRANT de UPDATE de tabela
--   inteira que a role da aplicacao tinha, a propria linha permitida bastava:
--     UPDATE lms.matricula SET tentativas_liberadas = 99 WHERE id = <a minha>;
--   e o limite conferido por lms.corrigir_tentativa (versao.tentativas_maximas +
--   matricula.tentativas_liberadas) virava tentativa infinita na avaliacao. Pelo mesmo
--   UPDATE o aluno saia do bloqueio ou trocava de versao_id.
--   Quem fecha isso e o privilegio de COLUNA em 02a, secao 3.2.2: a aplicacao recebe
--   UPDATE apenas em status, iniciado_em, concluido_em, prazo_em, obrigatoria,
--   atribuicao_id e atualizado_em. bloqueada, bloqueada_em e tentativas_liberadas so
--   se movem por lms.liberar_matricula(), que 02f-ajustes-base.sql torna SECURITY
--   DEFINER com checagem de admin dentro do corpo.
--   Nao troque este par USING/WITH CHECK por uma condicao de coluna: policy nao
--   compara OLD com NEW. Se um dia for preciso amarrar coluna dentro da policy, o
--   lugar e um trigger BEFORE UPDATE, nao a policy.
-- =====================================================================================
ALTER TABLE lms.matricula ENABLE ROW LEVEL SECURITY;

CREATE POLICY matricula_sel ON lms.matricula FOR SELECT
  USING (app.tem_perfil(ARRAY['admin','gestor'])
         OR (app.usuario_ativo() AND usuario_id = app.usuario_atual())
         OR app.lidero_usuario(usuario_id));

CREATE POLICY matricula_ins ON lms.matricula FOR INSERT
  WITH CHECK (app.tem_perfil(ARRAY['admin','gestor']));

CREATE POLICY matricula_upd_propria ON lms.matricula FOR UPDATE
  USING      (app.usuario_ativo() AND usuario_id = app.usuario_atual() AND NOT bloqueada)
  WITH CHECK (usuario_id = app.usuario_atual() AND NOT bloqueada);

CREATE POLICY matricula_upd_gestao ON lms.matricula FOR UPDATE
  USING      (app.tem_perfil(ARRAY['admin','gestor']))
  WITH CHECK (app.tem_perfil(ARRAY['admin','gestor']));

CREATE POLICY matricula_del ON lms.matricula FOR DELETE
  USING (app.eh_admin());

-- =====================================================================================
-- 6. PROGRESSO DE AULA: SO O DONO ESCREVE
--   O lider aparece apenas no SELECT. Nao existe policy que deixe alguem gravar
--   progresso alheio - nem gestor: acompanhamento se le, nao se preenche.
-- =====================================================================================
ALTER TABLE lms.progresso_aula ENABLE ROW LEVEL SECURITY;

CREATE POLICY progresso_sel ON lms.progresso_aula FOR SELECT
  USING (app.tem_perfil(ARRAY['admin','gestor'])
         -- FURO 7: o ramo do proprio dono precisa de app.usuario_ativo(). Comparar
         -- id com id nao diz nada sobre o estado da sessao, e sem esta condicao quem
         -- foi bloqueado continuava lendo o proprio historico de treinamento. O ramo
         -- do lider ao lado ja esta coberto: app.lidero_usuario() exige sessao ativa.
         OR (app.usuario_ativo()
             AND app.lms_dono_matricula(matricula_id) = app.usuario_atual())
         OR app.lidero_usuario(app.lms_dono_matricula(matricula_id)));

CREATE POLICY progresso_ins ON lms.progresso_aula FOR INSERT
  WITH CHECK (app.usuario_ativo()
              AND app.lms_dono_matricula(matricula_id) = app.usuario_atual());

CREATE POLICY progresso_upd ON lms.progresso_aula FOR UPDATE
  USING      (app.usuario_ativo()
              AND app.lms_dono_matricula(matricula_id) = app.usuario_atual())
  WITH CHECK (app.lms_dono_matricula(matricula_id) = app.usuario_atual());

CREATE POLICY progresso_del ON lms.progresso_aula FOR DELETE
  USING (app.eh_admin());

-- =====================================================================================
-- 7. TENTATIVA E RESPOSTAS: LEITURA APENAS
--   De proposito sem policy de INSERT, UPDATE ou DELETE. A role da aplicacao tem
--   GRANT de escrita nessas tabelas, e sem RLS bastaria um INSERT com nota 100 e
--   aprovado true para a pessoa se aprovar sozinha. Com o RLS ligado e nenhuma
--   policy permissiva de escrita, todo INSERT do cliente e recusado; as linhas
--   entram por lms.corrigir_tentativa(), que roda como dona da tabela.
--   FURO 4: "roda como dona da tabela" e o ponto cego. A ausencia de policy de escrita
--   aqui nao protege ninguem contra a propria funcao - ela e a excecao. Quem garante
--   que a tentativa gravada e da pessoa certa e a checagem de dono acrescentada em
--   02f-ajustes-base.sql, nao esta secao.
-- =====================================================================================
ALTER TABLE lms.tentativa ENABLE ROW LEVEL SECURITY;

CREATE POLICY tentativa_sel ON lms.tentativa FOR SELECT
  USING (app.tem_perfil(ARRAY['admin','gestor'])
         -- FURO 7: o ramo do proprio dono precisa de app.usuario_ativo(). Comparar
         -- id com id nao diz nada sobre o estado da sessao, e sem esta condicao quem
         -- foi bloqueado continuava lendo o proprio historico de treinamento. O ramo
         -- do lider ao lado ja esta coberto: app.lidero_usuario() exige sessao ativa.
         OR (app.usuario_ativo()
             AND app.lms_dono_matricula(matricula_id) = app.usuario_atual())
         OR app.lidero_usuario(app.lms_dono_matricula(matricula_id)));

ALTER TABLE lms.tentativa_resposta ENABLE ROW LEVEL SECURITY;

-- Espelha a visibilidade da tentativa: a subconsulta le lms.tentativa ja sob o RLS
-- acima, entao quem nao ve a tentativa nao ve as respostas dela.
CREATE POLICY tentativa_resposta_sel ON lms.tentativa_resposta FOR SELECT
  USING (EXISTS (SELECT 1 FROM lms.tentativa t WHERE t.id = tentativa_resposta.tentativa_id));

-- =====================================================================================
-- 8. LIBERACAO: A EXCECAO DAS 3 TENTATIVAS E SO DE ADMIN
--   Insere so admin, e obrigatoriamente assinando (liberado_por = quem esta na
--   sessao); assim o motivo registrado nao pode ser atribuido a um terceiro.
--   Sem UPDATE e sem DELETE: o registro da excecao e imutavel.
-- =====================================================================================
ALTER TABLE lms.liberacao ENABLE ROW LEVEL SECURITY;

CREATE POLICY liberacao_sel ON lms.liberacao FOR SELECT
  USING (app.tem_perfil(ARRAY['admin','gestor'])
         -- FURO 7: o ramo do proprio dono precisa de app.usuario_ativo(). Comparar
         -- id com id nao diz nada sobre o estado da sessao, e sem esta condicao quem
         -- foi bloqueado continuava lendo o proprio historico de treinamento. O ramo
         -- do lider ao lado ja esta coberto: app.lidero_usuario() exige sessao ativa.
         OR (app.usuario_ativo()
             AND app.lms_dono_matricula(matricula_id) = app.usuario_atual())
         OR app.lidero_usuario(app.lms_dono_matricula(matricula_id)));

CREATE POLICY liberacao_ins ON lms.liberacao FOR INSERT
  WITH CHECK (app.eh_admin() AND liberado_por = app.usuario_atual());

-- =====================================================================================
-- 9. CONCLUSAO (COMPROVANTE)
--   A automatica nasce dentro de lms.corrigir_tentativa(), pelo dono. A policy de
--   INSERT existe apenas para o lancamento MANUAL do admin, e amarra as tres coisas
--   que sustentam auditoria: perfil admin, evidencia manual e assinatura de quem
--   lancou. Comprovante nao se edita; corrigir erro e apagar e lancar de novo, e
--   apagar e so de admin.
-- =====================================================================================
ALTER TABLE lms.conclusao ENABLE ROW LEVEL SECURITY;

CREATE POLICY conclusao_sel ON lms.conclusao FOR SELECT
  USING (app.tem_perfil(ARRAY['admin','gestor'])
         -- FURO 7: o ramo do proprio dono precisa de app.usuario_ativo(). Comparar
         -- id com id nao diz nada sobre o estado da sessao, e sem esta condicao quem
         -- foi bloqueado continuava lendo o proprio historico de treinamento. O ramo
         -- do lider ao lado ja esta coberto: app.lidero_usuario() exige sessao ativa.
         OR (app.usuario_ativo()
             AND app.lms_dono_matricula(matricula_id) = app.usuario_atual())
         OR app.lidero_usuario(app.lms_dono_matricula(matricula_id)));

CREATE POLICY conclusao_ins ON lms.conclusao FOR INSERT
  WITH CHECK (app.eh_admin()
              AND evidencia = 'manual'
              AND registrado_por = app.usuario_atual());

CREATE POLICY conclusao_del ON lms.conclusao FOR DELETE
  USING (app.eh_admin());

-- =====================================================================================
-- 10. CONFERENCIA E REGISTRO
-- =====================================================================================
DO $$
DECLARE v_falta text;
BEGIN
  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO v_falta
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'lms' AND c.relkind = 'r' AND NOT c.relrowsecurity;
  IF v_falta IS NOT NULL THEN
    RAISE EXCEPTION 'Tabela de lms sem RLS habilitado: %', v_falta;
  END IF;
END $$;

INSERT INTO core.migration (versao, nome, observacao) VALUES
  ('0002e', 'rls-lms',
   'RLS nas 13 tabelas de lms. O UPDATE do aluno na propria matricula e limitado por privilegio de COLUNA em 02a (tentativas_liberadas, bloqueada e bloqueada_em ficam fora), porque a policy filtra linha e nao coluna. Progresso e escrito somente pelo dono da matricula; responsavel de grupo tem leitura de matricula, progresso, tentativa e conclusao dos seus liderados; conteudo aberto para leitura e restrito a admin/gestor na escrita; lms.tentativa e lms.tentativa_resposta sem policy de escrita (entram por lms.corrigir_tentativa, SECURITY DEFINER); desbloqueio de matricula e conclusao manual so de admin. Sem FORCE: o dono roda importacao, reconciliacao e correcao. FURO 4: a checagem de dono de lms.corrigir_tentativa nao esta aqui e sim em 0002f - esta migration depende dela para que "so o dono escreve" seja verdade.')
ON CONFLICT (versao) DO NOTHING;
