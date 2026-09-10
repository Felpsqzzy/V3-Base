/* BIOTROP V3-Base — ponte Supabase + menu por perfil */
(function () {
  'use strict';
  const SUPABASE_URL = 'https://hoikliqttxqdsyyjdnul.supabase.co';
  const SUPABASE_KEY = 'sb_publishable_PeiXiPCMENjp9ajwW-EbJw_IohMAt1h';
  const BRIDGE = { ready:false, syncing:false, session:null, client:null };
  window.BIOTROP_DB = BRIDGE;

  function loadSdk(){return new Promise(function(resolve,reject){if(window.supabase&&window.supabase.createClient)return resolve();const s=document.createElement('script');s.src='https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2';s.onload=resolve;s.onerror=reject;document.head.appendChild(s);});}
  function currentUser(){try{return window.STATE&&STATE.currentUser?STATE.currentUser:null;}catch(_){return null;}}
  function isAdmin(){try{const u=currentUser();return !!(u&&typeof isAdminUser==='function'&&isAdminUser(u));}catch(_){return false;}}

  /* Reconhece o Técnico tanto pelo estado da aplicação quanto pelo texto
     que a própria troca de visão coloca na sidebar. */
  function isTechnician(){
    const u=currentUser();
    if(u&&!isAdmin()){
      const pid=String(u.perfilId||'').trim().toLowerCase();
      if(pid==='tecnico'||pid.indexOf('tecnico')>=0)return true;
      try{const p=typeof getProfile==='function'?getProfile(u):null;const pn=String(p&&p.nome||'').trim().toLowerCase();if(pn.indexOf('técnico')>=0||pn.indexOf('tecnico')>=0)return true;}catch(_){ }
    }
    const selectors=['.user-role','.bt-rolepill__role','.sidebar .user-role','.sidebar'];
    for(let i=0;i<selectors.length;i++){
      try{const els=document.querySelectorAll(selectors[i]);for(let j=0;j<els.length;j++){const txt=String(els[j].textContent||'').toLowerCase();if(/(^|[^a-z])t[eé]cnico([^a-z]|$)/i.test(txt))return true;}}catch(_){ }
    }
    return false;
  }

  function metadataOf(o){return Object.assign({},o,{_biotrop_source:'v3-base-local',_biotrop_local_id:o&&o.id?String(o.id):null});}
  async function signInLocalUser(){const u=currentUser();if(!u||!u.usuario||!u.senha)return null;const email=String(u.usuario).trim().toLowerCase();if(!email||email.indexOf('@')<0)return null;const r=await BRIDGE.client.auth.signInWithPassword({email:email,password:String(u.senha)});if(r.error)return null;BRIDGE.session=r.data.session||null;return BRIDGE.session;}
  function localFromService(row){const m=row&&row.metadata&&typeof row.metadata==='object'?row.metadata:{};const x=Object.assign({},m);x.id=x.id||row.request_number;x.codigo=x.codigo||row.request_number;x.status=x.status||row.status||'aberto';x.solicitanteId=x.solicitanteId||row.requester_id;x.dataCriacao=x.dataCriacao||row.created_at;x._dbId=row.id;x._dbTable='service_requests';return x;}
  function localFromPurchase(row){const m=row&&row.metadata&&typeof row.metadata==='object'?row.metadata:{};const x=Object.assign({},m);x.id=x.id||row.code;x.codigo=x.codigo||row.code;x.status=x.status||row.status||'pendente_aprovacao_lider';x.solicitanteId=x.solicitanteId||row.requester_id;x.dataCriacao=x.dataCriacao||row.created_at;x._dbId=row.id;x._dbTable='purchase_requests';return x;}
  async function pullDatabase(){if(!BRIDGE.session)return;BRIDGE.syncing=true;try{const a=await Promise.all([BRIDGE.client.from('service_requests').select('*').eq('active',true).order('created_at',{ascending:false}),BRIDGE.client.from('purchase_requests').select('*').eq('active',true).order('created_at',{ascending:false})]);const sci=a[0],scm=a[1];if(!sci.error&&Array.isArray(sci.data)&&typeof SCI_LIST!=='undefined'){const db=sci.data.map(localFromService),local=Array.isArray(SCI_LIST)?SCI_LIST.slice():[],ids={};db.forEach(x=>ids[String(x._dbId)]=1);SCI_LIST=db.concat(local.filter(x=>!x._dbId||!ids[String(x._dbId)]));if(typeof saveSci==='function')saveSci(SCI_LIST);}if(!scm.error&&Array.isArray(scm.data)&&typeof SCM_LIST!=='undefined'){const db=scm.data.map(localFromPurchase),local=Array.isArray(SCM_LIST)?SCM_LIST.slice():[],ids={};db.forEach(x=>ids[String(x._dbId)]=1);SCM_LIST=db.concat(local.filter(x=>!x._dbId||!ids[String(x._dbId)]));if(typeof saveScm==='function')saveScm(SCM_LIST);}}finally{BRIDGE.syncing=false;}}
  function belongsToCurrentUser(x){const u=currentUser();if(!u)return false;const email=String(u.usuario||'').trim().toLowerCase();return String(x.solicitanteId||'')===String(u.id||'')||String(x.solicitanteEmail||'').trim().toLowerCase()===email;}
  async function pushSci(list){if(!BRIDGE.session||BRIDGE.syncing||!Array.isArray(list))return;const uid=BRIDGE.session.user.id;for(const s of list.filter(belongsToCurrentUser).filter(x=>!x._dbId)){const row={request_number:String(s.codigo||s.id),requester_id:uid,description:[s.familiaNome,s.observacoes].filter(Boolean).join(' — ').slice(0,10000),quantity:null,unit:null,justification:s.observacoes||null,process_number:s.numeroSolicitacaoCadastro||s.numeroProcessoME||null,warehouse_note:s.observacaoAlmoxarife||null,status:s.status||'aberto',active:true,metadata:metadataOf(s)};const r=await BRIDGE.client.from('service_requests').upsert(row,{onConflict:'request_number'}).select('id').maybeSingle();if(!r.error&&r.data)s._dbId=r.data.id;}}
  async function pushScm(list){if(!BRIDGE.session||BRIDGE.syncing||!Array.isArray(list))return;const uid=BRIDGE.session.user.id;for(const s of list.filter(belongsToCurrentUser).filter(x=>!x._dbId)){const row={code:String(s.codigo||s.id),requester_id:uid,description:s.descricaoUso||null,team:s.timeSolicitante||null,urgency:s.urgencia||null,cost_center:s.centroCusto||null,justification:s.descricaoUso||null,approval_note:s.observacaoLider||null,status:s.status||'pendente_aprovacao_lider',active:true,metadata:metadataOf(s)};const r=await BRIDGE.client.from('purchase_requests').upsert(row,{onConflict:'code'}).select('id').maybeSingle();if(!r.error&&r.data)s._dbId=r.data.id;}}
  async function softDelete(table,id){if(!BRIDGE.session||!id)return false;const r=await BRIDGE.client.from(table).update({active:false,deleted_at:new Date().toISOString()}).eq('id',id);if(r.error){alert('Não foi possível excluir no banco: '+r.error.message);return false;}return true;}
  function localDelete(kind,id){if(!isAdmin()){alert('A exclusão é exclusiva do Administrador.');return;}const list=kind==='sci'?(window.SCI_LIST||[]):(window.SCM_LIST||[]),item=list.find(x=>String(x.id)===String(id));if(!item)return;if(!confirm('Excluir definitivamente a solicitação '+(item.codigo||id)+'? Ela será removida da operação e marcada como excluída no banco.'))return;(async function(){if(item._dbId){const ok=await softDelete(kind==='sci'?'service_requests':'purchase_requests',item._dbId);if(!ok)return;}if(kind==='sci'){window.SCI_LIST=list.filter(x=>String(x.id)!==String(id));if(typeof saveSci==='function')saveSci(window.SCI_LIST);}else{window.SCM_LIST=list.filter(x=>String(x.id)!==String(id));if(typeof saveScm==='function')saveScm(window.SCM_LIST);}if(typeof renderAlmoxTabContent==='function')renderAlmoxTabContent();else if(typeof navigateTo==='function')navigateTo(kind==='sci'?'almox_solicitacoes':'almox_scm_gestao');})();}
  function injectDeleteButtons(){if(!isAdmin())return;document.querySelectorAll('[data-sci-view]').forEach(function(btn){const id=btn.getAttribute('data-sci-view');if(btn.parentElement&&!btn.parentElement.querySelector('[data-bt-db-delete="sci-'+id+'"]')){const b=document.createElement('button');b.className='icon-btn danger';b.title='Excluir SCI';b.setAttribute('data-bt-db-delete','sci-'+id);b.innerHTML='🗑';b.onclick=function(e){e.stopPropagation();localDelete('sci',id);};btn.parentElement.appendChild(b);}});document.querySelectorAll('[data-scm-manage]').forEach(function(btn){const id=btn.getAttribute('data-scm-manage');if(btn.parentElement&&!btn.parentElement.querySelector('[data-bt-db-delete="scm-'+id+'"]')){const b=document.createElement('button');b.className='icon-btn danger';b.title='Excluir SCM';b.setAttribute('data-bt-db-delete','scm-'+id);b.innerHTML='🗑';b.onclick=function(e){e.stopPropagation();localDelete('scm',id);};btn.parentElement.appendChild(b);}});}

  function navButton(id,label,icon){
    const b=document.createElement('button');
    b.type='button';
    b.className='nav-item bt-tech-added-nav';
    b.setAttribute('data-nav',id);
    b.setAttribute('data-bt-tech-nav',id);
    b.innerHTML='<span style="width:18px;display:inline-flex;justify-content:center" aria-hidden="true">'+icon+'</span><span>'+label+'</span>';
    b.onclick=function(e){e.preventDefault();e.stopPropagation();if(typeof navigateTo==='function')navigateTo(id);};
    return b;
  }

  /* A troca de visão recria a sidebar. Em vez de tentar alterar a função
     interna de renderização, este bloco reaplica o menu do Técnico toda vez
     que a aba/perfil muda. */
  function injectTechnicianMenu(){
    if(!isTechnician())return;
    const nav=document.querySelector('.sidebar-nav')||document.querySelector('.bt-nav')||document.getElementById('sidebar-nav');
    if(!nav)return;

    nav.querySelectorAll('[data-bt-tech-nav]').forEach(function(x){x.remove();});

    const all=Array.from(nav.querySelectorAll('button.nav-item,button.bt-nav__item,button'));
    const anchor=all.find(function(x){return /minhas solicitações/i.test(String(x.textContent||''));})||all.find(function(x){return /nova solicitação/i.test(String(x.textContent||''));});

    const items=[
      navButton('almox_solicitacoes','Solicitações (SCI)','▤'),
      navButton('almox_scm_form','Nova compra (SCM)','🛒'),
      navButton('almox_scm_gestao','Gestão de SCM','▤')
    ];
    items.forEach(function(b){
      if(anchor&&anchor.parentElement)anchor.insertAdjacentElement('afterend',b);
      else nav.appendChild(b);
      anchor=anchor;
    });
  }

  function wrapSaveFunctions(){if(typeof window.saveSci==='function'&&!window.saveSci.__btWrapped){const old=window.saveSci;window.saveSci=function(list){const r=old(list);if(!BRIDGE.syncing)pushSci(list);return r;};window.saveSci.__btWrapped=true;}if(typeof window.saveScm==='function'&&!window.saveScm.__btWrapped){const old=window.saveScm;window.saveScm=function(list){const r=old(list);if(!BRIDGE.syncing)pushScm(list);return r;}}}

  async function start(){
    try{
      const observer=new MutationObserver(function(){wrapSaveFunctions();injectDeleteButtons();injectTechnicianMenu();});
      observer.observe(document.body,{childList:true,subtree:true});
      injectTechnicianMenu();
      await loadSdk();
      BRIDGE.client=window.supabase.createClient(SUPABASE_URL,SUPABASE_KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});
      const ses=await signInLocalUser();
      if(!ses){injectTechnicianMenu();return;}
      BRIDGE.ready=true;
      await pullDatabase();
      wrapSaveFunctions();
      await pushSci(window.SCI_LIST||[]);
      await pushScm(window.SCM_LIST||[]);
      injectDeleteButtons();
      injectTechnicianMenu();
      console.info('[BIOTROP] Supabase conectado:',SUPABASE_URL);
    }catch(e){injectTechnicianMenu();console.warn('[BIOTROP] ponte Supabase indisponível:',e);}
  }
  setTimeout(start,250);
})();