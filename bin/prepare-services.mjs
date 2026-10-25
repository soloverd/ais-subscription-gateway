import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

// 설치는 별도 관리자 승인 단계에서 한다. 이 명령은 비밀값 없는 plist만 준비한다.
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const service = path.join(root, 'service');
const user = os.userInfo();
if (process.platform !== 'darwin' || user.uid === 0) throw new Error('Mac의 일반 사용자로 실행하세요.');
const envText = fs.readFileSync(path.join(service, '.env'), 'utf8');
const config = Object.fromEntries(envText.split(/\r?\n/).filter(line => line && !line.startsWith('#')).map(line => {
  const separator = line.indexOf('=');
  return [line.slice(0, separator), line.slice(separator + 1)];
}));
if (config.AUTO_START !== 'true' || config.ADMIN_AUTH_ENABLED !== 'true' || !config.ADMIN_USERNAME || !config.ADMIN_PASSWORD || !config.PROXY_API_KEY) {
  throw new Error('먼저 자동 시작과 관리자 인증을 설정하세요. 비밀값은 출력하지 않습니다.');
}
if (config.WAA_BACKEND !== 'go') throw new Error('로그인 전 호출을 위해 WAA_BACKEND=go가 필요합니다.');
const node = process.execPath;
const tailscalePrefix = execFileSync('/opt/homebrew/bin/brew', ['--prefix', 'tailscale'], { encoding: 'utf8' }).trim();
const tailscaled = path.join(tailscalePrefix, 'bin/tailscaled');
const addon = path.join(root, 'integrations/antigravity-add-model');
for (const file of [path.join(service, 'aistudio2api'), node, tailscaled, path.join(addon, 'dist/standaloneService.js')]) {
  fs.accessSync(file, fs.constants.R_OK);
}
const stage = path.join(service, 'launchd');
const logs = path.join(service, 'runtime');
fs.mkdirSync(stage, { recursive: true, mode: 0o700 });
fs.mkdirSync(logs, { recursive: true, mode: 0o700 });
fs.chmodSync(logs, 0o700);
fs.mkdirSync(path.join(service, 'tailscale'), { recursive: true, mode: 0o700 });
const jobs = [
  ['gateway', ['/bin/bash', path.join(root, 'bin/start.sh')]],
  ['models', [node, path.join(addon, 'scripts/desktop-service.mjs'), 'run', '--data-dir', path.join(service, 'antigravity-ide')]],
  ['tailscale', [tailscaled, '--tun=userspace-networking', '--statedir=' + path.join(service, 'tailscale'), '--state=' + path.join(service, 'tailscale/tailscaled.state'), '--socket=' + path.join(service, 'tailscale/tailscaled.sock'), '--port=0']],
  ['browser-host', [path.join(service, 'aistudio2api'), 'browser-host'], true],
];
for (const [name, argv, gui] of jobs) {
  const label = 'io.ais-subscription-gateway.' + name;
  const plist = {
    Label: label,
    ProgramArguments: argv,
    ...(gui ? { LimitLoadToSessionType: 'Aqua' } : { UserName: user.username }),
    WorkingDirectory: service,
    EnvironmentVariables: {
      HOME: user.homedir,
      PATH: path.dirname(node) + ':/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin',
      CAMOUFOX_HOST_SOCKET: path.join(logs, 'browser-host.sock'),
    },
    RunAtLoad: true,
    KeepAlive: true,
    ThrottleInterval: 10,
    ExitTimeOut: 30,
    Umask: 0o077,
    StandardOutPath: path.join(logs, name + '-service.log'),
    StandardErrorPath: path.join(logs, name + '-service.log'),
  };
  const filename = path.join(stage, label + '.plist');
  execFileSync('/usr/bin/plutil', ['-convert', 'xml1', '-o', filename, '-'], { input: JSON.stringify(plist) });
  fs.chmodSync(filename, 0o600);
}
console.log('시스템 서비스 3개·사용자 로그인 도우미 설정 준비 완료: ' + stage);
console.log('아직 서비스 설치·실행 또는 Tailscale 기존 설정을 변경하지 않았습니다.');
