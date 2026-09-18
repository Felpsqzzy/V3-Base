const APPROVER_PROFILES = new Set(['admin','gestor','lider']);
const ALMOX_PROFILES = new Set(['admin','gestor','almoxarife']);
const ADMIN_PROFILES = new Set(['admin','gestor']);

const t = v => v == null ? '' : String(v).trim();
const lo = v => t(v).toLowerCase();
const idEq = (a,b) => t(a) !== '' && t(a) === t(b);
const role = (u,set) => set.has(t(u?.perfilId));
const status = p => t(p?.status) || 'pendente_aprovacao_lider';
const deny = msg => { const e=new Error(msg); e.statusCode=403; throw e; };

function normStatus(v){
  const x=t(v);
  return ({'Pendente Aprovação Líder':'pendente_aprovacao_lider','Aprovada':'aprovada','Reprovada':'reprovada','Revisão Solicitada':'revisao_solicitada','Em Tratativa (Almoxarife)':'em_tratativa','Concluída':'concluida'})[x] || x;
}
function normUrgency(v){
  const x=lo(v).normalize('NFD').replace(/[\u0300-\u036f]/g,'');
  return ({baixa:'baixa',media:'media',alta:'alta'})[x] || 'media';
}
function changed(a,b,k){ return t(a?.[k]) !== t(b?.[k]); }

async function actorOf(client,session){
  const r=await client.query(
    'SELECT u.id::text AS id,u.nome,u.email::text AS email,u.perfil_id AS "perfilId",u.time,u.ativo,u.bloqueado,u.grupo_id::text AS "grupoId",u.email_lider_excecao::text AS "emailLiderExcecao",g.responsavel_id::text AS "responsavelId" FROM core.usuario u LEFT JOIN core.grupo g ON g.id=u.grupo_id WHERE u.id=$1 LIMIT 1',
    [String(session.sub)]
  );
  const a=r.rows[0];
  if(!a || !a.ativo || a.bloqueado) deny('Usuário inativo ou bloqueado.');
  return a;
}
async function approverOf(client,id,email){
  const r=await client.query(
    "SELECT u.id::text AS id,u.nome,u.email::text AS email,u.perfil_id AS \"perfilId\",u.ativo,u.bloqueado FROM core.usuario u WHERE ($1::uuid IS NOT NULL AND u.id=$1::uuid) OR ($2::text<>'' AND lower(u.email::text)=lower($2::text)) LIMIT 1",
    [id?t(id):null,t(email)]
  );
  return r.rows[0] || null;
}
async function resolveApprover(client,actor,requested,allowRequested){
  const rid=t(requested?.aprovadorId), rem=lo(requested?.aprovadorEmail);
  let a=null;
  if(allowRequested && (rid||rem)){
    a=await approverOf(client,rid||null,rem);
    if(!a) deny('Aprovador informado não existe.');
    if(rid&&!idEq(rid,a.id)) deny('Aprovador inconsistente.');
    if(rem&&lo(a.email)!==rem) deny('E-mail do aprovador inconsistente.');
  }else if(actor.responsavelId){
    a=await approverOf(client,actor.responsavelId,'');
  }else if(actor.emailLiderExcecao){
    a=await approverOf(client,null,actor.emailLiderExcecao);
  }
  if(!a) deny('O grupo do solicitante não possui responsável definido.');
  if(!a.ativo||a.bloqueado) deny('O aprovador está inativo ou bloqueado.');
  if(!APPROVER_PROFILES.has(t(a.perfilId))) deny('O aprovador não possui perfil de aprovação.');
  if(idEq(a.id,actor.id)) deny('O solicitante não pode aprovar a própria SCM.');
  return {id:a.id,email:a.email,nome:a.nome,origem:actor.responsavelId&&idEq(actor.responsavelId,a.id)?'grupo':'excecao'};
}

