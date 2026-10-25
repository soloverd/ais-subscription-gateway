#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL=io.ais-subscription-gateway.browser-host
SOURCE="$ROOT/service/launchd/$LABEL.plist"
DESTINATION="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
if [[ "$EUID" -eq 0 ]]; then
  echo '로그인한 Mac 사용자로 실행하세요. sudo는 사용하지 않습니다.' >&2
  exit 1
fi
/usr/bin/plutil -lint "$SOURCE"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$SOURCE")" == "$LABEL" ]]
if [[ -e "$DESTINATION" ]] || /bin/launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  echo '로그인 도우미가 이미 등록되어 있습니다. 기존 설정을 덮어쓰지 않습니다.' >&2
  exit 1
fi
/bin/mkdir -p "$HOME/Library/LaunchAgents"
/usr/bin/install -m 600 "$SOURCE" "$DESTINATION"
if ! /bin/launchctl bootstrap "$DOMAIN" "$DESTINATION"; then
  /bin/rm -f "$DESTINATION"
  echo '현재 GUI 로그인 세션에 도우미를 등록하지 못했습니다.' >&2
  exit 1
fi
echo '사용자 로그인 도우미를 등록했습니다. 로그아웃하면 종료되고 다음 GUI 로그인 때 다시 실행됩니다.'
