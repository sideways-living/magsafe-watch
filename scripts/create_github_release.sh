#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
VERSION_TAG="${1:-v$VERSION}"
EXPECTED_TAG="v$VERSION"
SPARKLE_ACCOUNT="sideways-living.MagSafeWatch"
REPOSITORY="sideways-living/magsafe-watch"
ARCHIVE_NAME="MagSafe-Watch-$VERSION.zip"
RELEASE_DIR="$(mktemp -d /private/tmp/magsafe-watch-release.XXXXXX)"
NOTARY_PROFILE="${NOTARYTOOL_PROFILE:-}"

cleanup() {
  rm -rf "$RELEASE_DIR"
}
trap cleanup EXIT

if [[ "$VERSION_TAG" != "$EXPECTED_TAG" ]]; then
  echo "Tag $VERSION_TAG does not match VERSION ($VERSION)." >&2
  exit 2
fi

for command in gh git curl xcrun; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required." >&2
    exit 2
  fi
done

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "Set NOTARYTOOL_PROFILE to a stored notarytool keychain profile." >&2
  exit 2
fi

if [[ -n "$(git -C "$ROOT_DIR" status --short)" ]]; then
  echo "Working tree is not clean. Commit intended changes before releasing." >&2
  exit 2
fi

if ! git -C "$ROOT_DIR" remote get-url origin >/dev/null 2>&1; then
  echo "No git remote named origin is configured." >&2
  exit 2
fi

CODE_SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)"/\1/p' | head -1)"
INSTALLER_SIGN_IDENTITY="$(security find-identity -v | sed -n 's/.*"\(Developer ID Installer:[^"]*\)"/\1/p' | head -1)"
if [[ -z "$CODE_SIGN_IDENTITY" || -z "$INSTALLER_SIGN_IDENTITY" ]]; then
  echo "Developer ID Application and Developer ID Installer identities are both required." >&2
  exit 2
fi

SPARKLE_BIN="$($ROOT_DIR/scripts/fetch_sparkle_tools.sh)"
"$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p >/dev/null

export MAGSAFEWATCH_VERSION="$VERSION"
export CODE_SIGN_IDENTITY
export INSTALLER_SIGN_IDENTITY
export NOTARYTOOL_PROFILE="$NOTARY_PROFILE"

"$ROOT_DIR/scripts/build_installer.sh"

SIGNED_APP="${MAGSAFEWATCH_BUILD_ROOT:-/private/tmp/magsafe-watch-build}/bundle/MagSafe Watch.app"
ditto -c -k --sequesterRsrc --keepParent "$SIGNED_APP" "$RELEASE_DIR/$ARCHIVE_NAME"
xcrun notarytool submit "$RELEASE_DIR/$ARCHIVE_NAME" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$SIGNED_APP"
rm -f "$RELEASE_DIR/$ARCHIVE_NAME"
ditto -c -k --sequesterRsrc --keepParent "$SIGNED_APP" "$RELEASE_DIR/$ARCHIVE_NAME"

cp "$ROOT_DIR/appcast.xml" "$RELEASE_DIR/appcast.xml"
if [[ -f "$ROOT_DIR/RELEASE_NOTES.md" ]]; then
  cp "$ROOT_DIR/RELEASE_NOTES.md" "$RELEASE_DIR/MagSafe-Watch-$VERSION.md"
else
  printf '# MagSafe Watch %s\n\nSigned and notarized update.\n' "$VERSION" > "$RELEASE_DIR/MagSafe-Watch-$VERSION.md"
fi

"$SPARKLE_BIN/generate_appcast" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "https://github.com/$REPOSITORY/releases/download/$VERSION_TAG/" \
  --link "https://github.com/$REPOSITORY/releases/tag/$VERSION_TAG" \
  --embed-release-notes \
  --maximum-versions 5 \
  "$RELEASE_DIR"

cp "$RELEASE_DIR/appcast.xml" "$ROOT_DIR/appcast.xml"
git -C "$ROOT_DIR" add VERSION appcast.xml
if ! git -C "$ROOT_DIR" diff --cached --quiet; then
  git -C "$ROOT_DIR" commit -m "Prepare $VERSION_TAG release feed"
fi

git -C "$ROOT_DIR" tag -a "$VERSION_TAG" -m "MagSafe Watch $VERSION_TAG"
git -C "$ROOT_DIR" push origin main
git -C "$ROOT_DIR" push origin "$VERSION_TAG"

gh release create "$VERSION_TAG" \
  "$RELEASE_DIR/$ARCHIVE_NAME" \
  "$ROOT_DIR/outputs/MagSafe Watch Installer.pkg" \
  --repo "$REPOSITORY" \
  --title "MagSafe Watch $VERSION" \
  --notes-file "$RELEASE_DIR/MagSafe-Watch-$VERSION.md"

echo "Published signed Sparkle release $VERSION_TAG."
