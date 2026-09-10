-- =====================================================================================
-- Gatilhos que ENFILEIRAM e-mail em core.email_fila
--
-- Aplicar depois de 01-base.sql e do RLS (02a..02f).
--
-- Decisão da reunião, mantida aqui: começa com UM aviso ligado.
--   LIGADO    SCI entra em "Aguardando Revisão do Solicitante" -> solicitante
--   DESLIGADO SCM entra na aprovação -> responsável direto do grupo
--   DESLIGADO Treinamento concluído -> colaborador e responsável
--
-- O liga/desliga fica em dado, não em código: core.parametro. Assim ligar
-- um aviso é um UPDATE, não um deploy.
-- =====================================================================================

-- -------------------------------------------------------------------------------------
-- 1. Parâmetros dos gatilhos
-- -------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS core.parametro (
  chave       text PRIMARY KEY,
  valor       text NOT NULL,
  descricao   text,
  alterado_em timestamptz NOT NULL DEFAULT now(),
  alterado_por uuid REFERENCES core.usuario(id)
);

COMMENT ON TABLE core.parametro IS
  'Configuração operacional que muda sem deploy. Os gatilhos de e-mail vivem aqui porque ligar um aviso é decisão de processo, não de código.';

INSERT INTO core.parametro (chave, valor, descricao) VALUES
  ('email.gatilho.sci_revisao_solicitante', 'true',
   'Avisa o solicitante quando a SCI volta para revisão dele. Único ligado na primeira versão: o almoxarifado acompanha a fila no sistema todo dia, o solicitante não.'),
  ('email.gatilho.scm_aprovacao_lider', 'false',
   'Avisa o responsável direto do grupo quando uma SCM entra na aprovação dele. Preparado e desligado por decisão da reunião.'),
  ('email.gatilho.treinamento_concluido', 'false',
   'Avisa o colaborador e o responsável do grupo na conclusão de treinamento. Depende de decidir se o comprovante vai anexado.'),
  ('email.remetente', 'manutencao@biotrop.com.br',
   'Caixa de comunicação usada pelo Microsoft Graph. Precisa existir e estar na Application Access Policy do aplicativo.'),
  ('email.responder_para', '',
   'Endereço que recebe resposta ao aviso. Vazio = sem replyTo.')
ON CONFLICT (chave) DO NOTHING;

CREATE OR REPLACE FUNCTION core.gatilho_ligado(p_chave text)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = core, pg_temp AS $$
  SELECT coalesce((SELECT valor = 'true' FROM core.parametro WHERE chave = p_chave), false);
$$;

COMMENT ON FUNCTION core.gatilho_ligado(text) IS
  'Lê o parâmetro do gatilho. SECURITY DEFINER porque o gatilho roda no contexto de quem fez a ação, e essa pessoa não precisa ter acesso à tabela de parâmetros.';

