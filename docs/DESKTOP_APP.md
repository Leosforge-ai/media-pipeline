# Desktop App

The desktop app is a Flutter controller for the media cleanup pipeline. It keeps the same
safety model as the original scripts: dry-runs stay visible, confirm actions stay explicit,
and duplicate cleanup still moves files into `media_trash`, never deletes.

## Execution model

Every pipeline step is either:

- **Container-routed (`dartAction`)** — the step's logic is native Dart, and any external
  tool it needs (`exiftool`, `ffmpeg`, `rclone`, `czkawka_cli`) runs inside the pinned
  `media-pipeline-tools` Docker image (see [`docker/tools/README.md`](../docker/tools/README.md)),
  one container session per step. This covers the duplicate scan, metadata stitch, both
  trash-confirm steps (duplicate delete, restore-from-trash), and the Immich Takeout
  duplicate dry-run. No native tool install is required for these on any platform.
- **Native subprocess (`command`)** — the step still shells out to the original
  `scripts/*.sh`/`.py` file on the host (system check, dependency install, rclone config,
  Immich setup/verify, sync-to-library, cleanup verify). These are Linux-only or genuinely
  need host-level access (`sudo`, interactive prompts, real device visibility) that a
  container can't provide.

Only Docker is required to build and run the container-routed steps — see the desktop app's
own `requiredTools` checks per step in the UI.

## Platform Support

