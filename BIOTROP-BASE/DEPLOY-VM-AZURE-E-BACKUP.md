# BIOTROP - Deploy na VM Azure, backup e rollback

Runbook operacional da fase 1: **uma VM Azure, um PostgreSQL 15 na propria VM, `git pull` +
build manual, login por Microsoft Entra ID, e-mail por Microsoft Graph, backup por `pg_dump`
na VM.** Uma pessoa mantem. Tudo aqui e comando ou arquivo completo, para copiar e rodar.

Fonte da verdade do banco: `migrations/0001_base.sql` (o arquivo `01-base.sql` deste
diretorio). Nomes de schema, tabela, coluna e funcao usados neste runbook vem de la.

## Convencoes fixadas (nao mudar sem atualizar este arquivo)

| Item | Valor |
|---|---|
| Host DNS | `manutencao.biotrop.com.br` |
| SO | Ubuntu Server 22.04 LTS |
| Banco | PostgreSQL 15, `listen_addresses = 'localhost'`, base `biotrop` |
| Roles do banco | `biotrop_owner` (dono/DDL), `biotrop_app` (aplicacao), `biotrop_ro` (leitura) |
| Usuario de SO da app | `biotrop` (sem shell de login) |
| Codigo | `/opt/biotrop/app` (working tree do git) |
| Segredos | `/etc/biotrop/app.env` (`0600 root:root`) |
| Backups | `/dados/backup/biotrop` |
| Logs da app | journald (`journalctl -u biotrop-app`) |
| Porta interna da app | `127.0.0.1:3000` |
| Timezone da VM | `America/Sao_Paulo` |

---

# 1. O que pedir no chamado para a TI

Texto para colar no chamado. Cada item tem o motivo, porque chamado sem motivo volta com
pergunta.

## 1.1 Maquina virtual

```text
Assunto: Provisionamento de VM Linux para a plataforma de manutencao industrial (Manutencao/PCM)

1) VM
   - Nome:            vm-biotrop-manut-prd-01
   - Regiao:          Brazil South
   - Tamanho:         Standard_B2ms (2 vCPU, 8 GiB RAM)
                      Justificativa: aplicacao Node + PostgreSQL na mesma maquina,
                      dezenas de usuarios internos, carga em horario comercial.
   - Imagem:          Ubuntu Server 22.04 LTS (Gen2)
   - Disco de SO:     64 GB Premium SSD
   - Disco de dados:  128 GB Premium SSD (LUN 0), montado em /dados
                      Justificativa: dados do PostgreSQL e dumps de backup ficam fora do
                      disco de SO, para reinstalar o SO sem tocar no banco.
   - Acesso:          chave SSH (sem senha). Chave publica anexa ao chamado.
   - Identidade gerenciada: habilitar (System assigned) - usada na fase 2 para Key Vault.
   - Boot diagnostics: habilitado (serial console para recuperacao).

2) Rede
   - IP:              estatico (Standard SKU). Publico somente se o item 4 for opcao B.
   - NSG - entrada:
       443/tcp  origem: faixas de rede corporativa + VPN   -> HTTPS da aplicacao
        80/tcp  origem: faixas de rede corporativa + VPN   -> redireciona p/ 443 e ACME
        22/tcp  origem: faixa de administracao da TI (ou Azure Bastion)
       Todo o resto: DENY.
   - NAO abrir 5432. O PostgreSQL escuta somente em localhost.
   - NSG - saida: 443/tcp para login.microsoftonline.com e graph.microsoft.com
                  (Entra ID e envio de e-mail), para os repositorios de pacotes
                  (archive.ubuntu.com, deb.nodesource.com, apt.postgresql.org) e github.com.

3) DNS
   - Registro A: manutencao.biotrop.com.br -> IP da VM
   - TTL 300 durante a implantacao, 3600 depois de estabilizar.
   - Se o acesso for somente interno, criar o A na zona interna apontando o IP privado.

4) Decisao necessaria: acesso externo?
   - Opcao A (interno): DNS interno + IP privado. Mais simples e mais seguro.
                        Certificado tem de vir da CA corporativa (Let's Encrypt nao valida
                        host sem DNS publico por HTTP-01).
   - Opcao B (externo): IP publico + registro A publico + Let's Encrypt automatico.
                        Exige NSG restrito as faixas corporativas mesmo assim.

5) TLS
   - Preferencia: certificado corporativo para manutencao.biotrop.com.br.
     Entregar .pfx (ou .crt + chave + cadeia intermediaria) e a data de expiracao.
   - Registrar na TI a renovacao como tarefa recorrente, com aviso 30 dias antes.
   - Se a TI optar por Let's Encrypt, informar e manter 80/tcp aberto para o HTTP-01.

6) Backup da VM
   - Azure Backup (Recovery Services vault), politica diaria, retencao 30 dias.
   - Observacao tecnica: snapshot de VM com o banco ligado e crash-consistent. O backup
     autoritativo do banco e o pg_dump diario feito dentro da VM (secao 6). O snapshot
     serve para recuperar a maquina, nao para garantir a integridade do banco.

7) Microsoft Entra ID (autenticacao)
   - App registration: "Biotrop - Plataforma de Manutencao"
   - Redirect URI (Web): https://manutencao.biotrop.com.br/api/auth/callback/azure-ad
   - Front-channel logout URL: https://manutencao.biotrop.com.br
   - Permissoes delegadas: openid, profile, email, User.Read
   - Client secret com validade de 24 meses. Entregar tenant id, client id e secret por
     cofre de senhas corporativo, nunca no corpo do chamado nem por e-mail.
   - Registrar a data de expiracao do secret como tarefa recorrente.

8) Microsoft Graph (envio de e-mail)
   - Caixa remetente: manutencao@biotrop.com.br
     (e o default de core.email_fila.remetente na migration 0001)
   - App registration separada: "Biotrop - Manutencao (envio de e-mail)"
   - Permissao de aplicacao: Mail.Send, com consentimento do administrador
   - Restringir por ApplicationAccessPolicy a um grupo que contenha somente a caixa
     manutencao@biotrop.com.br. Sem essa politica, Mail.Send de aplicacao permite enviar
     como qualquer caixa do tenant.

9) Janela de manutencao
   - Publicacao e atualizacoes: dias uteis, 18h-20h. A aplicacao fica fora do ar por menos
     de 1 minuto a cada deploy.
```

## 1.2 O que a TI precisa devolver antes de comecar a instalacao

- [ ] IP (publico e/ou privado) e confirmacao de que o registro A resolve
- [ ] Acesso SSH funcionando com a chave enviada
- [ ] Certificado TLS (arquivos + expiracao) **ou** confirmacao de usar Let's Encrypt
- [ ] `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` da app de login
- [ ] `GRAPH_CLIENT_ID`, `GRAPH_CLIENT_SECRET` da app de e-mail e confirmacao da
      ApplicationAccessPolicy aplicada
- [ ] Azure Backup da VM ativo, com a primeira execucao concluida

---

# 2. Instalacao da VM

Comandos rodados como o usuario admin da VM (`azureuser`), com `sudo`.

## 2.1 Base do sistema

```bash
sudo timedatectl set-timezone America/Sao_Paulo
sudo apt-get update && sudo apt-get -y upgrade
sudo apt-get -y install curl ca-certificates gnupg git jq unzip ufw \
                        nginx acl bc unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades   # aceitar atualizacoes de seguranca
```

## 2.2 Disco de dados em /dados

```bash
lsblk                                    # confirmar o disco novo (tipicamente /dev/sdc)
sudo parted /dev/sdc --script mklabel gpt mkpart primary ext4 0% 100%
sudo mkfs.ext4 -L dados /dev/sdc1
sudo mkdir -p /dados
echo 'LABEL=dados /dados ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab
sudo mount -a && df -h /dados
sudo mkdir -p /dados/backup/biotrop /dados/pgdata
```

## 2.3 Node 20 LTS

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get -y install nodejs
node -v && npm -v                        # esperado: v20.x
```

## 2.4 PostgreSQL 15

```bash
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -fsSLo /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
  https://www.postgresql.org/media/keys/ACCC4CF8.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list
sudo apt-get update && sudo apt-get -y install postgresql-15 postgresql-client-15
```

Mover o cluster para o disco de dados:

```bash
sudo systemctl stop postgresql
sudo rsync -a /var/lib/postgresql/15/main/ /dados/pgdata/main/
sudo chown -R postgres:postgres /dados/pgdata
sudo sed -i "s#^data_directory = .*#data_directory = '/dados/pgdata/main'#" \
     /etc/postgresql/15/main/postgresql.conf
```

Ajuste de configuracao (VM de 8 GiB com a aplicacao no mesmo host):

```bash
sudo mkdir -p /etc/postgresql/15/main/conf.d
# grep ancorado em ^: o postgresql.conf do Debian tem a linha tambem comentada,
# e um grep sem ancora acha o comentario e nunca inclui o diretorio de verdade
grep -q "^include_dir" /etc/postgresql/15/main/postgresql.conf || \
  echo "include_dir = 'conf.d'" | sudo tee -a /etc/postgresql/15/main/postgresql.conf

sudo tee /etc/postgresql/15/main/conf.d/biotrop.conf > /dev/null <<'CONF'
listen_addresses = 'localhost'
max_connections = 100
shared_buffers = 2GB
effective_cache_size = 5GB
work_mem = 16MB
maintenance_work_mem = 512MB
wal_compression = on
log_min_duration_statement = 1000
log_line_prefix = '%m [%p] %u@%d '
log_checkpoints = on
timezone = 'America/Sao_Paulo'
lc_messages = 'C'
CONF

sudo systemctl start postgresql && sudo systemctl enable postgresql
sudo -u postgres psql -c 'show data_directory'
```

## 2.5 Usuario de SO e diretorios

```bash
sudo useradd --system --create-home --home-dir /opt/biotrop \
             --shell /usr/sbin/nologin biotrop
sudo mkdir -p /opt/biotrop/app /opt/biotrop/estado /etc/biotrop
sudo chown -R biotrop:biotrop /opt/biotrop
sudo chown root:root /etc/biotrop && sudo chmod 750 /etc/biotrop
```

## 2.6 Primeiro clone

Vem antes do banco de proposito: a migration `0001_base.sql` mora no repositorio, nao em
um arquivo solto na VM. Chave de deploy read-only, nunca a chave pessoal:

```bash
sudo -u biotrop mkdir -p /opt/biotrop/.ssh
sudo -u biotrop ssh-keygen -t ed25519 -N '' -f /opt/biotrop/.ssh/id_ed25519
sudo cat /opt/biotrop/.ssh/id_ed25519.pub    # cadastrar como Deploy key (read-only)
sudo -u biotrop bash -c 'ssh-keyscan github.com >> /opt/biotrop/.ssh/known_hosts'
sudo -u biotrop git clone git@github.com:ORG/REPO.git /opt/biotrop/app
sudo -u biotrop git -C /opt/biotrop/app config core.fileMode false
ls /opt/biotrop/app/migrations/                # tem de listar 0001_base.sql
```

## 2.7 Banco, roles e a migration 0001

A migration `0001_base.sql` cria `biotrop_app` e `biotrop_ro` como **`NOLOGIN`**. Isso e de
proposito: quem define senha e quem opera a VM, nao um arquivo versionado no git. Sem o
`ALTER ROLE ... LOGIN PASSWORD` abaixo, a aplicacao nao conecta.

```bash
sudo -u postgres psql <<'SQL'
CREATE ROLE biotrop_owner LOGIN PASSWORD 'TROCAR_owner';
SQL

