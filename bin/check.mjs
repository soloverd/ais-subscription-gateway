import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const text=await readFile(path.join(root,'service/.env'),'utf8');
const config=Object.fromEntries(text.split(/\r?\n/).filter(x=>x&&!x.startsWith('#')).map(x=>{const p=x.indexOf('='); return [x.slice(0,p),x.slice(p+1)];}));
const expected=['charlie.main@example.com','alpha.sub@example.com','bravo.sub@example.com','delta.sub@example.com'];
if(config.ROUTING_STRATEGY!=='fill-first'||config.ACCOUNT_ORDER!==expected.join(',')||config.UPSTREAM_CHANNELS!=='playground'||config.LISTEN_ADDR!=='127.0.0.1:2048'||config.REQUEST_BODY_LOG!=='false') throw new Error('Unexpected routing/security configuration');
console.log('Configuration OK: local-only, primary-first, Playground channel, body logging off.');
if(process.argv.includes('--config-only')) process.exit(0);
const base='http://'+config.LISTEN_ADDR;
try {
  const res=await fetch(base+'/v1/models',{headers:{Authorization:'Bearer '+config.PROXY_API_KEY},signal:AbortSignal.timeout(10000)});
  if(!res.ok) throw new Error('Model endpoint HTTP '+res.status);
  const result=await res.json();
  const models=(result.data||[]).map(x=>x.id);
  console.log('Available Argon model IDs:',models.filter(x=>/argon/i.test(x)));
  console.log('Catalog access is NOT evidence of generation entitlement.');
} catch(err) { console.error('Runtime verification blocked:',err.message); process.exitCode=1; }
