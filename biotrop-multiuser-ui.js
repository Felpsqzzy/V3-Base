/* BIOTROP · status online/offline e alerta de conflito */
(function(){
  'use strict';
  var style = document.createElement('style');
  style.textContent = '.biotrop-online-pill{position:fixed;right:18px;bottom:16px;z-index:9999;display:flex;align-items:center;gap:8px;padding:8px 12px;border-radius:999px;background:#fff;border:1px solid #d7e6df;box-shadow:0 4px 18px rgba(0,60,65,.10);font:600 12px Segoe UI,system-ui,sans-serif;color:#35544a}.biotrop-online-dot{width:8px;height:8px;border-radius:50%;background:#6b7a75}.biotrop-online-pill.online .biotrop-online-dot{background:#1a8f6b}.biotrop-online-pill.offline .biotrop-online-dot{background:#d64545}.biotrop-online-pill.sync{opacity:.82}.biotrop-conflict{position:fixed;right:18px;bottom:62px;z-index:10000;max-width:360px;background:#fff8e6;border:1px solid #f0c36d;color:#704f00;border-radius:12px;padding:12px 14px;box-shadow:0 8px 24px rgba(0,0,0,.12);font:13px Segoe UI,system-ui,sans-serif}.biotrop-conflict button{margin-top:8px;border:0;background:#003C41;color:#fff;border-radius:999px;padding:7px 12px;cursor:pointer;font-weight:700}';
  document.head.appendChild(style);
  var pill=document.createElement('div');
  pill.className='biotrop-online-pill offline';
  pill.innerHTML='<span class="biotrop-online-dot"></span><span>Offline</span>';
  document.body.appendChild(pill);
  function set(text, cls){ pill.className='biotrop-online-pill '+cls; pill.lastChild.textContent=text; }
  function showConflict(){
    if(document.querySelector('.biotrop-conflict')) return;
    var box=document.createElement('div'); box.className='biotrop-conflict';
    box.innerHTML='<strong>Alteração simultânea detectada</strong><div style="margin-top:4px;line-height:1.45">Outra pessoa alterou o mesmo registro enquanto você editava. A versão do servidor foi preservada.</div><button type="button">Atualizar</button>';
    box.querySelector('button').onclick=function(){ location.reload(); };
    document.body.appendChild(box);
  }
  window.addEventListener('online',function(){set('Online','online');});
  window.addEventListener('offline',function(){set('Sem conexão','offline');});
  window.addEventListener('biotrop:data-synced',function(){set('Online · sincronizado','online');setTimeout(function(){set('Online','online');},1800);});
  window.addEventListener('biotrop:sync-conflict',showConflict);
  window.addEventListener('biotrop:sync-conflict-created',showConflict);
  setTimeout(function(){set(navigator.onLine?'Online':'Sem conexão',navigator.onLine?'online':'offline');},1200);
})();
