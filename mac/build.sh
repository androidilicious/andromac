#!/bin/bash
# Builds AndroMac.app with the Swift compiler alone (Command Line Tools are enough, no Xcode project).
# The result is ad-hoc signed and has everything except the virtual webcam extension,
# which needs Xcode and a paid Apple Developer team (see README).
#
#   ./build.sh            build into mac/build/AndroMac.app
#   ./build.sh install    also copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

APP=build/AndroMac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    -o "$APP/Contents/MacOS/AndroMac" AndroMac/*.swift

cp AndroMac/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AndroMac</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>app.andromac.AndroMac</string>
    <key>CFBundleName</key><string>AndroMac</string>
    <key>CFBundleDisplayName</key><string>AndroMac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key><string>AndroMac talks to your paired Android phone over your local network.</string>
    <key>NSBonjourServices</key><array><string>_andromac._tcp</string></array>
    <key>NSCameraUsageDescription</key><string>AndroMac feeds your phone's camera into its virtual webcam.</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $PWD/$APP"

if [ "${1:-}" = "install" ]; then
    pkill -x AndroMac 2>/dev/null || true
    rm -rf /Applications/AndroMac.app
    cp -R "$APP" /Applications/AndroMac.app
    open /Applications/AndroMac.app
    echo "Installed and launched /Applications/AndroMac.app"
fi
