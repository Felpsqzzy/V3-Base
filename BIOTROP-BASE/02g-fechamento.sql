-- =====================================================================================
-- BIOTROP - Fechamento do Row Level Security
-- Aplicar DEPOIS de 02f-ajustes-base.sql
-- =====================================================================================
--
-- Este arquivo fecha o que sobrou depois da revisao adversarial, mais dois furos
-- encontrados ao conferir a cobertura tabela por tabela.
--
-- O levantamento que motivou o arquivo: das 49 tabelas da base, 23 tinham RLS ligado
-- e 26 nao. A maior parte das 26 e legitima (catalogo e conteudo: perfil, permissao,
-- familia, centro de custo, treinamento, aula, questao - todo usuario autenticado le,
-- e a escrita e barrada por GRANT). Mas cinco NAO eram legitimas, e duas delas o
-- revisor nao tinha pego.
--
-- =====================================================================================
-- FURO NOVO 13 - TABELA FILHA SEM RLS ANULA A POLICY DA MAE
--
--   almox.scm tem RLS: o tecnico so ve a propria SCM. Mas almox.scm_item,
--   almox.scm_anexo e almox.scm_link NAO tinham RLS nenhum.
--
--   Exploit, com a aplicacao conectada como biotrop_app:
--     SET LOCAL app.usuario_id = '<uuid do tecnico>';
--     SELECT * FROM almox.scm_item;
--     -- devolve codigo, descricao, quantidade, estoque minimo e marca de TODAS as
--     -- compras da empresa, porque a policy que protege a linha esta na tabela mae
--     -- e o SELECT nem passa por ela.
--
--   Policy em tabela mae nao protege tabela filha. Cada uma precisa da sua, e a da
--   filha se resolve por EXISTS na mae - assim a regra fica escrita num lugar so
--   (a policy da mae) e a filha herda, em vez de duplicar a condicao.
--
-- FURO NOVO 14 - core.login_evento SEM RLS
--
--   O comentario de 02b (linha 15) promete "FORCE ROW LEVEL SECURITY entra apenas em
--   auditoria e login_evento". Nenhum FORCE foi aplicado, e login_evento nao tinha nem
--   RLS simples: qualquer usuario da aplicacao lia quando cada pessoa entrou, de qual
--   IP e com qual navegador. Comentario que promete e codigo que nao cumpre e pior que
--   ausencia de comentario, porque a proxima pessoa confia nele.
--
-- FURO 12 - schema pcm com CRUD e sem RLS (conhecido)
-- FURO 6  - schema mig sem RLS (conhecido; o acesso ja estava revogado em 02a)
-- FURO 11 - FORCE sem policy que alcance o dono: JA RESOLVIDO em 02d, que aplicou
--           NO FORCE em util.desvio_tratativa. Nenhum FORCE ficou ligado. Aqui apenas
--           cumpro o que o comentario de 02b promete, com a porta do dono aberta para
--           INSERT (ver secao 2).
-- =====================================================================================


-- =====================================================================================
-- 1. FURO 13 - itens, anexos e links da SCM herdam a policy da mae
-- =====================================================================================

ALTER TABLE almox.scm_item  ENABLE ROW LEVEL SECURITY;
ALTER TABLE almox.scm_anexo ENABLE ROW LEVEL SECURITY;
ALTER TABLE almox.scm_link  ENABLE ROW LEVEL SECURITY;

-- Um EXISTS na mae, e nao a repeticao da regra. Se amanha a policy da SCM mudar
-- (por exemplo o PCM passar a ver tudo), a filha acompanha sem edicao.
CREATE OR REPLACE FUNCTION app.scm_visivel(p_scm_id uuid)
RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM almox.scm s WHERE s.id = p_scm_id);
$$;

COMMENT ON FUNCTION app.scm_visivel(uuid) IS
  'A SCM esta visivel para quem consulta? Nao e SECURITY DEFINER de proposito: rodando com o direito de quem chama, o SELECT interno passa pelas policies de almox.scm, e a filha herda exatamente a regra da mae.';

