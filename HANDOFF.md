# Handoff: AI Studio 구독 사용량 다계정 게이트웨이

최종 확인: 2026-10-26 KST (독립 App 실제 구독 응답·웹 계정 저장·시스템 서비스 구성, 14절 참고)
작업 폴더: `~/Projects/ais-subscription-gateway`

## 1. 목표와 범위

AI Studio 웹에서 계정에 할당된 구독 사용량을 OpenAI/Anthropic/Gemini 호환 API로 중계한다. 월 $10 Google Cloud/API 크레딧을 소비하는 공식 API 연결 작업이 아니다.

계정 선택 우선순위:
1. `charlie.main@example.com` (main)
2. `alpha.sub@example.com`
3. `bravo.sub@example.com`
4. `delta.sub@example.com`

주 계정이 사용 가능하면 우선 사용하고, 인증/모델 자격/쿨다운/동시 요청 슬롯 등에 따라 다음 사용 가능한 계정으로 전환한다. 여러 계정으로 제한을 없애거나 Google의 승인을 보장하는 것은 아니다. 비공식 웹 프로토콜 기반이라 서비스 변경·계정 제한 위험이 있다.

기존 에이전트 도구 설정은 변경하지 않았다. 요청에 없던 Cloud 결제 계정 생성·카드 등록·충전·유료 API 키 연결도 하지 않았다.

## 2. 현재 상태 요약

**독립 App·IDE 구독 모델의 실제 응답, 인증된 Tailscale 대시보드, 웹 계정 추가가 동작한다. 시스템 자동 실행 구성은 설치했지만 실제 재부팅 후 로그인 전 검증은 남아 있다.**

- 사용하는 앱: `~/Applications/Antigravity Gateway.app`(2.26.0). 원본 `/Applications/Antigravity.app`은 무변경이며 복제본만 로컬 서명했다.
- 모델: `구독 · AI Studio Argon` → `gemini-4-argon`, `playground` 구독 경로. 독립 App과 IDE 모두 실제 `OK`, HTTP 200 기록. 유료 API 자동 전환 없음.
- 대시보드: `https://ais-subscription-gateway.your-tailnet.ts.net/`. Tailscale 사설 접근 + 관리자 로그인. 초기 자격증명은 `service/runtime/admin-login.json`(600), 값 출력 금지.
- 저장 계정: main(`charlie.main`), `alpha.sub`, `bravo.sub`, `delta.sub` 네 개. 나머지 세 계정은 웹 로그인 저장을 확인했고 모두 모델 45개·사용 가능 상태다.
- 생성 서비스는 RUNNING. `gateway`, `models`, `tailscale`은 system LaunchDaemon, 로그인 브라우저는 Aqua LaunchAgent로 분리했다.
- 모델 연결 서비스의 종료 후 자동 재시작 및 저장 모델 유지 확인. 기존 Tailscale Serve 설정은 보존했다.

### 아직 검증하지 않은 경계
- 실제 재부팅 후 Mac 사용자 로그인 전, 다른 기기에서 대시보드·기존 계정 모델 호출. 재부팅 승인 없이 실행하지 않는다.
- 실제 만료 계정 재인증 완료와 계정 간 실전 전환. 정상 인증이나 할당량을 고의로 소진하지 않는다.
- 웹 로그인 중 브라우저 준비 45초 초과 실패 1회가 있었고 이후 세 계정 저장은 성공했다. 원인은 미확정이며 해결됐다고 단정하지 않는다.

## 3. 디렉터리 구조

```text
upstream/                         Git 소스, 로컬 수정 포함
service/aistudio2api               빌드된 커스텀 바이너리
service/.env                      보호된 실행 설정, 비밀값 포함, mode 600
service/auth/                     지정 계정 인증 저장 위치, 확인된 계정 4개
service/runtime/camoufox/          자동 설치된 로그인 브라우저
service/runtime/*-service.log      시스템 서비스·GUI 브라우저 도우미 로그
service/runtime/admin-login.json   초기 관리자 로그인 정보, mode 600, 출력 금지
service/launchd/                   설치용 plist 원본
bin/build.sh                      웹 빌드 + 3개 패키지 테스트 + Go 빌드
bin/start.sh                      서비스 폴더에서 실행, umask 077
bin/check.mjs                     비밀 출력 없는 설정/모델 목록 점검
bin/prepare-services.mjs           설치용 시스템 서비스·Aqua 도우미 설정 생성
bin/install-services.sh            승인된 시스템 서비스 설치, root 전용
bin/install-browser-host.sh        사용자 Aqua 도우미 설치
관리 대시보드.webloc                사설 HTTPS 대시보드 열기
bin/login-proxy.mjs                초기 진단용 프록시, 현재 관리 경로에는 사용하지 않음
bin/config.test                   테스트 실행 파일
bin/aistudio.test
bin/app.test
toolchain/go/                     프로젝트 전용 공식 Go 1.27.3
README.ko.md                      현재 사용자 동선·운영·미검증 경계
```

