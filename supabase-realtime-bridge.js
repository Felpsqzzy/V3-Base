/* BIOTROP · Multi-user Supabase bridge v2
 * Mantém a interface atual baseada em localStorage, mas sincroniza por registro,
 * detecta conflitos de edição e mantém trilha de auditoria no banco.
 */
(function () {
  'use strict';

  var SUPABASE_URL = 'https://hoikliqttxqdsyyjdnul.supabase.co';
  var SUPABASE_KEY = 'sb_publishable_PeiXiPCMENjp9ajwW-EbJw_IohMAt1h';
  var TABLE = 'biotrop_realtime_records';
  var CONFLICTS = 'biotrop_sync_conflicts';
  var SYNC_KEYS = {
    'btlocal.biotrop_users_v2': 'users',
    'btlocal.biotrop_profiles_v2': 'profiles',
    'btlocal.biotrop_sci_v1': 'sci',
    'btlocal.biotrop_scm_v1': 'scm',
    'btlocal.biotrop_utility_meters_v1': 'utility_meters',
    'btlocal.biotrop_utility_readings_v1': 'utility_readings'
  };
  var KEY_BY_NAMESPACE = Object.keys(SYNC_KEYS).reduce(function (acc, key) {
    acc[SYNC_KEYS[key]] = key;
    return acc;
  }, {});

  var client = null;
  var booting = true;
  var writeQueue = [];
  var flushing = false;
  var pendingRemote = false;
  var baseline = {};
  var seenRemote = {};
  var clientId = '';

  try {
    clientId = localStorage.getItem('btlocal.biotrop_client_id_v1') ||
      ('web-' + Date.now() + '-' + Math.random().toString(36).slice(2));
    localStorage.setItem('btlocal.biotrop_client_id_v1', clientId);
  } catch (_) { clientId = 'web-' + Date.now(); }

  function safeParse(value) {
    try { return JSON.parse(value); } catch (_) { return null; }
  }
  function clone(value) {
    try { return JSON.parse(JSON.stringify(value)); } catch (_) { return value; }
  }
  function keyFor(namespace, recordId) { return namespace + '::' + recordId; }
  function stableId(item, index) {
    if (!item || typeof item !== 'object') return String(index);
    return String(item.id || item.codigo || item.code || item.request_number || ('row-' + index));
  }
  function getLocal(key) {
    try {
      var raw = localStorage.getItem(key);
      return raw == null ? null : safeParse(raw);
    } catch (_) { return null; }
  }
  function putLocalRaw(key, value) {
    try { localStorage.setItem(key, JSON.stringify(value)); } catch (_) {}
  }
  function loadSupabase() {
    if (window.supabase && window.supabase.createClient) {
      client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
        auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
      });
      return Promise.resolve();
    }
    return new Promise(function (resolve, reject) {
      var script = document.createElement('script');
      script.src = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2';
      script.async = false;
      script.onload = function () {
        if (!window.supabase || !window.supabase.createClient) return reject(new Error('Supabase JS não carregou.'));
        client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
          auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
        });
        resolve();
      };
      script.onerror = function () { reject(new Error('Falha ao carregar Supabase JS.')); };
      document.head.appendChild(script);
    });
  }
  function currentOnlineUser() {
    return String(window.BIOTROP_ONLINE_USER || '') || clientId;
  }
  function rowsToMap(rows) {
    var map = {};
    (rows || []).forEach(function (row) {
      map[String(row.record_id)] = row;
      seenRemote[keyFor(row.namespace, row.record_id)] = row.updated_at;
    });
    return map;
  }
  async function fetchNamespace(namespace) {
    var result = await client.from(TABLE).select('id,namespace,record_id,payload,deleted,updated_by,updated_at,version,client_id').eq('namespace', namespace).order('updated_at', { ascending: true });
    if (result.error) throw result.error;
    return result.data || [];
  }
  function mergeRemoteIntoLocal(namespace, rows) {
    var key = KEY_BY_NAMESPACE[namespace];
    if (!key) return false;
    var remote = (rows || []).filter(function (row) { return !row.deleted; }).map(function (row) { return row.payload; });
    var local = getLocal(key);
    if (!Array.isArray(local)) local = [];
    var byId = {};
    local.forEach(function (item, index) { byId[stableId(item, index)] = item; });
    remote.forEach(function (item, index) { byId[stableId(item, index)] = item; });
    var merged = Object.keys(byId).map(function (id) { return byId[id]; });
    merged.sort(function (a, b) {
      var da = new Date(a && (a.dataCriacao || a.created_at || a.createdAt) || 0).getTime();
      var db = new Date(b && (b.dataCriacao || b.created_at || b.createdAt) || 0).getTime();
      return db - da;
    });
    baseline[key] = clone(merged);
    if (JSON.stringify(local) !== JSON.stringify(merged)) {
      putLocalRaw(key, merged);
      return true;
    }
    return false;
  }
  async function recordConflict(namespace, recordId, expectedRow, serverRow, clientPayload) {
    try {
      await client.from(CONFLICTS).insert({
        namespace: namespace,
        record_id: recordId,
        client_id: clientId,
        expected_version: expectedRow && expectedRow.version ? expectedRow.version : null,
        server_version: serverRow && serverRow.version ? serverRow.version : null,
        server_payload: serverRow ? serverRow.payload : null,
        client_payload: clientPayload
      });
    } catch (e) { console.warn('[BIOTROP ONLINE] conflito não registrado:', e); }
  }
  async function upsertChangedRow(namespace, item, deleted) {
    var recordId = stableId(item, 0);
    var serverResult = await client.from(TABLE)
      .select('id,record_id,payload,deleted,updated_at,version')
      .eq('namespace', namespace).eq('record_id', recordId).maybeSingle();
    if (serverResult.error) throw serverResult.error;

    var serverRow = serverResult.data;
    var expectedUpdatedAt = seenRemote[keyFor(namespace, recordId)] || null;

    if (serverRow && expectedUpdatedAt && String(serverRow.updated_at) !== String(expectedUpdatedAt)) {
      await recordConflict(namespace, recordId, { version: null }, serverRow, item);
      return { conflict: true, recordId: recordId };
    }

    var nextVersion = serverRow && serverRow.version ? Number(serverRow.version) + 1 : 1;
    var now = new Date().toISOString();
    var payload = {
      namespace: namespace,
      record_id: recordId,
      payload: item,
      deleted: !!deleted,
      updated_by: currentOnlineUser(),
      updated_at: now,
      last_synced_at: now,
      version: nextVersion,
      client_id: clientId
    };
    var result = await client.from(TABLE).upsert(payload, { onConflict: 'namespace,record_id' }).select('id,updated_at,version').single();
    if (result.error) throw result.error;
    seenRemote[keyFor(namespace, recordId)] = result.data.updated_at;
    return { conflict: false, recordId: recordId };
  }
  function changedIds(namespace, key, nextValue) {
    var previous = baseline[key];
    if (!Array.isArray(previous)) previous = [];
    if (!Array.isArray(nextValue)) nextValue = [];
    var prevMap = {}, nextMap = {}, changes = [];
    previous.forEach(function (item, index) { prevMap[stableId(item, index)] = item; });
    nextValue.forEach(function (item, index) { nextMap[stableId(item, index)] = item; });
    Object.keys(nextMap).forEach(function (id) {
      if (JSON.stringify(prevMap[id]) !== JSON.stringify(nextMap[id])) changes.push({ id: id, item: nextMap[id], deleted: false });
    });
    Object.keys(prevMap).forEach(function (id) {
      if (!Object.prototype.hasOwnProperty.call(nextMap, id)) changes.push({ id: id, item: prevMap[id], deleted: true });
    });
    return changes;
  }
  async function pushArray(namespace, value) {
    if (!client || !Array.isArray(value)) return;
    var key = KEY_BY_NAMESPACE[namespace];
    if (!key) return;
    var changes = changedIds(namespace, key, value);
    if (!changes.length) { baseline[key] = clone(value); return; }
    var conflicts = [];
    for (var i = 0; i < changes.length; i++) {
      var result = await upsertChangedRow(namespace, changes[i].item, changes[i].deleted);
      if (result.conflict) conflicts.push(result.recordId);
    }
    if (conflicts.length) {
      window.BIOTROP_ONLINE_CONFLICTS = (window.BIOTROP_ONLINE_CONFLICTS || []).concat(conflicts);
      window.dispatchEvent(new CustomEvent('biotrop:sync-conflict', { detail: { namespace: namespace, recordIds: conflicts } }));
      await applyRemote(namespace, true);
    } else {
      baseline[key] = clone(value);
      window.dispatchEvent(new CustomEvent('biotrop:data-synced', { detail: { namespace: namespace } }));
    }
  }
  async function flushQueue() {
    if (flushing || booting || !writeQueue.length) return;
    flushing = true;
    var queue = writeQueue.splice(0, writeQueue.length);
    try {
      var latest = {};
      queue.forEach(function (entry) { latest[entry.key] = entry.value; });
      var keys = Object.keys(latest);
      for (var i = 0; i < keys.length; i++) {
        var key = keys[i];
        if (SYNC_KEYS[key]) await pushArray(SYNC_KEYS[key], latest[key]);
      }
    } catch (e) {
      console.warn('[BIOTROP ONLINE] falha de sincronização:', e);
      writeQueue = queue.concat(writeQueue);
    } finally { flushing = false; }
  }
  function queueWrite(key, value) {
    if (!SYNC_KEYS[key]) return;
    writeQueue.push({ key: key, value: clone(value) });
    if (!booting) setTimeout(flushQueue, 200);
  }
  function hasEditableFocus() {
    var el = document.activeElement;
    if (!el) return false;
    return /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName) || !!el.isContentEditable;
  }
  async function applyRemote(namespace, force) {
    if (!force && hasEditableFocus()) { pendingRemote = true; window.BIOTROP_ONLINE_PENDING = true; return; }
    try {
      var rows = await fetchNamespace(namespace);
      var key = KEY_BY_NAMESPACE[namespace];
      var previous = getLocal(key);
      var changed = mergeRemoteIntoLocal(namespace, rows);
      if (changed && (!force || !hasEditableFocus())) {
        if (JSON.stringify(previous) !== JSON.stringify(getLocal(key))) {
          window.BIOTROP_ONLINE_LAST_REMOTE = Date.now();
          window.dispatchEvent(new CustomEvent('biotrop:data-changed', { detail: { namespace: namespace } }));
          setTimeout(function () { if (!hasEditableFocus()) location.reload(); }, 100);
        }
      }
    } catch (e) { console.warn('[BIOTROP ONLINE] leitura remota:', e); }
  }
  async function bootstrap() {
    await loadSupabase();
    var namespaces = Object.keys(KEY_BY_NAMESPACE);
    for (var i = 0; i < namespaces.length; i++) {
      var namespace = namespaces[i];
      try {
        var rows = await fetchNamespace(namespace);
        rowsToMap(rows);
        mergeRemoteIntoLocal(namespace, rows);
      } catch (e) { console.warn('[BIOTROP ONLINE] bootstrap ' + namespace + ':', e); }
    }
    booting = false;
    window.BIOTROP_ONLINE = true;
    window.BIOTROP_ONLINE_CLIENT_ID = clientId;
    window.BIOTROP_ONLINE_FLUSH = flushQueue;
    try {
      var auth = await client.auth.getUser();
      if (auth && auth.data && auth.data.user) window.BIOTROP_AUTH_USER_ID = auth.data.user.id;
    } catch (_) {}
    setTimeout(flushQueue, 300);
    client.channel('biotrop-live-v2')
      .on('postgres_changes', { event: '*', schema: 'public', table: TABLE }, function (payload) {
        var row = payload.new || payload.old;
        if (!row || !KEY_BY_NAMESPACE[row.namespace]) return;
        applyRemote(row.namespace, false);
      })
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: CONFLICTS }, function () {
        window.BIOTROP_ONLINE_HAS_CONFLICT = true;
        window.dispatchEvent(new CustomEvent('biotrop:sync-conflict-created'));
      })
      .subscribe(function (status) { console.info('[BIOTROP ONLINE] Realtime:', status); });
  }

  try {
    var originalSet = Storage.prototype.setItem;
    Storage.prototype.setItem = function (key, value) {
      originalSet.call(this, key, value);
      if (this === window.localStorage && SYNC_KEYS[key]) queueWrite(key, safeParse(value));
    };
  } catch (e) { console.warn('[BIOTROP ONLINE] intercept localStorage:', e); }

  document.addEventListener('focusout', function () {
    if (pendingRemote && !hasEditableFocus()) {
      pendingRemote = false;
      window.BIOTROP_ONLINE_PENDING = false;
      Object.keys(KEY_BY_NAMESPACE).forEach(function (namespace) { applyRemote(namespace, true); });
    }
  });

  bootstrap().catch(function (e) {
    booting = false;
    console.warn('[BIOTROP ONLINE] modo local mantido:', e);
  });
})();