sudo -u postgres createdb -O biotrop_owner -E UTF8 -T template0 \
     --lc-collate=pt_BR.UTF-8 --lc-ctype=pt_BR.UTF-8 biotrop
```

Se a locale nao existir na imagem: `sudo locale-gen pt_BR.UTF-8 && sudo update-locale` e
repetir o `createdb`.

```bash
# as extensoes (pgcrypto, citext, pg_trgm, unaccent) exigem superusuario:
# a migration e aplicada como postgres, nao como biotrop_app
sudo -u postgres psql -d biotrop -v ON_ERROR_STOP=1 \
     -f /opt/biotrop/app/migrations/0001_base.sql

sudo -u postgres psql -d biotrop <<'SQL'
ALTER ROLE biotrop_app LOGIN PASSWORD 'TROCAR_app';
ALTER ROLE biotrop_ro  LOGIN PASSWORD 'TROCAR_ro';
SQL
```

Conferencia imediata. As tres precisam responder:

```bash
sudo -u postgres psql -d biotrop -c 'SELECT versao, nome, aplicado_em FROM core.migration;'
sudo -u postgres psql -d biotrop -xc 'SELECT * FROM app.vw_saude_operacional;'
sudo -u postgres psql -d biotrop -c \
  "SELECT * FROM core.pode_autenticar('felipe.vieira@biotrop.com.br');"
```

A terceira tem de voltar `permitido = t`. O seed de `core.email_autorizado` da migration
0001 ja libera esse e-mail com `perfil_padrao = 'admin'`. Se voltar `f`, pare aqui e
resolva antes de seguir: subir a aplicacao sem ninguem capaz de entrar e o caminho direto
para a secao 8.

## 2.8 Firewall local (segunda camada, depois do NSG)

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80,443/tcp
sudo ufw --force enable
sudo ufw status verbose
```

---

# 3. Variaveis de ambiente e onde guardar segredo

## 3.1 Regra

Segredo na VM mora em **um** lugar: `/etc/biotrop/app.env`, `0600 root:root`. O systemd le
esse arquivo como root e so depois derruba o privilegio para o usuario `biotrop`, entao o
processo recebe as variaveis sem que o usuario `biotrop` consiga ler o arquivo.

O que **nunca** entra em segredo versionado:

- `.env`, `.env.local`, `.env.production` no repositorio. Confirmar no `.gitignore`.
- senha em linha de comando (`psql -W`, `PGPASSWORD=...` inline): fica no `~/.bash_history`.
- segredo em log. `log_min_duration_statement` grava SQL, nao variavel de ambiente - ok.
- segredo no build. Next.js embute no bundle qualquer variavel `NEXT_PUBLIC_*`; nenhuma
  variavel desta lista pode receber esse prefixo.

Copia de seguranca do segredo: no cofre de senhas corporativo, entrada
"BIOTROP - Plataforma de Manutencao - VM prd". O `pg_dump` **nao** contem as senhas das
roles, e o arquivo `app.env` **nao** entra no dump do banco. Perder a VM e o cofre ao mesmo
tempo significa reemitir client secret no Entra e redefinir as senhas das roles.

## 3.2 /etc/biotrop/app.env

```bash
sudo tee /etc/biotrop/app.env > /dev/null <<'ENV'
# ---- runtime ------------------------------------------------------------------
NODE_ENV=production
PORT=3000
HOST=127.0.0.1
TZ=America/Sao_Paulo
APP_URL=https://manutencao.biotrop.com.br

# ---- banco (role da aplicacao, nunca a role dona) ----------------------------
DATABASE_URL=postgresql://biotrop_app:TROCAR_app@127.0.0.1:5432/biotrop?sslmode=disable
DATABASE_POOL_MAX=10
# sslmode=disable e correto aqui: a conexao nao sai da maquina (listen_addresses=localhost)

# ---- sessao --------------------------------------------------------------------
AUTH_SECRET=GERAR_COM_openssl_rand_base64_32
AUTH_TRUST_HOST=true

# ---- Microsoft Entra ID (login) -----------------------------------------------
AZURE_TENANT_ID=00000000-0000-0000-0000-000000000000
AZURE_CLIENT_ID=00000000-0000-0000-0000-000000000000
AZURE_CLIENT_SECRET=TROCAR_secret_entra

# ---- Microsoft Graph (envio da fila core.email_fila) --------------------------
GRAPH_TENANT_ID=00000000-0000-0000-0000-000000000000
GRAPH_CLIENT_ID=00000000-0000-0000-0000-000000000000
GRAPH_CLIENT_SECRET=TROCAR_secret_graph
GRAPH_SENDER=manutencao@biotrop.com.br
GRAPH_MAX_TENTATIVAS=5

# ---- limites -------------------------------------------------------------------
ANEXO_MAX_BYTES=20971520
# 20 MB, o mesmo valor da constraint ck_anexo_tamanho em core.anexo.
# Mudar aqui sem mudar a constraint gera erro de banco no upload.
ENV

sudo chmod 600 /etc/biotrop/app.env
sudo chown root:root /etc/biotrop/app.env
```

Gerar o `AUTH_SECRET` e as senhas de role:

```bash
openssl rand -base64 32          # AUTH_SECRET
openssl rand -base64 24          # senha de biotrop_app / biotrop_ro / biotrop_owner
```

## 3.3 .pgpass para os scripts de operacao

Os scripts de backup e restore rodam como `postgres` e usam autenticacao `peer` local -
nao precisam de senha. O `.pgpass` abaixo existe apenas para a conta de leitura
(`biotrop_ro`) em consultas manuais:

```bash
sudo -u postgres tee /var/lib/postgresql/.pgpass > /dev/null <<'PGPASS'
127.0.0.1:5432:biotrop:biotrop_ro:TROCAR_ro
PGPASS
sudo -u postgres chmod 600 /var/lib/postgresql/.pgpass
```

## 3.4 Rotacao

| Segredo | Prazo | Como |
|---|---|---|
| `AZURE_CLIENT_SECRET` | 24 meses (expira) | TI gera novo no Entra, editar `app.env`, `systemctl restart biotrop-app` |
| `GRAPH_CLIENT_SECRET` | 24 meses (expira) | idem, `systemctl restart biotrop-mailer.timer` |
| senha `biotrop_app` | anual ou em incidente | `ALTER ROLE biotrop_app PASSWORD '...'` + editar `DATABASE_URL` + restart |
| `AUTH_SECRET` | em incidente | trocar derruba todas as sessoes ativas (efeito desejado) |
| certificado TLS | conforme emissao | secao 4.2 |

---

# 4. Arquivos completos

## 4.1 /etc/systemd/system/biotrop-app.service

```ini
[Unit]
Description=Biotrop - Plataforma de Manutencao Industrial (Next.js)
Documentation=file:///opt/biotrop/app/DEPLOY-VM-AZURE-E-BACKUP.md
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=simple
User=biotrop
Group=biotrop
WorkingDirectory=/opt/biotrop/app
EnvironmentFile=/etc/biotrop/app.env
ExecStart=/usr/bin/node /opt/biotrop/app/.next/standalone/server.js
Restart=always
RestartSec=3
TimeoutStopSec=20
KillSignal=SIGTERM

StandardOutput=journal
StandardError=journal
SyslogIdentifier=biotrop-app

# isolamento: o processo web nao precisa escrever em nada fora de /tmp
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths=/opt/biotrop/app/.next/cache
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
MemoryMax=3G

[Install]
WantedBy=multi-user.target
```

Se o build **nao** for `output: 'standalone'`, trocar o `ExecStart` por
`/usr/bin/npm run start -- --port 3000` e remover `ProtectSystem=strict` (o `npm` precisa
escrever em mais lugares). Preferir `standalone`: sobe mais rapido e o isolamento fecha.

## 4.2 /etc/nginx/sites-available/biotrop.conf

```nginx
# ---------------------------------------------------------------------------
# Biotrop - proxy reverso para a aplicacao Node em 127.0.0.1:3000
# ---------------------------------------------------------------------------
upstream biotrop_app {
    server 127.0.0.1:3000 fail_timeout=10s max_fails=3;
    keepalive 16;
}

# HTTP: somente redireciona e responde o desafio ACME
server {
    listen 80;
    listen [::]:80;
    server_name manutencao.biotrop.com.br;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    # Ubuntu 22.04 traz nginx 1.18: HTTP/2 se habilita no listen.
    # Em nginx 1.25.1+ o correto e "listen 443 ssl;" + "http2 on;" numa linha separada.
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name manutencao.biotrop.com.br;

    # --- TLS ---------------------------------------------------------------
    ssl_certificate     /etc/ssl/biotrop/fullchain.pem;
    ssl_certificate_key /etc/ssl/biotrop/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:BIOTROP_TLS:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    # Com certificado de CA corporativa o nginx costuma avisar "ssl_stapling ignored,
    # issuer certificate not found". E aviso, nao erro: OCSP stapling so funciona se a
    # cadeia intermediaria estiver no fullchain.pem. Se o aviso incomodar, comentar.
    ssl_stapling        on;
    ssl_stapling_verify on;

    # --- cabecalhos de seguranca -------------------------------------------
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options    "nosniff" always;
    add_header X-Frame-Options           "SAMEORIGIN" always;
    add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy        "camera=(self), microphone=(), geolocation=()" always;
    # camera=(self): a tela de apontamento de utilidades tira foto do marcador.
    server_tokens off;

    # --- upload ------------------------------------------------------------
    # core.anexo aceita ate 20 MB (ck_anexo_tamanho). O app envia dataURL base64,
    # que infla ~33%. 32m cobre o pior caso sem 413 antes do banco recusar.
    client_max_body_size 32m;
    client_body_timeout  120s;

    # --- logs --------------------------------------------------------------
    access_log /var/log/nginx/biotrop.access.log;
    error_log  /var/log/nginx/biotrop.error.log warn;

    # --- compressao --------------------------------------------------------
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css application/json application/javascript
               application/x-javascript text/xml application/xml image/svg+xml;

    # --- estaticos do Next: cache longo, hash no nome ----------------------
    location /_next/static/ {
        proxy_pass http://biotrop_app;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        add_header Cache-Control "public, max-age=31536000, immutable";
    }

    # --- health check (nao poluir o access log) ----------------------------
    location = /api/health {
        access_log off;
        proxy_pass http://biotrop_app;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
    }

    # --- aplicacao ---------------------------------------------------------
    location / {
        proxy_pass http://biotrop_app;
        proxy_http_version 1.1;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        $connection_upgrade;

        proxy_connect_timeout 5s;
        proxy_send_timeout    120s;
        proxy_read_timeout    120s;
        proxy_buffering       off;

        # durante o restart do deploy o Node fica ~20s fora: nao devolver 502
        proxy_next_upstream error timeout http_502 http_503 http_504;
    }
}
```