REVOKE ALL ON FUNCTION app.scm_visivel(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.scm_visivel(uuid) TO biotrop_app, biotrop_ro;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['scm_item', 'scm_anexo', 'scm_link'] LOOP
    -- SELECT: ve o item se ve a compra.
    EXECUTE format(
      'DROP POLICY IF EXISTS %1$I_sel ON almox.%1$I; '
      'CREATE POLICY %1$I_sel ON almox.%1$I FOR SELECT TO biotrop_app, biotrop_ro '
      'USING (app.scm_visivel(scm_id));', t);

    -- INSERT e UPDATE: escreve no item se pode escrever na compra. WITH CHECK tanto
    -- no INSERT quanto no UPDATE, senao o UPDATE consegue MOVER a linha para uma
    -- compra que o usuario nao alcanca.
    EXECUTE format(
      'DROP POLICY IF EXISTS %1$I_ins ON almox.%1$I; '
      'CREATE POLICY %1$I_ins ON almox.%1$I FOR INSERT TO biotrop_app '
      'WITH CHECK (app.scm_visivel(scm_id));', t);

    EXECUTE format(
      'DROP POLICY IF EXISTS %1$I_upd ON almox.%1$I; '
      'CREATE POLICY %1$I_upd ON almox.%1$I FOR UPDATE TO biotrop_app '
      'USING (app.scm_visivel(scm_id)) WITH CHECK (app.scm_visivel(scm_id));', t);

    EXECUTE format(
      'DROP POLICY IF EXISTS %1$I_del ON almox.%1$I; '
      'CREATE POLICY %1$I_del ON almox.%1$I FOR DELETE TO biotrop_app '
      'USING (app.scm_visivel(scm_id));', t);
  END LOOP;
END $$;

COMMENT ON TABLE almox.scm_item IS
  'Itens da compra. RLS herda a visibilidade de almox.scm por app.scm_visivel(): policy em tabela mae nao protege tabela filha, e sem isto o tecnico lia os itens de toda a empresa.';


-- =====================================================================================
-- 2. FURO 14 - core.login_evento com RLS, e o FORCE que 02b prometeu
-- =====================================================================================

ALTER TABLE core.login_evento ENABLE ROW LEVEL SECURITY;

-- Cada um ve o proprio historico; admin ve tudo. Ninguem ALTERA nem APAGA - log que
-- se reescreve nao e log, e essa e a razao do FORCE mais abaixo.
DROP POLICY IF EXISTS login_evento_sel_proprio ON core.login_evento;
CREATE POLICY login_evento_sel_proprio ON core.login_evento
  FOR SELECT TO biotrop_app
  USING (app.usuario_ativo() AND usuario_id = app.usuario_atual());

DROP POLICY IF EXISTS login_evento_sel_admin ON core.login_evento;
CREATE POLICY login_evento_sel_admin ON core.login_evento
  FOR SELECT TO biotrop_app, biotrop_ro
  USING (app.eh_admin());

-- O INSERT tem de funcionar ANTES de existir identidade na sessao: e o registro do
-- proprio login, inclusive do login que FALHOU (e-mail nao autorizado, usuario
-- bloqueado). Exigir app.usuario_atual() aqui impediria justamente o registro que mais
-- interessa numa investigacao.
DROP POLICY IF EXISTS login_evento_ins ON core.login_evento;
CREATE POLICY login_evento_ins ON core.login_evento
  FOR INSERT TO biotrop_app
  WITH CHECK (true);

-- Sem policy de UPDATE e de DELETE: a ausencia ja nega. Escrever
-- "FOR UPDATE USING (false)" seria mais explicito, mas tambem sugeriria que existe
-- caminho - e nao existe, nem para admin.

-- Agora o FORCE que o comentario de 02b prometia. Ele vale para o DONO das tabelas
-- tambem, e e por isso que as duas precisam de policy de INSERT alcancando o dono:
-- a importacao do mig e o worker gravam auditoria e evento sem sessao de usuario.
ALTER TABLE core.login_evento FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS login_evento_ins_dono ON core.login_evento;
CREATE POLICY login_evento_ins_dono ON core.login_evento
  FOR INSERT TO PUBLIC
  WITH CHECK (true);

-- O FORCE existe por causa de UPDATE e DELETE ("log que o dono reescreve nao e log"),
-- nao de SELECT. Mas sob FORCE o dono tambem perde o SELECT, e e ele quem roda as
-- consultas de aceite da virada. Esta policy devolve a LEITURA ao dono e a mais
-- ninguem: quem nao e o dono da tabela nao passa por ela e cai nas policies acima.
DROP POLICY IF EXISTS login_evento_sel_dono ON core.login_evento;
CREATE POLICY login_evento_sel_dono ON core.login_evento
  FOR SELECT TO PUBLIC
  USING (current_user = (SELECT tableowner FROM pg_tables
                          WHERE schemaname = 'core' AND tablename = 'login_evento'));

COMMENT ON TABLE core.login_evento IS
  'Historico de autenticacao (inclusive tentativa recusada). RLS: cada um ve o proprio, admin ve tudo, ninguem altera nem apaga. FORCE para valer tambem para o dono, com policy de INSERT aberta porque o registro do login acontece antes de existir identidade na sessao.';

-- A mesma amarra em core.auditoria, que 02b tambem prometia.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'core' AND c.relname = 'auditoria' AND c.relrowsecurity) THEN
    EXECUTE 'ALTER TABLE core.auditoria FORCE ROW LEVEL SECURITY';
    EXECUTE 'DROP POLICY IF EXISTS auditoria_ins_dono ON core.auditoria';
    EXECUTE 'CREATE POLICY auditoria_ins_dono ON core.auditoria '
            'FOR INSERT TO PUBLIC WITH CHECK (true)';
    RAISE NOTICE '[02g] FORCE aplicado em core.auditoria, com porta de INSERT para o dono.';
  ELSE
    RAISE WARNING '[02g] core.auditoria esta sem RLS - o FORCE nao foi aplicado. Confira 02b.';
  END IF;