별도 설치한 Go는 전역 PATH나 시스템 Go 설치를 변경하지 않는다.

## 4. 코드 변경 상세

upstream: `https://github.com/Mag1cFall/AIStudio2API`
기준 커밋: `1169c534a4f4faa46981a117f0c80aada72bc0bb`
로컬 변경은 미커밋 상태. 빌드 UI에 `v0.2.15+dirty` 표시.

변경 파일:
- `.env.example`: ACCOUNT_ORDER 설명 추가.
- `internal/config/config.go`: ACCOUNT_ORDER 로드/저장/JSON roundtrip 및 중복 제거.
- `internal/aistudio/accounts.go`: 계정 순위 setter·비교 함수·standby 우선순위 도우미.
- `internal/aistudio/channel.go`: 계정/채널 후보 정렬에도 같은 순위 적용.
- `internal/app/runtime.go`: 시작 시 순위 설정, warm/standby 획득 로직 수정.
- `internal/app/admin.go`: UI 설정 저장 시 ACCOUNT_ORDER 보존 및 pool 반영.
- `internal/app/admin_config_test.go`: 관리자 저장 회귀 테스트.
- `internal/config/account_order_test.go`: 신규 설정 저장/로드 테스트.
- `internal/aistudio/account_order_test.go`: 두 정렬, round-robin 보존, busy/cooldown/disabled fallback, 소유 계정 pin, standby 우선순위 테스트.

핵심 주의:
- 원본 `fill-first`는 알파벳순이라 그대로면 alpha.sub이 main보다 먼저 선택된다. 가져온 순서나 디렉터리 접두어로 해결하지 말 것.
- ACCOUNT_ORDER는 **선호 순서이지 allowlist가 아니다**. 미등록 순위 계정도 뒤에서 선택될 수 있다. auth에는 지정한 네 계정만 추가하거나 나머지를 비활성화해야 한다.
- ACCOUNT_ORDER는 현재 env 전용이며 UI 편집 필드는 없다. 편집 후 재시작.
- round-robin과 명시적인 AccountID/ResourceID 소유권은 유지한다.
- main이 busy이면 기다리기만 하지 않고 다음 계정으로 넘어간다. '쿼터 소진 때만 fallback' 정책은 아니다.
- worker 슬롯이 꽉 차고 교체 가능한 idle worker도 없으면 standby 승격 우선권은 제한될 수 있다.
- 전체 acquireWarmLease의 실제 Google/worker 통합 테스트는 수행하지 않았다.

## 5. 실행 설정

비밀값을 제외한 의도:

```dotenv
LISTEN_ADDR=127.0.0.1:2048
PREVIEW_LISTEN_ADDR=127.0.0.1:2050
AISTUDIO_AUTH_STATES=auth
AUTO_START=true
REQUEST_BODY_LOG=false
LOG_FILE=true
LOG_MAX_TOTAL_MB=20
ADMIN_AUTH_ENABLED=true
WAA_BACKEND=go
WARM_WORKER_LIMIT=4
MAX_ACTIVE_WORKERS=4
WARM_STARTUP_CONCURRENCY=1
PER_ACCOUNT_CONCURRENCY=1
ROUTING_STRATEGY=fill-first
ACCOUNT_ORDER=charlie.main@example.com,alpha.sub@example.com,bravo.sub@example.com,delta.sub@example.com
UPSTREAM_CHANNELS=playground
REQUEST_TIMEOUT=5m
FAKE_STREAM=false
```