-- -------------------------------------------------------------------------------------
-- 2. Enfileirar
-- -------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION core.enfileirar_email(
  p_gatilho     text,
  p_destinatario citext,
  p_assunto     text,
  p_corpo_texto text,
  p_cc          citext[] DEFAULT NULL,
  p_referencia  text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = core, pg_temp AS $$
DECLARE
  v_id uuid;
BEGIN
  IF NOT core.gatilho_ligado('email.gatilho.' || p_gatilho) THEN
    RETURN NULL;
  END IF;

  -- Destinatário vazio não é motivo para abortar a ação do usuário: a SCI
  -- tem de ser devolvida mesmo que o cadastro esteja sem e-mail. Mas o
  -- caso fica REGISTRADO, porque "não chegou e-mail" sem rastro é o pior
  -- defeito para investigar depois.
  IF p_destinatario IS NULL OR position('@' in p_destinatario::text) = 0 THEN
    INSERT INTO core.email_fila (gatilho, destinatario, assunto, corpo_texto, referencia, status, erro)
    VALUES (p_gatilho, coalesce(p_destinatario, ''), p_assunto, p_corpo_texto, p_referencia,
            'sem_destinatario', 'Sem e-mail de destino no cadastro.')
    RETURNING id INTO v_id;
    RETURN v_id;
  END IF;

  INSERT INTO core.email_fila (gatilho, destinatario, cc, assunto, corpo_texto, referencia, status)
  VALUES (p_gatilho, p_destinatario, p_cc, p_assunto, p_corpo_texto, p_referencia, 'pendente')
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- -------------------------------------------------------------------------------------
-- 3. Gatilho: SCI devolvida para revisão do solicitante
-- -------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION almox.fn_email_sci_revisao()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = almox, core, pg_temp AS $$
DECLARE
  v_email  citext;
  v_nome   text;
  v_corpo  text;
BEGIN
  -- Só na ENTRADA no status. Sem esta comparação, qualquer edição da
  -- solicitação já em revisão dispararia um aviso novo.
  IF NEW.status <> 'revisao_solicitante' OR OLD.status = 'revisao_solicitante' THEN
    RETURN NEW;
  END IF;

  SELECT u.email, u.nome INTO v_email, v_nome
    FROM core.usuario u WHERE u.id = NEW.solicitante_id;

  v_corpo :=
    'Olá, ' || coalesce(v_nome, '') || E'.\n\n' ||
    'A sua solicitação de cadastro de item ' || NEW.codigo ||
    E' foi devolvida para revisão pelo almoxarifado.\n\n' ||
    'O que precisa ser corrigido:' || E'\n' ||
    coalesce(NEW.observacao_almoxarife, '—') || E'\n\n' ||
    'Para corrigir, entre na plataforma, abra "Minhas solicitações" e use o botão ' ||
    '"Corrigir e reenviar" na linha da ' || NEW.codigo || E'.\n\n' ||
    E'Enquanto a solicitação estiver neste status, ela não avança no almoxarifado.\n\n' ||
    E'—\nPlataforma de Manutenção · Biotrop\nEsta mensagem foi gerada pelo sistema.';

  PERFORM core.enfileirar_email(
    'sci_revisao_solicitante',
    v_email,
    '[Manutenção] ' || NEW.codigo || ' precisa da sua revisão',
    v_corpo,
    NULL,
    NEW.codigo
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_email_sci_revisao ON almox.sci;
CREATE TRIGGER trg_email_sci_revisao
  AFTER UPDATE OF status ON almox.sci
  FOR EACH ROW EXECUTE FUNCTION almox.fn_email_sci_revisao();

COMMENT ON FUNCTION almox.fn_email_sci_revisao() IS
  'Enfileira o aviso ao solicitante na entrada do status revisao_solicitante. AFTER UPDATE OF status para não rodar em toda edição da linha.';

-- -------------------------------------------------------------------------------------
-- 4. Gatilho: SCM entrou na aprovação do responsável (preparado, desligado)
-- -------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION almox.fn_email_scm_aprovacao()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = almox, core, pg_temp AS $$
DECLARE
  v_email citext;
  v_nome  text;
  v_sol   text;
  v_corpo text;
  v_itens text;
BEGIN
  IF NEW.status <> 'pendente_aprovacao_lider'
     OR (OLD.status IS NOT NULL AND OLD.status = 'pendente_aprovacao_lider') THEN
    RETURN NEW;
  END IF;

  SELECT u.email, u.nome INTO v_email, v_nome
    FROM core.usuario u WHERE u.id = NEW.aprovador_id;
  SELECT u.nome INTO v_sol FROM core.usuario u WHERE u.id = NEW.solicitante_id;

  SELECT string_agg('  - ' || coalesce(i.codigo_sistema, 'sem código') || ' — ' ||
                    coalesce(i.descricao, 'sem descrição') || ' · qtd ' || i.quantidade::text,
                    E'\n' ORDER BY i.criado_em)
    INTO v_itens
    FROM almox.scm_item i WHERE i.scm_id = NEW.id;

  v_corpo :=
    'Olá, ' || coalesce(v_nome, '') || E'.\n\n' ||
    E'Existe uma solicitação de compra esperando a sua aprovação.\n\n' ||
    '  Código: ' || NEW.codigo || E'\n' ||
    '  Solicitante: ' || coalesce(v_sol, '—') || E'\n' ||
    '  Urgência: ' || coalesce(NEW.urgencia::text, '—') || E'\n' ||
    '  Nº OM: ' || coalesce(NEW.numero_om, '—') || E'\n\n' ||
    'Itens:' || E'\n' || coalesce(v_itens, '  (sem itens)') || E'\n\n' ||
    'Uso: ' || coalesce(NEW.descricao_uso, '—') || E'\n\n' ||
    'A aprovação é feita DENTRO da plataforma, em "Aprovações SCM" — é lá que fica o ' ||
    E'registro de quem autorizou e quando. Responder este e-mail não aprova a solicitação.\n\n' ||
    E'—\nPlataforma de Manutenção · Biotrop';

  PERFORM core.enfileirar_email(
    'scm_aprovacao_lider',
    v_email,
    '[Manutenção] ' || NEW.codigo || ' aguarda sua aprovação',
    v_corpo,
    NULL,
    NEW.codigo
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_email_scm_aprovacao ON almox.scm;
CREATE TRIGGER trg_email_scm_aprovacao
  AFTER INSERT OR UPDATE OF status ON almox.scm
  FOR EACH ROW EXECUTE FUNCTION almox.fn_email_scm_aprovacao();

-- -------------------------------------------------------------------------------------
-- 5. Gatilho: treinamento concluído (preparado, desligado)
-- -------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION lms.fn_email_conclusao()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = lms, core, pg_temp AS $$
DECLARE
  v_email  citext;
  v_nome   text;
  v_resp   citext;
  v_titulo text;
  v_corpo  text;
BEGIN
  SELECT u.email, u.nome INTO v_email, v_nome
    FROM core.usuario u WHERE u.id = NEW.usuario_id;

  -- Responsável direto do grupo entra em cópia: foi o pedido da reunião,
  -- "encaminhar para ambos".
  SELECT r.email INTO v_resp
    FROM core.usuario u
    JOIN core.grupo g ON g.id = u.grupo_id
    JOIN core.usuario r ON r.id = g.responsavel_id
   WHERE u.id = NEW.usuario_id AND r.ativo;

  SELECT t.titulo INTO v_titulo FROM lms.treinamento t WHERE t.id = NEW.treinamento_id;

  v_corpo :=
    E'Olá.\n\n' || coalesce(v_nome, 'O colaborador') || ' concluiu o treinamento "' ||
    coalesce(v_titulo, '—') || E'".\n\n' ||
    '  Comprovante: ' || NEW.codigo_comprovante || E'\n' ||
    '  Conclusão: ' || to_char(NEW.concluido_em, 'DD/MM/YYYY') || E'\n' ||
    '  Aproveitamento: ' || NEW.nota::text || E'%\n' ||
    '  Validade: ' || coalesce(to_char(NEW.expira_em, 'DD/MM/YYYY'), 'indeterminada') || E'\n\n' ||
    E'O comprovante fica disponível na plataforma, em "Comprovantes".\n' ||
    E'Este documento é evidência interna de treinamento e não substitui certificado legal de NR.\n\n' ||
    E'—\nPlataforma de Manutenção · Biotrop';

  PERFORM core.enfileirar_email(
    'treinamento_concluido',
    v_email,
    '[Manutenção] Treinamento concluído — ' || coalesce(v_titulo, ''),
    v_corpo,
    CASE WHEN v_resp IS NULL THEN NULL ELSE ARRAY[v_resp] END,
    NEW.codigo_comprovante
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_email_conclusao ON lms.conclusao;
CREATE TRIGGER trg_email_conclusao
  AFTER INSERT ON lms.conclusao
  FOR EACH ROW EXECUTE FUNCTION lms.fn_email_conclusao();

-- -------------------------------------------------------------------------------------
-- 6. Consultas de operação
-- -------------------------------------------------------------------------------------

CREATE OR REPLACE VIEW app.vw_email_fila AS
SELECT f.id, f.gatilho, f.destinatario, f.assunto, f.referencia,
       f.status, f.tentativas, f.erro, f.criado_em, f.enviado_em, f.proxima_tentativa_em
  FROM core.email_fila f
 ORDER BY f.criado_em DESC;

ALTER VIEW app.vw_email_fila SET (security_invoker = true);

COMMENT ON VIEW app.vw_email_fila IS
  'Caixa de saída para a tela de administração. security_invoker para a policy da tabela valer para quem consulta.';

-- "A rotina rodou?" e "algo ficou preso?" em duas linhas:
--   SELECT * FROM core.rotina_execucao WHERE rotina='email_worker' ORDER BY executado_em DESC LIMIT 5;
--   SELECT status, count(*) FROM core.email_fila GROUP BY status;
