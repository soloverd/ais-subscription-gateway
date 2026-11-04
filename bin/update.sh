#!/bin/bash
# 두 원본(게이트웨이·Antigravity 연결 프로그램)의 새 버전을 내 수정과 합쳐 운영에 반영한다.
#
#   bin/update.sh check                  새 버전이 있는지만 확인 (아무것도 바꾸지 않음, 새 버전이 있으면 종료 코드 10)
#   bin/update.sh gateway [단계]         게이트웨이 업데이트
#   bin/update.sh antigravity [단계]     연결 프로그램 업데이트
#
# 단계를 생략하면 처음부터 끝까지 순서대로 한다.
#   게이트웨이:     merge(합치기) → test(시험) → build(빌드) → deploy(백업·교체) → verify(실제 요청 확인) → save(비공개 저장소 보관)
#   연결 프로그램:  merge → build(빌드·시험) → deploy(재시작) → verify → save
# 충돌·시험 실패·확인 실패가 나면 그 자리에서 멈춘다. 충돌을 정리해 커밋한 뒤 같은 명령을 다시 실행하면 이어서 진행한다.
# 게이트웨이는 원본의 최신 정식 릴리스를, 연결 프로그램은 원본 main 을 따라간다(정식 릴리스를 내지 않음).
# .env·API 키·쿠키 값은 화면에 출력하지 않는다.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GW="$ROOT/upstream"
AG="$ROOT/integrations/antigravity-add-model"
SV="$ROOT/service"
GOBIN="$ROOT/toolchain/go/bin"
GW_REPO="Mag1cFall/AIStudio2API"
GW_BIN="$GW/dist/aistudio2api"
APP_CLONE="$HOME/Applications/Antigravity Gateway.app"
HTTPS_URL="https://ais-subscription-gateway.your-tailnet.ts.net"
PRIVATE_REMOTE="private"
export PATH="$GOBIN:$PATH"

say() { printf '\n▶ %s\n' "$*"; }
die() { printf '\n✖ %s\n' "$*" >&2; exit "${2:-1}"; }

require_clean() { # $1 저장소, $2 브랜치
  [ "$(git -C "$1" branch --show-current)" = "$2" ] || die "$1 이 $2 브랜치가 아닙니다"
  ! git -C "$1" rev-parse -q --verify MERGE_HEAD >/dev/null || die "$1 에서 합치기가 진행 중입니다. 충돌을 정리해 커밋한 뒤 다시 실행하세요"
  [ -z "$(git -C "$1" status --porcelain)" ] || die "$1 에 커밋하지 않은 변경이 있습니다. 정리한 뒤 다시 실행하세요"
}

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time "${2:-5}" "$1" || true; }

wait_health() { # $1 URL, $2 최대 초
  local i
  for i in $(seq 1 "$2"); do
    [ "$(http_code "$1" 2)" = 200 ] && return 0
    sleep 1
  done
  return 1
}

service_pid() { launchctl print "$1" 2>/dev/null | awk '/^\tpid =/{print $3}'; }

# 실행 중인 서비스가 기대한 명령인지 확인한 뒤 종료 신호를 보낸다. launchd(KeepAlive)가 새 실행 파일로 다시 띄운다.
restart_service() { # $1 launchd 대상, $2 명령에 포함돼야 하는 문자열, $3 health URL
  local old new i cmd
  old="$(service_pid "$1")"
  [ -n "$old" ] || die "$1 이 실행 중이 아닙니다"
  cmd="$(ps -o user=,command= -p "$old")"
  case "$cmd" in "$(id -un) "*"$2"*) ;; *) die "$1 프로세스가 예상과 다릅니다: $cmd" ;; esac
  kill -TERM "$old"
  for i in $(seq 1 90); do
    new="$(service_pid "$1")"
    if [ -n "$new" ] && [ "$new" != "$old" ] && [ "$(http_code "$3" 2)" = 200 ]; then
      echo "  $1 재시작: PID $old → $new"
      return 0
    fi
    sleep 1
  done
  return 1
}

# 게이트웨이가 따라갈 대상: 원본의 최신 정식 릴리스 태그(대시보드 버전 탭과 같은 기준)
gateway_target() {
  curl -fsSL --max-time 20 "https://api.github.com/repos/$GW_REPO/releases/latest" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])'
}

