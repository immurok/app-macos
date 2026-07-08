#!/bin/bash
# 构建 AuthProbe.app —— 通用二进制(arm64 + x86_64),ad-hoc 签名。
# 直接用 swiftc 分架构编译 + lipo 合并,不需要完整 Xcode(CLT 即可)。
# 产物可拷到其它 Mac 测试(Intel / Apple Silicon 都能跑)。
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$DIR/Sources/AuthProbeApp/main.swift"
APP="$DIR/AuthProbe.app"
BUNDLE_ID="com.immurok.authprobe"
TMP="$(mktemp -d)"
DEPLOY="13.0"

echo "==> 编译 arm64…"
swiftc -O -target "arm64-apple-macos${DEPLOY}" -o "$TMP/arm64" "$SRC"

ARCHS="arm64"
if swiftc -O -target "x86_64-apple-macos${DEPLOY}" -o "$TMP/x86_64" "$SRC" 2>"$TMP/x86err"; then
    echo "==> 编译 x86_64…  OK"
    echo "==> lipo 合并为通用二进制…"
    lipo -create -output "$TMP/AuthProbe" "$TMP/arm64" "$TMP/x86_64"
    ARCHS="arm64 + x86_64"
else
    echo "==> x86_64 编译失败(下方为原因),仅出 arm64 版:"
    sed 's/^/    /' "$TMP/x86err" | tail -5
    cp "$TMP/arm64" "$TMP/AuthProbe"
fi

echo "==> 组装 .app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$TMP/AuthProbe" "$APP/Contents/MacOS/AuthProbe"
chmod +x "$APP/Contents/MacOS/AuthProbe"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AuthProbe</string>
    <key>CFBundleDisplayName</key><string>immurok AuthProbe</string>
    <key>CFBundleExecutable</key><string>AuthProbe</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>${DEPLOY}</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc 签名…"
codesign --force --sign - "$APP"
rm -rf "$TMP"

echo ""
echo "✅ 完成($ARCHS):$APP"
lipo -archs "$APP/Contents/MacOS/AuthProbe" | sed 's/^/   架构: /'
echo ""
echo "本机运行:  open \"$APP\""
echo "拷到别的 Mac 首次打开被 Gatekeeper 拦时,右键 → 打开;或先执行:"
echo "  xattr -dr com.apple.quarantine /路径/AuthProbe.app"
echo "首次运行需在 系统设置 ▸ 隐私与安全性 ▸ 辅助功能 里勾选 AuthProbe。"
