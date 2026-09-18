-- BIOTROP V3-Base · master data + multiuser sync hardening
-- Idempotent. No destructive data migration.
BEGIN;
CREATE SCHEMA IF NOT EXISTS core;
CREATE TABLE IF NOT EXISTS core.camm_catalogo (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), codigo text NOT NULL UNIQUE, nome text NOT NULL,
 posicao smallint NOT NULL DEFAULT 0, ativo boolean NOT NULL DEFAULT true,
 criado_em timestamptz NOT NULL DEFAULT now(), atualizado_em timestamptz NOT NULL DEFAULT now()
);
INSERT INTO core.camm_catalogo(codigo,nome,posicao)
VALUES ('CAMM 1','CAMM 1',1),('CAMM 2','CAMM 2',2),('CAMM 3','CAMM 3',3),('C. LOG','C. LOG',4)
ON CONFLICT(codigo) DO NOTHING;
CREATE TABLE IF NOT EXISTS core.lista_catalogo (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), lista text NOT NULL, codigo text NOT NULL, nome text NOT NULL,
 posicao smallint NOT NULL DEFAULT 0, ativo boolean NOT NULL DEFAULT true, metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
 criado_em timestamptz NOT NULL DEFAULT now(), atualizado_em timestamptz NOT NULL DEFAULT now(),
 UNIQUE(lista,codigo)
);
CREATE INDEX IF NOT EXISTS ix_lista_catalogo_lista ON core.lista_catalogo(lista,ativo,posicao,nome);
INSERT INTO core.lista_catalogo(lista,codigo,nome,posicao) VALUES
 ('scm_time','Elétrica e Automação','Elétrica e Automação',1),('scm_time','Predial','Predial',2),('scm_time','Mecânica','Mecânica',3),
 ('scm_time','PCM','PCM',4),('scm_time','Almoxarifado','Almoxarifado',5),('scm_time','Time CAMM 03','Time CAMM 03',6),('scm_time','Outra','Outra',99),
 ('scm_tipo_solicitacao','normal','Normal',1),('scm_tipo_solicitacao','emergencial','Emergencial',2),('scm_tipo_solicitacao','melhoria_capex','Melhoria/CAPEX',3),
 ('scm_urgencia','baixa','Baixa',1),('scm_urgencia','media','Média',2),('scm_urgencia','alta','Alta',3),
 ('scm_tipo_fornecedor','normal','Normal',1),('scm_tipo_fornecedor','escolhido','Escolhido',2),('scm_tipo_fornecedor','exclusivo','Exclusivo',3),
 ('scm_tipo_pedido','compra_material','Compra de Material',1),('scm_tipo_pedido','contratacao_servico_pcm','Contratação de Serviço (PCM)',2),
 ('scm_tipo_pedido','solicitacao_manutencao_externa','Solicitação de Manutenção Externa',3)
ON CONFLICT(lista,codigo) DO NOTHING;
CREATE TABLE IF NOT EXISTS core.camm_centro_custo (
 camm_codigo text NOT NULL REFERENCES core.camm_catalogo(codigo) ON UPDATE CASCADE,
 centro_custo_id smallint NOT NULL REFERENCES almox.centro_custo(id) ON DELETE CASCADE,
 posicao smallint NOT NULL DEFAULT 0, ativo boolean NOT NULL DEFAULT true,
 PRIMARY KEY(camm_codigo,centro_custo_id)
);
ALTER TABLE app.sync_registro ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.sync_registro FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sync_registro_select ON app.sync_registro;
CREATE POLICY sync_registro_select ON app.sync_registro FOR SELECT USING (
 app.usuario_ativo() AND (
  namespace IN ('utility_meters','utility_readings')
  OR (namespace='sci' AND (
   app.tem_perfil(ARRAY['admin','gestor','pcm','almoxarife','viewer'])
   OR NULLIF(payload->>'solicitanteId','')::uuid=app.usuario_atual()
   OR app.eh_do_meu_grupo(NULLIF(payload->>'solicitanteId','')::uuid)
  ))
  OR (namespace='scm' AND (
   app.tem_perfil(ARRAY['admin','gestor','pcm','almoxarife','viewer'])
   OR NULLIF(payload->>'solicitanteId','')::uuid=app.usuario_atual()
   OR NULLIF(payload->>'aprovadorId','')::uuid=app.usuario_atual()
   OR app.eh_do_meu_grupo(NULLIF(payload->>'solicitanteId','')::uuid)
  ))
 )
);
DROP POLICY IF EXISTS sync_registro_insert ON app.sync_registro;
CREATE POLICY sync_registro_insert ON app.sync_registro FOR INSERT WITH CHECK (
 app.usuario_ativo() AND (
  namespace IN ('utility_meters','utility_readings')
  OR (namespace='sci' AND (app.tem_perfil(ARRAY['admin','gestor','almoxarife','pcm']) OR NULLIF(payload->>'solicitanteId','')::uuid=app.usuario_atual()))
  OR (namespace='scm' AND (app.tem_perfil(ARRAY['admin','gestor']) OR NULLIF(payload->>'solicitanteId','')::uuid=app.usuario_atual()))
 )
);
DROP POLICY IF EXISTS sync_registro_update ON app.sync_registro;
CREATE POLICY sync_registro_update ON app.sync_registro FOR UPDATE
USING (
 app.usuario_ativo() AND (
  namespace IN ('utility_meters','utility_readings')
  OR (namespace='sci' AND (app.tem_perfil(ARRAY['admin','gestor','almoxarife','pcm']) OR NULLIF(payload->>'solicitanteId','')::uuid=app.usuario_atual()))
  OR (namespace='scm' AND (app.tem_perfil(ARRAY['admin','gestor']) OR NULLIF(payload->>'solicitanteId','')::uuid=app.usuario_atual() OR NULLIF(payload->>'aprovadorId','')::uuid=app.usuario_atual()))
 )
)
WITH CHECK (
 app.usuario_ativo() AND (
  namespace IN ('utility_meters','utility_readings')
  OR (namespace='sci' AND (app.tem_perfil(ARRAY['admin','gestor','almoxarife','pcm']) OR NULLIF(payload->>'solicitanteId','')::uuid=app.usuario_atual()))
  OR (namespace='scm' AND (app.tem_perfil(ARRAY['admin','gestor']) OR NULLIF(payload->>'solicitanteId','')::uuid=app.usuario_atual() OR NULLIF(payload->>'aprovadorId','')::uuid=app.usuario_atual()))
 )
);
DROP POLICY IF EXISTS sync_registro_delete ON app.sync_registro;
CREATE POLICY sync_registro_delete ON app.sync_registro FOR DELETE USING (
 app.usuario_ativo() AND (
  app.tem_perfil(ARRAY['admin','gestor'])
  OR (namespace IN ('utility_meters','utility_readings') AND NULLIF(payload->>'usuarioId','')::uuid=app.usuario_atual())
  OR (namespace IN ('sci','scm') AND NULLIF(payload->>'solicitanteId','')::uuid=app.usuario_atual())
 )
);
COMMIT;