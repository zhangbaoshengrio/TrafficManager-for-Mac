#!/usr/bin/env bash
#
# 打出可分发的 TrafficMonitor-<版本>.dmg。
#
# 产物是标准的「拖进 Applications」样式：磁盘映像里放 TrafficMonitor.app
# 和一个指向 /Applications 的软链接，UDZO 压缩。
#
# 用法:
#   Scripts/make-dmg.sh              # 产出 ./dist/TrafficMonitor-0.3.0.dmg
#   Scripts/make-dmg.sh ~/Desktop
set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="${1:-dist}"
CONST="Sources/Utilities/Constants.swift"
VERSION=$(sed -n 's/.*appVersion = "\(.*\)".*/\1/p' "$CONST")
: "${VERSION:?无法从 $CONST 解析 appVersion}"

DMG="$OUT_DIR/TrafficMonitor-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "▸ 构建 .app"
Scripts/make-app.sh "$STAGE" > /dev/null

echo "▸ 布置磁盘映像内容"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$OUT_DIR"
rm -f "$DMG"

echo "▸ 生成 $DMG"
hdiutil create \
    -volname "TrafficMonitor $VERSION" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -quiet \
    "$DMG"

SIZE=$(du -h "$DMG" | cut -f1 | tr -d ' ')
echo "✓ $DMG  ($SIZE)"
echo
echo "  未做公证，接收方首次打开需右键 → 打开，或："
echo "    xattr -dr com.apple.quarantine /Applications/TrafficMonitor.app"