- PROXY_API_KEY는 이 로컬 API 보호용으로 생성해 `.env`에만 저장했다. Google API 키가 아니다.
- **`.env` 전체, `/api/config` 전체, storage-state, 쿠키, 인증 헤더를 출력하거나 handoff에 복사하지 말 것.**
- 관리자는 인증이 필요하다. 루프백 바인딩을 유지하며 프로젝트 전용 Tailscale Serve가 인증된 사설 HTTPS 접근을 제공한다. 공개 Funnel은 사용하지 않는다.
- `UPSTREAM_CHANNELS=playground`여도 원본은 `-build` 도우미 모델을 별도 경로로 허용한다. 순수 Playground만 쓸 때는 `-build` 모델을 선택하지 말 것. 강제 차단 allowlist는 아직 구현하지 않았다.
- Go WAA 백엔드는 상시 생성 worker에 브라우저가 필요 없다는 의미이며, 최초 Google 로그인에는 Camoufox가 여전히 필요하다.

## 6. 실행·검증 명령

일상 사용은 앱과 웹 대시보드로 한다. 시스템 서비스가 이미 실행 중이므로 `bin/start.sh`를 중복 실행하지 않는다.

```bash
cd ~/Projects/ais-subscription-gateway
node bin/check.mjs --config-only
node bin/check.mjs
launchctl print system/io.ais-subscription-gateway.gateway
```

`check.mjs`의 모델 목록 조회는 생성 권한 검증과 다르다. `bin/build.sh`는 소스를 수정한 개발자가 사용하는 빌드·테스트 명령이며 서비스 설치·재시작 명령이 아니다. API 보호 키는 `.env`에서 내부로 읽고 명령행 인자·출력·채팅에 노출하지 않는다.

초기 config/aistudio/app 패키지는 격리 승인 후 실제 테스트가 PASS였다. compile-only 기록과 혼동하지 않는다. 최신 변경의 검증은 14절에 기록했다.

## 7. macOS 실행 허용 관련 승인 및 이력

사용자가 질문 UI에서 **'이 프로젝트만 허용'**을 선택했다. 허용 범위는 `~/Projects/ais-subscription-gateway` 내부 다운로드 격리 표시 해제이며 전역 보안 설정 변경 승인이 아니다.

수행:
- 프로젝트 내부 `com.apple.quarantine` 해제.
- 일부 `.git/objects/pack` 파일은 permission denied. 이 파일을 우회 접근하거나 권한 상승하지 않았다.
- npm 의존성 재설치 후 node_modules 격리 해제, 테스트/빌드 바이너리 격리 해제.
- 로그인 시 Camoufox가 다시 다운로드돼 새 격리 표시가 붙었고, 해당 브라우저 폴더의 표시도 승인 범위 안에서 해제.
- 이후 별도 승인으로 시스템 LaunchDaemon 3개를 macOS 관리자 인증 창을 통해 설치했다. 실제 서비스는 `macuser` 사용자로 실행한다.
- 원본 보존 조건의 별도 App 로컬 재서명과 수동 교체 정책도 후속 승인받아 적용했다. 전역 보안 해제나 원본 패치 승인은 아니다.

미수행:
- Gatekeeper/SIP/전역 보안 해제.
- Camoufox 임의 재서명·서명 제거.

`bin/build.sh`에는 승인된 프로젝트의 node_modules/생성 테스트/서비스 바이너리 격리 해제가 포함되어 있다. 다른 폴더로 옮겨 실행할 때 같은 승인으로 간주하지 말 것.

## 8. Camoufox 초기 장애 분석 (이력; 현재 해결 경로는 14절)

대상:
`service/runtime/camoufox/Camoufox.app`
버전: `152.0.4-beta.29`, mac arm64.

사용자에게 보인 경고:
> ‘Camoufox.app’은(는) 손상되었기 때문에 열 수 없습니다. 해당 항목을 휴지통으로 이동해야 합니다.

관측:
1. 첫 로그인: `signal: killed`.
2. 최신 다운로드 폴더 격리 표시 해제 후 로그인: `signal: abort trap`.
3. 직접 `--version`: `Camoufox Camoufox 152.0.4-beta.29` 정상 출력.
4. 직접 headless about:blank screenshot: `Abort trap: 6`, exit 134.
5. `codesign --verify --deep --strict`: `code has no resources but signature indicates they must be present`.
6. 설치된 앱의 `_CodeSignature/CodeResources`가 없고, 공식 ZIP에도 해당 항목이 없다. 따라서 이 항목 누락만으로 로컬 압축 해제 버그라고 결론 내리지 말 것.
7. 공식 ZIP SHA-256은 GitHub release asset digest와 일치.
8. 설치된 주 실행 파일 SHA-256도 공식 ZIP 안의 실행 파일과 일치.
9. 마지막 확인 시 Camoufox.app의 quarantine xattr는 없음.

