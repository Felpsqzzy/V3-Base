const { Pool } = require('pg');
const { readCookie, verifySession, sendJson, sameOrigin } = require('../_auth');
const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 5 });
const LISTS = new Set(['scm_time','scm_tipo_solicitacao','scm_urgencia','scm_tipo_fornecedor','scm_tipo_pedido']);
function session(req){const t=readCookie(req,'biotrop_session');return t?verifySession(t):null}
async function db(s,fn){const c=await pool.connect();try{await c.query('BEGIN');await c.query("select set_config('app.usuario_id',$1,true)",[String(s.sub)]);await c.query("select set_config('app.usuario_email',$1,true)",[String(s.email||'')]);const x=await fn(c);await c.query('COMMIT');return x}catch(e){try{await c.query('ROLLBACK')}catch(_){}throw e}finally{c.release()}}
function out(r){return {id:r.id,codigo:r.codigo,nome:r.nome,posicao:Number(r.posicao||0),ativo:r.ativo!==false,metadata:r.metadata||{},camm_codigo:r.camm_codigo||null}}
module.exports=async function(req,res){
 const s=session(req);if(!s)return sendJson(res,401,{ok:false,erro:'Sessão inválida.'});
 if(req.method!=='GET'&&!sameOrigin(req))return sendJson(res,403,{ok:false,erro:'Origem não autorizada.'});
 try{return await db(s,async c=>{
  const resource=String(req.query?.resource||'').trim(), list=String(req.query?.list||'').trim();
  if(req.method==='GET'){
   if(resource==='camm'){const q=await c.query("select id,codigo,nome,posicao,ativo from core.camm_catalogo where ativo order by posicao,nome");return sendJson(res,200,{ok:true,rows:q.rows.map(out)})}
   if(resource==='lista'&&LISTS.has(list)){const q=await c.query("select id,codigo,nome,posicao,ativo,metadata from core.lista_catalogo where lista=$1 and ativo order by posicao,nome",[list]);return sendJson(res,200,{ok:true,rows:q.rows.map(out)})}
   if(resource==='centro_custo'){const q=await c.query("select cc.id,cc.nome as codigo,cc.nome,cc.posicao,cc.ativo,array_remove(array_agg(distinct m.camm_codigo),null) camms from almox.centro_custo cc left join core.camm_centro_custo m on m.centro_custo_id=cc.id and m.ativo where cc.ativo group by cc.id,cc.nome,cc.posicao,cc.ativo order by cc.posicao,cc.nome");return sendJson(res,200,{ok:true,rows:q.rows.map(r=>Object.assign(out(r),{camm_codigo:(r.camms||[]).length===1?r.camms[0]:null,camms:r.camms||[]}))})}
   if(resource==='familias'){const q=await c.query("select id,nome,ordem as posicao,ativo from almox.familia where ativo order by ordem,nome");return sendJson(res,200,{ok:true,rows:q.rows.map(r=>({id:r.id,codigo:r.id,nome:r.nome,posicao:Number(r.posicao||0),ativo:r.ativo}))})}
   return sendJson(res,400,{ok:false,erro:'Recurso inválido.'})
  }
  const role=await c.query("select app.tem_perfil($1::text[]) ok",[['admin','gestor']]);if(!role.rows[0]?.ok)return sendJson(res,403,{ok:false,erro:'Apenas administradores/gestores podem editar dados mestre.'});
  let b={};try{b=typeof req.body==='object'?req.body:JSON.parse(req.body||'{}')}catch(_){return sendJson(res,400,{ok:false,erro:'JSON inválido.'})}
  if(resource==='camm'){const codigo=String(b.codigo||'').trim();if(!codigo)return sendJson(res,400,{ok:false,erro:'Código CAMM obrigatório.'});const e=await c.query("select 1 from pg_enum e join pg_type t on t.oid=e.enumtypid join pg_namespace n on n.oid=t.typnamespace where n.nspname='core' and t.typname='camm' and e.enumlabel=$1",[codigo]);if(!e.rowCount)return sendJson(res,400,{ok:false,erro:'O código CAMM não existe no domínio atual do banco.'});const q=await c.query("insert into core.camm_catalogo(codigo,nome,posicao,ativo) values($1,$2,$3,$4) on conflict(codigo) do update set nome=excluded.nome,posicao=excluded.posicao,ativo=excluded.ativo,atualizado_em=now() returning id,codigo,nome,posicao,ativo",[codigo,String(b.nome||codigo),Number(b.posicao||0),b.ativo!==false]);return sendJson(res,200,{ok:true,row:out(q.rows[0])})}
  if(resource==='lista'&&LISTS.has(list)){const codigo=String(b.codigo||'').trim();if(!codigo)return sendJson(res,400,{ok:false,erro:'Código obrigatório.'});const q=await c.query("insert into core.lista_catalogo(lista,codigo,nome,posicao,ativo,metadata) values($1,$2,$3,$4,$5,$6::jsonb) on conflict(lista,codigo) do update set nome=excluded.nome,posicao=excluded.posicao,ativo=excluded.ativo,metadata=excluded.metadata,atualizado_em=now() returning id,codigo,nome,posicao,ativo,metadata",[list,codigo,String(b.nome||codigo),Number(b.posicao||0),b.ativo!==false,JSON.stringify(b.metadata||{})]);return sendJson(res,200,{ok:true,row:out(q.rows[0])})}
  return sendJson(res,400,{ok:false,erro:'Recurso de edição inválido.'})
 })}catch(e){console.error('[MASTER DATA]',e);return sendJson(res,500,{ok:false,erro:'Falha ao acessar dados mestre.'})}
};