| Platform | Status |
| --- | --- |
| Linux | Full support, both container-routed and native steps. |
| ChromeOS | Supported through the ChromeOS Linux development environment. |
| macOS | App builds and runs; container-routed steps are architecturally cross-platform (Docker Desktop) but not yet verified end-to-end on real hardware. Native/Linux-only steps stay guarded. |
| Windows | Same as macOS. Additionally, the UID/GID host-file-ownership fix (`ToolsContainer`'s `--user` override) is Linux/macOS-only — Windows falls back to the container image's default user, so file ownership on the host may not match your account. Tracked in [#76](https://github.com/Leosforge-ai/media-pipeline/issues/76) Phase 5. |

See [#76](https://github.com/Leosforge-ai/media-pipeline/issues/76) for the full cross-platform roadmap and current status.

## Run Locally

```bash
flutter pub get
flutter run -d linux
```

For non-Linux development machines, use the matching Flutter desktop target:

```bash
flutter run -d macos
flutter run -d windows
```

## Workflow

The app has two modes for running the pipeline: a **Guided Run** that chains
the safe steps automatically, and the original **manual, per-step** mode
where every step is triggered by hand. Both share the same underlying step
definitions, safety gates, and run log — Guided Run does not skip or relax
any confirmation gate.

### Manual mode

1. Set `HD_PATH` and `REPORT_DIR`.
2. Run **System Check**.
3. Install or configure missing dependencies outside the app when needed
   (`setup-dependencies` and `configure-rclone` run interactive/`sudo`
   prompts and are always manual-only, even under Guided Run).
4. Run pipeline steps in order, one at a time.
5. Run duplicate cleanup dry-run (**Review Duplicate Move Plan**) and inspect
   the log output.
6. Open the **duplicate thumbnail review** (see below) — it must be
   acknowledged before the confirm step unlocks.
7. Run **Move Duplicates To Trash** from the app when you're ready. This is
   a real, working confirm button in the app UI, not CLI-only — it stays
   locked until both the dry-run has succeeded in the current app session
   and the thumbnail review has been acknowledged for that dry-run's
   output.

### Guided Run

Guided Run chains the safe, non-interactive steps of a full "clean and
import" pass automatically instead of requiring separate manual triggers for
each one: system check → stitch metadata → scan duplicates → duplicate
dry-run → verify cleanup → sync to the Immich library. It runs one segment
at a time and stops immediately if any step fails.

Guided Run always stops and waits for you at two checkpoints, each requiring
the same explicit action as manual mode:

1. **Before the delete-confirm step.** After the duplicate dry-run finishes,
   Guided Run pauses. Review the dry-run output and the thumbnail-diff
   dialog, then trigger **Move Duplicates To Trash** yourself — Guided Run
   never runs a confirm-gated step automatically; attempting to include one
   in the automatic chain is a hard error the app is tested against.
2. **Before the Immich rescan implied by syncing.** After copying the
   cleaned staging files into `immich_library`, Guided Run pauses so you can
   restart Immich / trigger a rescan on your own terms before continuing.

Interactive or privileged one-time setup steps (`setup-dependencies`,
`configure-rclone`, `setup-immich`, `verify-immich`, and the Immich Takeout
duplicate dry-run) are never part of the automatic Guided Run chain — they
stay in the manual per-step list, same as before Guided Run existed.

### Duplicate thumbnail review

Before **Move Duplicates To Trash** becomes available (in both manual mode
and Guided Run), the app shows a **Review Duplicate Move Plan** dialog: a
side-by-side thumbnail comparison of every proposed keep/trash pair from the
dry-run output, instead of asking you to trust raw Czkawka report text.

- It reads back only the exact `Keep: ...` / `Would trash: ...` lines the
  dry-run itself already produces — never the raw Czkawka report files, and
  never re-deriving which file would be kept.
- Large duplicate sets are sampled to at most 20 pairs per batch (a fixed,
  reproducible sample), with a **Review Another Sample** button to draw
  more. A coverage banner always shows an honest running total, e.g. "You
  reviewed 40 of 5,412 pairs (1%)" — for very large sets (200+ pairs, under
  10% reviewed) an extra warning explains that the percentage is still a
  small fraction and suggests reviewing more or spot-checking folders,
  rather than letting a rising percentage feel more conclusive than it is.
- Still images render inline; videos and unsupported formats show a file
  icon and filename instead.
- Opening the review marks it acknowledged for the dry-run output that
  produced it. Re-running the dry-run (manually or via Guided Run) resets
  the acknowledgment, since a new dry-run can find a different duplicate
  set — you must review again before confirming.
- This is an **additional** gate on top of the existing dry-run requirement,
  never a replacement for it: `06_delete_duplicates.sh`'s own Czkawka-report
  parsing is unchanged.

## Help Section

The app includes an **Immich Help** section for the parts users normally need while setting up a private photo server:

- private Docker server URLs and LAN/VPN access;
- phone backup setup;
- Android and iPhone background-upload caveats;
- phone backup checklist state stored locally as JSON;
- external-library setup for `/library`;
- Google Takeout localized year duplicates and the dry-run cleanup step;
- future private memories and notification direction;
- database and media backup safety.

The runner can now pass typed stdin to child processes, but the duplicate
cleanup confirm action still stays separate from the dry-run action. The design
note for the typed confirm UI lives in
[`docs/IMMICH_DUPLICATE_CONFIRM_MODE.md`](IMMICH_DUPLICATE_CONFIRM_MODE.md).

The full source-backed help library is maintained in [`docs/IMMICH_HELP_LIBRARY.md`](IMMICH_HELP_LIBRARY.md). A custom memory-curator/ranking-feedback feature was designed and partially built ([`docs/MEMORIES_AND_MOBILE_PLAN.md`](MEMORIES_AND_MOBILE_PLAN.md)) but is currently on hold in favor of Immich's own native Machine Learning (facial recognition, Smart Search) and Memories features — see [#111](https://github.com/Leosforge-ai/media-pipeline/issues/111).

## Immich Connection

The **Immich** section checks a private Immich server before future mobile backup and memory-curator features are enabled.

1. Enter the server URL, such as `http://localhost:2283` or `http://SERVER_IP:2283`.
2. Optionally enter an Immich API key from the web app user settings.
3. Select **Check Connection**.

The app runs `GET /api/server/ping` without credentials. If an API key is present, it also runs read-only authenticated server checks using the `x-api-key` header. The key is held only in memory for the running app session and is not written to project files.

When authenticated checks succeed, the app shows a read-only **Immich Server Statistics** panel for server version, photo count, video count, and storage usage. Missing statistics are shown as unavailable instead of failing the connection check.

Test the connection manually:

```bash
curl -i http://localhost:2283/api/server/ping
curl -i -H "x-api-key: YOUR_API_KEY" http://localhost:2283/api/server/about
curl -i -H "x-api-key: YOUR_API_KEY" http://localhost:2283/api/server/statistics
```

Replace `http://localhost:2283` with your own private Immich URL and `YOUR_API_KEY` with a key from your Immich web app. These commands reproduce the app checks outside the UI, which is useful for troubleshooting connectivity and permissions.

Common failure meanings:

- `Invalid URL` usually means the server URL is malformed. Check the scheme, host, port, path, whitespace, and typos so the app can reach the right Immich base URL.
- `Server unreachable` usually means the URL is wrong, the container is down, or the app cannot reach your LAN/VPN network.
- `API key rejected` usually means the key is invalid or missing `server.about` access.
- `Missing permission` means the key can talk to Immich, but it does not have `server.statistics`; the app can still verify the server and read basic info.

## Phone Backup Checklist Storage

The app keeps the phone backup checklist in a local JSON file only. It does not store API keys in that file.

- Linux: `~/.config/media_pipeline/immich_phone_checklists.json`
- macOS: `~/Library/Application Support/media_pipeline/immich_phone_checklists.json`
- Windows: `%APPDATA%\media_pipeline\immich_phone_checklists.json`

## Safety Notes

- The app never adds `--confirm` to dry-run commands, and never constructs a confirm action implicitly.
- Confirm steps are separate step definitions and are locked until their paired dry-run succeeds — this gate is enforced identically regardless of whether a step runs as a container-routed `dartAction` or a native `command`.
- For container-routed steps (see [Execution model](#execution-model) above), the Dart code is the actual, live implementation of media movement, metadata writes, and duplicate cleanup — not a wrapper around the Bash/Python scripts. The original scripts remain a fully maintained fallback for those specific steps, and the sole implementation for everything not yet container-routed (Immich setup, sync, verification, rclone config).
- Keep using a disposable test media folder when validating code changes.
- The Immich connection panel performs read-only HTTP GET checks only.