async function authorizeScmMutation({client,session,currentPayload,nextPayload,deleted}){
  const actor=await actorOf(client,session), current=currentPayload||null, next={...(nextPayload||{})};
  if(deleted){
    if(!role(actor,ADMIN_PROFILES)) deny('Somente admin/gestor pode excluir o registro de sincronização.');
    return next;
  }
  if(!current){
    if(next.solicitanteId&&!idEq(next.solicitanteId,actor.id)) deny('Solicitante inválido.');
    const a=await resolveApprover(client,actor,next,false);
    Object.assign(next,{solicitanteId:actor.id,solicitanteNome:actor.nome,solicitanteEmail:actor.email,solicitanteTime:actor.time||'',aprovadorId:a.id,aprovadorEmail:a.email,aprovadorNome:a.nome,aprovadorOrigem:a.origem,status:'pendente_aprovacao_lider',decididoPorId:null,decididoEm:null});
    return next;
  }

  const cs=status(current), ns=normStatus(next.status||cs);
  const admin=role(actor,ADMIN_PROFILES), approver=idEq(current.aprovadorId,actor.id)&&role(actor,APPROVER_PROFILES);
  const requester=idEq(current.solicitanteId,actor.id), almox=role(actor,ALMOX_PROFILES);
  if(!admin&&changed(current,next,'solicitanteId')) deny('Solicitante não pode ser alterado.');
  if(!admin&&changed(current,next,'aprovadorId')) deny('Aprovador não pode ser alterado.');

  if(admin){
    if(next.aprovadorId||next.aprovadorEmail){
      const a=await resolveApprover(client,actor,next,true);
      Object.assign(next,{aprovadorId:a.id,aprovadorEmail:a.email,aprovadorNome:a.nome,aprovadorOrigem:a.origem});
    }
    next.status=ns; return next;
  }
  if(approver){
    if(cs!=='pendente_aprovacao_lider'||!['aprovada','reprovada','revisao_solicitada'].includes(ns)) deny('Transição de aprovação inválida.');
    if(['reprovada','revisao_solicitada'].includes(ns)&&!t(next.observacaoLider)) deny('Observação obrigatória para reprovar ou solicitar revisão.');
    next.status=ns; next.decididoPorId=actor.id; next.decididoEm=new Date().toISOString(); return next;
  }
  if(requester){
    if(cs==='revisao_solicitada'&&ns==='pendente_aprovacao_lider'){
      const a=await resolveApprover(client,actor,current,false);
      Object.assign(next,{status:'pendente_aprovacao_lider',aprovadorId:a.id,aprovadorEmail:a.email,aprovadorNome:a.nome,aprovadorOrigem:a.origem,decididoPorId:null,decididoEm:null});
      return next;
    }
    if(ns!==cs) deny('Solicitante não pode decidir a própria SCM.');
    if(changed(current,next,'decididoPorId')||changed(current,next,'decididoEm')) deny('Solicitante não pode preencher dados da decisão.');
    next.status=cs; return next;
  }
  if(almox){
    const ok=(cs==='aprovada'&&ns==='em_tratativa')||(cs==='em_tratativa'&&ns==='concluida');
    if(!ok&&ns!==cs) deny('Transição de almoxarifado inválida.');
    next.status=ns; return next;
  }
  if(ns!==cs) deny('Perfil sem permissão para alterar o status da SCM.');
  next.status=cs; return next;
}