검증 해시:
- 공식 Camoufox ZIP: `620d33289b5d52154cc7d92a9cca5915329aa6684105ab0f371d01480768eb53`
- 설치/ZIP 내부 camoufox 실행 파일: `59d3e9f4dd3be10f6bf2f00c5fedf68ce5be03a0eadf6256d2464fef7e2e65eb`
- AIStudio2API v0.2.15 darwin-arm64 tar.gz: `facfd0edcd80c1255654abb7377478e4ddeda509686642eeef485c71594710e0`
- Go 1.27.3 darwin-arm64 tar.gz: `dd3908cf20959d798c1e06ebe5b72213f0505ce01373b40ce3110975a6cd99c2`

~~미확정~~ → 2026-10-25 22:43 재검증으로 **외부 앱 실행 환경 제약으로 확인**(아래). 다운로드 손상·서명 문제가 아니다.

### 재검증 결과 (2026-10-25 22:43, Claude Code 세션)
- 충돌 보고서 2건: `~/Library/Logs/DiagnosticReports/camoufox-2026-10-25-210130.ips`, `camoufox-2026-10-25-210214.ips`.
  - 둘 다 `responsibleProc: 외부 앱`. 첫 건은 `parentProc: aistudio2api`(관리 서버가 띄운 로그인 시도).
  - 중단 지점: `XUL → TransformProcessType → _RegisterApplication → abort()`. 앱이 macOS 창 시스템에 자신을 등록하는 단계에서 거부되어 스스로 멈춘 것이다.
- 같은 `Camoufox.app`을 이 세션(`launchctl managername` = `Aqua`, 상위 프로세스 에이전트 앱 → claude)에서 `--headless --screenshot about:blank` 실행: exit 0, 스크린샷 생성 성공. 진단용 임시 폴더는 삭제했다.
- 결론: 현재 관리 서버(PID 98243)도 외부 앱이 띄웠으므로, 이 서버로 로그인하면 같은 지점에서 계속 중단된다. **관리 서버를 Aqua 세션(이 세션·사용자 Terminal 등)에서 다시 띄운 뒤 로그인해야 한다.**
- 미검증: 창 모드에서 실제 Google 로그인 완료까지는 아직 확인하지 않았다.

## 9. 로그인 UI·프로세스 이력

- 원본의 로컬 로그인은 네이티브 창을 열려 했으나 사용자에게 보이지 않았다.
- 원본에는 reverse proxy 요청일 때 headless 브라우저 화면을 웹에 표시하는 LiveView 지원이 있다.
- `bin/login-proxy.mjs`는 루프백에서만 수신하며 X-Forwarded-For를 추가해 이 지원 경로를 사용한다. 인증/보안 우회가 아니라 내장 원격 로그인 표시 모드 선택용이다.
- 웹 로그인 관리 UI: `http://127.0.0.1:2148`.
- 처음 2049 포트를 선택했으나 Chromium ERR_UNSAFE_PORT로 차단돼 2148로 변경.
- 구 2049 로컬 프록시 PID 98244 종료 시 EPERM. 해당 PID 생존 여부는 재확인해야 하며 제어 거부를 우회하지 말 것. 2049 UI는 브라우저에서 사용할 수 없다.
  - 22:48 재확인: PID 98244(2049)와 PID 98636(2148) 모두 살아 있음. 둘 다 외부 앱 런타임 node(`~/.agent-app/runtime/node/bin/node`)로 실행 중.
- LaunchAgent 설치 시도는 `launchctl bootstrap` error 5로 실패. 서비스 조회에서도 미등록 확인. 이 작업에서 만든 두 plist는 삭제했다. 자동 부팅은 구성되지 않았다.
- 관리 서버와 로그인 프록시는 Node spawn detached로 띄웠다. PID는 참고만 하고 현재 리스너/상태로 확인할 것. 자동 재시작 보장은 없다.
- (이력, 2026-10-25 시점) 생성 서비스는 STOPPED이며 로그인 실패 후 계정 0개 상태였다. 현재 상태는 2절·14절을 따른다.

## 10. 최초 수동 로그인 안내 (이력; 현재 웹 경로는 14절)

아래는 Terminal 로그인 결과를 받기 전의 초기 안내다. 현재는 Aqua 브라우저 도우미를 사용하는 웹 계정 관리로 전환했으며 2절·14절을 우선한다.

