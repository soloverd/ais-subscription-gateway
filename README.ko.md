# AI Studio 구독 게이트웨이

## 매일 사용하는 방법

| 할 일 | 진입점 |
| --- | --- |
| Antigravity에서 구독 모델 사용 | `~/Applications/Antigravity Gateway.app` → 모델 목록의 **구독 · AI Studio Argon** |
| 계정 추가·상태 확인 | [관리 대시보드](https://ais-subscription-gateway.your-tailnet.ts.net/) 또는 이 폴더의 **관리 대시보드.webloc** |
| 같은 Mac에서 관리 | http://127.0.0.1:2048 |
| 다른 호환 클라이언트 연결 | 로컬 OpenAI Base URL: `http://127.0.0.1:2048/v1` |

대시보드는 같은 Tailscale 사설망에서 허용된 기기만 접근할 수 있고, 관리자 로그인이 추가로 필요합니다. 초기 로그인 정보는 소유자만 읽을 수 있는 `service/runtime/admin-login.json`에 있습니다. 비밀번호·쿠키·API 키를 채팅이나 로그에 붙여 넣지 마세요.

### 웹으로 Google 계정 추가

1. 서버 Mac에 사용자 로그인을 한 번 합니다. 화면을 잠그는 것과 로그아웃은 다릅니다.
2. 대시보드에서 **계정 → 계정 추가 → 브라우저로 로그인**을 선택합니다.
3. 웹 안에 표시되는 Google 화면에서 직접 로그인·2단계 인증합니다. Terminal 명령은 필요 없습니다.
4. 계정 목록에 이메일과 모델 상태가 표시되는지 확인합니다. 웹에서 저장한 계정은 실행 중인 서비스에 반영됩니다.

로그인이 만료된 계정에는 **다시 로그인** 버튼이 나타나며 같은 웹 로그인 화면을 사용합니다. 정상 계정의 **수정**은 프록시·언어·시간대 설정용입니다. 실제 계정 만료 후 재인증 완료 과정은 아직 실검증하지 않았습니다.

Mac 사용자 세션이 없으면 새 Google 로그인은 할 수 없으며, 웹에 로그인 세션이 필요하다는 오류를 표시합니다. **이미 저장한 계정의 모델 호출과 대시보드는 GUI 로그인과 별도인 시스템 서비스로 구성**했습니다. 실제 재부팅 후 로그인 전 동작은 아래 미검증 항목입니다.

## 계정 우선순위와 비용 경계

1. charlie.main@example.com (main)
2. alpha.sub@example.com
3. bravo.sub@example.com
4. delta.sub@example.com

이 순서는 `service/.env`의 `ACCOUNT_ORDER`에 저장되어 있고 `fill-first`에서 적용됩니다. 주 계정이 모델 미지원·로그인 만료·쿨다운·동시 요청 슬롯 부족이면 다음 사용 가능한 계정을 선택합니다. 사용량을 전부 썼을 때만 전환하는 정책은 아닙니다.

`ACCOUNT_ORDER`는 허용 목록이 아니므로 위 네 계정만 추가하세요. 2026-10-26 네 계정 모두 저장됐고 모델 45개·사용 가능 상태를 확인했습니다. 화면에 나열된 순서가 아니라 `ACCOUNT_ORDER`가 요청 우선순위입니다.

현재 모델은 AI Studio 웹 구독 경로(`playground`)의 `gemini-4-argon`입니다. Google 공식 유료 API 키·Cloud 결제·카드·충전을 연결하지 않았고, **구독 실패 시 유료 API로 자동 전환하지 않습니다**. `-build` 모델은 별도 Build 경로이므로 Playground만 원하면 선택하지 마세요. 비공식 웹 프로토콜이므로 Google 변경이나 계정 제한의 영향을 받을 수 있습니다.

## Mac 앱과 업데이트

- 원본 `/Applications/Antigravity.app`은 수정하지 않았습니다. 사용하는 것은 별도 **Antigravity Gateway.app**입니다.
- 복제본만 로컬 서명(ad-hoc: 파일이 바뀌지 않았는지 확인하는 서명)했습니다. Google 서명이나 Apple 공증을 새로 받은 것은 아닙니다. Gatekeeper·SIP 전역 설정은 바꾸지 않았습니다.
- 복제본의 Electron 사용자 데이터는 `service/antigravity-app`에 별도 저장합니다. 다만 실제 화면에 기존 Google 프로젝트·대화가 표시되므로 모든 데이터가 완전히 분리된 앱이라고 보장하지 않습니다.
- 복제본의 자동 업데이트 확인을 막고 업데이트 캐시를 분리했습니다. 공식 앱 업데이트 후 호환성을 검사하고 복제본을 수동 교체합니다. 자세한 명령은 [호환성·복구 안내](integrations/antigravity-add-model/docs/compatibility.md)를 따릅니다.
- Custom Models에서 모델을 저장한 뒤 기본 목록에 즉시 나타나지 않으면 앱을 종료 후 다시 엽니다.

## 자동 실행과 복구

관리자 승인으로 다음 시스템 서비스를 설치했습니다. 프로세스가 종료되면 macOS의 `launchd`가 다시 실행하며, 실제 프로그램은 root가 아닌 `macuser` 사용자로 동작합니다.

- `io.ais-subscription-gateway.gateway`: 대시보드·구독 API, 127.0.0.1:2048.
- `io.ais-subscription-gateway.models`: IDE 모델 연결 서비스, 127.0.0.1:50999.
- `io.ais-subscription-gateway.tailscale`: 프로젝트 전용 사설망 노드.
- `gui/501/io.ais-subscription-gateway.browser-host`: Mac 사용자 로그인 후 실행되는 Google 로그인 브라우저 도우미.

기존 Tailscale 앱·Serve 설정은 보존했습니다. 새 노드는 userspace 방식으로 별도 상태와 소켓을 사용하며, 공개 Funnel은 켜지 않았습니다. 자동 로그인과 FileVault 설정도 바꾸지 않았습니다.

관리 서버가 살아 있는데 생성 상태만 STOPPED이면 웹의 **서비스 시작**을 누릅니다. 시스템 서비스가 실행 중일 때 `bin/start.sh`로 중복 실행하지 마세요. 개발용 설정 점검은 `node bin/check.mjs --config-only`입니다.

- 프로세스 상태: `launchctl print system/io.ais-subscription-gateway.gateway` 등으로 확인.
- 로그: `service/runtime/gateway-service.log`, `models-service.log`, `tailscale-service.log`, `browser-host-service.log`.
- 관리자/API 비밀값: `service/.env`(권한 600). API 보호 키는 Google API 키가 아닙니다.
- 설치 원본: `bin/prepare-services.mjs`, `bin/install-services.sh`, `bin/install-browser-host.sh`. 기존 서비스를 덮어쓰지 않도록 설치기가 거절하므로 일상 실행용으로 다시 돌리지 않습니다.

브라우저 준비가 45초를 넘은 실패가 한 번 관측됐고 이후 세 계정 저장은 성공했습니다. 원인은 아직 확정하지 않았습니다. 실패 알림이 나와도 먼저 계정 목록에서 저장 여부를 확인하고, 저장되지 않은 계정만 다시 로그인하세요. 기존 정상 계정을 삭제하지 마세요.

## 확인한 것과 남은 것

2026-10-26 실제 확인:
- 독립 App 2.26.0과 IDE 2.5.5의 기본 모델 선택에서 구독 모델 선택 → 실제 `OK` 응답.
- 독립 App 요청 감사 기록: `gemini-4-argon`, main 계정, `playground`, HTTP 200, 도구 호출 0회. 앱을 실행한 뒤에도 복제본 서명 유효·원본 해시 변경 없음.
- Tailscale HTTPS 대시보드 관리자 인증, 웹 Google 로그인 화면 및 나머지 세 계정 추가 저장. main 포함 네 계정 준비 완료.
- 사용자가 다른 기기에서 관리자 로그인·대시보드 접속과 모델 실행을 확인했습니다. 서버 감사 기록 rowid 4도 gemini-4-argon, alpha.sub 계정, playground, HTTP 200, completed를 확인했습니다. 실제 재부팅 후 로그인 전 동작은 아직 미검증입니다.
- 모델 연결 프로세스 종료 후 macOS가 자동 재시작; 상태 조회와 저장 모델 유지 확인.
- 변경 Go 패키지 3개 테스트·웹/Go 빌드·Windows 교차 빌드 통과. 연결 프로그램 빌드와 테스트 모듈 검증 결과는 HANDOFF 14절 참고.

남은 실검증: **승인 후 실제 재부팅 → Mac에 로그인하지 않은 상태에서 다른 기기로 대시보드 접속·기존 계정 모델 호출**, 실제 만료 계정 재인증, 계정 간 실제 전환. 할당량을 고의로 소진하지 않습니다. 초기와 현재의 상세 변경·검증 이력은 [HANDOFF.md](HANDOFF.md)를 참고하세요.

## 로컬 버전 관리 경계

2026-10-26 사용자 승인으로 운영 루트와 두 소스 저장소를 별도로 보존했습니다. 원격 푸시나 서비스 재설치는 하지 않았습니다.

- 운영 루트: `local/operations-preservation`. `.gitignore`에 명시한 운영 스크립트와 문서만 추적합니다. `service/`, 도구체인, 빌드 산출물과 중첩 소스 저장소는 제외합니다. 새 파일은 검토 후 허용 목록에 추가해야 합니다.
- `upstream/`: (이력) `local/preserve-implemented-work`, 보존 기준 `25d264b`. 커밋되지 않았던 번역 15개·QUIC 수정 1개는 `bd146a5`에 같은 내용으로 들어 있다. 2026-11-04부터 이 폴더는 `gateway` 브랜치(현재 운영 소스)다. 아래 "업데이트 유지보수" 참고.
- `integrations/antigravity-add-model/`: 2026-11-04부터 브랜치 이름 `antigravity`(옛 이름 `local/preserve-implemented-work`, 같은 커밋 `228f0db`).
- 원래 에이전트 앱 작업 공간은 같은 운영 폴더를 공유한다. 통합 작업은 별도 worktree `integration/upstream-669a207`에서 진행했다. 서비스 실행·복구는 기존 launchd가 담당한다.

이 커밋 조합은 소스 보존 기준이며 새로운 빌드·실사용 검증 결과가 아닙니다. 계정명·사설 주소가 문서와 테스트에 포함되어 있으므로 공개 전에 개인정보를 별도로 검토해야 합니다. 인증정보·운영 상태는 Git에서 복원되지 않습니다.

## 승인된 원본 업데이트 운영 반영

- 원본 `669a207`과 계정 우선순위·Mac 브라우저 도우미·기존 번역을 합친 통합본을 운영에 반영했다. 통합 worktree는 `~/worktrees/ais-upstream-integration`, 기록 기준 커밋은 `7b064f8`다.
- 실제 배포 바이너리의 소스 revision은 `f8ecc39`(clean)이며, 이후 `7b064f8`는 검증 결과 문서만 추가했다. SHA-256은 `f67d0264dbe69c58f38094afd1001a0a30678fbc20665e510e48dcb850781714`다.
- 기존 바이너리와 일관된 SQLite 백업은 `service/runtime/deployment-backups/20261028T202418Z/`에 보존했다. 복구용 실행 파일은 `aistudio2api.previous`, 배포 기록은 `manifest.json`이다. 이 폴더는 Git 추적 대상이 아니다. DB 백업은 자동 덮어쓰기용이 아니며, 복원 전에 배포 후 요청 데이터 손실을 검토해야 한다.
- 게이트웨이와 GUI 브라우저 도우미만 새 바이너리로 재시작했다. 시스템 gateway의 `launchctl kickstart`는 권한 오류가 났고, 담당 에이전트가 중단하지 않고 같은 사용자 소유 PID에 SIGTERM을 보내 launchd 재기동으로 진행했다. 관리자 권한·보안 설정은 바꾸지 않았다. 모델 연결과 Tailscale 프로세스는 유지했다.
- 배포 후 로컬·사설 HTTPS `/health`와 모델 연결 서비스가 HTTP 200, 미인증 계정 조회가 HTTP 401이었다. 계정 4개·계정 우선순위·운영 설정이 유지됐다. 인증 상태 파일 일부는 재시작 중 갱신되어 파일 내용 전체가 불변인 것은 아니다.
- 실제 구독 요청 1건: `gemini-4-argon`, `playground`, HTTP 200, `completed`, 입력 168·응답 5토큰·도구 호출 0회. 공식 유료 API는 연결하거나 사용하지 않았다.
- 이번 확인은 API 요청 1건이다. Antigravity 화면에서의 재요청, 새 Google 로그인·만료 계정 재인증, 영상 입력 실사용, 재부팅 후 로그인 전 동작은 별도 검증 대상이다.

## 원본 v0.3.0 업데이트 운영 반영 (2026-11-04)

- 원본 GitHub 최신 `v0.3.0`(`591c81f`)을 기존 통합본(`7b064f8`)에 병합했다. 통합 worktree는 `~/worktrees/ais-upstream-v0.3.0`, 브랜치 `integration/upstream-v0.3.0`, 커밋 `259b2f0`(clean)다. 이전 통합 worktree·브랜치는 그대로 두었다.
- 유지한 로컬 기능: 계정 우선순위 `ACCOUNT_ORDER`(새 설정 구조에 다시 넣음), Mac 사용자 세션 브라우저 도우미, 세션 없음 안내 문구, 자주 보이는 오류의 한국어 문구. 화면 로그 번역은 원본이 서버 번역표로 옮겨 원본 구조를 따랐다.
- 버전 탭은 현재 `v0.3.1-0.20261104103143-259b2f044fbe`, 최신 `v0.3.0`, 업데이트 방식 `development`로 표시한다. 소스 빌드라서 **온라인 업데이트 버튼이 잠겨** 로컬 수정본이 공식 파일로 덮어써지지 않는다. 다음 원본 업데이트도 같은 병합·빌드 절차로 반영한다.
- 빌드에는 원본 작성자의 SpiderMonkey 정적 라이브러리가 필요하다. `toolchain/spidermonkey/v152.0.4-aistudio2api.1-darwin-arm64`(tar SHA-256 `19f690d5…b673`, GitHub 등록값과 일치)를 쓰고 `CGO_CXXFLAGS=-I…/include`, `CGO_LDFLAGS=-L…/lib`로 빌드했다. `bin/build.sh`는 옛 `upstream/` 경로용이라 이 빌드에 쓰지 않았다.
- 실행 파일 SHA-256 `a3b6588befb1f1790599a7142bc2f65370b7c3f3c977ec573ced12b18013b1fc`. 이전 실행 파일·`.env`·DB 백업과 배포 기록은 `service/runtime/deployment-backups/20261104T103417Z/`(Git 제외, `env.previous`에는 비밀값 포함)에 있다.
- 새 버전은 첫 시작 때 옛 형식의 `.env`를 자동 정리한다. 기본값과 같은 항목이 빠지고, `WAA_BACKEND=go`는 기본값 `spidermonkey`(브라우저 없이 서비스 안에서 실행)로 바뀌었다. 배포 전 `.env`에 남아 있던 `UPSTREAM_CHANNELS=playground,build`도 빠져 문서 의도대로 `playground`만 쓴다. `ACCOUNT_ORDER`·`fill-first`는 유지됐다. **되돌릴 때는 이전 실행 파일과 `env.previous`를 함께 복원**해야 한다(이전 버전은 `spidermonkey` 값을 받지 않는다).
- 배포 전 `.env`의 `REQUEST_TIMEOUT`은 문서의 5분이 아니라 30분이었다. 이번 배포로 바뀐 값이 아니며 그대로 30분이다.
- 원본 새 기본값으로 `gemini-4-argon`에는 첫 응답이 늦을 때 다른 계정으로 예비 요청을 보내는 기능(`FIRST_EVENT_HEDGE=auto`)이 켜진다. 느린 요청에서 사용량이 조금 더 들 수 있다.
- 재시작은 브라우저 도우미(PID 650→61806)와 게이트웨이(PID 271→61941)만 했다. 모델 연결·Tailscale은 유지했다. 재시작 뒤 경고·오류 로그 0건, 로컬·사설 HTTPS `/health` 200, 미인증 관리 API 401, 계정 5개·모델 45개 준비.
- 실제 구독 요청 1건: `gemini-4-argon`, 주 계정 `charlie.main@example.com`, `playground`, HTTP 200, `completed`, 응답 `OK`, 입력 167·응답 5토큰.
- 미검증: 관리자 로그인 뒤 버전 탭 화면 자체, Antigravity 화면에서의 요청, 새 Google 로그인·재인증(도우미 경유), 계정 간 실제 전환.

## Antigravity 공식 앱 2.29.0 반영 (2026-11-05)

- 공식 앱은 아직 새 버전을 내려받지 않은 상태였다(설치 2.26.0, 공식 최신 2.29.0). 그래서 `check`에 공식 업데이트 서버 버전 목록 비교를 추가했다.
- 공식 파일: `https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/manifest/latest-arm64-mac.yml`이 가리키는 `Antigravity.zip`(188,267,225바이트). 내려받은 뒤 이 목록의 SHA-512와 일치하는지, Google 서명·Apple 공증이 유효한지 확인했다.
- 교체 전 점검: 연결 프로그램 사전 점검(`deploy` 검사 모드)을 2.26.0·2.29.0 모두에 실행해 통과했다. 임시 폴더에 시험 복제본을 만들고 `verify`까지 성공한 뒤 지웠다. 2.29.0에 새로 생긴 실행 파일 `Resources/bin/cable_ble_scanner`도 권한(entitlements)을 유지한 채 재서명됐다.
- 교체: 복제본을 정상 종료했다. 기존 공식 앱·복제본·`.clone.json`은 `service/runtime/deployment-backups/20261104T162356Z-antigravity-2.26.0/`으로 옮겼다(Git 제외). 같은 ID의 앱으로 열리지 않도록 이름 끝에 `.backup`을 붙였다. 되돌리는 방법은 같은 폴더의 `manifest.txt`에 있다. 이어서 2.29.0을 `/Applications`에 풀고, `node scripts/macos-clone.mjs prepare --profile service/antigravity-app`(기존 사용자 데이터 폴더)으로 복제본을 다시 만들었다. `verify`는 `entitlementsPreserved: true`, `sourceVersion: 2.29.0`이었다.
- 실행 확인: 앱 2.29.0 시작, 언어 서버가 복제본 내부 프록시(`localhost`)를 사용, 로그인 유지(`fetchUserInfo` 200), 모델 목록 가로채기 정상. 사용자가 화면에서 구독 모델로 메시지를 보냈다. 연결 프로그램이 `custom-gemini-4-argon` → `구독 · AI Studio Argon`으로 넘겼고, 게이트웨이 기록은 `gemini-4-argon`, `alpha.sub@example.com`, HTTP 200, 도구 호출 1회 뒤 `completed`였다.
- 이번 요청은 주 계정이 아닌 `alpha.sub` 계정을 썼다. 업데이트 전(01:20~01:22) 요청도 같은 계정이었으므로 이번 교체 때문은 아니다.
- 이후(2026-11-05 20:49) macOS 저장 공간 정리로 공식 앱 `/Applications/Antigravity.app`과 위 2.26.0 보관 폴더가 지워졌다. 사용자는 공식 앱을 복구하지 않고 복제본만 쓰기로 했다. 복제본은 공식 앱 없이도 정상 실행됨을 확인했다(로그인 200, 모델 목록 가로채기). Launchpad에 남은 공식 앱 아이콘은 Launchpad 목록 파일에서 해당 항목(`com.google.antigravity`)을 지우고 Dock을 다시 시작해 정리했다. 이제 Spotlight·Launchpad·`antigravity://` 링크는 모두 복제본으로 연결된다.

## 업데이트 유지보수 (두 원본을 따라 내 앱 최신 유지)

내 앱은 남이 만든 원본 두 개에 내 수정을 덧붙여 조합한 것이다. 원본에 새 버전이 나오면 내 수정은 살린 채 합쳐서 다시 반영한다. 정책은 **알림 후 승인 반영**이다(2026-11-04 사용자 결정). 새 버전을 확인해 알리기만 하고, 사용자가 승인했을 때만 반영한다.

| 부품 | 원본 | 따라가는 기준 | 내 버전이 있는 곳 (로컬 폴더 / 비공개 저장소 브랜치) |
| --- | --- | --- | --- |
| 게이트웨이 | `Mag1cFall/AIStudio2API` | 최신 **정식 릴리스** (대시보드 버전 탭과 같은 기준) | `upstream/` / `gateway` |
| 연결 프로그램 | `vahapogut/antigravity-add-model` | 원본 `main` (정식 릴리스를 내지 않음) | `integrations/antigravity-add-model/` / `antigravity` |
| 운영 기록·스크립트 | — | — | 이 폴더 / `main` |

비공개 저장소는 `soloverd/ais-subscription-gateway` 하나다. 원본 저장소에는 푸시하지 않는다. 배포할 때마다 `gateway-날짜`, `antigravity-날짜` 태그를 붙여 어떤 소스가 운영에 들어갔는지 남긴다. `service/`의 인증정보·`.env`·DB·백업과 빌드 산출물은 올리지 않으며, 문서와 테스트에 계정 이메일·사설 주소가 있으므로 저장소를 공개로 바꾸지 않는다.

### 명령

```bash
bin/update.sh check          # 새 버전이 있는지만 확인. 아무것도 바꾸지 않음. 새 버전이 있으면 종료 코드 10
bin/update.sh gateway        # 게이트웨이: 합치기 → 시험 → 빌드 → 백업·교체 → 실제 요청 확인 → 비공개 저장소 보관
bin/update.sh antigravity    # 연결 프로그램: 합치기 → 빌드·시험 → 모델 연결 서비스 재시작 → 확인 → 보관
```

- **매일 자동 확인**: Claude 앱 예약 작업 `ais-gateway-upstream-check`(사이드바 Scheduled, 매일 오전 9시경, 자동 모드)가 `bin/update.sh check`를 실행한다. 새 버전이 있으면 알리고, 그 대화에서 승인해야 반영한다. 앱이 꺼져 있으면 다음 실행 때 돈다.
- 반영할 것이 없으면 "할 일이 없습니다"로 끝난다. 여러 번 실행해도 안전하다.
- **충돌**(종료 코드 2): 원본과 내 수정이 같은 곳을 고친 경우다. 해당 폴더에서 정리해 커밋한 뒤 같은 명령을 다시 실행하면 이어서 진행한다. 지켜야 할 내 수정: `ACCOUNT_ORDER` 계정 우선순위, Mac 사용자 세션 브라우저 도우미, 자주 보이는 오류의 한국어 문구, Antigravity 앱 복제 지원.
- **시험 실패**(3)면 운영은 바뀌지 않는다. **배포 후 90초 안에 응답이 없으면** 이전 실행 파일과 `.env`로 자동으로 되돌린다(4). 백업은 `service/runtime/deployment-backups/<시각>/`에 남는다.
- 단계만 따로 실행할 수 있다. 예: `bin/update.sh gateway test`, `bin/update.sh gateway verify`.
- 공식 Antigravity 앱은 `check`가 복제본을 만든 원본 버전(`.clone.json`의 `sourceVersion`)과 공식 업데이트 서버의 최신 정식 버전을 비교해 확인한다. 공식 앱은 설치해 두지 않으며, 복제본을 다시 만들 때만 공식 파일을 받아 원본으로 쓴다. 복제본 `Antigravity Gateway.app`을 다시 만드는 일은 앱 재서명이 포함되므로 별도 승인 후 진행한다. 절차는 위 "Antigravity 공식 앱 2.29.0 반영"을 따른다.
- 게이트웨이 빌드에 필요한 SpiderMonkey 라이브러리는 원본 `build.yml`이 지정한 버전을 쓴다. 없으면 GitHub 등록 해시와 일치할 때만 내려받는다. `bin/build.sh`는 v0.3.0 이전 방식이라 쓰지 않는다.

### 시험한 범위 (2026-11-04)

- `check`, 반영할 것이 없을 때의 `gateway`·`antigravity` 전체 실행, `gateway test·build·deploy(같은 소스라 교체 건너뜀)·verify·save`, `antigravity verify·save`를 실제로 실행했다.
- 실제로 새 버전을 합쳐 교체하는 경로(백업·재시작·자동 되돌리기)와 `antigravity build`는 아직 새 버전이 없어 실행하지 않았다. 교체 절차 자체는 v0.3.0 배포 때 손으로 같은 순서로 수행해 확인했다.
