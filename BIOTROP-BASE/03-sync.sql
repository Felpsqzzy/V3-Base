-- BIOTROP V3-Base · sincronização multiusuário
-- Executar DEPOIS de 02g-fechamento.sql no PostgreSQL real.
-- Não usa Supabase.

CREATE TABLE IF NOT EXISTS app.sync_registro (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  namespace text NOT NULL,
  record_id text NOT NULL,
  payload jsonb NOT NULL,
  deleted boolean NOT NULL DEFAULT false,
  version bigint NOT NULL DEFAULT 1,
  updated_by text NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(namespace, record_id)
);

CREATE INDEX IF NOT EXISTS idx_sync_registro_ns_updated
  ON app.sync_registro(namespace, updated_at, version);

CREATE INDEX IF NOT EXISTS idx_sync_registro_ns_record
  ON app.sync_registro(namespace, record_id);

ALTER TABLE app.sync_registro ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sync_registro_select ON app.sync_registro;
CREATE POLICY sync_registro_select
  ON app.sync_registro
  FOR SELECT
  USING (NULLIF(current_setting('app.usuario_id', true), '') IS NOT NULL);

DROP POLICY IF EXISTS sync_registro_insert ON app.sync_registro;
CREATE POLICY sync_registro_insert
  ON app.sync_registro
  FOR INSERT
  WITH CHECK (NULLIF(current_setting('app.usuario_id', true), '') IS NOT NULL);

DROP POLICY IF EXISTS sync_registro_update ON app.sync_registro;
CREATE POLICY sync_registro_update
  ON app.sync_registro
  FOR UPDATE
  USING (NULLIF(current_setting('app.usuario_id', true), '') IS NOT NULL)
  WITH CHECK (NULLIF(current_setting('app.usuario_id', true), '') IS NOT NULL);

DROP POLICY IF EXISTS sync_registro_delete ON app.sync_registro;
CREATE POLICY sync_registro_delete
  ON app.sync_registro
  FOR DELETE
  USING (NULLIF(current_setting('app.usuario_id', true), '') IS NOT NULL);

GRANT SELECT, INSERT, UPDATE, DELETE ON app.sync_registro TO biotrop_app;

COMMENT ON TABLE app.sync_registro IS
  'Estado compartilhado da aplicação para sincronização multiusuário. A API controla versionamento otimista e expõe somente os namespaces autorizados.';
COMMENT ON COLUMN app.sync_registro.namespace IS
  'Chave lógica do módulo: sci, scm, utility_meters, utility_readings.';
COMMENT ON COLUMN app.sync_registro.version IS
  'Versão monotônica do registro para detecção de conflito entre usuários.';
