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
  function localRole(role){
    role=String(role||'').toLowerCase();
    if(role==='super_admin'||role==='administrador') return 'admin';
    if(role==='pcm') return 'gestor';
    if(role==='lider') return 'lider';
    if(role==='almoxarife') return 'almoxarife';
    return 'tecnico';
  }
  async function buildLocalUser(c,authUser){
    var profileQuery=await c.from('profiles').select('*').eq('id',authUser.id).maybeSingle();
    if(profileQuery.error) throw profileQuery.error;
    var profile=profileQuery.data;
    if(!profile){
      var ensured=await c.rpc('ensure_current_profile');
      if(ensured.error) throw ensured.error;
      profile=(ensured.data&&ensured.data.id)?ensured.data:null;
    }
    if(!profile||profile.active===false||profile.is_active===false){
      throw new Error('Seu usuário está sem perfil ativo no sistema.');
    }
    var role=profile.role_code||profile.app_role||'tecnico';
    return {
      id:authUser.id,
      nome:profile.full_name||profile.name||authUser.email.split('@')[0],
      usuario:authUser.email,
      email:authUser.email,
      perfilId:localRole(role),
      role_code:role,
      app_role:role,
      time:profile.sector||profile.department||'',
      telefone:profile.phone||'',
      ativo:true,
      auth:true
    };
  }
  async function resolveLoginEmail(c,login){
    var r=await c.rpc('resolve_login_email',{p_login:login});
    if(!r.error && r.data) return String(r.data).toLowerCase();
    if(login.indexOf('@')>=0) return login;
    throw new Error('Usuário não encontrado. Informe o e-mail cadastrado.');
  }
  async function cacheAndStart(user){
    window.BIOTROP_AUTH_USER_ID=user.id;
    window.BIOTROP_ONLINE_USER=user.id;
    try{localStorage.setItem('btlocal.biotrop_supabase_user_id',user.id);}catch(_){ }
    try{
      var users=Array.isArray(window.USERS)?window.USERS.slice():[];
      var i=users.findIndex(function(u){return String(u.id)===String(user.id);});
      if(i<0) users.push(user); else users[i]=Object.assign({},users[i],user);
      window.USERS=users;
      localStorage.setItem('btlocal.biotrop_users_v2',JSON.stringify(users));
    }catch(_){ }
    if(typeof startLocalSession==='function') startLocalSession(user);
  }
  async function signIn(){
    var login=(document.getElementById('login-usuario').value||'').trim().toLowerCase();
    var password=document.getElementById('login-senha').value||'';
    if(!login||!password){msg('Informe e-mail/usuário e senha.');return false;}
    msg('Validando acesso…','ok');
    try{
      var c=await ensureClient();
      var email=await resolveLoginEmail(c,login);
      var auth=await c.auth.signInWithPassword({email:email,password:password});
      if(auth.error) throw auth.error;
      var user=await buildLocalUser(c,auth.data.user);
      await c.rpc('record_last_login').catch(function(){});
      await cacheAndStart(user);
      msg('Acesso confirmado.','ok');
      return true;
    }catch(e){
      console.error('[BIOTROP AUTH]',e);
      var text=String((e&&e.message)||'Falha ao validar acesso.');
      if(/invalid login credentials|invalid email or password/i.test(text)) text='E-mail/usuário ou senha inválidos.';
      msg('Não foi possível entrar: '+text);
      return false;
    }
  }
  async function restore(){
    try{
      var c=await ensureClient();
      var auth=await c.auth.getUser();
      if(!auth||!auth.data||!auth.data.user)return;
      var user=await buildLocalUser(c,auth.data.user);
      await cacheAndStart(user);
    }catch(e){ console.warn('[BIOTROP AUTH] restore:',e); }
  }
  document.addEventListener('submit',function(ev){
    var form=ev.target;
    if(!form||form.id!=='login-form')return;
    ev.preventDefault();
    ev.stopImmediatePropagation();
    signIn();
  },true);
  document.addEventListener('click',function(ev){
    var btn=ev.target && (ev.target.closest ? ev.target.closest('#forgot-pass-btn') : null);
    if(!btn)return;
    ev.preventDefault();ev.stopImmediatePropagation();
    var loginEl=document.getElementById('login-usuario');
    var login=(loginEl&&loginEl.value||'').trim().toLowerCase();
    if(!login){msg('Digite seu e-mail/usuário para recuperar a senha.');return;}
    ensureClient().then(function(c){
      return resolveLoginEmail(c,login).then(function(email){
        return c.auth.resetPasswordForEmail(email,{redirectTo:location.origin});
      });
    }).then(function(r){if(r&&r.error)throw r.error;msg('Se o e-mail existir no sistema, o link de recuperação foi enviado.','ok');})
      .catch(function(e){msg(e&&e.message?'Não foi possível solicitar a recuperação: '+e.message:'Não foi possível solicitar a recuperação.');});
  },true);
  window.BIOTROP_SIGNOUT_SUPABASE=async function(){try{var c=await ensureClient();await c.auth.signOut();}catch(_){}};
  window.addEventListener('load',function(){setTimeout(restore,300);});
})();
