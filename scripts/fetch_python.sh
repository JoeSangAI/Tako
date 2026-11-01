#!/bin/bash
# The Python that ships inside Tako: a pinned standalone build, checked by hash, trimmed, kept in .build/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE="20261026"
NAME="cpython-3.12.16+$RELEASE-aarch64-apple-darwin-install_only_stripped.tar.gz"
SHA256="353d5f1b4fd2715e7053f12f068435d5bbad16b91e057006b5d01e0925709a7e"
OUT="$ROOT/.build/python"
STAMP="$OUT/.tako-$SHA256"

[ -f "$STAMP" ] && exit 0

mkdir -p "$ROOT/.build"
ARCHIVE="$ROOT/.build/$NAME"
if [ ! -f "$ARCHIVE" ] || ! echo "$SHA256  $ARCHIVE" | shasum -a 256 -c - >/dev/null 2>&1; then
  curl -fL --retry 3 -o "$ARCHIVE" "https://github.com/astral-sh/python-build-standalone/releases/download/$RELEASE/$NAME"
  echo "$SHA256  $ARCHIVE" | shasum -a 256 -c -
fi
rm -rf "$OUT"
mkdir -p "$OUT"
tar -xzf "$ARCHIVE" -C "$OUT" --strip-components 1

# Only for the optional local WeChat reader; everything else Tako runs on is the standard library.
"$OUT/bin/python3" -m pip install --quiet --disable-pip-version-check --no-compile "pycryptodome==3.23.0" "zstandard==0.25.0"

LIB="$OUT/lib/python3.12"
rm -rf "$LIB/test" "$LIB/idlelib" "$LIB/tkinter" "$LIB/turtledemo" "$LIB/ensurepip" "$LIB/site-packages/pip" "$LIB"/site-packages/pip-* "$LIB/lib2to3" \
  "$OUT/lib/itcl"* "$OUT/lib/tcl"* "$OUT/lib/tk"* "$OUT/lib/thread"* "$OUT/lib/libtcl"* "$OUT/lib/libtk"* "$OUT/include" "$OUT/share" "$OUT/bin/idle"* "$OUT/bin/pip"* "$OUT/bin/2to3"* "$OUT/bin/pydoc"*
find "$OUT" -name '__pycache__' -type d -prune -exec rm -rf {} +
find "$LIB" -name '*.a' -delete
# Compiled ahead: nothing may be written inside a signed app, and startup shouldn't pay for it every time.
"$OUT/bin/python3" -m compileall -q --invalidation-mode unchecked-hash "$LIB" >/dev/null || true
touch "$STAMP"
