#!/bin/bash
# Renders icon.svg (128px and up) and icon-small.svg (under 128px) into TAKO.icns.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

render() {
  printf '<!doctype html><style>html,body{margin:0;background:transparent}img{display:block}</style><img src="file://%s" width=1024 height=1024>' "$HERE/$1" > "$WORK/page.html"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$WORK/chrome" --force-device-scale-factor=1 \
    --default-background-color=00000000 --allow-file-access-from-files --window-size=1024,1024 --screenshot="$WORK/$2" "file://$WORK/page.html" 2>/dev/null
}
render icon.svg big.png
render icon-small.svg small.png

SET="$WORK/TAKO.iconset"
mkdir "$SET"
scale() { sips -z "$2" "$2" "$WORK/$1" --out "$SET/$3" >/dev/null; }
scale small.png 16 icon_16x16.png
scale small.png 32 icon_16x16@2x.png
scale small.png 32 icon_32x32.png
scale small.png 64 icon_32x32@2x.png
scale big.png 128 icon_128x128.png
scale big.png 256 icon_128x128@2x.png
scale big.png 256 icon_256x256.png
scale big.png 512 icon_256x256@2x.png
scale big.png 512 icon_512x512.png
cp "$WORK/big.png" "$SET/icon_512x512@2x.png"
iconutil -c icns "$SET" -o "$HERE/TAKO.icns"
