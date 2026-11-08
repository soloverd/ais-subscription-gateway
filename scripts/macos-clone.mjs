#!/usr/bin/env node
// macOS 전용: 원본 Antigravity.app 은 읽기만 하고, 별도 복제본에 패치 + 로컬(ad-hoc) 재서명을 적용한다.
// ad-hoc 서명은 Google 의 Developer ID 서명/공증을 대체하지 않는다. 복제본은 "이 Mac 에서 만든 무결성 봉인"일 뿐이다.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath, pathToFileURL } from 'node:url';
import * as asar from '@electron/asar';
import { deploy, hashDirectory, walk } from './deploy.mjs';

const PROJECT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DEFAULT_SOURCE = '/Applications/Antigravity.app';
const DEFAULT_TARGET = path.join(os.homedir(), 'Applications', 'Antigravity Gateway.app');
const CLONE_ID_SUFFIX = '.gateway-local';
// Electron fuse 와이어 포맷: 센티널 + 버전(1바이트) + 개수(1바이트) + 각 fuse 의 '0'/'1'
const FUSE_SENTINEL = Buffer.from('dL7pKGdnNz796PbbjQWNKmHXBZaB9tsX');
const FUSE_NAMES = [
  'RunAsNode',
  'EnableCookieEncryption',
  'EnableNodeOptionsEnvironmentVariable',
  'EnableNodeCliInspectArguments',
  'EnableEmbeddedAsarIntegrityValidation',
  'OnlyLoadAppFromAsar',
  'LoadBrowserProcessSpecificV8Snapshot',
  'GrantFileProtocolExtraPrivileges',
  'WasmTrapHandlers',
];
const MACHO_MAGIC = new Set(['feedface', 'feedfacf', 'cefaedfe', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca']);
const exec = promisify(execFile);

function fail(code, message) {
  const error = new Error(code + ': ' + message);
  error.code = code;
  throw error;
}
function exists(target) {
  try {
    fs.lstatSync(target);
    return true;
  } catch {
    return false;
  }
}
function sha256(text) {
  return createHash('sha256').update(text).digest('hex');
}
async function tool(command, args) {
  try {
    const { stdout, stderr } = await exec(command, args, { maxBuffer: 64 * 1024 * 1024 });
    return { ok: true, stdout, stderr };
  } catch (error) {
    return { ok: false, stdout: error.stdout ?? '', stderr: error.stderr ?? error.message };
  }
}
async function readPlist(file) {
  const result = await tool('plutil', ['-convert', 'json', '-o', '-', file]);
  if (!result.ok) fail('PLIST_UNREADABLE', file + ': ' + result.stderr.trim());
  return JSON.parse(result.stdout);
}
function sortKeys(value) {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === 'object')
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sortKeys(value[key])]));
  return value;
}
function requireDarwin() {
  if (process.platform !== 'darwin') fail('UNSUPPORTED_PLATFORM', 'This command only supports macOS.');
}

/** 원본 .app 경로를 정규화하고 최소 구조를 확인한다 (쓰기 없음). */
function resolveApp(input) {
  const app = fs.realpathSync.native(path.resolve(input));
  if (!app.endsWith('.app') || !exists(path.join(app, 'Contents', 'Info.plist')))
    fail('APP_NOT_FOUND', 'Expected a macOS .app bundle with Contents/Info.plist: ' + input);
  return app;
}
/** 복제본 경로 검증: 원본과 같거나, 원본 안/밖으로 겹치거나, 이미 존재하면 거부한다. */
function resolveTarget(source, input) {
  const resolved = path.resolve(input);
  if (!resolved.endsWith('.app')) fail('UNSAFE_TARGET', 'The clone path must end with .app: ' + input);
  if (!exists(path.dirname(resolved))) fail('UNSAFE_TARGET', 'The clone parent directory does not exist: ' + path.dirname(resolved));
  const target = path.join(fs.realpathSync.native(path.dirname(resolved)), path.basename(resolved));
  const inside = (outer, inner) => inner === outer || inner.startsWith(outer + path.sep);
  if (inside(source, target) || inside(target, source))
    fail('UNSAFE_TARGET', 'The clone must be a separate path; the original app is never modified: ' + target);
  return target;
}
/** 이미 존재하는 복제본 경로를 정규화한다(부모만 realpath). */
function locate(input) {
  const resolved = path.resolve(input);
  return path.join(fs.realpathSync.native(path.dirname(resolved)), path.basename(resolved));
}
function manifestPath(target) {
  return target + '.clone.json';
}
function readManifest(target) {
  const file = manifestPath(target);
  if (!exists(file) || !exists(target)) fail('NOT_A_CLONE', 'No clone manifest for ' + target + '. Only clones made by prepare are handled.');
  const manifest = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (manifest.schema !== 1 || manifest.target !== target) fail('NOT_A_CLONE', 'The clone manifest does not belong to ' + target);
  return manifest;
}

