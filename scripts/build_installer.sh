#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${MAGSAFEWATCH_BUILD_ROOT:-/private/tmp/magsafe-watch-build}"
APP_DIR="${MAGSAFEWATCH_APP_OUTPUT:-$BUILD_ROOT/export/MagSafe Watch.app}"
PKG_DIR="/private/tmp/magsafe-watch-installer"
STAGING_DIR="$PKG_DIR/staging"
PKG_PATH="$ROOT_DIR/outputs/MagSafe Watch Installer.pkg"
VERSION="${MAGSAFEWATCH_VERSION:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")}"
export COPYFILE_DISABLE=1

"$ROOT_DIR/scripts/build_app.sh" >/dev/null

rm -rf "$PKG_DIR" "$PKG_PATH"
mkdir -p "$STAGING_DIR/Applications"
ditto --norsrc --noextattr "$APP_DIR" "$STAGING_DIR/Applications/MagSafe Watch.app"
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
  "$PKG_PATH.unsigned"

INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-}"
if [[ -z "$INSTALLER_SIGN_IDENTITY" ]]; then
  INSTALLER_SIGN_IDENTITY="$(security find-identity -v | sed -n 's/.*"\(Developer ID Installer:[^"]*\)"/\1/p' | head -1)"
fi

if [[ -n "$INSTALLER_SIGN_IDENTITY" ]]; then
  productsign --sign "$INSTALLER_SIGN_IDENTITY" "$PKG_PATH.unsigned" "$PKG_PATH"
  rm -f "$PKG_PATH.unsigned"
else
  mv "$PKG_PATH.unsigned" "$PKG_PATH"
  echo "Developer ID Installer identity not found; installer package is unsigned." >&2
fi

if [[ -n "${NOTARYTOOL_PROFILE:-}" && -n "$INSTALLER_SIGN_IDENTITY" ]]; then
  xcrun notarytool submit "$PKG_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
  xcrun stapler staple "$PKG_PATH"
fi

rm -rf "$PKG_DIR"
echo "$PKG_PATH"
