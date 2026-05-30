# Memory Write Path Design

This document defines the approval and safety boundary for the future Phase 5
write path. It is intentionally separate from the preview path and must stay
that way until implementation is approved.

## Goal

Allow a user to take a locally generated memory candidate and create or update
the corresponding Immich memory through the private Immich API, with explicit
user approval before any remote write happens.

## Scope

- Keep preview generation read-only.
- Require an explicit approval step before any create or update request.
- Record successful memory writes locally so later updates can reference them.
- Keep API keys in memory only while the app session is active.

## Required User Flow

1. Load memory candidates in preview mode.
2. Select a candidate.
3. Show a confirmation screen that summarizes:
   - the assets involved;
   - the scoring reasons;
   - the exact write action to be performed;
   - the Immich account/server being targeted.
4. Require a clear affirmative action before sending any write request.
5. Before sending the remote request, create a durable local `pending` record
   for the candidate with a generated idempotency token.
6. After success, update that local record with the returned memory identifier
   and mark it `committed`.

## Write Rules

- Do not create, update, or delete memories without explicit approval.
- Do not modify uploaded media files or external library files as part of the
  write flow.
- Do not write sidecar files unless a future setting explicitly enables them.
- Keep the dry-run preview as the default action.
- If the remote request fails, leave the local preview candidate unchanged and
  keep the local record in `pending` so the user can retry safely.

## Local State

The app should store only non-secret metadata needed to manage future updates:

- candidate identifier;
- remote memory identifier;
- selected state or approval state;
- write state (`pending` or `committed`);
- idempotency token for the write attempt;
- timestamps for local bookkeeping.

Do not store API keys, personal URLs, or media paths in this local record.

## Failure Handling

- If the API key is missing or invalid, refuse the write flow before sending
  the request.
- If the server returns an error, surface it in the UI and keep the candidate
  in preview mode.
- If the local `pending` record cannot be written, do not send the remote
  request.
- If the remote write succeeds but the local record cannot be finalized, keep
  the record in `pending`, surface a warning in the UI, and retry finalization
  on the next app launch or explicit retry action.
- Use the stored idempotency token when retrying the remote request so a
  repeated submission does not create a duplicate memory.

## Future Implementation Boundary

The eventual implementation should use the existing read-only preview engine as
its input and must keep the write code path isolated from preview scoring.
The preview UI should remain usable even when write support is unavailable.

## Verification

Before implementation begins, keep validating the current preview and beta
gates:

```bash
flutter test --plain-name "memory preview"
flutter test
flutter analyze
python3 -m unittest discover -s tests
python3 -m compileall scripts config tests
ruff check scripts config tests
shfmt -d scripts/*.sh config/*.sh
```

## Non-Goals

- No memory write endpoint wiring yet.
- No notification dispatch.
- No ranking model changes.
- No public-release packaging work.
