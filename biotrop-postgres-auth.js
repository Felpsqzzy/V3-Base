/* BIOTROP · autenticação do portal via PostgreSQL/API
 * O navegador nunca recebe DATABASE_URL nem senha do banco.
 */
(function(){
  'use strict';

  function box(text, ok){
    var el=document.getElementById('login-error-box');
    if(!el)return;
    el.innerHTML='<div class="'+(ok?'hint-box':'login-error')+'">'+text+'</div>';
  }

  function start(user){
    window.BIOTROP_AUTH_USER_ID=user.id;
    window.BIOTROP_ONLINE_USER=user.id;
    window.BIOTROP_AUTH_SOURCE='postgresql';
    try{
      var users=Array.isArray(window.USERS)?window.USERS.slice():[];
      var idx=users.findIndex(function(u){return String(u.id)===String(user.id);});
      if(idx<0) users.push(user); else users[idx]=Object.assign({},users[idx],user);
      window.USERS=users;
      localStorage.setItem('btlocal.biotrop_users_v2',JSON.stringify(users));
    }catch(_){ }
    if(typeof window.startLocalSession==='function') window.startLocalSession(user);
  }

  async function login(){
    var email=(document.getElementById('login-usuario')?.value||'').trim().toLowerCase();
    var senha=document.getElementById('login-senha')?.value||'';
    if(!email||!senha){box('Informe e-mail e senha.');return;}
    box('Validando acesso…',true);
    try{
      var r=await fetch('/api/auth/login',{method:'POST',headers:{'Content-Type':'application/json'},credentials:'include',body:JSON.stringify({email:email,senha:senha})});
      var data=await r.json();
      if(!r.ok||!data.ok) throw new Error(data.erro||'Não foi possível entrar.');
      start(data.usuario);
      box('Acesso confirmado.',true);
    }catch(e){ console.error('[BIOTROP AUTH]',e); box(e.message||'Não foi possível validar o acesso.'); }
  }

  async function restore(){
    try{
      var r=await fetch('/api/auth/session',{credentials:'include'});
      if(!r.ok)return;
      var data=await r.json();
      if(data.ok&&data.usuario) start(data.usuario);
    }catch(_){ }
  }

  async function logout(){
    try{ await fetch('/api/auth/session',{method:'DELETE',credentials:'include'}); }catch(_){ }
    window.BIOTROP_AUTH_USER_ID=null;
    window.BIOTROP_ONLINE_USER=null;
    window.BIOTROP_AUTH_SOURCE=null;
  }

  document.addEventListener('submit',function(ev){
    var form=ev.target;
    if(!form||form.id!=='login-form')return;
    ev.preventDefault();
    ev.stopImmediatePropagation();
    login();
  },true);

  window.BIOTROP_SIGNOUT_POSTGRES=logout;
  window.addEventListener('load',function(){setTimeout(restore,250);});
})();
