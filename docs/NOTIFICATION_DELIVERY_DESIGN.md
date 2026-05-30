# Notification Delivery Design

This note defines the future notification boundary for the Immich roadmap. It
is intentionally separated from preview, memory, and backup logic so the app
can review the delivery strategy before any provider is implemented.

## Goal

Notify the user when memory candidates are approved or created, using a
provider that fits a private-personal deployment first.

## Scope

- Notifications are downstream of preview and approval.
- The user must explicitly opt in before the app can send any notification.
- The app should support local desktop notifications and self-hosted private
  providers first.
- Notification content should stay minimal and actionable.

## Delivery Options

The first supported provider set should prefer private-network delivery:

- `ntfy`
- `Gotify`
- `Pushover`
- Home Assistant
- local desktop notifications

Provider support should be modular so each provider can be enabled or disabled
without affecting preview, memory scoring, or backup setup.

## Message Contract

Notifications should include only the information needed to act on the event:

- event type, such as approved memory, created memory, or background upload
  reminder;
- candidate title or short summary;
- private server or app link when available;
- a short status line explaining what happened.

Do not include API keys, passwords, personal media paths, or full asset lists in
the notification payload.

## Delivery Rules

- Send notifications only after the related preview or approval action has
  finished.
- Keep notification sending separate from memory scoring and write-path logic.
- Prefer private-network delivery when the recipient and provider support it.
- If outside-home access is needed, document VPN, Tailscale, or WireGuard first
  rather than exposing the server publicly.
- Keep the app usable when no notification provider is configured.

## Failure Handling

- If a provider is misconfigured, surface the error in the UI and keep the rest
  of the app usable.
- If a notification fails to send, do not roll back a successful preview or
  memory write.
- If the provider is offline, record the failure locally for later retry only if
  the design explicitly adds a retry queue.

## Future Implementation Boundary

The notification layer should consume finished events from the app rather than
calling preview or memory code directly. That keeps the provider code isolated
from scoring, external-library handling, and the memory write path.

## Verification

Before implementation begins, keep validating the current preview and beta
gates:

```bash
flutter test test/widget_test.dart --plain-name "queues a local memory write draft after approval"
flutter test test/widget_test.dart --plain-name "rejects a memory write draft with the wrong approval phrase"
flutter test
flutter analyze
python3 -m unittest discover -s tests
python3 -m compileall scripts config tests
ruff check scripts config tests
shfmt -d scripts/*.sh config/*.sh
```

## Non-Goals

- No notification provider wiring yet.
- No retry queue for notification delivery yet.
- No ranking-feedback notification templates yet.
- No public push-provider configuration in the app settings.