fetch_gateway_target() {
  local target
  target="$(gateway_target)" || die "GitHub 에서 게이트웨이 최신 릴리스를 읽지 못했습니다"
  git -C "$GW" fetch -q origin "refs/tags/$target:refs/tags/$target"
  echo "$target"
}

deployed_gateway_revision() {
  "$GOBIN/go" version -m "$SV/aistudio2api" 2>/dev/null | awk '$2 ~ /^vcs.revision=/{sub("vcs.revision=","",$2); print $2}'
}

# 오늘 날짜 태그를 붙이고 비공개 저장소에 브랜치와 그 태그를 올린다. 이미 태그가 붙은 커밋이면 새 태그는 만들지 않는다.
save_to_private() { # $1 저장소, $2 브랜치, $3 태그 접두어, $4 태그 설명
  local tag n=1
  tag="$(git -C "$1" tag --points-at HEAD | grep "^$3-" | head -1 || true)"
  if [ -n "$tag" ]; then
    echo "  이 커밋에는 이미 배포 태그가 있습니다: $tag"
  else
    tag="$3-$(date +%Y-%m-%d)"
    while git -C "$1" rev-parse -q --verify "refs/tags/$tag" >/dev/null; do n=$((n + 1)); tag="$3-$(date +%Y-%m-%d)-$n"; done
    git -C "$1" tag -a "$tag" -m "$4"
    echo "  새 태그: $tag"
  fi
  git -C "$1" push -q "$PRIVATE_REMOTE" "$2" "refs/tags/$tag"
  echo "  비공개 저장소에 $2 브랜치와 태그 $tag 를 올렸습니다"
}

merge_target() { # $1 저장소, $2 대상, $3 설명
  if git -C "$1" merge-base --is-ancestor "$2" HEAD; then
    echo "  이미 $2 까지 들어 있습니다"
    return 0
  fi
  echo "  새로 들어올 원본 커밋: $(git -C "$1" rev-list --count HEAD.."$2")개"
  if ! git -C "$1" merge --no-ff -m "원본 $2 통합: 로컬 수정 유지 ($3)" "$2"; then
    echo "  충돌 파일:"
    git -C "$1" diff --name-only --diff-filter=U | sed 's/^/    /'
    die "충돌이 났습니다. $1 에서 충돌을 정리해 커밋한 뒤 같은 명령을 다시 실행하세요" 2
  fi
}

# ─── 확인 ───────────────────────────────────────────────

cmd_check() {
  local target ahead clone status=0
  say "게이트웨이 원본($GW_REPO) 최신 정식 릴리스"
  target="$(fetch_gateway_target)"
  if git -C "$GW" merge-base --is-ancestor "$target" gateway; then
    echo "  최신입니다 (원본 $target 포함, 운영 소스 $(deployed_gateway_revision | cut -c1-7))"
  else
    ahead="$(git -C "$GW" rev-list --count gateway.."$target")"
    echo "  새 버전: $target (내 버전에 없는 원본 커밋 ${ahead}개)"
    git -C "$GW" log --oneline gateway.."$target" | head -10 | sed 's/^/    /'
    status=10
  fi

  say "연결 프로그램 원본(vahapogut/antigravity-add-model) main"
  git -C "$AG" fetch -q origin main
  if git -C "$AG" merge-base --is-ancestor origin/main antigravity; then
    echo "  최신입니다 (원본 $(git -C "$AG" rev-parse --short origin/main) 포함)"
  else
    ahead="$(git -C "$AG" rev-list --count antigravity..origin/main)"
    echo "  새 커밋 ${ahead}개"
    git -C "$AG" log --oneline antigravity..origin/main | head -10 | sed 's/^/    /'
    status=10
  fi

  say "Antigravity 공식 앱 (복제본 'Antigravity Gateway.app' 의 원본)"
  clone="$(cd "$AG" && node scripts/macos-clone.mjs verify --target "$APP_CLONE" --json 2>/dev/null || true)"
  case "$clone" in
    *'"sourceChanged":false'*) echo "  복제 이후 바뀌지 않았습니다 ($(printf '%s' "$clone" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sourceVersion"])'))" ;;
    *'"sourceChanged":true'*) echo "  공식 앱이 업데이트됐습니다. 복제본을 다시 만들어야 할 수 있습니다(승인 후 npm run mac:clone)"; status=10 ;;
    *) echo "  복제본 상태를 확인하지 못했습니다" ;;
  esac
  # 설치된 앱 비교만으로는 아직 내려받지 않은 새 버전을 모르므로, 공식 앱이 업데이트에 쓰는 서버의 정식 버전 목록과 비교한다.
  local installed latest
  installed="$(defaults read "/Applications/Antigravity.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)"
  latest="$(curl -fsS -m 15 https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/releases 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["version"])' 2>/dev/null || true)"
  if [ -z "$latest" ]; then
    echo "  공식 최신 버전을 확인하지 못했습니다 (설치됨 ${installed:-알 수 없음})"
  elif [ "$latest" = "$installed" ]; then
    echo "  공식 최신 버전과 같습니다 ($installed)"
  else
    echo "  공식 새 버전 $latest 이 나왔습니다 (설치됨 $installed). 공식 앱 업데이트 후 복제본을 다시 만들어야 합니다(승인 후)"
    status=10
  fi
  return "$status"
}

