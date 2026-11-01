#!/bin/bash
# Builds Tako.app from this checkout. Usage: scripts/build_app.sh /path/to/Tako.app
# Signed with the same identity every time, so macOS keeps its permissions across versions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$1"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
MINIMUM="14.0"

"$ROOT/scripts/fetch_python.sh"

# Built aside first: a compile error must not break what is already installed.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -O -target "arm64-apple-macos$MINIMUM" -framework AppKit -framework WebKit -framework ApplicationServices -framework QuartzCore -framework CoreImage \
  -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia -framework Vision -framework Carbon -framework UserNotifications \
  -o "$WORK/Tako" "$ROOT"/Sources/*.swift

APP="$WORK/Tako.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$WORK/Tako" "$APP/Contents/MacOS/Tako"
cp "$ROOT/icon/TAKO.icns" "$ROOT/Sources/tako_server.py" "$ROOT/Sources/codex_runtime.py" "$ROOT/Sources/wechat_reader.py" "$ROOT/Sources/listen_worker.py" "$ROOT/Sources/side.html" "$ROOT/CHANGELOG.md" "$APP/Contents/Resources/"
cp -R "$ROOT/Sources/vendor" "$APP/Contents/Resources/vendor"
cp -R "$ROOT/.build/python" "$APP/Contents/Resources/python"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.joesang.tako</string>
  <key>CFBundleName</key><string>Tako</string>
  <key>CFBundleDisplayName</key><string>Tako</string>
  <key>CFBundleExecutable</key><string>Tako</string>
  <key>CFBundleIconFile</key><string>TAKO</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MINIMUM</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key><string>黏在哪里，哪里就有了智能。</string>
  <key>NSAppleEventsUsageDescription</key><string>Tako 按你的要求操作这个窗口里的文档。</string>
  <key>NSDesktopFolderUsageDescription</key><string>你让 Tako 处理桌面上的文件时要用到，它做好的东西也默认放在桌面。</string>
  <key>NSDocumentsFolderUsageDescription</key><string>你让 Tako 处理文稿里的文件时要用到。</string>
  <key>NSDownloadsFolderUsageDescription</key><string>你让 Tako 处理下载里的文件时要用到。</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST

# Inside out: every library the Python carries, then the app that seals them.
IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)"
SIGN="${IDENTITY:--}"
[ "$SIGN" = "-" ] && echo "note: no signing identity on this Mac; ad-hoc build, permissions won't survive rebuilds and one-click update is off." >&2
find "$APP/Contents/Resources/python" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0 |
  while IFS= read -r -d '' file; do
    if file -b "$file" | grep -q 'Mach-O'; then codesign --force --sign "$SIGN" "$file" 2>/dev/null; fi
  done
codesign --force --sign "$SIGN" --identifier com.joesang.tako "$APP"
codesign --verify --strict "$APP"

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
ditto "$APP" "$OUT"
