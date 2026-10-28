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
- `upstream/`: `local/preserve-implemented-work`, 보존 기준 `25d264b` (계정 우선순위 `415700d` 포함). 기존 번역 15개와 QUIC 임시 수정 1개 파일은 원래 checkout에 그대로 보존했다. 현재 운영 실행 파일의 소스는 아래 통합 worktree 기준이다.
- `integrations/antigravity-add-model/`: `local/preserve-implemented-work`, 보존 기준 `228f0db` (테스트 환경 분리 `1296b41` 포함).
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