> 22:48 갱신: 결과는 여전히 미확인이며 `service/auth/`가 비어 있어 성공한 로그인은 없다. 8절 원인 확인에 따라 이 명령(사용자 Terminal = Aqua 세션)은 유효한 경로다. 다만 실행 중인 관리 서버는 계정을 시작할 때 읽고 auth 폴더 감시 기능은 찾지 못했으므로, 이 명령으로 저장한 계정을 반영하려면 서버 재시작이 필요하다. 대안은 Aqua 세션에서 관리 서버를 다시 띄우고 관리 화면 `계정 추가`로 로그인하는 것이다. 어느 쪽으로 할지는 사용자 확인을 기다리는 중이다.

```bash
cd ~/Projects/ais-subscription-gateway/service
./aistudio2api setup --login
```

1. 여기서 Camoufox가 열리는지 확인한다. 열리면 main 계정 `charlie.main@example.com` 로그인.
2. 비밀번호/OTP는 사용자 또는 승인된 비밀 안전 autofill로 입력. 채팅에 받거나 표시하지 않는다.
3. 동일 명령으로 나머지 지정 계정 3개 로그인. 다른 계정의 인증을 가져오지 않는다.
4. 사용자 터미널에서도 abort면 실제 crash report/배포본 호환성을 조사. 원본은 Camoufox 버전 일치를 요구하므로 임의 버전 교체를 정상 해결로 간주하지 않는다.
5. 관리 화면/API에서 네 이메일·상태·실제 감지 tier만 확인. 비밀 필드 출력 금지.
6. 서비스 시작 후 각 계정의 Argon 최소 응답을 구독 경로로 검증. 목록에 모델이 있다는 사실만으로 성공 주장 금지.
7. 기본 호출이 main을 선택하는지 sanitized 로그로 확인. 계정 간 fallback은 가능하면 가짜 테스트/안전한 상태 변경으로 검증하고 실제 할당량을 고의 소진하지 않는다.
8. 클라이언트는 Antigravity IDE의 기존 모델 드롭다운으로 확정했다. 독립 App 복제본 패치는 macOS 실행 경고로 중단했고, 사용자 승인으로 IDE 설정 연결 경로로 전환했다. 기존 에이전트 도구 설정은 변경하지 않는다.
9. 원격 접속은 필요 여부·인증·노출 범위를 별도로 확인한 뒤 구성한다. 현재 로컬 URL을 원격에서도 작동한다고 설명하지 말 것.

## 11. 주의할 기존 계정 정보

과거 Developer Program 점검과 현재 AIS 로그인 연결은 별개다.
- 계정에 따라 Developer Program 크레딧(월 $10) 표시나 결제 경고가 보일 수 있다.
- 이런 크레딧 화면이나 Pro 배지는 **AI Studio 아르곤 실제 구독 응답 권한 증거가 아니다**.
- 현재 범위는 웹 구독 다계정과 공식 API 키를 모두 지원하되, 유료 API는 사용자가 별도 모델로 직접 선택하는 방식이다. 구독 실패 시 유료 API로 자동 전환하지 않으며 API 크레딧·결제 설정을 임의로 바꾸지 않는다.

## 12. 참고 URL

- https://github.com/Mag1cFall/AIStudio2API
- https://github.com/daijro/camoufox/releases/tag/v152.0.4-beta.29
- https://github.com/daijro/camoufox/issues/480 (과거 quarantine 관련 사례. 현재 abort의 확정 원인 아님)

이 문서에는 API 키·쿠키·비밀번호·인증 state가 포함되지 않는다.

## 13. 초기 Antigravity IDE 연결 진행 (2026-10-26 이력; 후속 결과는 14절)