# ─── 게이트웨이 ─────────────────────────────────────────

# 빌드에 필요한 SpiderMonkey 정적 라이브러리. 없으면 원본 작성자의 GitHub 릴리스에서 받고, 등록된 SHA-256 과 일치할 때만 쓴다.
spidermonkey_dir() {
  local version dir asset tar want got
  version="$(awk '/SPIDERMONKEY:/{print $2; exit}' "$GW/.github/workflows/build.yml")"
  [ -n "$version" ] || die "원본 build.yml 에서 SpiderMonkey 버전을 찾지 못했습니다"
  dir="$ROOT/toolchain/spidermonkey/$version-darwin-arm64"
  if [ ! -f "$dir/lib/libjs_static.a" ]; then
    asset="spidermonkey-$version-darwin-arm64.tar.gz"
    tar="$ROOT/toolchain/spidermonkey/download/$asset"
    mkdir -p "$(dirname "$tar")"
    say "SpiderMonkey $version 내려받기" >&2
    want="$(curl -fsSL --max-time 20 "https://api.github.com/repos/Mag1cFall/firefox/releases/tags/$version" |
      python3 -c 'import json,sys; n=sys.argv[1]; print(next(a["digest"] for a in json.load(sys.stdin)["assets"] if a["name"]==n).split(":",1)[1])' "$asset")"
    curl -fsSL -o "$tar" "https://github.com/Mag1cFall/firefox/releases/download/$version/$asset"
    got="$(shasum -a 256 "$tar" | cut -d' ' -f1)"
    [ "$got" = "$want" ] || { rm -f "$tar"; die "SpiderMonkey 해시 불일치 (받은 $got, GitHub $want)"; }
    mkdir -p "$dir"
    tar -xzf "$tar" -C "$dir"
  fi
  echo "$dir"
}

go_env() {
  local sm
  sm="$(spidermonkey_dir)"
  export CGO_ENABLED=1 CGO_CXXFLAGS="-I$sm/include" CGO_LDFLAGS="-L$sm/lib" GOFLAGS=-mod=readonly
}

gateway_merge() {
  local target
  say "① 합치기: 게이트웨이 원본 최신 정식 릴리스를 내 버전에 합칩니다"
  require_clean "$GW" gateway
  target="$(fetch_gateway_target)"
  merge_target "$GW" "$target" "게이트웨이"
}

gateway_test() {
  local packages target
  say "② 시험: 관리 화면 빌드와, 내 수정이 들어간 Go 패키지 테스트"
  require_clean "$GW" gateway
  (cd "$GW/web" && npm ci --no-audit --no-fund --loglevel=error && npm run build >/dev/null) || die "관리 화면 빌드 실패" 3
  go_env
  target="$(fetch_gateway_target)"
  packages="$(git -C "$GW" diff --name-only "$target" gateway -- '*.go' | xargs -n1 dirname | sort -u | sed 's#^#./#' | tr '\n' ' ')"
  [ -n "$packages" ] || packages="./internal/config ./internal/aistudio ./internal/app"
  echo "  테스트 대상: $packages"
  (cd "$GW" && go test -timeout 900s $packages 2>&1 | grep -v 'ld: warning: ignoring duplicate libraries') ||
    die "테스트가 실패했습니다. 운영은 바꾸지 않았습니다" 3
}

