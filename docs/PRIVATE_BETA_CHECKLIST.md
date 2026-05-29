# Private Beta Checklist

This checklist defines what must be true before the Immich work is treated as private-beta ready. It is not a public-release checklist.

## Required Checks

- `flutter test`
- `flutter analyze`
- Python tests and syntax checks used by the repo
- Shell lint checks used by the repo
- Manual smoke test of the Immich section in the desktop app

## Required Smoke Tests

- Verify the app can reach a private Immich server over localhost, LAN, or VPN.
- Verify ping-only behavior still works when no API key is entered.
- Verify authenticated server info works with a valid API key.
- Verify missing statistics do not break the connection check.
- Verify the phone backup checklist persists locally and does not store secrets.

## Supported Platforms For Beta

- The primary desktop platform used by the repo.
- One additional local platform if available in CI or on the workstation.

## Known Limitations

- API keys stay in memory only until a proper credential-store design is approved.
- Memory-curator work remains preview-only.
- Notifications are not part of the core beta scope.
- Public packaging, signing, and distribution are still deferred.

## Not Public Release Ready

This build should not be described as public or generally available until all of the following exist:

- credential storage design and implementation;
- release packaging and signing;
- upgrade and migration coverage for local files;
- broader multi-platform smoke testing;
- a privacy review for any future memory write path.
