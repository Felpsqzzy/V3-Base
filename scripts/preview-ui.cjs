const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const assets = new Set(['/index.html','/biotrop-postgres-auth.js','/biotrop-data-sync.js','/login-hero.css','/src/ui/shell.js','/src/ui/theme.css']);
const mime = {'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.css':'text/css; charset=utf-8'};
http.createServer((req,res)=>{
  const requested = new URL(req.url, 'http://localhost').pathname;
  const route = requested === '/' ? '/index.html' : requested;
  res.setHeader('Cache-Control','no-store');
  if(route.startsWith('/api/')) {
    res.writeHead(503,{'Content-Type':'application/json'});
    return res.end(JSON.stringify({ok:false,erro:'Prévia local de interface. Backend não conectado.'}));
  }
  if(!assets.has(route)){res.writeHead(404);return res.end('Not found');}
  const file = path.join(root, route);
  res.writeHead(200,{'Content-Type':mime[path.extname(file)] || 'application/octet-stream'});
  fs.createReadStream(file).pipe(res);
}).listen(4318,'127.0.0.1',()=>console.log('Local: http://127.0.0.1:4318'));