O `$connection_upgrade` precisa do mapa abaixo, em `/etc/nginx/conf.d/upgrade.conf`:

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
```

Habilitar:

```bash
sudo mkdir -p /etc/ssl/biotrop && sudo chmod 700 /etc/ssl/biotrop
# certificado corporativo (.pfx): extrair antes
# sudo openssl pkcs12 -in biotrop.pfx -clcerts -nokeys -out /etc/ssl/biotrop/fullchain.pem
# sudo openssl pkcs12 -in biotrop.pfx -nocerts -nodes -out /etc/ssl/biotrop/privkey.pem
sudo chmod 600 /etc/ssl/biotrop/privkey.pem

sudo ln -sf /etc/nginx/sites-available/biotrop.conf /etc/nginx/sites-enabled/biotrop.conf
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

Let's Encrypt (somente na opcao B, com DNS publico):

```bash
sudo apt-get -y install certbot python3-certbot-nginx
sudo certbot certonly --webroot -w /var/www/html \
     -d manutencao.biotrop.com.br -m felipe.vieira@biotrop.com.br --agree-tos -n
sudo ln -sf /etc/letsencrypt/live/manutencao.biotrop.com.br/fullchain.pem \
            /etc/ssl/biotrop/fullchain.pem
sudo ln -sf /etc/letsencrypt/live/manutencao.biotrop.com.br/privkey.pem \
            /etc/ssl/biotrop/privkey.pem
sudo systemctl enable --now certbot.timer     # renovacao automatica
```

## 4.3 Timers de rotina (fila de e-mail e matriculas)

A migration 0001 deixa duas rotinas para a VM agendar: entregar `core.email_fila` pelo
Graph e rodar `lms.sincronizar_matriculas()` de madrugada como rede de seguranca dos
triggers.

`/etc/systemd/system/biotrop-mailer.service`:

```ini
[Unit]
Description=Biotrop - entrega da fila core.email_fila via Microsoft Graph
After=postgresql.service network-online.target

[Service]
Type=oneshot
User=biotrop
Group=biotrop
WorkingDirectory=/opt/biotrop/app
EnvironmentFile=/etc/biotrop/app.env
ExecStart=/usr/bin/node /opt/biotrop/app/scripts/enviar-fila.mjs
SyslogIdentifier=biotrop-mailer
NoNewPrivileges=true
PrivateTmp=true
```

`/etc/systemd/system/biotrop-mailer.timer`:

```ini
[Unit]
Description=Biotrop - dispara a fila de e-mail a cada 5 minutos

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
```

`/etc/systemd/system/biotrop-lms-sync.service`:

```ini
[Unit]
Description=Biotrop - sincroniza matriculas de treinamento por grupo
After=postgresql.service

[Service]
Type=oneshot
User=postgres
ExecStart=/usr/bin/psql -d biotrop -v ON_ERROR_STOP=1 -c "SELECT lms.sincronizar_matriculas();"
SyslogIdentifier=biotrop-lms-sync
```

`/etc/systemd/system/biotrop-lms-sync.timer`:

```ini
[Unit]
Description=Biotrop - sincronizacao diaria de matriculas (03:40)

[Timer]
OnCalendar=*-*-* 03:40:00
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now biotrop-app
sudo systemctl enable --now biotrop-lms-sync.timer
# habilitar o mailer somente depois que scripts/enviar-fila.mjs existir no repositorio:
sudo systemctl enable --now biotrop-mailer.timer
sudo systemctl list-timers 'biotrop*'
```

Enquanto o `enviar-fila.mjs` nao existir, a fila acumula em `core.email_fila` com
`status = 'pendente'` e nada se perde. Conferir o tamanho da fila com
`SELECT count(*) FROM app.vw_email_fila_pendente;`.

---

# 5. Ciclo de deploy e rollback

## 5.1 Os dois comandos

```bash
sudo /usr/local/sbin/biotrop-deploy.sh deploy      # git pull + build + migrations + restart
sudo /usr/local/sbin/biotrop-deploy.sh rollback    # volta ao commit anterior e reconstroi
```

O script fica em `/usr/local/sbin/`, **fora** do working tree do git, de proposito: se um
commit ruim quebrar o repositorio, o script que desfaz o commit ruim nao pode estar dentro
dele. Atualizar o script e um `scp` consciente, nao um efeito colateral de `git pull`.

## 5.2 O que o deploy faz, em ordem

1. checa que a arvore de trabalho esta limpa (aborta se alguem editou arquivo na VM);
2. grava o commit atual em `/opt/biotrop/estado/commit-anterior`;
3. `pg_dump` de pre-deploy (secao 6) - antes de qualquer migration;
4. `git pull --ff-only`;
5. `npm ci --omit=dev` e `npm run build`, como usuario `biotrop`;
6. aplica as migrations pendentes de `migrations/*.sql`, em ordem de prefixo, registrando
   em `core.migration` com checksum e duracao;
7. `systemctl restart biotrop-app` e espera o health check;
8. se o health check falhar, volta o codigo para o commit anterior automaticamente,
   reconstroi, reinicia e sai com erro.

O passo 8 desfaz **codigo**, nunca banco. Migration e forward-only (decisao registrada no
cabecalho da 0001): desfazer schema e escrever a proxima migration, ou restaurar dump.

## 5.3 /usr/local/sbin/biotrop-deploy.sh

```bash
#!/usr/bin/env bash
# =============================================================================
# BIOTROP - deploy, migrations e rollback na VM Azure
# Uso:  biotrop-deploy.sh {deploy|rollback|migrate|status|health}
# Roda como root (usa sudo -u biotrop para git/npm e sudo -u postgres para psql).
# =============================================================================
set -Eeuo pipefail

APP_DIR=/opt/biotrop/app
ESTADO_DIR=/opt/biotrop/estado
APP_USER=biotrop
SERVICO=biotrop-app
DB=biotrop
# Se a aplicacao ainda nao tem rota de health, usar "http://127.0.0.1:3000/" - qualquer
# resposta 200 serve como prova de que o Node subiu e o Next respondeu.
HEALTH_URL="http://127.0.0.1:3000/api/health"
HEALTH_TENTATIVAS=30
BACKUP_SH=/usr/local/sbin/biotrop-backup.sh
LOG=/var/log/biotrop-deploy.log

log()  { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }
erro() { printf '%s  ERRO: %s\n' "$(date '+%F %T')" "$*" >&2; }

if [[ $EUID -ne 0 ]]; then erro "rode com sudo"; exit 1; fi

mkdir -p "$ESTADO_DIR"
exec > >(tee -a "$LOG") 2>&1
trap 'erro "falhou na linha $LINENO"' ERR

como_app() { sudo -u "$APP_USER" -H "$@"; }
psql_db()  { sudo -u postgres psql -d "$DB" -v ON_ERROR_STOP=1 -qAt "$@"; }

# -----------------------------------------------------------------------------
# health check
# -----------------------------------------------------------------------------
esperar_saude() {
  local i
  for (( i=1; i<=HEALTH_TENTATIVAS; i++ )); do
    if curl -fsS --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
      log "health ok na tentativa $i"
      return 0
    fi
    sleep 2
  done
  erro "health check nao respondeu em $((HEALTH_TENTATIVAS*2))s"
  return 1
}

# -----------------------------------------------------------------------------
# migrations: aplica migrations/*.sql que ainda nao estao em core.migration
# -----------------------------------------------------------------------------
aplicar_migrations() {
  local arq base versao nome soma aplicado gravado ini fim dur
  shopt -s nullglob
  for arq in "$APP_DIR"/migrations/[0-9][0-9][0-9][0-9]_*.sql; do
    base=$(basename "$arq")
    versao=${base%%_*}
    nome=${base#*_}; nome=${nome%.sql}
    soma=$(sha256sum "$arq" | cut -d' ' -f1)

    aplicado=$(psql_db -c "SELECT count(*) FROM core.migration WHERE versao='$versao';")
    if [[ "$aplicado" == "1" ]]; then
      gravado=$(psql_db -c "SELECT coalesce(checksum,'') FROM core.migration WHERE versao='$versao';")
      if [[ -n "$gravado" && "$gravado" != "$soma" ]]; then
        erro "migration $base JA APLICADA e com conteudo diferente do registrado."
        erro "  banco:   $gravado"
        erro "  arquivo: $soma"
        erro "Migration aplicada nao se edita. Escreva a proxima e refaca o deploy."
        return 1
      fi
      log "migration $base: ja aplicada, pulando"
      continue
    fi

    log "migration $base: aplicando"
    ini=$(date +%s%3N)
    sudo -u postgres psql -d "$DB" -v ON_ERROR_STOP=1 --single-transaction -f "$arq"
    fim=$(date +%s%3N); dur=$((fim-ini))

    psql_db -c "INSERT INTO core.migration (versao, nome, checksum, duracao_ms)
                VALUES ('$versao','$nome','$soma',$dur)
                ON CONFLICT (versao) DO UPDATE
                  SET checksum   = coalesce(core.migration.checksum, EXCLUDED.checksum),
                      duracao_ms = EXCLUDED.duracao_ms;"
    log "migration $base: aplicada em ${dur}ms"
  done
  shopt -u nullglob
}

# -----------------------------------------------------------------------------
# build
# -----------------------------------------------------------------------------
construir() {
  log "npm ci"
  como_app npm --prefix "$APP_DIR" ci --omit=dev --no-audit --no-fund
  log "npm run build"
  como_app env -C "$APP_DIR" npm run build
  # Next standalone nao copia public/ nem os estaticos: o server.js precisa deles ao lado
  if [[ -d "$APP_DIR/.next/standalone" ]]; then
    como_app cp -r "$APP_DIR/public"        "$APP_DIR/.next/standalone/"       2>/dev/null || true
    como_app cp -r "$APP_DIR/.next/static"  "$APP_DIR/.next/standalone/.next/" 2>/dev/null || true
  fi
}

# -----------------------------------------------------------------------------
cmd_deploy() {
  log "===== DEPLOY ====="

  if [[ -n "$(como_app git -C "$APP_DIR" status --porcelain)" ]]; then
    erro "working tree suja em $APP_DIR. Rode: sudo -u $APP_USER git -C $APP_DIR status"
    erro "Edicao feita direto na VM nao sobrevive ao deploy. Comite ou descarte antes."
    exit 1
  fi

  local antes depois
  antes=$(como_app git -C "$APP_DIR" rev-parse HEAD)
  echo "$antes" > "$ESTADO_DIR/commit-anterior"
  log "commit atual (guardado para rollback): $antes"

  log "backup de pre-deploy"
  "$BACKUP_SH" pre-deploy

  log "git pull"
  como_app git -C "$APP_DIR" fetch --prune origin
  como_app git -C "$APP_DIR" pull --ff-only
  depois=$(como_app git -C "$APP_DIR" rev-parse HEAD)

  if [[ "$antes" == "$depois" ]]; then
    log "nenhum commit novo ($depois). Segue o build para garantir consistencia."
  else
    log "commits aplicados:"
    como_app git -C "$APP_DIR" --no-pager log --oneline "$antes..$depois"
  fi

  construir
  aplicar_migrations

  log "restart do servico"
  systemctl restart "$SERVICO"

  if ! esperar_saude; then
    erro "deploy falhou no health check - revertendo codigo para $antes"
    erro "ultimas linhas do servico:"
    journalctl -u "$SERVICO" -n 40 --no-pager || true
    cmd_rollback || erro "rollback automatico tambem falhou. Ver secao 9."
    exit 1
  fi

  echo "$depois" > "$ESTADO_DIR/commit-atual"
  log "===== DEPLOY OK: $depois ====="
  cmd_status
}

# -----------------------------------------------------------------------------
cmd_rollback() {
  log "===== ROLLBACK ====="
  local alvo
  if [[ ! -s "$ESTADO_DIR/commit-anterior" ]]; then
    erro "nao existe $ESTADO_DIR/commit-anterior. Rollback manual:"
    erro "  sudo -u $APP_USER git -C $APP_DIR log --oneline -20"
    erro "  sudo -u $APP_USER git -C $APP_DIR checkout <sha>"
    exit 1
  fi
  alvo=$(cat "$ESTADO_DIR/commit-anterior")
  log "voltando para $alvo"

  como_app git -C "$APP_DIR" checkout --force "$alvo"
  construir
  systemctl restart "$SERVICO"
  esperar_saude || { erro "o commit anterior TAMBEM nao sobe. Ver secao 9.4."; exit 1; }

  log "===== ROLLBACK OK: $alvo ====="
  log "ATENCAO: rollback desfaz CODIGO. Migration aplicada continua aplicada."
  log "         Conferir: sudo -u postgres psql -d $DB -c 'SELECT * FROM core.migration ORDER BY versao;'"
  log "         O repositorio esta em HEAD detached. Depois do fix:"
  log "         sudo -u $APP_USER git -C $APP_DIR checkout main"
}

# -----------------------------------------------------------------------------
cmd_status() {
  echo "--- git ---"
  como_app git -C "$APP_DIR" --no-pager log --oneline -3
  como_app git -C "$APP_DIR" status -sb | head -1
  echo "--- servicos ---"
  systemctl is-active "$SERVICO" nginx postgresql | paste -sd' '
  systemctl list-timers 'biotrop*' --no-pager | head -5
  echo "--- migrations ---"
  sudo -u postgres psql -d "$DB" -c \
    "SELECT versao, nome, aplicado_em, duracao_ms FROM core.migration ORDER BY versao;"
  echo "--- saude operacional ---"
  sudo -u postgres psql -d "$DB" -xc "SELECT * FROM app.vw_saude_operacional;"
}

# -----------------------------------------------------------------------------
case "${1:-}" in
  deploy)   cmd_deploy ;;
  rollback) cmd_rollback ;;
  migrate)  aplicar_migrations ;;
  status)   cmd_status ;;
  health)   esperar_saude ;;
  *) echo "uso: $0 {deploy|rollback|migrate|status|health}" >&2; exit 2 ;;
esac
```

