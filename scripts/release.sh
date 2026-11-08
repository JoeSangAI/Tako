#!/bin/bash
# Turns VERSION + CHANGELOG.md into a GitHub release that every installed Tako will offer.
# Normally runs by itself from .githooks/pre-push: bump VERSION, write the changelog, git push.
#   scripts/release.sh build              tests, public check, build, zip, latest.json in dist/
#   scripts/release.sh publish <commit>   waits for the commit on GitHub, then publishes (re-run to finish one that stopped)
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
    mkdir -p "$ROOT/.local/release-tests"
    for suite in test_guards test_first_run test_turns test_codex_log test_outfit; do
      log="$ROOT/.local/release-tests/$suite.log"
      if ! "$ROOT/.build/python/bin/python3" -B -W ignore "$ROOT/tests/$suite.py" > "$log" 2>&1 || ! tail -1 "$log" | grep -q '^OK'; then
        echo "$suite failed: nothing goes out. Whole output: $log" >&2
        grep -E '^(FAIL|ERROR):' "$log" >&2 || tail -5 "$log" >&2
        exit 1
      fi
    done
    "$ROOT/scripts/check_public.sh"
    rm -rf "$DIST"
    mkdir -p "$DIST"
    "$ROOT/scripts/build_app.sh" "$DIST/Tako.app" 2>/dev/null
    codesign --verify --strict "$DIST/Tako.app"
    # Installed copies accept only this identity: anything else would strand everyone on the old version.
    case "$(codesign -dv "$DIST/Tako.app" 2>&1)" in
      *TeamIdentifier=3BVM9N9HS4*) ;;
      *) echo "not signed by the release identity: renew the Apple Development certificate first" >&2; exit 1 ;;
    esac
    (cd "$DIST" && ditto -c -k --keepParent Tako.app Tako.zip)
    SHA="$(shasum -a 256 "$DIST/Tako.zip" | cut -d' ' -f1)"
    # What an installed Tako with this same Python fetches: about 1 MB instead of the whole thing.
    SMALL="$(mktemp -d)"
    ditto "$DIST/Tako.app" "$SMALL/Tako.app"
    rm -rf "$SMALL/Tako.app/Contents/Resources/python"
    (cd "$SMALL" && ditto -c -k --keepParent Tako.app "$DIST/Tako-update.zip")
    rm -rf "$SMALL"
    SMALL_SHA="$(shasum -a 256 "$DIST/Tako-update.zip" | cut -d' ' -f1)"
    notes > "$DIST/notes.md"
    VERSION="$VERSION" SHA="$SHA" SMALL_SHA="$SMALL_SHA" REPO="$REPO" DIST="$DIST" "$ROOT/.build/python/bin/python3" - <<'PY'
import json, os
dist = os.environ["DIST"]
base = f"https://github.com/{os.environ['REPO']}/releases/download/v{os.environ['VERSION']}"
json.dump({"version": os.environ["VERSION"], "sha256": os.environ["SHA"], "notes": open(f"{dist}/notes.md").read().strip(),
           "zip": f"{base}/Tako.zip",
           "patch": {"zip": f"{base}/Tako-update.zip", "sha256": os.environ["SMALL_SHA"],
                     "python": open(f"{dist}/Tako.app/Contents/Resources/python.id").read().strip()}},
          open(f"{dist}/latest.json", "w"), ensure_ascii=False, indent=1)
