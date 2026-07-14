# Desktop App

The desktop app is a Flutter controller for the existing media pipeline scripts. It does not replace the safety model in the scripts: dry-runs stay visible, confirm actions stay explicit, and duplicate cleanup still moves files into `media_trash`.

## Platform Support

| Platform | v1 support |
| --- | --- |
| Linux | Full app workflow when the required command-line tools are installed. |
| ChromeOS | Supported through the ChromeOS Linux development environment. |
| macOS | App can run and show workflow/configuration, but Linux-only dependency and Immich setup steps are guarded. |
| Windows | App can run and show workflow/configuration, but Linux-only dependency and Immich setup steps are guarded. |

The underlying media workflow still depends on tools such as Python, Bash, ExifTool, FFmpeg, rclone, Czkawka CLI, Docker, and Docker Compose. The app surfaces those checks instead of silently installing or running risky operations on unsupported platforms.

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
7. Run **Move Duplicates To Trash** (`06_delete_duplicates.sh --confirm`)
   from the app when you're ready. This is a real, working confirm button in
   the app UI, not CLI-only — it stays locked until both the dry-run has
   succeeded in the current app session and the thumbnail review has been
   acknowledged for that dry-run's output.

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

- It reads back only the exact `Keep: ...` / `Would trash: ...` lines that
  `06_delete_duplicates.sh` itself already prints during a dry-run — never
  the raw Czkawka report files, and never re-deriving which file would be
  kept.
- Large duplicate sets are sampled to at most 20 pairs (a fixed, reproducible
  sample). The dialog always shows an honest count, e.g. "Showing 20 of 137
  pairs — full list in the dry-run report," so nothing is silently hidden.
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

The full source-backed help library is maintained in [`docs/IMMICH_HELP_LIBRARY.md`](IMMICH_HELP_LIBRARY.md). The major implementation plan for mobile backup guidance, memories, notifications, and a future personal ranking model is maintained in [`docs/MEMORIES_AND_MOBILE_PLAN.md`](MEMORIES_AND_MOBILE_PLAN.md).

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

- The app never adds `--confirm` to dry-run commands.
- Confirm steps are separate step definitions and are locked until their paired dry-run succeeds.
- The scripts remain the source of truth for media movement, metadata writes, Immich setup, and recovery behavior.
- Keep using a disposable test media folder when validating code changes.
- The Immich connection panel performs read-only HTTP GET checks only.