Instalar. Os tres scripts operacionais (`deploy`, `backup`, `restore-test`) ficam versionados
no repositorio em `ops/`, e sao **copiados** para `/usr/local/sbin/` de propria mao - nunca
executados de dentro do working tree, pelo motivo da secao 5.1:

```bash
sudo install -m 0750 -o root -g root \
     /opt/biotrop/app/ops/biotrop-deploy.sh /usr/local/sbin/biotrop-deploy.sh
sudo mkdir -p /opt/biotrop/estado && sudo chown biotrop:biotrop /opt/biotrop/estado
sudo touch /var/log/biotrop-deploy.log && sudo chmod 640 /var/log/biotrop-deploy.log
sudo bash -n /usr/local/sbin/biotrop-deploy.sh    # confere a sintaxe sem executar
sudo /usr/local/sbin/biotrop-deploy.sh status     # primeira prova de vida
```

Sempre que um desses scripts mudar no repositorio, o `install` acima e um passo **manual e
consciente** depois do `git pull`. O deploy nao atualiza a si mesmo.

## 5.4 Rollback: os tres casos

| Situacao | O que fazer |
|---|---|
| Commit novo quebrou a tela, banco intocado | `sudo biotrop-deploy.sh rollback`. Resolve em um comando. |
| Commit novo veio com migration que **adiciona** coisa (coluna nova, tabela nova, view nova) | `rollback` do codigo basta. O objeto novo fica no banco sem uso e nao atrapalha - foi por isso que a 0001 e forward-only. |
| Migration **destrutiva** (dropou coluna, converteu dado, apagou linha) | Rollback de codigo nao resolve. Restaurar o dump de pre-deploy (secao 7.3) e escrever a migration corretiva. |

Antes de escrever migration que apaga ou converte dado: o dump de pre-deploy existe, mas
restaurar custa a janela e perde o que foi digitado depois do dump. Preferir sempre o
caminho aditivo (coluna nova, backfill, trocar a view do schema `app`, e so depois - em
outra migration, dias depois - remover a antiga).

## 5.5 Depois do rollback

O `git checkout <sha>` deixa o repositorio em HEAD detached. Isso e proposital: impede um
`deploy` seguinte de "consertar" sozinho por cima do rollback sem alguem entender o que
aconteceu. Sequencia correta de saida:

```bash
# na maquina de desenvolvimento: corrigir, testar, commitar, push
# na VM:
sudo -u biotrop git -C /opt/biotrop/app checkout main
sudo /usr/local/sbin/biotrop-deploy.sh deploy
```

---

# 6. Backup

## 6.1 O que precisa de backup, e por onde

| Ativo | Onde vive | Como e salvo | Se perder |
|---|---|---|---|
| Dados (inclui os anexos, que sao `bytea` em `core.anexo`) | base `biotrop` | `pg_dump -Fc` diario (6.2) | perda de trabalho digitado |
| Senhas das roles `biotrop_owner/app/ro` | catalogo global do cluster | `pg_dumpall --globals-only` diario | banco restaura, app nao conecta |
| Segredos do Entra/Graph | `/etc/biotrop/app.env` | cofre de senhas corporativo + copia cifrada (6.4) | login e e-mail param, precisa reemitir |
| Codigo | GitHub | o proprio git | nada, e so clonar |
| Configuracao da VM | `/etc/nginx`, `/etc/systemd/system`, `/etc/postgresql` | tar diario (6.2) + Azure Backup | remontar a VM na mao |
| A VM inteira | Azure | Azure Backup diario, 30 dias (6.5) | reprovisionar do zero |

O `pg_dump` cobre os anexos porque a decisao da 0001 foi guardar binario em `core.anexo`
como `bytea`. Isso engorda o dump: se `SELECT pg_size_pretty(sum(bytes)) FROM core.anexo`
passar de uns 5 GB, e hora de migrar conteudo para Azure Blob usando a coluna
`core.anexo.url_externa`, que ja existe para isso.

## 6.2 /usr/local/sbin/biotrop-backup.sh

