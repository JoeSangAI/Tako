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
  -o "$WORK/Tako" "$ROOT"/Sources/native/*.swift

APP="$WORK/Tako.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$WORK/Tako" "$APP/Contents/MacOS/Tako"
# Everything the Python side is made of: a new module can't be left out by accident.
cp "$ROOT/icon/TAKO.icns" "$ROOT"/Sources/brain/*.py "$ROOT/Sources/brain/side.html" "$ROOT/CHANGELOG.md" "$APP/Contents/Resources/"
cp "$ROOT"/Sources/art/*.png "$APP/Contents/Resources/"   # pieces of outfits cut from drawings (the whale girl's apron, tail, spout)
cp -R "$ROOT/Sources/brain/vendor" "$APP/Contents/Resources/vendor"
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
# TAKO_SIGN_IDENTITY names another certificate, such as a self-signed one made once in Keychain Access (docs/BUILDING.md):
# any certificate that stays the same keeps the permissions; ad hoc, each build is a new app to the system.
IDENTITY="${TAKO_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}"
SIGN="${IDENTITY:--}"
[ "$SIGN" = "-" ] && echo "note: no signing identity on this Mac; ad-hoc build: Screen Recording and Accessibility must be switched on again after every rebuild, and one-click update is off. See docs/BUILDING.md for a free certificate that keeps them." >&2
# A signature differs every time it is made, so the Python is signed once and reused: the same bytes in every
# release are what let an installed Tako keep the Python it has and fetch only the rest.
SIGNED="$ROOT/.build/signed-python/$(printf '%s' "$(ls -A "$ROOT/.build/python" | grep '^\.tako-')$SIGN" | shasum | cut -c1-16)"
if [ ! -f "$SIGNED.id" ]; then
  rm -rf "$ROOT/.build/signed-python"
  mkdir -p "$ROOT/.build/signed-python"
  cp -R "$ROOT/.build/python" "$SIGNED"
  find "$SIGNED" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0 |
    while IFS= read -r -d '' file; do
      if file -b "$file" | grep -q 'Mach-O'; then codesign --force --sign "$SIGN" "$file" 2>/dev/null; fi
    done
  (cd "$SIGNED" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1) > "$SIGNED.id"
fi
cp -R "$SIGNED" "$APP/Contents/Resources/python"
cp "$SIGNED.id" "$APP/Contents/Resources/python.id"
codesign --force --sign "$SIGN" --identifier com.joesang.tako "$APP"
codesign --verify --strict "$APP"

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
ditto "$APP" "$OUT"