END $$;


-- =====================================================================================
-- 3. FURO 12 - schema pcm: RLS antes de o modulo existir
-- =====================================================================================
--
-- O modulo e etapa posterior (ordem de servico, plano preventivo, estoque), mas as
-- tabelas ja existem e 02a concede CRUD para biotrop_app, com ALTER DEFAULT PRIVILEGES
-- para as futuras. Gravavel por qualquer usuario da aplicacao.
--
-- A regra aqui e deliberadamente restritiva: leitura para pcm, gestor e admin; escrita
-- so admin. Nao e a regra final - a final vem quando o modulo for especificado, porque
-- ainda nao se sabe, por exemplo, se o tecnico fecha a propria ordem de servico. Ate
-- la, e melhor que falte permissao a que sobre.

DO $$
DECLARE
  t record;
BEGIN
  FOR t IN
    SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'pcm' AND c.relkind = 'r'
  LOOP
    EXECUTE format('ALTER TABLE pcm.%I ENABLE ROW LEVEL SECURITY', t.relname);

    EXECUTE format(
      'DROP POLICY IF EXISTS %1$I_sel ON pcm.%1$I; '
      'CREATE POLICY %1$I_sel ON pcm.%1$I FOR SELECT TO biotrop_app, biotrop_ro '
      'USING (app.usuario_ativo() AND app.tem_perfil(ARRAY[''pcm'',''gestor'',''admin'']));',
      t.relname);

    EXECUTE format(
      'DROP POLICY IF EXISTS %1$I_todo_admin ON pcm.%1$I; '
      'CREATE POLICY %1$I_todo_admin ON pcm.%1$I FOR ALL TO biotrop_app '
      'USING (app.eh_admin()) WITH CHECK (app.eh_admin());',
      t.relname);

    EXECUTE format(
      'COMMENT ON TABLE pcm.%1$I IS %2$L',
      t.relname,
      'Modulo PCM - etapa posterior. RLS provisorio: leitura para pcm/gestor/admin, escrita so admin. A regra definitiva entra quando o modulo for especificado (falta decidir, por exemplo, se o tecnico fecha a propria ordem de servico).');

    RAISE NOTICE '[02g] RLS provisorio aplicado em pcm.%', t.relname;
  END LOOP;
END $$;


-- =====================================================================================
-- 4. FURO 6 - schema mig: RLS como segunda camada
-- =====================================================================================
--
-- 02a ja revogou mig de biotrop_app (linhas 173-186), de biotrop_ro (412-415) e de
-- PUBLIC (422-423), e registrou que nao ha default privilege. O acesso esta fechado.
--
-- Ligo RLS de todo jeito, e a razao esta escrita no proprio 02a: "um GRANT USAGE ON
-- SCHEMA mig futuro - num script de suporte, num deploy" devolve o acesso. REVOKE
-- protege enquanto ninguem conceder de novo; RLS protege mesmo depois. mig.dump guarda
-- o export inteiro do localStorage, com usuario, solicitacao, leitura e treinamento de
-- todo mundo em jsonb: e a tabela mais sensivel do banco.
--
-- Nenhuma policy para biotrop_app ou biotrop_ro: a ausencia de policy com RLS ligado
-- nega tudo. O acesso legitimo e do DONO, que roda a importacao, e do admin pela
-- funcao SECURITY DEFINER.

DO $$
DECLARE
  t record;
BEGIN
  FOR t IN
    SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'mig' AND c.relkind = 'r'
  LOOP
    EXECUTE format('ALTER TABLE mig.%I ENABLE ROW LEVEL SECURITY', t.relname);
    RAISE NOTICE '[02g] RLS ligado em mig.% (sem policy: nega para a aplicacao)', t.relname;
  END LOOP;
