-- BIOTROP V3-Base — hardening do fluxo SCM multiusuário
-- Idempotente. Não apaga dados.
CREATE EXTENSION IF NOT EXISTS citext;
CREATE SCHEMA IF NOT EXISTS almox;
CREATE SCHEMA IF NOT EXISTS app;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE t.typname='camm' AND n.nspname='core') THEN
    CREATE TYPE core.camm AS ENUM ('CAMM 1','CAMM 2','CAMM 3','C. LOG');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE t.typname='urgencia' AND n.nspname='almox') THEN
    CREATE TYPE almox.urgencia AS ENUM ('baixa','media','alta');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE t.typname='scm_status' AND n.nspname='almox') THEN
    CREATE TYPE almox.scm_status AS ENUM ('pendente_aprovacao_lider','aprovada','reprovada','revisao_solicitada','em_tratativa','concluida');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS core.grupo(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),origem_id text UNIQUE,codigo text NOT NULL UNIQUE,nome text NOT NULL,area text,responsavel_id uuid,ativo boolean NOT NULL DEFAULT true,criado_em timestamptz NOT NULL DEFAULT now(),atualizado_em timestamptz NOT NULL DEFAULT now());
ALTER TABLE core.usuario ADD COLUMN IF NOT EXISTS grupo_id uuid;
ALTER TABLE core.usuario ADD COLUMN IF NOT EXISTS email_lider_excecao citext;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='grupo_responsavel_fk') THEN ALTER TABLE core.grupo ADD CONSTRAINT grupo_responsavel_fk FOREIGN KEY(responsavel_id) REFERENCES core.usuario(id) ON DELETE SET NULL; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='usuario_grupo_fk') THEN ALTER TABLE core.usuario ADD CONSTRAINT usuario_grupo_fk FOREIGN KEY(grupo_id) REFERENCES core.grupo(id) ON DELETE SET NULL; END IF;
END $$;
ALTER TABLE core.email_autorizado ADD COLUMN IF NOT EXISTS perfil_padrao text;
ALTER TABLE core.email_autorizado ADD COLUMN IF NOT EXISTS grupo_padrao uuid;
ALTER TABLE core.email_autorizado ADD COLUMN IF NOT EXISTS motivo text;
ALTER TABLE core.email_autorizado ADD COLUMN IF NOT EXISTS liberado_por uuid;
INSERT INTO core.perfil(id,nome,ativo) VALUES('lider','Líder',true) ON CONFLICT(id) DO UPDATE SET nome=EXCLUDED.nome,ativo=true;

CREATE TABLE IF NOT EXISTS almox.centro_custo(id smallint PRIMARY KEY,nome text NOT NULL UNIQUE);
CREATE TABLE IF NOT EXISTS almox.scm(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),origem_id text UNIQUE,codigo text NOT NULL UNIQUE,time_solicitante text NOT NULL,
 tipo_solicitacao text,capex_projeto text,camm core.camm NOT NULL,urgencia almox.urgencia NOT NULL DEFAULT 'media',
 centro_custo_id smallint REFERENCES almox.centro_custo(id),numero_om text,tipo_fornecedor text,nome_fornecedor text,tipo_pedido text,
 descricao_uso text NOT NULL,solicitante_id uuid REFERENCES core.usuario(id) ON DELETE SET NULL,solicitante_nome text NOT NULL,
 solicitante_email citext,solicitante_time text,aprovador_id uuid REFERENCES core.usuario(id) ON DELETE SET NULL,aprovador_email citext,
 aprovador_origem text,status almox.scm_status NOT NULL DEFAULT 'pendente_aprovacao_lider',decidido_por_id uuid REFERENCES core.usuario(id) ON DELETE SET NULL,
 decidido_em timestamptz,observacao_lider text,observacao_almoxarife text,numero_processo_me text,criado_em timestamptz NOT NULL DEFAULT now(),atualizado_em timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS almox.scm_item(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),scm_id uuid NOT NULL REFERENCES almox.scm(id) ON DELETE CASCADE,posicao smallint NOT NULL DEFAULT 1,codigo_sistema text NOT NULL,descricao text,quantidade numeric(14,3) NOT NULL CHECK(quantidade>0),estoque_minimo numeric(14,3) CHECK(estoque_minimo IS NULL OR estoque_minimo>=0),marca_modelo_serie text,UNIQUE(scm_id,posicao));
