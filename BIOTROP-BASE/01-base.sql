-- =====================================================================================
-- BIOTROP - Plataforma de Manutencao Industrial
-- Migration 0001_base.sql  ·  PostgreSQL 15  ·  arquivo auto-contido e idempotente
-- =====================================================================================
--
-- OBJETIVO DESTE ARQUIVO
--   Sair do localStorage (HTML unico) para um PostgreSQL de verdade na VM Azure,
--   sem perder o que ja foi digitado, mantendo a fase 1 operavel por UMA pessoa.
--   O arquivo faz, na ordem: extensoes, schemas, controle de migrations, tipos,
--   tabelas, indices, constraints, funcoes/triggers de regra, dados de referencia,
--   maquinario de importacao do dump do navegador e, no fim, as views das telas.
--
-- COMO APLICAR (fase 1: VM Azure, git pull + build manual)
--   Este arquivo E a migration 0001. No repositorio ele entra como
--   migrations/0001_base.sql (o nome schema-migracao.sql e so o da proposta), porque
--   o script de deploy aplica por ordem de prefixo numerico.
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f migrations/0001_base.sql
--   Rodar duas vezes nao quebra: todo objeto usa IF NOT EXISTS / OR REPLACE e os
--   seeds usam ON CONFLICT DO NOTHING. Isso importa porque na fase 1 o deploy e
--   manual e a chance de reexecutar o mesmo arquivo e real.
--
-- VERSIONAMENTO DE MIGRATIONS (decisao)
--   Nao usamos ferramenta externa (Flyway/Prisma/Sqitch). Um arquivo por mudanca,
--   nome NNNN_descricao.sql, aplicados em ordem crescente por um script shell na VM,
--   e a tabela core.migration registra o que ja rodou (versao, checksum, quando, quem).
--   Regra: FORWARD-ONLY. Nao existe "down". Desfazer = escrever a proxima migration.
--   Porque: uma pessoa mantendo, deploy manual, sem CI. Um `ls migrations/` e um
--   `select * from core.migration` bastam para saber o estado do banco. Ferramenta
--   com estado proprio seria mais uma coisa para dar errado no `git pull`.
--
-- CODIGOS SEQUENCIAIS (SCI-0001 / SCM-0001) - decisao explicada
--   NAO usamos SEQUENCE nativa. SEQUENCE nao volta atras em ROLLBACK, entao geraria
--   buracos (SCI-0007 inexistente) em um codigo que o usuario le, anota e cobra.
--   Usamos core.sequencia + core.proximo_codigo(): um UPDATE ... RETURNING na linha
--   do escopo. O UPDATE trava a linha, entao duas solicitacoes simultaneas ficam
--   serializadas e NUNCA recebem o mesmo codigo; se a transacao aborta, o numero
--   volta e e reaproveitado. Custo: a linha fica travada ate o COMMIT. No volume
--   real (dezenas de solicitacoes por dia) isso e irrelevante, e a ausencia de
--   buraco na numeracao vale mais que a concorrencia teorica.
--   O codigo e preenchido por trigger BEFORE INSERT: o app manda codigo NULL e o
--   banco decide. Assim nenhum cliente (nem um script de importacao) consegue
--   inventar codigo.
--
-- BACKUP (fase 1)
--   Rotina diaria na VM: pg_dump -Fc para arquivo + backup do disco da VM.
--   Cada execucao registra em core.rotina_execucao para dar para responder
--   "o backup rodou hoje?" com uma query, sem abrir a VM.
--
-- ANEXOS E FOTOS (decisao)
--   Hoje sao dataURL base64 dentro do localStorage. Vao para core.anexo como bytea
--   na fase 1 (uma VM, um Postgres, backup unico - simples de manter). A tabela ja
--   nasce com a coluna url_externa: quando o volume pesar, o conteudo migra para
--   Azure Blob e a linha continua sendo a mesma referencia para o resto do schema.
--
-- =====================================================================================


-- =====================================================================================
-- 1. EXTENSOES
-- =====================================================================================
-- O arquivo tem texto em portugues nos COMMENT ON: fixar a codificacao evita que
-- um psql aberto em outra pagina de codigo (comum no Windows da VM) grave lixo.
SET client_encoding = 'UTF8';

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid() e digest() para sha256 de anexo
CREATE EXTENSION IF NOT EXISTS citext;     -- e-mail como citext: login nao depende de caixa
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- busca por trecho nas listas de SCI/SCM
CREATE EXTENSION IF NOT EXISTS unaccent;   -- busca sem acento ("valvula" acha "válvula")


-- =====================================================================================
-- 2. SCHEMAS
--   Um schema por modulo. Motivo pratico: GRANT por modulo, pg_dump -n de um modulo
--   isolado, e um `\dt almox.*` que responde "o que existe no almoxarifado" sem
--   varrer 60 tabelas. O schema app so tem views - e o contrato com as telas.
-- =====================================================================================
CREATE SCHEMA IF NOT EXISTS core;   -- pessoas, acesso, grupos, anexos, auditoria, e-mail
CREATE SCHEMA IF NOT EXISTS almox;  -- almoxarifado: familias, SCI, SCM
CREATE SCHEMA IF NOT EXISTS util;   -- utilidades: medidores e leituras
CREATE SCHEMA IF NOT EXISTS lms;    -- treinamentos
CREATE SCHEMA IF NOT EXISTS pcm;    -- PCM (etapa posterior, tabelas previstas)
CREATE SCHEMA IF NOT EXISTS mig;    -- staging e funcoes da migracao do localStorage
CREATE SCHEMA IF NOT EXISTS app;    -- views consumidas pelas telas

COMMENT ON SCHEMA core IS 'Cadastro de pessoas, perfis de acesso, grupos/cargos, anexos, auditoria, fila de e-mail e controle de migrations.';
COMMENT ON SCHEMA almox IS 'Almoxarifado: familias de item com campos dinamicos, SCI (cadastro de item) e SCM (compra de materiais).';
COMMENT ON SCHEMA util IS 'Utilidades: medidores de agua, gas, energia e horimetro, e os apontamentos de leitura.';
COMMENT ON SCHEMA lms IS 'Treinamentos: conteudo versionado, matriculas por pessoa ou por grupo, progresso, avaliacoes e comprovantes.';
COMMENT ON SCHEMA pcm IS 'PCM: ordens de servico, planos preventivos, ativos e estoque. Etapa posterior - tabelas previstas para nao redesenhar o banco depois.';
COMMENT ON SCHEMA mig IS 'Migracao: guarda o JSON exportado do navegador e as funcoes que transformam esse JSON nas tabelas definitivas. Pode ser dropado quando a virada terminar.';
COMMENT ON SCHEMA app IS 'Somente views: o contrato entre o banco e as telas. Mudar tabela sem mudar view nao quebra a aplicacao.';


-- =====================================================================================
-- 3. ROLES
--   biotrop_app  : role da aplicacao (a que a VM usa na connection string).
--   biotrop_ro   : leitura, para consulta/relatorio e para o proprio dono do banco
--                  conferir dado sem risco de escrever.
--   Se o usuario do psql nao tiver permissao de criar role, este bloco e ignorado
--   sem falhar - as roles podem ser criadas depois e os GRANTs do fim reexecutados.
-- =====================================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'biotrop_app') THEN
    BEGIN
      CREATE ROLE biotrop_app NOLOGIN;
    EXCEPTION WHEN insufficient_privilege THEN
      RAISE NOTICE 'sem permissao para criar role biotrop_app - crie manualmente e reexecute os GRANTs do fim do arquivo';
    END;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'biotrop_ro') THEN
    BEGIN
      CREATE ROLE biotrop_ro NOLOGIN;
    EXCEPTION WHEN insufficient_privilege THEN
      RAISE NOTICE 'sem permissao para criar role biotrop_ro';
    END;
  END IF;
END $$;


-- =====================================================================================
-- 4. CONTROLE DE MIGRATIONS
-- =====================================================================================
CREATE TABLE IF NOT EXISTS core.migration (
  versao        text        PRIMARY KEY,
  nome          text        NOT NULL,
  checksum      text,
  aplicado_em   timestamptz NOT NULL DEFAULT now(),
  aplicado_por  text        NOT NULL DEFAULT current_user,
  duracao_ms    integer,
  observacao    text
);
COMMENT ON TABLE  core.migration IS 'Registro de quais arquivos de migration ja foram aplicados neste banco. Forward-only: nao existe rollback, desfazer e escrever a proxima migration.';
COMMENT ON COLUMN core.migration.versao IS 'Prefixo numerico do arquivo (0001, 0002...). Ordem de aplicacao.';
COMMENT ON COLUMN core.migration.checksum IS 'sha256 do arquivo aplicado, calculado pelo script de deploy. Serve para detectar arquivo editado depois de aplicado.';


-- =====================================================================================
-- 5. HELPERS DE INFRAESTRUTURA (touch, sequencia, auditoria, anexo, rotinas)
-- =====================================================================================

-- 5.1 atualizado_em automatico -------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_touch() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.atualizado_em := now();
  RETURN NEW;
END $$;
COMMENT ON FUNCTION core.fn_touch() IS 'Trigger BEFORE UPDATE genérica: mantem atualizado_em sem depender do app lembrar de gravar.';

-- 5.2 codigos sequenciais ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.sequencia (
  escopo         text        PRIMARY KEY,
  prefixo        text        NOT NULL,
  largura        smallint    NOT NULL DEFAULT 4 CHECK (largura BETWEEN 1 AND 12),
  ultimo_valor   bigint      NOT NULL DEFAULT 0 CHECK (ultimo_valor >= 0),
  atualizado_em  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE  core.sequencia IS 'Contador dos codigos que o usuario le (SCI-0001, SCM-0001). Uma linha por escopo; core.proximo_codigo() faz UPDATE ... RETURNING nessa linha, o que serializa concorrentes e devolve o numero em caso de ROLLBACK (sem buraco na numeracao).';
COMMENT ON COLUMN core.sequencia.ultimo_valor IS 'Ultimo numero entregue. Na migracao e reposicionado por mig.sincronizar_sequencias() para o maior codigo importado.';

CREATE OR REPLACE FUNCTION core.proximo_codigo(p_escopo text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  v_n     bigint;
  v_pre   text;
  v_larg  smallint;
BEGIN
  UPDATE core.sequencia
     SET ultimo_valor  = ultimo_valor + 1,
         atualizado_em = now()
   WHERE escopo = p_escopo
  RETURNING ultimo_valor, prefixo, largura INTO v_n, v_pre, v_larg;

  IF v_n IS NULL THEN
    RAISE EXCEPTION 'Sequencia "%" nao cadastrada em core.sequencia', p_escopo;
  END IF;
  RETURN v_pre || lpad(v_n::text, v_larg, '0');
END $$;
COMMENT ON FUNCTION core.proximo_codigo(text) IS 'Devolve o proximo codigo do escopo (ex: SCI-0007). Trava a linha do contador, portanto e seguro em concorrencia.';

CREATE OR REPLACE FUNCTION core.fn_preencher_codigo() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.codigo IS NULL OR btrim(NEW.codigo) = '' THEN
    NEW.codigo := core.proximo_codigo(TG_ARGV[0]);
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION core.fn_preencher_codigo() IS 'Trigger BEFORE INSERT: preenche a coluna codigo com core.proximo_codigo(TG_ARGV[0]) quando o app manda NULL. Quem decide o codigo e o banco, nunca o cliente.';

-- 5.3 auditoria ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.auditoria (
  id            bigserial   PRIMARY KEY,
  tabela        text        NOT NULL,
  registro_id   text        NOT NULL,
  operacao      char(1)     NOT NULL CHECK (operacao IN ('I','U','D')),
  antes         jsonb,
  depois        jsonb,
  ator          text        NOT NULL DEFAULT current_user,
  ator_email    citext,
  em            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_auditoria_tabela_reg ON core.auditoria (tabela, registro_id, em DESC);
CREATE INDEX IF NOT EXISTS ix_auditoria_em         ON core.auditoria (em DESC);
COMMENT ON TABLE  core.auditoria IS 'Trilha generica de alteracoes das tabelas sensiveis (acesso, solicitacoes, leituras, matriculas). Uma tabela unica em vez de uma _historico por entidade: com uma pessoa mantendo, menos objeto para lembrar.';
COMMENT ON COLUMN core.auditoria.ator_email IS 'E-mail do usuario logado quando a aplicacao informa via SET LOCAL app.usuario_email. Fica nulo em alteracao feita direto no psql.';

CREATE OR REPLACE FUNCTION core.fn_auditar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_id    text;
  v_email citext;
BEGIN
  BEGIN
    v_email := nullif(current_setting('app.usuario_email', true), '')::citext;
  EXCEPTION WHEN others THEN
    v_email := NULL;
  END;

  IF TG_OP = 'DELETE' THEN
    -- Tabela de ligacao (ex: core.perfil_permissao) nao tem coluna id: nesse caso
    -- a propria linha em texto identifica o registro, e registro_id nunca fica nulo.
    v_id := coalesce(to_jsonb(OLD) ->> 'id', to_jsonb(OLD)::text);
    INSERT INTO core.auditoria (tabela, registro_id, operacao, antes, ator_email)
    VALUES (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, v_id, 'D', to_jsonb(OLD), v_email);
    RETURN OLD;
  ELSIF TG_OP = 'UPDATE' THEN
    IF to_jsonb(OLD) = to_jsonb(NEW) THEN
      RETURN NEW;  -- UPDATE que nao mudou nada nao gera linha de auditoria
    END IF;
    v_id := coalesce(to_jsonb(NEW) ->> 'id', to_jsonb(NEW)::text);
    INSERT INTO core.auditoria (tabela, registro_id, operacao, antes, depois, ator_email)
    VALUES (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, v_id, 'U', to_jsonb(OLD), to_jsonb(NEW), v_email);
    RETURN NEW;
  ELSE
    v_id := coalesce(to_jsonb(NEW) ->> 'id', to_jsonb(NEW)::text);
    INSERT INTO core.auditoria (tabela, registro_id, operacao, depois, ator_email)
    VALUES (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, v_id, 'I', to_jsonb(NEW), v_email);
    RETURN NEW;
  END IF;
END $$;
COMMENT ON FUNCTION core.fn_auditar() IS 'Trigger AFTER I/U/D que grava a linha inteira em core.auditoria. A aplicacao deve fazer SET LOCAL app.usuario_email no inicio da transacao para a trilha ter nome.';

-- 5.4 anexos -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.anexo (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  nome_original text        NOT NULL,
  mime          text        NOT NULL DEFAULT 'application/octet-stream',
  bytes         integer     NOT NULL CHECK (bytes >= 0),
  sha256        text,
  conteudo      bytea,
  url_externa   text,
  criado_por    uuid,
  criado_em     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_anexo_tem_conteudo CHECK (conteudo IS NOT NULL OR url_externa IS NOT NULL),
  CONSTRAINT ck_anexo_tamanho      CHECK (bytes <= 20 * 1024 * 1024)
);
CREATE INDEX IF NOT EXISTS ix_anexo_sha256 ON core.anexo (sha256);
COMMENT ON TABLE  core.anexo IS 'Arquivo binario unico do sistema (foto de SCI, foto do marcador, anexo de SCM, material de aula). Fase 1 guarda em bytea no proprio Postgres para o backup ser um so; url_externa ja existe para o dia em que o conteudo for para o Azure Blob.';
COMMENT ON COLUMN core.anexo.sha256 IS 'Hash do conteudo. Permite detectar a mesma foto enviada duas vezes sem duplicar o binario.';
COMMENT ON COLUMN core.anexo.bytes IS 'Tamanho em bytes, limitado a 20 MB: foto de celular cabe, PDF de manual gigante nao entope o dump.';

CREATE OR REPLACE FUNCTION core.anexo_de_dataurl(
  p_dataurl text,
  p_nome    text DEFAULT 'anexo',
  p_criador uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_mime  text;
  v_b64   text;
  v_bin   bytea;
  v_id    uuid;
BEGIN
  IF p_dataurl IS NULL OR btrim(p_dataurl) = '' THEN
    RETURN NULL;
  END IF;

  -- Formato gravado pelo HTML local: data:image/jpeg;base64,AAAA...
  v_mime := coalesce(substring(p_dataurl from '^data:([^;]+);'), 'application/octet-stream');
  v_b64  := regexp_replace(p_dataurl, '^data:[^,]*,', '');
  BEGIN
    v_bin := decode(replace(replace(v_b64, E'\n', ''), E'\r', ''), 'base64');
  EXCEPTION WHEN others THEN
    RETURN NULL;  -- dataURL corrompido no navegador nao pode abortar a importacao
  END;

  INSERT INTO core.anexo (nome_original, mime, bytes, sha256, conteudo, criado_por)
  VALUES (p_nome, v_mime, octet_length(v_bin), encode(digest(v_bin, 'sha256'), 'hex'), v_bin, p_criador)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;
COMMENT ON FUNCTION core.anexo_de_dataurl(text, text, uuid) IS 'Converte o dataURL base64 que hoje vive no localStorage em uma linha de core.anexo. Usada pela migracao e pelo upload do app.';

-- 5.5 execucao de rotinas (backup, envio de e-mail, sincronizacoes) -------------------
CREATE TABLE IF NOT EXISTS core.rotina_execucao (
  id        bigserial   PRIMARY KEY,
  rotina    text        NOT NULL,
  inicio    timestamptz NOT NULL DEFAULT now(),
  fim       timestamptz,
  sucesso   boolean,
  detalhe   text
);
CREATE INDEX IF NOT EXISTS ix_rotina_execucao ON core.rotina_execucao (rotina, inicio DESC);
COMMENT ON TABLE core.rotina_execucao IS 'Log das rotinas de servidor (backup diario para SQL, disparo de e-mail via Graph, sincronizacao de matriculas). Existe para responder "o backup rodou?" por query, sem abrir a VM.';




-- =====================================================================================
-- 6. TIPOS ENUM
--   Enum onde a lista e regra de negocio fechada (status, tipo de medidor). Tabela de
--   apoio onde a lista muda sem mudar regra (centro de custo, familia). Enum errado
--   custa uma migration; tabela para status permitiria status invalido em producao.
-- =====================================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE t.typname = 'camm' AND n.nspname = 'core') THEN
    CREATE TYPE core.camm AS ENUM ('CAMM 1', 'CAMM 2', 'CAMM 3', 'C. LOG');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE t.typname = 'tema' AND n.nspname = 'core') THEN
    CREATE TYPE core.tema AS ENUM ('claro', 'escuro', 'sistema');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE t.typname = 'email_status' AND n.nspname = 'core') THEN
    CREATE TYPE core.email_status AS ENUM ('pendente', 'enviando', 'enviado', 'erro', 'cancelado');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE t.typname = 'sci_status' AND n.nspname = 'almox') THEN
    CREATE TYPE almox.sci_status AS ENUM (
      'pendente_aprovacao',   -- Pendente de aprovacao
      'revisao_solicitante',  -- Aguardando revisao do solicitante
      'em_compra',            -- Em compra
      'aguardando_cadastro',  -- Aguardando o cadastro de item
      'cadastrado',           -- Cadastrado
      'reprovada'             -- Reprovada
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE t.typname = 'scm_status' AND n.nspname = 'almox') THEN
    CREATE TYPE almox.scm_status AS ENUM (
      'pendente_aprovacao_lider',
      'aprovada',
      'reprovada',
      'revisao_solicitada',
      'em_tratativa',
      'concluida'
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE t.typname = 'urgencia' AND n.nspname = 'almox') THEN
    CREATE TYPE almox.urgencia AS ENUM ('baixa', 'media', 'alta');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE t.typname = 'medidor_tipo' AND n.nspname = 'util') THEN
    CREATE TYPE util.medidor_tipo AS ENUM ('agua', 'gas', 'energia', 'horimetro');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE t.typname = 'unidade_medida' AND n.nspname = 'util') THEN
    CREATE TYPE util.unidade_medida AS ENUM ('m3', 'Nm3', 'kWh', 'h');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE t.typname = 'desvio_tipo' AND n.nspname = 'util') THEN
    CREATE TYPE util.desvio_tipo AS ENUM (
      'consumo_negativo',
      'leitura_seguinte_menor',
      'salto_consumo',
      'consumo_zero',
      'horimetro_sem_foto'
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE t.typname = 'versao_status' AND n.nspname = 'lms') THEN
    CREATE TYPE lms.versao_status AS ENUM ('rascunho', 'publicada', 'arquivada');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE t.typname = 'aula_tipo' AND n.nspname = 'lms') THEN
    CREATE TYPE lms.aula_tipo AS ENUM ('texto', 'video_youtube', 'video_arquivo', 'pdf', 'imagem', 'link');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE t.typname = 'questao_tipo' AND n.nspname = 'lms') THEN
    CREATE TYPE lms.questao_tipo AS ENUM ('unica', 'multipla');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE t.typname = 'alvo_tipo' AND n.nspname = 'lms') THEN
    CREATE TYPE lms.alvo_tipo AS ENUM ('usuario', 'grupo');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE t.typname = 'matricula_status' AND n.nspname = 'lms') THEN
    CREATE TYPE lms.matricula_status AS ENUM (
      'nao_iniciada',
      'em_andamento',
      'aguardando_avaliacao',
      'concluida',
      'reprovada',
      'cancelada'
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE t.typname = 'os_tipo' AND n.nspname = 'pcm') THEN
    CREATE TYPE pcm.os_tipo AS ENUM ('corretiva', 'preventiva', 'preditiva', 'melhoria');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE t.typname = 'os_status' AND n.nspname = 'pcm') THEN
    CREATE TYPE pcm.os_status AS ENUM ('aberta', 'planejada', 'em_execucao', 'concluida', 'cancelada');
  END IF;
END $$;

COMMENT ON TYPE core.camm        IS 'Unidade industrial. Utilidades usa as quatro; SCM aceita apenas CAMM 1/2/3 (restrito por CHECK na tabela, nao no tipo, para nao duplicar enum).';
COMMENT ON TYPE almox.sci_status IS 'Status da SCI conforme definido em reuniao e alinhado ao Forms. Os status antigos (pendente/aprovado/recusado/solicitado_cadastro) sao convertidos na importacao por mig.mapear_status_sci().';
COMMENT ON TYPE util.desvio_tipo IS 'Tipos de desvio que o PCM precisa olhar: consumo negativo, leitura seguinte menor, salto acima de 3x a mediana, consumo zero e horimetro sem foto.';


-- =====================================================================================
-- 7. CORE: ACESSO, PESSOAS E GRUPOS
-- =====================================================================================

-- 7.1 catalogo de permissoes ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.permissao (
  chave      text     PRIMARY KEY,
  area       text     NOT NULL,
  rotulo     text     NOT NULL,
  descricao  text,
  posicao    smallint NOT NULL DEFAULT 0
);
COMMENT ON TABLE  core.permissao IS 'Catalogo das permissoes granulares. E tabela, e nao colunas booleanas no perfil, porque a lista cresceu no meio do caminho (as permissoes de SCM entraram depois): acrescentar permissao passa a ser um INSERT, nao um ALTER TABLE mais deploy.';
COMMENT ON COLUMN core.permissao.chave IS 'Identificador usado no codigo, no formato area.permissao (ex: almoxarifado.scm_aprovacao).';

