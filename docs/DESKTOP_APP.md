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

1. Set `HD_PATH` and `REPORT_DIR`.
2. Run **System Check**.
3. Install or configure missing dependencies outside the app when needed.
4. Run pipeline steps in order.
5. Run duplicate cleanup dry-run and inspect the log output.
6. Use confirm cleanup only after the dry-run step succeeds in the same app session.

## Help Section

The app includes an **Immich Help** section for the parts users normally need while setting up a private photo server:

- private Docker server URLs and LAN/VPN access;
- phone backup setup;
- Android and iPhone background-upload caveats;
- external-library setup for `/library`;
- future private memories and notification direction;
- database and media backup safety.

The full source-backed help library is maintained in [`docs/IMMICH_HELP_LIBRARY.md`](IMMICH_HELP_LIBRARY.md). The major implementation plan for mobile backup guidance, memories, notifications, and a future personal ranking model is maintained in [`docs/MEMORIES_AND_MOBILE_PLAN.md`](MEMORIES_AND_MOBILE_PLAN.md).

## Immich Connection

The **Immich** section checks a private Immich server before future mobile backup and memory-curator features are enabled.

1. Enter the server URL, such as `http://localhost:2283` or `http://SERVER_IP:2283`.
2. Optionally enter an Immich API key from the web app user settings.
3. Select **Check Connection**.

The app runs `GET /api/server/ping` without credentials. If an API key is present, it also runs read-only authenticated server checks using the `x-api-key` header. The key is held only in memory for the running app session and is not written to project files.

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

## Safety Notes

- The app never adds `--confirm` to dry-run commands.
- Confirm steps are separate step definitions and are locked until their paired dry-run succeeds.
- The scripts remain the source of truth for media movement, metadata writes, Immich setup, and recovery behavior.
- Keep using a disposable test media folder when validating code changes.
- The Immich connection panel performs read-only HTTP GET checks only.
