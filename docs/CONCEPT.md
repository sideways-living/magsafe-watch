# MagSafe Watch Concept

## Product Intent

MagSafe Watch is a Mac utility for people who miss accidental power loss and then
find their MacBook battery drained later.

The app should warn when external power disappears while the Mac appears to still
be at the desk. It should avoid warning when the user likely intended to pick up
the laptop and use it on battery.

## Core User Scenarios

### Stationary Desk Unplug

The Mac is on a desk, connected to external power, and the cable is bumped or
pulled loose. The Mac remains physically still.

Expected behavior: alert locally and through any configured remote notification
channel.

### Desk Power Loss

The MagSafe connector remains attached to the Mac, but power is lost upstream:
the wall adapter is unplugged, a power board switches off, or a battery bank is
disconnected or turns off.

Expected behavior: treat this the same as a Mac-end cable pull, because macOS
reports the same high-level state: external power changed to battery.

### Intentional Laptop Use

The user disconnects power, picks up the MacBook, and starts using it on battery.

Expected behavior: suppress the first alert when motion is detected or built-in
keyboard/trackpad use suggests intentional laptop use.

### Desk Use With External Input

The user is actively using an external keyboard or mouse while the Mac remains
on the desk. External power is lost.

Expected behavior: alert, because external input suggests the Mac is still in a
desk setup and power loss is likely worth warning about.

## Detection Model

MagSafe Watch does not detect the physical cable end that disconnected. It
detects the operating-system result: external power is no longer supplying the
Mac.

Detection layers:

1. Power source event
   - `IOPSNotificationCreateRunLoopSource` notifies when power source changes.
   - `IOPSGetProvidingPowerSourceType` reports Power Adapter vs Battery.
2. Motion check
   - IOKit HID sensor events are sampled when the Mac exposes accelerometer-like
     events to user-space apps.
   - Stationary after power loss is treated as likely accidental.
   - Movement after power loss is treated as likely intentional.
3. Input context
   - Recent external keyboard/mouse input is treated as desk activity.
   - Recent built-in keyboard/trackpad input is treated as intentional laptop use.
4. Idle fallback
   - If motion data is unavailable and there is no recent input signal, long idle
     time is treated as likely unattended accidental power loss.

## Notification Model

Current notification channels:

- macOS local notification banners
- Local alert sound
- Webhook JSON payload for services such as Pushover, ntfy, IFTTT, Home
  Assistant, or a custom endpoint

Planned future channels:

- Native iPhone app notifications through APNs
- Apple Watch presentation through an iPhone/watchOS companion
- Notification actions such as snooze, mute, and mark intentional

## Settings Model

Current configurable behavior:

- Enable/disable power monitoring
- Enable/disable motion detection
- Enable/disable idle fallback
- Enable/disable external input as desk activity
- Enable/disable repeat reminders
- Enable/disable local notification banners
- Enable/disable local sound
- Enable/disable webhook push alerts
- Enable/disable update checks

Advanced settings currently live in:

```text
~/Library/Application Support/MagSafeWatch/config.json
```

## Current Limitations

- The app cannot reliably distinguish Mac-end MagSafe disconnect from upstream
  adapter, wall, charger, or battery-bank power loss.
- Motion sensors are not guaranteed to be exposed to macOS user-space apps on all
  Macs.
- External vs built-in input classification depends on HID metadata provided by
  macOS and connected devices.
- Webhook notifications rely on the third-party service being reachable.
- Update checks report availability; they do not silently replace the running
  app.
- Native iPhone/watchOS push is not implemented yet.

## Product Language

Use accurate language in user-facing docs:

- Prefer "external power loss" for the detected event.
- Use "MagSafe cable, charger, or battery bank" when describing what to check.
- Avoid claiming the app knows exactly which end of the cable disconnected.