gateway_build() {
  say "③ 빌드: 실행 파일 만들기"
  require_clean "$GW" gateway
  [ -f "$GW/internal/webui/dist/index.html" ] || die "관리 화면 빌드 결과가 없습니다. 먼저 test 단계를 실행하세요"
  go_env
  mkdir -p "$(dirname "$GW_BIN")"
  rm -f "$GW_BIN"
  (cd "$GW" && go build -trimpath -o "$GW_BIN" ./cmd/aistudio2api 2>&1 | grep -v 'ld: warning: ignoring duplicate libraries\|^# github.com' || true)
  [ -x "$GW_BIN" ] || die "빌드 실패" 3
  "$GOBIN/go" version -m "$GW_BIN" | grep -q 'vcs.modified=false' || die "커밋되지 않은 변경이 섞인 빌드입니다"
  echo "  $("$GOBIN/go" version -m "$GW_BIN" | awk '$1=="mod"{print $3}') / sha256 $(shasum -a 256 "$GW_BIN" | cut -c1-16)…"
}

gateway_deploy() {
  local stamp backup revision db
  say "④ 교체: 백업 후 운영 실행 파일을 바꾸고 재시작"
  [ -x "$GW_BIN" ] || die "빌드된 실행 파일이 없습니다. 먼저 build 단계를 실행하세요"
  revision="$("$GOBIN/go" version -m "$GW_BIN" | awk '$2 ~ /^vcs.revision=/{sub("vcs.revision=","",$2); print $2}')"
  [ "$revision" = "$(git -C "$GW" rev-parse HEAD)" ] || die "빌드 파일이 현재 gateway 커밋과 다릅니다. build 단계를 다시 실행하세요"
  if [ "$revision" = "$(deployed_gateway_revision)" ]; then
    echo "  운영 중인 실행 파일이 이미 이 소스(${revision:0:7})입니다. 교체하지 않습니다"
    return 0
  fi
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="$SV/runtime/deployment-backups/$stamp"
  mkdir -m 700 "$backup"
  cp -p "$SV/aistudio2api" "$backup/aistudio2api.previous"
  cp -p "$SV/.env" "$backup/env.previous" # 비밀값 포함, 권한 600 유지
  for db in requests prompts; do
    if [ -f "$SV/runtime/$db.db" ]; then
      sqlite3 "$SV/runtime/$db.db" ".backup '$backup/$db.db'"
      [ "$(sqlite3 "file:$backup/$db.db?immutable=1" 'pragma integrity_check;')" = ok ] || die "$db.db 백업 무결성 검사 실패. 운영은 바꾸지 않았습니다"
    fi
  done
  {
    echo "created_utc=$stamp"
    echo "previous_revision=$(deployed_gateway_revision)"
    echo "previous_sha256=$(shasum -a 256 "$backup/aistudio2api.previous" | cut -d' ' -f1)"
    echo "new_revision=$revision"
    echo "new_sha256=$(shasum -a 256 "$GW_BIN" | cut -d' ' -f1)"
    echo "env_previous_contains_secrets=true"
    echo "rollback=aistudio2api.previous 와 env.previous 를 함께 복원한 뒤 browser-host 와 gateway 재시작"
  } > "$backup/manifest.txt"
  echo "  백업: $backup"
  cp "$GW_BIN" "$SV/.aistudio2api.new"
  chmod 700 "$SV/.aistudio2api.new"
  mv -f "$SV/.aistudio2api.new" "$SV/aistudio2api"
  launchctl kickstart -k "gui/$(id -u)/io.ais-subscription-gateway.browser-host" ||
    echo "  (로그인 브라우저 도우미 재시작 실패: Mac 사용자 로그인 뒤 다시 시도 필요)"
  if ! restart_service system/io.ais-subscription-gateway.gateway "$SV/aistudio2api -open-ui=false" http://127.0.0.1:2048/health; then
    echo "  새 버전이 90초 안에 정상 응답하지 않아 이전 버전으로 되돌립니다"
    cp -p "$backup/aistudio2api.previous" "$SV/.aistudio2api.new" && mv -f "$SV/.aistudio2api.new" "$SV/aistudio2api"
    cp -p "$backup/env.previous" "$SV/.env"
    launchctl kickstart -k "gui/$(id -u)/io.ais-subscription-gateway.browser-host" || true
    restart_service system/io.ais-subscription-gateway.gateway "$SV/aistudio2api -open-ui=false" http://127.0.0.1:2048/health ||
      die "되돌린 뒤에도 게이트웨이가 응답하지 않습니다. $SV/runtime/gateway-service.log 를 확인하세요" 5
    echo "result=rolled_back" >> "$backup/manifest.txt"
    die "배포 실패로 이전 버전으로 되돌렸습니다. 로그: $SV/runtime/gateway-service.log" 4
  fi
  echo "result=deployed" >> "$backup/manifest.txt"
}

