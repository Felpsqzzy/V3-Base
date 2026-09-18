/* BIOTROP · PostgreSQL/Neon como fonte oficial
 * localStorage existe somente como cache de interface durante a transição.
 * Não usa Supabase. Escritas vão para /api/data e atualizações usam /api/realtime
 * com fallback para polling quando EventSource não estiver disponível.
 */
(function(){
  'use strict';

  var SYNC = {
    'btlocal.biotrop_sci_v1': 'sci',
    'btlocal.biotrop_scm_v1': 'scm',
    'btlocal.biotrop_utility_meters_v1': 'utility_meters',
    'btlocal.biotrop_utility_readings_v1': 'utility_readings'
  };
  var NAMESPACES = Object.keys(SYNC).map(function(k){ return SYNC[k]; });
  var KEY_BY_NS = {};
  NAMESPACES.forEach(function(ns, i){ KEY_BY_NS[ns] = Object.keys(SYNC)[i]; });

  var originalSetItem = null;
  var initialized = false;
  var applyingRemote = false;
  var authorized = false;
  var pollTimer = null;
  var pushTimers = {};
  var baseline = {};
  var lastSeen = {};
  var eventSources = {};
  var pendingReload = false;

  window.BIOTROP_SYNC_STATE = 'offline';
  window.BIOTROP_SYNC_CONFLICTS = [];

  function clone(value){
    try { return JSON.parse(JSON.stringify(value)); } catch (_) { return value; }
  }
  function parse(raw){
    try { return JSON.parse(raw); } catch (_) { return null; }
  }
  function getLocal(key){
    try {
      var raw = localStorage.getItem(key);
      return raw == null ? null : parse(raw);
    } catch (_) { return null; }
  }
  function setLocal(key, value){
    applyingRemote = true;
    try { localStorage.setItem(key, JSON.stringify(value)); } catch (_) {}
    applyingRemote = false;
  }
  function stableId(item, index){
    if(!item || typeof item !== 'object') return String(index);
    return String(item.id || item.codigo || item.code || item.request_number || item.requestNumber || ('row-'+index));
  }
  function mapArray(arr){
    var out = {};
    (Array.isArray(arr) ? arr : []).forEach(function(item, index){ out[stableId(item,index)] = item; });
    return out;
  }
  function editableFocus(){
    var el = document.activeElement;
    if(!el) return false;
    return /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName) || !!el.isContentEditable;
  }
  function dispatch(name, detail){
    try { window.dispatchEvent(new CustomEvent(name, {detail: detail || {}})); } catch (_) {}
  }
  async function request(url, options){
    var opts = options || {};
    opts.credentials = 'include';
    opts.headers = Object.assign({'Content-Type':'application/json'}, opts.headers || {});
    var r = await fetch(url, opts);
    var data = {};
    try { data = await r.json(); } catch (_) {}
    if(!r.ok){
      var error = new Error(data.erro || 'Falha de sincronização.');
      error.status = r.status;
      error.payload = data;
      throw error;
    }
    return data;
  }

  function applyRow(namespace, row){
    var key = KEY_BY_NS[namespace];
    if(!key || !row) return;
    var current = getLocal(key);
    var map = mapArray(Array.isArray(current) ? current : []);
    var id = String(row.recordId);
    if(row.deleted) delete map[id];
    else map[id] = clone(row.payload);
    setLocal(key, Object.keys(map).map(function(k){ return map[k]; }));

    baseline[namespace] = baseline[namespace] || {};
    baseline[namespace][id] = {
      version:Number(row.version),
      payload:clone(row.payload),
      deleted:!!row.deleted,
      updatedAt:row.updatedAt
    };
    if(row.updatedAt && (!lastSeen[namespace] || String(row.updatedAt) > String(lastSeen[namespace]))) lastSeen[namespace] = row.updatedAt;
    dispatch('biotrop:data-changed',{namespace:namespace,source:'realtime',row:row});
    scheduleReload();
  }

  function rebuildLocal(namespace, rows){
    var key = KEY_BY_NS[namespace];
    if(!key) return;
    var local = getLocal(key);
    var localMap = mapArray(Array.isArray(local) ? local : []);
    var changed = false;

    (rows || []).forEach(function(row){
      var id = String(row.recordId);
      if(row.updatedAt && (!lastSeen[namespace] || String(row.updatedAt) > String(lastSeen[namespace]))) lastSeen[namespace] = row.updatedAt;
      baseline[namespace] = baseline[namespace] || {};
      baseline[namespace][id] = {
        version:Number(row.version),
        payload:clone(row.payload),
        deleted:!!row.deleted,
        updatedAt:row.updatedAt
      };
      if(row.deleted){
        if(Object.prototype.hasOwnProperty.call(localMap,id)){ delete localMap[id]; changed=true; }
      }else if(JSON.stringify(localMap[id]) !== JSON.stringify(row.payload)){
        localMap[id]=clone(row.payload);
        changed=true;
      }
    });

    if(changed){
      setLocal(key, Object.keys(localMap).map(function(id){ return localMap[id]; }));
      dispatch('biotrop:data-changed',{namespace:namespace,source:'remote'});
      scheduleReload();
    }
  }

  function scheduleReload(){
    if(pendingReload) return;
    pendingReload = true;
    if(editableFocus()) return;
    setTimeout(function(){
      if(editableFocus()) return;
      pendingReload=false;
      // Nunca recarrega a página inteira durante sincronização: isso fazia o
      // app reconstruir o estado local e podia causar o retorno à tela de login.
      try{
        if(typeof navigateTo==='function' && typeof STATE!=='undefined' && STATE.screen==='app'){
          navigateTo(STATE.activeArea);
        }else{
          dispatch('biotrop:sync-refresh');
        }
      }catch(_){ dispatch('biotrop:sync-refresh'); }
    },250);
  }

  async function pullNamespace(namespace, since){
    try{
      var url = '/api/data?namespace=' + encodeURIComponent(namespace);
      if(since) url += '&since=' + encodeURIComponent(new Date(new Date(since).getTime()-1000).toISOString());
      var data = await request(url, {method:'GET',headers:{}});
      var rows = data.rows || [];
      rebuildLocal(namespace, rows);
      return {ok:true,count:rows.length};
    }catch(error){
      if(error.status===401 || error.status===403){ authorized=false; dispatch('biotrop:auth-expired',{status:error.status}); }
      if(error.status!==401 && error.status!==403 && error.status!==503) console.warn('[BIOTROP SYNC]', namespace, error.message);
      return {ok:false,count:0};
    }
  }

  async function pushRecord(namespace, recordId, payload, deleted, expectedVersion){
    try{
      var data = await request('/api/data', {
        method:'POST',
        body:JSON.stringify({
          namespace:namespace,
          recordId:recordId,
          payload:payload || {},
          deleted:!!deleted,
          expectedVersion: expectedVersion == null ? null : expectedVersion
        })
      });
      applyRow(namespace, data.row);
      window.BIOTROP_SYNC_STATE='online';
      dispatch('biotrop:data-synced',{namespace:namespace,recordId:recordId});
      return true;
    }catch(error){
      if(error.status===409){
        var row = error.payload && error.payload.row;
        window.BIOTROP_SYNC_CONFLICTS.push({namespace:namespace,recordId:recordId});
        dispatch('biotrop:sync-conflict',{namespace:namespace,recordId:recordId,row:row||null});
        if(row) applyRow(namespace,row);
        return false;
      }
      if(error.status===401 || error.status===403){ authorized=false; dispatch('biotrop:auth-expired',{status:error.status}); } else if(error.status===503) authorized=false;
      console.warn('[BIOTROP SYNC PUSH]', namespace, recordId, error.message);
      return false;
    }
  }

  async function pushNamespace(namespace){
    var key = KEY_BY_NS[namespace];
    var current = getLocal(key);
    var currentMap = mapArray(Array.isArray(current) ? current : []);
    var base = baseline[namespace] || {};
    var ids = {};
    Object.keys(currentMap).forEach(function(id){ ids[id]=true; });
    Object.keys(base).forEach(function(id){ ids[id]=true; });

    var list = Object.keys(ids);
    for(var i=0;i<list.length;i++){
      var id=list[i];
      var localItem=currentMap[id];
      var remote=base[id];
      var localDeleted=!Object.prototype.hasOwnProperty.call(currentMap,id);
      if(!remote){
        if(localDeleted) continue;
        await pushRecord(namespace,id,localItem,false,0);
        continue;
      }
      if(localDeleted){
        if(!remote.deleted) await pushRecord(namespace,id,remote.payload,true,remote.version);
        continue;
      }
      if(remote.deleted){
        await pushRecord(namespace,id,localItem,false,remote.version);
        continue;
      }
      if(JSON.stringify(localItem)!==JSON.stringify(remote.payload)){
        await pushRecord(namespace,id,localItem,false,remote.version);
      }
    }
  }

  function schedulePush(namespace){
    if(!authorized || applyingRemote) return;
    clearTimeout(pushTimers[namespace]);
    pushTimers[namespace]=setTimeout(function(){ pushNamespace(namespace); },350);
  }

  function stopRealtime(){
    Object.keys(eventSources).forEach(function(namespace){
      try{ eventSources[namespace].close(); }catch(_){ }
      delete eventSources[namespace];
    });
    clearInterval(pollTimer);
  }

  function connectRealtime(namespace){
    if(!authorized || typeof EventSource === 'undefined') return false;
    try{
      var source = new EventSource('/api/realtime?namespace=' + encodeURIComponent(namespace) +
        (lastSeen[namespace] ? '&since=' + encodeURIComponent(lastSeen[namespace]) : ''), {withCredentials:true});
      source.addEventListener('change',function(event){
        try{ applyRow(namespace, JSON.parse(event.data)); }catch(_){ }
      });
      source.addEventListener('error',function(){
        try{ source.close(); }catch(_){ }
        delete eventSources[namespace];
      });
      source.addEventListener('reconnect',function(){
        try{ source.close(); }catch(_){ }
        delete eventSources[namespace];
        setTimeout(function(){ if(authorized) connectRealtime(namespace); },300);
      });
      eventSources[namespace]=source;
      return true;
    }catch(_){
      return false;
    }
  }

  async function initialize(){
    if(initialized) return;
    initialized=true;
    if(String(window.BIOTROP_AUTH_SOURCE||'')==='local-recovery'){
      authorized=false;
      window.BIOTROP_SYNC_STATE='local';
      return;
    }
    if(!window.BIOTROP_AUTH_USER_ID) return;

    authorized=true;
    window.BIOTROP_SYNC_STATE='syncing';

    for(var i=0;i<NAMESPACES.length;i++){
      var namespace=NAMESPACES[i];
      var pulled=await pullNamespace(namespace,null);
      var local = getLocal(KEY_BY_NS[namespace]);
      /* Importação inicial segura: só envia cache local quando a API confirma
         que o namespace está vazio. Depois disso, PostgreSQL é a autoridade. */
      if(pulled.ok && pulled.count===0 && Array.isArray(local) && local.length) await pushNamespace(namespace);
    }

    window.BIOTROP_SYNC_STATE='online';
    dispatch('biotrop:sync-ready',{namespaces:NAMESPACES.slice(),mode:'postgres-primary',realtime:'sse'});

    stopRealtime();
    var connected=NAMESPACES.map(connectRealtime).some(Boolean);
    if(!connected){
      pollTimer=setInterval(async function(){
        if(!authorized) return;
        for(var j=0;j<NAMESPACES.length;j++) await pullNamespace(NAMESPACES[j],lastSeen[NAMESPACES[j]]||null);
      },3000);
    }
  }

  function installStorageHook(){
    if(!window.Storage || !Storage.prototype.setItem || originalSetItem) return;
    originalSetItem=Storage.prototype.setItem;
    Storage.prototype.setItem=function(key,value){
      originalSetItem.call(this,key,value);
      if(this===window.localStorage && SYNC[key] && !applyingRemote) schedulePush(SYNC[key]);
    };
  }

  window.addEventListener('biotrop:auth-ready',function(){ initialized=false; initialize(); });
  window.addEventListener('biotrop:auth-logout',function(){
    authorized=false;
    window.BIOTROP_SYNC_STATE='offline';
    stopRealtime();
  });
  window.addEventListener('focusout',function(){
    if(window.BIOTROP_SYNC_STATE==='online' && pendingReload && !editableFocus()){
      pendingReload=false;
      setTimeout(function(){ if(!editableFocus()) location.reload(); },100);
    }
  });

  installStorageHook();
  setTimeout(function(){ if(window.BIOTROP_AUTH_USER_ID) initialize(); },600);
})();
