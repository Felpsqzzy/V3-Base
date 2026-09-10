/* BIOTROP V3-Base — ponte Supabase + menu por perfil (segura) */
(function () {
  'use strict';

  const SUPABASE_URL = 'https://hoikliqttxqdsyyjdnul.supabase.co';
  const SUPABASE_KEY = 'sb_publishable_PeiXiPCMENjp9ajwW-EbJw_IohMAt1h';
  const BRIDGE = { ready:false, syncing:false, session:null, client:null, started:false };
  window.BIOTROP_DB = BRIDGE;

  function currentUser(){
    try { return window.STATE && STATE.currentUser ? STATE.currentUser : null; }
    catch (_) { return null; }
  }

  function isAdmin(){
    try {
      const u=currentUser();
      return !!(u && typeof window.isAdminUser==='function' && window.isAdminUser(u));
    } catch (_) { return false; }
  }

  function isTechnician(){
    const u=currentUser();
    try {
      if (u && !isAdmin()) {
        const pid=String(u.perfilId||u.perfil||u.role||'').toLowerCase();
        if (pid.includes('tecnico') || pid.includes('técnico')) return true;
        if (typeof window.getProfile==='function') {
          const p=window.getProfile(u);
          const n=String((p&&p.nome)||'').toLowerCase();
          if (n.includes('tecnico') || n.includes('técnico')) return true;
        }
      }
    } catch (_) {}
    const roleEls=document.querySelectorAll('.user-role,.bt-rolepill__role,.sidebar .user-role');
    for (const el of roleEls) {
      const t=String(el.textContent||'').toLowerCase();
      if (t.includes('técnico') || t.includes('tecnico')) return true;
    }
    return false;
  }

  function loadSdk(){
    return new Promise(function(resolve,reject){
      if(window.supabase && window.supabase.createClient) return resolve();
      const s=document.createElement('script');
      s.src='https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2';
      s.onload=resolve; s.onerror=reject;
      document.head.appendChild(s);
    });
  }

  async function signInLocalUser(){
    const u=currentUser();
    if(!u || !u.usuario || !u.senha) return null;
    const email=String(u.usuario).trim().toLowerCase();
    if(!email.includes('@')) return null;
    try {
      const r=await BRIDGE.client.auth.signInWithPassword({email,password:String(u.senha)});
      if(r.error) return null;
      BRIDGE.session=r.data.session||null;
      return BRIDGE.session;
    } catch (_) { return null; }
  }

  function localFromService(row){
    const m=row&&row.metadata&&typeof row.metadata==='object'?row.metadata:{};
    const x=Object.assign({},m);
    x.id=x.id||row.request_number; x.codigo=x.codigo||row.request_number;
    x.status=x.status||row.status||'aberto';
    x.solicitanteId=x.solicitanteId||row.requester_id;
    x.dataCriacao=x.dataCriacao||row.created_at;
    x._dbId=row.id; x._dbTable='service_requests';
    return x;
  }

  function localFromPurchase(row){
    const m=row&&row.metadata&&typeof row.metadata==='object'?row.metadata:{};
    const x=Object.assign({},m);
    x.id=x.id||row.code; x.codigo=x.codigo||row.code;
    x.status=x.status||row.status||'pendente_aprovacao_lider';
    x.solicitanteId=x.solicitanteId||row.requester_id;
    x.dataCriacao=x.dataCriacao||row.created_at;
    x._dbId=row.id; x._dbTable='purchase_requests';
    return x;
  }

  async function pullDatabase(){
    if(!BRIDGE.session || BRIDGE.syncing) return;
    BRIDGE.syncing=true;
    try {
      const [sci,scm]=await Promise.all([
        BRIDGE.client.from('service_requests').select('*').eq('active',true).order('created_at',{ascending:false}),
        BRIDGE.client.from('purchase_requests').select('*').eq('active',true).order('created_at',{ascending:false})
      ]);
      if(!sci.error && Array.isArray(sci.data) && typeof window.SCI_LIST!=='undefined'){
        const db=sci.data.map(localFromService), local=Array.isArray(window.SCI_LIST)?window.SCI_LIST.slice():[];
        const ids=new Set(db.map(x=>String(x._dbId)));
        window.SCI_LIST=db.concat(local.filter(x=>!x._dbId || !ids.has(String(x._dbId))));
        if(typeof window.saveSci==='function') window.saveSci(window.SCI_LIST);
      }
      if(!scm.error && Array.isArray(scm.data) && typeof window.SCM_LIST!=='undefined'){
        const db=scm.data.map(localFromPurchase), local=Array.isArray(window.SCM_LIST)?window.SCM_LIST.slice():[];
        const ids=new Set(db.map(x=>String(x._dbId)));
        window.SCM_LIST=db.concat(local.filter(x=>!x._dbId || !ids.has(String(x._dbId))));
        if(typeof window.saveScm==='function') window.saveScm(window.SCM_LIST);
      }
    } finally { BRIDGE.syncing=false; }
  }

  function belongsToCurrentUser(x){
    const u=currentUser(); if(!u) return false;
    const email=String(u.usuario||'').trim().toLowerCase();
    return String(x.solicitanteId||'')===String(u.id||'') || String(x.solicitanteEmail||'').trim().toLowerCase()===email;
  }

  function metadataOf(o){ return Object.assign({},o,{_biotrop_source:'v3-base-local',_biotrop_local_id:o&&o.id?String(o.id):null}); }

  async function pushSci(list){
    if(!BRIDGE.session||BRIDGE.syncing||!Array.isArray(list)) return;
    const uid=BRIDGE.session.user.id;
    for(const s of list.filter(belongsToCurrentUser).filter(x=>!x._dbId)){
      const row={request_number:String(s.codigo||s.id),requester_id:uid,description:[s.familiaNome,s.observacoes].filter(Boolean).join(' — ').slice(0,10000),quantity:null,unit:null,justification:s.observacoes||null,process_number:s.numeroSolicitacaoCadastro||s.numeroProcessoME||null,warehouse_note:s.observacaoAlmoxarife||null,status:s.status||'aberto',active:true,metadata:metadataOf(s)};
      const r=await BRIDGE.client.from('service_requests').upsert(row,{onConflict:'request_number'}).select('id').maybeSingle();
      if(!r.error&&r.data) s._dbId=r.data.id;
    }
  }

  async function pushScm(list){
    if(!BRIDGE.session||BRIDGE.syncing||!Array.isArray(list)) return;
    const uid=BRIDGE.session.user.id;
    for(const s of list.filter(belongsToCurrentUser).filter(x=>!x._dbId)){
      const row={code:String(s.codigo||s.id),requester_id:uid,description:s.descricaoUso||null,team:s.timeSolicitante||null,urgency:s.urgencia||null,cost_center:s.centroCusto||null,justification:s.descricaoUso||null,approval_note:s.observacaoLider||null,status:s.status||'pendente_aprovacao_lider',active:true,metadata:metadataOf(s)};
      const r=await BRIDGE.client.from('purchase_requests').upsert(row,{onConflict:'code'}).select('id').maybeSingle();
      if(!r.error&&r.data) s._dbId=r.data.id;
    }
  }

  function softDelete(table,id){
    if(!BRIDGE.session||!id) return Promise.resolve(false);
    return BRIDGE.client.from(table).update({active:false,deleted_at:new Date().toISOString()}).eq('id',id).then(function(r){
      if(r.error){ alert('Não foi possível excluir no banco: '+r.error.message); return false; }
      return true;
    });
  }

  function localDelete(kind,id){
    if(!isAdmin()){ alert('A exclusão é exclusiva do Administrador.'); return; }
    const list=kind==='sci'?(window.SCI_LIST||[]):(window.SCM_LIST||[]);
    const item=list.find(x=>String(x.id)===String(id));
    if(!item || !confirm('Excluir '+(item.codigo||id)+'?')) return;
    (async function(){
      if(item._dbId && !(await softDelete(kind==='sci'?'service_requests':'purchase_requests',item._dbId))) return;
      if(kind==='sci') window.SCI_LIST=list.filter(x=>String(x.id)!==String(id));
      else window.SCM_LIST=list.filter(x=>String(x.id)!==String(id));
      if(kind==='sci' && typeof window.saveSci==='function') window.saveSci(window.SCI_LIST);
      if(kind==='scm' && typeof window.saveScm==='function') window.saveScm(window.SCM_LIST);
      if(typeof window.navigateTo==='function') window.navigateTo(kind==='sci'?'almox_solicitacoes':'almox_scm_gestao');
    })();
  }

  function injectDeleteButtons(){
    if(!isAdmin()) return;
    document.querySelectorAll('[data-sci-view]').forEach(function(btn){
      const id=btn.getAttribute('data-sci-view');
      if(!btn.parentElement || btn.parentElement.querySelector('[data-bt-db-delete="sci-'+id+'"]')) return;
      const b=document.createElement('button'); b.className='icon-btn danger'; b.type='button'; b.title='Excluir SCI';
      b.setAttribute('data-bt-db-delete','sci-'+id); b.textContent='🗑';
      b.onclick=function(e){e.stopPropagation();localDelete('sci',id);}; btn.parentElement.appendChild(b);
    });
    document.querySelectorAll('[data-scm-manage]').forEach(function(btn){
      const id=btn.getAttribute('data-scm-manage');
      if(!btn.parentElement || btn.parentElement.querySelector('[data-bt-db-delete="scm-'+id+'"]')) return;
      const b=document.createElement('button'); b.className='icon-btn danger'; b.type='button'; b.title='Excluir SCM';
      b.setAttribute('data-bt-db-delete','scm-'+id); b.textContent='🗑';
      b.onclick=function(e){e.stopPropagation();localDelete('scm',id);}; btn.parentElement.appendChild(b);
    });
  }

  function navButton(id,label,icon){
    const b=document.createElement('button');
    b.type='button'; b.className='nav-item bt-tech-added-nav';
    b.setAttribute('data-nav',id); b.setAttribute('data-bt-tech-nav',id);
    b.innerHTML='<span style="width:18px;display:inline-flex;justify-content:center" aria-hidden="true">'+icon+'</span><span>'+label+'</span>';
    b.onclick=function(e){e.preventDefault();e.stopPropagation();if(typeof window.navigateTo==='function')window.navigateTo(id);};
    return b;
  }

  function injectTechnicianMenu(){
    if(!isTechnician()) return;
    const nav=document.querySelector('.sidebar-nav')||document.querySelector('.bt-nav')||document.getElementById('sidebar-nav');
    if(!nav) return;
    // IMPORTANT: do not remove/reinsert on every DOM mutation. That caused an infinite MutationObserver loop.
    const wanted=[
      ['almox_solicitacoes','Solicitações (SCI)','▤'],
      ['almox_scm_form','Nova compra (SCM)','🛒'],
      ['almox_scm_gestao','Gestão de SCM','▤']
    ];
    let anchor=Array.from(nav.querySelectorAll('button')).find(x=>/minhas solicitações/i.test(x.textContent||''));
    if(!anchor) anchor=Array.from(nav.querySelectorAll('button')).find(x=>/nova solicitação/i.test(x.textContent||''));
    wanted.forEach(function(item){
      if(nav.querySelector('[data-bt-tech-nav="'+item[0]+'"]')) return;
      const b=navButton(item[0],item[1],item[2]);
      if(anchor && anchor.parentElement){ anchor.insertAdjacentElement('afterend',b); anchor=b; }
      else nav.appendChild(b);
    });
  }

  function wrapSaveFunctions(){
    if(typeof window.saveSci==='function'&&!window.saveSci.__btWrapped){
      const old=window.saveSci; window.saveSci=function(list){const r=old(list);if(!BRIDGE.syncing)pushSci(list);return r;}; window.saveSci.__btWrapped=true;
    }
    if(typeof window.saveScm==='function'&&!window.saveScm.__btWrapped){
      const old=window.saveScm; window.saveScm=function(list){const r=old(list);if(!BRIDGE.syncing)pushScm(list);return r;}; window.saveScm.__btWrapped=true;
    }
  }

  async function start(){
    if(BRIDGE.started) return; BRIDGE.started=true;
    try{
      const observer=new MutationObserver(function(){
        // Run at most once per event loop turn; if the menu already exists nothing is changed.
        if(!BRIDGE._scheduled){
          BRIDGE._scheduled=true;
          setTimeout(function(){BRIDGE._scheduled=false;wrapSaveFunctions();injectDeleteButtons();injectTechnicianMenu();},0);
        }
      });
      if(document.body) observer.observe(document.body,{childList:true,subtree:true});
      injectTechnicianMenu();
      await loadSdk();
      BRIDGE.client=window.supabase.createClient(SUPABASE_URL,SUPABASE_KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});
      const ses=await signInLocalUser();
      if(!ses){ injectTechnicianMenu(); return; }
      BRIDGE.ready=true;
      await pullDatabase();
      wrapSaveFunctions(); await pushSci(window.SCI_LIST||[]); await pushScm(window.SCM_LIST||[]);
      injectDeleteButtons(); injectTechnicianMenu();
      console.info('[BIOTROP] Supabase conectado');
    }catch(e){
      injectTechnicianMenu();
      console.warn('[BIOTROP] ponte Supabase indisponível:',e);
    }
  }

  setTimeout(start,250);
})();