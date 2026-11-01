#!/bin/bash
# For developing Tako: builds this checkout into /Applications and restarts it. Usage: ./run.sh ["part of a chat name"]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/Tako.app"
BINARY="$APP/Contents/MacOS/Tako"

if pkill -TERM -x Tako; then
  for _ in $(seq 1 25); do pgrep -x Tako >/dev/null || break; sleep 0.2; done
fi

CHANGED="$(find "$HERE/Sources" "$HERE/scripts" "$HERE/icon/TAKO.icns" "$HERE/VERSION" "$HERE/CHANGELOG.md" "$HERE/run.sh" -newer "$BINARY" 2>/dev/null || true)"
if [ ! -x "$BINARY" ] || [ -n "$CHANGED" ]; then
  "$HERE/scripts/build_app.sh" "$APP"
fi

ARGUMENTS=(${TAKO_ARGS:-})
[ -n "${1:-}" ] && ARGUMENTS+=(--chat "$1" "${@:2}")
open "$APP" ${ARGUMENTS[@]+--args "${ARGUMENTS[@]}"}