async function verifySignature(app) {
  const result = await tool('codesign', ['--verify', '--deep', '--strict', '--verbose=2', app]);
  return { ok: result.ok, detail: result.stderr.trim() };
}
async function signatureDetail(app) {
  const detail = (await tool('codesign', ['-dvv', app])).stderr;
  const field = (name) => detail.match(new RegExp('^' + name + '=(.*)$', 'm'))?.[1] ?? null;
  return {
    adhoc: /^Signature=adhoc$/m.test(detail) || /flags=0x[0-9a-f]+\([^)]*adhoc/.test(detail),
    teamIdentifier: field('TeamIdentifier'),
    authorities: [...detail.matchAll(/^Authority=(.*)$/gm)].map((match) => match[1]),
    notarizationTicket: field('Notarization Ticket'),
  };
}
/** 항목의 entitlement 를 XML 파일(서명 입력)과 정규화 JSON(비교용)으로 읽는다. 없으면 null. */
async function entitlementsOf(item, scratch) {
  const result = await tool('codesign', ['-d', '--entitlements', '-', '--xml', item]);
  const xml = result.stdout.trim();
  if (!result.ok || !xml.startsWith('<')) return { file: null, canonical: null };
  const file = path.join(scratch, sha256(item) + '.plist');
  fs.writeFileSync(file, xml);
  return { file, canonical: JSON.stringify(sortKeys(await readPlist(file))) };
}
function isMachO(file) {
  const fd = fs.openSync(file, 'r');
  try {
    const head = Buffer.alloc(4);
    return fs.readSync(fd, head, 0, 4, 0) === 4 && MACHO_MAGIC.has(head.toString('hex'));
  } finally {
    fs.closeSync(fd);
  }
}
/** 서명 대상: 중첩 번들(.app/.framework)과 독립 Mach-O. 번들의 주 실행 파일은 번들 서명에 포함되므로 제외. 깊은 순서(안쪽 먼저). */
export function codeItems(app) {
  const items = [];
  const mains = new Set();
  const entries = walk(app);
  for (const { name, stat } of entries) {
    if (!stat.isDirectory()) continue;
    if (name.endsWith('.framework')) {
      items.push(name);
      const versions = path.join(app, name, 'Versions');
      if (exists(versions))
        for (const version of fs.readdirSync(versions))
          mains.add(name + '/Versions/' + version + '/' + path.posix.basename(name, '.framework'));
    } else if (name.endsWith('.app')) items.push(name);
  }
  for (const { name, stat } of entries) {
    if (!stat.isFile() || mains.has(name) || /(^|\/)Contents\/MacOS\/[^/]+$/.test(name)) continue;
    if (isMachO(path.join(app, name))) items.push(name);
  }
  items.sort((a, b) => b.split('/').length - a.split('/').length);
  return [...items, ''];
}
/** 안쪽부터 ad-hoc 재서명한다. entitlement 는 원본의 같은 항목에서 읽어 그대로 부여한다. 반환값: 항목별 정규화 entitlement. */
export async function signBundle(app, source, scratch) {
  const entitlements = {};
  for (const item of codeItems(app)) {
    const original = await entitlementsOf(path.join(source, item), scratch);
    entitlements[item] = original.canonical;
    // runtime(hardened) 옵션은 의도적으로 제외: ad-hoc 서명은 Team ID 가 없어 라이브러리 검증과 충돌한다.
    const args = ['--force', '--sign', '-', '--timestamp=none'];
    if (original.file) args.push('--entitlements', original.file);
    const result = await tool('codesign', [...args, path.join(app, item)]);
    if (!result.ok) fail('SIGN_FAILED', (item || '.') + ': ' + result.stderr.trim());
  }
  return entitlements;
}

async function assertEntitlements(app, expected, scratch) {
  for (const [item, canonical] of Object.entries(expected)) {
    if ((await entitlementsOf(path.join(app, item), scratch)).canonical !== canonical)
      fail('ENTITLEMENT_MISMATCH', 'Entitlements differ from the original for ' + (item || '.'));
  }
}