- 공개 연결 프로그램: `integrations/antigravity-add-model`. 초기 독립 App 2.24.0·2.26.0 구조 검사는 통과했지만 수정 복제본에서 사용자가 macOS "손상됨" 경고를 확인했다. 당시 원본 `/Applications/Antigravity.app`은 패치하지 않았고 원본 서명 검사는 통과했다. 이후 승인된 별도 복제본 로컬 재서명 결과는 14절에 기록했다.
- IDE 2.5.5는 읽기 전용 호환성 검사 통과. `scripts/ide.mjs apply → restore → apply`로 설정 적용·원복을 실제 확인했다. IDE 앱 파일은 변경하지 않았다.
- IDE 설정 `~/Library/Application Support/Antigravity IDE/User/settings.json`의 `jetski.cloudCodeUrl=http://127.0.0.1:50999`. 원본 백업은 같은 폴더의 `settings.json.antigravity-model-patch/`에 있다.
- 연결 서비스 데이터는 `service/antigravity-ide`. 시작: 연결 프로그램 폴더에서 `node scripts/desktop-service.mjs start --data-dir ~/Projects/ais-subscription-gateway/service/antigravity-ide`. 루프백 전용이며 재부팅 자동 실행은 구성하지 않았다.
- `구독 · AI Studio Argon` → `http://127.0.0.1:2048/v1/chat/completions`, 모델 `gemini-4-argon`, `fallbackModels=[]`(유료 API 대체 없음). 자동 생성 예제 모델 3개는 삭제했다.
- 사용자가 Aqua Terminal에서 `./aistudio2api setup --login`으로 `charlie.main@example.com` 저장 완료. 당시 STOPPED에서 `POST /api/control/start`로 시작하며 새 계정을 읽었다. 이미 RUNNING일 때도 다시 읽는다는 뜻은 아니다.
- **실검증**: IDE 기존 드롭다운에서 해당 모델 선택 후 "OK만 답하세요" 전송 → 응답 `OK`. `service/runtime/requests.db`에 `gemini-4-argon`, 계정 `charlie.main@example.com`, 채널 `playground`, HTTP 200 기록. 입력 토큰 41,297개(IDE 시스템 프롬프트 포함) 소모.
- 이 단계에서 미완료였던 독립 App·추가 계정·사설 원격 접속은 이후 14절처럼 진행됐다. 유료 API 키는 여전히 미저장이며 구독 실패 시 유료 경로로 바꾸지 않는다.

## 14. App·웹 계정·사설 접근·자동 실행 구현 및 실제 검증 (2026-10-26)

### Mac App
- `scripts/macos-clone.mjs`가 원본을 읽기만 하고 별도 복제본을 패치·로컬 서명한다. 원본 entitlements는 보존하고 복제본만 hardened runtime 플래그를 제외한다. 로컬 서명은 Google 서명/Apple 공증과 다르다.
- 실제 복제본: `~/Applications/Antigravity Gateway.app`, bundle ID `com.google.antigravity.gateway-local`, Electron 프로필 `service/antigravity-app`. 프로필 지정은 복제본에 내장되어 Finder로 바로 실행한다. 기존 프로젝트·대화가 보이므로 모든 Google 저장소까지 완전 분리됐다고 설명하지 않는다.
- 업데이트 확인을 검증된 시작 지점에서 막고 캐시 이름을 분리했다. 가짜 업데이트 URL 방식은 제거했다. 자동 업데이트 옵션 값만 껐다고 주장하지 않는다. 호환성을 확인한 복제본을 수동 교체한다.
- 실제 기본 목록에서 `구독 · AI Studio Argon` 선택, No Project 대화에서 도구 사용 금지·OK 요청 → `OK`. requests.db rowid 2: main, `gemini-4-argon`, `playground`, HTTP 200, completed, 입력 24,934 / 답변 5 토큰, tool_calls 0. 과거 IDE 요청(rowid 1)과 구별했다.
- 실행 후 `macos-clone.mjs verify`: `signature=adhoc`, `entitlementsPreserved=true`, `sourceChanged=false`, `sourceVersion=2.26.0`. 검사 후 디버깅 인자 없이 일반 실행했다.
- Custom Models 변경 후 기존 기본 목록이 갱신되지 않으면 앱을 다시 연다. 예제 모델 3개는 제거하고 실제 구독 모델만 남겼다.

