# Memory Preview Immich Adapter

This note defines the read-only adapter boundary for feeding real Immich data
into the local memory-preview scorer.

## Purpose

The current preview engine works on already-loaded asset metadata. The adapter
described here is the smallest bridge needed to fetch that metadata from a
private Immich server without introducing any write path.

## Data Contract

The adapter should return a list of assets that can be mapped to
`MemoryPreviewAsset` with the following minimum fields:

- asset identifier
- taken-at timestamp
- favorite flag
- album names
- people names when available
- city or place label when available
- screenshot, receipt, blurry, and near-duplicate hints when available

Optional metadata should be treated as best-effort only. If a field is missing,
the adapter should supply a safe default rather than fail the preview.

## Read-Only API Boundary

The adapter may read from Immich endpoints that support:

- authenticated server information needed to confirm the connection;
- asset listing or search queries needed to discover candidate media;
- lightweight read-only metadata lookups needed to populate the preview model.

The adapter must not call any endpoint that creates, updates, deletes, or
approves memories or assets.

## Failure Behavior

- If the API key is invalid, the app should show a readable connection error.
- If a read-only metadata field is missing, the preview should still render with
  reduced detail.
- If one page or query fails, the adapter should fail the preview gracefully
  instead of mutating remote state.
- If the server is reachable but returns partial data, the preview should still
  show any assets that were successfully loaded.

## Safety Constraints

- Keep the API key in memory only.
- Do not persist the API key in local JSON settings.
- Do not write sidecar files, memory records, or server state from the adapter.
- Do not use the adapter to trigger notifications or ranking feedback.

## Acceptance Criteria

- The preview can load real assets from a private Immich server using a
  read-only adapter.
- The preview scorer still runs locally on the loaded metadata.
- Missing optional metadata does not block the preview.
- No Immich writes are performed by the adapter.

## Verification

Run these checks against a private Immich server and API key before enabling
the adapter in normal app use:

```bash
# 1) Connectivity check with no key
curl -fsS "$IMMICH_URL/api/server/ping"

# 2) Read-only authenticated server info
curl -fsS -H "x-api-key: $IMMICH_API_KEY" "$IMMICH_URL/api/server/about" >/tmp/immich_about.json

# 3) Read-only asset listing
curl -fsS -H "x-api-key: $IMMICH_API_KEY" "$IMMICH_URL/api/assets?withDeleted=false" >/tmp/immich_assets_page1.json
```

Expected results:

- The ping endpoint succeeds without a key.
- The authenticated read-only endpoints succeed with a valid key.
- The adapter only reads data and does not emit any create, update, delete, or
  approve calls.
- The preview still renders when optional metadata is missing.

Where to inspect results:

- The saved JSON files in `/tmp` for manual inspection.
- The app log output for read-only fetch errors or missing optional metadata.
- The preview panel for rendered candidates and exclusions.