async function syncScmToDatabase({client,session,payload,currentPayload}){
  const code=t(payload.codigo), camm=t(payload.camm);
  if(!code) deny('SCM sem código.');
  if(!['CAMM 1','CAMM 2','CAMM 3'].includes(camm)) deny('CAMM inválido.');
  const a=await approverOf(client,payload.aprovadorId||null,payload.aprovadorEmail||'');
  if(!a) deny('Aprovador não encontrado.');
  const r=await client.query(
    'INSERT INTO almox.scm(origem_id,codigo,time_solicitante,tipo_solicitacao,capex_projeto,camm,urgencia,numero_om,tipo_fornecedor,nome_fornecedor,tipo_pedido,descricao_uso,solicitante_id,solicitante_nome,solicitante_email,solicitante_time,aprovador_id,aprovador_email,aprovador_origem,status,decidido_por_id,decidido_em,observacao_lider,observacao_almoxarife,numero_processo_me,atualizado_em) VALUES($1,$2,$3,$4,$5,$6::core.camm,$7::almox.urgencia,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20::almox.scm_status,$21,$22,$23,$24,$25,now()) ON CONFLICT(origem_id) DO UPDATE SET codigo=EXCLUDED.codigo,time_solicitante=EXCLUDED.time_solicitante,tipo_solicitacao=EXCLUDED.tipo_solicitacao,capex_projeto=EXCLUDED.capex_projeto,camm=EXCLUDED.camm,urgencia=EXCLUDED.urgencia,numero_om=EXCLUDED.numero_om,tipo_fornecedor=EXCLUDED.tipo_fornecedor,nome_fornecedor=EXCLUDED.nome_fornecedor,tipo_pedido=EXCLUDED.tipo_pedido,descricao_uso=EXCLUDED.descricao_uso,solicitante_id=EXCLUDED.solicitante_id,solicitante_nome=EXCLUDED.solicitante_nome,solicitante_email=EXCLUDED.solicitante_email,solicitante_time=EXCLUDED.solicitante_time,aprovador_id=EXCLUDED.aprovador_id,aprovador_email=EXCLUDED.aprovador_email,aprovador_origem=EXCLUDED.aprovador_origem,status=EXCLUDED.status,decidido_por_id=EXCLUDED.decidido_por_id,decidido_em=EXCLUDED.decidido_em,observacao_lider=EXCLUDED.observacao_lider,observacao_almoxarife=EXCLUDED.observacao_almoxarife,numero_processo_me=EXCLUDED.numero_processo_me,atualizado_em=now() RETURNING id',
    [t(payload.id)||code,code,t(payload.timeSolicitante)||'Não informado',t(payload.tipoSolicitacao)||null,t(payload.capexProjeto)||null,camm,normUrgency(payload.urgencia),t(payload.numeroOM)||null,t(payload.tipoFornecedor)||null,t(payload.nomeFornecedor)||null,t(payload.tipoPedido)||null,t(payload.descricaoUso)||'Sem descrição',payload.solicitanteId,t(payload.solicitanteNome),t(payload.solicitanteEmail)||null,t(payload.solicitanteTime)||null,a.id,a.email,t(payload.aprovadorOrigem)||'grupo',normStatus(payload.status),payload.decididoPorId||null,payload.decididoEm||null,t(payload.observacaoLider)||null,t(payload.observacaoAlmoxarife)||null,t(payload.numeroProcessoME)||null]
  );
  const scmId=r.rows[0].id;
  await client.query('DELETE FROM almox.scm_item WHERE scm_id=$1',[scmId]);
  const items=Array.isArray(payload.itens)?payload.itens.slice(0,100):[];
  for(let i=0;i<items.length;i++){
    const item=items[i]||{}, qty=Number(String(item.quantidade??'').replace(',','.'));
    if(!Number.isFinite(qty)||qty<=0) deny('Quantidade de item inválida.');
    await client.query('INSERT INTO almox.scm_item(scm_id,posicao,codigo_sistema,descricao,quantidade,estoque_minimo,marca_modelo_serie) VALUES($1,$2,$3,$4,$5,$6,$7)',
      [scmId,i+1,t(item.codigoSistema)||'SEM-CODIGO',t(item.descricaoItem)||null,qty,Number.isFinite(Number(item.estoqueMinimo))?Number(item.estoqueMinimo):null,t(item.marcaModeloSerie)||null]);
  }
  const prev=normStatus(currentPayload?.status||''), nowStatus=normStatus(payload.status);
  if(prev&&prev!==nowStatus) await client.query('INSERT INTO almox.scm_historico(scm_id,de,para,por_usuario_id,por_nome,nota) VALUES($1,$2::almox.scm_status,$3::almox.scm_status,$4,$5,$6)',[scmId,prev,nowStatus,String(session.sub),t(payload.decididoPorNome||payload.solicitanteNome),t(payload.observacaoLider||payload.observacaoAlmoxarife)]);
  else if(!prev) await client.query('INSERT INTO almox.scm_historico(scm_id,de,para,por_usuario_id,por_nome,nota) VALUES($1,NULL,$2::almox.scm_status,$3,$4,$5)',[scmId,nowStatus,String(session.sub),t(payload.solicitanteNome),t(payload.observacaoLider||'')]);
}
module.exports={authorizeScmMutation,syncScmToDatabase};
