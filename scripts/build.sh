#!/bin/sh
set -eu
UXUY_WEB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 "$UXUY_WEB_ROOT/scripts/verify-parity.py"
cd "$UXUY_WEB_ROOT"
node scripts/build-local-log.mjs
cd "$UXUY_WEB_ROOT/frontend/web"
set -- pub get --enforce-lockfile
if [ "${UXUY_PUB_OFFLINE:-0}" = 1 ] || { [ -z "${PUB_CACHE:-}" ] && [ -d "$UXUY_WEB_ROOT/.tooling/pub-cache/hosted" ] && [ -x "$UXUY_WEB_ROOT/.tooling/flutter-3.47.6/flutter/bin/flutter" ]; }; then
  set -- "$@" --offline
fi
"$UXUY_WEB_ROOT/scripts/flutter.sh" "$@"
"$UXUY_WEB_ROOT/scripts/flutter.sh" analyze --no-pub
"$UXUY_WEB_ROOT/scripts/flutter.sh" build web --release --no-pub --no-web-resources-cdn
python3 "$UXUY_WEB_ROOT/scripts/version-material-icons.py"
