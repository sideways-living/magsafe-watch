#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${MAGSAFEWATCH_BUILD_ROOT:-/private/tmp/magsafe-watch-build}"
BUILD_DIR="$BUILD_ROOT/release"
APP_DIR="$ROOT_DIR/outputs/MagSafe Watch.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/module-cache"
export SWIFTPM_HOME="$BUILD_ROOT/swiftpm-home"

swift build -c release --package-path "$ROOT_DIR" --scratch-path "$BUILD_ROOT"

pkill -f "$APP_DIR/Contents/MacOS/MagSafe Watch" >/dev/null 2>&1 || true
for _ in {1..20}; do
  if ! pgrep -f "$APP_DIR/Contents/MacOS/MagSafe Watch" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_DIR/MagSafeWatch" "$MACOS_DIR/MagSafe Watch"
swift "$ROOT_DIR/scripts/generate_icon.swift" "$ROOT_DIR/Assets/MagSafeWatchLogo.svg" "$RESOURCES_DIR"
cp "$ROOT_DIR/Assets/MagSafeWatchAppIcon.icns" "$RESOURCES_DIR/MagSafeWatch.icns"
cp "$ROOT_DIR"/Assets/MenuBarIcons/*.png "$RESOURCES_DIR"/

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>MagSafe Watch</string>
  <key>CFBundleIdentifier</key>
  <string>local.magsafewatch.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>MagSafe Watch</string>
  <key>CFBundleIconFile</key>
  <string>MagSafeWatch</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSUserNotificationAlertStyle</key>
  <string>alert</string>
</dict>
</plist>
PLIST

xattr -cr "$APP_DIR"
xattr -c "$APP_DIR" >/dev/null 2>&1 || true
xattr -d com.apple.FinderInfo "$APP_DIR" >/dev/null 2>&1 || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_DIR" >/dev/null 2>&1 || true
codesign --force --deep --sign - "$APP_DIR" >/dev/null
xattr -cr "$APP_DIR" >/dev/null 2>&1 || true
xattr -d com.apple.FinderInfo "$APP_DIR" >/dev/null 2>&1 || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_DIR" >/dev/null 2>&1 || true

echo "$APP_DIR"
