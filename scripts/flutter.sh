#!/bin/sh
set -eu
UXUY_WEB_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
UXUY_WEB_TOOLS="$UXUY_WEB_ROOT/.tooling"
pinned_bin="$UXUY_WEB_TOOLS/flutter-3.47.6/flutter/bin"
if [ -x "$pinned_bin/flutter" ]; then
  export PATH="$pinned_bin:$PATH"
  export PUB_CACHE="${PUB_CACHE:-$UXUY_WEB_TOOLS/pub-cache}"
  export XDG_CONFIG_HOME="$UXUY_WEB_TOOLS/config"
  export XDG_CACHE_HOME="$UXUY_WEB_TOOLS/cache"
  export TMPDIR="$UXUY_WEB_TOOLS/tmp/"
  export GRADLE_USER_HOME="$UXUY_WEB_TOOLS/gradle"
  mkdir -p "$PUB_CACHE" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$TMPDIR"
elif ! command -v flutter >/dev/null 2>&1; then
  echo 'Install Flutter 3.47.6 and put flutter on PATH.' >&2
  exit 127
fi
export FLUTTER_SUPPRESS_ANALYTICS=true
export DART_SUPPRESS_ANALYTICS=true
export CI=true
exec flutter "$@"
