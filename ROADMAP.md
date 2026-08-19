# MagSafe Watch Roadmap

## Current Scope

MagSafe Watch currently focuses on reliable Mac-side detection and notification:

- Detects when macOS changes from external power to battery power.
- Uses motion sensor events, when available, to decide whether the Mac moved.
- Uses idle state and external keyboard/mouse activity as fallback desk-use signals.
- Sends local macOS notifications, alert sounds, and optional webhook push alerts.
- Checks for app updates through a configurable GitHub Releases feed.

See `docs/CONCEPT.md` for the current detection model and limitations.

## Notification Provider Architecture

Before adding a native iPhone or Apple Watch companion, the Mac app should split
notification delivery into separate providers:

- Local Mac notifications
- Local Mac alert sound
- Webhook notifications
- Future native iPhone/watchOS push notifications

This keeps charger detection separate from notification delivery and avoids
rewriting detection logic later.

## iPhone And Apple Watch Companion

A native helper app could improve the notification experience beyond generic
webhooks.

Potential benefits:

- Native APNs push alerts branded as MagSafe Watch.
- Better Apple Watch presentation with app icon, title, and watch-specific copy.
- Notification actions such as:
  - Remind me in 5 minutes
  - Mute this Mac for 1 hour
  - Mark as intentional
  - Open status
- Multi-Mac status, including which Mac lost power and when.
- Alert history across Macs.
- Cleaner setup without manually editing webhook URLs.

## Expected Architecture

Recommended eventual flow:

1. Mac app detects external power loss.
2. Mac app classifies likely accidental vs intentional power loss.
3. Mac app sends an event to a small backend or cloud function.
4. Backend sends APNs push to the iPhone app.
5. Apple forwards eligible alerts to Apple Watch.
6. iPhone/watchOS app can send user actions back to the backend.
7. Mac app polls or receives the action to mute, snooze, or mark the event.

## Tradeoffs

Native iPhone/watchOS support is more polished but adds cost and complexity:

- Requires an Apple Developer account for distribution and APNs.
- Requires APNs device-token registration.
- Should use a backend so APNs signing credentials are not stored in the Mac app.
- Still depends on Apple notification delivery rules and user notification
  settings.

## Proposed Phases

### Phase 1: Provider Cleanup

- Introduce a notification provider protocol in the Mac app.
- Move local notification, sound, and webhook delivery into separate providers.
- Add provider-specific test buttons.
- Add provider health/status display.

### Phase 2: Webhook Polish

- Support named webhook profiles.
- Add payload preview.
- Add retry/backoff for failed webhooks.
- Add delivery logs in the Status page.

### Phase 3: Native Companion Prototype

- Create iOS app target.
- Register for APNs.
- Add a minimal backend endpoint for Mac events.
- Show alerts on iPhone.
- Add basic alert history.

### Phase 4: watchOS Companion

- Add watchOS target.
- Add watch-specific notification categories and actions.
- Use Watch Connectivity for iPhone/watch communication where appropriate.
- Add quick actions for snooze and mute.

### Phase 5: Multi-Mac Sync

- Add Mac identity and pairing.
- Show all registered Macs in the iPhone app.
- Add per-Mac notification settings.
- Add per-Mac mute/snooze state.