/** 복제본의 번들 ID와 패치된 asar 무결성 정보를 원본과 분리한다. */
async function retargetClone(app, bundleId) {
  const infoFile = path.join(app, 'Contents', 'Info.plist');
  const info = await readPlist(infoFile);
  const resources = path.join(app, 'Contents', 'Resources');
  const set = await tool('plutil', ['-replace', 'CFBundleIdentifier', '-string', bundleId, infoFile]);
  if (!set.ok) fail('PLIST_WRITE_FAILED', set.stderr.trim());
  // 패치된 app.asar 의 헤더 해시로 ElectronAsarIntegrity 를 갱신한다(해당 fuse 가 꺼져 있어도 값은 일치시킨다).
  const archive = path.join(resources, 'app.asar');
  if (info.ElectronAsarIntegrity?.['Resources/app.asar']) {
    asar.uncache(archive);
    const hash = sha256(asar.getRawHeader(archive).headerString);
    const integrity = {
      ...info.ElectronAsarIntegrity,
      'Resources/app.asar': { ...info.ElectronAsarIntegrity['Resources/app.asar'], hash },
    };
    const write = await tool('plutil', ['-replace', 'ElectronAsarIntegrity', '-json', JSON.stringify(integrity), infoFile]);
    if (!write.ok) fail('PLIST_WRITE_FAILED', write.stderr.trim());
  }
  const updateConfig = path.join(resources, 'app-update.yml');
  if (exists(updateConfig)) {
    const updateText = fs.readFileSync(updateConfig, 'utf8');
    if (!/^updaterCacheDirName:.*$/m.test(updateText))
      fail('UNSUPPORTED_UPDATE_LAYOUT', '복제본의 업데이트 캐시를 원본과 분리할 수 없습니다.');
    fs.writeFileSync(updateConfig, updateText.replace(/^updaterCacheDirName:.*$/m, 'updaterCacheDirName: ' + bundleId));
  }
}

/** 원본은 읽기 전용으로만 접근한다. 모든 쓰기는 target 옆 staging 안에서 이뤄지고, 성공 시에만 rename 한다. */
export async function prepareMacClone(options = {}, operations = {}) {
  requireDarwin();
  const sign = operations.sign || signBundle;
  const source = resolveApp(options.source ?? DEFAULT_SOURCE);
  const target = resolveTarget(source, options.target ?? DEFAULT_TARGET);
  if (exists(target) || exists(manifestPath(target))) fail('UNSAFE_TARGET', 'The clone path already exists; choose a new path: ' + target);
  const dist = path.resolve(options.dist || path.join(PROJECT, 'dist'));
  const profilePath = path.resolve(options.profile || path.join(os.homedir(), 'Library/Application Support/Antigravity Gateway'));
  const profile = exists(profilePath) ? fs.realpathSync.native(profilePath) : locate(profilePath);
  if ([source, target].some((bundle) => profile === bundle || profile.startsWith(bundle + path.sep)))
    fail('UNSAFE_PROFILE', '앱 내부를 사용자 데이터 폴더로 사용할 수 없습니다.');
  const sourceResources = path.join(source, 'Contents', 'Resources');
  const sourceSignature = await verifySignature(source);
  if (!sourceSignature.ok)
    fail('SOURCE_SIGNATURE_INVALID', 'The original app does not pass codesign verification; reinstall it first. ' + sourceSignature.detail);
  // 쓰기 없이 패치 가능 여부(지원 레이아웃, 빌드 산출물)를 먼저 확인한다.
  await deploy({ resources: sourceResources, dist, check: true, signedBundleClone: true, cloneUserDataDir: profile });
  const sourceInfo = await readPlist(path.join(source, 'Contents', 'Info.plist'));
  const signer = await signatureDetail(source);
  const sourceHash = hashDirectory(source);
  const bundleId = sourceInfo.CFBundleIdentifier + CLONE_ID_SUFFIX;
  const staging = fs.mkdtempSync(path.join(path.dirname(target), '.' + path.basename(target) + '.staging-'));
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'antigravity-clone-'));
  try {
    const clone = path.join(staging, path.basename(target));
    fs.cpSync(source, clone, {
      recursive: true,
      verbatimSymlinks: true,
      preserveTimestamps: true,
      mode: fs.constants.COPYFILE_FICLONE,
      force: false,
      errorOnExist: true,
    });
    // cpSync 는 현재 umask 를 권한에 적용한다(예: umask 077 이면 실행 파일 755 → 700). 원본 권한을 그대로 되돌린다.
    for (const { name, stat } of walk(source)) {
      if (!stat.isSymbolicLink()) fs.chmodSync(path.join(clone, name), stat.mode & 0o777);
    }
    // 서명 전 복제본 무결성: 원본과 파일 내용/모드/링크가 완전히 같아야 한다.
    if (hashDirectory(clone) !== sourceHash) fail('CLONE_MISMATCH', 'The unsigned clone differs from the original; nothing was installed.');
    const resources = path.join(clone, 'Contents', 'Resources');
    await deploy({ resources, dist, signedBundleClone: true, cloneUserDataDir: profile });
    // 원본이 곧 백업이므로 복제본 안의 백업/상태는 서명 봉인에 넣지 않는다.
    fs.rmSync(path.join(resources, '.antigravity-model-patch'), { recursive: true, force: true });
    await retargetClone(clone, bundleId);
    const entitlements = await sign(clone, source, scratch);
    const signature = await verifySignature(clone);
    if (!signature.ok) fail('CLONE_SIGNATURE_INVALID', signature.detail);
    await assertEntitlements(clone, entitlements, scratch);
    if (hashDirectory(source) !== sourceHash) fail('SOURCE_CHANGED', 'The original app changed while the clone was prepared; nothing was installed.');
    fs.renameSync(clone, target);
    try {
      fs.writeFileSync(
        manifestPath(target),
        JSON.stringify(
          {
            schema: 1,
            createdAt: new Date().toISOString(),
            source,
            sourceVersion: sourceInfo.CFBundleShortVersionString,
            sourceHash,
            sourceSigner: signer.authorities[0] ?? null,
            sourceTeamIdentifier: signer.teamIdentifier,
            target,
            bundleId,
            profile,
            signature: 'adhoc',
            entitlements,
          },
          null,
          2,
        ) + '\n',
      );
    } catch (error) {
      fs.rmSync(target, { recursive: true, force: true });
      throw error;
    }
    return { action: 'prepare', source, target, version: sourceInfo.CFBundleShortVersionString, bundleId };
  } finally {
    fs.rmSync(staging, { recursive: true, force: true });
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}

