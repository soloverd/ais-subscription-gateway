#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/toolchain/go/bin:$PATH"
umask 077
cd "$ROOT/upstream/web"
npm ci
# User approved removing quarantine only inside this isolated project.
if [[ "$(uname -s)" == Darwin ]]; then
  xattr -dr com.apple.quarantine "$ROOT/upstream/web/node_modules"
fi
npm run build
cd "$ROOT/upstream"
for pkg in config aistudio app; do
  go test -mod=readonly -c -o "$ROOT/bin/$pkg.test" "./internal/$pkg"
  if [[ "$(uname -s)" == Darwin ]]; then
    xattr -d com.apple.quarantine "$ROOT/bin/$pkg.test" 2>/dev/null || true
  fi
  "$ROOT/bin/$pkg.test" -test.timeout=180s
done
go build -mod=readonly -trimpath -o "$ROOT/service/aistudio2api" ./cmd/aistudio2api
if [[ "$(uname -s)" == Darwin ]]; then
  xattr -d com.apple.quarantine "$ROOT/service/aistudio2api" 2>/dev/null || true
fi
