#!/bin/bash
# Turns VERSION + CHANGELOG.md into a GitHub release that every installed Tako will offer.
# Normally runs by itself from .githooks/pre-push: bump VERSION, write the changelog, git push.
#   scripts/release.sh build              tests, public check, build, zip, latest.json in dist/
#   scripts/release.sh publish <commit>   waits for the commit on GitHub, then creates the release
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="JoeSangAI/Tako"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
DIST="$ROOT/dist"

notes() {
  /usr/bin/awk -v v="$VERSION" '$1=="##"{if($2==v){on=1;next}else if(on){exit}} on' "$ROOT/CHANGELOG.md" | sed '/./,$!d'
}

case "${1:-}" in
  build)
    [ -n "$(notes)" ] || { echo "CHANGELOG.md has no section for $VERSION" >&2; exit 1; }
    "$ROOT/scripts/fetch_python.sh"
    "$ROOT/.build/python/bin/python3" -B "$ROOT/tests/test_guards.py" 2>&1 | tail -1 | grep -q '^OK' || { echo "guard tests failed" >&2; exit 1; }
    "$ROOT/scripts/check_public.sh"
    rm -rf "$DIST"
    mkdir -p "$DIST"
    "$ROOT/scripts/build_app.sh" "$DIST/Tako.app" 2>/dev/null
    codesign --verify --strict "$DIST/Tako.app"
    # Installed copies accept only this identity: anything else would strand everyone on the old version.
    codesign -dv "$DIST/Tako.app" 2>&1 | grep -q '^TeamIdentifier=3BVM9N9HS4$' || { echo "not signed by the release identity: renew the Apple Development certificate first" >&2; exit 1; }
    (cd "$DIST" && ditto -c -k --keepParent Tako.app Tako.zip)
    SHA="$(shasum -a 256 "$DIST/Tako.zip" | cut -d' ' -f1)"
    notes > "$DIST/notes.md"
    VERSION="$VERSION" SHA="$SHA" REPO="$REPO" DIST="$DIST" "$ROOT/.build/python/bin/python3" - <<'PY'
import json, os
dist = os.environ["DIST"]
json.dump({"version": os.environ["VERSION"], "sha256": os.environ["SHA"], "notes": open(f"{dist}/notes.md").read().strip(),
           "zip": f"https://github.com/{os.environ['REPO']}/releases/download/v{os.environ['VERSION']}/Tako.zip"},
          open(f"{dist}/latest.json", "w"), ensure_ascii=False, indent=1)
PY
    echo "built Tako $VERSION: $(du -h "$DIST/Tako.zip" | cut -f1)"
    ;;
  publish)
    COMMIT="$2"
    for _ in $(seq 1 90); do
      [ "$(git -C "$ROOT" ls-remote origin refs/heads/main | cut -f1)" = "$COMMIT" ] && break
      sleep 2
    done
    [ "$(git -C "$ROOT" ls-remote origin refs/heads/main | cut -f1)" = "$COMMIT" ] || { echo "$COMMIT never reached GitHub" >&2; exit 1; }
    gh release create "v$VERSION" "$DIST/Tako.zip" "$DIST/latest.json" --repo "$REPO" --target "$COMMIT" --title "Tako $VERSION" --notes-file "$DIST/notes.md"
    ;;
  *) sed -n 2,5p "$0"; exit 2 ;;
esac
