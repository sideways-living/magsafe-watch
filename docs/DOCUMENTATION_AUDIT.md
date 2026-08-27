# Concept Documentation Audit

Audit date: 2026-08-20

## Scope

Reviewed the concept-level documentation for MagSafe Watch:

- `README.md`
- `ROADMAP.md`
- User-facing language implied by the current app behavior

The audit checked whether the documentation accurately explains what the app
detects, what it can infer, what is configurable, and what is future work.

## Findings

### 1. External Power Loss Was Described Too Narrowly

Some wording implied the app detects a MagSafe cable being physically pulled from
the Mac.

Reality: the app detects the macOS power-source transition from Power Adapter to
Battery. It cannot reliably identify whether power was lost at the Mac connector,
adapter, wall plug, power board, charger, or battery bank.

Resolution: documented the broader "external power loss" model and added a
language guideline in `docs/CONCEPT.md`.

### 2. Current Detection Signals Needed A Single Source Of Truth

The detection model had grown across several turns: power source, motion,
external input, built-in input, idle fallback, and repeat reminders.

Resolution: added `docs/CONCEPT.md` with the layered detection model and the
expected behavior for each user scenario.

### 3. README Menu And Settings Description Lagged App Behavior

The README did not include the Check for Updates menu item and did not clearly
identify update checks as a configurable behavior.

Resolution: updated `README.md` menu and settings descriptions.

### 4. iPhone And Apple Watch Work Needed Clear Current/Future Separation

The existing roadmap described native iPhone/watchOS support, but the current
README needed a sharper boundary between implemented webhook notification support
and future native companion-app work.

Resolution: kept the roadmap as future direction and linked concept docs so the
current implementation remains clear.

## Residual Risks

- Motion detection behavior needs real-device validation across multiple MacBook
  models.
- HID metadata for external vs built-in input may vary between keyboards, mice,
  trackpads, docks, and Bluetooth devices.
- Update checks require a real GitHub repository with releases before they can be
  fully exercised end to end.

## Completed Follow-Up Documentation Work

- Added screenshots to `README.md` using tracked files in `docs/screenshots/`.
- Added `docs/WEBHOOK_SETUP.md` for Pushover, ntfy, IFTTT, and Home Assistant.
- Added `docs/RELEASE_CHECKLIST.md` for GitHub Releases and update-feed setup.
- Added `docs/TROUBLESHOOTING.md` for notification permissions, login item setup,
  motion/input detection diagnostics, webhooks, and update checks.
- Added `docs/REAL_DEVICE_TEST_PLAN.md` for stationary, moving, battery-bank,
  external-input, and built-in-input validation.
