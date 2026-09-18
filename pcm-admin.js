
(function(){
"use strict";
var API="/api/master-data";
var state={lists:{},camm:[],familias:[],ready:false,loading:false};
var defs=[
["scm_time","Time Solicitante","SCM"],
["scm_tipo_solicitacao","Tipo de Solicitação","SCM"],
["scm_camm","CAMMs","SCM"],
["scm_urgencia","Urgência","SCM"],
["scm_centro_custo","Centro de Custo","SCM"],
["scm_tipo_fornecedor","Tipo de Fornecedor","SCM"],
["scm_tipo_pedido","Tipo de Pedido","SCM"]
];
var fallback={
scm_time:["Elétrica e Automação","Predial","Mecânica","PCM","Almoxarifado","Time CAMM 03","Outra"],
scm_tipo_solicitacao:["Normal","Emergencial","Melhoria/CAPEX"],
scm_camm:["CAMM 1","CAMM 2","CAMM 3"],
scm_urgencia:["Baixa","Média","Alta"],
scm_centro_custo:["CENTRO LOGÍSTICO","COMPRAS","COMPRAS - PRODUÇÃO","CONTABILIDADE","CONTROLE DE QUALIDADE - CAMM 3","EMPACOTAMENTO - CAMM 1","EMPACOTAMENTO -CAMM 2","ENVASE - CAMM 1","ENVASE - CAMM 2","ESG","FACILITIES","FACILITIES - INDUSTRIAL - CAMM 3","FACILITIES - PRODUÇÃO","FATURAMENTO E EXPEDIÇÃO","FERMENTAÇÃO - CAMM 2","FERMENTAÇÃO - CAMM 3","FERMENTADORES - CAMM 1","FISCAL","FORMULAÇÃO/EMPACOTAMENTO - CAMM 3","FP&A","FRACIONAMENTO DE MP","FROTAS","INOVAÇÃO","LABORATÓRIO","LOGÍSTICA INTERNA","LOGÍSTICA INTERNA - CAMM 3","MANUTENÇÃO","MANUTENÇÃO E ENGENHARIA - CAMM 3","MANUTENÇÃO PREDIAL (FACILITIES)","MELHORIA CONTÍNUA","PCP","PESQUISA","QUALIDADE","RECRUTAMENTO E SELEÇÃO","REGULATÓRIO","S&OP","SEGURANÇA DO TRABALHO - CAMM 3","SEGURANÇA DO TRABALHO - G&A","SEGURANÇA DO TRABALHO - PRODUÇÃO","TESOURARIA","TI","UTILIDADES","UTILIDADES - CAMM 3","VENDAS INDUSTRIAIS B2B","Outro"],
scm_tipo_fornecedor:["Normal","Escolhido","Exclusivo"],
scm_tipo_pedido:["Compra de Material","Contratação de Serviço (PCM)","Solicitação de Manutenção Externa"]
};
function esc(v){var d=document.createElement("div");d.textContent=String(v==null?"":v);return d.innerHTML;}
function slug(v){return String(v||"").normalize("NFD").replace(/[\u0300-\u036f]/g,"").toLowerCase().replace(/[^a-z0-9]+/g,"_").replace(/^_+|_+$/g,"").slice(0,80)||("item_"+Date.now());}
async function get(url){var r=await fetch(url,{credentials:"same-origin",cache:"no-store"});var j=await r.json().catch(function(){return {};});if(!r.ok)throw new Error(j.erro||"Falha ao carregar cadastro.");return j.rows||[];}
async function save(url,body){var r=await fetch(url,{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)});var j=await r.json().catch(function(){return {};});if(!r.ok)throw new Error(j.erro||"Falha ao salvar.");return j.row;}
async function remove(url){var r=await fetch(url,{method:"DELETE",credentials:"same-origin"});var j=await r.json().catch(function(){return {};});if(!r.ok)throw new Error(j.erro||"Falha ao remover.");return j;}
function canAll(){var u=window.BIOTROP_STATE&&window.BIOTROP_STATE.currentUser||{};var p=String(u.perfilId||"").toLowerCase();return p==="admin"||p==="gestor"||p==="pcm";}
function canFamily(){var u=window.BIOTROP_STATE&&window.BIOTROP_STATE.currentUser||{};return canAll()||String(u.perfilId||"").toLowerCase()==="almoxarife";}
async function loadAll(){
if(state.loading)return;
state.loading=true;
try{
var listDefs=defs.filter(function(d){return d[0]!=="scm_camm";});
var rs=await Promise.all(listDefs.map(function(d){return get(API+"?resource=lista&list="+encodeURIComponent(d[0]));}));
rs.forEach(function(rows,i){state.lists[listDefs[i][0]]=rows;});
state.camm=await get(API+"?resource=camm");state.lists.scm_camm=state.camm;
state.familias=await get(API+"?resource=familias");state.ready=true;
}catch(e){
Object.keys(fallback).forEach(function(k){state.lists[k]=fallback[k].map(function(n,i){return{id:"fallback_"+slug(n),codigo:k==="scm_tipo_solicitacao"?slug(n):n,nome:n,posicao:i+1,ativo:true,metadata:{}};});});
state.camm=state.lists.scm_camm;state.ready=false;state.familias=[];
console.warn("[PCM]",e);
}
finally{state.loading=false;hydrateForms();if(document.getElementById("pcm-page"))draw();}
}
function renderPcmPage(){
return '<div id="pcm-page" class="pcm-page"><div class="pcm-hero"><div><div class="pcm-kicker">PLANEJAMENTO E CONTROLE DE MANUTENÇÃO</div><h1>PCM · Governança de Cadastros</h1><p>Cadastros compartilhados do SCI e SCM. Adicione, edite ou desative opções sem alterar o código do sistema.</p></div><button class="pcm-refresh" id="pcm-refresh">Atualizar</button></div><div class="pcm-status '+(state.ready?"ok":"warn")+'">'+(state.ready?"Banco conectado · alterações compartilhadas entre usuários":"Banco indisponível · exibindo valores padrão")+'</div><div class="pcm-grid">'+defs.map(card).join("")+'</div>'+(canAll()?'<div class="pcm-editor"><div class="pcm-editor-head"><div><h2>Cadastros SCM</h2><p>As opções abaixo alimentam diretamente os formulários de compra.</p></div><select id="pcm-catalog-select">'+defs.map(function(d){return '<option value="'+esc(d[0])+'">'+esc(d[1])+'</option>';}).join("")+'</select></div><div id="pcm-catalog-editor"></div></div>':"")+(canFamily()?'<div class="pcm-editor"><div class="pcm-editor-head"><div><h2>Famílias e campos da SCI</h2><p>Configure os campos específicos exigidos para cada família de material.</p></div><button class="pcm-primary" id="pcm-new-family">Nova família</button></div><div id="pcm-family-editor"></div></div>':"")+'</div>';
}
function card(d){
var rows=d[0]==="scm_camm"?state.camm:(state.lists[d[0]]||[]);
return '<section class="pcm-card"><div class="pcm-card-head"><div><div class="pcm-card-kicker">'+esc(d[2])+'</div><h3>'+esc(d[1])+'</h3></div><span class="pcm-count">'+rows.length+'</span></div><div class="pcm-mini-list">'+rows.slice(0,6).map(function(r){return '<div>'+esc(r.nome||r.codigo)+'</div>';}).join("")+(rows.length>6?'<div class="pcm-more">+'+(rows.length-6)+' itens</div>':"")+'</div></section>';
}
function draw(){
var refresh=document.getElementById("pcm-refresh");if(refresh)refresh.onclick=function(){loadAll();};
var sel=document.getElementById("pcm-catalog-select");if(sel){sel.onchange=drawCatalog;drawCatalog();}
var nf=document.getElementById("pcm-new-family");if(nf)nf.onclick=function(){familyForm(null);};
drawFamilies();
}
function drawCatalog(){
var key=document.getElementById("pcm-catalog-select")?.value||"scm_time",rows=key==="scm_camm"?state.camm:(state.lists[key]||[]),el=document.getElementById("pcm-catalog-editor");if(!el)return;
el.innerHTML='<div class="pcm-table"><div class="pcm-tr pcm-th"><span>Nome</span><span>Código</span><span>Ordem</span><span>Status</span><span>Ações</span></div>'+rows.map(function(r){return '<div class="pcm-tr"><span>'+esc(r.nome||"")+'</span><span><code>'+esc(r.codigo||"")+'</code></span><span>'+Number(r.posicao||0)+'</span><span><b class="pcm-badge '+(r.ativo===false?"off":"on")+'">'+(r.ativo===false?"Inativo":"Ativo")+'</b></span><span class="pcm-actions"><button data-edit="'+esc(r.id)+'">Editar</button><button class="danger" data-del="'+esc(r.id)+'">Desativar</button></span></div>';}).join("")+'</div><button class="pcm-add" id="pcm-add-row">+ Adicionar opção</button>';
el.querySelector("#pcm-add-row").onclick=function(){catalogForm(key,null);};
el.querySelectorAll("[data-edit]").forEach(function(b){b.onclick=function(){catalogForm(key,rows.find(function(r){return String(r.id)===String(b.dataset.edit);}));};});
el.querySelectorAll("[data-del]").forEach(function(b){b.onclick=async function(){if(!confirm("Desativar esta opção?"))return;try{await remove(API+"?resource="+(key==="scm_camm"?"camm":"lista&list="+encodeURIComponent(key))+"&id="+encodeURIComponent(b.dataset.del));await loadAll();}catch(e){alert(e.message);}};});
}
function catalogForm(key,row){
var modal=document.createElement("div");modal.className="pcm-modal";
var meta=row&&row.metadata||{};
modal.innerHTML='<div class="pcm-modal-box"><div class="pcm-modal-head"><h3>'+(row?"Editar opção":"Nova opção")+'</h3><button id="x">×</button></div><label>Nome</label><input id="n" value="'+esc(row&&row.nome||"")+'" placeholder="Nome exibido"><label>Código interno</label><input id="c" value="'+esc(row&&row.codigo||"")+'" placeholder="Código estável"><label>Ordem</label><input id="p" type="number" value="'+Number(row&&row.posicao||0)+'">'+(key==="scm_centro_custo"?'<label>CAMMs associados (opcional)</label><input id="cm" value="'+esc(Array.isArray(meta.camm)?meta.camm.join(", "):"")+'" placeholder="CAMM 1, CAMM 2">':"")+'<div class="pcm-modal-actions"><button id="cancel">Cancelar</button><button id="save" class="pcm-primary">Salvar</button></div></div>';
document.body.appendChild(modal);
modal.querySelector("#x").onclick=modal.querySelector("#cancel").onclick=function(){modal.remove();};
modal.onclick=function(e){if(e.target===modal)modal.remove();};
modal.querySelector("#save").onclick=async function(){
var nome=modal.querySelector("#n").value.trim(),codigo=modal.querySelector("#c").value.trim()||slug(nome),pos=Number(modal.querySelector("#p").value||0);
if(!nome){alert("Informe o nome.");return;}
var metadata=Object.assign({},meta);
if(key==="scm_centro_custo")metadata.camm=(modal.querySelector("#cm").value||"").split(",").map(function(x){return x.trim();}).filter(Boolean);
try{await save(API+"?resource="+(key==="scm_camm"?"camm":"lista&list="+encodeURIComponent(key)),{codigo:codigo,nome:nome,posicao:pos,ativo:true,metadata:metadata});modal.remove();await loadAll();}catch(e){alert(e.message);}
};
}
function drawFamilies(){
var el=document.getElementById("pcm-family-editor");if(!el)return;
el.innerHTML=state.familias.map(function(f){return '<div class="pcm-family-row"><div><b>'+esc(f.nome)+'</b><small>'+((f.campos||[]).length)+' campo(s)</small></div><div><button data-fe="'+esc(f.id)+'">Editar</button><button class="danger" data-fd="'+esc(f.id)+'">Desativar</button></div></div>';}).join("")||'<div class="pcm-empty">Nenhuma família.</div>';
el.querySelectorAll("[data-fe]").forEach(function(b){b.onclick=function(){familyForm(state.familias.find(function(f){return String(f.id)===String(b.dataset.fe);}));};});
el.querySelectorAll("[data-fd]").forEach(function(b){b.onclick=async function(){if(!confirm("Desativar esta família?"))return;try{await remove(API+"?resource=familias&id="+encodeURIComponent(b.dataset.fd));await loadAll();}catch(e){alert(e.message);}};});
}
function familyForm(row){
var fields=(row&&row.campos||[]).map(function(c){return{id:c.id_campo||c.id,label:c.label,obrigatorio:c.obrigatorio};});
var modal=document.createElement("div");modal.className="pcm-modal";
modal.innerHTML='<div class="pcm-modal-box pcm-wide"><div class="pcm-modal-head"><h3>'+(row?"Editar família":"Nova família")+'</h3><button id="x">×</button></div><label>Nome da família</label><input id="fn" value="'+esc(row&&row.nome||"")+'" placeholder="Ex.: Rolamento"><label>Campos específicos</label><div id="fs"></div><button id="af" class="pcm-add">+ Adicionar campo</button><div class="pcm-modal-actions"><button id="cancel">Cancelar</button><button id="save" class="pcm-primary">Salvar</button></div></div>';
document.body.appendChild(modal);
var fs=modal.querySelector("#fs");
function drawF(){fs.innerHTML=fields.map(function(f,i){return '<div class="pcm-field"><input class="fl" value="'+esc(f.label)+'" placeholder="Nome do campo"><label><input class="fr" type="checkbox" '+(f.obrigatorio?"checked":"")+'> Obrigatório</label><button data-i="'+i+'">×</button></div>';}).join("");fs.querySelectorAll("[data-i]").forEach(function(b){b.onclick=function(){fields.splice(Number(b.dataset.i),1);drawF();};});}
drawF();
modal.querySelector("#af").onclick=function(){fields.push({id:"",label:"",obrigatorio:false});drawF();};
modal.querySelector("#x").onclick=modal.querySelector("#cancel").onclick=function(){modal.remove();};
modal.onclick=function(e){if(e.target===modal)modal.remove();};
modal.querySelector("#save").onclick=async function(){
var nome=modal.querySelector("#fn").value.trim();if(!nome){alert("Informe o nome.");return;}
var out=[];fs.querySelectorAll(".pcm-field").forEach(function(r,i){var label=r.querySelector(".fl").value.trim();if(label)out.push({id:slug(label),label:label,obrigatorio:r.querySelector(".fr").checked,posicao:i});});
try{await save(API+"?resource=familias",{id:row&&row.id||slug(nome),nome:nome,posicao:row&&row.posicao||0,ativo:true,campos:out});modal.remove();await loadAll();}catch(e){alert(e.message);}
};
}
function hydrateSelect(id,rows,placeholder){
var el=document.getElementById(id);if(!el)return;
var prev=el.value;el.innerHTML='<option value="">'+esc(placeholder||"Selecione...")+'</option>'+(rows||[]).filter(function(r){return r.ativo!==false;}).map(function(r){return '<option value="'+esc(r.codigo||r.nome)+'">'+esc(r.nome||r.codigo)+'</option>';}).join("");
if(prev&&Array.from(el.options).some(function(o){return o.value===prev;}))el.value=prev;
}
function hydrateForms(){
hydrateSelect("scm-time",state.lists.scm_time,"Selecione...");
hydrateSelect("scm-camm",state.lists.scm_camm,"Selecione...");
hydrateSelect("scm-urgencia",state.lists.scm_urgencia,"Selecione...");
hydrateSelect("scm-tipo-solicitacao",state.lists.scm_tipo_solicitacao,"Selecione...");
hydrateSelect("scm-tipo-fornecedor",state.lists.scm_tipo_fornecedor,"Selecione...");
hydrateSelect("scm-tipo-pedido",state.lists.scm_tipo_pedido,"Selecione...");
hydrateSelect("scm-centro-custo",state.lists.scm_centro_custo,"Selecione...");
var fam=document.getElementById("sci-familia");
if(fam){
var prev=fam.value;fam.innerHTML='<option value="">Selecione o tipo de material...</option>'+state.familias.map(function(f){return '<option value="'+esc(f.id)+'">'+esc(f.nome)+'</option>';}).join("");
fam.onchange=function(){
var f=state.familias.find(function(x){return String(x.id)===String(fam.value);}),dyn=document.getElementById("sci-dynamic-fields"),common=document.getElementById("sci-common-fields");if(!dyn||!common)return;
dyn.innerHTML=(f&&f.campos||[]).map(function(c){return '<label class="field-label" style="margin-top:12px;">'+esc(c.label)+(c.obrigatorio?' <span style="color:#d64545">*</span>':"")+'</label><input class="modal-input sci-dyn-field" data-field="'+esc(c.id_campo||c.id)+'" '+(c.obrigatorio?'required':"")+">";}).join("");
common.style.display=f?"block":"none";
};
if(prev)fam.value=prev;
}
}
window.renderPcmPage=renderPcmPage;
window.attachPcmPageEvents=draw;
window.BIOTROP_MASTER_DATA=state.lists;
window.BIOTROP_MASTER_DATA.refresh=loadAll;
window.BIOTROP_MASTER_DATA_HOOK=function(){hydrateForms();};
window.addEventListener("DOMContentLoaded",function(){loadAll();});
setInterval(function(){if(document.visibilityState==="visible")loadAll();},15000);
var css=document.createElement("style");css.id="pcm-admin-css";css.textContent=".pcm-page{padding:26px;max-width:1400px;margin:auto}.pcm-hero{display:flex;justify-content:space-between;gap:20px;align-items:flex-start;background:linear-gradient(135deg,#003c41,#0b6659);color:#fff;border-radius:18px;padding:28px 30px;margin-bottom:14px}.pcm-kicker{font-size:11px;font-weight:800;letter-spacing:.12em;opacity:.78}.pcm-hero h1{margin:7px 0 5px;font-size:27px}.pcm-hero p{margin:0;max-width:780px;line-height:1.55;color:#d9eee8}.pcm-refresh{border:1px solid rgba(255,255,255,.25);background:rgba(255,255,255,.1);color:#fff;border-radius:10px;padding:10px 15px;cursor:pointer}.pcm-status{padding:11px 14px;border-radius:10px;margin-bottom:16px;font-size:13px}.pcm-status.ok{background:#eaf7f1;color:#176c4c}.pcm-status.warn{background:#fff5e6;color:#8a5a00}.pcm-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin-bottom:18px}.pcm-card{background:var(--surface,#fff);border:1px solid var(--border,#e3ece8);border-radius:14px;padding:16px}.pcm-card-head{display:flex;justify-content:space-between;align-items:center}.pcm-card-kicker{font-size:10px;color:#1a8f6b;font-weight:800}.pcm-card h3{margin:4px 0 0;color:#003c41;font-size:15px}.pcm-count{width:30px;height:30px;border-radius:50%;background:#eef7f3;color:#176c4c;display:grid;place-items:center;font-weight:800}.pcm-mini-list{margin-top:12px;font-size:12px;color:#66766f;display:grid;gap:5px}.pcm-more{font-weight:700;color:#1a8f6b}.pcm-editor{background:var(--surface,#fff);border:1px solid var(--border,#e3ece8);border-radius:16px;padding:20px;margin-top:14px}.pcm-editor-head{display:flex;justify-content:space-between;gap:16px;align-items:center;margin-bottom:15px}.pcm-editor-head h2{margin:0;color:#003c41;font-size:19px}.pcm-editor-head p{margin:4px 0 0;color:#6b7a75;font-size:12px}.pcm-editor-head select{padding:9px 12px;border:1px solid #d7e6df;border-radius:9px;background:#fff;min-width:230px}.pcm-table{border:1px solid #e4ece8;border-radius:12px;overflow:hidden}.pcm-tr{display:grid;grid-template-columns:1.5fr 1.2fr .5fr .7fr 1.2fr;gap:12px;align-items:center;padding:11px 13px;border-bottom:1px solid #edf2ef;font-size:13px}.pcm-tr:last-child{border-bottom:0}.pcm-th{background:#f7faf8;font-size:11px;font-weight:800;color:#6b7a75;text-transform:uppercase}.pcm-actions{display:flex;gap:6px;justify-content:flex-end}.pcm-actions button,.pcm-family-row button{border:0;background:#eef5f1;color:#1b5e4c;border-radius:8px;padding:7px 9px;cursor:pointer}.pcm-actions .danger,.pcm-family-row .danger{color:#a12f36;background:#fdeeee}.pcm-badge{display:inline-block;padding:4px 7px;border-radius:99px;font-size:10px;font-weight:800}.pcm-badge.on{background:#e6f7ee;color:#0f7a44}.pcm-badge.off{background:#f1f3f2;color:#6b7a75}.pcm-add,.pcm-primary{margin-top:12px;border:0;border-radius:9px;padding:9px 13px;cursor:pointer;background:#eef5f1;color:#155c4a;font-weight:700}.pcm-primary{background:#003c41;color:#fff}.pcm-family-row{display:flex;justify-content:space-between;align-items:center;border:1px solid #e6eee9;border-radius:11px;padding:12px 14px;margin-bottom:8px}.pcm-family-row small{display:block;color:#6b7a75;margin-top:3px}.pcm-empty{padding:16px;color:#6b7a75}.pcm-modal{position:fixed;inset:0;background:rgba(0,20,18,.48);display:grid;place-items:center;z-index:1000;padding:18px}.pcm-modal-box{background:#fff;border-radius:16px;padding:20px;width:min(520px,100%);max-height:90vh;overflow:auto;box-shadow:0 18px 60px rgba(0,0,0,.2)}.pcm-wide{width:min(700px,100%)}.pcm-modal-head{display:flex;justify-content:space-between;align-items:center;margin-bottom:16px}.pcm-modal-head h3{margin:0;color:#003c41}.pcm-modal-head button{border:0;background:transparent;font-size:25px;cursor:pointer}.pcm-modal-box label{display:block;font-size:12px;font-weight:700;color:#566a62;margin:12px 0 6px}.pcm-modal-box input,.pcm-modal-box select{width:100%;padding:10px 11px;border:1px solid #d7e6df;border-radius:9px;outline:none}.pcm-modal-actions{display:flex;justify-content:flex-end;gap:8px;margin-top:18px}.pcm-modal-actions button{border:0;background:#eef5f1;padding:9px 13px;border-radius:9px;cursor:pointer}.pcm-field{display:grid;grid-template-columns:1fr auto auto;gap:8px;align-items:center;margin-bottom:8px}.pcm-field label{margin:0;white-space:nowrap}.pcm-field button{border:0;background:#fdeeee;color:#a12f36;border-radius:7px;padding:7px;cursor:pointer}@media(max-width:1050px){.pcm-grid{grid-template-columns:repeat(2,1fr)}}@media(max-width:650px){.pcm-page{padding:14px}.pcm-grid{grid-template-columns:1fr}.pcm-hero{padding:20px;display:block}.pcm-refresh{margin-top:12px}.pcm-editor-head{display:block}.pcm-editor-head select{margin-top:12px;width:100%}.pcm-tr{grid-template-columns:1fr;gap:5px}.pcm-actions{justify-content:flex-start}.pcm-field{grid-template-columns:1fr auto auto}}";document.head.appendChild(css);
})();