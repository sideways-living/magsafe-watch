# Release Checklist

MagSafe Watch uses Sparkle 2 for in-app updates and a signed installer package
for first installation.

## One-time setup

- Install `Developer ID Application` and `Developer ID Installer` certificates,
  including their private keys, in the login Keychain.
- Store App Store Connect credentials for notarization:

```bash
xcrun notarytool store-credentials MagSafeWatch-notary \
  --apple-id YOUR-APPLE-ID \
  --team-id YOUR-TEAM-ID \
  --password YOUR-APP-SPECIFIC-PASSWORD
```

- Keep the Sparkle private key in Keychain under account
  `sideways-living.MagSafeWatch`. Never commit or export it into the repository.
- Confirm `origin` points to `sideways-living/magsafe-watch`.

## Prepare a release

1. Update `VERSION` to the new semantic version.
2. Add user-facing notes to `RELEASE_NOTES.md` if detailed notes are needed.
3. Commit and test all changes. The release script requires a clean worktree.
4. Build and verify locally:

```bash
./scripts/build_installer.sh
codesign --verify --deep --strict --verbose=2 \
  "/private/tmp/magsafe-watch-build/export/MagSafe Watch.app"
pkgutil --check-signature "outputs/MagSafe Watch Installer.pkg"
```

5. Check the app window, menu bar item, alert flow, and `Check for Updates...`
   UI before publishing.

## Publish

```bash
NOTARYTOOL_PROFILE=MagSafeWatch-notary \
  ./scripts/create_github_release.sh v0.2.0
```

The release script requires both Developer ID identities. It builds and signs
the app and installer, notarizes them, creates a Sparkle update ZIP, signs the
ZIP with the Keychain-held EdDSA key, updates `appcast.xml`, commits the feed,
pushes the tag, and uploads both release assets to GitHub.

## Verify the published release

- Open the raw `appcast.xml` URL and confirm the new item is present.
- Confirm the ZIP and installer assets download from the GitHub Release.
- Install the previous version on a test Mac and run `Check for Updates...`.
- Complete the update and confirm the new bundle version launches.
- Recheck menu bar, login item, notification permission, and unplug alerts.

The first Sparkle-enabled build still needs to be installed manually. Sparkle
can update that build and all later releases.
