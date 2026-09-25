#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${MAGSAFEWATCH_BUILD_ROOT:-/private/tmp/magsafe-watch-build}"
BUILD_DIR="$BUILD_ROOT/release"
OUTPUT_APP_DIR="${MAGSAFEWATCH_APP_OUTPUT:-$BUILD_ROOT/export/MagSafe Watch.app}"
APP_DIR="$BUILD_ROOT/bundle/MagSafe Watch.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
VERSION="${MAGSAFEWATCH_VERSION:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")}"
IFS=. read -r VERSION_MAJOR VERSION_MINOR VERSION_PATCH <<< "$VERSION"
BUILD_NUMBER="${MAGSAFEWATCH_BUILD_NUMBER:-$((10#${VERSION_MAJOR:-0} * 10000 + 10#${VERSION_MINOR:-0} * 100 + 10#${VERSION_PATCH:-0}))}"
BUNDLE_ID="living.sideways.MagSafeWatch"
FEED_URL="https://raw.githubusercontent.com/sideways-living/magsafe-watch/main/appcast.xml"
SPARKLE_PUBLIC_KEY="QDT8tychLodNImrN6i1DHoTHdxeRsqYQcNsR7IXRmJw="
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/module-cache"
export SWIFTPM_HOME="$BUILD_ROOT/swiftpm-home"

swift build -c release --package-path "$ROOT_DIR" --scratch-path "$BUILD_ROOT"

pkill -f "$OUTPUT_APP_DIR/Contents/MacOS/MagSafe Watch" >/dev/null 2>&1 || true
for _ in {1..20}; do
  if ! pgrep -f "$OUTPUT_APP_DIR/Contents/MacOS/MagSafe Watch" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
rm -rf "$APP_DIR" "$OUTPUT_APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"
cp "$BUILD_DIR/MagSafeWatch" "$MACOS_DIR/MagSafe Watch"
SPARKLE_FRAMEWORK="$(find "$BUILD_ROOT" -type d -name Sparkle.framework -print -quit)"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
  echo "Sparkle.framework was not produced by SwiftPM." >&2
  exit 1
fi
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/Sparkle.framework"
swift "$ROOT_DIR/scripts/generate_icon.swift" "$ROOT_DIR/Assets/MagSafeWatchLogo.svg" "$RESOURCES_DIR"
cp "$ROOT_DIR/Assets/MagSafeWatchAppIcon.icns" "$RESOURCES_DIR/MagSafeWatch.icns"
cp "$ROOT_DIR/Assets/AppIcons/macos/AppIcon512.png" "$RESOURCES_DIR/MagSafeWatchBrand.png"
cp -R "$ROOT_DIR/Assets/AppIcons" "$RESOURCES_DIR/AppIcons"
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
  <string>living.sideways.MagSafeWatch</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>MagSafe Watch</string>
  <key>CFBundleIconFile</key>
  <string>MagSafeWatch</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>__VERSION__</string>
  <key>CFBundleVersion</key>
  <string>__BUILD_NUMBER__</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSUserNotificationAlertStyle</key>
  <string>alert</string>
  <key>SUFeedURL</key>
  <string>__FEED_URL__</string>
  <key>SUPublicEDKey</key>
  <string>__SPARKLE_PUBLIC_KEY__</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUAllowsAutomaticUpdates</key>
  <true/>
</dict>
</plist>
PLIST

sed -i '' \
  -e "s|__VERSION__|$VERSION|g" \
  -e "s|__BUILD_NUMBER__|$BUILD_NUMBER|g" \
  -e "s|__FEED_URL__|$FEED_URL|g" \
  -e "s|__SPARKLE_PUBLIC_KEY__|$SPARKLE_PUBLIC_KEY|g" \
  "$CONTENTS_DIR/Info.plist"

for _ in {1..10}; do
  xattr -d com.apple.FinderInfo "$APP_DIR" >/dev/null 2>&1 || true
  if ! xattr -p com.apple.FinderInfo "$APP_DIR" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$CODE_SIGN_IDENTITY" ]]; then
  CODE_SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)"/\1/p' | head -1)"
fi
if [[ -z "$CODE_SIGN_IDENTITY" ]]; then
  CODE_SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)"/\1/p' | head -1)"
fi
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"

SIGN_ARGS=(--force --options runtime --sign "$CODE_SIGN_IDENTITY")
if [[ "$CODE_SIGN_IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--timestamp)
  if [[ "$CODE_SIGN_IDENTITY" == Apple\ Development:* ]]; then
    echo "Developer ID Application identity not found; using $CODE_SIGN_IDENTITY for this local build." >&2
  fi
else
  echo "No signing identity found; using an ad-hoc signature for this local build." >&2
fi

SPARKLE_VERSION_DIR="$FRAMEWORKS_DIR/Sparkle.framework/Versions/B"
codesign "${SIGN_ARGS[@]}" "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
codesign "${SIGN_ARGS[@]}" "$SPARKLE_VERSION_DIR/Autoupdate"
codesign "${SIGN_ARGS[@]}" "$SPARKLE_VERSION_DIR/Updater.app"
codesign "${SIGN_ARGS[@]}" "$FRAMEWORKS_DIR/Sparkle.framework"
codesign "${SIGN_ARGS[@]}" "$APP_DIR"

mkdir -p "$(dirname "$OUTPUT_APP_DIR")"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr "$APP_DIR" "$OUTPUT_APP_DIR"

OUTPUT_LINK="$ROOT_DIR/outputs/MagSafe Watch.app"
mkdir -p "$ROOT_DIR/outputs"
if [[ -L "$OUTPUT_LINK" || ! -e "$OUTPUT_LINK" ]]; then
  ln -sfn "$OUTPUT_APP_DIR" "$OUTPUT_LINK"
else
  echo "Existing $OUTPUT_LINK is not a symlink; leaving it unchanged." >&2
fi

echo "$OUTPUT_APP_DIR"