CREATE TABLE IF NOT EXISTS core.perfil (
  id             text        PRIMARY KEY,
  nome           text        NOT NULL,
  fixo           boolean     NOT NULL DEFAULT false,
  ativo          boolean     NOT NULL DEFAULT true,
  descricao      text,
  criado_em      timestamptz NOT NULL DEFAULT now(),
  atualizado_em  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE  core.perfil IS 'Perfis de acesso (admin, gestor, pcm, almoxarife, lider, tecnico, viewer). O id e texto e igual ao que o HTML local ja usava, para a importacao nao precisar traduzir nada.';
COMMENT ON COLUMN core.perfil.fixo IS 'Perfil de sistema (admin). Nao pode ser apagado nem perder permissao - protegido por trigger, porque perder o admin em producao deixa o sistema sem dono.';

CREATE TABLE IF NOT EXISTS core.perfil_permissao (
  perfil_id       text NOT NULL REFERENCES core.perfil(id) ON DELETE CASCADE,
  permissao_chave text NOT NULL REFERENCES core.permissao(chave) ON DELETE CASCADE,
  PRIMARY KEY (perfil_id, permissao_chave)
);
COMMENT ON TABLE core.perfil_permissao IS 'Quais permissoes cada perfil tem. A view app.vw_perfil_permissoes devolve isso no mesmo formato de objeto (almoxarifado/pcm/utilidades) que as telas ja consomem hoje.';

-- 7.2 grupos / cargos ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.grupo (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  origem_id      text        UNIQUE,
  codigo         text        NOT NULL UNIQUE,
  nome           text        NOT NULL,
  area           text,
  responsavel_id uuid,
  ativo          boolean     NOT NULL DEFAULT true,
  criado_em      timestamptz NOT NULL DEFAULT now(),
  atualizado_em  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE  core.grupo IS 'Grupos/cargos da manutencao (Mecanica, Soldador, Tecnico Utilidades, Eletrica/Automacao, Predial, Predial Eletrica, Eletromecanica, PCM, Almoxarifado, Coordenador ADM, Coordenador Eletrica). O grupo passa a ser a origem do aprovador e o alvo de treinamento obrigatorio.';
COMMENT ON COLUMN core.grupo.responsavel_id IS 'Responsavel direto do grupo. E daqui que sai o aprovador da SCM: o campo solto de e-mail do lider vira excecao, nao a regra.';
COMMENT ON COLUMN core.grupo.origem_id IS 'Id que o registro tinha no localStorage (ex: g-mecanica). Existe para a importacao ser idempotente e rastreavel.';

-- 7.3 usuarios ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.usuario (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  origem_id            text        UNIQUE,
  nome                 text        NOT NULL,
  email                citext      NOT NULL UNIQUE,
  entra_object_id      uuid        UNIQUE,
  senha_hash           text,
  perfil_id            text        NOT NULL REFERENCES core.perfil(id),
  grupo_id             uuid        REFERENCES core.grupo(id) ON DELETE SET NULL,
  time                 text,
  email_lider_excecao  citext,
  telefone             text,
  tema                 core.tema   NOT NULL DEFAULT 'sistema',
  notificacoes         boolean     NOT NULL DEFAULT true,
  ativo                boolean     NOT NULL DEFAULT true,
  bloqueado            boolean     NOT NULL DEFAULT false,
  motivo_bloqueio      text,
  ultimo_login_em      timestamptz,
  criado_em            timestamptz NOT NULL DEFAULT now(),
  atualizado_em        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_usuario_email_valido CHECK (position('@' in email::text) > 1),
  CONSTRAINT ck_usuario_bloqueio     CHECK (NOT bloqueado OR motivo_bloqueio IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS ix_usuario_grupo     ON core.usuario (grupo_id) WHERE ativo;
CREATE INDEX IF NOT EXISTS ix_usuario_perfil    ON core.usuario (perfil_id);
CREATE INDEX IF NOT EXISTS ix_usuario_nome_trgm ON core.usuario USING gin (nome gin_trgm_ops);
COMMENT ON TABLE  core.usuario IS 'Pessoas do sistema. O login e o e-mail corporativo; a autenticacao e Microsoft Entra ID, e entra_object_id guarda o oid do token para amarrar a conta do AD a esta linha no primeiro acesso.';
COMMENT ON COLUMN core.usuario.senha_hash IS 'Hash bcrypt/argon2 da senha local. Fica NULL para quem entra por Entra ID; existe apenas como saida de emergencia da fase 1 (VM sem Entra configurado). A senha em texto que hoje esta no localStorage NAO e importada.';
COMMENT ON COLUMN core.usuario.email_lider_excecao IS 'E-mail de lider por excecao. A regra e o responsavel do grupo; este campo cobre quem responde a alguem fora do proprio grupo. Mantido porque o dado atual do localStorage vem assim.';
COMMENT ON COLUMN core.usuario.bloqueado IS 'Bloqueio de acesso. Usuario bloqueado nao autentica, mesmo tendo conta Biotrop valida e estando na lista de e-mails autorizados.';
COMMENT ON COLUMN core.usuario.time IS 'Time textual que o cadastro atual usa (Eletrica e Automacao, Predial, PCM...). Continua existindo porque a SCM filtra por ele; o grupo e o vinculo formal, o time e o rotulo operacional.';

ALTER TABLE core.grupo DROP CONSTRAINT IF EXISTS fk_grupo_responsavel;
ALTER TABLE core.grupo
  ADD CONSTRAINT fk_grupo_responsavel
  FOREIGN KEY (responsavel_id) REFERENCES core.usuario(id) ON DELETE SET NULL;

ALTER TABLE core.anexo DROP CONSTRAINT IF EXISTS fk_anexo_criador;
ALTER TABLE core.anexo
  ADD CONSTRAINT fk_anexo_criador
  FOREIGN KEY (criado_por) REFERENCES core.usuario(id) ON DELETE SET NULL;

-- 7.4 protecao do perfil fixo --------------------------------------------------------
CREATE OR REPLACE FUNCTION core.fn_protege_perfil_fixo() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_TABLE_NAME = 'perfil' THEN
    IF TG_OP = 'DELETE' AND OLD.fixo THEN
      RAISE EXCEPTION 'O perfil "%" e fixo e nao pode ser apagado', OLD.id;
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.fixo AND (NOT NEW.fixo OR NOT NEW.ativo) THEN
      RAISE EXCEPTION 'O perfil "%" e fixo: nao pode ser desativado nem deixar de ser fixo', OLD.id;
    END IF;
  ELSE
    IF EXISTS (SELECT 1 FROM core.perfil p WHERE p.id = OLD.perfil_id AND p.fixo) THEN
      RAISE EXCEPTION 'Nao e possivel remover permissoes do perfil fixo "%"', OLD.perfil_id;
    END IF;
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
COMMENT ON FUNCTION core.fn_protege_perfil_fixo() IS 'Impede apagar/desativar o perfil admin e impede tirar permissao dele. Sem essa trava, um clique na tela de perfis deixa a plataforma sem ninguem capaz de administrar.';

DROP TRIGGER IF EXISTS tg_perfil_fixo ON core.perfil;
CREATE TRIGGER tg_perfil_fixo BEFORE UPDATE OR DELETE ON core.perfil
  FOR EACH ROW EXECUTE FUNCTION core.fn_protege_perfil_fixo();

DROP TRIGGER IF EXISTS tg_perfil_permissao_fixo ON core.perfil_permissao;
CREATE TRIGGER tg_perfil_permissao_fixo BEFORE DELETE ON core.perfil_permissao
  FOR EACH ROW EXECUTE FUNCTION core.fn_protege_perfil_fixo();

-- 7.5 lista de e-mails autorizados ---------------------------------------------------
CREATE TABLE IF NOT EXISTS core.email_autorizado (
  email         citext      PRIMARY KEY,
  ativo         boolean     NOT NULL DEFAULT true,
  perfil_padrao text        REFERENCES core.perfil(id),
  grupo_padrao  uuid        REFERENCES core.grupo(id) ON DELETE SET NULL,
  motivo        text,
  liberado_por  uuid        REFERENCES core.usuario(id) ON DELETE SET NULL,
  liberado_em   timestamptz NOT NULL DEFAULT now(),
  revogado_em   timestamptz,
  CONSTRAINT ck_email_autorizado_revogacao CHECK (ativo OR revogado_em IS NOT NULL)
);
COMMENT ON TABLE  core.email_autorizado IS 'Lista de liberacao de acesso combinada com a TI: ter conta Biotrop no Entra ID nao basta, o e-mail precisa estar aqui e ativo. Separada de core.usuario de proposito - da para liberar alguem antes do primeiro login, e o usuario e criado no momento em que ele entra.';
COMMENT ON COLUMN core.email_autorizado.perfil_padrao IS 'Perfil aplicado no provisionamento automatico do primeiro login. Sem isso o usuario novo entraria sem permissao nenhuma e alguem teria de editar na mao.';

CREATE TABLE IF NOT EXISTS core.login_evento (
  id          bigserial   PRIMARY KEY,
  email       citext,
  usuario_id  uuid        REFERENCES core.usuario(id) ON DELETE SET NULL,
  sucesso     boolean     NOT NULL,
  motivo      text,
  ip          inet,
  user_agent  text,
  em          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_login_evento_email ON core.login_evento (email, em DESC);
COMMENT ON TABLE core.login_evento IS 'Tentativas de login com o motivo da recusa (nao autorizado, bloqueado, inativo). Site com acesso externo: sem esse log nao ha como investigar acesso indevido.';

CREATE OR REPLACE FUNCTION core.pode_autenticar(p_email citext)
RETURNS TABLE (permitido boolean, motivo text, usuario_id uuid)
LANGUAGE sql STABLE AS $$
  SELECT
    CASE
      WHEN a.email IS NULL OR NOT a.ativo THEN false
      WHEN u.id IS NULL                   THEN true
      WHEN u.bloqueado                    THEN false
      WHEN NOT u.ativo                    THEN false
      ELSE true
    END AS permitido,
    CASE
      WHEN a.email IS NULL THEN 'e-mail nao consta na lista de autorizados'
      WHEN NOT a.ativo     THEN 'autorizacao revogada'
      WHEN u.id IS NULL    THEN 'autorizado - usuario sera criado no primeiro acesso'
      WHEN u.bloqueado     THEN coalesce('bloqueado: ' || u.motivo_bloqueio, 'usuario bloqueado')
      WHEN NOT u.ativo     THEN 'usuario inativo'
      ELSE 'ok'
    END AS motivo,
    u.id AS usuario_id
  FROM (SELECT p_email AS email) q
  LEFT JOIN core.email_autorizado a ON a.email = q.email
  LEFT JOIN core.usuario          u ON u.email = q.email;
$$;
COMMENT ON FUNCTION core.pode_autenticar(citext) IS 'Decide se um e-mail vindo do Entra ID pode entrar, e por que nao quando nao pode. Ponto unico da regra: autorizacao ativa E usuario nao bloqueado e nao inativo.';

-- 7.6 fila de e-mail (outbox para o Microsoft Graph) ---------------------------------
CREATE TABLE IF NOT EXISTS core.email_fila (
  id                uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
  destinatario      citext            NOT NULL,
  copia             citext[],
  remetente         citext            NOT NULL DEFAULT 'manutencao@biotrop.com.br',
  assunto           text              NOT NULL,
  corpo_html        text              NOT NULL,
  referencia_tabela text,
  referencia_id     text,
  motivo            text              NOT NULL,
  status            core.email_status NOT NULL DEFAULT 'pendente',
  tentativas        smallint          NOT NULL DEFAULT 0,
  erro              text,
  graph_message_id  text,
  criado_em         timestamptz       NOT NULL DEFAULT now(),
  enviado_em        timestamptz
);
CREATE INDEX IF NOT EXISTS ix_email_fila_pendente ON core.email_fila (criado_em) WHERE status = 'pendente';
COMMENT ON TABLE  core.email_fila IS 'Caixa de saida. O banco grava a intencao de enviar dentro da mesma transacao do fato (ex: SCI voltou para revisao) e uma rotina na VM entrega via Microsoft Graph com a conta remetente corporativa. Se o Graph estiver fora, a mensagem espera na fila em vez de se perder.';
COMMENT ON COLUMN core.email_fila.motivo IS 'Por que este e-mail existe (ex: sci_revisao_solicitante). Serve para nao disparar aviso que ninguem pediu: na SCI a unica notificacao acordada e a de revisao do solicitante.';

DROP TRIGGER IF EXISTS tg_touch_perfil  ON core.perfil;
CREATE TRIGGER tg_touch_perfil  BEFORE UPDATE ON core.perfil  FOR EACH ROW EXECUTE FUNCTION core.fn_touch();
DROP TRIGGER IF EXISTS tg_touch_grupo   ON core.grupo;
CREATE TRIGGER tg_touch_grupo   BEFORE UPDATE ON core.grupo   FOR EACH ROW EXECUTE FUNCTION core.fn_touch();
DROP TRIGGER IF EXISTS tg_touch_usuario ON core.usuario;
CREATE TRIGGER tg_touch_usuario BEFORE UPDATE ON core.usuario FOR EACH ROW EXECUTE FUNCTION core.fn_touch();

DROP TRIGGER IF EXISTS tg_audit_usuario ON core.usuario;
CREATE TRIGGER tg_audit_usuario AFTER INSERT OR UPDATE OR DELETE ON core.usuario
  FOR EACH ROW EXECUTE FUNCTION core.fn_auditar();
DROP TRIGGER IF EXISTS tg_audit_perfil_permissao ON core.perfil_permissao;
CREATE TRIGGER tg_audit_perfil_permissao AFTER INSERT OR DELETE ON core.perfil_permissao
  FOR EACH ROW EXECUTE FUNCTION core.fn_auditar();
DROP TRIGGER IF EXISTS tg_audit_email_autorizado ON core.email_autorizado;
CREATE TRIGGER tg_audit_email_autorizado AFTER INSERT OR UPDATE OR DELETE ON core.email_autorizado
  FOR EACH ROW EXECUTE FUNCTION core.fn_auditar();


-- =====================================================================================
-- 8. ALMOXARIFADO - FAMILIAS E CAMPOS DINAMICOS
-- =====================================================================================
CREATE TABLE IF NOT EXISTS almox.familia (
  id             text        PRIMARY KEY,
  nome           text        NOT NULL,
  posicao        smallint    NOT NULL DEFAULT 0,
  ativo          boolean     NOT NULL DEFAULT true,
  criado_em      timestamptz NOT NULL DEFAULT now(),
  atualizado_em  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE  almox.familia IS 'Familias de item da SCI (parafuso, porca, arruela, tubos e conexoes, bucha de fixacao, valvulas, vedacao, componente especifico, outros). O id e o mesmo slug do arquivo local.';
COMMENT ON COLUMN almox.familia.ativo IS 'Familia inativa deixa de aparecer no formulario novo, mas continua respondendo pelas SCI antigas - nunca apagar familia com solicitacao vinculada.';

CREATE TABLE IF NOT EXISTS almox.familia_campo (
  id           uuid     PRIMARY KEY DEFAULT gen_random_uuid(),
  familia_id   text     NOT NULL REFERENCES almox.familia(id) ON DELETE CASCADE,
  chave        text     NOT NULL,
  rotulo       text     NOT NULL,
  obrigatorio  boolean  NOT NULL DEFAULT false,
  posicao      smallint NOT NULL DEFAULT 0,
  ativo        boolean  NOT NULL DEFAULT true,
  UNIQUE (familia_id, chave)
);
CREATE INDEX IF NOT EXISTS ix_familia_campo_familia ON almox.familia_campo (familia_id, posicao);
COMMENT ON TABLE  almox.familia_campo IS 'Campos dinamicos de cada familia (parafuso tem material construtivo, revestimento, tipo de rosca...). O formulario da SCI e montado a partir daqui, entao mudar campo e INSERT/UPDATE, nao deploy.';
COMMENT ON COLUMN almox.familia_campo.chave IS 'Identificador estavel do campo dentro da familia (material_construtivo). E o que aparece nas chaves do JSON antigo, por isso a importacao casa por ele.';


-- =====================================================================================
-- 9. ALMOXARIFADO - SCI (SOLICITACAO DE CADASTRO DE ITEM)
-- =====================================================================================
CREATE TABLE IF NOT EXISTS almox.sci (
  id                            uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
  origem_id                     text              UNIQUE,
  codigo                        text              NOT NULL UNIQUE,
  familia_id                    text              NOT NULL REFERENCES almox.familia(id),
  campos_originais              jsonb             NOT NULL DEFAULT '{}'::jsonb,
  link                          text,
  marcas_homologadas            text,
  observacoes                   text,
  foto_anexo_id                 uuid              REFERENCES core.anexo(id) ON DELETE SET NULL,
  solicitante_id                uuid              REFERENCES core.usuario(id) ON DELETE SET NULL,
  solicitante_nome              text              NOT NULL,
  status                        almox.sci_status  NOT NULL DEFAULT 'pendente_aprovacao',
  numero_solicitacao_cadastro   text,
  codigo_item                   text,
  observacao_almoxarife         text,
  aviso_solicitante_em          timestamptz,
  aviso_solicitante_lido        boolean           NOT NULL DEFAULT false,
  criado_em                     timestamptz       NOT NULL DEFAULT now(),
  atualizado_em                 timestamptz       NOT NULL DEFAULT now(),
  -- As duas regras abaixo valem para o que nasce na plataforma nova. Linhas com
  -- origem_id (vindas do localStorage) ficam de fora porque o dado historico as
  -- vezes nao tem o campo: rejeitar na importacao apagaria solicitacao real. O que
  -- falta vira lista de pendencia em mig.ocorrencia e na view app.vw_sci_pendencia_dado.
  CONSTRAINT ck_sci_codigo_item_no_cadastrado
    CHECK (origem_id IS NOT NULL OR status <> 'cadastrado'
           OR nullif(btrim(codigo_item), '') IS NOT NULL),
  CONSTRAINT ck_sci_motivo_na_revisao
    CHECK (origem_id IS NOT NULL OR status <> 'revisao_solicitante'
           OR nullif(btrim(observacao_almoxarife), '') IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS ix_sci_status       ON almox.sci (status, criado_em DESC);
CREATE INDEX IF NOT EXISTS ix_sci_solicitante  ON almox.sci (solicitante_id, criado_em DESC);
CREATE INDEX IF NOT EXISTS ix_sci_familia      ON almox.sci (familia_id);
CREATE INDEX IF NOT EXISTS ix_sci_codigo_item  ON almox.sci (codigo_item) WHERE codigo_item IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_sci_campos_gin   ON almox.sci USING gin (campos_originais jsonb_path_ops);

COMMENT ON TABLE  almox.sci IS 'Solicitacao de Cadastro de Item. Codigo sequencial SCI-0001 gerado pelo banco, familia com campos dinamicos, e o fluxo de status alinhado ao Forms: pendente de aprovacao, aguardando revisao do solicitante, em compra, aguardando o cadastro de item, cadastrado, reprovada.';
COMMENT ON COLUMN almox.sci.numero_solicitacao_cadastro IS 'Numero da solicitacao de cadastro gerado na plataforma 4MDG. NAO e o processo ME: o processo ME pertence ao fluxo de compra e mora em almox.scm.numero_processo_me.';
COMMENT ON COLUMN almox.sci.codigo_item IS 'Codigo do item criado no ERP. Obrigatorio para fechar em Cadastrado - garantido por CHECK, porque fechar sem o codigo tira a razao de existir da solicitacao.';
COMMENT ON COLUMN almox.sci.campos_originais IS 'Retrato do que foi preenchido no momento do envio (chave do campo -> valor). Os valores atuais ficam normalizados em almox.sci_valor_campo; este JSON e o registro imutavel, porque a definicao da familia pode mudar depois e nao pode reescrever o passado.';
COMMENT ON COLUMN almox.sci.solicitante_nome IS 'Nome no momento do envio. Fica denormalizado de proposito: o solicitante pode ser desativado ou renomeado e a solicitacao antiga precisa continuar dizendo quem pediu.';
COMMENT ON COLUMN almox.sci.observacao_almoxarife IS 'Devolutiva do almoxarife. Obrigatoria quando o status vai para revisao do solicitante - devolver sem dizer o que corrigir gera retrabalho garantido.';

CREATE TABLE IF NOT EXISTS almox.sci_valor_campo (
  sci_id    uuid NOT NULL REFERENCES almox.sci(id) ON DELETE CASCADE,
  campo_id  uuid NOT NULL REFERENCES almox.familia_campo(id) ON DELETE CASCADE,
  valor     text,
  PRIMARY KEY (sci_id, campo_id)
);
COMMENT ON TABLE almox.sci_valor_campo IS 'Valores dos campos dinamicos em formato consultavel (uma linha por campo). Existe junto com sci.campos_originais porque relatorio por atributo ("todas as valvulas DN50") em JSON puro fica ilegivel.';

CREATE TABLE IF NOT EXISTS almox.sci_historico (
  id              bigserial         PRIMARY KEY,
  sci_id          uuid              NOT NULL REFERENCES almox.sci(id) ON DELETE CASCADE,
  de              almox.sci_status,
  para            almox.sci_status  NOT NULL,
  por_usuario_id  uuid              REFERENCES core.usuario(id) ON DELETE SET NULL,
  por_nome        text,
  nota            text,
  em              timestamptz       NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_sci_historico_sci ON almox.sci_historico (sci_id, em DESC);
COMMENT ON TABLE almox.sci_historico IS 'Historico de transicoes da SCI (de, para, quem, quando, nota). Gravado por trigger, nao pela aplicacao: assim nenhuma tela consegue mudar status sem deixar rastro.';

DROP TRIGGER IF EXISTS tg_sci_codigo ON almox.sci;
CREATE TRIGGER tg_sci_codigo BEFORE INSERT ON almox.sci
  FOR EACH ROW EXECUTE FUNCTION core.fn_preencher_codigo('sci');

DROP TRIGGER IF EXISTS tg_touch_sci ON almox.sci;
CREATE TRIGGER tg_touch_sci BEFORE UPDATE ON almox.sci
  FOR EACH ROW EXECUTE FUNCTION core.fn_touch();

CREATE OR REPLACE FUNCTION almox.fn_sci_transicao() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_email  citext;
  v_id     uuid;
  v_nome   text;
  v_dest   citext;
BEGIN
  v_email := nullif(current_setting('app.usuario_email', true), '')::citext;
  v_id    := nullif(current_setting('app.usuario_id', true), '')::uuid;
  SELECT u.nome INTO v_nome FROM core.usuario u WHERE u.id = v_id OR u.email = v_email LIMIT 1;

  IF TG_OP = 'INSERT' THEN
    -- Linha vinda da migracao traz o proprio historico no dump: registrar
    -- "solicitacao criada" agora duplicaria a timeline.
    IF NEW.origem_id IS NOT NULL THEN
      RETURN NEW;
    END IF;
    INSERT INTO almox.sci_historico (sci_id, de, para, por_usuario_id, por_nome, nota)
    VALUES (NEW.id, NULL, NEW.status, coalesce(v_id, NEW.solicitante_id),
            coalesce(v_nome, NEW.solicitante_nome), 'solicitacao criada');
    RETURN NEW;
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO almox.sci_historico (sci_id, de, para, por_usuario_id, por_nome, nota)
    VALUES (NEW.id, OLD.status, NEW.status, v_id, v_nome, NEW.observacao_almoxarife);

    -- Aviso ao solicitante APENAS quando entra em revisao do solicitante.
    -- Qualquer outra transicao nao gera e-mail: foi o que ficou acordado.
    IF NEW.status = 'revisao_solicitante' THEN
      SELECT u.email INTO v_dest FROM core.usuario u WHERE u.id = NEW.solicitante_id;
      IF v_dest IS NOT NULL THEN
        INSERT INTO core.email_fila (destinatario, assunto, corpo_html, referencia_tabela, referencia_id, motivo)
        VALUES (
          v_dest,
          NEW.codigo || ' - sua solicitacao de cadastro precisa de revisao',
          '<p>A solicitacao <b>' || NEW.codigo || '</b> foi devolvida para revisao.</p><p><b>O que o almoxarifado pediu:</b><br>' ||
            coalesce(NEW.observacao_almoxarife, '(sem observacao)') || '</p>',
          'almox.sci', NEW.id::text, 'sci_revisao_solicitante');
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION almox.fn_sci_transicao() IS 'Grava o historico de status da SCI e enfileira o e-mail de revisao do solicitante. Concentra as duas coisas que nao podem depender de a tela lembrar de fazer.';

DROP TRIGGER IF EXISTS tg_sci_transicao ON almox.sci;
CREATE TRIGGER tg_sci_transicao AFTER INSERT OR UPDATE ON almox.sci
  FOR EACH ROW EXECUTE FUNCTION almox.fn_sci_transicao();


-- =====================================================================================
-- 10. ALMOXARIFADO - SCM (SOLICITACAO DE COMPRA DE MATERIAIS)
-- =====================================================================================
CREATE TABLE IF NOT EXISTS almox.centro_custo (
  id       smallserial PRIMARY KEY,
  nome     text        NOT NULL UNIQUE,
  ativo    boolean     NOT NULL DEFAULT true,
  posicao  smallint    NOT NULL DEFAULT 0
);
COMMENT ON TABLE almox.centro_custo IS 'Lista de centros de custo da SCM (cerca de 45 valores). E tabela e nao enum porque a lista muda por decisao administrativa, sem mudar regra de negocio - e enum nao se apaga.';

CREATE TABLE IF NOT EXISTS almox.scm (
  id                     uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
  origem_id              text              UNIQUE,
  codigo                 text              NOT NULL UNIQUE,
  time_solicitante       text              NOT NULL,
  tipo_solicitacao       text,
  capex_projeto          text,
  camm                   core.camm         NOT NULL,
  urgencia               almox.urgencia    NOT NULL DEFAULT 'media',
  centro_custo_id        smallint          REFERENCES almox.centro_custo(id),
  numero_om              text,
  tipo_fornecedor        text,
  nome_fornecedor        text,
  tipo_pedido            text,
  descricao_uso          text              NOT NULL,
  solicitante_id         uuid              REFERENCES core.usuario(id) ON DELETE SET NULL,
  solicitante_nome       text              NOT NULL,
  solicitante_email      citext,
  solicitante_time       text,
  aprovador_id           uuid              REFERENCES core.usuario(id) ON DELETE SET NULL,
  aprovador_email        citext,
  aprovador_origem       text,
  status                 almox.scm_status  NOT NULL DEFAULT 'pendente_aprovacao_lider',
  decidido_por_id        uuid              REFERENCES core.usuario(id) ON DELETE SET NULL,
  decidido_em            timestamptz,
  observacao_lider       text,
  observacao_almoxarife  text,
  numero_processo_me     text,
  criado_em              timestamptz       NOT NULL DEFAULT now(),
  atualizado_em          timestamptz       NOT NULL DEFAULT now(),
  CONSTRAINT ck_scm_camm_valida
    CHECK (camm IN ('CAMM 1', 'CAMM 2', 'CAMM 3')),
  -- Mesma logica da SCI: exigido para o que nasce aqui, dispensado para o
  -- historico importado, que nao registrava quem decidiu.
  CONSTRAINT ck_scm_decisao_registrada
    CHECK (origem_id IS NOT NULL
           OR status NOT IN ('aprovada', 'reprovada', 'revisao_solicitada')
           OR (decidido_por_id IS NOT NULL AND decidido_em IS NOT NULL)),
  CONSTRAINT ck_scm_devolutiva_obrigatoria
    CHECK (origem_id IS NOT NULL
           OR status NOT IN ('reprovada', 'revisao_solicitada')
           OR nullif(btrim(observacao_lider), '') IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS ix_scm_status      ON almox.scm (status, criado_em DESC);
CREATE INDEX IF NOT EXISTS ix_scm_aprovador   ON almox.scm (aprovador_email) WHERE status = 'pendente_aprovacao_lider';
CREATE INDEX IF NOT EXISTS ix_scm_solicitante ON almox.scm (solicitante_id, criado_em DESC);
CREATE INDEX IF NOT EXISTS ix_scm_om          ON almox.scm (numero_om) WHERE numero_om IS NOT NULL;

COMMENT ON TABLE  almox.scm IS 'Solicitacao de Compra de Materiais. Codigo SCM-0001 gerado pelo banco. A aprovacao acontece dentro do sistema: quem decidiu, quando e a devolutiva ficam na propria linha, e o passo a passo em almox.scm_historico.';
COMMENT ON COLUMN almox.scm.camm IS 'CAMM 1, 2 ou 3. O tipo core.camm tambem tem C. LOG (usado por utilidades); o CHECK impede que uma SCM nasca com C. LOG.';
COMMENT ON COLUMN almox.scm.aprovador_email IS 'Aprovador congelado no momento do envio, resolvido por app.vw_aprovador_de (responsavel do grupo, ou o e-mail de excecao). Congelar evita que a troca de responsavel amanha faca a solicitacao de hoje desaparecer da fila de quem ja estava analisando.';
COMMENT ON COLUMN almox.scm.aprovador_origem IS 'De onde veio o aprovador: grupo ou excecao. Serve para achar quem ainda esta sem responsavel de grupo definido.';
COMMENT ON COLUMN almox.scm.numero_processo_me IS 'Processo ME do fluxo de compra. Nao confundir com o numero da solicitacao de cadastro da SCI (4MDG).';
COMMENT ON COLUMN almox.scm.observacao_lider IS 'Devolutiva da aprovacao. Obrigatoria em reprovada e revisao solicitada, por CHECK.';

CREATE TABLE IF NOT EXISTS almox.scm_item (
  id                  uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  scm_id              uuid          NOT NULL REFERENCES almox.scm(id) ON DELETE CASCADE,
  posicao             smallint      NOT NULL DEFAULT 1,
  codigo_sistema      text          NOT NULL,
  descricao           text,
  quantidade          numeric(14,3) NOT NULL CHECK (quantidade > 0),
  estoque_minimo      numeric(14,3) CHECK (estoque_minimo IS NULL OR estoque_minimo >= 0),
  marca_modelo_serie  text,
  UNIQUE (scm_id, posicao)
);
CREATE INDEX IF NOT EXISTS ix_scm_item_codigo ON almox.scm_item (codigo_sistema);
COMMENT ON TABLE almox.scm_item IS 'Itens da SCM: codigo do sistema, descricao, quantidade, estoque minimo e marca/modelo/serie. Tabela filha e nao JSON porque o almoxarifado precisa somar e cruzar por codigo de item entre solicitacoes.';

CREATE TABLE IF NOT EXISTS almox.scm_anexo (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scm_id    uuid NOT NULL REFERENCES almox.scm(id) ON DELETE CASCADE,
  anexo_id  uuid NOT NULL REFERENCES core.anexo(id) ON DELETE CASCADE,
  UNIQUE (scm_id, anexo_id)
);
COMMENT ON TABLE almox.scm_anexo IS 'Anexos da SCM (orcamento, foto da peca, ficha tecnica).';

CREATE TABLE IF NOT EXISTS almox.scm_link (
  id       uuid     PRIMARY KEY DEFAULT gen_random_uuid(),
  scm_id   uuid     NOT NULL REFERENCES almox.scm(id) ON DELETE CASCADE,
  url      text     NOT NULL,
  posicao  smallint NOT NULL DEFAULT 1
);
COMMENT ON TABLE almox.scm_link IS 'Links de referencia da SCM (pagina do fornecedor, catalogo). Separados dos anexos porque link nao entra no backup binario.';

CREATE TABLE IF NOT EXISTS almox.scm_historico (
  id              bigserial         PRIMARY KEY,
  scm_id          uuid              NOT NULL REFERENCES almox.scm(id) ON DELETE CASCADE,
  de              almox.scm_status,
  para            almox.scm_status  NOT NULL,
  por_usuario_id  uuid              REFERENCES core.usuario(id) ON DELETE SET NULL,
  por_nome        text,
  nota            text,
  em              timestamptz       NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_scm_historico_scm ON almox.scm_historico (scm_id, em DESC);
COMMENT ON TABLE almox.scm_historico IS 'Log de aprovacao/reprovacao da SCM: de qual status para qual, quem fez e a devolutiva. E a resposta para "quem aprovou essa compra?".';

DROP TRIGGER IF EXISTS tg_scm_codigo ON almox.scm;
CREATE TRIGGER tg_scm_codigo BEFORE INSERT ON almox.scm
  FOR EACH ROW EXECUTE FUNCTION core.fn_preencher_codigo('scm');

DROP TRIGGER IF EXISTS tg_touch_scm ON almox.scm;
CREATE TRIGGER tg_touch_scm BEFORE UPDATE ON almox.scm
  FOR EACH ROW EXECUTE FUNCTION core.fn_touch();

CREATE OR REPLACE FUNCTION almox.fn_scm_transicao() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_email citext;
  v_id    uuid;
  v_nome  text;
BEGIN
  v_email := nullif(current_setting('app.usuario_email', true), '')::citext;
  v_id    := nullif(current_setting('app.usuario_id', true), '')::uuid;
  SELECT u.nome INTO v_nome FROM core.usuario u WHERE u.id = v_id OR u.email = v_email LIMIT 1;

  IF TG_OP = 'INSERT' THEN
    -- Importacao: nao reescreve historico nem, principalmente, dispara e-mail.
    -- Sem esta guarda a virada mandaria um aviso de aprovacao para cada
    -- solicitacao antiga do banco inteiro.
    IF NEW.origem_id IS NOT NULL THEN
      RETURN NEW;
    END IF;

    INSERT INTO almox.scm_historico (scm_id, de, para, por_usuario_id, por_nome, nota)
    VALUES (NEW.id, NULL, NEW.status, coalesce(v_id, NEW.solicitante_id),
            coalesce(v_nome, NEW.solicitante_nome), 'solicitacao criada');

    -- Aviso ao aprovador: o arquivo local ja avisava o lider na criacao,
    -- entao a fila mantem o mesmo comportamento em vez de mudar o combinado.
    IF NEW.aprovador_email IS NOT NULL THEN
      INSERT INTO core.email_fila (destinatario, assunto, corpo_html, referencia_tabela, referencia_id, motivo)
      VALUES (NEW.aprovador_email,
              NEW.codigo || ' - nova solicitacao de compra aguardando sua aprovacao',
              '<p><b>' || NEW.codigo || '</b> enviada por ' || NEW.solicitante_nome ||
              ' (' || NEW.time_solicitante || ', urgencia ' || NEW.urgencia::text || ').</p><p>' ||
              coalesce(NEW.descricao_uso, '') || '</p>',
              'almox.scm', NEW.id::text, 'scm_pendente_aprovacao');
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO almox.scm_historico (scm_id, de, para, por_usuario_id, por_nome, nota)
    VALUES (NEW.id, OLD.status, NEW.status, coalesce(NEW.decidido_por_id, v_id), v_nome,
            coalesce(NEW.observacao_lider, NEW.observacao_almoxarife));
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION almox.fn_scm_transicao() IS 'Grava o log de aprovacao da SCM e enfileira o aviso ao aprovador na criacao.';

DROP TRIGGER IF EXISTS tg_scm_transicao ON almox.scm;
CREATE TRIGGER tg_scm_transicao AFTER INSERT OR UPDATE ON almox.scm
  FOR EACH ROW EXECUTE FUNCTION almox.fn_scm_transicao();

DROP TRIGGER IF EXISTS tg_touch_familia ON almox.familia;
CREATE TRIGGER tg_touch_familia BEFORE UPDATE ON almox.familia
  FOR EACH ROW EXECUTE FUNCTION core.fn_touch();


-- =====================================================================================
-- 11. UTILIDADES - MEDIDORES E LEITURAS
-- =====================================================================================
CREATE TABLE IF NOT EXISTS util.medidor (
  id              uuid                 PRIMARY KEY DEFAULT gen_random_uuid(),
  origem_id       text                 UNIQUE,
  codigo          text                 NOT NULL UNIQUE,
  nome            text                 NOT NULL,
  camm            core.camm            NOT NULL,
  tipo            util.medidor_tipo    NOT NULL,
  unidade         util.unidade_medida  NOT NULL,
  leitura_inicial numeric(14,3)        NOT NULL DEFAULT 0 CHECK (leitura_inicial >= 0),
  ativo           boolean              NOT NULL DEFAULT true,
  observacao      text,
  criado_em       timestamptz          NOT NULL DEFAULT now(),
  atualizado_em   timestamptz          NOT NULL DEFAULT now(),
  -- Par tipo/unidade tirado dos 18 medidores oficiais: agua em m3, gas em Nm3,
  -- energia em kWh, horimetro em h. Se algum dia existir gas medido em m3,
  -- a correcao e uma migration soltando este CHECK - preferivel a aceitar
  -- kWh em hidrometro e descobrir isso no fechamento do mes.
  CONSTRAINT ck_medidor_unidade_do_tipo CHECK (
       (tipo = 'agua'      AND unidade = 'm3')
    OR (tipo = 'gas'       AND unidade = 'Nm3')
    OR (tipo = 'energia'   AND unidade = 'kWh')
    OR (tipo = 'horimetro' AND unidade = 'h')
  )
);
CREATE INDEX IF NOT EXISTS ix_medidor_camm ON util.medidor (camm, tipo) WHERE ativo;
COMMENT ON TABLE  util.medidor IS 'Medidores de utilidades (18 oficiais): agua, gas, energia e horimetro, por unidade industrial (CAMM 1, CAMM 2, CAMM 3, C. LOG).';
COMMENT ON COLUMN util.medidor.codigo IS 'Codigo operacional do medidor no padrao CAMM1-AGUA-02. E o que esta escrito no equipamento, por isso e unico e visivel.';
COMMENT ON COLUMN util.medidor.ativo IS 'Medidor inativo nao aparece para quem aponta, e o historico dele continua no banco. Inativar em vez de apagar e a regra: apagar medidor apagaria a serie de consumo da planta.';
COMMENT ON COLUMN util.medidor.leitura_inicial IS 'Leitura de partida. Serve de leitura anterior do primeiro apontamento, para o primeiro consumo nao sair inflado.';

CREATE TABLE IF NOT EXISTS util.leitura (
  id                uuid           PRIMARY KEY DEFAULT gen_random_uuid(),
  origem_id         text           UNIQUE,
  medidor_id        uuid           NOT NULL REFERENCES util.medidor(id),
  leitura           numeric(14,3)  NOT NULL CHECK (leitura >= 0),
  leitura_anterior  numeric(14,3)  CHECK (leitura_anterior IS NULL OR leitura_anterior >= 0),
  consumo           numeric(14,3)  GENERATED ALWAYS AS (leitura - leitura_anterior) STORED,
  anexo_id          uuid           REFERENCES core.anexo(id) ON DELETE SET NULL,
  observacao        text,
  latitude          numeric(9,6)   CHECK (latitude  IS NULL OR latitude  BETWEEN -90  AND 90),
  longitude         numeric(9,6)   CHECK (longitude IS NULL OR longitude BETWEEN -180 AND 180),
  responsavel_id    uuid           REFERENCES core.usuario(id) ON DELETE SET NULL,
  responsavel_nome  text           NOT NULL,
  medido_em         timestamptz    NOT NULL DEFAULT now(),
  criado_em         timestamptz    NOT NULL DEFAULT now(),
  CONSTRAINT ck_leitura_acumulativa CHECK (leitura_anterior IS NULL OR leitura >= leitura_anterior),
  UNIQUE (medidor_id, medido_em)
);
CREATE INDEX IF NOT EXISTS ix_leitura_medidor ON util.leitura (medidor_id, medido_em DESC);
CREATE INDEX IF NOT EXISTS ix_leitura_data    ON util.leitura (medido_em DESC);
CREATE INDEX IF NOT EXISTS ix_leitura_sem_foto ON util.leitura (medidor_id) WHERE anexo_id IS NULL;

COMMENT ON TABLE  util.leitura IS 'Apontamentos de consumo. Uma linha por leitura, com foto de evidencia, observacao, GPS opcional, responsavel e data/hora.';
COMMENT ON COLUMN util.leitura.leitura_anterior IS 'Preenchido pelo banco (trigger), nunca pelo formulario: e a ultima leitura do mesmo medidor ate a data informada, ou a leitura inicial do medidor quando e o primeiro apontamento.';
COMMENT ON COLUMN util.leitura.consumo IS 'Coluna GERADA: leitura menos leitura anterior. Consumo nunca e digitado - digitar consumo esconde erro de leitura. Fica NULL no primeiro apontamento, quando nao existe base de comparacao.';
COMMENT ON COLUMN util.leitura.anexo_id IS 'Foto do marcador. Obrigatoria em horimetro (validado por trigger, porque a regra depende do tipo do medidor e CHECK nao le outra tabela).';
COMMENT ON CONSTRAINT ck_leitura_acumulativa ON util.leitura IS 'Medidor e acumulativo: leitura menor que a anterior e recusada pelo banco, nao apenas pela tela.';

CREATE OR REPLACE FUNCTION util.fn_leitura_preparar() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  m         util.medidor;
  v_ant     numeric(14,3);
BEGIN
  SELECT * INTO m FROM util.medidor WHERE id = NEW.medidor_id;
  IF m.id IS NULL THEN
    RAISE EXCEPTION 'Medidor inexistente';
  END IF;
  IF NOT m.ativo AND TG_OP = 'INSERT' THEN
    RAISE EXCEPTION 'Medidor % (%) esta inativo e nao aceita apontamento', m.codigo, m.nome;
  END IF;

  -- A leitura anterior e sempre a do banco, considerando a data informada
  -- (o apontamento pode ser lancado com atraso).
  SELECT l.leitura INTO v_ant
    FROM util.leitura l
   WHERE l.medidor_id = NEW.medidor_id
     AND l.medido_em <= NEW.medido_em
     AND l.id <> NEW.id
   ORDER BY l.medido_em DESC, l.criado_em DESC
   LIMIT 1;

  NEW.leitura_anterior := coalesce(v_ant, m.leitura_inicial);

  IF NEW.leitura < NEW.leitura_anterior THEN
    IF NEW.origem_id IS NOT NULL THEN
      -- Leitura historica: recusar apagaria um apontamento que existiu de fato
      -- (tipicamente troca fisica do medidor). Entra sem base de comparacao,
      -- portanto sem consumo, e o PCM ve o caso em app.vw_util_desvio.
      INSERT INTO mig.ocorrencia (etapa, severidade, registro, mensagem, dado)
      VALUES ('importar_leituras', 'aviso', NEW.origem_id,
              format('leitura %s menor que a anterior %s no medidor %s: importada sem consumo',
                     NEW.leitura, NEW.leitura_anterior, m.codigo),
              jsonb_build_object('medidor', m.codigo, 'leitura', NEW.leitura,
                                 'anterior', NEW.leitura_anterior, 'medido_em', NEW.medido_em));
      NEW.leitura_anterior := NULL;
    ELSE
      RAISE EXCEPTION
        'Leitura % menor que a anterior (%) no medidor %. O medidor e acumulativo: confira o numero ou avise o PCM se o equipamento foi trocado.',
        NEW.leitura, NEW.leitura_anterior, m.codigo;
    END IF;
  END IF;

  -- A exigencia de foto vale para o apontamento novo. Leitura historica sem foto
  -- entra e fica marcada como desvio "horimetro sem foto".
  IF m.tipo = 'horimetro' AND NEW.anexo_id IS NULL AND NEW.origem_id IS NULL THEN
    RAISE EXCEPTION 'Horimetro % exige foto do marcador', m.codigo;
  END IF;

  RETURN NEW;
END $$;
COMMENT ON FUNCTION util.fn_leitura_preparar() IS 'Aplica no banco as tres regras do apontamento: leitura anterior vem do historico (nao do formulario), leitura menor que a anterior e recusada, e horimetro exige foto.';

DROP TRIGGER IF EXISTS tg_leitura_preparar ON util.leitura;
CREATE TRIGGER tg_leitura_preparar BEFORE INSERT OR UPDATE OF leitura, medido_em, medidor_id, anexo_id
  ON util.leitura FOR EACH ROW EXECUTE FUNCTION util.fn_leitura_preparar();

DROP TRIGGER IF EXISTS tg_touch_medidor ON util.medidor;
CREATE TRIGGER tg_touch_medidor BEFORE UPDATE ON util.medidor
  FOR EACH ROW EXECUTE FUNCTION core.fn_touch();

DROP TRIGGER IF EXISTS tg_audit_leitura ON util.leitura;
CREATE TRIGGER tg_audit_leitura AFTER UPDATE OR DELETE ON util.leitura
  FOR EACH ROW EXECUTE FUNCTION core.fn_auditar();

CREATE TABLE IF NOT EXISTS util.desvio_tratativa (
  leitura_id     uuid             NOT NULL REFERENCES util.leitura(id) ON DELETE CASCADE,
  tipo           util.desvio_tipo NOT NULL,
  situacao       text             NOT NULL DEFAULT 'aberto'
                                  CHECK (situacao IN ('aberto', 'justificado', 'corrigido', 'ignorado')),
  nota           text,
  analisado_por  uuid             REFERENCES core.usuario(id) ON DELETE SET NULL,
  analisado_em   timestamptz,
  criado_em      timestamptz      NOT NULL DEFAULT now(),
  PRIMARY KEY (leitura_id, tipo),
  CONSTRAINT ck_tratativa_analise CHECK (situacao = 'aberto' OR (analisado_por IS NOT NULL AND analisado_em IS NOT NULL))
);
COMMENT ON TABLE util.desvio_tratativa IS 'O que o PCM concluiu sobre cada desvio apontado. O desvio em si NAO e tabela: e calculado pela view app.vw_util_desvio, porque um dos criterios ("leitura seguinte menor") depende de um apontamento que ainda nao existe quando o primeiro e gravado - persistir isso nasceria desatualizado.';


-- =====================================================================================
-- 12. PCM - ETAPA POSTERIOR (tabelas previstas)
--   Entram agora, vazias, para o modelo de dados nao precisar ser redesenhado quando
--   o modulo comecar: as OS ja apontam para ativo e para plano, e o estoque ja e
--   movimento com saldo por view, e nao um campo saldo que desanda com concorrencia.
-- =====================================================================================
CREATE TABLE IF NOT EXISTS pcm.ativo (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo         text        NOT NULL UNIQUE,
  nome           text        NOT NULL,
  camm           core.camm,
  local          text,
  pai_id         uuid        REFERENCES pcm.ativo(id) ON DELETE SET NULL,
  criticidade    text        CHECK (criticidade IS NULL OR criticidade IN ('alta', 'media', 'baixa')),
  ativo          boolean     NOT NULL DEFAULT true,
  criado_em      timestamptz NOT NULL DEFAULT now(),
  atualizado_em  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE  pcm.ativo IS 'Ativos e equipamentos, com hierarquia (pai_id) para linha -> maquina -> conjunto.';
COMMENT ON COLUMN pcm.ativo.pai_id IS 'Ativo pai. Auto-referencia permite a arvore da planta sem tabela extra.';

CREATE TABLE IF NOT EXISTS pcm.plano_preventivo (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo            text        NOT NULL UNIQUE,
  nome              text        NOT NULL,
  periodicidade_dias integer    CHECK (periodicidade_dias IS NULL OR periodicidade_dias > 0),
  periodicidade_horas integer   CHECK (periodicidade_horas IS NULL OR periodicidade_horas > 0),
  medidor_id        uuid        REFERENCES util.medidor(id) ON DELETE SET NULL,
  instrucoes        text,
  ativo             boolean     NOT NULL DEFAULT true,
  criado_em         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_plano_tem_periodicidade
    CHECK (periodicidade_dias IS NOT NULL OR periodicidade_horas IS NOT NULL)
);
COMMENT ON TABLE  pcm.plano_preventivo IS 'Planos preventivos por tempo (dias) ou por uso (horas). Quando a periodicidade e por horas, medidor_id aponta o horimetro que conta o uso - e a ligacao entre utilidades e PCM.';

CREATE TABLE IF NOT EXISTS pcm.plano_ativo (
  plano_id  uuid NOT NULL REFERENCES pcm.plano_preventivo(id) ON DELETE CASCADE,
  ativo_id  uuid NOT NULL REFERENCES pcm.ativo(id) ON DELETE CASCADE,
  PRIMARY KEY (plano_id, ativo_id)
);
COMMENT ON TABLE pcm.plano_ativo IS 'Quais ativos cada plano preventivo cobre.';

CREATE TABLE IF NOT EXISTS pcm.ordem_servico (
  id               uuid           PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo           text           NOT NULL UNIQUE,
  tipo             pcm.os_tipo    NOT NULL,
  status           pcm.os_status  NOT NULL DEFAULT 'aberta',
  ativo_id         uuid           REFERENCES pcm.ativo(id) ON DELETE SET NULL,
  plano_id         uuid           REFERENCES pcm.plano_preventivo(id) ON DELETE SET NULL,
  grupo_id         uuid           REFERENCES core.grupo(id) ON DELETE SET NULL,
  responsavel_id   uuid           REFERENCES core.usuario(id) ON DELETE SET NULL,
  solicitante_id   uuid           REFERENCES core.usuario(id) ON DELETE SET NULL,
  descricao        text           NOT NULL,
  prioridade       almox.urgencia NOT NULL DEFAULT 'media',
  aberta_em        timestamptz    NOT NULL DEFAULT now(),
  prevista_para    timestamptz,
  concluida_em     timestamptz,
  horas_gastas     numeric(8,2)   CHECK (horas_gastas IS NULL OR horas_gastas >= 0),
  relato_execucao  text,
  atualizado_em    timestamptz    NOT NULL DEFAULT now(),
  CONSTRAINT ck_os_conclusao CHECK (status <> 'concluida' OR concluida_em IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS ix_os_status ON pcm.ordem_servico (status, aberta_em DESC);
CREATE INDEX IF NOT EXISTS ix_os_ativo  ON pcm.ordem_servico (ativo_id);
COMMENT ON TABLE  pcm.ordem_servico IS 'Ordens de servico. O numero da OM que a SCM referencia (almox.scm.numero_om) vai casar com o codigo daqui quando o modulo entrar - por isso o codigo e texto e unico.';
COMMENT ON COLUMN pcm.ordem_servico.grupo_id IS 'Grupo responsavel pela execucao (Mecanica, Eletrica/Automacao...). Aproveita o mesmo cadastro de grupos do acesso, sem criar uma segunda lista de equipes.';

CREATE TABLE IF NOT EXISTS pcm.item_estoque (
  id              uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo_item     text          NOT NULL UNIQUE,
  descricao       text          NOT NULL,
  unidade         text          NOT NULL DEFAULT 'UN',
  estoque_minimo  numeric(14,3) NOT NULL DEFAULT 0 CHECK (estoque_minimo >= 0),
  familia_id      text          REFERENCES almox.familia(id) ON DELETE SET NULL,
  sci_id          uuid          REFERENCES almox.sci(id) ON DELETE SET NULL,
  ativo           boolean       NOT NULL DEFAULT true,
  criado_em       timestamptz   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  pcm.item_estoque IS 'Cadastro de item de estoque. sci_id fecha o ciclo: o item nasceu de uma SCI e da para ir do saldo ate quem pediu o cadastro.';

CREATE TABLE IF NOT EXISTS pcm.movimento_estoque (
  id             uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  item_id        uuid          NOT NULL REFERENCES pcm.item_estoque(id),
  quantidade     numeric(14,3) NOT NULL CHECK (quantidade <> 0),
  motivo         text          NOT NULL,
  ordem_id       uuid          REFERENCES pcm.ordem_servico(id) ON DELETE SET NULL,
  scm_id         uuid          REFERENCES almox.scm(id) ON DELETE SET NULL,
  responsavel_id uuid          REFERENCES core.usuario(id) ON DELETE SET NULL,
  em             timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_movimento_item ON pcm.movimento_estoque (item_id, em DESC);
COMMENT ON TABLE  pcm.movimento_estoque IS 'Entradas (positivo) e saidas (negativo) de estoque. O saldo e a soma dos movimentos (view app.vw_estoque_saldo), e nao uma coluna: coluna de saldo divergindo do movimento e o defeito classico desse modulo.';


-- =====================================================================================
-- 13. TREINAMENTOS (LMS)
--   Conteudo e versionado; matricula e sempre por pessoa, mas pode NASCER de uma
--   atribuicao a um grupo. Assim entrada e saida de gente no grupo reflete nas
--   matriculas por reconciliacao (lms.sincronizar_matriculas), e nao por alguem
--   lembrar de matricular na mao.
-- =====================================================================================
CREATE TABLE IF NOT EXISTS lms.treinamento (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  origem_id       text        UNIQUE,
  codigo          text        NOT NULL UNIQUE,
  titulo          text        NOT NULL,
  categoria       text,
  descricao       text,
  obrigatorio     boolean     NOT NULL DEFAULT false,
  validade_meses  smallint    CHECK (validade_meses IS NULL OR validade_meses > 0),
  prazo_dias      smallint    NOT NULL DEFAULT 30 CHECK (prazo_dias > 0),
  ativo           boolean     NOT NULL DEFAULT true,
  criado_em       timestamptz NOT NULL DEFAULT now(),
  atualizado_em   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE  lms.treinamento IS 'Catalogo de treinamentos: codigo, titulo, categoria, se e obrigatorio, validade e prazo.';
COMMENT ON COLUMN lms.treinamento.validade_meses IS 'Meses de validade do comprovante. NULL = sem vencimento. O dado antigo grava 0 para "sem validade" e a importacao converte 0 em NULL, para nao existirem duas formas de dizer a mesma coisa.';
COMMENT ON COLUMN lms.treinamento.prazo_dias IS 'Prazo, em dias, contado da matricula. Usado para calcular a data limite de cada matricula.';

CREATE TABLE IF NOT EXISTS lms.versao (
  id                  uuid               PRIMARY KEY DEFAULT gen_random_uuid(),
  origem_id           text               UNIQUE,
  treinamento_id      uuid               NOT NULL REFERENCES lms.treinamento(id) ON DELETE CASCADE,
  numero              smallint           NOT NULL CHECK (numero > 0),
  status              lms.versao_status  NOT NULL DEFAULT 'rascunho',
  minutos_minimos     smallint           NOT NULL DEFAULT 0 CHECK (minutos_minimos >= 0),
  nota_corte          smallint           NOT NULL DEFAULT 70 CHECK (nota_corte BETWEEN 0 AND 100),
  tentativas_maximas  smallint           NOT NULL DEFAULT 3 CHECK (tentativas_maximas > 0),
  publicado_em        timestamptz,
  criado_em           timestamptz        NOT NULL DEFAULT now(),
  UNIQUE (treinamento_id, numero)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_versao_publicada
  ON lms.versao (treinamento_id) WHERE status = 'publicada';
COMMENT ON TABLE  lms.versao IS 'Versao do treinamento: minutos minimos, nota de corte e tentativas maximas. Conteudo e avaliacao pendurados na versao, nao no treinamento - assim mudar o conteudo nao reescreve o que quem ja fez estudou.';
COMMENT ON INDEX lms.ux_versao_publicada IS 'So uma versao publicada por treinamento. Publicar a proxima exige arquivar a atual, e "qual e a versao vigente" deixa de ser uma pergunta com resposta calculada.';

CREATE TABLE IF NOT EXISTS lms.aula (
  id                uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  origem_id         text          UNIQUE,
  versao_id         uuid          NOT NULL REFERENCES lms.versao(id) ON DELETE CASCADE,
  posicao           smallint      NOT NULL CHECK (posicao > 0),
  titulo            text          NOT NULL,
  tipo              lms.aula_tipo NOT NULL,
  obrigatoria       boolean       NOT NULL DEFAULT true,
  segundos_minimos  integer       NOT NULL DEFAULT 0 CHECK (segundos_minimos >= 0),
  corpo             text,
  url               text,
  anexo_id          uuid          REFERENCES core.anexo(id) ON DELETE SET NULL,
  UNIQUE (versao_id, posicao),
  CONSTRAINT ck_aula_conteudo CHECK (
       (tipo = 'texto'         AND nullif(btrim(corpo), '') IS NOT NULL)
    OR (tipo IN ('video_youtube', 'link') AND nullif(btrim(url), '') IS NOT NULL)
    OR (tipo IN ('video_arquivo', 'pdf', 'imagem') AND (anexo_id IS NOT NULL OR nullif(btrim(url), '') IS NOT NULL))
  )
);
COMMENT ON TABLE  lms.aula IS 'Aulas da versao, em ordem: texto, video do YouTube, video em arquivo, PDF, imagem ou link. O CHECK garante que cada tipo tem o conteudo que lhe corresponde - aula de video sem endereco e aula quebrada em producao.';
COMMENT ON COLUMN lms.aula.segundos_minimos IS 'Tempo minimo de visualizacao. E o que lms.registrar_progresso() compara para concluir a aula.';

CREATE TABLE IF NOT EXISTS lms.avaliacao (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  origem_id  text UNIQUE,
  versao_id  uuid NOT NULL UNIQUE REFERENCES lms.versao(id) ON DELETE CASCADE,
  titulo     text NOT NULL
);
COMMENT ON TABLE lms.avaliacao IS 'Avaliacao da versao (no maximo uma, por isso versao_id e UNIQUE).';

CREATE TABLE IF NOT EXISTS lms.questao (
  id            uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
  origem_id     text              UNIQUE,
  avaliacao_id  uuid              NOT NULL REFERENCES lms.avaliacao(id) ON DELETE CASCADE,
  posicao       smallint          NOT NULL CHECK (posicao > 0),
  tipo          lms.questao_tipo  NOT NULL DEFAULT 'unica',
  peso          numeric(5,2)      NOT NULL DEFAULT 1 CHECK (peso > 0),
  enunciado     text              NOT NULL,
  UNIQUE (avaliacao_id, posicao)
);
COMMENT ON TABLE lms.questao IS 'Questoes da avaliacao, de resposta unica ou multipla, com peso.';

CREATE TABLE IF NOT EXISTS lms.questao_opcao (
  id          uuid     PRIMARY KEY DEFAULT gen_random_uuid(),
  origem_id   text     UNIQUE,
  questao_id  uuid     NOT NULL REFERENCES lms.questao(id) ON DELETE CASCADE,
  posicao     smallint NOT NULL CHECK (posicao > 0),
  texto       text     NOT NULL,
  correta     boolean  NOT NULL DEFAULT false,
  UNIQUE (questao_id, posicao)
);
COMMENT ON TABLE  lms.questao_opcao IS 'Alternativas da questao. A coluna correta e o gabarito: a role da aplicacao NAO recebe SELECT nessa coluna (ver secao de GRANTs), entao o gabarito nao chega ao navegador nem por engano. A correcao acontece dentro de lms.corrigir_tentativa().';
COMMENT ON COLUMN lms.questao_opcao.correta IS 'Gabarito. Leitura restrita por privilegio de coluna; so a funcao de correcao (SECURITY DEFINER) enxerga.';

-- 13.1 atribuicao e matricula --------------------------------------------------------
CREATE TABLE IF NOT EXISTS lms.atribuicao (
  id              uuid           PRIMARY KEY DEFAULT gen_random_uuid(),
  treinamento_id  uuid           NOT NULL REFERENCES lms.treinamento(id) ON DELETE CASCADE,
  alvo            lms.alvo_tipo  NOT NULL,
  usuario_id      uuid           REFERENCES core.usuario(id) ON DELETE CASCADE,
  grupo_id        uuid           REFERENCES core.grupo(id) ON DELETE CASCADE,
  obrigatoria     boolean        NOT NULL DEFAULT true,
  prazo_dias      smallint       CHECK (prazo_dias IS NULL OR prazo_dias > 0),
  ativa           boolean        NOT NULL DEFAULT true,
  criado_por      uuid           REFERENCES core.usuario(id) ON DELETE SET NULL,
  criado_em       timestamptz    NOT NULL DEFAULT now(),
  CONSTRAINT ck_atribuicao_alvo CHECK (
       (alvo = 'usuario' AND usuario_id IS NOT NULL AND grupo_id IS NULL)
    OR (alvo = 'grupo'   AND grupo_id   IS NOT NULL AND usuario_id IS NULL)
  )
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_atribuicao_usuario
  ON lms.atribuicao (treinamento_id, usuario_id) WHERE alvo = 'usuario';
CREATE UNIQUE INDEX IF NOT EXISTS ux_atribuicao_grupo
  ON lms.atribuicao (treinamento_id, grupo_id) WHERE alvo = 'grupo';
COMMENT ON TABLE  lms.atribuicao IS 'Quem deve fazer o treinamento: uma pessoa ou um GRUPO inteiro. Atribuir ao grupo e o pedido do cliente - entrada e saida de gente no grupo passa a atualizar as matriculas sozinha.';
COMMENT ON COLUMN lms.atribuicao.prazo_dias IS 'Prazo especifico desta atribuicao. NULL usa o prazo do treinamento.';

CREATE TABLE IF NOT EXISTS lms.matricula (
  id                    uuid                  PRIMARY KEY DEFAULT gen_random_uuid(),
  origem_id             text                  UNIQUE,
  atribuicao_id         uuid                  REFERENCES lms.atribuicao(id) ON DELETE SET NULL,
  treinamento_id        uuid                  NOT NULL REFERENCES lms.treinamento(id) ON DELETE CASCADE,
  versao_id             uuid                  NOT NULL REFERENCES lms.versao(id) ON DELETE CASCADE,
  usuario_id            uuid                  NOT NULL REFERENCES core.usuario(id) ON DELETE CASCADE,
  obrigatoria           boolean               NOT NULL DEFAULT false,
  status                lms.matricula_status  NOT NULL DEFAULT 'nao_iniciada',
  prazo_em              timestamptz,
  iniciado_em           timestamptz,
  concluido_em          timestamptz,
  bloqueada             boolean               NOT NULL DEFAULT false,
  bloqueada_em          timestamptz,
  tentativas_liberadas  smallint              NOT NULL DEFAULT 0 CHECK (tentativas_liberadas >= 0),
  criado_em             timestamptz           NOT NULL DEFAULT now(),
  atualizado_em         timestamptz           NOT NULL DEFAULT now(),
  UNIQUE (usuario_id, versao_id)
);
CREATE INDEX IF NOT EXISTS ix_matricula_usuario ON lms.matricula (usuario_id, status);
CREATE INDEX IF NOT EXISTS ix_matricula_prazo   ON lms.matricula (prazo_em) WHERE status IN ('nao_iniciada', 'em_andamento', 'aguardando_avaliacao');
COMMENT ON TABLE  lms.matricula IS 'Matricula de UMA pessoa em UMA versao de treinamento. Mesmo quando a atribuicao e ao grupo, a matricula e individual - progresso e comprovante sao da pessoa.';
COMMENT ON COLUMN lms.matricula.atribuicao_id IS 'Atribuicao que gerou a matricula. Preenchido = automatica (pode ser cancelada quando a pessoa sai do grupo). NULL = matricula manual, que a reconciliacao nao mexe.';
COMMENT ON COLUMN lms.matricula.bloqueada IS 'Bloqueio por esgotar as tentativas. Fica bloqueada ate o administrador liberar em lms.liberar_matricula().';
COMMENT ON COLUMN lms.matricula.tentativas_liberadas IS 'Tentativas extras concedidas pelo administrador. O limite efetivo e tentativas_maximas da versao mais este numero.';

CREATE TABLE IF NOT EXISTS lms.progresso_aula (
  id                  uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  matricula_id        uuid        NOT NULL REFERENCES lms.matricula(id) ON DELETE CASCADE,
  aula_id             uuid        NOT NULL REFERENCES lms.aula(id) ON DELETE CASCADE,
  segundos_assistidos integer     NOT NULL DEFAULT 0 CHECK (segundos_assistidos >= 0),
  confirmou_leitura   boolean     NOT NULL DEFAULT false,
  concluido_em        timestamptz,
  atualizado_em       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (matricula_id, aula_id)
);
COMMENT ON TABLE  lms.progresso_aula IS 'Progresso por aula: segundos assistidos, confirmacao de leitura e conclusao.';
COMMENT ON COLUMN lms.progresso_aula.segundos_assistidos IS 'Monotonico e com teto de 120 s por gravacao, aplicado em lms.registrar_progresso(). O teto existe para a tela nao pular para o fim mandando o total de uma vez.';

CREATE TABLE IF NOT EXISTS lms.tentativa (
  id             uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  matricula_id   uuid         NOT NULL REFERENCES lms.matricula(id) ON DELETE CASCADE,
  avaliacao_id   uuid         NOT NULL REFERENCES lms.avaliacao(id) ON DELETE CASCADE,
  numero         smallint     NOT NULL CHECK (numero > 0),
  nota           numeric(5,2) NOT NULL CHECK (nota BETWEEN 0 AND 100),
  aprovado       boolean      NOT NULL,
  finalizado_em  timestamptz  NOT NULL DEFAULT now(),
  UNIQUE (matricula_id, numero)
);
COMMENT ON TABLE lms.tentativa IS 'Tentativas de avaliacao: numero, nota e se foi aprovado. Uma linha por envio - nao se sobrescreve tentativa.';

CREATE TABLE IF NOT EXISTS lms.tentativa_resposta (
  tentativa_id  uuid    NOT NULL REFERENCES lms.tentativa(id) ON DELETE CASCADE,
  questao_id    uuid    NOT NULL REFERENCES lms.questao(id) ON DELETE CASCADE,
  opcoes        uuid[]  NOT NULL DEFAULT '{}',
  correta       boolean NOT NULL,
  PRIMARY KEY (tentativa_id, questao_id)
);
COMMENT ON TABLE lms.tentativa_resposta IS 'O que a pessoa marcou em cada questao e se acertou. Guardado para poder revisar a prova depois sem recalcular nada.';

CREATE TABLE IF NOT EXISTS lms.liberacao (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  matricula_id      uuid        NOT NULL REFERENCES lms.matricula(id) ON DELETE CASCADE,
  tentativas_extra  smallint    NOT NULL DEFAULT 1 CHECK (tentativas_extra > 0),
  motivo            text        NOT NULL,
  liberado_por      uuid        REFERENCES core.usuario(id) ON DELETE SET NULL,
  em                timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE lms.liberacao IS 'Registro de cada liberacao dada pelo administrador a uma matricula bloqueada, com motivo. Liberar sem justificar transforma o limite de tentativas em enfeite.';

CREATE TABLE IF NOT EXISTS lms.conclusao (
  id                  uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  origem_id           text          UNIQUE,
  matricula_id        uuid          NOT NULL UNIQUE REFERENCES lms.matricula(id) ON DELETE CASCADE,
  codigo_comprovante  text          NOT NULL UNIQUE,
  concluido_em        timestamptz   NOT NULL DEFAULT now(),
  aproveitamento      numeric(5,2)  NOT NULL CHECK (aproveitamento BETWEEN 0 AND 100),
  valido_ate          timestamptz,
  evidencia           text          NOT NULL DEFAULT 'automatica'
                                    CHECK (evidencia IN ('automatica', 'manual')),
  motivo_manual       text,
  registrado_por      uuid          REFERENCES core.usuario(id) ON DELETE SET NULL,
  CONSTRAINT ck_conclusao_manual CHECK (evidencia <> 'manual' OR nullif(btrim(motivo_manual), '') IS NOT NULL)
);
COMMENT ON TABLE  lms.conclusao IS 'Comprovante: codigo unico, data, aproveitamento e validade. Uma por matricula.';
COMMENT ON COLUMN lms.conclusao.evidencia IS 'automatica = aprovado na avaliacao pelo sistema; manual = lancado por administrador (exige motivo). Distinguir as duas coisas e o que sustenta auditoria de treinamento obrigatorio.';
COMMENT ON COLUMN lms.conclusao.valido_ate IS 'Vencimento calculado da validade do treinamento. NULL quando o treinamento nao vence.';

DROP TRIGGER IF EXISTS tg_touch_treinamento ON lms.treinamento;
CREATE TRIGGER tg_touch_treinamento BEFORE UPDATE ON lms.treinamento
  FOR EACH ROW EXECUTE FUNCTION core.fn_touch();
DROP TRIGGER IF EXISTS tg_touch_matricula ON lms.matricula;
CREATE TRIGGER tg_touch_matricula BEFORE UPDATE ON lms.matricula
  FOR EACH ROW EXECUTE FUNCTION core.fn_touch();
DROP TRIGGER IF EXISTS tg_audit_matricula ON lms.matricula;
CREATE TRIGGER tg_audit_matricula AFTER INSERT OR UPDATE OR DELETE ON lms.matricula
  FOR EACH ROW EXECUTE FUNCTION core.fn_auditar();


-- 13.2 reconciliacao de matriculas ---------------------------------------------------
CREATE OR REPLACE FUNCTION lms.sincronizar_matriculas() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  v_criadas    integer := 0;
  v_canceladas integer := 0;
BEGIN
  -- 1) toda pessoa que o alvo alcanca tem matricula na versao publicada
  WITH alvo AS (
    SELECT a.id AS atribuicao_id, a.obrigatoria, a.prazo_dias, t.id AS treinamento_id,
           t.prazo_dias AS prazo_treinamento, v.id AS versao_id, u.id AS usuario_id
      FROM lms.atribuicao a
      JOIN lms.treinamento t ON t.id = a.treinamento_id AND t.ativo
      JOIN lms.versao      v ON v.treinamento_id = t.id AND v.status = 'publicada'
      JOIN core.usuario    u ON u.ativo
                            AND NOT u.bloqueado
                            AND ( (a.alvo = 'usuario' AND u.id = a.usuario_id)
                               OR (a.alvo = 'grupo'   AND u.grupo_id = a.grupo_id) )
     WHERE a.ativa
  ), ins AS (
    INSERT INTO lms.matricula (atribuicao_id, treinamento_id, versao_id, usuario_id,
                               obrigatoria, status, prazo_em)
    SELECT atribuicao_id, treinamento_id, versao_id, usuario_id, obrigatoria, 'nao_iniciada',
           now() + make_interval(days => coalesce(prazo_dias, prazo_treinamento)::int)
      FROM alvo
    ON CONFLICT (usuario_id, versao_id) DO UPDATE
      SET atribuicao_id = EXCLUDED.atribuicao_id,
          obrigatoria   = EXCLUDED.obrigatoria,
          -- reentrada no grupo reabre a matricula que havia sido cancelada,
          -- sem apagar o progresso que a pessoa ja tinha
          status        = CASE WHEN matricula.status = 'cancelada'
                               THEN 'nao_iniciada'::lms.matricula_status
                               ELSE matricula.status END
      WHERE matricula.status = 'cancelada'
         OR matricula.atribuicao_id IS DISTINCT FROM EXCLUDED.atribuicao_id
    RETURNING 1
  )
  SELECT count(*) INTO v_criadas FROM ins;

  -- 2) quem saiu do grupo (ou perdeu a atribuicao) deixa de ter pendencia,
  --    mas conclusao existente nunca e mexida
  WITH upd AS (
    UPDATE lms.matricula m
       SET status = 'cancelada'
     WHERE m.atribuicao_id IS NOT NULL
       AND m.status NOT IN ('concluida', 'cancelada')
       AND NOT EXISTS (
             SELECT 1
               FROM lms.atribuicao a
               JOIN core.usuario u ON u.id = m.usuario_id
              WHERE a.id = m.atribuicao_id
                AND a.ativa
                AND u.ativo
                AND ( (a.alvo = 'usuario' AND u.id = a.usuario_id)
                   OR (a.alvo = 'grupo'   AND u.grupo_id = a.grupo_id) ) )
    RETURNING 1
  )
  SELECT count(*) INTO v_canceladas FROM upd;

  INSERT INTO core.rotina_execucao (rotina, fim, sucesso, detalhe)
  VALUES ('lms.sincronizar_matriculas', now(), true,
          format('criadas/reabertas: %s, canceladas: %s', v_criadas, v_canceladas));

  RETURN jsonb_build_object('criadas', v_criadas, 'canceladas', v_canceladas);
END $$;
COMMENT ON FUNCTION lms.sincronizar_matriculas() IS 'Reconcilia matriculas com as atribuicoes: cria as que faltam, reabre as canceladas de quem voltou ao grupo e cancela as de quem saiu (sem tocar em conclusao). Chamada por trigger quando o grupo de alguem muda e tambem pela rotina noturna.';

CREATE OR REPLACE FUNCTION lms.fn_sincronizar_matriculas_trigger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM lms.sincronizar_matriculas();
  RETURN NULL;
END $$;
COMMENT ON FUNCTION lms.fn_sincronizar_matriculas_trigger() IS 'Adaptador de trigger para lms.sincronizar_matriculas(). Roda por STATEMENT, nao por linha: importar 80 usuarios de uma vez chama a reconciliacao uma unica vez.';

DROP TRIGGER IF EXISTS tg_usuario_sincroniza_lms ON core.usuario;
CREATE TRIGGER tg_usuario_sincroniza_lms
  AFTER INSERT OR DELETE OR UPDATE OF grupo_id, ativo, bloqueado ON core.usuario
  FOR EACH STATEMENT EXECUTE FUNCTION lms.fn_sincronizar_matriculas_trigger();

DROP TRIGGER IF EXISTS tg_atribuicao_sincroniza_lms ON lms.atribuicao;
CREATE TRIGGER tg_atribuicao_sincroniza_lms
  AFTER INSERT OR DELETE OR UPDATE OF ativa, grupo_id, usuario_id ON lms.atribuicao
  FOR EACH STATEMENT EXECUTE FUNCTION lms.fn_sincronizar_matriculas_trigger();


-- 13.3 progresso ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lms.registrar_progresso(
  p_matricula uuid,
  p_aula      uuid,
  p_segundos  integer,
  p_confirmou boolean DEFAULT false
) RETURNS lms.progresso_aula
LANGUAGE plpgsql AS $$
DECLARE
  m   lms.matricula;
  a   lms.aula;
  p   lms.progresso_aula;
BEGIN
  SELECT * INTO m FROM lms.matricula WHERE id = p_matricula;
  IF m.id IS NULL THEN RAISE EXCEPTION 'Matricula inexistente'; END IF;
  IF m.status = 'cancelada' THEN RAISE EXCEPTION 'Matricula cancelada'; END IF;

  SELECT * INTO a FROM lms.aula WHERE id = p_aula AND versao_id = m.versao_id;
  IF a.id IS NULL THEN RAISE EXCEPTION 'A aula nao pertence a versao desta matricula'; END IF;

  INSERT INTO lms.progresso_aula (matricula_id, aula_id, segundos_assistidos, confirmou_leitura)
  VALUES (p_matricula, p_aula, 0, false)
  ON CONFLICT (matricula_id, aula_id) DO NOTHING;

  SELECT * INTO p FROM lms.progresso_aula WHERE matricula_id = p_matricula AND aula_id = p_aula;

  -- Monotonico (nunca diminui) e com teto de 120 s por gravacao.
  UPDATE lms.progresso_aula
     SET segundos_assistidos = greatest(p.segundos_assistidos,
                                        least(coalesce(p_segundos, 0), p.segundos_assistidos + 120)),
         confirmou_leitura   = p.confirmou_leitura OR coalesce(p_confirmou, false),
         atualizado_em       = now()
   WHERE id = p.id
  RETURNING * INTO p;

  -- Conclui a aula quando cumpriu tempo minimo e, quando o tipo pede, confirmou leitura.
  IF p.concluido_em IS NULL
     AND p.segundos_assistidos >= a.segundos_minimos
     AND (a.tipo NOT IN ('texto', 'pdf', 'link') OR p.confirmou_leitura) THEN
    UPDATE lms.progresso_aula SET concluido_em = now() WHERE id = p.id RETURNING * INTO p;
  END IF;

  UPDATE lms.matricula
     SET status      = CASE WHEN status = 'nao_iniciada' THEN 'em_andamento'::lms.matricula_status ELSE status END,
         iniciado_em = coalesce(iniciado_em, now())
   WHERE id = p_matricula;

  RETURN p;
END $$;
COMMENT ON FUNCTION lms.registrar_progresso(uuid, uuid, integer, boolean) IS 'Unico caminho para gravar progresso de aula. Aplica o teto de 120 s por gravacao, a monotonicidade e a conclusao por tempo minimo mais confirmacao de leitura.';


-- 13.4 correcao da avaliacao (no servidor) -------------------------------------------
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
BEGIN
  SELECT * INTO m FROM lms.matricula WHERE id = p_matricula FOR UPDATE;
  IF m.id IS NULL THEN RAISE EXCEPTION 'Matricula inexistente'; END IF;
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
COMMENT ON FUNCTION lms.corrigir_tentativa(uuid, jsonb) IS 'Corrige a avaliacao DENTRO do banco. E SECURITY DEFINER porque a role da aplicacao nao tem permissao de ler a coluna do gabarito: o navegador manda as respostas e recebe apenas nota, aprovacao e tentativas restantes. Aplica tambem o bloqueio ao esgotar as tentativas.';

CREATE OR REPLACE FUNCTION lms.liberar_matricula(
  p_matricula uuid,
  p_motivo    text,
  p_por       uuid,
  p_extra     smallint DEFAULT 1
) RETURNS lms.matricula
LANGUAGE plpgsql AS $$
DECLARE m lms.matricula;
BEGIN
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
COMMENT ON FUNCTION lms.liberar_matricula(uuid, text, uuid, smallint) IS 'Desbloqueia uma matricula que esgotou as tentativas, exigindo motivo e registrando quem liberou.';


-- =====================================================================================
-- 14. DADOS DE REFERENCIA (seeds)
--   Entram aqui os dados que sao parte do sistema, nao do movimento: permissoes,
--   perfis, grupos, familias e seus campos, centros de custo e os 18 medidores.
--   Todos com ON CONFLICT DO NOTHING para o arquivo poder ser reaplicado.
-- =====================================================================================

INSERT INTO core.sequencia (escopo, prefixo, largura) VALUES
  ('sci', 'SCI-', 4),
  ('scm', 'SCM-', 4)
ON CONFLICT (escopo) DO NOTHING;

INSERT INTO core.permissao (chave, area, rotulo, descricao, posicao) VALUES
  ('almoxarifado.acesso',        'almoxarifado', 'Acessar almoxarifado',          'Ve o modulo do almoxarifado.',                          1),
  ('almoxarifado.solicitacoes',  'almoxarifado', 'Tratar solicitacoes (SCI)',     'Muda status e preenche dados da SCI.',                   2),
  ('almoxarifado.familias',      'almoxarifado', 'Gerenciar familias',            'Cria e edita familias e campos dinamicos.',              3),
  ('almoxarifado.scm_acesso',    'almoxarifado', 'Acessar SCM',                   'Abre e acompanha solicitacoes de compra.',               4),
  ('almoxarifado.scm_gestao',    'almoxarifado', 'Gerir SCM',                     'Tratativa do almoxarife nas solicitacoes de compra.',    5),
  ('almoxarifado.scm_aprovacao', 'almoxarifado', 'Aprovar SCM',                   'Aprova ou reprova solicitacao de compra.',               6),
  ('pcm.acesso',                 'pcm',          'Acessar PCM',                   'Ve o modulo de PCM.',                                    7),
  ('utilidades.acesso',          'utilidades',   'Acessar utilidades',            'Aponta leitura e ve o painel de medidores.',              8)
ON CONFLICT (chave) DO NOTHING;

INSERT INTO core.perfil (id, nome, fixo, descricao) VALUES
  ('admin',      'Administrador', true,  'Acesso total. Perfil de sistema, protegido contra exclusao.'),
  ('gestor',     'Gestor',        false, 'Mesma amplitude do administrador na operacao, sem ser perfil de sistema.'),
  ('pcm',        'PCM',           false, 'Planejamento e controle da manutencao.'),
  ('almoxarife', 'Almoxarife',    false, 'Tratativa de SCI e SCM no almoxarifado.'),
  ('lider',      'Lider',         false, 'Aprova solicitacao de compra da equipe e acompanha treinamentos.'),
  ('tecnico',    'Tecnico',       false, 'Abre solicitacao e aponta utilidades.'),
  ('viewer',     'Viewer',        false, 'Somente visualizacao.')
ON CONFLICT (id) DO NOTHING;

-- Permissoes por perfil, iguais ao que o HTML local ja aplicava.
-- pcm e viewer nao tinham conjunto definido no arquivo local: nascem no minimo
-- (menor privilegio) e o administrador completa na tela de perfis. Chutar
-- permissao aqui seria dar acesso que ninguem pediu.
INSERT INTO core.perfil_permissao (perfil_id, permissao_chave)
SELECT p.perfil_id, p.chave
  FROM (VALUES
    ('admin',      'almoxarifado.acesso'),
    ('admin',      'almoxarifado.solicitacoes'),
    ('admin',      'almoxarifado.familias'),
    ('admin',      'almoxarifado.scm_acesso'),
    ('admin',      'almoxarifado.scm_gestao'),
    ('admin',      'almoxarifado.scm_aprovacao'),
    ('admin',      'pcm.acesso'),
    ('admin',      'utilidades.acesso'),
    ('gestor',     'almoxarifado.acesso'),
    ('gestor',     'almoxarifado.solicitacoes'),
    ('gestor',     'almoxarifado.familias'),
    ('gestor',     'almoxarifado.scm_acesso'),
    ('gestor',     'almoxarifado.scm_gestao'),
    ('gestor',     'almoxarifado.scm_aprovacao'),
    ('gestor',     'pcm.acesso'),
    ('gestor',     'utilidades.acesso'),
    ('almoxarife', 'almoxarifado.acesso'),
    ('almoxarife', 'almoxarifado.solicitacoes'),
    ('almoxarife', 'almoxarifado.familias'),
    ('almoxarife', 'almoxarifado.scm_acesso'),
    ('almoxarife', 'almoxarifado.scm_gestao'),
    ('lider',      'almoxarifado.acesso'),
    ('lider',      'almoxarifado.scm_acesso'),
    ('lider',      'almoxarifado.scm_aprovacao'),
    ('lider',      'pcm.acesso'),
    ('lider',      'utilidades.acesso'),
    ('tecnico',    'almoxarifado.acesso'),
    ('tecnico',    'almoxarifado.scm_acesso'),
    ('tecnico',    'utilidades.acesso'),
    ('pcm',        'pcm.acesso')
  ) AS p(perfil_id, chave)
ON CONFLICT DO NOTHING;

INSERT INTO core.grupo (origem_id, codigo, nome, area) VALUES
  ('g-mecanica',            'g-mecanica',            'Mecanica',             'Manutencao'),
  ('g-soldador',            'g-soldador',            'Soldador',             'Manutencao'),
  ('g-tec-utilidades',      'g-tec-utilidades',      'Tecnico Utilidades',   'Utilidades'),
  ('g-eletrica-automacao',  'g-eletrica-automacao',  'Eletrica / Automacao', 'Manutencao'),
  ('g-predial',             'g-predial',             'Predial',              'Facilities'),
  ('g-predial-eletrica',    'g-predial-eletrica',    'Predial Eletrica',     'Facilities'),
  ('g-eletromecanica',      'g-eletromecanica',      'Eletromecanica',       'Manutencao'),
  ('g-pcm',                 'g-pcm',                 'PCM',                  'PCM'),
  ('g-almoxarifado',        'g-almoxarifado',        'Almoxarifado',         'Almoxarifado'),
  ('g-coord-adm',           'g-coord-adm',           'Coordenador ADM',      'Coordenacao'),
  ('g-coord-eletrica',      'g-coord-eletrica',      'Coordenador Eletrica', 'Coordenacao')
ON CONFLICT (codigo) DO NOTHING;

-- Primeiro acesso: sem ninguem na lista de autorizados o site sobe e nao entra
-- nenhum usuario. Fica liberado o administrador que hoje mantem a plataforma;
-- revogar/trocar e um UPDATE nesta tabela.
INSERT INTO core.email_autorizado (email, perfil_padrao, motivo) VALUES
  ('felipe.vieira@biotrop.com.br', 'admin', 'administrador inicial da plataforma')
ON CONFLICT (email) DO NOTHING;

INSERT INTO almox.familia (id, nome, posicao) VALUES
  ('parafuso',               'Parafuso',               1),
  ('porca',                  'Porca',                  2),
  ('componente_especifico',  'Componente Especifico',  3),
  ('arruela',                'Arruela',                4),
  ('tubos_e_conex_es',       'Tubos e Conexoes',       5),
  ('bucha_de_fixacao',       'Bucha de Fixacao',       6),
  ('valvulas',               'Valvulas',               7),
  ('vedacao',                'Vedacao',                8),
  ('outros',                 'Outros',                 9)
ON CONFLICT (id) DO NOTHING;

INSERT INTO almox.familia_campo (familia_id, chave, rotulo, obrigatorio, posicao)
SELECT f.familia_id, f.chave, f.rotulo, f.obrigatorio, f.posicao
  FROM (VALUES
    ('parafuso','material_construtivo','MATERIAL CONSTRUTIVO',true,1),
    ('parafuso','revestimento_acabamento','REVESTIMENTO/ACABAMENTO',true,2),
    ('parafuso','tipo_rosca','TIPO ROSCA',true,3),
    ('parafuso','passo_fio','PASSO/FIO',false,4),
    ('parafuso','comprimento_rosca','COMPRIMENTO ROSCA',true,5),
    ('parafuso','norma','NORMA',false,6),
    ('parafuso','diametro','DIAMETRO',true,7),
    ('parafuso','comprimento_total','COMPRIMENTO TOTAL',true,8),
    ('parafuso','tipo_cabeca','TIPO CABECA',true,9),
    ('parafuso','tipo_de_acionamento','TIPO DE ACIONAMENTO',true,10),
    ('parafuso','sentido_rosca','SENTIDO ROSCA',true,11),
    ('porca','tipo','TIPO',true,1),
    ('porca','material_construtivo','MATERIAL CONSTRUTIVO',true,2),
    ('porca','acabamento','ACABAMENTO',true,3),
    ('porca','tipo_rosca','TIPO ROSCA',true,4),
    ('porca','passo_de_rosca','PASSO DE ROSCA',true,5),
    ('porca','classe_de_resistencia','CLASSE DE RESISTENCIA',true,6),
    ('porca','unidade_de_medida','UNIDADE DE MEDIDA',true,7),
    ('porca','diametro','DIAMETRO',true,8),
    ('porca','norma','NORMA',false,9),
    ('componente_especifico','nome_da_peca','NOME DA PECA',true,1),
    ('componente_especifico','material','MATERIAL',true,2),
    ('componente_especifico','dimensoes','DIMENSOES',true,3),
    ('componente_especifico','aplicacao','APLICACAO',true,4),
    ('componente_especifico','dados_adicionais','DADOS ADICIONAIS',true,5),
    ('componente_especifico','fabricante','FABRICANTE',true,6),
    ('componente_especifico','referencia_fabricante','REFERENCIA FABRICANTE',true,7),
    ('arruela','tipo','TIPO',true,1),
    ('arruela','material_construtivo','MATERIAL CONSTRUTIVO',true,2),
    ('arruela','acabamento','ACABAMENTO',true,3),
    ('arruela','norma','NORMA',true,4),
    ('arruela','perfil','PERFIL',true,5),
    ('arruela','medidas','MEDIDAS',true,6),
    ('arruela','espessura','ESPESSURA',true,7),
    ('tubos_e_conex_es','tipo_de_conexao','TIPO DE CONEXAO',true,1),
    ('tubos_e_conex_es','angulo','ANGULO',false,2),
    ('tubos_e_conex_es','material','MATERIAL',true,3),
    ('tubos_e_conex_es','acabamento_revestimento','ACABAMENTO/REVESTIMENTO',false,4),
    ('tubos_e_conex_es','cor','COR',false,5),
    ('tubos_e_conex_es','diametro_nominal','DIAMETRO NOMINAL',true,6),
    ('tubos_e_conex_es','espessura','ESPESSURA',true,7),
    ('tubos_e_conex_es','extremidade','EXTREMIDADE',true,8),
    ('tubos_e_conex_es','norma','NORMA',true,9),
    ('bucha_de_fixacao','tipo','TIPO',true,1),
    ('bucha_de_fixacao','material','MATERIAL',true,2),
    ('bucha_de_fixacao','diametro','DIAMETRO',true,3),
    ('bucha_de_fixacao','comprimento','COMPRIMENTO',true,4),
    ('bucha_de_fixacao','carga_aplicacao','CARGA/APLICACAO',true,5),
    ('bucha_de_fixacao','diametro_parafuso','DIAMETRO PARAFUSO',true,6),
    ('valvulas','tipo','TIPO',true,1),
    ('valvulas','diametro_nominal','DIAMETRO NOMINAL',true,2),
    ('valvulas','tipo_conexao','TIPO CONEXAO',true,3),
    ('valvulas','pressao_maxima_de_trabalho','PRESSAO MAXIMA DE TRABALHO',true,4),
    ('valvulas','material_construtivo','MATERIAL CONSTRUTIVO',true,5),
    ('valvulas','material_vedacao_interna','MATERIAL VEDACAO INTERNA',true,6),
    ('valvulas','acionamento','ACIONAMENTO',true,7),
    ('valvulas','faixa_de_temperatura_trabalho','FAIXA DE TEMPERATURA TRABALHO',false,8),
    ('valvulas','fluido_aplicacao','FLUIDO/APLICACAO',false,9),
    ('valvulas','vias','VIAS',true,10),
    ('valvulas','classe','CLASSE',false,11),
    ('vedacao','tipo','TIPO',true,1),
    ('vedacao','formato_perfil','FORMATO/PERFIL',true,2),
    ('vedacao','material','MATERIAL',true,3),
    ('vedacao','dureza_shore','DUREZA/SHORE',false,4),
    ('vedacao','medidas','MEDIDAS',true,5),
    ('vedacao','espessura','ESPESSURA',true,6),
    ('vedacao','faixa_de_temperatura','FAIXA DE TEMPERATURA',true,7),
    ('vedacao','norma','NORMA',false,8),
    ('vedacao','aplicacao','APLICACAO',false,9),
    ('outros','descricao_completa','DESCRICAO COMPLETA',true,1),
    ('outros','material','MATERIAL',true,2),
    ('outros','medidas','MEDIDAS',true,3),
    ('outros','aplicacao','APLICACAO',true,4),
    ('outros','norma','NORMA',false,5)
  ) AS f(familia_id, chave, rotulo, obrigatorio, posicao)
ON CONFLICT (familia_id, chave) DO NOTHING;

INSERT INTO almox.centro_custo (nome, posicao)
SELECT c.nome, c.posicao
  FROM (VALUES
    ('CENTRO LOGISTICO',1),('COMPRAS',2),('COMPRAS - PRODUCAO',3),('CONTABILIDADE',4),
    ('CONTROLE DE QUALIDADE - CAMM 3',5),('EMPACOTAMENTO - CAMM 1',6),('EMPACOTAMENTO - CAMM 2',7),
    ('ENVASE - CAMM 1',8),('ENVASE - CAMM 2',9),('ESG',10),('FACILITIES',11),
    ('FACILITIES - INDUSTRIAL - CAMM 3',12),('FACILITIES - PRODUCAO',13),
    ('FATURAMENTO E EXPEDICAO',14),('FERMENTACAO - CAMM 2',15),('FERMENTACAO - CAMM 3',16),
    ('FERMENTADORES - CAMM 1',17),('FISCAL',18),('FORMULACAO/EMPACOTAMENTO - CAMM 3',19),
    ('FP&A',20),('FRACIONAMENTO DE MP',21),('FROTAS',22),('INOVACAO',23),('LABORATORIO',24),
    ('LOGISTICA INTERNA',25),('LOGISTICA INTERNA - CAMM 3',26),('MANUTENCAO',27),
    ('MANUTENCAO E ENGENHARIA - CAMM 3',28),('MANUTENCAO PREDIAL (FACILITIES)',29),
    ('MELHORIA CONTINUA',30),('PCP',31),('PESQUISA',32),('QUALIDADE',33),
    ('RECRUTAMENTO E SELECAO',34),('REGULATORIO',35),('S&OP',36),
    ('SEGURANCA DO TRABALHO - CAMM 3',37),('SEGURANCA DO TRABALHO - G&A',38),
    ('SEGURANCA DO TRABALHO - PRODUCAO',39),('TESOURARIA',40),('TI',41),('UTILIDADES',42),
    ('UTILIDADES - CAMM 3',43),('VENDAS INDUSTRIAIS B2B',44),('Outro',45)
  ) AS c(nome, posicao)
ON CONFLICT (nome) DO NOTHING;

INSERT INTO util.medidor (origem_id, codigo, nome, camm, tipo, unidade)
SELECT m.codigo, m.codigo, m.nome, m.camm::core.camm, m.tipo::util.medidor_tipo, m.unidade::util.unidade_medida
  FROM (VALUES
    ('CAMM1-GAS-01',  'MEDIDOR GAS 01 - CAMM 1',                        'CAMM 1', 'gas',     'Nm3'),
    ('CAMM1-AGUA-02', 'HIDROMETRO 02 - CAMM 1',                         'CAMM 1', 'agua',    'm3'),
    ('CAMM1-AGUA-03', 'HIDROMETRO 03 - CAMM 1',                         'CAMM 1', 'agua',    'm3'),
    ('CAMM1-AGUA-06', 'HIDROMETRO 06 - CAMM 1 - POCO',                  'CAMM 1', 'agua',    'm3'),
    ('CAMM1-LUZ-01',  'MEDIDOR ENERGIA 01 - CAMM 1 - CABINE PRIMARIA',  'CAMM 1', 'energia', 'kWh'),
    ('CAMM1-LUZ-02',  'MEDIDOR ENERGIA 02 - CAMM 1 - BOMBA DE INCENDIO','CAMM 1', 'energia', 'kWh'),
    ('CAMM2-GAS-01',  'MEDIDOR GAS 01 - CAMM 2',                        'CAMM 2', 'gas',     'Nm3'),
    ('CAMM2-AGUA-01', 'HIDROMETRO 01 - CAMM 2',                         'CAMM 2', 'agua',    'm3'),
    ('CAMM2-AGUA-02', 'HIDROMETRO 02 - CAMM 2',                         'CAMM 2', 'agua',    'm3'),
    ('CAMM2-AGUA-08', 'HIDROMETRO 08 - CAMM 2',                         'CAMM 2', 'agua',    'm3'),
    ('CAMM2-AGUA-09', 'HIDROMETRO 09 - CAMM 2',                         'CAMM 2', 'agua',    'm3'),
    ('CAMM2-LUZ-01',  'MEDIDOR ENERGIA 01 - CAMM 2',                    'CAMM 2', 'energia', 'kWh'),
    ('CAMM2-LUZ-02',  'MEDIDOR ENERGIA 02 - CAMM 2',                    'CAMM 2', 'energia', 'kWh'),
    ('CAMM3-GAS-01',  'MEDIDOR GAS 01 - CAMM 3',                        'CAMM 3', 'gas',     'Nm3'),
    ('CAMM3-AGUA-01', 'HIDROMETRO 01 - CAMM 3',                         'CAMM 3', 'agua',    'm3'),
    ('CAMM3-LUZ-01',  'MEDIDOR ENERGIA 01 - CAMM 3',                    'CAMM 3', 'energia', 'kWh'),
    ('CLOG-AGUA-01',  'HIDROMETRO 01 - C. LOG',                         'C. LOG', 'agua',    'm3'),
    ('CLOG-LUZ-01',   'MEDIDOR ENERGIA 01 - C. LOG',                    'C. LOG', 'energia', 'kWh')
  ) AS m(codigo, nome, camm, tipo, unidade)
ON CONFLICT (codigo) DO NOTHING;


-- =====================================================================================
-- 15. MIGRACAO DO LOCALSTORAGE
--
-- COMO TIRAR O DADO DO NAVEGADOR
--   exportLocalBackup() resolve a maior parte, MAS nao exporta duas coisas que hoje
--   existem: btlocal.lms_v1 (todo o modulo de treinamentos novo) e btlocal.grupos_v1
--   (grupos e responsaveis). Por isso o procedimento recomendado e um dump bruto de
--   TODAS as chaves, no console (F12) do arquivo local, com o usuario logado:
--
--     copy(JSON.stringify(Object.fromEntries(
--       Object.keys(localStorage).filter(k => k.startsWith('btlocal.'))
--         .map(k => [k, JSON.parse(localStorage.getItem(k))]))))
--
--   Cole o resultado em um arquivo dump.json e carregue com:
--     \set dump `cat dump.json`
--     SELECT mig.carregar_dump(:'dump'::jsonb, 'dump.json');
--     SELECT mig.importar_tudo('<lote uuid devolvido acima>');
--     SELECT * FROM mig.vw_conferencia;      -- confere quantidade origem x destino
--     SELECT * FROM mig.ocorrencia ORDER BY id;  -- o que precisou de decisao humana
--
--   mig.carregar_dump aceita as duas formas: o dump bruto (chaves btlocal.*) e o JSON
--   do exportLocalBackup() (chaves users/profiles/sci/scm/...). O que estiver ausente
--   simplesmente nao e importado, e a ocorrencia registra a falta.
--
-- IDEMPOTENCIA
--   Toda tabela migrada tem origem_id UNIQUE com o id que o registro tinha no
--   navegador. Reimportar o mesmo dump nao duplica nada e atualiza o que mudou.
--   E isso que permite ensaiar a virada quantas vezes for preciso antes do dia.
-- =====================================================================================

CREATE TABLE IF NOT EXISTS mig.lote (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  arquivo        text,
  exportado_em   timestamptz,
  carregado_em   timestamptz NOT NULL DEFAULT now(),
  importado_em   timestamptz,
  importado_por  text        NOT NULL DEFAULT current_user,
  resultado      jsonb
);
COMMENT ON TABLE mig.lote IS 'Cada carga de dump do navegador. Guardar o lote permite repetir a importacao e comparar resultados entre ensaios.';

CREATE TABLE IF NOT EXISTS mig.dump (
  lote_id   uuid  NOT NULL REFERENCES mig.lote(id) ON DELETE CASCADE,
  chave     text  NOT NULL,
  conteudo  jsonb NOT NULL,
  PRIMARY KEY (lote_id, chave)
);
COMMENT ON TABLE mig.dump IS 'JSON cru, uma linha por chave do localStorage, normalizada para nome curto (users, profiles, sci, scm, meters, readings, lms, grupos...). O cru fica guardado: se a transformacao estiver errada, a origem ainda esta aqui.';

CREATE TABLE IF NOT EXISTS mig.ocorrencia (
  id          bigserial   PRIMARY KEY,
  lote_id     uuid        REFERENCES mig.lote(id) ON DELETE CASCADE,
  etapa       text        NOT NULL,
  severidade  text        NOT NULL DEFAULT 'aviso' CHECK (severidade IN ('info', 'aviso', 'erro')),
  registro    text,
  mensagem    text        NOT NULL,
  dado        jsonb,
  em          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_ocorrencia_lote ON mig.ocorrencia (lote_id, severidade);
COMMENT ON TABLE mig.ocorrencia IS 'Tudo que a importacao nao conseguiu resolver sozinha: leitura recusada pela regra do acumulativo, SCI cadastrada sem codigo do item, centro de custo desconhecido, treinamento do modelo antigo sem equivalente. E a lista de trabalho pos-virada.';

-- 15.1 carga do dump ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mig.carregar_dump(p_json jsonb, p_arquivo text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_lote  uuid;
  v_chave text;
  v_norm  text;
  v_val   jsonb;
BEGIN
  INSERT INTO mig.lote (arquivo, exportado_em)
  VALUES (p_arquivo, nullif(p_json ->> 'exportedAt', '')::timestamptz)
  RETURNING id INTO v_lote;

  FOR v_chave, v_val IN SELECT key, value FROM jsonb_each(p_json) LOOP
    v_norm := CASE v_chave
      WHEN 'btlocal.biotrop_users_v2'             THEN 'users'
      WHEN 'btlocal.biotrop_profiles_v2'          THEN 'profiles'
      WHEN 'btlocal.biotrop_families_v1'          THEN 'families'
      WHEN 'btlocal.biotrop_sci_v1'               THEN 'sci'
      WHEN 'btlocal.biotrop_scm_v1'               THEN 'scm'
      WHEN 'btlocal.biotrop_utility_meters_v1'    THEN 'meters'
      WHEN 'btlocal.biotrop_utility_readings_v1'  THEN 'readings'
      WHEN 'btlocal.grupos_v1'                    THEN 'grupos'
      WHEN 'btlocal.lms_v1'                       THEN 'lms'
      WHEN 'btlocal.BIOTROP_TRAININGS_V8'         THEN 'trainings_v8'
      WHEN 'btlocal.BIOTROP_TRAINING_PROGRESS_V8' THEN 'training_progress_v8'
      WHEN 'btlocal.biotrop_sci_counter_v1'       THEN 'sci_counter'
      WHEN 'btlocal.biotrop_scm_counter_v1'       THEN 'scm_counter'
      -- nomes curtos do exportLocalBackup() passam direto
      WHEN 'trainings'                            THEN 'trainings_v8'
      WHEN 'trainingProgress'                     THEN 'training_progress_v8'
      ELSE v_chave
    END;

    IF v_norm IN ('users','profiles','families','sci','scm','meters','readings','grupos','lms',
                  'trainings_v8','training_progress_v8','sci_counter','scm_counter') THEN
      INSERT INTO mig.dump (lote_id, chave, conteudo)
      VALUES (v_lote, v_norm, v_val)
      ON CONFLICT (lote_id, chave) DO UPDATE SET conteudo = EXCLUDED.conteudo;
    END IF;
  END LOOP;

  IF NOT EXISTS (SELECT 1 FROM mig.dump WHERE lote_id = v_lote AND chave = 'lms') THEN
    INSERT INTO mig.ocorrencia (lote_id, etapa, severidade, mensagem)
    VALUES (v_lote, 'carregar_dump', 'aviso',
            'dump sem a chave lms: o exportLocalBackup() nao exporta btlocal.lms_v1. Refaca o dump bruto se os treinamentos precisam vir.');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM mig.dump WHERE lote_id = v_lote AND chave = 'grupos') THEN
    INSERT INTO mig.ocorrencia (lote_id, etapa, severidade, mensagem)
    VALUES (v_lote, 'carregar_dump', 'aviso',
            'dump sem a chave grupos: os grupos ficam apenas com os do seed e os responsaveis precisam ser reapontados.');
  END IF;

  RETURN v_lote;
END $$;
COMMENT ON FUNCTION mig.carregar_dump(jsonb, text) IS 'Guarda o dump do navegador em mig.dump, normalizando o nome das chaves e aceitando tanto o dump bruto do localStorage quanto a saida do exportLocalBackup().';

-- 15.2 mapeamentos --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mig.mapear_status_sci(p text) RETURNS almox.sci_status
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE lower(coalesce(p, ''))
    WHEN 'pendente'            THEN 'pendente_aprovacao'
    WHEN 'aprovado'            THEN 'em_compra'
    WHEN 'solicitado_cadastro' THEN 'aguardando_cadastro'
    WHEN 'recusado'            THEN 'reprovada'
    WHEN 'pendente_aprovacao'  THEN 'pendente_aprovacao'
    WHEN 'revisao_solicitante' THEN 'revisao_solicitante'
    WHEN 'em_compra'           THEN 'em_compra'
    WHEN 'aguardando_cadastro' THEN 'aguardando_cadastro'
    WHEN 'cadastrado'          THEN 'cadastrado'
    WHEN 'reprovada'           THEN 'reprovada'
    ELSE 'pendente_aprovacao'
  END::almox.sci_status;
$$;
COMMENT ON FUNCTION mig.mapear_status_sci(text) IS 'De/para dos status antigos da SCI para os definidos em reuniao. Mesma tabela de conversao que o arquivo local usa, para o dado nao mudar de significado no meio do caminho.';

CREATE OR REPLACE FUNCTION mig.mapear_status_scm(p text) RETURNS almox.scm_status
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE lower(coalesce(p, ''))
    WHEN 'aprovada'                 THEN 'aprovada'
    WHEN 'reprovada'                THEN 'reprovada'
    WHEN 'revisao_solicitada'       THEN 'revisao_solicitada'
    WHEN 'em_tratativa'             THEN 'em_tratativa'
    WHEN 'concluida'                THEN 'concluida'
    ELSE 'pendente_aprovacao_lider'
  END::almox.scm_status;
$$;

-- STABLE (nao IMMUTABLE) porque unaccent() depende de dicionario carregado.
CREATE OR REPLACE FUNCTION mig.mapear_urgencia(p text) RETURNS almox.urgencia
LANGUAGE sql STABLE AS $$
  SELECT CASE lower(unaccent(coalesce(p, '')))
    WHEN 'baixa' THEN 'baixa'
    WHEN 'alta'  THEN 'alta'
    ELSE 'media'
  END::almox.urgencia;
$$;

CREATE OR REPLACE FUNCTION mig.mapear_camm(p text) RETURNS core.camm
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN upper(replace(coalesce(p, ''), ' ', '')) IN ('CAMM1','CAMM01') THEN 'CAMM 1'
    WHEN upper(replace(coalesce(p, ''), ' ', '')) IN ('CAMM2','CAMM02') THEN 'CAMM 2'
    WHEN upper(replace(coalesce(p, ''), ' ', '')) IN ('CAMM3','CAMM03') THEN 'CAMM 3'
    WHEN upper(replace(replace(coalesce(p, ''), ' ', ''), '.', '')) IN ('CLOG','CENTROLOGISTICO') THEN 'C. LOG'
    ELSE NULL
  END::core.camm;
$$;
COMMENT ON FUNCTION mig.mapear_camm(text) IS 'Normaliza as varias escritas de CAMM que existem no dado antigo (CAMM 1, CAMM1, Time CAMM 03, C. LOG).';

CREATE OR REPLACE FUNCTION mig.mapear_unidade(p_tipo text, p_unidade text) RETURNS util.unidade_medida
LANGUAGE sql IMMUTABLE AS $$
  -- A unidade segue o tipo, que e a regra do CHECK do medidor. A unidade escrita
  -- no dado antigo (m3, Nm3, kWh, h) so e usada como confirmacao.
  SELECT CASE lower(coalesce(p_tipo, ''))
    WHEN 'agua'      THEN 'm3'
    WHEN 'gas'       THEN 'Nm3'
    WHEN 'energia'   THEN 'kWh'
    WHEN 'horimetro' THEN 'h'
    ELSE 'm3'
  END::util.unidade_medida;
$$;

-- 15.3 importacao por modulo ----------------------------------------------------------
CREATE OR REPLACE FUNCTION mig.importar_perfis(p_lote uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  v_json  jsonb;
  r       jsonb;
  v_area  text;
  v_perm  text;
  v_val   jsonb;
  v_n     integer := 0;
BEGIN
  SELECT conteudo INTO v_json FROM mig.dump WHERE lote_id = p_lote AND chave = 'profiles';
  IF v_json IS NULL THEN RETURN 0; END IF;

  FOR r IN SELECT value FROM jsonb_array_elements(v_json) LOOP
    INSERT INTO core.perfil (id, nome, fixo)
    VALUES (r ->> 'id', coalesce(r ->> 'nome', r ->> 'id'), coalesce((r ->> 'fixo')::boolean, false))
    ON CONFLICT (id) DO UPDATE SET nome = EXCLUDED.nome;
    v_n := v_n + 1;

    -- permissoes: {area: {chave: true|false}} -> uma linha por chave verdadeira
    FOR v_area, v_val IN SELECT key, value FROM jsonb_each(coalesce(r -> 'permissoes', '{}'::jsonb)) LOOP
      FOR v_perm IN SELECT key FROM jsonb_each(v_val) WHERE value = 'true'::jsonb LOOP
        IF EXISTS (SELECT 1 FROM core.permissao WHERE chave = v_area || '.' || v_perm) THEN
          INSERT INTO core.perfil_permissao (perfil_id, permissao_chave)
          VALUES (r ->> 'id', v_area || '.' || v_perm)
          ON CONFLICT DO NOTHING;
        ELSE
          INSERT INTO mig.ocorrencia (lote_id, etapa, severidade, registro, mensagem)
          VALUES (p_lote, 'importar_perfis', 'aviso', r ->> 'id',
                  'permissao desconhecida no dump: ' || v_area || '.' || v_perm);
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;

  RETURN v_n;
END $$;
COMMENT ON FUNCTION mig.importar_perfis(uuid) IS 'Importa perfis e converte o objeto de permissoes do localStorage nas linhas de core.perfil_permissao.';

CREATE OR REPLACE FUNCTION mig.importar_grupos(p_lote uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_json jsonb; v_n integer := 0;
BEGIN
  SELECT conteudo INTO v_json FROM mig.dump WHERE lote_id = p_lote AND chave = 'grupos';
  IF v_json IS NULL THEN RETURN 0; END IF;

  WITH ins AS (
    INSERT INTO core.grupo (origem_id, codigo, nome, area, ativo)
    SELECT g ->> 'id', g ->> 'id', g ->> 'nome', g ->> 'area',
           coalesce((g ->> 'ativo')::boolean, true)
      FROM jsonb_array_elements(v_json) AS g
    ON CONFLICT (origem_id) DO UPDATE
      SET nome = EXCLUDED.nome, area = EXCLUDED.area, ativo = EXCLUDED.ativo
    RETURNING 1
  ) SELECT count(*) INTO v_n FROM ins;

  RETURN v_n;
END $$;
COMMENT ON FUNCTION mig.importar_grupos(uuid) IS 'Importa os grupos. O responsavel de cada grupo e apontado depois, em mig.vincular_responsaveis(), porque depende dos usuarios ja existirem.';

CREATE OR REPLACE FUNCTION mig.importar_usuarios(p_lote uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  v_json jsonb;
  u      jsonb;
  v_n    integer := 0;
  v_mail citext;
  v_perf text;
BEGIN
  SELECT conteudo INTO v_json FROM mig.dump WHERE lote_id = p_lote AND chave = 'users';
  IF v_json IS NULL THEN RETURN 0; END IF;

  FOR u IN SELECT value FROM jsonb_array_elements(v_json) LOOP
    v_mail := lower(btrim(coalesce(u ->> 'usuario', u ->> 'email', '')))::citext;
    IF v_mail IS NULL OR v_mail::text = '' OR position('@' in v_mail::text) < 2 THEN
      INSERT INTO mig.ocorrencia (lote_id, etapa, severidade, registro, mensagem, dado)
      VALUES (p_lote, 'importar_usuarios', 'erro', u ->> 'id',
              'usuario sem e-mail valido: nao importado', u);
      CONTINUE;
    END IF;

    v_perf := coalesce(u ->> 'perfilId', 'tecnico');
    IF NOT EXISTS (SELECT 1 FROM core.perfil WHERE id = v_perf) THEN
      INSERT INTO mig.ocorrencia (lote_id, etapa, severidade, registro, mensagem)
      VALUES (p_lote, 'importar_usuarios', 'aviso', u ->> 'id',
              format('perfil "%s" inexistente; usuario importado como tecnico', v_perf));
      v_perf := 'tecnico';
    END IF;

    BEGIN
      -- A senha do localStorage (texto puro) NAO vem: quem entra passa a entrar
      -- por Entra ID. senha_hash fica nula de proposito.
      INSERT INTO core.usuario (origem_id, nome, email, perfil_id, grupo_id, time,
                                email_lider_excecao, telefone, notificacoes, ativo)
      VALUES (u ->> 'id',
              coalesce(nullif(btrim(u ->> 'nome'), ''), split_part(v_mail::text, '@', 1)),
              v_mail,
              v_perf,
              (SELECT g.id FROM core.grupo g WHERE g.origem_id = u ->> 'grupoId'),
              nullif(btrim(coalesce(u ->> 'time', '')), ''),
              nullif(lower(btrim(coalesce(u ->> 'emailLider', ''))), '')::citext,
              nullif(btrim(coalesce(u ->> 'telefone', '')), ''),
              coalesce((u ->> 'notificacoes')::boolean, true),
              coalesce((u ->> 'ativo')::boolean, true))
      ON CONFLICT (origem_id) DO UPDATE
        SET nome                = EXCLUDED.nome,
            email               = EXCLUDED.email,
            perfil_id           = EXCLUDED.perfil_id,
            grupo_id            = coalesce(EXCLUDED.grupo_id, usuario.grupo_id),
            time                = EXCLUDED.time,
            email_lider_excecao = EXCLUDED.email_lider_excecao,
            telefone            = EXCLUDED.telefone,
            ativo               = EXCLUDED.ativo;
      v_n := v_n + 1;
    EXCEPTION WHEN unique_violation THEN
      INSERT INTO mig.ocorrencia (lote_id, etapa, severidade, registro, mensagem, dado)
      VALUES (p_lote, 'importar_usuarios', 'erro', u ->> 'id',
              'e-mail ja existe em outro cadastro: resolva manualmente', u);
    END;

    -- A lista de autorizados nasce do cadastro atual: quem ja usava a plataforma
    -- continua entrando no dia da virada, sem depender de alguem liberar um por um.
    IF coalesce((u ->> 'ativo')::boolean, true) THEN
      INSERT INTO core.email_autorizado (email, perfil_padrao, motivo)
      VALUES (v_mail, v_perf, 'migrado do cadastro local')
      ON CONFLICT (email) DO NOTHING;
    END IF;
  END LOOP;

  RETURN v_n;
END $$;
COMMENT ON FUNCTION mig.importar_usuarios(uuid) IS 'Importa usuarios sem trazer senha (a autenticacao passa a ser Entra ID) e alimenta a lista de e-mails autorizados a partir de quem estava ativo.';

CREATE OR REPLACE FUNCTION mig.vincular_responsaveis(p_lote uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_json jsonb; v_n integer := 0;
BEGIN
  SELECT conteudo INTO v_json FROM mig.dump WHERE lote_id = p_lote AND chave = 'grupos';
  IF v_json IS NULL THEN RETURN 0; END IF;

  WITH upd AS (
    UPDATE core.grupo g
       SET responsavel_id = u.id
      FROM jsonb_array_elements(v_json) AS j
      JOIN core.usuario u ON u.origem_id = j ->> 'responsavelId'
     WHERE g.origem_id = j ->> 'id'
    RETURNING 1
  ) SELECT count(*) INTO v_n FROM upd;

  INSERT INTO mig.ocorrencia (lote_id, etapa, severidade, registro, mensagem)
  SELECT p_lote, 'vincular_responsaveis', 'aviso', g.codigo,
         'grupo sem responsavel definido: a SCM desses colaboradores cai no e-mail de excecao'
    FROM core.grupo g
   WHERE g.ativo AND g.responsavel_id IS NULL;

  RETURN v_n;
END $$;
COMMENT ON FUNCTION mig.vincular_responsaveis(uuid) IS 'Aponta o responsavel de cada grupo depois que os usuarios existem, e lista os grupos que ficaram sem responsavel.';

CREATE OR REPLACE FUNCTION mig.importar_familias(p_lote uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_json jsonb; v_n integer := 0;
BEGIN
  SELECT conteudo INTO v_json FROM mig.dump WHERE lote_id = p_lote AND chave = 'families';
  IF v_json IS NULL THEN RETURN 0; END IF;

  INSERT INTO almox.familia (id, nome)
  SELECT f ->> 'id', f ->> 'nome'
    FROM jsonb_array_elements(v_json) AS f
  ON CONFLICT (id) DO UPDATE SET nome = EXCLUDED.nome;

  WITH campos AS (
    SELECT f ->> 'id' AS familia_id,
           c ->> 'id' AS chave,
           c ->> 'label' AS rotulo,
           coalesce((c ->> 'obrigatorio')::boolean, false) AS obrigatorio,
           ord::smallint AS posicao
      FROM jsonb_array_elements(v_json) AS f
      CROSS JOIN LATERAL jsonb_array_elements(coalesce(f -> 'campos', '[]'::jsonb))
                         WITH ORDINALITY AS t(c, ord)
  ), ins AS (
    INSERT INTO almox.familia_campo (familia_id, chave, rotulo, obrigatorio, posicao)
    SELECT familia_id, chave, rotulo, obrigatorio, posicao FROM campos
    ON CONFLICT (familia_id, chave) DO UPDATE
      SET rotulo = EXCLUDED.rotulo, obrigatorio = EXCLUDED.obrigatorio, posicao = EXCLUDED.posicao
    RETURNING 1
  ) SELECT count(*) INTO v_n FROM ins;

  RETURN v_n;
END $$;
COMMENT ON FUNCTION mig.importar_familias(uuid) IS 'Importa familias e seus campos dinamicos, preservando a ordem em que apareciam no formulario.';

CREATE OR REPLACE FUNCTION mig.importar_sci(p_lote uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  v_json  jsonb;
  s       jsonb;
  v_id    uuid;
  v_foto  uuid;
  v_n     integer := 0;
  v_st    almox.sci_status;
BEGIN
  SELECT conteudo INTO v_json FROM mig.dump WHERE lote_id = p_lote AND chave = 'sci';
  IF v_json IS NULL THEN RETURN 0; END IF;

  FOR s IN SELECT value FROM jsonb_array_elements(v_json) LOOP
    -- Familia que nao existe mais e criada a partir do nome gravado na propria
    -- solicitacao: melhor uma familia orfa do que perder a SCI.
    IF NOT EXISTS (SELECT 1 FROM almox.familia WHERE id = s ->> 'familiaId') THEN
      INSERT INTO almox.familia (id, nome, ativo)
      VALUES (s ->> 'familiaId', coalesce(s ->> 'familiaNome', s ->> 'familiaId'), false)
      ON CONFLICT (id) DO NOTHING;
      INSERT INTO mig.ocorrencia (lote_id, etapa, severidade, registro, mensagem)
      VALUES (p_lote, 'importar_sci', 'aviso', s ->> 'codigo',
              format('familia "%s" nao existia; criada inativa para nao perder a solicitacao', s ->> 'familiaId'));
    END IF;

    v_id   := NULL;   -- zerar antes: sem isso um erro nesta linha faria os filhos
                      -- (campos e historico) grudarem na SCI anterior do laco
    v_st   := mig.mapear_status_sci(s ->> 'status');
    v_foto := core.anexo_de_dataurl(s ->> 'foto', coalesce(s ->> 'codigo', 'sci') || '-foto');

    BEGIN
    INSERT INTO almox.sci (
      origem_id, codigo, familia_id, campos_originais, link, marcas_homologadas,
      observacoes, foto_anexo_id, solicitante_id, solicitante_nome, status,
      numero_solicitacao_cadastro, codigo_item, observacao_almoxarife, criado_em)
    VALUES (
      s ->> 'id',
      coalesce(nullif(btrim(s ->> 'codigo'), ''), core.proximo_codigo('sci')),
      s ->> 'familiaId',
      coalesce(s -> 'campos', '{}'::jsonb),
      nullif(btrim(coalesce(s ->> 'link', '')), ''),
      nullif(btrim(coalesce(s ->> 'marcas', '')), ''),
      nullif(btrim(coalesce(s ->> 'observacoes', '')), ''),
      v_foto,
      (SELECT u.id FROM core.usuario u WHERE u.origem_id = s ->> 'solicitanteId'),
      coalesce(nullif(btrim(s ->> 'solicitanteNome'), ''), 'nao identificado'),
      v_st,
      nullif(btrim(coalesce(s ->> 'numeroSolicitacaoCadastro', s ->> 'numeroProcessoME', '')), ''),
      nullif(btrim(coalesce(s ->> 'codigoItem', '')), ''),
      nullif(btrim(coalesce(s ->> 'observacaoAlmoxarife', '')), ''),
      coalesce((s ->> 'dataCriacao')::timestamptz, now()))
    ON CONFLICT (origem_id) DO UPDATE
      SET status                      = EXCLUDED.status,
          codigo_item                 = EXCLUDED.codigo_item,
          numero_solicitacao_cadastro = EXCLUDED.numero_solicitacao_cadastro,
          observacao_almoxarife       = EXCLUDED.observacao_almoxarife
    RETURNING id INTO v_id;
      v_n := v_n + 1;
    EXCEPTION WHEN others THEN
      -- Uma SCI problematica nao pode derrubar a importacao das outras.
      INSERT INTO mig.ocorrencia (lote_id, etapa, severidade, registro, mensagem, dado)
      VALUES (p_lote, 'importar_sci', 'erro', s ->> 'codigo', SQLERRM, s);
    END;

    IF v_id IS NULL THEN
      CONTINUE;
    END IF;

    IF v_st = 'cadastrado' AND nullif(btrim(coalesce(s ->> 'codigoItem', '')), '') IS NULL THEN
      INSERT INTO mig.ocorrencia (lote_id, etapa, severidade, registro, mensagem)
      VALUES (p_lote, 'importar_sci', 'aviso', s ->> 'codigo',
              'SCI marcada como Cadastrado sem codigo do item: preencher (ver app.vw_sci_pendencia_dado)');
    END IF;

    -- valores dos campos dinamicos
    INSERT INTO almox.sci_valor_campo (sci_id, campo_id, valor)
    SELECT v_id, fc.id, kv.value #>> '{}'
      FROM jsonb_each(coalesce(s -> 'campos', '{}'::jsonb)) AS kv
      JOIN almox.familia_campo fc ON fc.familia_id = s ->> 'familiaId' AND fc.chave = kv.key
    ON CONFLICT (sci_id, campo_id) DO UPDATE SET valor = EXCLUDED.valor;

    INSERT INTO mig.ocorrencia (lote_id, etapa, severidade, registro, mensagem)
    SELECT p_lote, 'importar_sci', 'info', s ->> 'codigo',
           'campo "' || kv.key || '" nao existe mais na familia; valor preservado apenas em campos_originais'
      FROM jsonb_each(coalesce(s -> 'campos', '{}'::jsonb)) AS kv
     WHERE NOT EXISTS (SELECT 1 FROM almox.familia_campo fc
                        WHERE fc.familia_id = s ->> 'familiaId' AND fc.chave = kv.key);

    -- historico de transicoes
    INSERT INTO almox.sci_historico (sci_id, de, para, por_nome, nota, em)
    SELECT v_id,
           CASE WHEN nullif(h ->> 'de', '') IS NULL THEN NULL
                ELSE mig.mapear_status_sci(h ->> 'de') END,
           mig.mapear_status_sci(h ->> 'para'),
           h ->> 'por',
           nullif(h ->> 'nota', ''),
           coalesce((h ->> 'em')::timestamptz, now())
      FROM jsonb_array_elements(coalesce(s -> 'historico', '[]'::jsonb)) AS h
     WHERE NOT EXISTS (
             SELECT 1 FROM almox.sci_historico x
              WHERE x.sci_id = v_id AND x.em = coalesce((h ->> 'em')::timestamptz, now()));
  END LOOP;

  RETURN v_n;
END $$;
COMMENT ON FUNCTION mig.importar_sci(uuid) IS 'Importa as SCI: converte status antigo, transforma a foto em dataURL em anexo, normaliza os campos dinamicos e reconstroi o historico de transicoes.';

CREATE OR REPLACE FUNCTION mig.importar_scm(p_lote uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  v_json jsonb;
  s      jsonb;
  v_id   uuid;
  v_cc   smallint;
  v_camm core.camm;
  v_n    integer := 0;
BEGIN
  SELECT conteudo INTO v_json FROM mig.dump WHERE lote_id = p_lote AND chave = 'scm';
  IF v_json IS NULL THEN RETURN 0; END IF;

  FOR s IN SELECT value FROM jsonb_array_elements(v_json) LOOP
    v_id := NULL;

    -- centro de custo: casa por nome sem acento; o que nao casar entra na
    -- tabela para nao travar a importacao, e fica registrado para revisao.
    SELECT cc.id INTO v_cc
      FROM almox.centro_custo cc
     WHERE upper(unaccent(cc.nome)) = upper(unaccent(coalesce(s ->> 'centroCusto', '')))
     LIMIT 1;

    IF v_cc IS NULL AND nullif(btrim(coalesce(s ->> 'centroCusto', '')), '') IS NOT NULL THEN
      INSERT INTO almox.centro_custo (nome, ativo, posicao)
      VALUES (s ->> 'centroCusto', false, 999)
      ON CONFLICT (nome) DO NOTHING;
      SELECT cc.id INTO v_cc FROM almox.centro_custo cc WHERE cc.nome = s ->> 'centroCusto';
      INSERT INTO mig.ocorrencia (lote_id, etapa, severidade, registro, mensagem)
      VALUES (p_lote, 'importar_scm', 'aviso', s ->> 'codigo',
              format('centro de custo "%s" nao estava na lista; criado inativo', s ->> 'centroCusto'));
    END IF;

    -- A SCM so aceita CAMM 1/2/3 (CHECK). Nao reconhecido, ou C. LOG (que existe
    -- para utilidades), entra como CAMM 1 registrado, em vez de abortar a carga.
    v_camm := mig.mapear_camm(s ->> 'camm');
    IF v_camm IS NULL OR v_camm = 'C. LOG' THEN
      INSERT INTO mig.ocorrencia (lote_id, etapa, severidade, registro, mensagem)
      VALUES (p_lote, 'importar_scm', 'aviso', s ->> 'codigo',
              format('CAMM "%s" invalido para SCM; assumido CAMM 1 - conferir', s ->> 'camm'));
      v_camm := 'CAMM 1';
    END IF;

    BEGIN
    INSERT INTO almox.scm (
      origem_id, codigo, time_solicitante, tipo_solicitacao, capex_projeto, camm, urgencia,
      centro_custo_id, numero_om, tipo_fornecedor, nome_fornecedor, tipo_pedido, descricao_uso,
      solicitante_id, solicitante_nome, solicitante_email, solicitante_time,
      aprovador_id, aprovador_email, aprovador_origem, status,
      observacao_lider, observacao_almoxarife, numero_processo_me, criado_em)
    VALUES (
      s ->> 'id',
      coalesce(nullif(btrim(s ->> 'codigo'), ''), core.proximo_codigo('scm')),
      coalesce(nullif(btrim(s ->> 'timeSolicitante'), ''), 'nao informado'),
      nullif(btrim(coalesce(s ->> 'tipoSolicitacao', '')), ''),
      nullif(btrim(coalesce(s ->> 'capexProjeto', '')), ''),
      v_camm,
      mig.mapear_urgencia(s ->> 'urgencia'),
      v_cc,
      nullif(btrim(coalesce(s ->> 'numeroOM', '')), ''),
      nullif(btrim(coalesce(s ->> 'tipoFornecedor', '')), ''),
      nullif(btrim(coalesce(s ->> 'nomeFornecedor', '')), ''),
      nullif(btrim(coalesce(s ->> 'tipoPedido', '')), ''),
      coalesce(nullif(btrim(s ->> 'descricaoUso'), ''), '(sem descricao no dado antigo)'),
      (SELECT u.id FROM core.usuario u WHERE u.origem_id = s ->> 'solicitanteId'),
      coalesce(nullif(btrim(s ->> 'solicitanteNome'), ''), 'nao identificado'),
      nullif(lower(btrim(coalesce(s ->> 'solicitanteEmail', ''))), '')::citext,
      nullif(btrim(coalesce(s ->> 'solicitanteTime', '')), ''),
      (SELECT u.id FROM core.usuario u
        WHERE u.email = nullif(lower(btrim(coalesce(s ->> 'solicitanteEmailLider', ''))), '')::citext),
      nullif(lower(btrim(coalesce(s ->> 'solicitanteEmailLider', ''))), '')::citext,
      CASE WHEN nullif(btrim(coalesce(s ->> 'solicitanteEmailLider', '')), '') IS NULL
           THEN 'nenhum' ELSE 'excecao' END,
      mig.mapear_status_scm(s ->> 'status'),
      nullif(btrim(coalesce(s ->> 'observacaoLider', '')), ''),
      nullif(btrim(coalesce(s ->> 'observacaoAlmoxarife', '')), ''),
      nullif(btrim(coalesce(s ->> 'numeroProcessoME', '')), ''),
      coalesce((s ->> 'dataCriacao')::timestamptz, now()))
    ON CONFLICT (origem_id) DO UPDATE
      SET status                = EXCLUDED.status,
          observacao_lider      = EXCLUDED.observacao_lider,
          observacao_almoxarife = EXCLUDED.observacao_almoxarife,
          numero_processo_me    = EXCLUDED.numero_processo_me
    RETURNING id INTO v_id;
      v_n := v_n + 1;
    EXCEPTION WHEN others THEN
      INSERT INTO mig.ocorrencia (lote_id, etapa, severidade, registro, mensagem, dado)
      VALUES (p_lote, 'importar_scm', 'erro', s ->> 'codigo', SQLERRM, s);
    END;

    IF v_id IS NULL THEN
      CONTINUE;
    END IF;

    DELETE FROM almox.scm_item WHERE scm_id = v_id;
    INSERT INTO almox.scm_item (scm_id, posicao, codigo_sistema, descricao, quantidade,
                                estoque_minimo, marca_modelo_serie)
    SELECT v_id, ord::smallint,
           coalesce(nullif(btrim(i ->> 'codigoSistema'), ''), 'SEM-CODIGO'),
           nullif(btrim(coalesce(i ->> 'descricaoItem', '')), ''),
           -- quantidade vinha como texto livre ("2", "2,5", "2 un"): limpa e
           -- troca virgula por ponto. Sem numero valido assume 1 (o CHECK exige > 0).
           greatest(coalesce(nullif(replace(regexp_replace(coalesce(i ->> 'quantidade', ''),
                                                           '[^0-9,.]', '', 'g'), ',', '.'), '')::numeric, 1), 0.001),
           nullif(replace(regexp_replace(coalesce(i ->> 'estoqueMinimo', ''),
                                         '[^0-9,.]', '', 'g'), ',', '.'), '')::numeric,
           nullif(btrim(coalesce(i ->> 'marcaModeloSerie', '')), '')
      FROM jsonb_array_elements(coalesce(s -> 'itens', '[]'::jsonb)) WITH ORDINALITY AS t(i, ord);

    DELETE FROM almox.scm_link WHERE scm_id = v_id;
    INSERT INTO almox.scm_link (scm_id, url, posicao)
    SELECT v_id, btrim(l), ord::smallint
      FROM unnest(
             -- o campo links as vezes e lista, as vezes uma linha de texto com
             -- varios enderecos separados por espaco/virgula: cobre os dois
             CASE jsonb_typeof(coalesce(s -> 'links', 'null'::jsonb))
               WHEN 'array'  THEN ARRAY(SELECT e FROM jsonb_array_elements_text(s -> 'links') AS e)
               WHEN 'string' THEN regexp_split_to_array(s ->> 'links', '[[:space:],;]+')
               ELSE ARRAY[]::text[]
             END) WITH ORDINALITY AS t(l, ord)
     WHERE btrim(coalesce(l, '')) <> '';

    -- anexos: o dado antigo guarda dataURL; cada um vira uma linha de core.anexo
    INSERT INTO almox.scm_anexo (scm_id, anexo_id)
    SELECT v_id, x.anexo_id
      FROM (SELECT core.anexo_de_dataurl(a ->> 'data', coalesce(a ->> 'name', 'anexo')) AS anexo_id
              FROM jsonb_array_elements(coalesce(s -> 'anexos', '[]'::jsonb)) AS a
             WHERE nullif(a ->> 'data', '') IS NOT NULL) x
     WHERE x.anexo_id IS NOT NULL
    ON CONFLICT DO NOTHING;
  END LOOP;

  RETURN v_n;
END $$;
COMMENT ON FUNCTION mig.importar_scm(uuid) IS 'Importa as SCM com itens, links e anexos. Quantidade em texto e limpa para numero; centro de custo e CAMM desconhecidos entram registrados como ocorrencia em vez de derrubar a carga.';

CREATE OR REPLACE FUNCTION mig.importar_medidores(p_lote uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_json jsonb; m jsonb; v_camm core.camm; v_n integer := 0;
BEGIN
  SELECT conteudo INTO v_json FROM mig.dump WHERE lote_id = p_lote AND chave = 'meters';
  IF v_json IS NULL THEN RETURN 0; END IF;

  FOR m IN SELECT value FROM jsonb_array_elements(v_json) LOOP
    v_camm := mig.mapear_camm(coalesce(m ->> 'asset', m ->> 'camm'));
    IF v_camm IS NULL THEN
      INSERT INTO mig.ocorrencia (lote_id, etapa, severidade, registro, mensagem, dado)
      VALUES (p_lote, 'importar_medidores', 'erro', m ->> 'id',
              'unidade industrial do medidor nao reconhecida: medidor nao importado', m);
      CONTINUE;
    END IF;

    INSERT INTO util.medidor (origem_id, codigo, nome, camm, tipo, unidade, leitura_inicial, ativo)
    VALUES (m ->> 'id',
            m ->> 'id',
            coalesce(nullif(btrim(m ->> 'name'), ''), m ->> 'id'),
            v_camm,
            coalesce(nullif(m ->> 'type', ''), 'agua')::util.medidor_tipo,
            mig.mapear_unidade(m ->> 'type', m ->> 'unit'),
            coalesce(nullif(regexp_replace(coalesce(m ->> 'initial', '0'), '[^0-9.-]', '', 'g'), '')::numeric, 0),
            coalesce((m ->> 'ativo')::boolean, true))
    ON CONFLICT (codigo) DO UPDATE
      SET nome            = EXCLUDED.nome,
          camm            = EXCLUDED.camm,
          leitura_inicial = EXCLUDED.leitura_inicial,
          ativo           = EXCLUDED.ativo,
          origem_id       = coalesce(medidor.origem_id, EXCLUDED.origem_id);
    v_n := v_n + 1;
  END LOOP;

  RETURN v_n;
END $$;
COMMENT ON FUNCTION mig.importar_medidores(uuid) IS 'Importa medidores casando pelo codigo (CAMM1-AGUA-02), que e o mesmo id usado no navegador - por isso os 18 do seed nao duplicam.';

CREATE OR REPLACE FUNCTION mig.importar_leituras(p_lote uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
  v_json jsonb;
  r      jsonb;
  v_med  uuid;
  v_foto uuid;
  v_n    integer := 0;
BEGIN
  SELECT conteudo INTO v_json FROM mig.dump WHERE lote_id = p_lote AND chave = 'readings';
  IF v_json IS NULL THEN RETURN 0; END IF;

  -- Ordem cronologica e obrigatoria: a leitura anterior de cada linha e
  -- calculada pelo banco a partir do que ja esta gravado.
  FOR r IN SELECT value FROM jsonb_array_elements(v_json)
            ORDER BY (value ->> 'at')::timestamptz NULLS LAST LOOP
    SELECT id INTO v_med FROM util.medidor WHERE origem_id = r ->> 'meterId' OR codigo = r ->> 'meterId';
    IF v_med IS NULL THEN
      INSERT INTO mig.ocorrencia (lote_id, etapa, severidade, registro, mensagem, dado)
      VALUES (p_lote, 'importar_leituras', 'erro', r ->> 'id',
              'medidor do apontamento nao existe: leitura nao importada', r);
      CONTINUE;
    END IF;

    v_foto := core.anexo_de_dataurl(r ->> 'photoData', coalesce(r ->> 'photoName', 'leitura'));

    BEGIN
      INSERT INTO util.leitura (origem_id, medidor_id, leitura, anexo_id, observacao,
                                latitude, longitude, responsavel_id, responsavel_nome, medido_em)
      VALUES (r ->> 'id',
              v_med,
              (r ->> 'reading')::numeric,
              v_foto,
              nullif(btrim(coalesce(r ->> 'observation', '')), ''),
              nullif(r ->> 'latitude', '')::numeric,
              nullif(r ->> 'longitude', '')::numeric,
              (SELECT u.id FROM core.usuario u
                WHERE u.email = nullif(lower(btrim(coalesce(r ->> 'user', ''))), '')::citext),
              coalesce(nullif(btrim(r ->> 'user'), ''), 'nao identificado'),
              coalesce((r ->> 'at')::timestamptz, now()))
      ON CONFLICT (origem_id) DO NOTHING;
      v_n := v_n + 1;
    EXCEPTION WHEN others THEN
      INSERT INTO mig.ocorrencia (lote_id, etapa, severidade, registro, mensagem, dado)
      VALUES (p_lote, 'importar_leituras', 'erro', r ->> 'id', SQLERRM, r);
    END;
  END LOOP;

  RETURN v_n;
END $$;
COMMENT ON FUNCTION mig.importar_leituras(uuid) IS 'Importa os apontamentos em ordem cronologica para o banco recalcular leitura anterior e consumo. Linha que quebrar alguma regra e registrada em mig.ocorrencia e a carga continua.';

CREATE OR REPLACE FUNCTION mig.importar_lms(p_lote uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_json jsonb; v_n integer := 0;
BEGIN
  SELECT conteudo INTO v_json FROM mig.dump WHERE lote_id = p_lote AND chave = 'lms';
  IF v_json IS NULL THEN RETURN 0; END IF;

  INSERT INTO lms.treinamento (origem_id, codigo, titulo, categoria, descricao, obrigatorio,
                               validade_meses, prazo_dias, ativo)
  SELECT t ->> 'id',
         coalesce(nullif(t ->> 'code', ''), 'TR-' || left(md5(t ->> 'id'), 6)),
         t ->> 'title',
         nullif(t ->> 'category', ''),
         nullif(t ->> 'description', ''),
         coalesce((t ->> 'mandatory')::boolean, false),
         -- 0 no dado antigo significa "sem validade": vira NULL
         nullif(coalesce((t ->> 'validity_months')::int, 0), 0)::smallint,
         coalesce(nullif((t ->> 'deadline_days')::int, 0), 30)::smallint,
         coalesce((t ->> 'active')::boolean, true)
    FROM jsonb_array_elements(coalesce(v_json -> 'trainings', '[]'::jsonb)) AS t
  ON CONFLICT (origem_id) DO UPDATE
    SET titulo = EXCLUDED.titulo, categoria = EXCLUDED.categoria,
        obrigatorio = EXCLUDED.obrigatorio, ativo = EXCLUDED.ativo;

  INSERT INTO lms.versao (origem_id, treinamento_id, numero, status, minutos_minimos,
                          nota_corte, tentativas_maximas, publicado_em)
  SELECT v ->> 'id', t.id,
         coalesce((v ->> 'version_no')::int, 1)::smallint,
         CASE WHEN v ->> 'status' = 'publicada' THEN 'publicada' ELSE 'rascunho' END::lms.versao_status,
         coalesce((v ->> 'min_minutes')::int, 0)::smallint,
         coalesce((v ->> 'pass_score')::int, 70)::smallint,
         coalesce((v ->> 'max_attempts')::int, 3)::smallint,
         CASE WHEN v ->> 'status' = 'publicada' THEN now() ELSE NULL END
    FROM jsonb_array_elements(coalesce(v_json -> 'versions', '[]'::jsonb)) AS v
    JOIN lms.treinamento t ON t.origem_id = v ->> 'training_id'
  ON CONFLICT (origem_id) DO UPDATE
    SET minutos_minimos = EXCLUDED.minutos_minimos,
        nota_corte = EXCLUDED.nota_corte,
        tentativas_maximas = EXCLUDED.tentativas_maximas;

  INSERT INTO lms.aula (origem_id, versao_id, posicao, titulo, tipo, obrigatoria,
                        segundos_minimos, corpo, url)
  SELECT l ->> 'id', v.id,
         coalesce((l ->> 'position')::int, 1)::smallint,
         l ->> 'title',
         CASE lower(coalesce(l ->> 'kind', 'texto'))
           WHEN 'texto'         THEN 'texto'
           WHEN 'video'         THEN 'video_youtube'
           WHEN 'video_youtube' THEN 'video_youtube'
           WHEN 'video_arquivo' THEN 'video_arquivo'
           WHEN 'pdf'           THEN 'pdf'
           WHEN 'imagem'        THEN 'imagem'
           WHEN 'link'          THEN 'link'
           ELSE 'texto'
         END::lms.aula_tipo,
         coalesce((l ->> 'required')::boolean, true),
         coalesce((l ->> 'min_seconds')::int, 0),
         -- aula de texto sem corpo violaria o CHECK: entra marcada
         CASE WHEN lower(coalesce(l ->> 'kind', 'texto')) = 'texto'
              THEN coalesce(nullif(btrim(l ->> 'body'), ''), '(conteudo nao migrado)')
              ELSE nullif(btrim(l ->> 'body'), '') END,
         nullif(btrim(coalesce(l ->> 'video', l ->> 'url', '')), '')
    FROM jsonb_array_elements(coalesce(v_json -> 'lessons', '[]'::jsonb)) AS l
    JOIN lms.versao v ON v.origem_id = l ->> 'version_id'
  ON CONFLICT (origem_id) DO UPDATE
    SET titulo = EXCLUDED.titulo, corpo = EXCLUDED.corpo, url = EXCLUDED.url,
        segundos_minimos = EXCLUDED.segundos_minimos;

  INSERT INTO lms.avaliacao (origem_id, versao_id, titulo)
  SELECT q ->> 'id', v.id, coalesce(nullif(q ->> 'title', ''), 'Avaliacao')
    FROM jsonb_array_elements(coalesce(v_json -> 'quizzes', '[]'::jsonb)) AS q
    JOIN lms.versao v ON v.origem_id = q ->> 'version_id'
  ON CONFLICT (origem_id) DO UPDATE SET titulo = EXCLUDED.titulo;

  INSERT INTO lms.questao (origem_id, avaliacao_id, posicao, tipo, peso, enunciado)
  SELECT q ->> 'id', a.id,
         coalesce((q ->> 'position')::int, 1)::smallint,
         CASE lower(coalesce(q ->> 'kind', 'unica')) WHEN 'multipla' THEN 'multipla' ELSE 'unica' END::lms.questao_tipo,
         coalesce((q ->> 'weight')::numeric, 1),
         q ->> 'statement'
    FROM jsonb_array_elements(coalesce(v_json -> 'questions', '[]'::jsonb)) AS q
    JOIN lms.avaliacao a ON a.origem_id = q ->> 'quiz_id'
  ON CONFLICT (origem_id) DO UPDATE SET enunciado = EXCLUDED.enunciado, peso = EXCLUDED.peso;

  INSERT INTO lms.questao_opcao (origem_id, questao_id, posicao, texto, correta)
  SELECT o ->> 'id', qq.id, ord::smallint, o ->> 'label',
         coalesce((o ->> 'is_correct')::boolean, false)
    FROM jsonb_array_elements(coalesce(v_json -> 'questions', '[]'::jsonb)) AS q
    JOIN lms.questao qq ON qq.origem_id = q ->> 'id'
    CROSS JOIN LATERAL jsonb_array_elements(coalesce(q -> 'options', '[]'::jsonb))
                       WITH ORDINALITY AS t(o, ord)
  ON CONFLICT (origem_id) DO UPDATE SET texto = EXCLUDED.texto, correta = EXCLUDED.correta;

  -- matriculas: o id de usuario do modelo antigo e o id OU o e-mail
  WITH ins AS (
    INSERT INTO lms.matricula (origem_id, treinamento_id, versao_id, usuario_id, obrigatoria,
                               status, prazo_em, iniciado_em)
    SELECT e ->> 'id', t.id, v.id, u.id,
           coalesce((e ->> 'mandatory')::boolean, false),
           CASE lower(coalesce(e ->> 'status', ''))
             WHEN 'nao_iniciado'    THEN 'nao_iniciada'
             WHEN 'em_andamento'    THEN 'em_andamento'
             WHEN 'aguardando_quiz' THEN 'aguardando_avaliacao'
             WHEN 'concluido'       THEN 'concluida'
             WHEN 'reprovado'       THEN 'reprovada'
             ELSE 'nao_iniciada'
           END::lms.matricula_status,
           nullif(e ->> 'due_at', '')::timestamptz,
           nullif(e ->> 'started_at', '')::timestamptz
      FROM jsonb_array_elements(coalesce(v_json -> 'enrollments', '[]'::jsonb)) AS e
      JOIN lms.treinamento t ON t.origem_id = e ->> 'training_id'
      JOIN lms.versao      v ON v.origem_id = e ->> 'version_id'
      JOIN core.usuario    u ON u.origem_id = e ->> 'user_id'
                             OR u.email = nullif(e ->> 'user_id', '')::citext
      -- matricula da mesma pessoa na mesma versao pode ja ter sido criada pela
      -- reconciliacao de grupo; nesse caso a linha do dump nao entra de novo
     WHERE NOT EXISTS (SELECT 1 FROM lms.matricula mm
                        WHERE mm.usuario_id = u.id AND mm.versao_id = v.id
                          AND mm.origem_id IS DISTINCT FROM e ->> 'id')
    ON CONFLICT (origem_id) DO UPDATE SET status = EXCLUDED.status
    RETURNING 1
  ) SELECT count(*) INTO v_n FROM ins;

  INSERT INTO lms.progresso_aula (matricula_id, aula_id, segundos_assistidos,
                                  confirmou_leitura, concluido_em)
  SELECT m.id, a.id,
         coalesce((p ->> 'seconds_watched')::int, 0),
         coalesce((p ->> 'acknowledged')::boolean, false),
         nullif(p ->> 'completed_at', '')::timestamptz
    FROM jsonb_array_elements(coalesce(v_json -> 'progress', '[]'::jsonb)) AS p
    JOIN lms.matricula m ON m.origem_id = p ->> 'enrollment_id'
    JOIN lms.aula      a ON a.origem_id = p ->> 'lesson_id'
  ON CONFLICT (matricula_id, aula_id) DO UPDATE
    SET segundos_assistidos = greatest(progresso_aula.segundos_assistidos, EXCLUDED.segundos_assistidos),
        confirmou_leitura   = progresso_aula.confirmou_leitura OR EXCLUDED.confirmou_leitura,
        concluido_em        = coalesce(progresso_aula.concluido_em, EXCLUDED.concluido_em);

  INSERT INTO lms.tentativa (matricula_id, avaliacao_id, numero, nota, aprovado, finalizado_em)
  SELECT m.id, a.id,
         coalesce((t ->> 'attempt_no')::int, 1)::smallint,
         round(coalesce((t ->> 'score')::numeric, 0), 2),
         coalesce((t ->> 'passed')::boolean, false),
         coalesce((t ->> 'finished_at')::timestamptz, now())
    FROM jsonb_array_elements(coalesce(v_json -> 'attempts', '[]'::jsonb)) AS t
    JOIN lms.matricula m ON m.origem_id = t ->> 'enrollment_id'
    JOIN lms.avaliacao a ON a.origem_id = t ->> 'quiz_id'
  ON CONFLICT (matricula_id, numero) DO NOTHING;

  INSERT INTO lms.conclusao (origem_id, matricula_id, codigo_comprovante, concluido_em,
                             aproveitamento, valido_ate, evidencia, motivo_manual)
  SELECT c ->> 'id', m.id,
         coalesce(nullif(c ->> 'certificate_code', ''), 'BT-' || upper(left(md5(c ->> 'id'), 10))),
         coalesce((c ->> 'completed_at')::timestamptz, now()),
         round(coalesce((c ->> 'score')::numeric, 0), 2),
         nullif(c ->> 'expires_at', '')::timestamptz,
         CASE WHEN coalesce(c ->> 'evidence', 'automatica') = 'automatica' THEN 'automatica' ELSE 'manual' END,
         CASE WHEN coalesce(c ->> 'evidence', 'automatica') = 'automatica' THEN NULL
              ELSE coalesce(nullif(c ->> 'manual_reason', ''), 'lancamento manual migrado') END
    FROM jsonb_array_elements(coalesce(v_json -> 'completions', '[]'::jsonb)) AS c
    JOIN lms.matricula m ON m.origem_id = c ->> 'enrollment_id'
  ON CONFLICT (origem_id) DO NOTHING;

  RETURN v_n;
END $$;
COMMENT ON FUNCTION mig.importar_lms(uuid) IS 'Importa o modulo de treinamentos inteiro (conteudo, matriculas, progresso, tentativas e comprovantes) a partir da chave lms do dump bruto.';

CREATE OR REPLACE FUNCTION mig.registrar_treinamentos_antigos(p_lote uuid) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE v_t jsonb; v_p jsonb; v_n integer := 0;
BEGIN
  SELECT conteudo INTO v_t FROM mig.dump WHERE lote_id = p_lote AND chave = 'trainings_v8';
  SELECT conteudo INTO v_p FROM mig.dump WHERE lote_id = p_lote AND chave = 'training_progress_v8';
  IF v_t IS NULL AND v_p IS NULL THEN RETURN 0; END IF;

  -- O modelo antigo guardava so um percentual por pessoa/treinamento, sem aula,
  -- sem avaliacao e sem evidencia. Transformar 100% em comprovante seria inventar
  -- aprovacao que ninguem registrou, entao o dado fica anotado para decisao humana.
  INSERT INTO mig.ocorrencia (lote_id, etapa, severidade, mensagem, dado)
  VALUES (p_lote, 'treinamentos_antigos', 'aviso',
          'Catalogo e percentuais do modelo antigo (V8) nao foram convertidos em matricula/conclusao: sem aula, avaliacao nem evidencia nao ha como comprovar. Decidir caso a caso e, se preciso, lancar conclusao manual com motivo.',
          jsonb_build_object('trainings', coalesce(v_t, '[]'::jsonb),
                             'progress',  coalesce(v_p, '{}'::jsonb)));
  v_n := 1;
  RETURN v_n;
END $$;
COMMENT ON FUNCTION mig.registrar_treinamentos_antigos(uuid) IS 'Preserva no banco o catalogo e os percentuais do LMS antigo (V8) como ocorrencia, sem inventar conclusao a partir de percentual solto.';

-- 15.4 sequenciais e orquestracao -----------------------------------------------------
CREATE OR REPLACE FUNCTION mig.sincronizar_sequencias() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_sci bigint; v_scm bigint;
BEGIN
  -- Reposiciona o contador no maior numero JA usado, para o proximo codigo
  -- gerado depois da virada nao colidir com codigo importado.
  SELECT coalesce(max(nullif(regexp_replace(codigo, '\D', '', 'g'), '')::bigint), 0)
    INTO v_sci FROM almox.sci;
  SELECT coalesce(max(nullif(regexp_replace(codigo, '\D', '', 'g'), '')::bigint), 0)
    INTO v_scm FROM almox.scm;

  UPDATE core.sequencia SET ultimo_valor = greatest(ultimo_valor, v_sci), atualizado_em = now()
   WHERE escopo = 'sci';
  UPDATE core.sequencia SET ultimo_valor = greatest(ultimo_valor, v_scm), atualizado_em = now()
   WHERE escopo = 'scm';

  RETURN jsonb_build_object('sci', v_sci, 'scm', v_scm);
END $$;
COMMENT ON FUNCTION mig.sincronizar_sequencias() IS 'Depois da importacao, empurra core.sequencia para o maior numero existente em SCI e SCM. Sem isso a primeira solicitacao criada na plataforma nova tentaria repetir SCI-0001.';

CREATE OR REPLACE FUNCTION mig.importar_tudo(p_lote uuid) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_res jsonb;
BEGIN
  -- A ordem importa: perfil antes de usuario, grupo antes de usuario,
  -- usuario antes de solicitacao, medidor antes de leitura.
  v_res := jsonb_build_object(
    'perfis',        mig.importar_perfis(p_lote),
    'grupos',        mig.importar_grupos(p_lote),
    'usuarios',      mig.importar_usuarios(p_lote),
    'responsaveis',  mig.vincular_responsaveis(p_lote),
    'familias',      mig.importar_familias(p_lote),
    'sci',           mig.importar_sci(p_lote),
    'scm',           mig.importar_scm(p_lote),
    'medidores',     mig.importar_medidores(p_lote),
    'leituras',      mig.importar_leituras(p_lote),
    'lms',           mig.importar_lms(p_lote),
    'lms_antigo',    mig.registrar_treinamentos_antigos(p_lote),
    'sequencias',    mig.sincronizar_sequencias(),
    'matriculas',    lms.sincronizar_matriculas()
  );

  UPDATE mig.lote SET importado_em = now(), resultado = v_res WHERE id = p_lote;

  INSERT INTO core.rotina_execucao (rotina, fim, sucesso, detalhe)
  VALUES ('mig.importar_tudo', now(), true, v_res::text);

  RETURN v_res;
END $$;
COMMENT ON FUNCTION mig.importar_tudo(uuid) IS 'Roda a importacao completa na ordem correta de dependencia e devolve a contagem por modulo. Reexecutar o mesmo lote e seguro (tudo casa por origem_id).';


-- =====================================================================================
-- 16. ROTULOS DE STATUS
--   Os rotulos ficam no banco para tela, e-mail e exportacao dizerem a mesma coisa.
-- =====================================================================================
CREATE OR REPLACE FUNCTION almox.sci_status_rotulo(p almox.sci_status) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p
    WHEN 'pendente_aprovacao'  THEN 'Pendente de aprovacao'
    WHEN 'revisao_solicitante' THEN 'Aguardando revisao do solicitante'
    WHEN 'em_compra'           THEN 'Em compra'
    WHEN 'aguardando_cadastro' THEN 'Aguardando o cadastro de item'
    WHEN 'cadastrado'          THEN 'Cadastrado'
    WHEN 'reprovada'           THEN 'Reprovada'
  END;
$$;
COMMENT ON FUNCTION almox.sci_status_rotulo(almox.sci_status) IS 'Rotulo de exibicao do status da SCI, exatamente como ficou definido em reuniao.';

CREATE OR REPLACE FUNCTION almox.scm_status_rotulo(p almox.scm_status) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p
    WHEN 'pendente_aprovacao_lider' THEN 'Pendente aprovacao do lider'
    WHEN 'aprovada'                 THEN 'Aprovada'
    WHEN 'reprovada'                THEN 'Reprovada'
    WHEN 'revisao_solicitada'       THEN 'Revisao solicitada'
    WHEN 'em_tratativa'             THEN 'Em tratativa (almoxarife)'
    WHEN 'concluida'                THEN 'Concluida'
  END;
$$;


-- =====================================================================================
-- 17. VIEWS DAS TELAS (schema app)
-- =====================================================================================

-- 17.1 acesso -------------------------------------------------------------------------
CREATE OR REPLACE VIEW app.vw_perfil_permissoes AS
SELECT p.id                                                    AS perfil_id,
       p.nome,
       p.fixo,
       p.ativo,
       coalesce(jsonb_object_agg(x.area, x.mapa) FILTER (WHERE x.area IS NOT NULL),
                '{}'::jsonb)                                   AS permissoes
  FROM core.perfil p
  LEFT JOIN (
        SELECT pp.perfil_id,
               pm.area,
               jsonb_object_agg(split_part(pm.chave, '.', 2), true) AS mapa
          FROM core.perfil_permissao pp
          JOIN core.permissao pm ON pm.chave = pp.permissao_chave
         GROUP BY pp.perfil_id, pm.area
       ) x ON x.perfil_id = p.id
 GROUP BY p.id, p.nome, p.fixo, p.ativo;
COMMENT ON VIEW app.vw_perfil_permissoes IS 'Perfil com as permissoes no mesmo formato de objeto que as telas ja consomem. Permissao ausente significa nao concedida (a tela le como falso), entao a view nao precisa emitir false para tudo.';

CREATE OR REPLACE VIEW app.vw_usuario AS
SELECT u.id,
       u.nome,
       u.email,
       u.ativo,
       u.bloqueado,
       u.motivo_bloqueio,
       u.telefone,
       u.tema,
       u.notificacoes,
       u.time,
       u.perfil_id,
       pf.nome                          AS perfil_nome,
       pf.fixo                          AS perfil_fixo,
       u.grupo_id,
       g.nome                           AS grupo_nome,
       g.area                           AS grupo_area,
       resp.id                          AS responsavel_id,
       resp.nome                        AS responsavel_nome,
       resp.email                       AS responsavel_email,
       u.email_lider_excecao,
       vp.permissoes,
       u.ultimo_login_em,
       (u.entra_object_id IS NOT NULL)  AS vinculado_entra_id,
       u.criado_em
  FROM core.usuario u
  JOIN core.perfil  pf ON pf.id = u.perfil_id
  LEFT JOIN core.grupo   g    ON g.id = u.grupo_id
  LEFT JOIN core.usuario resp ON resp.id = g.responsavel_id
  LEFT JOIN app.vw_perfil_permissoes vp ON vp.perfil_id = u.perfil_id;
COMMENT ON VIEW app.vw_usuario IS 'Linha completa do usuario para a tela de cadastro e para o app decidir menu: perfil, permissoes, grupo e responsavel direto, tudo resolvido.';

CREATE OR REPLACE VIEW app.vw_aprovador_de AS
SELECT u.id                                         AS usuario_id,
       u.nome                                       AS usuario_nome,
       u.email                                      AS usuario_email,
       g.nome                                       AS grupo_nome,
       CASE
         WHEN resp.id IS NOT NULL AND resp.ativo THEN resp.email
         WHEN u.email_lider_excecao IS NOT NULL  THEN u.email_lider_excecao
         ELSE NULL
       END                                          AS aprovador_email,
       CASE
         WHEN resp.id IS NOT NULL AND resp.ativo THEN resp.nome
         WHEN u.email_lider_excecao IS NOT NULL  THEN u.email_lider_excecao::text
         ELSE NULL
       END                                          AS aprovador_nome,
       CASE
         WHEN resp.id IS NOT NULL AND resp.ativo THEN 'grupo'
         WHEN u.email_lider_excecao IS NOT NULL  THEN 'excecao'
         ELSE 'nenhum'
       END                                          AS origem
  FROM core.usuario u
  LEFT JOIN core.grupo   g    ON g.id = u.grupo_id AND g.ativo
  LEFT JOIN core.usuario resp ON resp.id = g.responsavel_id;
COMMENT ON VIEW app.vw_aprovador_de IS 'Quem aprova a solicitacao de cada pessoa. Ordem: responsavel do grupo, depois o e-mail de lider por excecao, depois ninguem. E daqui que a SCM copia aprovador_email na criacao; origem = nenhum e a lista do que falta configurar.';

CREATE OR REPLACE VIEW app.vw_login_permitido AS
SELECT a.email,
       a.ativo                AS autorizacao_ativa,
       a.perfil_padrao,
       a.grupo_padrao,
       u.id                   AS usuario_id,
       u.nome                 AS usuario_nome,
       u.ativo                AS usuario_ativo,
       u.bloqueado,
       c.permitido,
       c.motivo
  FROM core.email_autorizado a
  LEFT JOIN core.usuario u ON u.email = a.email
  CROSS JOIN LATERAL core.pode_autenticar(a.email) c;
COMMENT ON VIEW app.vw_login_permitido IS 'Estado de acesso de cada e-mail liberado: se entra hoje e, quando nao entra, por que. Usada na tela de gestao de acesso e no diagnostico de "nao consigo logar".';

-- 17.2 almoxarifado - SCI -------------------------------------------------------------
CREATE OR REPLACE VIEW app.vw_sci AS
SELECT s.id,
       s.codigo,
       s.status,
       almox.sci_status_rotulo(s.status)                     AS status_rotulo,
       f.id                                                  AS familia_id,
       f.nome                                                AS familia_nome,
       s.solicitante_id,
       s.solicitante_nome,
       su.email                                              AS solicitante_email,
       s.numero_solicitacao_cadastro,
       s.codigo_item,
       s.observacoes,
       s.observacao_almoxarife,
       s.marcas_homologadas,
       s.link,
       (s.foto_anexo_id IS NOT NULL)                         AS tem_foto,
       s.foto_anexo_id,
       s.criado_em,
       s.atualizado_em,
       date_part('day', now() - s.criado_em)::int            AS dias_aberta,
       s.status IN ('cadastrado', 'reprovada')               AS encerrada,
       (SELECT count(*) FROM almox.sci_historico h WHERE h.sci_id = s.id) AS transicoes,
       s.aviso_solicitante_em,
       s.aviso_solicitante_lido
  FROM almox.sci s
  JOIN almox.familia f ON f.id = s.familia_id
  LEFT JOIN core.usuario su ON su.id = s.solicitante_id;
COMMENT ON VIEW app.vw_sci IS 'Lista de SCI para as telas de acompanhamento: status com rotulo, familia, solicitante, numeros de referencia e tempo em aberto.';

CREATE OR REPLACE VIEW app.vw_sci_campos AS
SELECT s.id            AS sci_id,
       s.codigo,
       fc.posicao,
       fc.chave,
       fc.rotulo,
       fc.obrigatorio,
       v.valor
  FROM almox.sci s
  JOIN almox.familia_campo fc ON fc.familia_id = s.familia_id
  LEFT JOIN almox.sci_valor_campo v ON v.sci_id = s.id AND v.campo_id = fc.id
 ORDER BY s.codigo, fc.posicao;
COMMENT ON VIEW app.vw_sci_campos IS 'Campos dinamicos de cada SCI em ordem de formulario, com o valor preenchido. Campo criado depois da solicitacao aparece vazio, o que e a informacao correta.';

CREATE OR REPLACE VIEW app.vw_sci_fila_almoxarifado AS
SELECT *
  FROM app.vw_sci
 WHERE status IN ('pendente_aprovacao', 'em_compra', 'aguardando_cadastro')
 ORDER BY criado_em;
COMMENT ON VIEW app.vw_sci_fila_almoxarifado IS 'Fila de trabalho do almoxarifado: o que depende dele, mais antigo primeiro. Revisao do solicitante nao entra porque a bola esta com o solicitante.';

CREATE OR REPLACE VIEW app.vw_sci_pendencia_dado AS
SELECT s.id, s.codigo, s.status, s.solicitante_nome, s.criado_em,
       'SCI em Cadastrado sem codigo do item' AS pendencia
  FROM almox.sci s
 WHERE s.status = 'cadastrado' AND nullif(btrim(s.codigo_item), '') IS NULL
UNION ALL
SELECT s.id, s.codigo, s.status, s.solicitante_nome, s.criado_em,
       'SCI em revisao do solicitante sem observacao do almoxarife'
  FROM almox.sci s
 WHERE s.status = 'revisao_solicitante' AND nullif(btrim(s.observacao_almoxarife), '') IS NULL
UNION ALL
SELECT s.id, s.codigo, s.status, s.solicitante_nome, s.criado_em,
       'SCI sem solicitante vinculado a um usuario'
  FROM almox.sci s
 WHERE s.solicitante_id IS NULL;
COMMENT ON VIEW app.vw_sci_pendencia_dado IS 'Lista de trabalho pos-migracao: as solicitacoes antigas as quais falta um dado que o fluxo novo exige. Existe porque a importacao preferiu trazer o registro incompleto a descartar historico.';

-- 17.3 almoxarifado - SCM -------------------------------------------------------------
CREATE OR REPLACE VIEW app.vw_scm AS
SELECT s.id,
       s.codigo,
       s.status,
       almox.scm_status_rotulo(s.status)          AS status_rotulo,
       s.urgencia,
       initcap(s.urgencia::text)                  AS urgencia_rotulo,
       s.camm,
       s.time_solicitante,
       s.tipo_solicitacao,
       s.capex_projeto,
       cc.nome                                    AS centro_custo,
       s.numero_om,
       s.tipo_fornecedor,
       s.nome_fornecedor,
       s.tipo_pedido,
       s.descricao_uso,
       s.solicitante_id,
       s.solicitante_nome,
       s.solicitante_email,
       s.solicitante_time,
       s.aprovador_email,
       s.aprovador_origem,
       s.decidido_por_id,
       dp.nome                                    AS decidido_por_nome,
       s.decidido_em,
       s.observacao_lider,
       s.observacao_almoxarife,
       s.numero_processo_me,
       it.itens,
       it.quantidade_total,
       (SELECT count(*) FROM almox.scm_anexo a WHERE a.scm_id = s.id) AS anexos,
       (SELECT count(*) FROM almox.scm_link  l WHERE l.scm_id = s.id) AS links,
       s.criado_em,
       s.atualizado_em,
       date_part('day', now() - s.criado_em)::int AS dias_aberta
  FROM almox.scm s
  LEFT JOIN almox.centro_custo cc ON cc.id = s.centro_custo_id
  LEFT JOIN core.usuario       dp ON dp.id = s.decidido_por_id
  CROSS JOIN LATERAL (
        SELECT count(*)::int AS itens, coalesce(sum(i.quantidade), 0) AS quantidade_total
          FROM almox.scm_item i WHERE i.scm_id = s.id
       ) it;
COMMENT ON VIEW app.vw_scm IS 'Lista de SCM com tudo que a tela mostra sem abrir a solicitacao: status, urgencia, centro de custo, aprovador, quem decidiu e a contagem de itens e anexos.';

CREATE OR REPLACE VIEW app.vw_scm_itens AS
SELECT s.id AS scm_id, s.codigo, i.posicao, i.codigo_sistema, i.descricao,
       i.quantidade, i.estoque_minimo, i.marca_modelo_serie
  FROM almox.scm s
  JOIN almox.scm_item i ON i.scm_id = s.id
 ORDER BY s.codigo, i.posicao;
COMMENT ON VIEW app.vw_scm_itens IS 'Itens das SCM, um por linha, para a tela de detalhe e para exportacao ao almoxarifado.';

CREATE OR REPLACE VIEW app.vw_scm_fila_aprovacao AS
SELECT *
  FROM app.vw_scm
 WHERE status = 'pendente_aprovacao_lider'
 ORDER BY CASE urgencia WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END, criado_em;
COMMENT ON VIEW app.vw_scm_fila_aprovacao IS 'Fila de aprovacao. A tela filtra por aprovador_email igual ao e-mail de quem esta logado; a ordem ja vem por urgencia e antiguidade.';

-- 17.4 utilidades ---------------------------------------------------------------------
CREATE OR REPLACE VIEW app.vw_medidor_apontavel AS
SELECT m.id, m.codigo, m.nome, m.camm, m.tipo, m.unidade, m.leitura_inicial,
       coalesce(u.leitura, m.leitura_inicial) AS leitura_atual,
       u.medido_em                            AS ultima_leitura_em,
       (m.tipo = 'horimetro')                 AS foto_obrigatoria
  FROM util.medidor m
  LEFT JOIN LATERAL (
        SELECT l.leitura, l.medido_em
          FROM util.leitura l
         WHERE l.medidor_id = m.id
         ORDER BY l.medido_em DESC, l.criado_em DESC
         LIMIT 1
       ) u ON true
 WHERE m.ativo
 ORDER BY m.camm, m.tipo, m.codigo;
COMMENT ON VIEW app.vw_medidor_apontavel IS 'Medidores que aparecem para quem aponta: somente ativos, ja com a leitura anterior e o aviso de foto obrigatoria do horimetro.';

CREATE OR REPLACE VIEW app.vw_medidor_painel AS
SELECT m.id, m.codigo, m.nome, m.camm, m.tipo, m.unidade, m.ativo,
       u.leitura                              AS ultima_leitura,
       u.consumo                              AS ultimo_consumo,
       u.medido_em                            AS ultima_leitura_em,
       u.responsavel_nome                     AS ultimo_responsavel,
       (u.anexo_id IS NOT NULL)               AS ultima_com_foto,
       tot.leituras,
       tot.consumo_30d,
       CASE WHEN u.medido_em IS NULL THEN 'sem leitura'
            WHEN u.medido_em < now() - interval '35 days' THEN 'atrasado'
            ELSE 'em dia' END                 AS situacao_apontamento
  FROM util.medidor m
  LEFT JOIN LATERAL (
        SELECT l.* FROM util.leitura l
         WHERE l.medidor_id = m.id
         ORDER BY l.medido_em DESC, l.criado_em DESC
         LIMIT 1
       ) u ON true
  CROSS JOIN LATERAL (
        SELECT count(*)::int AS leituras,
               coalesce(sum(l.consumo) FILTER (WHERE l.medido_em >= now() - interval '30 days'), 0) AS consumo_30d
          FROM util.leitura l WHERE l.medidor_id = m.id
       ) tot;
COMMENT ON VIEW app.vw_medidor_painel IS 'Painel de medidores: ultima leitura, consumo, evidencia, consumo dos ultimos 30 dias e se o apontamento esta atrasado.';

CREATE OR REPLACE VIEW app.vw_leitura_historico AS
SELECT l.id,
       m.codigo                       AS medidor_codigo,
       m.nome                         AS medidor_nome,
       m.camm,
       m.tipo,
       m.unidade,
       l.leitura_anterior,
       l.leitura,
       l.consumo,
       l.observacao,
       (l.anexo_id IS NOT NULL)       AS tem_foto,
       l.anexo_id,
       l.latitude,
       l.longitude,
       l.responsavel_id,
       l.responsavel_nome,
       l.medido_em,
       l.criado_em
  FROM util.leitura l
  JOIN util.medidor m ON m.id = l.medidor_id
 ORDER BY l.medido_em DESC;
COMMENT ON VIEW app.vw_leitura_historico IS 'Historico de apontamentos para a lista mestre do PCM: medidor, CAMM, tipo, leitura anterior, leitura, consumo, evidencia e responsavel.';

CREATE OR REPLACE VIEW app.vw_util_desvio AS
WITH base AS (
  SELECT l.id, l.medidor_id, l.leitura, l.leitura_anterior, l.consumo, l.anexo_id,
         l.medido_em, l.responsavel_nome,
         m.codigo AS medidor_codigo, m.nome AS medidor_nome, m.camm, m.tipo, m.unidade,
         lead(l.leitura) OVER (PARTITION BY l.medidor_id ORDER BY l.medido_em, l.criado_em) AS leitura_seguinte
    FROM util.leitura l
    JOIN util.medidor m ON m.id = l.medidor_id
), referencia AS (
  -- Mediana, e nao media: com media o proprio salto puxa a referencia para cima
  -- e se esconde. Um consumo de 790 entre valores de 10 tem mediana 10 e salta
  -- a vista; com media ele passaria por normal.
  SELECT medidor_id,
         (percentile_cont(0.5) WITHIN GROUP (ORDER BY consumo::double precision))::numeric(14,3) AS mediana
    FROM util.leitura
   WHERE consumo > 0
   GROUP BY medidor_id
)
SELECT b.id                       AS leitura_id,
       b.medidor_codigo,
       b.medidor_nome,
       b.camm,
       b.tipo,
       b.unidade,
       b.leitura_anterior,
       b.leitura,
       b.consumo,
       r.mediana                  AS consumo_mediana,
       b.medido_em,
       b.responsavel_nome,
       d.tipo                     AS desvio,
       d.detalhe,
       coalesce(t.situacao, 'aberto') AS situacao,
       t.nota                     AS nota_tratativa,
       t.analisado_em
  FROM base b
  LEFT JOIN referencia r ON r.medidor_id = b.medidor_id
  CROSS JOIN LATERAL (VALUES
      -- consumo negativo nao entra mais por CHECK; fica no criterio para
      -- pegar linha antiga e para o dia em que a regra for relaxada
      ('consumo_negativo'::util.desvio_tipo,
       b.consumo IS NOT NULL AND b.consumo < 0,
       'consumo negativo'),
      ('leitura_seguinte_menor',
       b.leitura_seguinte IS NOT NULL AND b.leitura_seguinte < b.leitura,
       'a leitura seguinte deste medidor e menor que esta'),
      ('salto_consumo',
       r.mediana IS NOT NULL AND r.mediana > 0 AND b.consumo IS NOT NULL AND b.consumo > r.mediana * 3,
       'consumo acima de 3x a mediana do medidor'),
      ('consumo_zero',
       b.leitura_anterior IS NOT NULL AND b.consumo = 0,
       'consumo zero com leitura anterior existente'),
      ('horimetro_sem_foto',
       b.tipo = 'horimetro' AND b.anexo_id IS NULL,
       'horimetro sem foto do marcador')
    ) AS d(tipo, aplica, detalhe)
  LEFT JOIN util.desvio_tratativa t ON t.leitura_id = b.id AND t.tipo = d.tipo
 WHERE d.aplica;
COMMENT ON VIEW app.vw_util_desvio IS 'Deteccao de desvio para o PCM, uma linha por (leitura, tipo de desvio): consumo negativo, leitura seguinte menor, salto acima de 3x a mediana, consumo zero e horimetro sem foto. Calculada na hora - nada de tabela de desvio desatualizada.';

-- 17.5 treinamentos -------------------------------------------------------------------
CREATE OR REPLACE VIEW app.vw_lms_matricula AS
SELECT m.id                                   AS matricula_id,
       m.usuario_id,
       u.nome                                  AS colaborador,
       u.email                                 AS colaborador_email,
       u.time,
       g.nome                                  AS grupo_nome,
       t.id                                    AS treinamento_id,
       t.codigo                                AS treinamento_codigo,
       t.titulo                                AS treinamento,
       t.categoria,
       m.obrigatoria,
       v.numero                                AS versao,
       v.nota_corte,
       v.tentativas_maximas,
       m.tentativas_liberadas,
       m.status,
       m.bloqueada,
       m.prazo_em,
       m.iniciado_em,
       m.concluido_em,
       a.aulas_obrigatorias,
       a.aulas_concluidas,
       tt.tentativas,
       tt.melhor_nota,
       c.codigo_comprovante,
       c.aproveitamento,
       c.valido_ate,
       CASE
         WHEN c.id IS NOT NULL THEN 100
         WHEN a.aulas_obrigatorias = 0 THEN 0
         ELSE round((a.aulas_concluidas::numeric / a.aulas_obrigatorias)
                    * CASE WHEN av.id IS NOT NULL THEN 90 ELSE 100 END)
       END                                     AS percentual,
       (av.id IS NOT NULL)                     AS tem_avaliacao
  FROM lms.matricula m
  JOIN core.usuario     u ON u.id = m.usuario_id
  JOIN lms.treinamento  t ON t.id = m.treinamento_id
  JOIN lms.versao       v ON v.id = m.versao_id
  LEFT JOIN core.grupo  g ON g.id = u.grupo_id
  LEFT JOIN lms.avaliacao av ON av.versao_id = m.versao_id
  LEFT JOIN lms.conclusao  c ON c.matricula_id = m.id
  CROSS JOIN LATERAL (
        SELECT count(*)::int AS aulas_obrigatorias,
               count(p.concluido_em)::int AS aulas_concluidas
          FROM lms.aula al
          LEFT JOIN lms.progresso_aula p ON p.aula_id = al.id AND p.matricula_id = m.id
         WHERE al.versao_id = m.versao_id AND al.obrigatoria
       ) a
  CROSS JOIN LATERAL (
        SELECT count(*)::int AS tentativas, max(x.nota) AS melhor_nota
          FROM lms.tentativa x WHERE x.matricula_id = m.id
       ) tt;
COMMENT ON VIEW app.vw_lms_matricula IS 'Uma linha por matricula com colaborador, time, grupo/cargo, versao, progresso e comprovante. Percentual segue a regra da tela: aulas obrigatorias valem 90% quando existe avaliacao, e a avaliacao fecha os 10% restantes.';

CREATE OR REPLACE VIEW app.vw_lms_conformidade AS
SELECT vm.usuario_id,
       vm.colaborador,
       vm.colaborador_email,
       vm.time,
       vm.grupo_nome,
       vm.treinamento_id,
       vm.treinamento,
       vm.matricula_id,
       vm.status,
       vm.prazo_em,
       vm.valido_ate,
       vm.percentual,
       CASE
         WHEN vm.codigo_comprovante IS NOT NULL
              AND (vm.valido_ate IS NULL OR vm.valido_ate > now()) THEN 'em_dia'
         WHEN vm.codigo_comprovante IS NOT NULL                    THEN 'vencido'
         WHEN vm.bloqueada                                         THEN 'bloqueado'
         WHEN vm.status = 'reprovada'                              THEN 'reprovado'
         WHEN vm.prazo_em IS NOT NULL AND vm.prazo_em < now()      THEN 'atrasado'
         ELSE 'pendente'
       END AS situacao
  FROM app.vw_lms_matricula vm
 WHERE vm.obrigatoria;
COMMENT ON VIEW app.vw_lms_conformidade IS 'Conformidade dos treinamentos obrigatorios: em dia, vencido, atrasado, reprovado, bloqueado ou pendente. Base do indicador de treinamento por pessoa.';

CREATE OR REPLACE VIEW app.vw_lms_visao_lider AS
SELECT g.responsavel_id                AS lider_id,
       resp.email                      AS lider_email,
       vm.*
  FROM app.vw_lms_matricula vm
  JOIN core.usuario     u    ON u.id = vm.usuario_id
  JOIN core.grupo       g    ON g.id = u.grupo_id AND g.ativo
  JOIN core.usuario     resp ON resp.id = g.responsavel_id;
COMMENT ON VIEW app.vw_lms_visao_lider IS 'Visao gerencial de treinamentos filtrada pelo responsavel do grupo: a tela filtra por lider_email e pode cruzar com colaborador, time e grupo/cargo. Quem nao e responsavel de grupo nao ve ninguem por esta view.';

CREATE OR REPLACE VIEW app.vw_lms_bloqueada AS
SELECT vm.matricula_id, vm.colaborador, vm.colaborador_email, vm.treinamento,
       vm.tentativas, vm.melhor_nota, vm.nota_corte,
       vm.tentativas_maximas + vm.tentativas_liberadas AS limite_atual,
       m.bloqueada_em,
       (SELECT count(*) FROM lms.liberacao l WHERE l.matricula_id = vm.matricula_id) AS liberacoes_anteriores
  FROM app.vw_lms_matricula vm
  JOIN lms.matricula m ON m.id = vm.matricula_id
 WHERE vm.bloqueada
 ORDER BY m.bloqueada_em;
COMMENT ON VIEW app.vw_lms_bloqueada IS 'Matriculas travadas por esgotar as tentativas, aguardando liberacao do administrador. Mostra quantas vezes a pessoa ja foi liberada antes.';

-- 17.6 operacao -----------------------------------------------------------------------
CREATE OR REPLACE VIEW app.vw_email_fila_pendente AS
SELECT id, destinatario, remetente, assunto, motivo, referencia_tabela, referencia_id,
       tentativas, criado_em
  FROM core.email_fila
 WHERE status = 'pendente'
 ORDER BY criado_em;
COMMENT ON VIEW app.vw_email_fila_pendente IS 'O que a rotina do Microsoft Graph precisa enviar. Fila vazia com e-mail nao chegando significa problema na aplicacao; fila cheia significa problema no envio.';

CREATE OR REPLACE VIEW app.vw_estoque_saldo AS
SELECT i.id AS item_id, i.codigo_item, i.descricao, i.unidade, i.estoque_minimo,
       coalesce(sum(mv.quantidade), 0)                                   AS saldo,
       coalesce(sum(mv.quantidade), 0) < i.estoque_minimo                AS abaixo_do_minimo,
       max(mv.em)                                                        AS ultimo_movimento
  FROM pcm.item_estoque i
  LEFT JOIN pcm.movimento_estoque mv ON mv.item_id = i.id
 WHERE i.ativo
 GROUP BY i.id, i.codigo_item, i.descricao, i.unidade, i.estoque_minimo;
COMMENT ON VIEW app.vw_estoque_saldo IS 'Saldo de estoque somando os movimentos, com o alerta de abaixo do minimo. Etapa posterior (PCM), mas a view ja define como o saldo sera lido: sempre calculado.';

CREATE OR REPLACE VIEW app.vw_saude_operacional AS
SELECT (SELECT count(*) FROM core.usuario WHERE ativo AND NOT bloqueado)                    AS usuarios_ativos,
       (SELECT count(*) FROM core.grupo WHERE ativo AND responsavel_id IS NULL)             AS grupos_sem_responsavel,
       (SELECT count(*) FROM almox.sci WHERE status NOT IN ('cadastrado', 'reprovada'))     AS sci_em_aberto,
       (SELECT count(*) FROM almox.scm WHERE status = 'pendente_aprovacao_lider')           AS scm_aguardando_aprovacao,
       (SELECT count(*) FROM app.vw_sci_pendencia_dado)                                     AS sci_com_dado_faltando,
       (SELECT count(*) FROM app.vw_util_desvio WHERE situacao = 'aberto')                  AS desvios_abertos,
       (SELECT count(*) FROM util.medidor m WHERE m.ativo
          AND NOT EXISTS (SELECT 1 FROM util.leitura l
                           WHERE l.medidor_id = m.id AND l.medido_em >= now() - interval '35 days'))
                                                                                            AS medidores_sem_leitura_recente,
       (SELECT count(*) FROM app.vw_lms_conformidade WHERE situacao IN ('atrasado', 'vencido')) AS treinamentos_irregulares,
       (SELECT count(*) FROM core.email_fila WHERE status = 'pendente')                     AS emails_pendentes,
       (SELECT count(*) FROM core.email_fila WHERE status = 'erro')                         AS emails_com_erro,
       (SELECT max(inicio) FROM core.rotina_execucao WHERE rotina = 'backup' AND sucesso)    AS ultimo_backup_ok;
COMMENT ON VIEW app.vw_saude_operacional IS 'Uma linha com o estado do sistema. Feita para quem mantem sozinho: responde em uma query se algo precisa de atencao hoje, incluindo se o backup rodou.';

-- 17.7 conferencia da migracao --------------------------------------------------------
CREATE OR REPLACE VIEW mig.vw_conferencia AS
SELECT l.id AS lote_id, l.arquivo, l.carregado_em, l.importado_em, x.entidade,
       x.no_dump, x.no_banco,
       CASE WHEN x.no_dump = x.no_banco THEN 'ok' ELSE 'conferir' END AS resultado
  FROM mig.lote l
  CROSS JOIN LATERAL (
    VALUES
      ('usuarios',  (SELECT jsonb_array_length(d.conteudo) FROM mig.dump d WHERE d.lote_id = l.id AND d.chave = 'users'),
                    (SELECT count(*)::int FROM core.usuario WHERE origem_id IS NOT NULL)),
      ('perfis',    (SELECT jsonb_array_length(d.conteudo) FROM mig.dump d WHERE d.lote_id = l.id AND d.chave = 'profiles'),
                    (SELECT count(*)::int FROM core.perfil)),
      ('grupos',    (SELECT jsonb_array_length(d.conteudo) FROM mig.dump d WHERE d.lote_id = l.id AND d.chave = 'grupos'),
                    (SELECT count(*)::int FROM core.grupo WHERE origem_id IS NOT NULL)),
      ('familias',  (SELECT jsonb_array_length(d.conteudo) FROM mig.dump d WHERE d.lote_id = l.id AND d.chave = 'families'),
                    (SELECT count(*)::int FROM almox.familia)),
      ('sci',       (SELECT jsonb_array_length(d.conteudo) FROM mig.dump d WHERE d.lote_id = l.id AND d.chave = 'sci'),
                    (SELECT count(*)::int FROM almox.sci WHERE origem_id IS NOT NULL)),
      ('scm',       (SELECT jsonb_array_length(d.conteudo) FROM mig.dump d WHERE d.lote_id = l.id AND d.chave = 'scm'),
                    (SELECT count(*)::int FROM almox.scm WHERE origem_id IS NOT NULL)),
      ('medidores', (SELECT jsonb_array_length(d.conteudo) FROM mig.dump d WHERE d.lote_id = l.id AND d.chave = 'meters'),
                    (SELECT count(*)::int FROM util.medidor)),
      ('leituras',  (SELECT jsonb_array_length(d.conteudo) FROM mig.dump d WHERE d.lote_id = l.id AND d.chave = 'readings'),
                    (SELECT count(*)::int FROM util.leitura WHERE origem_id IS NOT NULL))
  ) AS x(entidade, no_dump, no_banco);
COMMENT ON VIEW mig.vw_conferencia IS 'Confronto entre quantidade no dump e quantidade no banco por entidade. E o aceite da virada: linha marcada como conferir tem explicacao em mig.ocorrencia.';


-- =====================================================================================
-- 18. PRIVILEGIOS
--   A aplicacao (biotrop_app) escreve o que o fluxo pede e NAO ve o gabarito da
--   avaliacao. biotrop_ro le tudo, menos o gabarito, para relatorio e conferencia.
-- =====================================================================================
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'biotrop_app') THEN
    GRANT USAGE ON SCHEMA core, almox, util, lms, pcm, app, mig TO biotrop_app;

    GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core, almox, util, pcm TO biotrop_app;
    GRANT SELECT ON ALL TABLES IN SCHEMA app TO biotrop_app;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA core, almox, util, lms, pcm TO biotrop_app;

    -- Trilha de auditoria e log de login sao append-only para a aplicacao: quem
    -- pode reescrever o log pode apagar o proprio rastro.
    REVOKE UPDATE, DELETE ON core.auditoria    FROM biotrop_app;
    REVOKE UPDATE, DELETE ON core.login_evento FROM biotrop_app;

    -- LMS tabela por tabela, porque questao_opcao e a excecao
    GRANT SELECT, INSERT, UPDATE, DELETE ON lms.treinamento, lms.versao, lms.aula,
      lms.avaliacao, lms.questao, lms.atribuicao, lms.matricula, lms.progresso_aula,
      lms.tentativa, lms.tentativa_resposta, lms.liberacao, lms.conclusao TO biotrop_app;

    -- Gabarito: a role da aplicacao nao recebe SELECT na coluna correta. Sem isso,
    -- qualquer "select *" acabaria mandando a resposta certa para o navegador.
    GRANT SELECT (id, questao_id, posicao, texto) ON lms.questao_opcao TO biotrop_app;
    GRANT INSERT, UPDATE, DELETE ON lms.questao_opcao TO biotrop_app;

    GRANT EXECUTE ON FUNCTION lms.corrigir_tentativa(uuid, jsonb) TO biotrop_app;
    GRANT EXECUTE ON FUNCTION lms.registrar_progresso(uuid, uuid, integer, boolean) TO biotrop_app;
    GRANT EXECUTE ON FUNCTION lms.liberar_matricula(uuid, text, uuid, smallint) TO biotrop_app;
    GRANT EXECUTE ON FUNCTION lms.sincronizar_matriculas() TO biotrop_app;
    GRANT EXECUTE ON FUNCTION core.pode_autenticar(citext) TO biotrop_app;
    GRANT EXECUTE ON FUNCTION core.proximo_codigo(text) TO biotrop_app;
    GRANT EXECUTE ON FUNCTION core.anexo_de_dataurl(text, text, uuid) TO biotrop_app;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'biotrop_ro') THEN
    GRANT USAGE ON SCHEMA core, almox, util, lms, pcm, app, mig TO biotrop_ro;
    GRANT SELECT ON ALL TABLES IN SCHEMA core, almox, util, pcm, app, mig TO biotrop_ro;
    GRANT SELECT ON lms.treinamento, lms.versao, lms.aula, lms.avaliacao, lms.questao,
      lms.atribuicao, lms.matricula, lms.progresso_aula, lms.tentativa,
      lms.tentativa_resposta, lms.liberacao, lms.conclusao TO biotrop_ro;
    GRANT SELECT (id, questao_id, posicao, texto) ON lms.questao_opcao TO biotrop_ro;
  END IF;
END $$;

-- Objetos criados em migrations futuras herdam os mesmos privilegios, para ninguem
-- descobrir tabela sem GRANT depois do deploy.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'biotrop_app') THEN
    ALTER DEFAULT PRIVILEGES IN SCHEMA core, almox, util, pcm
      GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO biotrop_app;
    ALTER DEFAULT PRIVILEGES IN SCHEMA app
      GRANT SELECT ON TABLES TO biotrop_app;
    ALTER DEFAULT PRIVILEGES IN SCHEMA core, almox, util, lms, pcm
      GRANT USAGE, SELECT ON SEQUENCES TO biotrop_app;
  END IF;
END $$;


-- =====================================================================================
-- 19. REGISTRO DESTA MIGRATION
-- =====================================================================================
INSERT INTO core.migration (versao, nome, observacao) VALUES
  ('0001', 'base',
   'Esquema inicial: acesso com Entra ID e lista de autorizados, grupos com responsavel, SCI, SCM, utilidades, treinamentos, tabelas previstas de PCM, maquinario de migracao do localStorage e views das telas.')
ON CONFLICT (versao) DO NOTHING;

-- =====================================================================================
-- FIM. Proximos passos operacionais (fora do DDL):
--   1) criar o banco e rodar este arquivo;
--   2) SELECT mig.carregar_dump(...) e SELECT mig.importar_tudo(...) com o dump do navegador;
--   3) SELECT * FROM mig.vw_conferencia e SELECT * FROM mig.ocorrencia;
--   4) apontar responsavel em core.grupo onde estiver nulo (app.vw_aprovador_de mostra);
--   5) revisar core.email_autorizado antes de liberar o acesso externo;
--   6) agendar na VM: pg_dump diario, envio da fila core.email_fila via Graph e
--      SELECT lms.sincronizar_matriculas() de madrugada (rede de seguranca dos triggers);
--   7) quando a virada estiver aceita: DROP SCHEMA mig CASCADE (o dump ja esta no backup).
-- =====================================================================================