# 실제 구독 요청 1건을 보내 응답을 확인한다(수 토큰 사용). 키는 내부에서만 읽는다.
real_request() {
  (cd "$ROOT" && node --input-type=module -e '
import {readFileSync} from "node:fs";
const env=Object.fromEntries(readFileSync("service/.env","utf8").split(/\r?\n/).filter(x=>x&&!x.startsWith("#")).map(x=>{const p=x.indexOf("=");return [x.slice(0,p),x.slice(p+1)]}));
const key=(env.PROXY_API_KEY||"").split(",")[0].trim();
const r=await fetch("http://"+(env.LISTEN_ADDR||"127.0.0.1:2048")+"/v1/chat/completions",{method:"POST",headers:{Authorization:"Bearer "+key,"Content-Type":"application/json"},body:JSON.stringify({model:"gemini-4-argon",stream:false,messages:[{role:"user",content:"OK만 답하세요"}]}),signal:AbortSignal.timeout(180000)});
const b=await r.json();
console.log("  실제 요청: HTTP",r.status,"응답",JSON.stringify(b.choices?.[0]?.message?.content??b.error?.message??""),"토큰",b.usage?.total_tokens??"-");
if(r.status!==200) process.exit(1);
')
}

gateway_verify() {
  say "⑤ 확인: 상태 점검, 설정 점검, 실제 요청"
  wait_health http://127.0.0.1:2048/health 60 || die "로컬 상태 점검 실패" 4
  echo "  로컬 $(http_code http://127.0.0.1:2048/health) / 사설 HTTPS $(http_code "$HTTPS_URL/health" 15) / 미인증 관리 API $(http_code http://127.0.0.1:2048/api/accounts) (401 이어야 정상)"
  [ "$(http_code http://127.0.0.1:2048/api/accounts)" = 401 ] || die "관리 API 가 인증 없이 열려 있습니다" 4
  node "$ROOT/bin/check.mjs" --config-only | sed 's/^/  /'
  echo "  운영 버전: $("$GOBIN/go" version -m "$SV/aistudio2api" | awk '$1=="mod"{print $3}')"
  real_request || die "실제 요청이 실패했습니다. 대시보드 계정 상태와 $SV/runtime/gateway-service.log 를 확인하세요" 4
}

gateway_save() {
  say "⑥ 보관: 비공개 저장소에 내 게이트웨이 버전 저장"
  require_clean "$GW" gateway
  [ "$(git -C "$GW" rev-parse HEAD)" = "$(deployed_gateway_revision)" ] || die "운영 중인 소스와 gateway 커밋이 다릅니다. 배포를 먼저 끝내세요"
  save_to_private "$GW" gateway gateway "배포한 게이트웨이 소스: 원본 $(git -C "$GW" describe --tags --abbrev=0 --match 'v*' 2>/dev/null || echo '?') + 로컬 수정"
}

cmd_gateway() {
  case "${1:-all}" in
    merge) gateway_merge ;; test) gateway_test ;; build) gateway_build ;;
    deploy) gateway_deploy ;; verify) gateway_verify ;; save) gateway_save ;;
    all)
      gateway_merge
      if [ "$(git -C "$GW" rev-parse HEAD)" = "$(deployed_gateway_revision)" ]; then
        echo "  운영 중인 게이트웨이가 이미 이 버전입니다. 할 일이 없습니다"
        return 0
      fi
      gateway_test; gateway_build; gateway_deploy; gateway_verify; gateway_save ;;
    *) die "알 수 없는 단계: $1" ;;
  esac
}

# ─── 연결 프로그램 ───────────────────────────────────────

