# Ranking Feedback Design

This note defines the boundary for the future Phase 7 ranking work. It stays
rules-first and local-only so the app can collect opt-in feedback before any
trained model exists.

## Goal

Learn from the user's own choices so later memory ranking can be tuned without
uploading feedback off the device.

## Scope

- Start with explainable rules and local heuristics.
- Collect feedback only after the user explicitly opts in.
- Keep feedback local unless the user explicitly exports it.
- Keep the ranking layer separate from memory preview, write approval, and
  notification delivery.

## Feedback Events

The first supported events should be small and explicit:

- opened
- ignored
- hidden
- favorited
- shared

Each event should map to a local record keyed by the memory or candidate the
user saw.

## Local Data Model

The ranking layer should store only non-secret metadata needed to understand
behavior over time:

- candidate or memory identifier;
- event type;
- timestamp;
- optional short reason supplied by the user;
- model or ruleset version used when the event was recorded.

Do not store API keys, personal URLs, raw media paths, or full private captions
in the feedback log.

## Persistence

Persist feedback events to a local JSON file under the same app-data base used
by the rest of Media Pipeline state:

- `memory_feedback_events.json`

Example locations:

- macOS: `~/Library/Application Support/media_pipeline/memory_feedback_events.json`
- Linux: `~/.config/media_pipeline/memory_feedback_events.json`
- Windows: `%APPDATA%\media_pipeline\memory_feedback_events.json`

If the file is missing, initialize the app with an empty feedback list. If the
JSON is corrupt, parse defensively and ignore unreadable entries rather than
failing the whole app. To reset local feedback, close the app and delete
`memory_feedback_events.json`.

The file should remain readable only by the local user and must not contain
secrets.

## Scoring Rules

The first scoring pass should remain explainable and local:

- keep the current rules-based preview as the default signal source;
- apply feedback as a light local adjustment rather than a trained model;
- keep the user able to inspect why a candidate was ranked higher or lower;
- avoid hidden state changes that the user cannot review.

## Privacy And Safety Constraints

- No feedback collection without explicit opt-in.
- No cloud sync for feedback unless the user explicitly exports it.
- No auto-deletion or automatic writing based on feedback alone.
- No cross-user aggregation.
- No notification side effects from feedback collection.

## Future Implementation Boundary

The ranking code should read local candidate metadata and local feedback, then
emit adjusted scores for the preview UI. It should not call Immich directly, and
it should not depend on the memory write path or notification providers.

## Verification

Before implementation begins, keep validating the current preview and beta
gates:

```bash
flutter test test/widget_test.dart --plain-name "memory preview"
flutter test test/widget_test.dart --plain-name "queues a local memory write draft after approval"
flutter test
flutter analyze
python3 -m unittest discover -s tests
python3 -m compileall scripts config tests
ruff check scripts config tests
shfmt -d scripts/*.sh config/*.sh
```

## Non-Goals

- No trained ranker yet.
- No network sync for feedback.
- No public API for feedback export.
- No notification integration from ranking events.
