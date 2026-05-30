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
  ```bash
  flutter test --plain-name "Immich connection"
  ```
- Verify ping-only behavior still works when no API key is entered.
  ```bash
  flutter test --plain-name "ping-only"
  ```
- Verify authenticated server info works with a valid API key.
  ```bash
  flutter test --plain-name "authenticated server info"
  ```
- Verify missing statistics do not break the connection check.
  ```bash
  flutter test --plain-name "missing statistics"
  ```
- Verify the phone backup checklist persists locally and does not store secrets.
  ```bash
  flutter test --plain-name "phone backup checklist"
  ```
- Verify the phone backup troubleshooting section renders in the app help view.
  ```bash
  flutter test --plain-name "backup troubleshooting"
  ```
- Verify the memory preview panel still shows sample-ready, loading, empty, and
  error states.
  ```bash
  flutter test --plain-name "memory preview"
  ```
- Verify the memory preview docs stay read-only and do not describe any write
  path.
  ```bash
  flutter test --plain-name "memory preview"
  flutter analyze
  python3 -m unittest discover -s tests
  python3 -m compileall scripts config tests
  ruff check scripts config tests
  shfmt -d scripts/*.sh config/*.sh
  ```

## Supported Platforms For Beta

- The primary desktop platform used by the repo.
- One additional local platform if available in CI or on the workstation.

## Known Limitations

- API keys stay in memory only until a proper credential-store design is approved.
- Memory-curator work remains preview-only.
- The read-only Immich adapter is documented but not yet wired to live assets.
- Notifications are not part of the core beta scope.
- Public packaging, signing, and distribution are still deferred.

## Not Public Release Ready

This build should not be described as public or generally available until all of the following exist:

- credential storage design and implementation;
- release packaging and signing;
- upgrade and migration coverage for local files;
- broader multi-platform smoke testing;
- real-asset memory preview adapter wiring;
- a privacy review for any future memory write path.
