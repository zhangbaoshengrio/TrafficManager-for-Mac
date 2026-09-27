#!/usr/bin/env bash
#
# 把编译产物组装成一个真正的 TrafficMonitor.app。
#
# 为什么需要这一步：`swift build` 只产出裸可执行文件，此时
# `Bundle.main.bundleIdentifier` 为 nil，而 UNUserNotificationCenter 要求
# 调用方必须有 Bundle ID —— 代码里的告警通知会被 guard 直接跳过。
# 换句话说，**不打包成 .app，告警功能就是静默失效的**。
#
# 用法:
#   Scripts/make-app.sh            # 产出 ./TrafficMonitor.app
#   Scripts/make-app.sh /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${1:-.}"
APP="$DEST/TrafficMonitor.app"

# 版本号与 Bundle ID 的唯一真源在 Constants.swift，这里解析出来写进 Info.plist
CONST="Sources/Utilities/Constants.swift"
VERSION=$(sed -n 's/.*appVersion = "\(.*\)".*/\1/p' "$CONST")
BUNDLE_ID=$(sed -n 's/.*bundleIdentifier = "\(.*\)".*/\1/p' "$CONST")
: "${VERSION:?无法从 $CONST 解析 appVersion}"
: "${BUNDLE_ID:?无法从 $CONST 解析 bundleIdentifier}"

echo "▸ 编译 release"
swift build -c release

echo "▸ 组装 $APP  (v$VERSION, $BUNDLE_ID)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TrafficMonitor "$APP/Contents/MacOS/TrafficMonitor"

# 本地化资源包：SwiftPM 把 .lproj 打进 TrafficMonitor_TrafficMonitor.bundle。
#
# 必须放 Contents/Resources/，**不能**放 Contents/MacOS/ —— 后者会被 codesign
# 当作未签名的嵌套代码而整个签名失败：
#   "code object is not signed at all
#    In subcomponent: .../Contents/MacOS/TrafficMonitor_TrafficMonitor.bundle"
# 放在 Resources 下，Bundle.module 经由 Bundle.main.resourceURL 一样能找到。
BUNDLE=".build/release/TrafficMonitor_TrafficMonitor.bundle"
if [[ -d "$BUNDLE" ]]; then
    cp -R "$BUNDLE" "$APP/Contents/Resources/"
else
    echo "  ⚠️  $BUNDLE 缺失，界面将只有英文兜底"
fi

# 图标：产物已提交在 Resources/，改图标用 Scripts/make-icon.swift 重新生成
ICON_KEY=""
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY="    <key>CFBundleIconFile</key>                     <string>AppIcon</string>"
else
    echo "  ⚠️  Resources/AppIcon.icns 缺失，将使用系统通用图标"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>            <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
    <key>CFBundleExecutable</key>                   <string>TrafficMonitor</string>
    <key>CFBundleIdentifier</key>                   <string>$BUNDLE_ID</string>
$ICON_KEY
    <key>CFBundleInfoDictionaryVersion</key>        <string>6.0</string>
    <key>CFBundleName</key>                         <string>TrafficMonitor</string>
    <key>CFBundleDisplayName</key>                  <string>TrafficMonitor</string>
    <key>CFBundlePackageType</key>                  <string>APPL</string>
    <key>CFBundleShortVersionString</key>           <string>$VERSION</string>
    <key>CFBundleVersion</key>                      <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>               <string>14.0</string>
    <key>LSApplicationCategoryType</key>            <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>              <true/>
    <key>NSSupportsAutomaticTermination</key>       <true/>
    <key>NSSupportsSuddenTermination</key>          <false/>
    <key>NSHumanReadableCopyright</key>             <string>MIT License</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" > /dev/null

# Ad-hoc 签名：让 macOS 认这是一个合法 bundle（本地自用足够，不用于分发）
echo "▸ Ad-hoc 签名"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "✓ $APP"
echo "  首次启动会请求「通知」权限 —— 告警功能需要它。"
echo "  未签名的应用首次打开需右键 → 打开，或："
echo "    xattr -dr com.apple.quarantine \"$APP\""