```bash
#!/usr/bin/env bash
# =============================================================================
# BIOTROP - backup do PostgreSQL e da configuracao da VM
# Uso: biotrop-backup.sh [diario|pre-deploy|manual]
# Registra cada execucao em core.rotina_execucao (rotina = 'backup'), para que
# app.vw_saude_operacional.ultimo_backup_ok responda "o backup rodou?" por query.
# =============================================================================
set -Eeuo pipefail

DB=biotrop
RAIZ=/dados/backup/biotrop
MODO="${1:-diario}"
STAMP=$(date '+%Y%m%d-%H%M%S')
HOJE=$(date '+%Y-%m-%d')
DIA_SEMANA=$(date '+%u')     # 7 = domingo
DIA_MES=$(date '+%d')

RET_DIARIO=14                # dias
RET_SEMANAL=8                # semanas
RET_MENSAL=12                # meses
LOG=/var/log/biotrop-backup.log

mkdir -p "$RAIZ"/{diario,semanal,mensal,pre-deploy,config,globals}
exec > >(tee -a "$LOG") 2>&1
log() { printf '%s  [%s] %s\n' "$(date '+%F %T')" "$MODO" "$*"; }

psql_db() { sudo -u postgres psql -d "$DB" -v ON_ERROR_STOP=1 -qAt -c "$1"; }

# abre a linha de execucao ANTES de comecar: se a VM cair no meio, sobra uma
# linha com fim IS NULL, que e exatamente o sinal de "backup interrompido"
EXEC_ID=$(psql_db "INSERT INTO core.rotina_execucao (rotina, detalhe)
                   VALUES ('backup', 'modo=$MODO inicio') RETURNING id;")
log "core.rotina_execucao id=$EXEC_ID"

fechar() {
  local ok="$1" det="$2"
  psql_db "UPDATE core.rotina_execucao
              SET fim = now(), sucesso = $ok,
                  detalhe = \$\$$det\$\$
            WHERE id = $EXEC_ID;" >/dev/null
}
trap 'fechar false "falha na linha $LINENO (modo=$MODO)"; log "FALHOU"' ERR

case "$MODO" in
  pre-deploy) DESTINO="$RAIZ/pre-deploy" ;;
  *)          DESTINO="$RAIZ/diario" ;;
esac

ARQ="$DESTINO/${DB}-${STAMP}-${MODO}.dump"

# -----------------------------------------------------------------------------
# 1. dump dos dados (-Fc: comprimido, restauravel por objeto com pg_restore)
# -----------------------------------------------------------------------------
log "pg_dump -> $ARQ"
# SEM --no-privileges: os GRANTs da secao 18 da migration 0001 fazem parte do dump.
# O mais importante deles e o privilegio de coluna que esconde lms.questao_opcao.correta
# de biotrop_app. Dump sem privilegio restaura o gabarito visivel para a aplicacao.
sudo -u postgres pg_dump -Fc -Z6 -d "$DB" -f "$ARQ"
sudo -u postgres pg_restore --list "$ARQ" > /dev/null    # o dump abre?
TAM=$(du -h "$ARQ" | cut -f1)
log "dump ok ($TAM)"

# -----------------------------------------------------------------------------
# 2. globals: as senhas das roles NAO estao no pg_dump acima
# -----------------------------------------------------------------------------
GLOB="$RAIZ/globals/globals-${HOJE}.sql"
sudo -u postgres pg_dumpall --globals-only -f "$GLOB"
chmod 600 "$GLOB"
log "globals ok"

# -----------------------------------------------------------------------------
# 3. configuracao da VM
# -----------------------------------------------------------------------------
CFG="$RAIZ/config/config-${HOJE}.tar.gz"
tar -czf "$CFG" \
    /etc/nginx/sites-available /etc/nginx/conf.d \
    /etc/systemd/system/biotrop-*.service /etc/systemd/system/biotrop-*.timer \
    /etc/postgresql/15/main /usr/local/sbin/biotrop-*.sh 2>/dev/null || true
log "config ok"

# -----------------------------------------------------------------------------
# 4. copias de retencao (domingo = semanal, dia 01 = mensal)
# -----------------------------------------------------------------------------
# cp -l cria hardlink: a copia semanal/mensal nao gasta disco de novo, e o expurgo
# do diario nao apaga o conteudo enquanto o hardlink existir.
# if/then em vez de "[[ ]] && cmd": sob set -e, um teste falso na ultima posicao
# da linha derruba o script (e dispararia o trap ERR toda segunda-feira).
if [[ "$MODO" == "diario" ]]; then
  if [[ "$DIA_SEMANA" == "7"  ]]; then cp -l "$ARQ" "$RAIZ/semanal/"; log "copia semanal"; fi
  if [[ "$DIA_MES"    == "01" ]]; then cp -l "$ARQ" "$RAIZ/mensal/";  log "copia mensal";  fi
fi

# -----------------------------------------------------------------------------
# 5. expurgo
# -----------------------------------------------------------------------------
find "$RAIZ/diario"     -name '*.dump' -mtime +$RET_DIARIO            -delete -print
find "$RAIZ/semanal"    -name '*.dump' -mtime +$((RET_SEMANAL*7))     -delete -print
find "$RAIZ/mensal"     -name '*.dump' -mtime +$((RET_MENSAL*31))     -delete -print
find "$RAIZ/pre-deploy" -name '*.dump' -mtime +7                      -delete -print
find "$RAIZ/globals"    -name '*.sql'  -mtime +$RET_DIARIO            -delete
find "$RAIZ/config"     -name '*.tar.gz' -mtime +$RET_DIARIO          -delete

# -----------------------------------------------------------------------------
# 6. copia para fora da VM (backup no mesmo disco morre com o disco)
# -----------------------------------------------------------------------------
if [[ -n "${BACKUP_BLOB_URL:-}" ]]; then
  log "enviando para o Storage Account"
  az login --identity --only-show-errors >/dev/null
  az storage blob upload --auth-mode login --overwrite \
     --blob-url "${BACKUP_BLOB_URL}/$(basename "$ARQ")" --file "$ARQ" --only-show-errors
  log "copia externa ok"
else
  log "AVISO: BACKUP_BLOB_URL nao definido - backup existe SO no disco desta VM"
fi

TOTAL=$(du -sh "$RAIZ" | cut -f1)
fechar true "modo=$MODO arquivo=$(basename "$ARQ") tamanho=$TAM total_retido=$TOTAL"
log "OK  arquivo=$TAM  retido=$TOTAL"
```

Instalar:

```bash
sudo install -m 0750 -o root -g root \
     /opt/biotrop/app/ops/biotrop-backup.sh /usr/local/sbin/biotrop-backup.sh
sudo mkdir -p /dados/backup/biotrop && sudo chmod 750 /dados/backup/biotrop
sudo touch /var/log/biotrop-backup.log && sudo chmod 640 /var/log/biotrop-backup.log
sudo bash -n /usr/local/sbin/biotrop-backup.sh
sudo /usr/local/sbin/biotrop-backup.sh manual      # primeira execucao, na mao
```

## 6.3 Cron

```bash
sudo tee /etc/cron.d/biotrop > /dev/null <<'CRON'
# BIOTROP - rotinas de servidor
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
# destino externo do backup (deixar vazio desabilita o upload)
BACKUP_BLOB_URL=https://stbiotropbkp.blob.core.windows.net/biotrop-db

# backup completo, todo dia as 02:10 (fora do horario de uso)
10 2 * * *   root  /usr/local/sbin/biotrop-backup.sh diario

# teste de restauracao, todo dia 05 as 03:20 - backup nunca restaurado nao e backup
20 3 5 * *   root  /usr/local/sbin/biotrop-restore-test.sh

# VACUUM ANALYZE semanal, domingo 04:00
0 4 * * 0    postgres  /usr/bin/vacuumdb --analyze --quiet -d biotrop

# aviso por e-mail se o backup nao rodou nas ultimas 26h
30 8 * * *   root  /usr/local/sbin/biotrop-check-backup.sh
CRON
sudo chmod 644 /etc/cron.d/biotrop
```

`/usr/local/sbin/biotrop-check-backup.sh` - usa a propria fila de e-mail do sistema, entao
o aviso sai pelo mesmo caminho (Graph) que o resto:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
sudo -u postgres psql -d biotrop -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO core.email_fila (destinatario, assunto, corpo_html, motivo)
SELECT 'felipe.vieira@biotrop.com.br',
       'BIOTROP: backup do banco NAO rodou',
       '<p>Ultimo backup com sucesso: <b>' ||
         coalesce(to_char(v.ultimo_backup_ok, 'DD/MM/YYYY HH24:MI'), 'NUNCA') ||
       '</b></p><p>Verificar na VM: <code>journalctl -t biotrop-backup</code> e ' ||
       '<code>tail /var/log/biotrop-backup.log</code></p>',
       'backup_atrasado'
  FROM app.vw_saude_operacional v
 WHERE v.ultimo_backup_ok IS NULL
    OR v.ultimo_backup_ok < now() - interval '26 hours';
SQL
```

## 6.4 Copia do segredo

O `app.env` nao entra em nenhum dump. Copia cifrada, guardada junto do backup e com a
senha no cofre corporativo (senha diferente das senhas de role):

```bash
sudo bash -c 'gpg --symmetric --cipher-algo AES256 \
  --output /dados/backup/biotrop/config/app.env.$(date +%F).gpg /etc/biotrop/app.env'
```

Refazer a cada troca de segredo. Sem isso, restaurar o banco em uma VM nova nao entrega o
sistema funcionando: a aplicacao sobe e ninguem loga.

## 6.5 Backup da VM (Azure Backup)

Pedir a TI (adendo ao chamado da secao 1):

- Recovery Services vault, politica diaria, retencao 30 dias, janela 01:00-03:00.
- Storage Account `stbiotropbkp`, container `biotrop-db`, replicacao GRS, soft delete 14
  dias, e **Storage Blob Data Contributor** para a identidade gerenciada da VM
  (e o que faz o `az storage blob upload` da secao 6.2 funcionar sem senha na VM).
- Confirmar por escrito a primeira execucao com sucesso.

Snapshot de VM com o Postgres ligado e crash-consistent: recupera a maquina, nao garante o
banco. A ordem de preferencia numa recuperacao e sempre: (1) `pg_dump` do dia, (2) snapshot
da VM, (3) reprovisionar e aplicar a migration 0001 do zero.

## 6.6 Conferir o backup sem abrir a VM

```sql
-- rodou hoje?
SELECT ultimo_backup_ok FROM app.vw_saude_operacional;

-- ultimas 10 execucoes, com tamanho e duracao
SELECT inicio, fim - inicio AS duracao, sucesso, detalhe
  FROM core.rotina_execucao
 WHERE rotina = 'backup'
 ORDER BY inicio DESC
 LIMIT 10;

-- execucao que comecou e nunca terminou (VM caiu no meio do dump)
SELECT * FROM core.rotina_execucao
 WHERE rotina = 'backup' AND fim IS NULL AND inicio < now() - interval '2 hours';
```

Na VM:

```bash
ls -lh /dados/backup/biotrop/diario | tail -5
df -h /dados
sudo -u postgres pg_restore --list \
  "$(ls -t /dados/backup/biotrop/diario/*.dump | head -1)" | head -20
```

---

# 7. Restauracao

**Backup nunca restaurado nao e backup.** O teste roda todo dia 05 pelo cron da secao 6.3 e
falha alto (linha em `core.rotina_execucao` com `sucesso = false`) quando o dump nao presta.

## 7.1 /usr/local/sbin/biotrop-restore-test.sh

Restaura o dump mais recente em uma base descartavel do mesmo cluster e confere se o
conteudo faz sentido. Nao toca na base de producao em nenhum momento.

```bash
#!/usr/bin/env bash
# =============================================================================
# BIOTROP - teste de restauracao do backup
# Restaura o dump mais novo em biotrop_teste_restore e valida o conteudo.
# Registra em core.rotina_execucao (rotina = 'restore_teste') NO BANCO DE PRODUCAO,
# para o resultado aparecer na mesma consulta de sempre.
# =============================================================================
set -Eeuo pipefail

DB_PRD=biotrop
DB_TST=biotrop_teste_restore
RAIZ=/dados/backup/biotrop
LOG=/var/log/biotrop-restore-test.log

exec > >(tee -a "$LOG") 2>&1
log() { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }
prd() { sudo -u postgres psql -d "$DB_PRD" -v ON_ERROR_STOP=1 -qAt -c "$1"; }
tst() { sudo -u postgres psql -d "$DB_TST" -v ON_ERROR_STOP=1 -qAt -c "$1"; }