### 웹 계정과 Aqua 브라우저 도우미
- `internal/camoufoxnative/host.go`, `internal/app/browser_host.go`: `aistudio2api browser-host`를 GUI 사용자 세션에서 실행한다. daemon은 Unix 소켓으로 로그인 브라우저를 요청한다. 소켓 600, 상위 runtime 700, 임시 프로필·실행 파일 검증 및 연결 종료 시 프로세스 그룹 정리.
- GUI 세션이 없으면 `gui_session_required`/503과 현지화한 안내를 반환한다. Mac에서만 helper를 사용하고 상시 생성 Go worker 경로는 바꾸지 않았다.
- 관리자 인증된 Tailscale HTTPS 화면에서 Google LiveView 표시 → 사용자가 직접 로그인 → `bravo.sub`, `alpha.sub`, `delta.sub` 세 계정 저장. 마지막 계정은 01:37 KST에 저장됐고 worker 4/4 준비 완료 로그가 남았다. main 포함 네 계정 모두 모델 45개·사용 가능 상태를 확인했다.
- 기존 `AccountsPanel.vue`는 `auth_required`일 때만 다시 로그인 버튼을 표시하고, 신규 계정과 같은 `runBrowserLogin`/LoginViewer를 사용한다. 정상 계정을 강제로 만료시키지 않았으며 실제 만료 재인증 완료는 미검증이다.
- 01:12 KST경 Camoufox BiDi 준비 45초 초과 실패 1회가 기록됐다. 이후 로그인은 성공했다. 브라우저 준비 지연의 원인은 로그만으로 확정하지 못했다.

### 서비스·외부 접근·복구
- system: `io.ais-subscription-gateway.gateway`, `.models`, `.tailscale`. UserName=macuser, RunAtLoad/KeepAlive, 파일 생성 권한 077. GUI: `gui/501/io.ais-subscription-gateway.browser-host`, Aqua 세션 한정.
- Tailscale 1.104.2의 별도 userspace 노드 `ais-subscription-gateway`(100.x.y.z). 상태·소켓은 `service/tailscale/`. 프로젝트 조작 시 반드시 이 소켓을 지정한다.
- 사설 HTTPS `https://ais-subscription-gateway.your-tailnet.ts.net/` → 127.0.0.1:2048. 공개 Funnel·DNS/라우팅 인수 없음. 기존 GUI Tailscale Serve 설정 유지 확인.
- 관리자 미인증 계정 API는 401, 로그인 후 200. 초기 관리자 정보와 `.env` 백업은 소유자만 읽게 저장했다. 원문 출력 금지.
- models 프로세스 정상 종료 후 launchd가 새 PID로 재기동; health 200과 저장 구독 모델 보존 확인. 실제 재부팅 전 단계의 복구 검증이며 로그인 전 부팅 검증을 대신하지 않는다.
- FileVault는 확인 당시 Off였으며 변경하지 않았다. 자동 로그인도 설정하지 않았다. 사용자가 다른 기기에서 관리자 로그인 후 대시보드 접속 성공을 확인했다. 실제 재부팅 후 로그인 전 동작은 아직 미검증이다.
- 다른 기기의 모델 실행도 사용자 완료 확인 후 감사 기록으로 확인했다. requests.db rowid 4: gemini-4-argon, alpha.sub 계정, playground, HTTP 200, completed, 답변 5 토큰, tool_calls 0. main 이외 계정의 실응답 증거이며 한도 소진 시 전환을 검증한 것은 아니다.
- `관리 대시보드.webloc` 형식 검사 통과. 안내는 README.ko.md에 현재 동선으로 정리했다.

### 실행한 검증
- Go: `go test ./internal/api ./internal/app ./internal/camoufoxnative` 모두 통과. 웹 프로덕션 빌드와 실제 Go 바이너리 빌드 성공. `GOOS=windows CGO_ENABLED=0 go build ./...` 성공.
- 연결 프로그램: `npm run build` 성공. 전체 테스트 실행은 59개 파일 중 58개 성공, 1개 환경 의존 실패였다. 실제 설치 앱 대신 임시 fixture만 읽도록 해당 테스트를 고친 뒤 `google-native-client.test.ts` 15개 성공. 최종 clone/runtime 변경 뒤 `deployment.test.ts` + `runtime-patch.test.ts` 71개 성공. 마지막에 59개 전체를 한 번 더 실행한 결과라고 보고하지 않는다.
- 실제 화면·응답·요청 감사 기록·서명 확인은 위 항목처럼 별도로 수행했다. 단위 테스트나 모델 목록만으로 실사용 성공을 주장하지 않는다.

수동으로 auth 파일을 추가한 경우 시작 시에만 다시 읽는다. 이미 RUNNING이면 안전한 시점에 stop/start가 필요하다. 웹 저장에는 이 절차가 필요 없다. 지정된 네 계정은 모두 저장됐으므로 추가 로그인 작업은 남아 있지 않다.

남은 승인·확인은 실제 재부팅 후 Mac 로그인 전 동작이다. 미커밋 사용자 변경은 보존했으며 커밋·푸시·PR은 만들지 않았다.

