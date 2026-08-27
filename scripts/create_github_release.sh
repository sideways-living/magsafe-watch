#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 v0.2.0" >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI is required. Install gh and run: gh auth login" >&2
  exit 2
fi

if ! git -C "$ROOT_DIR" remote get-url origin >/dev/null 2>&1; then
  echo "No git remote named origin is configured." >&2
  echo "Create a GitHub repository, then run:" >&2
  echo "  git remote add origin git@github.com:YOUR-USER/magsafe-watch.git" >&2
  exit 2
fi

if [[ -n "$(git -C "$ROOT_DIR" status --short)" ]]; then
  echo "Working tree is not clean. Commit or stash changes before releasing." >&2
  exit 2
fi

"$ROOT_DIR/scripts/build_installer.sh" >/dev/null

git -C "$ROOT_DIR" tag -a "$VERSION" -m "MagSafe Watch $VERSION" 2>/dev/null || true
git -C "$ROOT_DIR" push origin main
git -C "$ROOT_DIR" push origin "$VERSION"

gh release create "$VERSION" \
  "$ROOT_DIR/outputs/MagSafe Watch Installer.pkg" \
  --title "MagSafe Watch $VERSION" \
  --notes "Unsigned local installer build. See docs/RELEASE_CHECKLIST.md for verification and update-feed setup."

echo "Release created: $VERSION"
