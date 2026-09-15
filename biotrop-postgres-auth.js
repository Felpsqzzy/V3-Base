/* BIOTROP · autenticação via PostgreSQL/API + Microsoft Entra ID
 * O navegador nunca recebe DATABASE_URL, client secret ou senha do banco.
 * A autenticação é exclusivamente validada pelo servidor.
 */
(function(){
  'use strict';

  function box(text, ok){
    var el=document.getElementById('login-error-box');
    if(!el)return;
    el.innerHTML='<div class="'+(ok?'hint-box':'login-error')+'">'+text+'</div>';
  }

  function cleanLocalRecoveryUi(){
    try{
      var selectors=['.demo-note','#reset-local-btn'];
      selectors.forEach(function(selector){
        document.querySelectorAll(selector).forEach(function(el){ el.remove(); });
      });
      document.querySelectorAll('.bt-topbar__sub').forEach(function(el){
        var text=String(el.textContent||'');
        if(/vers[aã]o local/i.test(text)) el.textContent='Acesso online · dados sincronizados';
      });
    }catch(_){ }
  }

  function start(user){
    window.BIOTROP_AUTH_USER_ID=user.id;
    window.BIOTROP_ONLINE_USER=user.id;
    window.BIOTROP_AUTH_SOURCE=user.authSource||'postgresql';
    try{
      var users=Array.isArray(window.USERS)?window.USERS.slice():[];
      var idx=users.findIndex(function(u){return String(u.id)===String(user.id);});
      if(idx<0) users.push(user); else users[idx]=Object.assign({},users[idx],user);
      window.USERS=users;
    }catch(_){ }
    if(typeof window.startLocalSession==='function') window.startLocalSession(user);
    try{ window.dispatchEvent(new CustomEvent('biotrop:auth-ready',{detail:user})); }catch(_){ }
  }

  async function login(){
    var email=(document.getElementById('login-usuario')?.value||'').trim().toLowerCase();
    var senha=document.getElementById('login-senha')?.value||'';
    if(!email||!senha){box('Informe e-mail e senha.');return;}
    box('Validando acesso…',true);
    try{
      var r=await fetch('/api/auth/login',{method:'POST',headers:{'Content-Type':'application/json'},credentials:'include',body:JSON.stringify({email:email,senha:senha})});
      var data={};
      try{ data=await r.json(); }catch(_){ }
      if(r.ok && data.ok){
        start(data.usuario);
        box('Acesso confirmado.',true);
        return;
      }

      if(r.status===401){
        box('E-mail ou senha incorretos.');
        return;
      }
      if(r.status===403){
        box(data.erro||'Acesso não autorizado para este usuário.');
        return;
      }
      box('Não foi possível validar o acesso agora. Tente novamente em instantes.');
    }catch(e){
      console.error('[BIOTROP AUTH]',e);
      box('Não foi possível conectar ao servidor. Tente novamente.');
    }
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
    try{ window.dispatchEvent(new CustomEvent('biotrop:auth-logout')); }catch(_){ }
  }

  function ensureMicrosoftButton(){
    if(document.getElementById('biotrop-microsoft-login')) return;
    var form=document.getElementById('login-form');
    if(!form) return;

    var style=document.createElement('style');
    style.textContent='\n#biotrop-microsoft-login{width:100%;margin-top:12px;display:flex;align-items:center;justify-content:center;gap:10px;padding:11px 18px;border-radius:999px;border:1px solid #cfd9d7;background:#fff;color:#17332b;font-size:14px;font-weight:700;font-family:inherit;cursor:pointer;transition:.15s ease}#biotrop-microsoft-login:hover{background:#f4f8f7;border-color:#9db4af}#biotrop-microsoft-login svg{width:18px;height:18px;flex:none}\n';
    document.head.appendChild(style);

    var button=document.createElement('button');
    button.type='button';
    button.id='biotrop-microsoft-login';
    button.innerHTML='<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="#f35325" d="M1 1h10.5v10.5H1z"></path><path fill="#81bc06" d="M12.5 1H23v10.5H12.5z"></path><path fill="#05a6f0" d="M1 12.5h10.5V23H1z"></path><path fill="#ffba08" d="M12.5 12.5H23V23h-10.5z"></path></svg><span>Entrar com Microsoft</span>';
    button.addEventListener('click',function(){
      button.disabled=true;
      button.style.opacity='.7';
      location.href='/api/auth/microsoft/start';
    });

    var divider=form.querySelector('.divider');
    if(divider) form.insertBefore(button,divider.nextSibling || null);
    else form.appendChild(button);
  }

  function handleAuthResult(){
    try{
      var params=new URLSearchParams(location.search);
      if(params.get('login')==='ok'){
        history.replaceState({},'',location.pathname);
        box('Login Microsoft confirmado.',true);
      }
      if(params.get('login')==='erro'){
        var reason=params.get('motivo')||'Não foi possível concluir o login Microsoft.';
        history.replaceState({},'',location.pathname);
        var map={
          configuracao_microsoft:'Login Microsoft ainda não configurado no servidor.',
          email_nao_autorizado:'Seu e-mail Microsoft não está liberado no sistema.',
          tenant_nao_autorizado:'A conta pertence a um tenant Microsoft não autorizado.',
          usuario_bloqueado:'Seu usuário está bloqueado ou inativo.',
          sessao_microsoft_expirada:'A tentativa de login Microsoft expirou. Tente novamente.',
          nonce_invalido:'Falha de segurança na validação Microsoft.',
          falha_autenticacao_microsoft:'Não foi possível concluir o login Microsoft.'
        };
        box(map[reason]||'Não foi possível concluir o login Microsoft.');
      }
    }catch(_){ }
  }

  document.addEventListener('submit',function(ev){
    var form=ev.target;
    if(!form||form.id!=='login-form')return;
    ev.preventDefault();
    ev.stopImmediatePropagation();
    login();
  },true);

  window.BIOTROP_SIGNOUT_POSTGRES=logout;
  window.addEventListener('load',function(){
    cleanLocalRecoveryUi();
    ensureMicrosoftButton();
    handleAuthResult();
    setTimeout(function(){ cleanLocalRecoveryUi(); restore(); },250);
  });
})();
