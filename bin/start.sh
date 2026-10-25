#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
umask 077
cd "$ROOT/service"
exec "$ROOT/service/aistudio2api" -open-ui=false "$@"
