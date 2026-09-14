/* BIOTROP · sincronização multiusuário via PostgreSQL/API
 * Sem Supabase. Mantém o localStorage como cache/local-fallback, mas sincroniza
 * SCI, SCM e Utilidades com o PostgreSQL quando a sessão é corporativa.
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
  var running = false;
  var pollTimer = null;
  var pushTimers = {};
  var baseline = {};
  var lastSeen = {};
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

  function rebuildLocal(namespace, rows){
    var key = KEY_BY_NS[namespace];
    if(!key) return;
    var local = getLocal(key);
    if(!Array.isArray(local)) local = [];
    var localMap = mapArray(local);
    var remoteMap = {};
    var changed = false;
    var previousBaseline = baseline[namespace] || {};
    var nextBaseline = {};

    (rows || []).forEach(function(row){
      var id = String(row.recordId);
      var previous = previousBaseline[id] || null;
      var serverVersion = Number(row.version);

      remoteMap[id] = row;
      nextBaseline[id] = {
        version: serverVersion,
        payload: clone(row.payload),
        deleted: !!row.deleted,
        updatedAt: row.updatedAt
      };
      if(row.updatedAt && (!lastSeen[namespace] || String(row.updatedAt) > String(lastSeen[namespace]))) lastSeen[namespace] = row.updatedAt;

      /* Se o usuário tem uma cópia local diferente do último estado que ele
         conhecia e o servidor avançou a versão, é um conflito real. */
      if(previous && serverVersion > Number(previous.version)){
        var localExists = Object.prototype.hasOwnProperty.call(localMap,id);
        var localValue = localExists ? localMap[id] : undefined;
        var localChanged = previous.deleted !== !!(!localExists) || JSON.stringify(localValue) !== JSON.stringify(previous.payload);
        if(localChanged && !applyingRemote){
          window.BIOTROP_SYNC_CONFLICTS.push({namespace:namespace,recordId:id,serverVersion:serverVersion});
          dispatch('biotrop:sync-conflict',{namespace:namespace,recordId:id,row:row});
          return;
        }
      }

      if(row.deleted){
        if(Object.prototype.hasOwnProperty.call(localMap,id)){
          delete localMap[id];
          changed = true;
        }
      }else if(JSON.stringify(localMap[id]) !== JSON.stringify(row.payload)){
        localMap[id] = clone(row.payload);
        changed = true;
      }
    });

    baseline[namespace] = nextBaseline;

    if(changed){
      var merged = Object.keys(localMap).map(function(id){ return localMap[id]; });
      setLocal(key, merged);
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
      pendingReload = false;
      location.reload();
    },350);
  }

  async function pullNamespace(namespace, since){
    try{
      var url = '/api/data?namespace=' + encodeURIComponent(namespace);
      if(since) url += '&since=' + encodeURIComponent(new Date(new Date(since).getTime()-1500).toISOString());
      var data = await request(url, {method:'GET',headers:{}});
      rebuildLocal(namespace, data.rows || []);
      return true;
    }catch(error){
      if(error.status===401 || error.status===403) authorized=false;
      if(error.status!==401 && error.status!==403 && error.status!==503) console.warn('[BIOTROP SYNC]', namespace, error.message);
      return false;
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
      var row = data.row;
      baseline[namespace] = baseline[namespace] || {};
      baseline[namespace][recordId] = {
        version:Number(row.version),
        payload:clone(row.payload),
        deleted:!!row.deleted,
        updatedAt:row.updatedAt
      };
      if(row.updatedAt && (!lastSeen[namespace] || String(row.updatedAt) > String(lastSeen[namespace]))) lastSeen[namespace]=row.updatedAt;
      window.BIOTROP_SYNC_STATE='online';
      dispatch('biotrop:data-synced',{namespace:namespace,recordId:recordId});
      return true;
    }catch(error){
      if(error.status===409){
        var row = error.payload && error.payload.row;
        window.BIOTROP_SYNC_CONFLICTS.push({namespace:namespace,recordId:recordId});
        dispatch('biotrop:sync-conflict',{namespace:namespace,recordId:recordId,row:row||null});
        if(row) rebuildLocal(namespace,[row]);
        return false;
      }
      if(error.status===401 || error.status===403 || error.status===503) authorized=false;
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
    pushTimers[namespace]=setTimeout(function(){ pushNamespace(namespace); },450);
  }

  async function initialize(){
    if(initialized || running) return;
    initialized=true;
    running=true;
    if(String(window.BIOTROP_AUTH_SOURCE||'')==='local-recovery'){
      authorized=false;
      window.BIOTROP_SYNC_STATE='local';
      running=false;
      return;
    }
    if(!window.BIOTROP_AUTH_USER_ID){
      running=false;
      return;
    }
    authorized=true;
    window.BIOTROP_SYNC_STATE='syncing';

    for(var i=0;i<NAMESPACES.length;i++){
      var namespace=NAMESPACES[i];
      await pullNamespace(namespace,null);
      await pushNamespace(namespace);
    }

    window.BIOTROP_SYNC_STATE='online';
    dispatch('biotrop:sync-ready',{namespaces:NAMESPACES.slice(),intervalMs:3000});
    clearInterval(pollTimer);
    pollTimer=setInterval(async function(){
      if(!authorized) return;
      for(var j=0;j<NAMESPACES.length;j++) await pullNamespace(NAMESPACES[j],lastSeen[NAMESPACES[j]]||null);
    },3000);
    running=false;
  }

  function installStorageHook(){
    if(!window.Storage || !Storage.prototype.setItem || originalSetItem) return;
    originalSetItem=Storage.prototype.setItem;
    Storage.prototype.setItem=function(key,value){
      originalSetItem.call(this,key,value);
      if(this===window.localStorage && SYNC[key] && !applyingRemote){
        if(authorized) schedulePush(SYNC[key]);
      }
    };
  }

  window.addEventListener('biotrop:auth-ready',function(){
    initialized=false;
    initialize();
  });
  window.addEventListener('biotrop:auth-logout',function(){
    authorized=false;
    window.BIOTROP_SYNC_STATE='offline';
    clearInterval(pollTimer);
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
