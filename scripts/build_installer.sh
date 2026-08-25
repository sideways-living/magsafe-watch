#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/outputs/MagSafe Watch.app"
PKG_DIR="$ROOT_DIR/outputs/installer"
STAGING_DIR="$PKG_DIR/staging"
PKG_PATH="$ROOT_DIR/outputs/MagSafe Watch Installer.pkg"
VERSION="0.1.0"
export COPYFILE_DISABLE=1

"$ROOT_DIR/scripts/build_app.sh" >/dev/null

rm -rf "$PKG_DIR" "$PKG_PATH"
mkdir -p "$STAGING_DIR/Applications"
ditto --norsrc --noextattr "$APP_DIR" "$STAGING_DIR/Applications/MagSafe Watch.app"
xattr -cr "$STAGING_DIR/Applications/MagSafe Watch.app" >/dev/null 2>&1 || true
find "$STAGING_DIR" \( -name '._*' -o -name '.__*' -o -name '.DS_Store' \) -delete

pkgbuild \
  --root "$STAGING_DIR" \
  --install-location "/" \
  --identifier "local.magsafewatch.installer" \
  --version "$VERSION" \
  --filter '(^|/)\._' \
  --filter '(^|/)\.__' \
  --filter '\.DS_Store$' \
  --filter '(^|/)CVS($|/)' \
  --filter '(^|/)\.svn($|/)' \
  "$PKG_PATH"

rm -rf "$PKG_DIR"
xattr -d com.apple.FinderInfo "$APP_DIR" >/dev/null 2>&1 || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_DIR" >/dev/null 2>&1 || true
echo "$PKG_PATH"