# 마지막으로 운영에 반영한 연결 프로그램 커밋(antigravity-날짜 태그)
last_antigravity_tag() { git -C "$AG" describe --tags --abbrev=0 --match 'antigravity-*' 2>/dev/null || true; }

antigravity_is_deployed() {
  local last
  last="$(last_antigravity_tag)"
  [ -n "$last" ] && [ "$(git -C "$AG" rev-parse "$last^{commit}")" = "$(git -C "$AG" rev-parse HEAD)" ]
}

antigravity_merge() {
  say "① 합치기: 연결 프로그램 원본 main 을 내 버전에 합칩니다"
  require_clean "$AG" antigravity
  git -C "$AG" fetch -q origin main
  merge_target "$AG" origin/main "연결 프로그램"
}

antigravity_build() {
  say "② 빌드·시험: 연결 프로그램 빌드와 테스트"
  require_clean "$AG" antigravity
  (cd "$AG" && npm ci --no-audit --no-fund --loglevel=error && npm run build >/dev/null) || die "빌드 실패" 3
  if [ -n "$(git -C "$AG" status --porcelain -- dist)" ]; then
    # 이 저장소는 빌드 결과(dist)를 함께 커밋하는 방식이다
    git -C "$AG" add -A dist
    git -C "$AG" commit -q -m "빌드: 합친 소스로 dist 다시 생성"
    echo "  빌드 결과(dist)를 커밋했습니다"
  fi
  [ -z "$(git -C "$AG" status --porcelain)" ] || die "빌드 뒤 dist 밖의 파일이 바뀌었습니다. 확인이 필요합니다"
  (cd "$AG" && npm test) || die "테스트가 실패했습니다. 모델 연결 서비스는 아직 재시작하지 않았습니다" 3
}

antigravity_deploy() {
  local last
  say "③ 교체: 모델 연결 서비스 재시작"
  if antigravity_is_deployed; then
    echo "  운영 중인 버전($(last_antigravity_tag))과 같습니다. 재시작하지 않습니다"
    return 0
  fi
  last="$(last_antigravity_tag)"
  restart_service system/io.ais-subscription-gateway.models "$AG/scripts/desktop-service.mjs" http://127.0.0.1:50999/health ||
    die "모델 연결 서비스가 90초 안에 응답하지 않습니다. 이전 버전은 태그 $last 입니다" 4
  if [ -n "$last" ] && [ -n "$(git -C "$AG" diff --name-only "$last" HEAD -- src scripts ':!src/__tests__')" ]; then
    echo "  ⚠ 앱에 들어가는 코드가 바뀌었습니다. 'Antigravity Gateway.app' 복제본을 다시 만들어야 새 기능이 앱에 반영됩니다(승인 후 npm run mac:clone)"
  fi
}

antigravity_verify() {
  say "④ 확인: 모델 연결 서비스 상태"
  wait_health http://127.0.0.1:50999/health 30 || die "모델 연결 서비스 상태 점검 실패" 4
  echo "  모델 연결 서비스 $(http_code http://127.0.0.1:50999/health) / 게이트웨이 $(http_code http://127.0.0.1:2048/health)"
}

antigravity_save() {
  say "⑤ 보관: 비공개 저장소에 내 연결 프로그램 버전 저장"
  require_clean "$AG" antigravity
  save_to_private "$AG" antigravity antigravity "운영 중인 연결 프로그램: 원본 $(git -C "$AG" rev-parse --short origin/main) + 로컬 수정"
}

cmd_antigravity() {
  case "${1:-all}" in
    merge) antigravity_merge ;; build) antigravity_build ;; deploy) antigravity_deploy ;;
    verify) antigravity_verify ;; save) antigravity_save ;;
    all)
      antigravity_merge
      if antigravity_is_deployed; then
        echo "  운영 중인 연결 프로그램이 이미 이 버전입니다. 할 일이 없습니다"
        return 0
      fi
      antigravity_build; antigravity_deploy; antigravity_verify; antigravity_save ;;
    *) die "알 수 없는 단계: $1" ;;
  esac
}

case "${1:-}" in
  check) cmd_check ;;
  gateway) cmd_gateway "${2:-all}" ;;
  antigravity) cmd_antigravity "${2:-all}" ;;
  *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
