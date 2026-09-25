# Troubleshooting

## No Notification Appears

1. Open MagSafe Watch > `Permissions`.
2. Click `Request Notification Permission`.
3. Open `Notification Settings`.
4. Enable notifications for MagSafe Watch.
5. Open `Notifications` and confirm `Show macOS notification banners` is on.
6. Use `Test Mac Notification`.

If sound is missing, confirm `Play alert sound on this Mac` is on and use
`Test Sound`.

## No Menu Bar Icon Appears

1. Open MagSafe Watch.
2. Open `Settings`.
3. Enable `Show MagSafe Watch in the menu bar`.
4. If the app is Dock-only, use the Dock icon or app window to reopen settings.

At least one of menu bar or Dock mode stays enabled so the app does not become
invisible.

## Input Monitoring

Input Monitoring may be required when using external keyboard or mouse activity
as a desk-use signal.

1. Open MagSafe Watch > `Permissions`.
2. Click `Open Input Monitoring`.
3. Enable MagSafe Watch if macOS lists it.
4. Restart MagSafe Watch.

If external input still does not affect detection, check the Status page `Input`
field and diagnostics. Some docks, Bluetooth devices, and keyboards report
different HID metadata.

## Motion Detection

Some MacBook models expose motion-like HID sensor events to user-space apps and
some do not.

Check the Status page:

- `Motion` shows the latest motion classification.
- Diagnostics records whether the app sampled motion, found movement, found
  stationary state, or fell back because motion was unavailable.

If motion detection is unavailable, keep `Use idle-time fallback when motion data
is unavailable` enabled.

## Unplug Warning Does Not Appear

Check:

- `Monitor MagSafe and power adapter changes` is enabled.
- The Mac is actually running on battery.
- The Mac remains stationary during the motion sample window.
- Idle fallback threshold has elapsed if motion data is unavailable.
- Built-in keyboard or trackpad input was not recent when using idle fallback.
- Repeat reminders are enabled if you expect follow-up alerts.

The Status page diagnostics should show the reason an alert was sent or
suppressed.

## Webhook Alerts Do Not Arrive

1. Open `Notifications`.
2. Enable `Send webhook push notifications for iPhone or Apple Watch`.
3. Open `Advanced Config`.
4. Confirm `webhookURL` is set.
5. Trigger an unplug event while stationary.
6. Or use `Test Webhook`.
7. Check Status page diagnostics.

Diagnostics will report:

- Webhook disabled.
- Missing webhook URL.
- Webhook sending.
- Webhook retry scheduled.
- Webhook failed with an error.
- Webhook completed with an HTTP status.

If the app reports HTTP success but the phone does not alert, debug the provider
automation or mobile notification settings.

## Launch At Login

Open `Settings` and enable `Launch MagSafe Watch when I log in`.

Or open MagSafe Watch > `Permissions` > `Open Login Items` and add the app
manually.

## Update Checks

Updates are handled by Sparkle using the feed baked into the app:

```text
https://raw.githubusercontent.com/sideways-living/magsafe-watch/main/appcast.xml
```

Use `Check for Updates...` in the app menu, menu bar menu, or Status page to
test manually. If it fails, confirm the feed is reachable, the release archive
URL returns HTTP 200, and Console contains no Sparkle signature or version
errors. Sparkle will reject an archive whose EdDSA signature does not match the
public key embedded in the app.
