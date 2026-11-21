#!/bin/sh
set -eu
UXUY_WEB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$UXUY_WEB_ROOT"
if [ ! -f frontend/web/build/web/index.html ]; then
  if [ ! -f node_modules/vite/package.json ]; then
    npm ci
  fi
  sh scripts/build.sh
fi
exec node scripts/serve.mjs
