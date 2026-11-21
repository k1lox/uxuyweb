import {createServer} from 'node:http';
import {request as httpRequest} from 'node:http';
import {request as httpsRequest} from 'node:https';
import {readFile,stat} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {resolve,extname,sep} from 'node:path';
const root=resolve(fileURLToPath(new URL('../frontend/web/build/web/',import.meta.url)));
const target=new URL(process.env.UXUY_PROXY_TARGET || 'http://127.0.0.1:3291/');
if(!['http:','https:'].includes(target.protocol)) throw Error('Invalid backend protocol');
const mime={'.css':'text/css; charset=utf-8','.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.json':'application/json','.wasm':'application/wasm','.png':'image/png','.svg':'image/svg+xml','.otf':'font/otf','.ttf':'font/ttf','.woff2':'font/woff2'};
const server=createServer(async(req,res)=>{
 const pathname=new URL(req.url,'http://localhost').pathname;
 if(pathname.startsWith('/api/')){
  const dest=new URL(req.url,target);dest.host=target.host;dest.protocol=target.protocol;
  const headers={...req.headers,host:target.host,'x-real-ip':req.socket.remoteAddress};delete headers.origin;delete headers.connection;delete headers.cookie;delete headers.authorization;
  const upstream=(dest.protocol==='https:'?httpsRequest:httpRequest)(dest,{method:req.method,headers,timeout:180000},r=>{
   const h={...r.headers,'cache-control':'no-store'};delete h['set-cookie'];delete h['transfer-encoding'];
   res.writeHead(r.statusCode,h);r.pipe(res);
  });
  upstream.on('timeout',()=>upstream.destroy(new Error('upstream timeout')));
  upstream.on('error',()=>{if(!res.headersSent){res.writeHead(502,{'content-type':'application/json'});res.end(JSON.stringify({ok:false,code:'BACKEND_UNAVAILABLE',message:'后端暂不可用，请稍后重试'}));}else res.destroy();});
  req.on('aborted',()=>upstream.destroy());req.pipe(upstream);return;
 }
 try{
  let path=resolve(root, '.'+decodeURIComponent(pathname));
  if(path!==root&&!path.startsWith(root+sep)){res.writeHead(403);res.end();return;}
  if((await stat(path).catch(()=>null))?.isDirectory()){
   if(!pathname.endsWith('/')){
    const url=new URL(req.url,'http://localhost');
    res.writeHead(308,{location:url.pathname.replace(/^\/+/, '/')+'/'+url.search});res.end();return;
   }
   path=resolve(path,'index.html');
  }
  const data=await readFile(path);
  res.writeHead(200,{'content-type':mime[extname(path)]||'application/octet-stream','cache-control':'no-cache','x-content-type-options':'nosniff'});res.end(data);
 }catch{res.writeHead(404);res.end('Not found. Run npm run build first.');}
});
server.listen(Number(process.env.PORT||3190),'127.0.0.1',()=>console.log(`UXUY Web: http://127.0.0.1:${server.address().port}`));
