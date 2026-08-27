# Release Checklist

Use this checklist when publishing a new MagSafe Watch build.

## Before Building

- Confirm `CFBundleShortVersionString` in `scripts/build_app.sh`.
- Confirm `VERSION` in `scripts/build_installer.sh`.
- Run `git status --short` and make sure only intended files are changed.
- Review `README.md`, `ROADMAP.md`, and docs for version-specific notes.
- Confirm `updateFeedURL` documentation points to the intended GitHub repository.

## Build

```bash
swift build --scratch-path /private/tmp/magsafe-watch-debug-build
./scripts/build_installer.sh
```

Expected outputs:

```text
outputs/MagSafe Watch.app
outputs/MagSafe Watch Installer.pkg
```

## Verify

```bash
codesign --verify --deep --strict "outputs/MagSafe Watch.app"
pkgutil --check-signature "outputs/MagSafe Watch Installer.pkg"
```

The current local package is unsigned, so `pkgutil` reports `Status: no
signature`. That is expected until Developer ID signing is added.

Also verify:

- App opens.
- Menu bar icon appears.
- Settings window opens from the menu.
- Local test alert works after notification permission is granted.
- Unplug warning appears after the configured delay when the Mac is stationary.
- Status page diagnostics record alert decisions and webhook outcomes.

## GitHub Release

1. Commit the release changes.
2. Tag the commit with a version such as `v0.2.0`.
3. Create a GitHub Release from that tag.
4. Upload `outputs/MagSafe Watch Installer.pkg`.
5. Add release notes covering user-visible changes, known limits, and install
   notes.
6. Confirm the latest-release API endpoint returns the new release:

```text
https://api.github.com/repos/YOUR-USER/magsafe-watch/releases/latest
```

## Update Feed

After the release exists, set `updateFeedURL` in the app config:

```json
{
  "updateFeedURL": "https://api.github.com/repos/YOUR-USER/magsafe-watch/releases/latest"
}
```

Then use `Status` > `Check for Updates` in an older installed build to verify
the update notice opens the GitHub release page.

## Later Hardening

- Add Developer ID signing.
- Add notarization.
- Sign the installer package.
- Automate build, checks, and release upload.