CREATE TABLE IF NOT EXISTS almox.scm_historico(id bigserial PRIMARY KEY,scm_id uuid NOT NULL REFERENCES almox.scm(id) ON DELETE CASCADE,de almox.scm_status,para almox.scm_status NOT NULL,por_usuario_id uuid REFERENCES core.usuario(id) ON DELETE SET NULL,por_nome text,nota text,em timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS ix_scm_status ON almox.scm(status,criado_em DESC);
CREATE INDEX IF NOT EXISTS ix_scm_aprovador ON almox.scm(aprovador_id,status);
CREATE INDEX IF NOT EXISTS ix_scm_solicitante ON almox.scm(solicitante_id,criado_em DESC);

CREATE OR REPLACE FUNCTION app.usuario_atual() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT NULLIF(current_setting('app.usuario_id',true),'')::uuid $$;
CREATE OR REPLACE FUNCTION app.usuario_ativo() RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT EXISTS(SELECT 1 FROM core.usuario u WHERE u.id=app.usuario_atual() AND u.ativo AND NOT u.bloqueado) $$;
CREATE OR REPLACE FUNCTION app.tem_perfil(p text[]) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=core,pg_temp AS $$ SELECT EXISTS(SELECT 1 FROM core.usuario u WHERE u.id=app.usuario_atual() AND u.ativo AND NOT u.bloqueado AND u.perfil_id=ANY(p)) $$;
CREATE OR REPLACE FUNCTION app.scm_aprovador_valido(p_solicitante uuid,p_aprovador uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=core,pg_temp AS $$
SELECT EXISTS(SELECT 1 FROM core.usuario s JOIN core.grupo g ON g.id=s.grupo_id JOIN core.usuario a ON a.id=g.responsavel_id WHERE s.id=p_solicitante AND a.id=p_aprovador AND a.ativo AND NOT a.bloqueado)
OR EXISTS(SELECT 1 FROM core.usuario s WHERE s.id=p_solicitante AND s.email_lider_excecao IS NOT NULL AND lower(s.email_lider_excecao::text)=lower((SELECT email::text FROM core.usuario WHERE id=p_aprovador)) AND EXISTS(SELECT 1 FROM core.usuario a WHERE a.id=p_aprovador AND a.ativo AND NOT a.bloqueado));
$$;

CREATE OR REPLACE FUNCTION app.guard_scm_workflow() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=core,almox,app,pg_temp AS $$
DECLARE admin_or_gestor boolean:=app.tem_perfil(ARRAY['admin','gestor']); aprovador boolean:=NEW.aprovador_id=app.usuario_atual(); solicitante boolean:=NEW.solicitante_id=app.usuario_atual(); almoxarife boolean:=app.tem_perfil(ARRAY['almoxarife']);
BEGIN
IF TG_OP='INSERT' THEN
 IF NOT solicitante AND NOT admin_or_gestor THEN RAISE EXCEPTION 'Somente o solicitante pode criar a SCM'; END IF;
 IF NOT admin_or_gestor THEN NEW.solicitante_id:=app.usuario_atual(); NEW.status:='pendente_aprovacao_lider'; NEW.decidido_por_id:=NULL; NEW.decidido_em:=NULL;
  IF NEW.aprovador_id IS NOT NULL AND NOT app.scm_aprovador_valido(NEW.solicitante_id,NEW.aprovador_id) THEN RAISE EXCEPTION 'Aprovador inválido para o solicitante'; END IF;
 END IF;
 RETURN NEW;
END IF;
IF NEW.solicitante_id IS DISTINCT FROM OLD.solicitante_id AND NOT admin_or_gestor THEN RAISE EXCEPTION 'Solicitante não pode ser alterado'; END IF;
IF NEW.aprovador_id IS DISTINCT FROM OLD.aprovador_id AND NOT admin_or_gestor THEN RAISE EXCEPTION 'Aprovador não pode ser alterado'; END IF;
IF NOT admin_or_gestor THEN
 IF solicitante THEN
  IF OLD.status='revisao_solicitada' AND NEW.status='pendente_aprovacao_lider' THEN NULL; ELSIF NEW.status IS DISTINCT FROM OLD.status THEN RAISE EXCEPTION 'Solicitante não pode decidir a própria SCM'; END IF;
  IF NEW.decidido_por_id IS DISTINCT FROM OLD.decidido_por_id OR NEW.decidido_em IS DISTINCT FROM OLD.decidido_em THEN RAISE EXCEPTION 'Solicitante não pode preencher dados da decisão'; END IF;
 ELSIF aprovador THEN
  IF OLD.status<>'pendente_aprovacao_lider' OR NEW.status NOT IN('aprovada','reprovada','revisao_solicitada') THEN RAISE EXCEPTION 'Transição de aprovação inválida'; END IF;
  IF NOT app.scm_aprovador_valido(NEW.solicitante_id,app.usuario_atual()) THEN RAISE EXCEPTION 'Usuário não é o aprovador válido desta SCM'; END IF;
  NEW.decidido_por_id:=app.usuario_atual(); NEW.decidido_em:=now();
  IF NEW.status IN('reprovada','revisao_solicitada') AND nullif(btrim(coalesce(NEW.observacao_lider,'')),'') IS NULL THEN RAISE EXCEPTION 'Observação obrigatória para reprovar ou solicitar revisão'; END IF;
 ELSIF almoxarife THEN
  IF NOT ((OLD.status='aprovada' AND NEW.status='em_tratativa') OR (OLD.status='em_tratativa' AND NEW.status='concluida')) AND NEW.status IS DISTINCT FROM OLD.status THEN RAISE EXCEPTION 'Transição de almoxarifado inválida'; END IF;
 ELSE
  IF NEW.status IS DISTINCT FROM OLD.status THEN RAISE EXCEPTION 'Perfil sem permissão para alterar o status da SCM'; END IF;
 END IF;
END IF;
NEW.atualizado_em:=now(); RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS tg_scm_workflow ON almox.scm;
CREATE TRIGGER tg_scm_workflow BEFORE INSERT OR UPDATE ON almox.scm FOR EACH ROW EXECUTE FUNCTION app.guard_scm_workflow();

ALTER TABLE almox.scm ENABLE ROW LEVEL SECURITY;
ALTER TABLE almox.scm FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS scm_select ON almox.scm;
CREATE POLICY scm_select ON almox.scm FOR SELECT USING(app.usuario_ativo() AND (solicitante_id=app.usuario_atual() OR aprovador_id=app.usuario_atual() OR app.tem_perfil(ARRAY['admin','gestor','almoxarife'])));
DROP POLICY IF EXISTS scm_insert ON almox.scm;
CREATE POLICY scm_insert ON almox.scm FOR INSERT WITH CHECK(app.usuario_ativo() AND solicitante_id=app.usuario_atual() AND status='pendente_aprovacao_lider' AND (aprovador_id IS NULL OR app.scm_aprovador_valido(solicitante_id,aprovador_id)));
DROP POLICY IF EXISTS scm_update ON almox.scm;
CREATE POLICY scm_update ON almox.scm FOR UPDATE USING(app.usuario_ativo() AND (solicitante_id=app.usuario_atual() OR aprovador_id=app.usuario_atual() OR app.tem_perfil(ARRAY['admin','gestor','almoxarife']))) WITH CHECK(app.usuario_ativo() AND (solicitante_id=app.usuario_atual() OR aprovador_id=app.usuario_atual() OR app.tem_perfil(ARRAY['admin','gestor','almoxarife'])));
ALTER TABLE almox.scm_item ENABLE ROW LEVEL SECURITY;
ALTER TABLE almox.scm_item FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS scm_item_select ON almox.scm_item;
CREATE POLICY scm_item_select ON almox.scm_item FOR SELECT USING(EXISTS(SELECT 1 FROM almox.scm s WHERE s.id=scm_id));
DROP POLICY IF EXISTS scm_item_write ON almox.scm_item;
CREATE POLICY scm_item_write ON almox.scm_item FOR ALL USING(EXISTS(SELECT 1 FROM almox.scm s WHERE s.id=scm_id)) WITH CHECK(EXISTS(SELECT 1 FROM almox.scm s WHERE s.id=scm_id));
