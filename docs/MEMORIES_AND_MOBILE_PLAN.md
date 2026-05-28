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

## Phase 5: Create Memories In Immich

- Add explicit user approval before creating or updating Immich memories.
- Use API-key authentication and Immich memory endpoints.
- Keep dry-run preview as the default.
- Record created memory IDs locally for later update/removal.
- Avoid modifying external media files; Immich metadata lives in the Immich database unless the user explicitly configures sidecars.

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
