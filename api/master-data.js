
const { Pool } = require('pg');
const { readCookie, verifySession, sendJson, sameOrigin } = require('../_auth');

const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 5 });
const LISTS = new Set(['scm_time','scm_tipo_solicitacao','scm_urgencia','scm_tipo_fornecedor','scm_tipo_pedido','scm_centro_custo']);

function session(req){ const t=readCookie(req,'biotrop_session'); return t?verifySession(t):null; }
async function db(s,fn){
  const c=await pool.connect();
  try{
    await c.query('BEGIN');
    await c.query("select set_config('app.usuario_id',$1,true)",[String(s.sub)]);
    await c.query("select set_config('app.usuario_email',$1,true)",[String(s.email||'')]);
    const x=await fn(c); await c.query('COMMIT'); return x;
  }catch(e){ try{await c.query('ROLLBACK')}catch(_){} throw e; }
  finally{ c.release(); }
}
function clean(v,max=300){ return String(v??'').trim().slice(0,max); }
function out(r){ return {id:r.id,codigo:r.codigo,nome:r.nome,posicao:Number(r.posicao||0),ativo:r.ativo!==false,metadata:r.metadata||{},campos:r.campos||[]}; }
function parseBody(req){
  if(req.body && typeof req.body==='object') return req.body;
  try{return JSON.parse(req.body||'{}')}catch(_){return null;}
}
module.exports=async function(req,res){
  const s=session(req);
  if(!s) return sendJson(res,401,{ok:false,erro:'Sessão inválida.'});
  if(req.method!=='GET'&&!sameOrigin(req)) return sendJson(res,403,{ok:false,erro:'Origem não autorizada.'});
  try{
    return await db(s,async c=>{
      const resource=clean(req.query?.resource,60), list=clean(req.query?.list,60);
      const roleRow=await c.query("select perfil_id from core.usuario where id=$1 and ativo and not bloqueado",[String(s.sub)]);
      const role=String(roleRow.rows[0]?.perfil_id||'');
      const editor=['admin','gestor','pcm'].includes(role);
      if(req.method==='GET'){
        if(resource==='camm'){
          const q=await c.query("select id,codigo,nome,posicao,ativo from core.camm_catalogo where ativo order by posicao,nome");
          return sendJson(res,200,{ok:true,rows:q.rows.map(out)});
        }
        if(resource==='lista'&&LISTS.has(list)){
          const q=await c.query("select id,codigo,nome,posicao,ativo,metadata from core.lista_catalogo where lista=$1 and ativo order by posicao,nome",[list]);
          return sendJson(res,200,{ok:true,rows:q.rows.map(out)});
        }
        if(resource==='familias'){
          const q=await c.query(
            "select f.id,f.id as codigo,f.nome,f.posicao,f.ativo,coalesce(json_agg(json_build_object('id',fc.id,'id_campo',fc.chave,'label',fc.rotulo,'obrigatorio',fc.obrigatorio,'posicao',fc.posicao) order by fc.posicao,fc.rotulo) filter (where fc.id is not null),'[]') as campos from almox.familia f left join almox.familia_campo fc on fc.familia_id=f.id and fc.ativo where f.ativo group by f.id,f.nome,f.posicao,f.ativo order by f.posicao,f.nome"
          );
          return sendJson(res,200,{ok:true,rows:q.rows.map(out)});
        }
        return sendJson(res,400,{ok:false,erro:'Recurso inválido.'});
      }

      if(!editor && !(role==='almoxarife'&&resource==='familias'))
        return sendJson(res,403,{ok:false,erro:'Seu perfil não pode editar este cadastro.'});

      const b=parseBody(req);
      if(!b) return sendJson(res,400,{ok:false,erro:'JSON inválido.'});

      if(req.method==='DELETE'){
        const id=clean(req.query?.id,120);
        if(!id) return sendJson(res,400,{ok:false,erro:'ID obrigatório.'});
        if(resource==='camm'){
          await c.query("update core.camm_catalogo set ativo=false,atualizado_em=now() where id=$1",[id]);
          return sendJson(res,200,{ok:true});
        }
        if(resource==='lista'&&LISTS.has(list)){
          await c.query("update core.lista_catalogo set ativo=false,atualizado_em=now() where id=$1 and lista=$2",[id,list]);
          return sendJson(res,200,{ok:true});
        }
        if(resource==='familias'){
          await c.query("update almox.familia set ativo=false,atualizado_em=now() where id=$1",[id]);
          await c.query("update almox.familia_campo set ativo=false where familia_id=$1",[id]);
          return sendJson(res,200,{ok:true});
        }
        return sendJson(res,400,{ok:false,erro:'Recurso de exclusão inválido.'});
      }

      if(resource==='camm'){
        const codigo=clean(b.codigo,80), nome=clean(b.nome||codigo,160);
        if(!codigo) return sendJson(res,400,{ok:false,erro:'Código CAMM obrigatório.'});
        const q=await c.query(
          "insert into core.camm_catalogo(codigo,nome,posicao,ativo) values($1,$2,$3,$4) on conflict(codigo) do update set nome=excluded.nome,posicao=excluded.posicao,ativo=excluded.ativo,atualizado_em=now() returning id,codigo,nome,posicao,ativo",
          [codigo,nome,Number(b.posicao||0),b.ativo!==false]
        );
        return sendJson(res,200,{ok:true,row:out(q.rows[0])});
      }

      if(resource==='lista'&&LISTS.has(list)){
        const codigo=clean(b.codigo,120), nome=clean(b.nome||codigo,240);
        if(!codigo) return sendJson(res,400,{ok:false,erro:'Código obrigatório.'});
        let metadata=b.metadata&&typeof b.metadata==='object'?b.metadata:{};
        if(list==='scm_centro_custo'){
          await c.query("lock table almox.centro_custo in exclusive mode");
          let ccId=metadata.centro_custo_id?Number(metadata.centro_custo_id):null;
          if(!ccId){
            const existing=await c.query("select id from almox.centro_custo where lower(nome)=lower($1) limit 1",[nome]);
            if(existing.rowCount) ccId=Number(existing.rows[0].id);
            else{
              const mx=await c.query("select coalesce(max(id),0)+1 id from almox.centro_custo");
              ccId=Number(mx.rows[0].id);
              if(ccId>32767) return sendJson(res,409,{ok:false,erro:'Limite de centros de custo atingido.'});
              await c.query("insert into almox.centro_custo(id,nome) values($1,$2)",[ccId,nome]);
            }
          }else{
            await c.query("update almox.centro_custo set nome=$1 where id=$2",[nome,ccId]);
          }
          metadata=Object.assign({},metadata,{centro_custo_id:ccId});
        }
        const q=await c.query(
          "insert into core.lista_catalogo(lista,codigo,nome,posicao,ativo,metadata) values($1,$2,$3,$4,$5,$6::jsonb) on conflict(lista,codigo) do update set nome=excluded.nome,posicao=excluded.posicao,ativo=excluded.ativo,metadata=excluded.metadata,atualizado_em=now() returning id,codigo,nome,posicao,ativo,metadata",
          [list,codigo,nome,Number(b.posicao||0),b.ativo!==false,JSON.stringify(metadata)]
        );
        return sendJson(res,200,{ok:true,row:out(q.rows[0])});
      }

      if(resource==='familias'){
        const id=clean(b.id,120), nome=clean(b.nome,200);
        if(!id||!nome) return sendJson(res,400,{ok:false,erro:'ID e nome da família são obrigatórios.'});
        const campos=Array.isArray(b.campos)?b.campos:[];
        await c.query(
          "insert into almox.familia(id,nome,posicao,ativo) values($1,$2,$3,$4) on conflict(id) do update set nome=excluded.nome,posicao=excluded.posicao,ativo=excluded.ativo,atualizado_em=now()",
          [id,nome,Number(b.posicao||0),b.ativo!==false]
        );
        await c.query("update almox.familia_campo set ativo=false where familia_id=$1",[id]);
        for(let i=0;i<campos.length;i++){
          const chave=clean(campos[i].id||campos[i].id_campo,100), rotulo=clean(campos[i].label||campos[i].rotulo,200);
          if(!chave||!rotulo) continue;
          await c.query(
            "insert into almox.familia_campo(familia_id,chave,rotulo,obrigatorio,posicao,ativo) values($1,$2,$3,$4,$5,true) on conflict(familia_id,chave) do update set rotulo=excluded.rotulo,obrigatorio=excluded.obrigatorio,posicao=excluded.posicao,ativo=true",
            [id,chave,rotulo,campos[i].obrigatorio===true,i]
          );
        }
        const q=await c.query(
          "select f.id,f.id as codigo,f.nome,f.posicao,f.ativo,coalesce(json_agg(json_build_object('id',fc.id,'id_campo',fc.chave,'label',fc.rotulo,'obrigatorio',fc.obrigatorio,'posicao',fc.posicao) order by fc.posicao,fc.rotulo) filter (where fc.id is not null),'[]') as campos from almox.familia f left join almox.familia_campo fc on fc.familia_id=f.id and fc.ativo where f.id=$1 group by f.id,f.nome,f.posicao,f.ativo",
          [id]
        );
        return sendJson(res,200,{ok:true,row:out(q.rows[0])});
      }
      return sendJson(res,400,{ok:false,erro:'Recurso de edição inválido.'});
    });
  }catch(e){
    console.error('[MASTER DATA]',e);
    return sendJson(res,500,{ok:false,erro:'Falha ao acessar dados mestre.'});
  }
};
