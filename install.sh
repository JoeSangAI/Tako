#!/bin/bash
# Installs the latest Tako. curl -fsSL https://raw.githubusercontent.com/JoeSangAI/Tako/main/install.sh | bash
set -euo pipefail

FEED="https://github.com/JoeSangAI/Tako/releases/latest/download/latest.json"
DEST="${TAKO_INSTALL_DIR:-/Applications}"

say() { printf '\033[1m%s\033[0m\n' "$1"; }
stop() { printf '没有装好：%s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || stop "Tako 只支持 Mac。"
[ "$(uname -m)" = "arm64" ] || stop "目前只支持 Apple 芯片的 Mac（M1 及以后）。"
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || stop "需要 macOS 14 或更新，这台是 $(sw_vers -productVersion)。"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say "正在查找最新版本…"
curl -fsSL --retry 3 "$FEED" -o "$WORK/latest.json" || stop "连不上 GitHub，检查网络后再试一次。"
field() { plutil -extract "$1" raw -o - "$WORK/latest.json"; }
VERSION="$(field version)"; ZIP="$(field zip)"; SHA="$(field sha256)"

say "正在下载 Tako $VERSION…"
curl -fL --retry 3 --progress-bar "$ZIP" -o "$WORK/Tako.zip" || stop "下载没有完成，检查网络后再试一次。"
echo "$SHA  $WORK/Tako.zip" | shasum -a 256 -c - >/dev/null 2>&1 || stop "下载的文件不完整，再试一次。"

ditto -x -k "$WORK/Tako.zip" "$WORK/unpacked"
xattr -dr com.apple.quarantine "$WORK/unpacked/Tako.app" 2>/dev/null || true
codesign --verify --strict "$WORK/unpacked/Tako.app" 2>/dev/null || stop "这份安装包的签名不对，没有安装。"

if pgrep -x Tako >/dev/null; then
  say "先关掉正在运行的 Tako…"
  pkill -TERM -x Tako || true
  for _ in $(seq 1 25); do pgrep -x Tako >/dev/null || break; sleep 0.2; done
fi
rm -rf "$DEST/Tako.app"
mv "$WORK/unpacked/Tako.app" "$DEST/Tako.app"

[ -n "${TAKO_NO_OPEN:-}" ] || open "$DEST/Tako.app"
say "Tako $VERSION 装好了，在“$DEST”里。"
echo "系统会问“辅助功能”和“屏幕录制”权限：打开它们，Tako 才能看见和操作窗口。"
echo "接下来把屏幕上的小章鱼拖到任意窗口上松手，或者按 ⌃⌥T。以后的新版本它会自己告诉你。"
echo "测试版会回传匿名统计（只有数字和固定词表，没有你说的话），不想要就右键小章鱼去掉“帮助作者优化”的勾。"
