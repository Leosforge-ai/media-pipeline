# Domain Context — media-pipeline

> Personal-media management domain. Reviewers: Cody (safety), Leila (personal data).

## Domain

Ingest a user's personal photo/video library (Google Takeout / Drive), normalize and de-duplicate, preserve metadata, and load into a self-hosted **Immich** server. The data is irreplaceable personal media — the entire design is **data-loss-averse** (dry-run, trash-not-delete, reversible).

## Pipeline

Numbered Bash/Python steps `scripts/00`–`12`: download/ingest (rclone) → metadata stitch (exiftool) → de-dup (czkawka) → load to Immich. The Flutter desktop app orchestrates with a dry-run-first UX. See `docs/IMMICH_*` and the app-plan docs.

## Immich

External library mounted **read-only**; upload storage (`/data`) separate from the library (`/library`). Compose under `immich/`. See `docs/IMMICH_EXTERNAL_LIBRARY.md`, `IMMICH_SETTINGS_STORAGE.md`.

## Compliance framing

Handles personal media (photos/videos) — personal data under GDPR, but **self-hosted / local** (no third-party transfer by default). Any feature moving media to an external service requires **Leila** review (company-os `policies/external-platforms.md`).
