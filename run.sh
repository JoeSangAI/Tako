#!/bin/bash
# For developing Tako: builds this checkout into /Applications and restarts it. Usage: ./run.sh ["part of a chat name"]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/Tako.app"
BINARY="$APP/Contents/MacOS/Tako"

# A restart kills whatever job the owner has going (it happened 2026-11-04). Wait for it to end, or say TAKO_FORCE=1.
if [ -z "${TAKO_FORCE:-}" ] && pgrep -x Tako >/dev/null; then
  # Only jobs begun by the Tako running now: one that was killed keeps saying 在做 forever. Its brain rewrites agent.json on every start.
  BUSY="$(/usr/bin/python3 -c 'import json,os,sys,time
home=os.environ.get("TAKO_HOME") or os.path.expanduser("~/Library/Application Support/Tako")
try: jobs, began = json.load(open(os.path.join(home,"asked.json"))), os.path.getmtime(os.path.join(home,"agent.json"))
except Exception: sys.exit()
print(" ".join(j.get("where","") for j in jobs if j.get("ended")=="在做" and float(j.get("at",0))>began-5 and time.time()-float(j.get("at",0))<1800))' 2>/dev/null || true)"
  if [ -n "$BUSY" ]; then
    echo "Tako 正在做事（$BUSY），重启会打断它。等它做完再跑，或者 TAKO_FORCE=1 ./run.sh。" >&2
    exit 1
  fi
fi

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
