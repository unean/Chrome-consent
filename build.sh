#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-$ROOT/build}"
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"
APP="$DEST/Chrome Consent.app"
WORK="$(mktemp -d "$DEST/.build.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
export COPYFILE_DISABLE=1
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
PLUGIN="$APP/Contents/Resources/ChromeConsentAuthorizationPlugin.bundle"
mkdir -p "$PLUGIN/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.chromeconsent.app</string>
<key>CFBundleExecutable</key><string>ChromeConsent</string>
<key>CFBundleName</key><string>Chrome Consent</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.1</string>
<key>CFBundleVersion</key><string>106</string>
<key>LSMinimumSystemVersion</key><string>14.4</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Chrome Consent requests administrator approval for its installer.</string>
</dict></plist>
PLIST
cat > "$PLUGIN/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.chromeconsent.authorization</string>
<key>CFBundleExecutable</key><string>ChromeConsentAuthorizationPlugin</string>
<key>CFBundleName</key><string>ChromeConsentAuthorizationPlugin</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
FRAMEWORKS=(-framework Foundation -framework AppKit -framework ApplicationServices -framework Security -framework SystemConfiguration -framework IOKit -framework ServiceManagement -framework QuartzCore -framework ScreenCaptureKit)
PREFIX_MAPS=("-ffile-prefix-map=$ROOT=." "-ffile-prefix-map=$WORK=./build")
xcrun clang -fobjc-arc -O2 "${PREFIX_MAPS[@]}" -mmacosx-version-min=14.4 -c "$ROOT/src/Bridge.m" -o "$WORK/Bridge.o"
xcrun clang -fobjc-arc -O2 "${PREFIX_MAPS[@]}" -mmacosx-version-min=14.4 -bundle "$ROOT/src/AuthorizationPlugin.m" "$WORK/Bridge.o" "${FRAMEWORKS[@]}" -o "$PLUGIN/Contents/MacOS/ChromeConsentAuthorizationPlugin"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.4 -import-objc-header "$ROOT/src/Bridge.h" \
    -file-prefix-map "$ROOT=." -file-prefix-map "$WORK=./build" \
    "$ROOT/src/Core.swift" "$ROOT/src/RunState.swift" "$ROOT/src/ProcessLease.swift" "$ROOT/src/Permissions.swift" "$ROOT/src/LoginScreen.swift" "$ROOT/src/LockShield.swift" "$ROOT/src/Guardian.swift" "$ROOT/src/App.swift" "$ROOT/src/main.swift" "$WORK/Bridge.o" \
    "${FRAMEWORKS[@]}" -o "$APP/Contents/MacOS/ChromeConsent"
cp "$ROOT/installer.py" "$APP/Contents/Resources/installer.py"
xcrun swiftc -file-prefix-map "$ROOT=." -file-prefix-map "$WORK=./build" "$ROOT/src/icon.swift" -o "$WORK/make-icon" -framework AppKit
"$WORK/make-icon" "$WORK/AppIcon.iconset"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$WORK/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>com.apple.security.automation.apple-events</key><true/></dict></plist>
PLIST
codesign --force --sign - --options runtime --identifier local.chromeconsent.authorization "$PLUGIN"
codesign --force --sign - --options runtime --entitlements "$WORK/entitlements.plist" --identifier local.chromeconsent.app "$APP"
xattr -cr "$APP"
codesign --verify --deep --strict "$APP"
printf '\nBuilt: Chrome Consent.app\n'
