# MagSafe Watch

MagSafe Watch is a small macOS app that watches for AC power changes. When the
Mac switches to battery power and does not physically move, it plays a sound and
posts a local macOS notification.

The app uses the macOS power-source APIs directly:

- `IOPSNotificationCreateRunLoopSource` tells the app when power changes
- `IOPSGetProvidingPowerSourceType` reports Power Adapter vs Battery

For accidental-unplug detection it then samples accelerometer-like HID sensor
events, when the Mac model exposes them to user-space apps:

- charger disconnects and the Mac stays motionless: alert
- charger disconnects and the Mac is picked up or moved: suppress the first alert
- if no motion sensor is available, fall back to idle-time detection
- recent external keyboard or mouse input can count as desk activity, so the app
  can still alert while you are actively using the Mac at your desk
- recent built-in keyboard or trackpad input is treated as more likely intentional
  laptop use and can suppress the fallback alert
- repeat reminders continue while the Mac remains on battery and motionless

## Build

```bash
./scripts/build_app.sh
```

The app bundle is written to:

```text
outputs/MagSafe Watch.app
```

## Run

Open the app bundle. An introduction window appears, and macOS will ask for
notification permission the first time.

The window has separate pages:

- Intro: explains what the app does and how it decides whether an unplug looks accidental
- Settings: switches for monitoring, motion detection, idle fallback, external input detection, and repeat reminders
- Notifications: switches for macOS banners, alert sound, and webhook push alerts
- Status: current power source, idle time, and latest motion result

You can close the window after launch. The menu-bar bolt icon keeps running and
has:

- Show Status Window
- Send Test Alert
- Open Settings
- Quit

To start it automatically at login:

```bash
./scripts/install_login_item.sh
```

## Settings

The app creates a config file at:

```text
~/Library/Application Support/MagSafeWatch/config.json
```

Example:

```json
{
  "monitorEnabled": true,
  "motionDetectionEnabled": true,
  "idleFallbackEnabled": true,
  "externalInputDeskSignalEnabled": true,
  "repeatRemindersEnabled": true,
  "localNotificationsEnabled": true,
  "soundEnabled": true,
  "webhookNotificationsEnabled": false,
  "stationaryIdleThresholdSeconds": 90,
  "motionSampleWindowSeconds": 10,
  "inputActivityWindowSeconds": 15,
  "movementThresholdG": 0.08,
  "repeatAlertIntervalSeconds": 300,
  "webhookURL": ""
}
```

`movementThresholdG` is the accelerometer vector-change threshold. Lower values
make movement detection more sensitive; higher values make it less sensitive.

Set the same `webhookURL` on each Mac you want monitored. That is the current
sync model: every computer reports to the same push endpoint, and the payload
includes the Mac name.

Set `webhookURL` to a service that can push to iPhone/Apple Watch, such as
Pushover, ntfy, IFTTT, Home Assistant, or your own endpoint. The app sends:

```json
{
  "title": "MacBook unplugged",
  "message": "Power changed to Battery after 90s without input.",
  "source": "Your Mac Name"
}
```

## iPhone and Apple Watch alerts

macOS local notifications are local to the Mac. For iPhone or Apple Watch alerts,
there are two realistic paths:

1. Use the built-in webhook setting with a push service that already has an iOS
   and watchOS notification app.
2. Build a companion iOS/watchOS app and an APNs backend. That is more work but
   gives a fully native Apple-only notification path.

This prototype implements option 1 so it can be used immediately without a paid
Apple Developer account or backend.
