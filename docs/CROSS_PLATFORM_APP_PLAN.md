# Cross-Platform Desktop App Transformation Plan

## Summary

Transform the current Linux-first media-cleanup pipeline into a Flutter desktop app for Linux, macOS, Windows, and ChromeOS through the ChromeOS Linux environment. The v1 app will wrap the existing shell and Python scripts as the trusted execution engine, preserving the repository's safety-first behavior.

Branch: `feature-cross-platform-desktop-app`

## Safety Rules

- No destructive action runs by default.
- Duplicate cleanup must run in dry-run mode before confirm mode is enabled.
- Confirm mode must remain explicit and visible in both UI and command construction.
- Existing scripts remain the source of truth for media processing behavior.
- Media is moved to `media_trash`; the app must not permanently delete media.

## Implementation Steps

| Step | Status | Commit | Verification | Notes |
| --- | --- | --- | --- | --- |
| 1. Create branch and planning artifacts | Complete | `75073c7` | Plan document and memory file created. | Branch created as `feature-cross-platform-desktop-app` because slash refs were blocked by local `.git` sandboxing. |
| 2. Scaffold Flutter desktop app | Complete | `b439119` | Flutter scaffold generated and smoke test updated. | App shell preserves existing scripts and docs. |
| 3. Add pipeline runner and step model | Complete | `9b3a932` | `flutter analyze`; `flutter test` | Stream logs, pass env vars, capture exit codes. |
| 4. Build core UI | Complete | `9b3a932` | `flutter analyze`; `flutter test` | Operational workflow, path settings, logs, guarded actions. |
| 5. Add platform and dependency checks | Complete | `9b3a932` | `flutter analyze`; `flutter test` | Linux/ChromeOS full support; macOS/Windows guarded support. |
| 6. Integrate safety-critical workflows | Complete | `9b3a932` | `flutter analyze`; `flutter test` | Dry-run review before confirm cleanup or restore. |
| 7. Add tests and CI | Complete | `1854d6f` | `flutter analyze`; `flutter test`; CI workflow updated. | Flutter model/widget tests added. |
| 8. Update user documentation | Complete | `1854d6f` | Documentation updated. | README, instructions, and app usage docs. |
| 9. Final verification and push | Complete | `4ab9af8` | `flutter analyze`; `flutter test`; `python3 -m compileall scripts config`. | Structured commits ready for origin push. |

## Public Interfaces

- App settings: `HD_PATH`, `REPORT_DIR`, optional environment overrides.
- App step model: step id, display name, command, platform support, required dependencies, safety level, dry-run requirement, status, logs.
- Existing script CLI contracts remain unchanged unless a small compatibility fix is required for reliable orchestration.

## Test Plan

- Existing checks: ShellCheck, shfmt, Python compile, Ruff, yamllint, Docker Compose config.
- Flutter checks: `flutter analyze`, `flutter test`, desktop build where locally supported.
- Unit coverage for command construction, confirm gating, environment handling, dependency parsing, and step state transitions.

## Progress Log

- 2026-05-28: Started implementation on `feature-cross-platform-desktop-app`.
- 2026-05-28: Completed planning artifact setup; commit `75073c7`.
- 2026-05-28: Completed Flutter desktop scaffold; commit `b439119`.
- 2026-05-28: Added typed pipeline model, process runner, guarded desktop UI, and Flutter tests; commit `9b3a932`. Verification: `flutter analyze` passed; `flutter test` passed.
- 2026-05-28: Added Flutter CI job and desktop app documentation; commit `1854d6f`.
- 2026-05-28: Final local verification: `flutter analyze` passed; `flutter test` passed; `python3 -m compileall scripts config` passed. Linux desktop build could not complete locally because `cmake` is not installed. `shellcheck`, `shfmt`, `ruff`, and `yamllint` are also not installed locally and remain covered by CI.
- 2026-05-28: Final plan status updated; commit `4ab9af8`.
- 2026-05-28: Added Immich mobile backup and memories expansion plan, source-backed help library, and in-app Immich Help section.