/** 복제본의 서명 봉인·ad-hoc 여부·entitlement 보존을 확인하고, 원본이 바뀌었는지(=수동 재준비 필요)를 알린다. */
export async function verifyMacClone(options = {}) {
  requireDarwin();
  const target = locate(options.target ?? DEFAULT_TARGET);
  const manifest = readManifest(target);
  const signature = await verifySignature(target);
  if (!signature.ok) fail('CLONE_SIGNATURE_INVALID', 'The clone was modified after signing or is damaged. ' + signature.detail);
  const detail = await signatureDetail(target);
  if (!detail.adhoc) fail('CLONE_NOT_ADHOC', 'The clone is not locally ad-hoc signed.');
  const info = await readPlist(path.join(target, 'Contents', 'Info.plist'));
  if (info.CFBundleIdentifier !== manifest.bundleId) fail('CLONE_MISMATCH', 'The clone bundle identifier changed.');
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'antigravity-clone-'));
  try {
    await assertEntitlements(target, manifest.entitlements, scratch);
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
  const sourceChanged = !exists(manifest.source) || hashDirectory(manifest.source) !== manifest.sourceHash;
  return { action: 'verify', target, signature: 'adhoc', entitlementsPreserved: true, sourceChanged, sourceVersion: manifest.sourceVersion };
}

/** 복원 = 복제본과 매니페스트만 삭제. 원본 경로는 읽지도 쓰지도 않는다(원본이 곧 정상 상태). */
export function restoreMacClone(options = {}) {
  requireDarwin();
  const target = locate(options.target ?? DEFAULT_TARGET);
  const manifest = readManifest(target);
  if (target === manifest.source || manifest.source.startsWith(target + path.sep) || target.startsWith(manifest.source + path.sep))
    fail('UNSAFE_TARGET', 'Refusing to remove a path that overlaps the original app.');
  if (fs.lstatSync(target).isSymbolicLink()) fail('UNSAFE_TARGET', 'Refusing to remove a symlink: ' + target);
  fs.rmSync(target, { recursive: true, force: true });
  fs.rmSync(manifestPath(target), { force: true });
  return { action: 'restore', target, source: manifest.source };
}