PY
    echo "built Tako $VERSION: $(du -h "$DIST/Tako.zip" | cut -f1), update $(du -h "$DIST/Tako-update.zip" | cut -f1)"
    ;;
  publish)
    # The uplink here can be ~25 KB/s and GitHub drops an upload that stalls (HTTP 408), so the 20 MB whole app is the part that fails.
    # A relay with a fast uplink makes all of it take seconds; without one, the 1 MB update that installed copies fetch goes public first
    # and the whole app follows with retries.
    # Until it lands, latest.json sends new installs and a changed Python to the previous whole app, which then offers this update.
    # Safe to run again: it picks up where it stopped.
    COMMIT="$(git -C "$ROOT" rev-parse "$2")"
    for _ in $(seq 1 90); do
      [ "$(git -C "$ROOT" ls-remote origin refs/heads/main | cut -f1)" = "$COMMIT" ] && break
      sleep 2
    done
    [ "$(git -C "$ROOT" ls-remote origin refs/heads/main | cut -f1)" = "$COMMIT" ] || { echo "$COMMIT never reached GitHub" >&2; exit 1; }
    TAG="v$VERSION"
    say() { echo "$(date '+%H:%M:%S') $1"; }
    tell() { osascript -e "display notification \"$1\" with title \"Tako 发布\"" >/dev/null 2>&1 || true; }
    # What GitHub holds for this release, by name and content: a re-run uploads only what is missing, cut short or different.
    holds() { gh api "repos/$REPO/releases/$RELEASE_ID/assets" --paginate --jq '.[] | select(.state=="uploaded") | "\(.name) \(.digest)"' 2>/dev/null || true; }
    has() { holds | grep -qx "$(basename "$1") sha256:$(shasum -a 256 "$1" | cut -d' ' -f1)"; }
    # A machine with a fast uplink, reached over ssh, carries the bytes when it answers (its host in .local/release-relay, never in the repo).
    # The token goes to it on stdin, never on a command line; the file is gone from it afterwards.
    RELAY="${TAKO_RELEASE_RELAY:-$(tr -d '[:space:]' < "$ROOT/.local/release-relay" 2>/dev/null || true)}"
    via_relay() {
      local file="$1" name type id
      name="$(basename "$file")"
      [ -n "$RELAY" ] && ssh -o ConnectTimeout=8 -o BatchMode=yes "$RELAY" true 2>/dev/null || return 1
      say "uploading $name ($(du -h "$file" | cut -f1)) through $RELAY"
      scp -q -o BatchMode=yes "$file" "$RELAY:/tmp/tako-release-$name" || return 1
      for id in $(gh api "repos/$REPO/releases/$RELEASE_ID/assets" --paginate --jq ".[] | select(.name==\"$name\") | .id" 2>/dev/null || true); do
        gh api -X DELETE "repos/$REPO/releases/assets/$id" >/dev/null 2>&1 || true
      done
      case "$name" in *.zip) type=application/zip ;; *.json) type=application/json ;; *) type=application/octet-stream ;; esac
      printf 'Authorization: Bearer %s\n' "$(gh auth token)" | ssh -o BatchMode=yes "$RELAY" \
        "curl -sS --fail --max-time 900 -o /dev/null -H @- -H 'Content-Type: $type' --data-binary @/tmp/tako-release-$name 'https://uploads.github.com/repos/$REPO/releases/$RELEASE_ID/assets?name=$name'; s=\$?; rm -f /tmp/tako-release-$name; exit \$s"
    }
    upload() {  # file: tries until GitHub holds it whole; a stalled try is killed rather than waited on
      local file="$1" try
      for try in 1 2 3 4 5 6; do
        has "$file" && return 0
        if via_relay "$file"; then has "$file" && return 0; fi
        say "uploading $(basename "$file") ($(du -h "$file" | cut -f1)) from here, try $try"
        gh release upload "$TAG" "$file" --clobber --repo "$REPO" & local pid=$!
        ( sleep 2400; kill "$pid" 2>/dev/null ) & local watch=$!
        wait "$pid" 2>/dev/null || true
        kill "$watch" 2>/dev/null || true; wait "$watch" 2>/dev/null || true
        has "$file" && return 0
        sleep $((try * 15))
      done
      say "gave up on $(basename "$file")"; return 1
    }
    RELEASE_ID="$(gh api "repos/$REPO/releases?per_page=20" --jq ".[] | select(.name==\"Tako $VERSION\") | .id" | head -1)"
    if [ -z "$RELEASE_ID" ]; then
      gh release create "$TAG" --draft --repo "$REPO" --target "$COMMIT" --title "Tako $VERSION" --notes-file "$DIST/notes.md" >/dev/null
      RELEASE_ID="$(gh api "repos/$REPO/releases?per_page=20" --jq ".[] | select(.name==\"Tako $VERSION\") | .id" | head -1)"
    fi
    [ -n "$RELEASE_ID" ] || { echo "could not create the release" >&2; exit 1; }
    FIRST="$(mktemp -d)"
    trap 'rm -rf "$FIRST"' EXIT
    if [ "$(gh api "repos/$REPO/releases/$RELEASE_ID" --jq .draft)" = "true" ]; then
      # The previous whole app stands in for this one until it is up, if it has the same Python: then it takes this update straight after.
      if gh release download --repo "$REPO" --pattern latest.json --dir "$FIRST/previous" >/dev/null 2>&1 &&
        "$ROOT/.build/python/bin/python3" - "$DIST/latest.json" "$FIRST/previous/latest.json" "$FIRST/latest.json" <<'PY'
import json, sys
mine, previous = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
if (previous.get("patch") or {}).get("python") != mine["patch"]["python"]:
    sys.exit(1)
mine["zip"], mine["sha256"] = previous["zip"], previous["sha256"]
json.dump(mine, open(sys.argv[3], "w"), ensure_ascii=False, indent=1)
PY
      then :
      else
        upload "$DIST/Tako.zip" || exit 1   # nothing earlier can stand in: the whole app has to be there first
        cp "$DIST/latest.json" "$FIRST/latest.json"
      fi
      upload "$DIST/Tako-update.zip" || exit 1
      has "$FIRST/latest.json" || upload "$FIRST/latest.json" || exit 1
      gh release edit "$TAG" --draft=false --latest --repo "$REPO" >/dev/null
      say "Tako $VERSION is out: installed copies get the update now"
      tell "Tako $VERSION 已发布，装过的人会收到提示。"
    fi
    upload "$DIST/Tako.zip" || { tell "Tako $VERSION 的完整安装包没传上，新装的人暂时拿到上一版。重跑 scripts/release.sh publish $COMMIT"; exit 1; }
    upload "$DIST/latest.json" || exit 1
    say "Tako $VERSION complete: the whole app is up too"
    ;;
  *) sed -n 2,5p "$0"; exit 2 ;;
esac
