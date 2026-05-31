# Immich Mobile Backup And Memories Expansion Plan

## Summary

Add a major Immich-focused expansion to the desktop app: guided mobile backup setup, a local Immich help library, and a future private memory-curator module that can create better memories from a personal Docker Immich server.

The feature must assume a private personal Immich deployment by default. It should work against `http://localhost:2283`, a LAN address such as `http://SERVER_IP:2283`, or a VPN address, without requiring the Immich instance to be public.

## Phase 1: Help Library And Guided Setup

- Add an app Help section with the essential Immich setup checklist.
- Document how to connect the mobile app to a private Docker server.
- Explain phone backup setup:
  - install Immich mobile app;
  - log in with server URL;
  - open the backup screen;
  - select phone albums;
  - enable backup;
  - optionally enable album synchronization.
- Document platform caveats:
  - Android battery optimization can block background backup;
  - iOS requires Background App Refresh and is still scheduled by iOS;
  - Wi-Fi-only backup is the safe default unless changed in settings.
- Document backup safety:
  - Immich database backups do not include media files;
  - a real backup must include database plus asset folders;
  - do not manually edit Immich-managed asset folders.

## Phase 2: Immich Connection

- Add app settings for Immich server URL and API key.
- Store credentials locally outside Git-tracked files.
- Validate connectivity with a read-only API call.
- Show server health, authenticated user, and basic library statistics.
- Keep private LAN/VPN use as the default documented path.
- See [`docs/IMMICH_SETTINGS_STORAGE.md`](IMMICH_SETTINGS_STORAGE.md) for the current storage boundary between non-secret app settings and secrets.

Status: in progress. The desktop app now has an **Immich** section that keeps the server URL and API key in memory for the current app session, runs a public ping check, verifies authenticated read-only server information, shows a read-only server statistics panel when the API key allows it, and includes a locally saved phone backup checklist. No credentials are written to repository files.

## Phase 3: Mobile Backup Assistant

- Add a guided checklist for each family phone.
- Track device setup state locally:
  - app installed;
  - server login confirmed;
  - albums selected;
  - backup enabled;
  - first upload observed;
  - background permissions reviewed.
- Add troubleshooting guidance for stalled background uploads, iOS Low Power Mode, Android battery optimization, and wrong server URL.

Status: in progress. The desktop app now includes a phone backup checklist and a
compact troubleshooting section for stalled uploads, Android battery
optimization, iPhone Low Power Mode, and private server URL mistakes.
The private-beta checklist also reflects the current feature set and keeps the
read-only memory-adapter work explicitly out of the public-release criteria.

## Phase 4: Memory Curator Preview

- Query Immich assets and existing memories through the Immich API.
- Generate local memory candidates without changing Immich:
  - this day/week in prior years;
  - event clusters;
  - location clusters;
  - people/faces where available;
  - favorites and album membership;
  - quality and duplicate penalties.
- Show explainable scoring so the user can understand why a memory was chosen.
- Exclude low-value assets by default, such as screenshots, receipts, blurry images, and near-duplicates when detectable.

Status: in progress. The repo now includes a local preview scoring engine and a
desktop-app preview panel that renders sample read-only candidates for prior
year, album, and location groupings. The preview still does not call Immich or
write memories.

The preview panel can now load live read-only assets from Immich on demand via
the adapter documented in
[`docs/MEMORY_PREVIEW_IMMICH_ADAPTER.md`](MEMORY_PREVIEW_IMMICH_ADAPTER.md).
The panel still defaults to sample data and keeps explicit ready, loading,
empty, and error states so the UI can move between sample and live assets
without changing the preview contract.

Verification:

```bash
flutter test test/widget_test.dart --plain-name "memory preview"
flutter test test/widget_test.dart --plain-name "memory write draft"
```

Expected outcome:

- The widget test covers the sample-ready, loading, empty, and error preview
  states.
- The preview panel still renders sample candidates in ready mode.
- The preview panel also exposes a local-only memory write approval draft queue
  for the future write path.


## Phase 5: Create Memories In Immich

- Add explicit user approval before creating or updating Immich memories.
- Use API-key authentication and Immich memory endpoints.
- Keep dry-run preview as the default.
- Record created memory IDs locally for later update/removal.
- Avoid modifying external media files; Immich metadata lives in the Immich database unless the user explicitly configures sidecars.

Status: implementation in progress. The app now has a local memory-write
approval draft queue in the Memories panel, but it still does not send create or
update requests to Immich. The remote write path remains intentionally split
into [`docs/MEMORY_WRITE_PATH_DESIGN.md`](MEMORY_WRITE_PATH_DESIGN.md) so the
approval flow stays reviewed before any network write is added.

Phase 5 verification:

```bash
flutter test test/memory_write_flow_test.dart
flutter test test/widget_test.dart --plain-name "memory write draft"
```

## Phase 6: Notifications

- Add optional notification providers:
  - ntfy;
  - Gotify;
  - Pushover;
  - Home Assistant;
  - local desktop notification.
- Send notifications only after memory candidates are created or approved.
- Prefer private-network delivery. For outside-home access, document VPN/Tailscale/WireGuard or a trusted notification provider.
- Include an Immich deep link or server link when available.

Status: design in progress. The notification boundary is documented in
[`docs/NOTIFICATION_DELIVERY_DESIGN.md`](NOTIFICATION_DELIVERY_DESIGN.md), but
the app does not yet send notifications. Provider wiring remains out of scope
until that design is reviewed.

## Phase 7: Personal Ranking Model

- Start with explainable rules, not a trained model.
- Collect local feedback only after explicit opt-in:
  - opened;
  - ignored;
  - hidden;
  - favorited;
  - shared.
- Train or tune a lightweight local ranker only after enough feedback exists.
- Keep all feedback and scoring data local unless the user explicitly exports it.

Status: in progress. The app now includes an opt-in local feedback scaffold in
the Memories panel, and the Phase 7 boundary is documented in
[`docs/RANKING_FEEDBACK_DESIGN.md`](RANKING_FEEDBACK_DESIGN.md). The current
work stays local, and the preview can apply small rules-first score
adjustments from feedback without introducing a trained model.

Phase 7 verification:

```bash
flutter test test/memory_feedback_test.dart
flutter test test/widget_test.dart --plain-name "feedback"
```

Expected outcome:

- Feedback events are recorded only after explicit opt-in.
- Feedback stays local-only and is not exported or sent to external services.
- Preview ranking remains rules-first and only applies light local score
  adjustments, not a trained model.

## App Help Library Sources

- Immich mobile backup: https://docs.immich.app/features/mobile-backup
- Immich mobile app: https://docs.immich.app/features/mobile-app
- Immich external libraries: https://docs.immich.app/features/libraries
- Immich backup and restore: https://docs.immich.app/administration/backup-and-restore/
- Immich API: https://api.immich.app/endpoints

## Acceptance Criteria

- The app has a Help section covering mobile backup, private Docker access, memories, notifications, and backup safety.
- The help documentation exists in `docs/` and can be used without opening the app.
- Future Immich API features must keep read-only/dry-run behavior until the user explicitly approves changes.
- No API keys, mobile logs, personal URLs, or media paths are committed.
