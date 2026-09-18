const APPROVER_PROFILES = new Set(['admin','gestor','lider']);
const ALMOX_PROFILES = new Set(['admin','gestor','almoxarife']);
const ADMIN_PROFILES = new Set(['admin','gestor']);
function text(v){ return v==null?'':String(v).trim(); }
function lower(v){ return text(v).toLowerCase(); }
function sameId(a,b){ return text(a)!=='' && text(a)===text(b); }
function roleIn(actor,set){ return set.has(text(actor?.perfilId)); }
function statusOf(p){ return text(p?.status)||'pendente_aprovacao_lider'; }
function forbidden(message){ const e=new Error(message); e.statusCode=403; throw e; }
function normalizeStatus(v){
  const m={'Pendente Aprovação Líder':'pendente_aprovacao_lider','Aprovada':'aprovada','Reprovada':'reprovada','Revisão Solicitada':'revisao_solicitada','Em Tratativa (Almoxarife)':'em_tratativa','Concluída':'concluida'};
  return m[text(v)]||text(v);
}
function normalizeUrgency(v){
  const m={'Baixa':'baixa','Média':'media','Alta':'alta','baixa':'baixa','media':'media','alta':'alta'};
  return m[text(v)]||'media';
}
async function loadActor(client,session){
  const r=await client.query(
    'SELECT u.id::text AS id,u.nome,u.email::text AS email,u.perfil_id AS "perfilId",u.time,u.ativo,u.bloqueado,u.grupo_id::text AS "grupoId",u.email_lider_excecao::text AS "emailLiderExcecao",g.responsavel_id::text AS "responsavelId" FROM core.usuario u LEFT JOIN core.grupo g ON g.id=u.grupo_id WHERE u.id=$1 LIMIT 1',
    [String(session.sub)]
  );
  const a=r.rows[0];
  if(!a||!a.ativo||a.bloqueado) forbidden('Usuário inativo ou bloqueado.');
  return a;
}
async function loadApprover(client,id,email){
  const r=await client.query(
    'SELECT u.id::text AS id,u.nome,u.email::text AS email,u.perfil_id AS "perfilId",u.ativo,u.bloqueado FROM core.usuario u WHERE ($1::uuid IS NOT NULL AND u.id=$1::uuid) OR ($2::text<>'''' AND lower(u.email::text)=lower($2::text)) LIMIT 1',
    [id?String(id):null,text(email)]
  );
  return r.rows[0]||null;
}
async function resolveApprover(client,actor,requested){
  const rid=text(requested?.aprovadorId), remail=lower(requested?.aprovadorEmail);
  let a=null;
  if(rid||remail){
    a=await loadApprover(client,rid||null,remail);
    if(!a) forbidden('Aprovador informado não existe.');
    if(rid&&!sameId(rid,a.id)) forbidden('Aprovador inconsistente.');
    if(remail&&lower(a.email)!==remail) forbidden('E-mail do aprovador inconsistente.');
  } else if(actor.responsavelId) a=await loadApprover(client,actor.responsavelId,'');
  else if(actor.emailLiderExcecao) a=await loadApprover(client,null,actor.emailLiderExcecao);
  if(!a) forbidden('O grupo do solicitante não possui responsável definido.');
  if(!a.ativo||a.bloqueado) forbidden('O aprovador está inativo ou bloqueado.');
  if(!APPROVER_PROFILES.has(text(a.perfilId))) forbidden('O aprovador não possui perfil de aprovação.');
  if(sameId(a.id,actor.id)) forbidden('O solicitante não pode aprovar a própria SCM.');
  return {id:a.id,email:a.email,nome:a.nome,origem:actor.responsavelId&&sameId(actor.responsavelId,a.id)?'grupo':'excecao'};
}
function immutableChanged(c,n,k){ return text(c?.[k])!==text(n?.[k]); }
function approverCanDecide(actor,current){ return sameId(current?.aprovadorId,actor.id)&&roleIn(actor,APPROVER_PROFILES); }
function requester(actor,current){ return sameId(current?.solicitanteId,actor.id); }

async function authorizeScmMutation({client,session,currentPayload,nextPayload,deleted}){
  const actor=await loadActor(client,session);
  const current=currentPayload||null;
  const next={...(nextPayload||{})};
  if(deleted){
    if(!roleIn(actor,ADMIN_PROFILES)) forbidden('Somente admin/gestor pode excluir o registro de sincronização.');
    return next;
  }
  if(!current){
    if(next.solicitanteId&&!sameId(next.solicitanteId,actor.id)) forbidden('Solicitante inválido.');
    const a=await resolveApprover(client,actor,next);
    next.solicitanteId=actor.id; next.solicitanteNome=actor.nome; next.solicitanteEmail=actor.email; next.solicitanteTime=actor.time||'';
    next.aprovadorId=a.id; next.aprovadorEmail=a.email; next.aprovadorNome=a.nome; next.aprovadorOrigem=a.origem;
    next.status='pendente_aprovacao_lider'; next.decididoPorId=null; next.decididoEm=null;
    return next;
  }
  const cs=statusOf(current), ns=normalizeStatus(next.status||cs);
  const admin=roleIn(actor,ADMIN_PROFILES), approver=approverCanDecide(actor,current), own=requester(actor,current), almox=roleIn(actor,ALMOX_PROFILES);
  if(!admin&&immutableChanged(current,next,'solicitanteId')) forbidden('Solicitante não pode ser alterado.');
  if(!admin&&immutableChanged(current,next,'aprovadorId')) forbidden('Aprovador não pode ser alterado.');
  if(admin){
    if(next.aprovadorId||next.aprovadorEmail){
      const a=await resolveApprover(client,actor,next);
      next.aprovadorId=a.id; next.aprovadorEmail=a.email; next.aprovadorNome=a.nome; next.aprovadorOrigem=a.origem;
    }
    next.status=ns; return next;
  }
  if(approver){
    if(cs!=='pendente_aprovacao_lider'||!['aprovada','reprovada','revisao_solicitada'].includes(ns)) forbidden('Transição de aprovação inválida.');
    if(['reprovada','revisao_solicitada'].includes(ns)&&!text(next.observacaoLider)) forbidden('Observação obrigatória para reprovar ou solicitar revisão.');
    next.status=ns; next.decididoPorId=actor.id; next.decididoEm=new Date().toISOString(); return next;
  }
  if(own){
    if(cs==='revisao_solicitada'&&ns==='pendente_aprovacao_lider'){
      const a=await resolveApprover(client,actor,current);
      next.status='pendente_aprovacao_lider'; next.aprovadorId=a.id; next.aprovadorEmail=a.email; next.aprovadorNome=a.nome; next.aprovadorOrigem=a.origem;
      next.decididoPorId=null; next.decididoEm=null; return next;
    }
    if(ns!==cs) forbidden('Solicitante não pode decidir a própria SCM.');
    if(immutableChanged(current,next,'decididoPorId')||immutableChanged(current,next,'decididoEm')) forbidden('Solicitante não pode preencher dados da decisão.');
    next.status=cs; return next;
  }
  if(almox){
    if(!((cs==='aprovada'&&ns==='em_tratativa')||(cs==='em_tratativa'&&ns==='concluida'))&&ns!==cs) forbidden('Transição de almoxarifado inválida.');
    next.status=ns; return next;
  }
  if(ns!==cs) forbidden('Perfil sem permissão para alterar o status da SCM.');
  next.status=cs; return next;
}

async function syncScmToDatabase({client,session,payload,currentPayload}){
  const code=text(payload.codigo); if(!code) forbidden('SCM sem código.');
  const originId=text(payload.id)||code, camm=text(payload.camm);
  if(!['CAMM 1','CAMM 2','CAMM 3'].includes(camm)) forbidden('CAMM inválido.');
  const a=await loadApprover(client,payload.aprovadorId||null,payload.aprovadorEmail||'');
  if(!a) forbidden('Aprovador não encontrado.');
  const status=normalizeStatus(payload.status), urgency=normalizeUrgency(payload.urgencia);
  const r=await client.query(
    'INSERT INTO almox.scm(origin_id,codigo,time_solicitante,tipo_solicitacao,capex_projeto,camm,urgencia,numero_om,tipo_fornecedor,nome_fornecedor,tipo_pedido,descricao_uso,solicitante_id,solicitante_nome,solicitante_email,solicitante_time,aprovador_id,aprovador_email,aprovador_origem,status,decidido_por_id,decidido_em,observacao_lider,observacao_almoxarife,numero_processo_me,atualizado_em) VALUES($1,$2,$3,$4,$5,$6::core.camm,$7::almox.urgencia,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20::almox.scm_status,$21,$22,$23,$24,$25,now()) ON CONFLICT(origin_id) DO UPDATE SET codigo=EXCLUDED.codigo,time_solicitante=EXCLUDED.time_solicitante,tipo_solicitacao=EXCLUDED.tipo_solicitacao,capex_projeto=EXCLUDED.capex_projeto,camm=EXCLUDED.camm,urgencia=EXCLUDED.urgencia,numero_om=EXCLUDED.numero_om,tipo_fornecedor=EXCLUDED.tipo_fornecedor,nome_fornecedor=EXCLUDED.nome_fornecedor,tipo_pedido=EXCLUDED.tipo_pedido,descricao_uso=EXCLUDED.descricao_uso,solicitante_id=EXCLUDED.solicitante_id,solicitante_nome=EXCLUDED.solicitante_nome,solicitante_email=EXCLUDED.solicitante_email,solicitante_time=EXCLUDED.solicitante_time,aprovador_id=EXCLUDED.aprovador_id,aprovador_email=EXCLUDED.aprovador_email,aprovador_origem=EXCLUDED.aprovador_origem,status=EXCLUDED.status,decidido_por_id=EXCLUDED.decidido_por_id,decidido_em=EXCLUDED.decidido_em,observacao_lider=EXCLUDED.observacao_lider,observacao_almoxarife=EXCLUDED.observacao_almoxarife,numero_processo_me=EXCLUDED.numero_processo_me,atualizado_em=now() RETURNING id',
    [originId,code,text(payload.timeSolicitante)||'Não informado',text(payload.tipoSolicitacao)||null,text(payload.capexProjeto)||null,camm,urgency,text(payload.numeroOM)||null,text(payload.tipoFornecedor)||null,text(payload.nomeFornecedor)||null,text(payload.tipoPedido)||null,text(payload.descricaoUso)||'Sem descrição',payload.solicitanteId,text(payload.solicitanteNome),text(payload.solicitanteEmail)||null,text(payload.solicitanteTime)||null,a.id,a.email,text(payload.aprovadorOrigem)||'grupo',status,payload.decididoPorId||null,payload.decididoEm||null,text(payload.observacaoLider)||null,text(payload.observacaoAlmoxarife)||null,text(payload.numeroProcessoME)||null]
  );
  const scmId=r.rows[0].id;
  await client.query('DELETE FROM almox.scm_item WHERE scm_id=$1',[scmId]);
  const items=Array.isArray(payload.itens)?payload.itens.slice(0,100):[];
  for(let i=0;i<items.length;i++){
    const item=items[i]||{}, qty=Number(String(item.quantidade??'').replace(',','.'));
    if(!Number.isFinite(qty)||qty<=0) forbidden('Quantidade de item inválida.');
    await client.query('INSERT INTO almox.scm_item(scm_id,posicao,codigo_sistema,descricao,quantidade,estoque_minimo,marca_modelo_serie) VALUES($1,$2,$3,$4,$5,$6,$7)',
      [scmId,i+1,text(item.codigoSistema)||'SEM-CODIGO',text(item.descricaoItem)||null,qty,Number.isFinite(Number(item.estoqueMinimo))?Number(item.estoqueMinimo):null,text(item.marcaModeloSerie)||null]);
  }
  const prev=normalizeStatus(currentPayload?.status||'');
  if(prev&&prev!==status) await client.query('INSERT INTO almox.scm_historico(scm_id,de,para,por_usuario_id,por_nome,nota) VALUES($1,$2::almox.scm_status,$3::almox.scm_status,$4,$5,$6)',
    [scmId,prev,status,String(session.sub),text(payload.decididoPorNome||payload.solicitanteNome),text(payload.observacaoLider||payload.observacaoAlmoxarife)]);
  else if(!prev) await client.query('INSERT INTO almox.scm_historico(scm_id,de,para,por_usuario_id,por_nome,nota) VALUES($1,NULL,$2::almox.scm_status,$3,$4,$5)',
    [scmId,status,String(session.sub),text(payload.solicitanteNome),text(payload.observacaoLider||'')]);
}

module.exports={authorizeScmMutation,syncScmToDatabase};