/** 읽기 전용 진단: 서명, 공증, entitlement 요약, Electron fuse, asar 무결성, 업데이트 설정, quarantine. */
export async function inspectMacApp(input = DEFAULT_SOURCE) {
  requireDarwin();
  const app = resolveApp(input);
  const info = await readPlist(path.join(app, 'Contents', 'Info.plist'));
  const archive = path.join(app, 'Contents', 'Resources', 'app.asar');
  const declared = info.ElectronAsarIntegrity?.['Resources/app.asar']?.hash ?? null;
  const framework = path.join(app, 'Contents', 'Frameworks', 'Electron Framework.framework', 'Electron Framework');
  let fuses = null;
  if (exists(framework)) {
    const binary = fs.readFileSync(framework);
    const at = binary.indexOf(FUSE_SENTINEL);
    if (at >= 0) {
      const bytes = binary.subarray(at + FUSE_SENTINEL.length + 2, at + FUSE_SENTINEL.length + 2 + binary[at + FUSE_SENTINEL.length + 1]);
      fuses = Object.fromEntries([...bytes].map((byte, index) => [FUSE_NAMES[index] ?? 'fuse' + index, byte === 0x31]));
    }
  }
  const updateConfig = path.join(app, 'Contents', 'Resources', 'app-update.yml');
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'antigravity-clone-'));
  try {
    const entitlements = {};
    for (const item of codeItems(app)) {
      const { canonical } = await entitlementsOf(path.join(app, item), scratch);
      if (canonical) entitlements[item || '.'] = JSON.parse(canonical);
    }
    return {
      app,
      version: info.CFBundleShortVersionString,
      bundleId: info.CFBundleIdentifier,
      signatureValid: (await verifySignature(app)).ok,
      ...(await signatureDetail(app)),
      gatekeeper: ((await tool('spctl', ['-a', '-vv', app])).stderr.trim().split('\n').slice(0, 2).join(' | ')),
      quarantined: (await tool('xattr', ['-p', 'com.apple.quarantine', app])).ok,
      fuses,
      asarIntegrity: { declared, actual: exists(archive) ? sha256(asar.getRawHeader(archive).headerString) : null },
      updateUrl: exists(updateConfig) ? fs.readFileSync(updateConfig, 'utf8').match(/^url:\s*(.*)$/m)?.[1] ?? null : null,
      entitlements,
    };
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}

const USAGE = [
  'Usage: node scripts/macos-clone.mjs <inspect|prepare|verify|restore> [options]',
  '  inspect [--source APP]                     읽기 전용 진단 (원본 미변경)',
  '  prepare [--source APP] [--target APP]      복제본 생성 + 패치 + ad-hoc 재서명 (새 경로만 허용)',
  '  verify  [--target APP]                     서명 봉인/entitlement/원본 변경 여부 확인',
  '  restore [--target APP]                     복제본과 매니페스트만 삭제 (원본은 손대지 않음)',
  '  common: --dist DIR (prepare), --profile DIR (prepare), --json',
].join('\n');
export function parseCloneArgs(argv) {
  const [command, ...rest] = argv;
  if (!['inspect', 'prepare', 'verify', 'restore'].includes(command)) fail('USAGE', USAGE);
  const options = { command };
  for (let index = 0; index < rest.length; index++) {
    const arg = rest[index];
    if (arg === '--json') options.json = true;
    else if (['--source', '--target', '--dist', '--profile'].includes(arg)) {
      if (!rest[index + 1] || rest[index + 1].startsWith('--')) fail('USAGE', arg + ' requires a path.');
      options[arg.slice(2)] = rest[++index];
    } else fail('USAGE', 'Unknown argument: ' + arg);
  }
  return options;
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  try {
    const options = parseCloneArgs(process.argv.slice(2));
    const result =
      options.command === 'inspect'
        ? await inspectMacApp(options.source)
        : options.command === 'prepare'
          ? await prepareMacClone(options)
          : options.command === 'verify'
            ? await verifyMacClone(options)
            : restoreMacClone(options);
    console.log(JSON.stringify(result, null, options.json ? 0 : 2));
    if (options.command === 'prepare')
      console.log('복제본은 로컬 ad-hoc 서명입니다(Google 서명/공증 아님). 직접 실행해 동작을 확인한 뒤에만 사용하세요: ' + result.target);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
