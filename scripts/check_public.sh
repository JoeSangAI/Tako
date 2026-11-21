#!/bin/bash
# Without arguments, preflight the tracked working files. With --commits, check Git objects.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DENY=.local/deny.txt
if [ ! -r "$DENY" ] || [ ! -f "$DENY" ]; then
  echo "public check: place the private word list at $ROOT/$DENY" >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  if [ "$1" != --commits ] || [ "$#" -lt 2 ]; then
    echo "usage: scripts/check_public.sh [--commits <commit-or-tag>...]" >&2
    exit 2
  fi
  shift
fi

# Read blobs directly so checkout filters, archive attributes and the index cannot change what is checked.
summary="$(python3 - "$DENY" "$@" <<'PY'
import os
import re
import subprocess
import sys
from pathlib import Path

deny = tuple(word for word in Path(sys.argv[1]).read_bytes().splitlines() if word)
if not deny:
    sys.exit("public check: .local/deny.txt has no private words")

generic = re.compile(rb"/Users/[A-Za-z]|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}")
checker = b"scripts/check_public.sh"
failed = False
blob_results = {}
visited = set()
files = 0

def git(*args):
    return subprocess.check_output(["git", "--no-replace-objects", *args])

def check(data, *, allow_checker_pattern=False):
    private_word = any(word in data for word in deny)
    if allow_checker_pattern:
        data = data.replace(generic.pattern, b"", 1)
    return private_word or bool(generic.search(data))

def report(label, kind, path=None):
    global failed
    failed = True
    location = f" in {os.fsdecode(path)!r}" if path is not None else ""
    print(f"public check: {label}: {kind}{location}", file=sys.stderr)

def check_file(label, name, *, oid=None):
    global files
    files += 1
    if check(name):
        report(label, "private file name")
        name_for_report = None
    else:
        name_for_report = name
    if oid is None:
        path = Path(os.fsdecode(name))
        data = os.fsencode(os.readlink(path)) if path.is_symlink() else path.read_bytes()
        hit = check(data, allow_checker_pattern=(name == checker))
    else:
        key = (oid, name == checker)
        if key not in blob_results:
            data = git("cat-file", "blob", oid)
            blob_results[key] = check(data, allow_checker_pattern=key[1])
        hit = blob_results[key]
    if hit:
        report(label, "private file content", name_for_report)

def check_object(revision):
    oid = git("rev-parse", "--verify", "--end-of-options", revision).strip().decode("ascii")
    if oid in visited:
        return
    visited.add(oid)
    kind = git("cat-file", "-t", oid).strip()
    if kind not in (b"tag", b"commit"):
        sys.exit(f"public check: {oid} does not refer to a commit or tag")
    data = git("cat-file", kind.decode("ascii"), oid)
    # Headers contain public Git identity and object metadata. Scan the annotation or commit message.
    if check(data.partition(b"\n\n")[2]):
        report(oid, "private commit or tag message")
    if kind == b"tag":
        check_object(data.splitlines()[0].split()[1].decode("ascii"))
        return
    for entry in git("ls-tree", "-rz", "--full-tree", oid).split(b"\0"):
        if not entry:
            continue
        meta, name = entry.split(b"\t", 1)
        _, obj_type, obj_id = meta.split()
        if obj_type == b"blob":
            check_file(oid, name, oid=obj_id.decode("ascii"))
        elif check(name):
            report(oid, "private file name")

revisions = sys.argv[2:]
if revisions:
    for revision in revisions:
        check_object(revision)
else:
    for name in filter(None, git("ls-files", "-z").split(b"\0")):
        path = Path(os.fsdecode(name))
        if path.is_symlink() or path.is_file():
            check_file("worktree", name)
        elif check(name):
            report("worktree", "private file name")
if failed:
    sys.exit(1)
scope = f"{len(visited)} Git objects, {files} file entries" if revisions else f"{files} tracked files"
print(f"public check: clean ({scope})")
PY
)"

if command -v gitleaks >/dev/null 2>&1; then
  if [ "$#" -gt 0 ]; then
    commits=()
    for revision in "$@"; do
      commits+=("$(git --no-replace-objects rev-parse --verify --end-of-options "$revision^{commit}")")
    done
    gitleaks detect --no-banner --redact --source . --log-opts="--no-walk -m ${commits[*]}" >/dev/null 2>&1 || {
      echo "public check: gitleaks reported a finding or failed on the selected commits" >&2
      exit 1
    }
  else
    gitleaks detect --no-banner --redact --source . >/dev/null 2>&1 || {
      echo "public check: gitleaks reported a finding or failed on repository history" >&2
      exit 1
    }
  fi
fi
printf '%s\n' "$summary"