END $$;

COMMENT ON TABLE mig.dump IS
  'Export bruto do localStorage para a virada. Tabela mais sensivel do banco: guarda usuario, solicitacao, leitura e treinamento de todo mundo em jsonb. RLS ligado SEM policy para a aplicacao (ausencia de policy nega tudo); acesso so do dono, que roda a importacao. O REVOKE de 02a protege enquanto ninguem conceder de novo - o RLS protege mesmo depois.';


-- =====================================================================================
-- 5. Conferencia que para o deploy
-- =====================================================================================
--
-- O levantamento que originou este arquivo foi manual. Nao pode depender de alguem
-- lembrar de refazer: a conferencia abaixo roda no deploy, imprime a situacao e FALHA
-- quando aparece tabela desprotegida onde nao pode haver.

DO $$
DECLARE
  v_criticas text[];
  v_catalogo text[];
  v_esperadas text[] := ARRAY[
    -- Catalogo e infraestrutura: sem RLS de proposito. Todo usuario autenticado le;
    -- a escrita e barrada por GRANT. Se uma tabela sair desta lista, ela passa a ser
    -- cobrada pela conferencia - o que e o comportamento desejado.
    'core.migration', 'core.sequencia', 'core.rotina_execucao',
    'core.permissao', 'core.perfil',
    'almox.familia', 'almox.familia_campo', 'almox.centro_custo',
    'lms.treinamento', 'lms.aula', 'lms.avaliacao', 'lms.questao'
  ];
BEGIN
  SELECT array_agg(n.nspname || '.' || c.relname ORDER BY n.nspname, c.relname)
    INTO v_criticas
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relkind = 'r'
     AND n.nspname IN ('core', 'almox', 'util', 'lms', 'pcm', 'mig')
     AND NOT c.relrowsecurity
     AND (n.nspname || '.' || c.relname) <> ALL (v_esperadas);

  IF v_criticas IS NOT NULL THEN
    RAISE EXCEPTION
      '[02g] % tabela(s) sem RLS fora da lista de catalogo: %. Ligue o RLS ou justifique acrescentando a v_esperadas neste arquivo.',
      array_length(v_criticas, 1), array_to_string(v_criticas, ', ');
  END IF;

  -- lms.questao_opcao merece nota propria: ela guarda o gabarito, e a protecao dele
  -- hoje e por privilegio de COLUNA (02a). RLS ligado ali seria terceira camada, mas a
  -- funcao de correcao roda como dona e nao tem FORCE, entao ligar RLS sem cuidado
  -- quebraria a correcao. Fica registrado como decisao consciente, nao como esquecimento.
  IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname = 'lms' AND c.relname = 'questao_opcao'
                    AND c.relrowsecurity) THEN
    RAISE NOTICE '[02g] lms.questao_opcao segue sem RLS - o gabarito e protegido por privilegio de coluna em 02a, e a conferencia de has_table_privilege de 02a barra o deploy se o SELECT de tabela voltar.';
  END IF;

  SELECT array_agg(x ORDER BY x) INTO v_catalogo FROM unnest(v_esperadas) x;
  RAISE NOTICE '[02g] conferencia OK. Sem RLS por decisao (catalogo/infra): %',
    array_to_string(v_catalogo, ', ');
END $$;


-- =====================================================================================
-- 6. Registro da migration
-- =====================================================================================

INSERT INTO core.migration (versao, nome, observacao)
VALUES ('02g', '02g-fechamento.sql',
        'Fechamento do RLS: itens da SCM herdam a policy da mae (furo 13), login_evento protegido com FORCE (furo 14), RLS provisorio em pcm (furo 12), RLS em mig (furo 6) e conferencia que para o deploy.')
ON CONFLICT (versao) DO UPDATE
  SET aplicado_em = now(), observacao = EXCLUDED.observacao;

-- Conferencias uteis depois de aplicar:
--
--   -- nenhuma tabela desprotegida fora do catalogo (deve voltar zero linhas)
--   SELECT n.nspname||'.'||c.relname FROM pg_class c
--     JOIN pg_namespace n ON n.oid=c.relnamespace
--    WHERE c.relkind='r' AND n.nspname IN ('core','almox','util','lms','pcm','mig')
--      AND NOT c.relrowsecurity;
--
--   -- o furo 13 esta fechado? como tecnico, deve devolver so os itens das SCM dele
--   SET LOCAL app.usuario_id = '<uuid do tecnico>';
--   SELECT count(*) FROM almox.scm_item;
--   SELECT count(*) FROM almox.scm;   -- os dois numeros tem de ser coerentes
