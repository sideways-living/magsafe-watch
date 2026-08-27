# Real-Device Test Plan

Use this checklist on each MacBook model you care about. Keep the Status page
open while testing so the diagnostics feed captures why an alert was sent or
suppressed.

## Test Setup

1. Install the latest `outputs/MagSafe Watch Installer.pkg`.
2. Open MagSafe Watch.
3. Open `Permissions` and allow notifications.
4. Open `Settings` and confirm:
   - `Monitor MagSafe and power adapter changes` is on.
   - `Use motion detection when sensor events are available` is on.
   - `Use idle-time fallback when motion data is unavailable` is on.
   - `Treat external keyboard or mouse input as desk activity` is on.
   - `Repeat reminders while the Mac remains unplugged` is on.
5. Open `Status` and clear your mental baseline: note Power, Motion, Input, and
   Diagnostics before each scenario.

## Scenario 1: Stationary Desk Unplug

Purpose: confirm the core accidental-unplug alert.

1. Put the MacBook on a desk.
2. Do not touch keyboard, trackpad, or mouse.
3. Disconnect MagSafe or the power adapter.
4. Wait through the motion sample and warning delay.

Expected result:

- App detects Battery power.
- Diagnostics show motion sampling or idle fallback.
- Local notification appears.
- Full-screen warning appears after the configured delay.
- Repeat reminders remain armed while still unplugged.

Record:

- Mac model:
- macOS version:
- Alert appeared: yes/no
- Motion status:
- Diagnostics summary:

## Scenario 2: Intentional Unplug While Moving

Purpose: confirm moving the Mac suppresses the first accidental alert.

1. Plug in the MacBook.
2. Pick up the MacBook.
3. Disconnect MagSafe while moving it or immediately before moving it.
4. Keep moving for a few seconds.

Expected result:

- App detects Battery power.
- Diagnostics show motion sampling.
- First accidental-unplug alert is suppressed if motion is detected.
- Repeat reminder behavior depends on later stationary state.

Record:

- Alert suppressed: yes/no
- Motion status:
- Diagnostics summary:

## Scenario 3: Battery Bank Or Charger-End Disconnect

Purpose: confirm the app responds to external power loss even if the MagSafe end
is still physically attached.

1. Plug MagSafe into a charger or battery bank.
2. Keep the MagSafe connector attached to the MacBook.
3. Disconnect power from the charger/battery-bank side.
4. Leave the MacBook stationary.

Expected result:

- macOS reports Battery power.
- App treats this the same as a power-loss event.
- Diagnostics identify power loss and alert decision.

Record:

- Alert appeared: yes/no
- Battery/source description:
- Diagnostics summary:

## Scenario 4: External Keyboard Or Mouse At Desk

Purpose: confirm external input counts as desk activity.

1. Plug in the MacBook.
2. Use an external keyboard or mouse.
3. Disconnect power while the MacBook remains stationary.
4. Continue using the external device.

Expected result:

- Diagnostics show recent external input.
- App can alert even though the user is active, because input suggests desk use.

Record:

- External device type:
- Alert appeared: yes/no
- Input status:
- Diagnostics summary:

## Scenario 5: Built-In Keyboard Or Trackpad After Unplug

Purpose: confirm built-in input can suppress idle fallback as intentional laptop
use.

1. Plug in the MacBook.
2. Disconnect power.
3. Use the built-in keyboard or trackpad soon after unplug.

Expected result:

- Diagnostics show recent built-in input.
- Idle fallback alert may be suppressed.

Record:

- Alert suppressed: yes/no
- Input status:
- Diagnostics summary:

## Pass Criteria

- Stationary desk unplug reliably alerts.
- Moving unplug suppresses the first alert on models with motion data.
- Charger-end disconnect is treated as power loss.
- External keyboard/mouse desk use can still alert.
- Built-in input can suppress idle fallback.
- Diagnostics are clear enough to explain each decision.
