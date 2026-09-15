/* Shared navigation. Business routes and their permission checks remain in the domain runtime. */
(function () {
  'use strict';
  let eventScope;
  let restoreFocus;
  const media = window.matchMedia('(max-width: 860px)');
  const names = {home:'Início', lms_my:'Treinamentos', utilidades:'Consumos', almox_minhas:'Solicitações'};
  const symbols = {home:'home', lms_my:'bookopen', utilidades:'gauge', almoxarifado:'package', almox_minhas:'clipboard', almox_scm_form:'cart', almox_scm_gestao:'cart', almox_scm_aprovacao:'check', almox_solicitacoes:'clipboard', familias:'package', usuarios:'users', email_fila:'send'};
  function allItems() { return btNavGroups().flatMap(g => g.items.filter(i => i && i.id)); }
  function glyph(item) { return icon(symbols[item.id] || 'clipboard', 20); }
  function navItem(item, mobile) {
    const active = STATE.activeArea === item.id;
    return '<button type="button" data-nav="'+esc(item.id)+'" class="portal-nav-item'+(active?' is-current':'')+'"'+(active?' aria-current="page"':'')+' title="'+esc(item.label)+'">'+
      '<span aria-hidden="true">'+glyph(item)+'</span><span class="portal-nav-label">'+esc(mobile ? (names[item.id] || item.label) : item.label)+'</span>'+
      (!mobile && Number(item.badge)>0?'<span class="portal-count">'+Number(item.badge)+'</span>':'')+'</button>';
  }
  btRenderNav = function () {
    const filter = btNormalize(BT_NAV.filter || '').trim();
    return btNavGroups().map(function (group) {
      const items = group.items.filter(i => i && i.id && (!filter || btNormalize(i.label+' '+group.label).includes(filter)));
      if (!items.length) return '';
      return '<section class="portal-nav-group"><h2>'+esc(group.label)+'</h2>'+items.map(i => navItem(i,false)).join('')+'</section>';
    }).join('') || '<p class="portal-no-results">Nenhuma opção encontrada.</p>';
  };
  btRenderTabbar = function () {
    const items = allItems();
    const ids = ['home','utilidades','almox_minhas','lms_my'];
    const shortcuts = ids.map(id => items.find(i=>i.id===id)).filter(Boolean).slice(0,4);
    return shortcuts.map(i => navItem(i,true)).join('')+'<button type="button" class="portal-nav-item" data-open-menu aria-label="Abrir todas as opções" aria-controls="bt-side"><span aria-hidden="true">'+icon('menu',20)+'</span><span>Menu</span></button>';
  };
  renderAppShell = function () {
    const user = STATE.currentUser;
    const profile = getProfile(user);
    const initials = String(user.nome || '').split(/\s+/).filter(Boolean).slice(0,2).map(s=>s[0]).join('');
    document.body.classList.remove('bt-rail','bt-side-open');
    return '<a class="portal-skip" href="#main-content">Pular para o conteúdo</a><div class="portal-shell">'+
      '<aside class="portal-sidebar" id="bt-side" aria-label="Menu principal">'+
        '<div class="portal-brand"><img src="'+LOGO_ICON+'" alt=""><div><strong>BIOTROP</strong><span>Manutenção</span></div><button type="button" data-close-menu class="portal-icon-button portal-close" aria-label="Fechar menu">'+icon('x',20)+'</button></div>'+
        '<label class="portal-search">'+icon('search',18)+'<input id="bt-nav-search" type="search" placeholder="Buscar no menu" aria-label="Buscar no menu" autocomplete="off" value="'+esc(BT_NAV.filter || '')+'"></label>'+
        '<nav id="bt-nav" class="portal-nav" aria-label="Navegação principal">'+btRenderNav()+'</nav>'+
        '<footer class="portal-account"><span class="portal-avatar" aria-hidden="true">'+esc(initials)+'</span><div><strong>'+esc(user.nome)+'</strong><span>'+esc(profile?profile.nome:'Usuário')+'</span></div><button class="portal-icon-button" id="logout-btn" aria-label="Sair">'+icon('logout',18)+'</button></footer></aside>'+
      '<div class="portal-workspace"><header class="portal-topbar"><button type="button" class="portal-icon-button portal-menu-trigger" id="bt-burger" data-open-menu aria-label="Abrir menu" aria-controls="bt-side" aria-expanded="false">'+icon('menu',20)+'</button><div class="portal-location"><span>Manutenção</span>'+icon('chevrondown',14)+'<strong id="bt-page-title">Início</strong></div><div class="portal-topbar-end"><span id="bt-clock" class="portal-clock"></span><button type="button" id="bt-theme" class="portal-icon-button" aria-label="Alternar tema">'+icon('sun',19)+'</button></div></header>'+
      '<main class="portal-page"><div id="main-content" tabindex="-1"></div></main></div></div>'+
      '<button type="button" class="portal-scrim" data-close-menu aria-label="Fechar menu" hidden></button>'+
      '<nav class="portal-bottom" id="bt-tabbar" aria-label="Atalhos de navegação">'+btRenderTabbar()+'</nav>';
  };
  function closeMenu(focus) {
    const side = document.getElementById('bt-side');
    if (side) { side.classList.remove('is-open'); side.removeAttribute('role'); side.removeAttribute('aria-modal'); }
    const scrim=document.querySelector('.portal-scrim');
    if(scrim) scrim.hidden=true;
    document.body.classList.remove('portal-menu-open','bt-side-open');
    const workspace=document.querySelector('.portal-workspace');
    if(workspace) workspace.inert=false;
    const bottom=document.getElementById('bt-tabbar');
    if(bottom) bottom.inert=false;
    document.querySelectorAll('[data-open-menu]').forEach(b=>b.setAttribute('aria-expanded','false'));
    if(focus && restoreFocus && restoreFocus.isConnected) restoreFocus.focus();
  }
  function openMenu(trigger) {
    if(!media.matches) return;
    restoreFocus=trigger;
    const side=document.getElementById('bt-side');
    if(!side) return;
    side.classList.add('is-open'); side.setAttribute('role','dialog'); side.setAttribute('aria-modal','true');
    const scrim=document.querySelector('.portal-scrim'); if(scrim) scrim.hidden=false;
    document.body.classList.add('portal-menu-open');
    document.querySelector('.portal-workspace').inert=true;
    document.getElementById('bt-tabbar').inert=true;
    document.querySelectorAll('[data-open-menu]').forEach(b=>b.setAttribute('aria-expanded','true'));
    side.querySelector('[data-close-menu]').focus();
  }
  btCloseSide = function () { closeMenu(false); };
  btWireNav = function () {
    document.querySelectorAll('#bt-nav [data-nav], #bt-tabbar [data-nav]').forEach(button=>{
      button.onclick=function(){ closeMenu(false); navigateTo(this.dataset.nav); };
    });
    document.querySelectorAll('[data-open-menu]').forEach(button=>button.onclick=()=>openMenu(button));
    document.querySelectorAll('[data-close-menu]').forEach(button=>button.onclick=()=>closeMenu(true));
    const search=document.getElementById('bt-nav-search');
    if(search) search.oninput=function(){BT_NAV.filter=this.value;document.getElementById('bt-nav').innerHTML=btRenderNav();btWireNav();};
  };
  btRefreshNav = function () {
    const nav=document.getElementById('bt-nav'); if(nav) nav.innerHTML=btRenderNav();
    const bottom=document.getElementById('bt-tabbar'); if(bottom) bottom.innerHTML=btRenderTabbar();
    btWireNav();
  };
  attachShellEvents = function () {
    if(eventScope) eventScope.abort();
    eventScope=new AbortController();
    btWireNav(); installV12Controls();
    document.addEventListener('keydown',function(event){
      if(!document.body.classList.contains('portal-menu-open')) return;
      if(event.key==='Escape'){event.preventDefault();closeMenu(true);return;}
      if(event.key!=='Tab') return;
      const nodes=Array.from(document.querySelectorAll('#bt-side button,#bt-side input,#bt-side a')).filter(el=>!el.disabled&&el.getClientRects().length);
      const first=nodes[0],last=nodes[nodes.length-1];
      if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus();}
      else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus();}
    },{signal:eventScope.signal});
    media.addEventListener('change',()=>closeMenu(false),{signal:eventScope.signal});
  };
})();
