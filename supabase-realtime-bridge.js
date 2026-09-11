/* BIOTROP · Supabase Realtime Bridge
 * Mantém contas, SCI, SCM e Utilidades sincronizados entre computadores.
 * As telas continuam usando localStorage; este arquivo transforma as gravações
 * locais em registros online e aplica mudanças remotas quase em tempo real.
 */
(function () {
  'use strict';

  var SUPABASE_URL = 'https://hoikliqttxqdsyyjdnul.supabase.co';
  var SUPABASE_KEY = 'sb_publishable_PeiXiPCMENjp9ajwW-EbJw_IohMAt1h';
  var TABLE = 'biotrop_realtime_records';
  var SYNC_KEYS = {
    'btlocal.biotrop_users_v2': 'users',
    'btlocal.biotrop_profiles_v2': 'profiles',
    'btlocal.biotrop_sci_v1': 'sci',
    'btlocal.biotrop_scm_v1': 'scm',
    'btlocal.biotrop_utility_meters_v1': 'utility_meters',
    'btlocal.biotrop_utility_readings_v1': 'utility_readings'
  };
  var KEY_BY_NAMESPACE = Object.keys(SYNC_KEYS).reduce(function (acc, k) {
    acc[SYNC_KEYS[k]] = k;
    return acc;
  }, {});

  var client = null;
  var booting = true;
  var writeQueue = [];
  var flushing = false;
  var pendingRemote = false;
  var seenRemote = {};

  function loadSupabase() {
    if (window.supabase && window.supabase.createClient) {
      client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
        auth: { persistSession: false, autoRefreshToken: false }
      });
      return Promise.resolve();
    }
    return new Promise(function (resolve, reject) {
      var s = document.createElement('script');
      s.src = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2';
      s.async = false;
      s.onload = function () {
        if (!window.supabase || !window.supabase.createClient) return reject(new Error('Supabase JS não carregou.'));
        client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
          auth: { persistSession: false, autoRefreshToken: false }
        });
        resolve();
      };
      s.onerror = function () { reject(new Error('Falha ao carregar Supabase JS.')); };
      document.head.appendChild(s);
    });
  }

  function safeParse(value) {
    try { return JSON.parse(value); } catch (_) { return null; }
  }

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
    try {
      localStorage.setItem(key, JSON.stringify(value));
    } catch (_) {}
  }

  function arraysEqual(a, b) {
    try { return JSON.stringify(a) === JSON.stringify(b); } catch (_) { return false; }
  }

  function mergeRemoteIntoLocal(namespace, rows) {
    var key = KEY_BY_NAMESPACE[namespace];
    if (!key) return false;
    var remote = (rows || []).filter(function (r) { return !r.deleted; }).map(function (r) { return r.payload; });
    var local = getLocal(key);

    if (namespace === 'users' || namespace === 'profiles' || namespace === 'sci' || namespace === 'scm' || namespace === 'utility_meters' || namespace === 'utility_readings') {
      if (!Array.isArray(local)) local = [];
      var byId = {};
      local.forEach(function (item, i) { byId[stableId(item, i)] = item; });
      remote.forEach(function (item, i) { byId[stableId(item, i)] = item; });
      var merged = Object.keys(byId).map(function (id) { return byId[id]; });
      merged.sort(function (a, b) {
        var da = new Date(a && (a.dataCriacao || a.created_at || a.createdAt) || 0).getTime();
        var db = new Date(b && (b.dataCriacao || b.created_at || b.createdAt) || 0).getTime();
        return db - da;
      });
      if (!arraysEqual(local, merged)) {
        putLocalRaw(key, merged);
        return true;
      }
    }
    return false;
  }

  async function fetchNamespace(namespace) {
    if (!client) return [];
    var result = await client.from(TABLE).select('id,namespace,record_id,payload,deleted,updated_at').eq('namespace', namespace).eq('deleted', false).order('updated_at', { ascending: true });
    if (result.error) throw result.error;
    return result.data || [];
  }

  async function pushArray(namespace, value) {
    if (!client || !Array.isArray(value) || !SYNC_KEYS) return;
    var key = KEY_BY_NAMESPACE[namespace];
    if (!key) return;
    var current = getLocal(key);
    if (!Array.isArray(current)) return;

    var rows = current.map(function (item, index) {
      return {
        namespace: namespace,
        record_id: stableId(item, index),
        payload: item,
        deleted: false,
        updated_by: (window.BIOTROP_ONLINE_USER || '')
      };
    });

    if (!rows.length) return;
    var result = await client.from(TABLE).upsert(rows, { onConflict: 'namespace,record_id' });
    if (result.error) throw result.error;
  }

  async function flushQueue() {
    if (flushing || booting || !writeQueue.length) return;
    flushing = true;
    var queue = writeQueue.splice(0, writeQueue.length);
    try {
      for (var i = 0; i < queue.length; i++) {
        var item = queue[i];
        if (SYNC_KEYS[item.key]) await pushArray(SYNC_KEYS[item.key], item.value);
      }
    } catch (e) {
      console.warn('[BIOTROP ONLINE] falha de sincronização:', e);
      writeQueue = queue.concat(writeQueue);
    } finally {
      flushing = false;
    }
  }

  function queueWrite(key, value) {
    if (!SYNC_KEYS[key]) return;
    writeQueue.push({ key: key, value: value });
    if (!booting) setTimeout(flushQueue, 150);
  }

  function hasEditableFocus() {
    var el = document.activeElement;
    if (!el) return false;
    return /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName) || !!el.isContentEditable;
  }

  function applyRemote(namespace) {
    if (hasEditableFocus()) {
      pendingRemote = true;
      window.BIOTROP_ONLINE_PENDING = true;
      return;
    }
    fetchNamespace(namespace).then(function (rows) {
      var changed = mergeRemoteIntoLocal(namespace, rows);
      if (changed) location.reload();
    }).catch(function (e) { console.warn('[BIOTROP ONLINE] leitura remota:', e); });
  }

  async function bootstrap() {
    await loadSupabase();
    var namespaces = Object.keys(KEY_BY_NAMESPACE);
    var changed = false;
    for (var i = 0; i < namespaces.length; i++) {
      var ns = namespaces[i];
      try {
        var rows = await fetchNamespace(ns);
        if (rows.length) {
          changed = mergeRemoteIntoLocal(ns, rows) || changed;
          rows.forEach(function (r) { seenRemote[r.id] = r.updated_at; });
        }
      } catch (e) {
        console.warn('[BIOTROP ONLINE] bootstrap ' + ns + ':', e);
      }
    }

    booting = false;
    if (changed && !sessionStorage.getItem('biotrop_online_bootstrap_reload')) {
      sessionStorage.setItem('biotrop_online_bootstrap_reload', '1');
      location.reload();
      return;
    }
    sessionStorage.removeItem('biotrop_online_bootstrap_reload');

    window.addEventListener('beforeunload', function () {
      try { sessionStorage.removeItem('biotrop_online_bootstrap_reload'); } catch (_) {}
    });

    window.BIOTROP_ONLINE = true;
    window.BIOTROP_ONLINE_FLUSH = flushQueue;
    setTimeout(flushQueue, 300);

    client.channel('biotrop-live')
      .on('postgres_changes', { event: '*', schema: 'public', table: TABLE }, function (payload) {
        var row = payload.new || payload.old;
        if (!row || !SYNC_KEYS[KEY_BY_NAMESPACE[row.namespace] === row.namespace ? row.namespace : '']) {
          // fallback below; namespace is checked by KEY_BY_NAMESPACE itself
        }
        if (!row || !KEY_BY_NAMESPACE[row.namespace]) return;
        applyRemote(row.namespace);
      })
      .subscribe(function (status) {
        console.info('[BIOTROP ONLINE] Realtime:', status);
      });
  }

  try {
    var originalSet = Storage.prototype.setItem;
    Storage.prototype.setItem = function (key, value) {
      originalSet.call(this, key, value);
      if (this === window.localStorage && SYNC_KEYS[key]) {
        queueWrite(key, safeParse(value));
      }
    };
  } catch (e) {
    console.warn('[BIOTROP ONLINE] não foi possível interceptar localStorage:', e);
  }

  document.addEventListener('focusout', function () {
    if (pendingRemote && !hasEditableFocus()) {
      pendingRemote = false;
      window.BIOTROP_ONLINE_PENDING = false;
      location.reload();
    }
  });

  // Inicialização sem bloquear a renderização local.
  bootstrap().catch(function (e) {
    booting = false;
    console.warn('[BIOTROP ONLINE] modo local mantido:', e);
  });
})();
