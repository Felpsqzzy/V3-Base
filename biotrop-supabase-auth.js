/* BIOTROP · autenticação Supabase Auth integrada ao login existente */
(function(){
  'use strict';
  var URL='https://hoikliqttxqdsyyjdnul.supabase.co';
  var KEY='sb_publishable_PeiXiPCMENjp9ajwW-EbJw_IohMAt1h';
  var client=null;
  function ensureClient(){
    if(client) return Promise.resolve(client);
    if(window.supabase && window.supabase.createClient){
      client=window.supabase.createClient(URL,KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});
      return Promise.resolve(client);
    }
    return new Promise(function(resolve,reject){
      var s=document.createElement('script');
      s.src='https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2';
      s.async=false;
      s.onload=function(){
        if(!window.supabase||!window.supabase.createClient) return reject(new Error('Supabase JS não carregou.'));
        client=window.supabase.createClient(URL,KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});
        resolve(client);
      };
      s.onerror=function(){reject(new Error('Não foi possível carregar o serviço de autenticação.'));};
      document.head.appendChild(s);
    });
  }
  function msg(text,kind){
    var box=document.getElementById('login-error-box');
    if(!box)return;
    box.innerHTML='<div class="'+(kind==='ok'?'hint-box':'login-error')+'">'+text+'</div>';
  }
  async function signIn(form){
    var email=(document.getElementById('login-usuario').value||'').trim().toLowerCase();
    var password=document.getElementById('login-senha').value||'';
    if(!email||!password){msg('Informe e-mail e senha.');return false;}
    msg('Validando acesso…','ok');
    try{
      var c=await ensureClient();
      var auth=await c.auth.signInWithPassword({email:email,password:password});
      if(auth.error) throw auth.error;
      var authUser=auth.data.user;
      var profileQuery=await c.from('profiles').select('*').eq('id',authUser.id).maybeSingle();
      if(profileQuery.error) throw profileQuery.error;
      var profile=profileQuery.data;
      if(!profile||profile.active===false||profile.is_active===false){
        await c.auth.signOut();
        throw new Error('Seu usuário está sem perfil ativo no sistema.');
      }
      window.BIOTROP_AUTH_USER_ID=authUser.id;
      window.BIOTROP_ONLINE_USER=authUser.id;
      try{localStorage.setItem('btlocal.biotrop_supabase_user_id',authUser.id);}catch(_){ }
      var role=profile.role_code||profile.app_role||'tecnico';
      var user={
        id:authUser.id,
        nome:profile.full_name||profile.name||email.split('@')[0],
        usuario:email,
        email:email,
        perfilId:role,
        role_code:role,
        app_role:role,
        time:profile.sector||profile.department||'',
        ativo:true,
        auth:true
      };
      if(Array.isArray(window.USERS)){
        var i=window.USERS.findIndex(function(u){return String(u.id)===String(user.id)});
        if(i<0) window.USERS.push(user); else window.USERS[i]=Object.assign({},window.USERS[i],user);
        try{localStorage.setItem('btlocal.biotrop_users_v2',JSON.stringify(window.USERS));}catch(_){ }
      }
      if(typeof startLocalSession==='function') startLocalSession(user);
      msg('Acesso confirmado.','ok');
      return true;
    }catch(e){
      console.error('[BIOTROP AUTH]',e);
      msg(e && e.message ? 'Não foi possível entrar: '+e.message : 'Não foi possível validar o acesso.');
      return false;
    }
  }
  async function restore(){
    try{
      var c=await ensureClient();
      var auth=await c.auth.getUser();
      if(!auth||!auth.data||!auth.data.user)return;
      var q=await c.from('profiles').select('*').eq('id',auth.data.user.id).maybeSingle();
      if(!q.data||q.data.active===false||q.data.is_active===false)return;
      window.BIOTROP_AUTH_USER_ID=auth.data.user.id;
      window.BIOTROP_ONLINE_USER=auth.data.user.id;
    }catch(_){ }
  }
  document.addEventListener('submit',function(ev){
    var form=ev.target;
    if(!form||form.id!=='login-form')return;
    ev.preventDefault();
    ev.stopImmediatePropagation();
    signIn(form);
  },true);
  document.addEventListener('click',function(ev){
    var btn=ev.target && (ev.target.closest ? ev.target.closest('#forgot-pass-btn') : null);
    if(!btn)return;
    ev.preventDefault();ev.stopImmediatePropagation();
    var emailEl=document.getElementById('login-usuario');
    var email=(emailEl&&emailEl.value||'').trim();
    if(!email){msg('Digite seu e-mail para recuperar a senha.');return;}
    ensureClient().then(function(c){
      return c.auth.resetPasswordForEmail(email,{redirectTo:location.origin});
    }).then(function(r){if(r&&r.error)throw r.error;msg('Se o e-mail existir no sistema, o link de recuperação foi enviado.','ok');})
      .catch(function(e){msg(e&&e.message?'Não foi possível solicitar a recuperação: '+e.message:'Não foi possível solicitar a recuperação.');});
  },true);
  window.BIOTROP_SIGNOUT_SUPABASE=async function(){try{var c=await ensureClient();await c.auth.signOut();}catch(_){}}
  window.addEventListener('load',restore);
})();
