import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const parse=text=>Object.fromEntries(text.split(/\r?\n/).filter(x=>x&&!x.startsWith('#')).map(x=>{const p=x.indexOf('='); return [x.slice(0,p),x.slice(p+1)];}));
const text=await readFile(path.join(root,'service/.env'),'utf8');
// v0.3.0부터 .env에는 기본값과 다른 항목만 저장되므로, 빠진 항목은 원본 기본값으로 본다.
const defaults={UPSTREAM_CHANNELS:'playground',LISTEN_ADDR:'127.0.0.1:2048',REQUEST_BODY_LOG:'false'};
const config={...defaults,...parse(text)};
// 계정 이메일은 개인 값이라 저장소에 두지 않는다. Git 에서 빠지는 로컬 전용 파일 service/ops-local.env 의 EXPECTED_ACCOUNT_ORDER 와 비교한다.
const local=parse(await readFile(path.join(root,'service/ops-local.env'),'utf8').catch(()=>''));
if(!local.EXPECTED_ACCOUNT_ORDER) throw new Error('service/ops-local.env 에 EXPECTED_ACCOUNT_ORDER 가 없습니다');
if(config.ROUTING_STRATEGY!=='fill-first'||config.ACCOUNT_ORDER!==local.EXPECTED_ACCOUNT_ORDER||config.UPSTREAM_CHANNELS!=='playground'||config.LISTEN_ADDR!=='127.0.0.1:2048'||config.REQUEST_BODY_LOG!=='false') throw new Error('Unexpected routing/security configuration');
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