DUMP=$(ls -t "$RAIZ"/diario/*.dump 2>/dev/null | head -1 || true)
[[ -n "$DUMP" ]] || { log "ERRO: nenhum dump em $RAIZ/diario"; exit 1; }
log "dump escolhido: $DUMP"

EXEC_ID=$(prd "INSERT INTO core.rotina_execucao (rotina, detalhe)
                VALUES ('restore_teste', 'arquivo=$(basename "$DUMP")') RETURNING id;")
fechar() { prd "UPDATE core.rotina_execucao SET fim = now(), sucesso = $1,
                    detalhe = \$\$$2\$\$ WHERE id = $EXEC_ID;" >/dev/null; }
trap 'fechar false "falha na linha $LINENO"; log "TESTE FALHOU"' ERR

# 1. base limpa
sudo -u postgres dropdb --if-exists "$DB_TST"
sudo -u postgres createdb -E UTF8 -T template0 \
     --lc-collate=pt_BR.UTF-8 --lc-ctype=pt_BR.UTF-8 "$DB_TST"

# 2. restaurar. -j 2 na B2ms; --exit-on-error para o teste falhar de verdade
INI=$(date +%s)
sudo -u postgres pg_restore -d "$DB_TST" -j 2 --exit-on-error "$DUMP"
DUR=$(( $(date +%s) - INI ))
log "restaurado em ${DUR}s"

# 3. validacao: estrutura
MIGR=$(tst "SELECT count(*) FROM core.migration;")
TABS=$(tst "SELECT count(*) FROM pg_tables
             WHERE schemaname IN ('core','almox','util','lms','pcm','mig');")
VIEWS=$(tst "SELECT count(*) FROM pg_views WHERE schemaname IN ('app','mig');")
FUNCS=$(tst "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname IN ('core','almox','util','lms','mig');")
log "migrations=$MIGR tabelas=$TABS views=$VIEWS funcoes=$FUNCS"
[[ "$MIGR"  -ge 1  ]] || { log "ERRO: core.migration vazia"; false; }
[[ "$TABS"  -ge 45 ]] || { log "ERRO: menos tabelas que o esperado (>=45)"; false; }
[[ "$VIEWS" -ge 20 ]] || { log "ERRO: menos views que o esperado (>=20)"; false; }
[[ "$FUNCS" -ge 30 ]] || { log "ERRO: menos funcoes que o esperado (>=30)"; false; }

# 4. validacao: dado, comparando com producao (tolerancia = o que foi digitado hoje)
for T in core.usuario core.grupo almox.sci almox.scm util.medidor util.leitura \
         lms.matricula core.anexo core.email_autorizado; do
  A=$(prd "SELECT count(*) FROM $T;")
  B=$(tst "SELECT count(*) FROM $T;")
  log "  $T  producao=$A  restaurado=$B"
  [[ "$B" -le "$A" ]] || { log "ERRO: $T tem MAIS linhas no dump que em producao"; false; }
done

# 5. validacao: as regras do banco continuam de pe no restaurado
tst "SELECT * FROM core.pode_autenticar('felipe.vieira@biotrop.com.br');" > /dev/null
tst "SELECT * FROM app.vw_saude_operacional;"  > /dev/null
tst "SELECT * FROM app.vw_sci;"                > /dev/null
tst "SELECT * FROM app.vw_scm_fila_aprovacao;" > /dev/null
tst "SELECT * FROM app.vw_util_desvio;"        > /dev/null
tst "SELECT * FROM app.vw_lms_conformidade;"   > /dev/null
log "views das telas respondem no banco restaurado"

# 6. validacao: os anexos nao vieram truncados (bytea e o que mais engorda o dump)
ANEXO_OK=$(tst "SELECT count(*) FROM core.anexo
                 WHERE conteudo IS NOT NULL AND octet_length(conteudo) <> bytes;")
[[ "$ANEXO_OK" == "0" ]] || { log "ERRO: $ANEXO_OK anexos com tamanho divergente"; false; }
log "anexos conferem"

# 7. validacao: o gabarito continua invisivel para a role da aplicacao
GAB=$(sudo -u postgres psql -d "$DB_TST" -qAt -c \
  "SELECT has_column_privilege('biotrop_app','lms.questao_opcao','correta','SELECT');")
[[ "$GAB" == "f" ]] || { log "ERRO: biotrop_app enxerga lms.questao_opcao.correta"; false; }
log "privilegio de coluna do gabarito preservado"

sudo -u postgres dropdb "$DB_TST"
fechar true "restauracao validada em ${DUR}s, arquivo=$(basename "$DUMP"), tabelas=$TABS"
log "TESTE OK"
```

Instalar e rodar a primeira vez na mao, no mesmo dia da publicacao:

```bash
sudo install -m 0750 -o root -g root \
     /opt/biotrop/app/ops/biotrop-restore-test.sh /usr/local/sbin/biotrop-restore-test.sh
sudo bash -n /usr/local/sbin/biotrop-restore-test.sh
sudo /usr/local/sbin/biotrop-restore-test.sh
```

E o script `biotrop-check-backup.sh` da secao 6.3:

```bash
sudo install -m 0750 -o root -g root \
     /opt/biotrop/app/ops/biotrop-check-backup.sh /usr/local/sbin/biotrop-check-backup.sh
```

Conferir o historico depois:

```sql
SELECT inicio, fim - inicio AS duracao, sucesso, detalhe
  FROM core.rotina_execucao
 WHERE rotina = 'restore_teste'
 ORDER BY inicio DESC LIMIT 6;
```

## 7.2 Restauracao real na mesma VM

Cenario: alguem apagou dado em producao, ou uma migration converteu dado errado.

```bash
# 1. tirar a aplicacao do ar (evita gravar por cima durante a restauracao)
sudo systemctl stop biotrop-app biotrop-mailer.timer

# 2. dump do estado ATUAL, mesmo que ele esteja errado.
#    Restauracao apaga o presente: sem esta copia, nao existe volta da volta.
sudo -u postgres pg_dump -Fc -d biotrop \
     -f /dados/backup/biotrop/pre-deploy/antes-da-restauracao-$(date +%F-%H%M).dump

# 3. escolher o dump de origem
ls -lht /dados/backup/biotrop/diario | head
DUMP=/dados/backup/biotrop/diario/biotrop-AAAAMMDD-HHMMSS-diario.dump

# 4. renomear a base atual em vez de dropar (volta em 1 comando se der errado)
sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
                           WHERE datname = 'biotrop' AND pid <> pg_backend_pid();"
sudo -u postgres psql -c 'ALTER DATABASE biotrop RENAME TO biotrop_quebrado;'

# 5. base nova e restauracao
sudo -u postgres createdb -O biotrop_owner -E UTF8 -T template0 \
     --lc-collate=pt_BR.UTF-8 --lc-ctype=pt_BR.UTF-8 biotrop
sudo -u postgres pg_restore -d biotrop -j 2 --exit-on-error "$DUMP"

# 6. conferir ANTES de subir a aplicacao
sudo -u postgres psql -d biotrop -c 'SELECT * FROM core.migration ORDER BY versao;'
sudo -u postgres psql -d biotrop -xc 'SELECT * FROM app.vw_saude_operacional;'
sudo -u postgres psql -d biotrop -c \
  "SELECT * FROM core.pode_autenticar('felipe.vieira@biotrop.com.br');"

# 7. o codigo tem de casar com o schema restaurado.
#    Se o dump e de antes da migration 0003, o codigo tambem tem de ser de antes:
sudo /usr/local/sbin/biotrop-deploy.sh status     # comparar core.migration com o commit

# 8. subir
sudo systemctl start biotrop-app biotrop-mailer.timer
sudo /usr/local/sbin/biotrop-deploy.sh health

# 9. so depois de alguns dias de operacao normal:
sudo -u postgres dropdb biotrop_quebrado
```

Restaurar **uma tabela so** (caso mais comum: alguem apagou uma lista):

```bash
# 7.2 completo e caro. Para uma tabela, restaurar em base auxiliar e copiar as linhas.
sudo -u postgres createdb biotrop_aux
sudo -u postgres pg_restore -d biotrop_aux -t medidor -n util --exit-on-error "$DUMP"
sudo -u postgres psql -d biotrop_aux -c \
  "\copy (SELECT * FROM util.medidor) TO '/tmp/medidor.csv' CSV HEADER"
sudo -u postgres psql -d biotrop <<'SQL'
CREATE TEMP TABLE t_medidor (LIKE util.medidor INCLUDING DEFAULTS);
\copy t_medidor FROM '/tmp/medidor.csv' CSV HEADER
INSERT INTO util.medidor SELECT * FROM t_medidor
  ON CONFLICT (id) DO NOTHING;      -- so o que faltava; nao sobrescreve o atual
SQL
sudo -u postgres dropdb biotrop_aux && sudo rm -f /tmp/medidor.csv
```

## 7.3 Restauracao em VM nova (perda total)

Ordem obrigatoria. Errar a ordem 2/3 faz o `pg_restore` falhar nos GRANTs.

1. Provisionar VM pela secao 2 (itens 2.1 a 2.4). **Nao** aplicar a 0001 ainda.
2. Restaurar as roles e suas senhas:
   `sudo -u postgres psql -f globals-AAAA-MM-DD.sql`
3. `createdb` + `pg_restore` do dump mais recente (passos 5 e 6 da secao 7.2).
4. Restaurar a configuracao: `sudo tar -xzf config-AAAA-MM-DD.tar.gz -C /` e
   `sudo systemctl daemon-reload`.
5. Recuperar o segredo: `gpg --decrypt app.env.AAAA-MM-DD.gpg | sudo tee /etc/biotrop/app.env`
   e `sudo chmod 600 /etc/biotrop/app.env`.
6. `git clone` do repositorio no commit que corresponde a maior `versao` de
   `core.migration`, e `biotrop-deploy.sh deploy`.
7. TI atualiza o registro A do DNS para o novo IP e reinstala o certificado.
8. Rodar o checklist da secao 10 inteiro antes de avisar os usuarios.

Tempo realista deste procedimento, com o dump em maos: 2 a 3 horas. E o RTO da fase 1. RPO:
24 horas (backup diario as 02:10) - o que foi digitado entre o ultimo dump e a queda se
perde. Se isso for inaceitavel para o negocio, o proximo passo tecnico e WAL archiving
para o Storage Account, nao mais backup diario.

---

# 8. Emergencia: ninguem consegue entrar

Caso concreto, ja aconteceu: **o unico usuario foi bloqueado pela propria tela de acesso e
a plataforma ficou sem ninguem capaz de administrar.** Nao existe "esqueci a senha" para
resolver isso - o login e Entra ID e a autorizacao esta no banco. A saida e o `psql` na VM.

Isso funciona porque o PostgreSQL usa autenticacao `peer` local: quem e root na VM entra
como `postgres` **sem senha**. Cuidar do acesso SSH e, portanto, cuidar da chave mestra do
sistema.

## 8.1 Chegar ao psql

```bash
ssh azureuser@manutencao.biotrop.com.br
sudo -u postgres psql -d biotrop
```

Se o SSH nao responder (NSG mudou, sshd fora), do Windows com Azure CLI:

```powershell
az vm run-command invoke -g rg-biotrop-prd -n vm-biotrop-manut-prd-01 `
  --command-id RunShellScript `
  --scripts "sudo -u postgres psql -d biotrop -c \"SELECT * FROM app.vw_login_permitido;\""
```

Ultimo recurso: portal Azure > VM > Support + troubleshooting > Serial console.

## 8.2 Diagnostico (rodar antes de mudar qualquer coisa)

```sql
-- 1. estado de acesso de TODO e-mail liberado, com o motivo da recusa
SELECT email, autorizacao_ativa, usuario_ativo, bloqueado, perfil_padrao,
       permitido, motivo
  FROM app.vw_login_permitido
 ORDER BY permitido, email;

-- 2. existe algum administrador em pe?
SELECT u.nome, u.email, u.perfil_id, u.ativo, u.bloqueado, u.motivo_bloqueio
  FROM core.usuario u
 WHERE u.perfil_id = 'admin'
 ORDER BY u.ativo DESC, u.bloqueado;

-- 3. as ultimas recusas de login, com o motivo que o sistema registrou
SELECT em, email, sucesso, motivo, ip
  FROM core.login_evento
 ORDER BY em DESC
 LIMIT 20;

-- 4. quem mudou o que, e quando (a trilha guarda a linha antes e depois)
SELECT em, ator_email, operacao,
       antes  ->> 'email'     AS email,
       antes  ->> 'bloqueado' AS bloqueado_antes,
       depois ->> 'bloqueado' AS bloqueado_depois,
       depois ->> 'motivo_bloqueio' AS motivo
  FROM core.auditoria
 WHERE tabela = 'core.usuario'
 ORDER BY em DESC
 LIMIT 20;
```

A coluna `motivo` da consulta 1 vem de `core.pode_autenticar()`, que e o ponto unico da
regra de acesso. Ela diz exatamente qual dos quatro bloqueios pegou:

| `motivo` | O que corrigir |
|---|---|
| `e-mail nao consta na lista de autorizados` | falta linha em `core.email_autorizado` |
| `autorizacao revogada` | `core.email_autorizado.ativo = false` |
| `bloqueado: <texto>` | `core.usuario.bloqueado = true` |
| `usuario inativo` | `core.usuario.ativo = false` |
| `autorizado - usuario sera criado no primeiro acesso` | ok, so nunca logou |

## 8.3 O comando de reativacao

Uma transacao, resolve os quatro bloqueios de uma vez e serve tanto para usuario existente
quanto para usuario que nunca logou. O `SET LOCAL app.usuario_email` faz a trilha em
`core.auditoria` registrar que a mudanca foi de emergencia no psql, e nao da tela - sem
ele o campo `ator_email` fica nulo e o rastro perde o dono.

```sql
\set alvo 'felipe.vieira@biotrop.com.br'

BEGIN;
SET LOCAL app.usuario_email = 'emergencia-psql@biotrop.com.br';

-- 1. liberar/reativar a autorizacao de acesso.
--    revogado_em volta a NULL por causa da constraint ck_email_autorizado_revogacao,
--    que exige (ativo OR revogado_em IS NOT NULL).
INSERT INTO core.email_autorizado (email, ativo, perfil_padrao, motivo)
VALUES (:'alvo', true, 'admin',
        'reativacao de emergencia ' || to_char(now(), 'YYYY-MM-DD HH24:MI'))
ON CONFLICT (email) DO UPDATE
   SET ativo         = true,
       revogado_em   = NULL,
       perfil_padrao = 'admin',
       motivo        = 'reativacao de emergencia ' || to_char(now(), 'YYYY-MM-DD HH24:MI');

-- 2. desbloquear e reativar o usuario, devolvendo o perfil admin.
--    motivo_bloqueio volta a NULL: a constraint ck_usuario_bloqueio so exige motivo
--    quando bloqueado = true.
UPDATE core.usuario
   SET ativo           = true,
       bloqueado       = false,
       motivo_bloqueio = NULL,
       perfil_id       = 'admin'
 WHERE email = :'alvo';

-- 3. se a pessoa nunca chegou a existir em core.usuario, criar agora.
--    perfil_id 'admin' vem do seed de core.perfil, que e fixo e protegido por trigger.
INSERT INTO core.usuario (nome, email, perfil_id, ativo, bloqueado)
SELECT 'Administrador de emergencia', :'alvo', 'admin', true, false
 WHERE NOT EXISTS (SELECT 1 FROM core.usuario WHERE email = :'alvo');

-- 4. CONFERIR ANTES DE COMMITAR. Tem de voltar permitido = t, motivo = ok
SELECT * FROM core.pode_autenticar(:'alvo');

COMMIT;
```

Se o `SELECT` do passo 4 voltar `permitido = f`, **nao commite**: rode `ROLLBACK;`, releia
a secao 8.2 e descubra qual condicao ainda esta de pe. Commitar sem conferir e como o
bloqueio comecou.

Depois do COMMIT, conferir do lado de fora e limpar a sessao velha:

```sql
SELECT email, permitido, motivo FROM app.vw_login_permitido WHERE email = :'alvo';
```

O usuario precisa **sair e entrar de novo** no navegador: a sessao antiga pode ter sido
emitida antes do bloqueio e o servidor a revalida contra `core.pode_autenticar()` a cada
requisicao protegida.

## 8.4 Reativar um segundo administrador (o que evita a proxima vez)

Um administrador so e o defeito de projeto que causou o incidente. Criar o segundo agora:

```sql
BEGIN;
SET LOCAL app.usuario_email = 'emergencia-psql@biotrop.com.br';

INSERT INTO core.email_autorizado (email, ativo, perfil_padrao, motivo)
VALUES ('SEGUNDO.ADMIN@biotrop.com.br', true, 'admin',
        'segundo administrador - nao remover, e a saida de emergencia')
ON CONFLICT (email) DO UPDATE SET ativo = true, revogado_em = NULL, perfil_padrao = 'admin';

INSERT INTO core.usuario (nome, email, perfil_id, grupo_id, ativo)
SELECT 'Nome do Segundo Admin', 'SEGUNDO.ADMIN@biotrop.com.br', 'admin',
       (SELECT id FROM core.grupo WHERE codigo = 'g-pcm'), true
ON CONFLICT (email) DO UPDATE SET perfil_id = 'admin', ativo = true, bloqueado = false;

SELECT email, permitido, motivo FROM app.vw_login_permitido WHERE perfil_padrao = 'admin';
COMMIT;
```

## 8.5 Trava para o banco recusar ficar sem administrador

O arquivo 0001 ja protege o **perfil**: `core.fn_protege_perfil_fixo()` impede apagar ou
desativar o perfil `admin` e impede remover permissao dele. O que ele **nao** protege e o
ultimo **usuario** administrador. Essa e a trava que faltava, e ela e a proxima migration -
nao um comando digitado no psql, que se perde no proximo restore.

Criar `migrations/0002_trava_admin.sql` no repositorio:

```sql
-- =====================================================================================
-- Migration 0002_trava_admin.sql
-- Motivo: em producao o unico administrador foi bloqueado pela propria tela de acesso e
-- a plataforma ficou sem ninguem capaz de administrar. A recuperacao exigiu psql na VM.
-- O banco passa a recusar a operacao que produz esse estado.
-- =====================================================================================
SET client_encoding = 'UTF8';

CREATE OR REPLACE FUNCTION core.fn_exige_admin_utilizavel() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM core.usuario u
      JOIN core.email_autorizado a ON a.email = u.email AND a.ativo
     WHERE u.perfil_id = 'admin'
       AND u.ativo
       AND NOT u.bloqueado
  ) THEN
    RAISE EXCEPTION
      'Operacao recusada: deixaria a plataforma sem nenhum administrador ativo, '
      'nao bloqueado e com e-mail autorizado. Promova outro administrador antes.';
  END IF;
  RETURN NULL;
END $$;
COMMENT ON FUNCTION core.fn_exige_admin_utilizavel() IS
  'Constraint trigger DEFERRABLE: no COMMIT precisa existir ao menos um usuario perfil_id=admin ativo, nao bloqueado e com core.email_autorizado.ativo. Sendo deferida, uma troca de administrador dentro da mesma transacao continua possivel.';

DROP TRIGGER IF EXISTS tg_exige_admin_usuario ON core.usuario;
CREATE CONSTRAINT TRIGGER tg_exige_admin_usuario
  AFTER INSERT OR UPDATE OR DELETE ON core.usuario
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION core.fn_exige_admin_utilizavel();

DROP TRIGGER IF EXISTS tg_exige_admin_autorizado ON core.email_autorizado;
CREATE CONSTRAINT TRIGGER tg_exige_admin_autorizado
  AFTER INSERT OR UPDATE OR DELETE ON core.email_autorizado
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION core.fn_exige_admin_utilizavel();

INSERT INTO core.migration (versao, nome, observacao) VALUES
  ('0002', 'trava_admin',
   'Constraint trigger deferida que recusa transacao que deixe a plataforma sem administrador utilizavel.')
ON CONFLICT (versao) DO NOTHING;
```

Testar antes de subir (a transacao tem de estourar no COMMIT, nao no UPDATE):

```sql
BEGIN;
UPDATE core.usuario SET bloqueado = true, motivo_bloqueio = 'teste da trava'
 WHERE perfil_id = 'admin';
COMMIT;   -- esperado: ERROR: Operacao recusada: deixaria a plataforma sem ...
ROLLBACK;
```

Sendo deferida, a trava nao atrapalha nada legitimo: trocar de administrador em uma
transacao (promover o novo, rebaixar o antigo) passa, porque a verificacao acontece no
COMMIT. E a importacao do dump do localStorage (`mig.importar_tudo`) tambem passa, desde
que ao final exista um administrador utilizavel.

## 8.6 Outras formas de perder o acesso (e o conserto)

| Sintoma | Causa provavel | Conserto |
|---|---|---|
| Tela de login abre, entra e cai em "sem permissao" | perfil do usuario perdeu permissao | `SELECT * FROM app.vw_perfil_permissoes WHERE perfil_id = 'admin';` - o perfil `admin` e fixo e o trigger `tg_perfil_permissao_fixo` impede remover; se a pessoa nao e admin, `UPDATE core.usuario SET perfil_id='admin' WHERE email='...'` |
| Erro 500 em toda tela, log com `password authentication failed for user "biotrop_app"` | senha da role divergente do `DATABASE_URL` | `ALTER ROLE biotrop_app PASSWORD '...'` + ajustar `/etc/biotrop/app.env` + `systemctl restart biotrop-app` |
| Erro 500 com `role "biotrop_app" is not permitted to log in` | role voltou a `NOLOGIN` (por restore de globals antigo) | `ALTER ROLE biotrop_app LOGIN;` |
| Erro 500 com `permission denied for table ...` depois de uma migration | tabela nova sem GRANT | reaplicar a secao 18 da 0001 (e idempotente) ou incluir o GRANT na propria migration |
| Login do Entra devolve `AADSTS7000215` / `invalid_client` | client secret expirou | TI emite novo, atualizar `AZURE_CLIENT_SECRET`, restart |
| Login do Entra devolve `AADSTS50011` (redirect mismatch) | Redirect URI diferente do `APP_URL` | conferir os dois valores caractere por caractere |
| Ninguem recebe e-mail | fila parada | `SELECT count(*) FROM app.vw_email_fila_pendente;` e `SELECT id, destinatario, erro, tentativas FROM core.email_fila WHERE status='erro' ORDER BY criado_em DESC;` |
| SCM nao encontra aprovador | grupo sem responsavel | `SELECT * FROM app.vw_aprovador_de WHERE origem = 'nenhum';` e apontar `core.grupo.responsavel_id` |

---

# 9. Onde olhar quando quebrar

```bash
# aplicacao
sudo systemctl status biotrop-app
sudo journalctl -u biotrop-app -n 200 --no-pager
sudo journalctl -u biotrop-app -f                      # acompanhar ao vivo

# proxy
sudo nginx -t
sudo tail -f /var/log/nginx/biotrop.error.log
sudo tail -f /var/log/nginx/biotrop.access.log

# banco
sudo systemctl status postgresql
sudo tail -100 /var/log/postgresql/postgresql-15-main.log
sudo -u postgres psql -d biotrop -c \
  "SELECT pid, usename, state, wait_event, now()-query_start AS ha, left(query,80)
     FROM pg_stat_activity WHERE datname='biotrop' AND state<>'idle'
     ORDER BY query_start;"

# rotinas
sudo systemctl list-timers 'biotrop*' --no-pager
sudo journalctl -u biotrop-mailer -n 50 --no-pager
sudo tail -50 /var/log/biotrop-backup.log
sudo tail -80 /var/log/biotrop-deploy.log

# recursos
df -h / /dados
free -m
sudo -u postgres psql -d biotrop -c \
  "SELECT pg_size_pretty(pg_database_size('biotrop')) AS banco,
          (SELECT pg_size_pretty(coalesce(sum(bytes),0)) FROM core.anexo) AS anexos;"
```

Uma query para a rotina de segunda-feira:

```sql
SELECT * FROM app.vw_saude_operacional;
```

Devolve, em uma linha: usuarios ativos, grupos sem responsavel, SCI em aberto, SCM
aguardando aprovacao, SCI com dado faltando, desvios de utilidades abertos, medidores sem
leitura em 35 dias, treinamentos irregulares, e-mails pendentes, e-mails com erro e o
horario do ultimo backup bem-sucedido.

| Coluna com valor ruim | O que fazer |
|---|---|
| `ultimo_backup_ok` nulo ou de anteontem | secao 6.6 |
| `emails_com_erro` > 0 | `SELECT id, destinatario, assunto, erro, tentativas FROM core.email_fila WHERE status='erro';` |
| `emails_pendentes` crescendo | `systemctl status biotrop-mailer.timer` e `journalctl -u biotrop-mailer` |
| `grupos_sem_responsavel` > 0 | `SELECT * FROM app.vw_aprovador_de WHERE origem='nenhum';` - SCM desse pessoal nao tem para quem ir |
| `desvios_abertos` > 0 | `SELECT * FROM app.vw_util_desvio WHERE situacao='aberto';` |
| `sci_com_dado_faltando` > 0 | `SELECT * FROM app.vw_sci_pendencia_dado;` |

---

# 10. Checklist de publicacao

Imprimir e riscar. Nada de "depois eu vejo".

## A. Antes de tocar na VM (depende da TI)

- [ ] VM criada, tamanho e discos conforme a secao 1.1
- [ ] SSH funcionando com a chave enviada
- [ ] `nslookup manutencao.biotrop.com.br` resolve para o IP correto
- [ ] NSG: 443 e 80 restritos as faixas corporativas, 22 restrito a TI, **5432 fechado**
- [ ] Certificado TLS em maos (ou Let's Encrypt confirmado) com a data de expiracao anotada
- [ ] App registration de login criada, Redirect URI conferido caractere por caractere
- [ ] App registration de e-mail criada, Mail.Send consentido e ApplicationAccessPolicy
      limitando ao remetente `manutencao@biotrop.com.br`
- [ ] Azure Backup da VM ativo com a primeira execucao concluida
- [ ] Storage Account do backup criado e identidade gerenciada da VM com
      Storage Blob Data Contributor

## B. Sistema operacional

- [ ] `timedatectl` mostrando `America/Sao_Paulo`
- [ ] `/dados` montado e no `/etc/fstab` com `nofail`
- [ ] Node 20 (`node -v`)
- [ ] `unattended-upgrades` ativo para pacotes de seguranca
- [ ] `ufw status` com apenas 22, 80 e 443
- [ ] usuario de SO `biotrop` criado sem shell de login

## C. Banco

- [ ] PostgreSQL 15 rodando com `data_directory = /dados/pgdata/main`
- [ ] `show listen_addresses` = `localhost`
- [ ] base `biotrop` criada com encoding UTF8
- [ ] `migrations/0001_base.sql` aplicado sem erro, com `ON_ERROR_STOP=1`
- [ ] `SELECT versao, nome FROM core.migration;` mostra a linha `0001 / base`
- [ ] `ALTER ROLE biotrop_app LOGIN PASSWORD` e o mesmo de `biotrop_ro` executados
- [ ] `psql "postgresql://biotrop_app:...@127.0.0.1/biotrop" -c 'select 1'` conecta
- [ ] `SELECT has_column_privilege('biotrop_app','lms.questao_opcao','correta','SELECT');`
      devolve **`f`** (o gabarito nao pode chegar ao navegador)
- [ ] `SELECT count(*) FROM core.grupo;` = 11
- [ ] `SELECT count(*) FROM core.perfil;` = 7
- [ ] `SELECT * FROM core.pode_autenticar('felipe.vieira@biotrop.com.br');` devolve
      `permitido = t`
- [ ] `SELECT * FROM app.vw_saude_operacional;` responde sem erro

## D. Aplicacao

- [ ] repositorio clonado em `/opt/biotrop/app` com Deploy key read-only
- [ ] `.gitignore` cobre `.env*` (conferir com `git check-ignore -v .env.production`)
- [ ] `/etc/biotrop/app.env` completo, `0600 root:root`
- [ ] nenhuma variavel de segredo com prefixo `NEXT_PUBLIC_`
- [ ] `/usr/local/sbin/biotrop-deploy.sh deploy` roda do inicio ao fim
- [ ] `systemctl is-enabled biotrop-app` = `enabled`
- [ ] `curl -fsS http://127.0.0.1:3000/api/health` responde 200
- [ ] `curl -I https://manutencao.biotrop.com.br` responde 200 com
      `Strict-Transport-Security`
- [ ] `curl -I http://manutencao.biotrop.com.br` responde 301 para https
- [ ] login pelo Entra ID funcionando com a conta do administrador
- [ ] upload de foto de 15 MB conclui (testa `client_max_body_size` contra
      `ck_anexo_tamanho`)
- [ ] reiniciar a VM inteira (`sudo reboot`) e conferir que tudo volta sozinho

## E. Virada do localStorage (uma vez so)

- [ ] export do navegador salvo fora da VM antes de qualquer coisa
- [ ] `SELECT mig.carregar_dump( <json> , 'export-AAAA-MM-DD.json');`
- [ ] `SELECT mig.importar_tudo('<lote_id>');`
- [ ] `SELECT * FROM mig.vw_conferencia;` - toda linha com divergencia explicada
- [ ] `SELECT * FROM mig.ocorrencia ORDER BY em;` lido inteiro
- [ ] `SELECT * FROM app.vw_aprovador_de WHERE origem = 'nenhum';` vazio, ou com
      `core.grupo.responsavel_id` apontado
- [ ] `SELECT escopo, ultimo_valor FROM core.sequencia;` maior que o maior codigo
      importado (a `mig.sincronizar_sequencias()` faz isso; conferir)
- [ ] `core.email_autorizado` revisado linha por linha antes de liberar o acesso
- [ ] **segundo administrador** criado (secao 8.4)
- [ ] `migrations/0002_trava_admin.sql` no repositorio e aplicado (secao 8.5)

## F. Backup e recuperacao

- [ ] `/usr/local/sbin/biotrop-backup.sh manual` executado com sucesso
- [ ] `/etc/cron.d/biotrop` instalado, com `BACKUP_BLOB_URL` preenchido
- [ ] arquivo `.dump` aparecendo no container do Storage Account
- [ ] `globals-*.sql` gerado e com permissao 600
- [ ] `app.env.*.gpg` gerado, senha do gpg no cofre corporativo
- [ ] **`/usr/local/sbin/biotrop-restore-test.sh` executado com sucesso** - este item nao
      pode ser adiado; sem ele nao existe backup, existe arquivo
- [ ] `SELECT * FROM core.rotina_execucao WHERE rotina IN ('backup','restore_teste');`
      mostrando as duas com `sucesso = true`
- [ ] restauracao completa da secao 7.2 ensaiada **uma vez**, com cronometro, e o tempo
      real anotado aqui: ______ min
- [ ] este arquivo (`DEPLOY-VM-AZURE-E-BACKUP.md`) no repositorio e impresso/salvo fora
      da VM - runbook que so existe na maquina quebrada nao serve

## G. No dia seguinte a publicacao

- [ ] `SELECT * FROM core.rotina_execucao WHERE rotina='backup' ORDER BY inicio DESC LIMIT 1;`
      mostra o backup automatico das 02:10 com `sucesso = true`
- [ ] `SELECT * FROM app.vw_saude_operacional;` sem numero estranho
- [ ] `SELECT em, email, motivo FROM core.login_evento WHERE NOT sucesso ORDER BY em DESC;`
      - toda recusa tem explicacao
- [ ] `sudo journalctl -u biotrop-app --since yesterday -p err` sem erro repetido
- [ ] `df -h /dados` com folga (o dump diario acumula 14 dias)

---

# 11. Resumo operacional

| Preciso... | Comando |
|---|---|
| publicar mudanca | `sudo /usr/local/sbin/biotrop-deploy.sh deploy` |
| desfazer a ultima publicacao | `sudo /usr/local/sbin/biotrop-deploy.sh rollback` |
| ver o estado | `sudo /usr/local/sbin/biotrop-deploy.sh status` |
| backup agora | `sudo /usr/local/sbin/biotrop-backup.sh manual` |
| provar que o backup presta | `sudo /usr/local/sbin/biotrop-restore-test.sh` |
| reiniciar so a aplicacao | `sudo systemctl restart biotrop-app` |
| recarregar o proxy sem cair | `sudo nginx -t && sudo systemctl reload nginx` |
| entrar no banco | `sudo -u postgres psql -d biotrop` |
| destravar o acesso perdido | secao 8.3 |
| restaurar producao | secao 7.2 |
| montar tudo de novo | secao 7.3 |

Duas coisas que nao valem atalho: **conferir o `SELECT core.pode_autenticar(...)` antes do
COMMIT** na secao 8.3, e **rodar o teste de restauracao** do item F do checklist.

