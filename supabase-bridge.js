/* BIOTROP V3-Base — ponte Supabase + exclusão administrativa SCI/SCM */
(function () {
  'use strict';
  const SUPABASE_URL = 'https://hoikliqttxqdsyyjdnul.supabase.co';
  const SUPABASE_KEY = 'sb_publishable_PeiXiPCMENjp9ajwW-EbJw_IohMAt1h';
  const BRIDGE = { ready:false, syncing:false, session:null, client:null };
  window.BIOTROP_DB = BRIDGE;

  function loadSdk() {
    return new Promise(function(resolve, reject) {
      if (window.supabase && window.supabase.createClient) return resolve();
      const s = document.createElement('script');
      s.src = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2';
      s.onload = resolve;
      s.onerror = reject;
      document.head.appendChild(s);
    });
  }
  function currentUser() { try { return window.STATE && STATE.currentUser ? STATE.currentUser : null; } catch (_) { return null; } }
  function isAdmin() { try { return !!(currentUser() && typeof isAdminUser === 'function' && isAdminUser(currentUser())); } catch (_) { return false; } }
  function metadataOf(obj) { return Object.assign({}, obj, { _biotrop_source:'v3-base-local', _biotrop_local_id: obj && obj.id ? String(obj.id) : null }); }

  async function signInLocalUser() {
    const u = currentUser();
    if (!u || !u.usuario || !u.senha) return null;
    const email = String(u.usuario).trim().toLowerCase();
    if (!email || email.indexOf('@') < 0) return null;
    const r = await BRIDGE.client.auth.signInWithPassword({ email:email, password:String(u.senha) });
    if (r.error) return null;
    BRIDGE.session = r.data.session || null;
    return BRIDGE.session;
  }
  function localFromService(row) {
    const m = row && row.metadata && typeof row.metadata === 'object' ? row.metadata : {};
    const base = Object.assign({}, m);
    base.id = base.id || row.request_number; base.codigo = base.codigo || row.request_number;
    base.status = base.status || row.status || 'aberto'; base.solicitanteId = base.solicitanteId || row.requester_id;
    base.dataCriacao = base.dataCriacao || row.created_at; base._dbId = row.id; base._dbTable = 'service_requests';
    return base;
  }
  function localFromPurchase(row) {
    const m = row && row.metadata && typeof row.metadata === 'object' ? row.metadata : {};
    const base = Object.assign({}, m);
    base.id = base.id || row.code; base.codigo = base.codigo || row.code;
    base.status = base.status || row.status || 'pendente_aprovacao_lider'; base.solicitanteId = base.solicitanteId || row.requester_id;
    base.dataCriacao = base.dataCriacao || row.created_at; base._dbId = row.id; base._dbTable = 'purchase_requests';
    return base;
  }
  async function pullDatabase() {
    if (!BRIDGE.session) return;
    BRIDGE.syncing = true;
    try {
      const [sciRes, scmRes] = await Promise.all([
        BRIDGE.client.from('service_requests').select('*').eq('active',true).order('created_at',{ascending:false}),
        BRIDGE.client.from('purchase_requests').select('*').eq('active',true).order('created_at',{ascending:false})
      ]);
      if (!sciRes.error && Array.isArray(sciRes.data) && typeof SCI_LIST !== 'undefined') {
        const dbItems=sciRes.data.map(localFromService), local=Array.isArray(SCI_LIST)?SCI_LIST.slice():[], ids={};
        dbItems.forEach(function(x){ids[String(x._dbId)]=true;});
        SCI_LIST=dbItems.concat(local.filter(function(x){return !x._dbId || !ids[String(x._dbId)];}));
        if (typeof saveSci==='function') saveSci(SCI_LIST);
      }
      if (!scmRes.error && Array.isArray(scmRes.data) && typeof SCM_LIST !== 'undefined') {
        const dbItems=scmRes.data.map(localFromPurchase), local=Array.isArray(SCM_LIST)?SCM_LIST.slice():[], ids={};
        dbItems.forEach(function(x){ids[String(x._dbId)]=true;});
        SCM_LIST=dbItems.concat(local.filter(function(x){return !x._dbId || !ids[String(x._dbId)];}));
        if (typeof saveScm==='function') saveScm(SCM_LIST);
      }
    } finally { BRIDGE.syncing=false; }
  }
  async function pushSci(list) {
    if (!BRIDGE.session || BRIDGE.syncing || !Array.isArray(list)) return;
    const uid=BRIDGE.session.user.id, me=String(currentUser()?.usuario || '').toLowerCase();
    for (const s of list.filter(function(x){return !x._dbId && String(x.solicitanteEmail || x.solicitanteId || '').toLowerCase()===me;})) {
      const row={request_number:String(s.codigo||s.id),requester_id:uid,description:[s.familiaNome,s.observacoes].filter(Boolean).join(' — ').slice(0,10000),quantity:null,unit:null,justification:s.observacoes||null,process_number:s.numeroSolicitacaoCadastro||s.numeroProcessoME||null,warehouse_note:s.observacaoAlmoxarife||null,status:s.status||'aberto',active:true,metadata:metadataOf(s)};
      const r=await BRIDGE.client.from('service_requests').upsert(row,{onConflict:'request_number'}).select('id').maybeSingle();
      if(!r.error&&r.data)s._dbId=r.data.id;
    }
  }
  async function pushScm(list) {
    if (!BRIDGE.session || BRIDGE.syncing || !Array.isArray(list)) return;
    const uid=BRIDGE.session.user.id, me=String(currentUser()?.usuario || '').toLowerCase();
    for (const s of list.filter(function(x){return !x._dbId && String(x.solicitanteEmail || x.solicitanteId || '').toLowerCase()===me;})) {
      const row={code:String(s.codigo||s.id),requester_id:uid,description:s.descricaoUso||null,team:s.timeSolicitante||null,urgency:s.urgencia||null,cost_center:s.centroCusto||null,justification:s.descricaoUso||null,approval_note:s.observacaoLider||null,status:s.status||'pendente_aprovacao_lider',active:true,metadata:metadataOf(s)};
      const r=await BRIDGE.client.from('purchase_requests').upsert(row,{onConflict:'code'}).select('id').maybeSingle();
      if(!r.error&&r.data)s._dbId=r.data.id;
    }
  }
  async function softDelete(table,id) {
    if(!BRIDGE.session||!id)return false;
    const r=await BRIDGE.client.from(table).update({active:false,deleted_at:new Date().toISOString()}).eq('id',id);
    if(r.error){alert('Não foi possível excluir no banco: '+r.error.message);return false;} return true;
  }
  function localDelete(kind,id) {
    if(!isAdmin()){alert('A exclusão é exclusiva do Administrador.');return;}
    const list=kind==='sci'?(window.SCI_LIST||[]):(window.SCM_LIST||[]), item=list.find(function(x){return String(x.id)===String(id);});
    if(!item)return;
    if(!confirm('Excluir definitivamente a solicitação '+(item.codigo||id)+'? Ela será removida da operação e marcada como excluída no banco.'))return;
    (async function(){
      if(item._dbId){const ok=await softDelete(kind==='sci'?'service_requests':'purchase_requests',item._dbId);if(!ok)return;}
      if(kind==='sci'){window.SCI_LIST=list.filter(function(x){return String(x.id)!==String(id);});if(typeof saveSci==='function')saveSci(window.SCI_LIST);}
      else {window.SCM_LIST=list.filter(function(x){return String(x.id)!==String(id);});if(typeof saveScm==='function')saveScm(window.SCM_LIST);}
      if(typeof renderAlmoxTabContent==='function')renderAlmoxTabContent();
      else if(typeof navigateTo==='function')navigateTo(kind==='sci'?'almox_solicitacoes':'almox_scm_gestao');
    })();
  }
  function injectDeleteButtons() {
    if(!isAdmin())return;
    document.querySelectorAll('[data-sci-view]').forEach(function(btn){
      const id=btn.getAttribute('data-sci-view');
      if(btn.parentElement&&!btn.parentElement.querySelector('[data-bt-db-delete="sci-'+id+'"]')){
        const b=document.createElement('button');b.className='icon-btn danger';b.title='Excluir SCI';b.setAttribute('data-bt-db-delete','sci-'+id);b.innerHTML='🗑';b.onclick=function(e){e.stopPropagation();localDelete('sci',id);};btn.parentElement.appendChild(b);
      }
    });
    document.querySelectorAll('[data-scm-manage]').forEach(function(btn){
      const id=btn.getAttribute('data-scm-manage');
      if(btn.parentElement&&!btn.parentElement.querySelector('[data-bt-db-delete="scm-'+id+'"]')){
        const b=document.createElement('button');b.className='icon-btn danger';b.title='Excluir SCM';b.setAttribute('data-bt-db-delete','scm-'+id);b.innerHTML='🗑';b.onclick=function(e){e.stopPropagation();localDelete('scm',id);};btn.parentElement.appendChild(b);
      }
    });
  }
  function wrapSaveFunctions(){
    if(typeof window.saveSci==='function'&&!window.saveSci.__btWrapped){const old=window.saveSci;window.saveSci=function(list){const r=old(list);if(!BRIDGE.syncing)pushSci(list);return r;};window.saveSci.__btWrapped=true;}
    if(typeof window.saveScm==='function'&&!window.saveScm.__btWrapped){const old=window.saveScm;window.saveScm=function(list){const r=old(list);if(!BRIDGE.syncing)pushScm(list);return r;};window.saveScm.__btWrapped=true;}
  }
  async function start(){
    try{await loadSdk();BRIDGE.client=window.supabase.createClient(SUPABASE_URL,SUPABASE_KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});const ses=await signInLocalUser();if(!ses)return;BRIDGE.ready=true;await pullDatabase();wrapSaveFunctions();await pushSci(window.SCI_LIST||[]);await pushScm(window.SCM_LIST||[]);injectDeleteButtons();const observer=new MutationObserver(function(){wrapSaveFunctions();injectDeleteButtons();});observer.observe(document.body,{childList:true,subtree:true});console.info('[BIOTROP] Supabase conectado:',SUPABASE_URL);}catch(e){console.warn('[BIOTROP] ponte Supabase indisponível:',e);}
  }
  setTimeout(start,250);
})();
