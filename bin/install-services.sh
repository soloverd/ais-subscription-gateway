#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$ROOT/service/launchd"
LABELS=(io.ais-subscription-gateway.gateway io.ais-subscription-gateway.models io.ais-subscription-gateway.tailscale)
if [[ "$EUID" -ne 0 ]]; then
  echo '시스템 서비스 등록에는 macOS 관리자 승인이 필요합니다.' >&2
  exit 1
fi
# 기존 서비스나 다른 프로젝트를 덮어쓰지 않는다. 먼저 전체 입력을 검사한다.
for label in "${LABELS[@]}"; do
  source="$STAGE/$label.plist"
  destination="/Library/LaunchDaemons/$label.plist"
  /usr/bin/plutil -lint "$source"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$source")" == "$label" ]]
  owner="$(/usr/libexec/PlistBuddy -c 'Print :UserName' "$source")"
  [[ -n "$owner" && "$owner" != root ]]
  if [[ -e "$destination" ]] || /bin/launchctl print "system/$label" >/dev/null 2>&1; then
    echo "이미 등록된 서비스입니다. 덮어쓰지 않습니다: $label" >&2
    exit 1
  fi
done
for port in 2048 50999; do
  if /usr/sbin/lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "기존 프로젝트 프로세스를 정상 종료한 뒤 다시 실행하세요: 포트 $port" >&2
    exit 1
  fi
done
if /usr/sbin/lsof "$ROOT/service/tailscale/tailscaled.sock" >/dev/null 2>&1; then
  echo '임시 프로젝트 Tailscale 프로세스를 먼저 정상 종료하세요. 기존 Mac Tailscale 앱은 종료하지 않습니다.' >&2
  exit 1
fi
installed=()
rollback() {
  local status=$?
  trap - ERR
  set +u
  for label in "${installed[@]}"; do
    /bin/launchctl bootout "system/$label" >/dev/null 2>&1 || true
    /bin/rm -f "/Library/LaunchDaemons/$label.plist"
  done
  echo '설치가 실패해 이번에 등록한 시스템 서비스만 되돌렸습니다.' >&2
  exit "$status"
}
trap rollback ERR
for label in "${LABELS[@]}"; do
  installed+=("$label")
  /usr/bin/install -o root -g wheel -m 644 "$STAGE/$label.plist" "/Library/LaunchDaemons/$label.plist"
  /bin/launchctl bootstrap system "/Library/LaunchDaemons/$label.plist"
done
trap - ERR
echo '프로젝트 시스템 서비스 3개를 등록했습니다. 실제 상태·접근 인증·모델 호출 검증은 별도로 확인해야 합니다.'
