# media-pipeline-tools (Docker image)

Phase 1 of the cross-platform roadmap in [#76](https://github.com/Leosforge-ai/media-pipeline/issues/76)
(Design A — Docker-containerized tool runtime). This image bundles the four external CLI
tools the pipeline scripts already shell out to — `exiftool`, `ffmpeg`/`ffprobe`, `rclone`,
`czkawka_cli` — at pinned, verified versions, multi-arch (`linux/amd64` + `linux/arm64`, the
latter for Apple Silicon Macs).

**This image is not wired into the pipeline yet.** No `scripts/*.sh` file calls it. That's
Phase 2 of #76, a separate future PR. This phase only proves the container exists, builds
for both architectures, and the tools actually run inside it.

## What's in it

| Tool | Version | Install method |
|---|---|---|
| `exiftool` | 12.57 (Debian package `libimage-exiftool-perl=12.57+dfsg-1`) | apt, pinned exact version |
| `ffmpeg` / `ffprobe` | 5.1.9 (Debian package `ffmpeg=7:5.1.9-0+deb12u1`) | apt, pinned exact version |
| `rclone` | v1.74.4 | upstream release binary, checksum-verified |
| `czkawka_cli` | 12.0.0 | upstream GitHub release binary, checksum-verified |
| `sha256sum` (GNU coreutils) | 9.1 (Debian package `coreutils=9.1-1`) | transitive — see below |

Base image: `debian:bookworm-slim`, pinned by digest (see the `FROM` line in `Dockerfile`).
Debian 12 (bookworm) is a minimal, long-term-supported base (security support into ~2028),
already has the two apt-installable tools at recent, security-patched versions, and is the
same base OS family this repo's existing dependency script (`scripts/01_setup_dependencies.sh`)
targets — so containerized behavior matches what the Bash pipeline expects on a native Ubuntu/
Debian host.

### Deviations from `scripts/01_setup_dependencies.sh`

- **`rclone`**: the host script installs rclone via `apt-get install rclone`, which on Debian
  bookworm resolves to **v1.60.1** — several years behind upstream and missing fixes in active
  use for Google Drive remotes. This image installs the upstream release binary instead,
  pinned to `v1.74.4` and checksum-verified against rclone's published `SHA256SUMS`. If this
  version gap ever causes a behavioral difference against the Bash scripts, that's a Phase 2
  concern (when the container is actually wired up) — flag it there.
- **`czkawka_cli`**: the host script's `install_czkawka()` downloads from GitHub's `latest`
  release tag, which is not reproducible (a bump in `qarmin/czkawka` upstream silently changes
  what the host installs on next fresh setup). This image pins an exact tag (`12.0.0`) instead,
  matching the download-a-release-binary method but making it reproducible. czkawka does not
  publish a `SHA256SUMS` file, so the pinned checksums in the `Dockerfile` were computed at
  pin-time from the downloaded assets and must be recomputed on every version bump (see below).
- **`exiftool`** and **`ffmpeg`**: same apt package family as the host script; pinned to the
  exact package version present in the `debian:bookworm-slim` snapshot pinned in the `Dockerfile`,
  so a Debian point release doesn't silently swap versions on you.

### GNU coreutils / `sha256sum` — provenance and pinning (transitive, not explicit)

`lib/src/clean_takeout_duplicates.dart`'s `TakeoutDuplicateCleaner` uses this image's
`sha256sum` (via `containerFileHasher`, part of #76 Phase 2 container wiring) for its
three-way basename+size+SHA-256 duplicate verification. Unlike the four tools in the table
above, `sha256sum` is **not** explicitly `apt-get install`ed anywhere in `Dockerfile` — it
ships as part of **GNU coreutils**, which Debian marks `Essential: yes`, meaning it is
present in literally every Debian/`bookworm-slim` image, this one included, without any
install line at all. This was flagged as an undocumented gap in Astrid's review of PR #93
(the `ToolsContainer` plumbing PR): `sha256sum` was known to work, but — unlike `exiftool`/
`ffmpeg`/`rclone`/`czkawka_cli` — its provenance and version were never written down anywhere.

**Verified version, at the `FROM` line's currently-pinned digest**
(`debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818`):

```
$ docker run --rm media-pipeline-tools:local bash -c "sha256sum --version | head -1; dpkg -s coreutils | grep Version"
sha256sum (GNU coreutils) 9.1
Version: 9.1-1
```

**Why this is still considered "pinned" despite no explicit `ARG`/version line in the
`Dockerfile`:** the `FROM debian:bookworm-slim@sha256:...` line pins the entire base image
by content digest, and coreutils is bundled inside that same digest-pinned image — so the
coreutils (and therefore `sha256sum`) version is exactly as reproducible, build-to-build, as
`exiftool`'s or `ffmpeg`'s explicit `ARG` pins are. The *only* difference is that this
document is the sole place recording what that transitively-pinned version currently
resolves to; the `Dockerfile` itself carries a short inline comment (next to the other `ARG`
pins) pointing here, but deliberately does not add an `apt-get install coreutils=...` line —
see that comment for why (an `Essential: yes` package can't be absent from any
`debian:bookworm-slim` image, so an explicit install/pin line would add ceremony without
adding any actual reproducibility the digest pin doesn't already provide).

**How to verify/re-check after a base-image bump:** re-run the `docker run` one-liner above
against the freshly built image (after bumping the `FROM` digest — see "Bumping a pinned tool
version" below) and update the version numbers in the table and this section if they changed.
Unlike `czkawka_cli`, this needs no separate checksum step — `apt`'s own package integrity
checking already covers it, exactly as it does for `exiftool`/`ffmpeg`.

## Building locally

Single-arch (fast, for local iteration — builds only for your host's architecture):

```bash
docker build -t media-pipeline-tools:local -f docker/tools/Dockerfile docker/tools
```

Multi-arch (what CI/release should do — requires a `docker buildx` builder with the
`docker-container` driver, since the default driver can't export multi-platform images):

```bash
docker buildx create --name media-pipeline-tools-builder --use   # one-time setup
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -f docker/tools/Dockerfile \
  -t media-pipeline-tools:latest \
  docker/tools \
  --push   # or --load (single-platform only) / omit to just verify the build
```

`--push` requires a registry destination in `-t` (e.g. `ghcr.io/leosforge-ai/media-pipeline-tools:latest`).
Registry distribution (GHCR, matching how Immich itself is distributed) is a Phase 1/2
decision still open in #76 — not made in this PR.

## Debugging: shell into the image

```bash
docker run --rm -it media-pipeline-tools:local bash
```

The image runs as a non-root user (`tools`, uid 10000) with `WORKDIR /work` by default — this
is a safe default for standalone verification so any files the container creates aren't
root-owned; Phase 3 of #76 covers proper host UID/GID mapping for the real bind-mount use case.

To run a single tool without a shell:

```bash
docker run --rm media-pipeline-tools:local exiftool -ver
docker run --rm media-pipeline-tools:local ffmpeg -version
docker run --rm media-pipeline-tools:local rclone version
docker run --rm media-pipeline-tools:local czkawka_cli --version
```

To exercise `czkawka_cli` against real files, bind-mount a directory in:

```bash
docker run --rm -v /path/to/test/dir:/data:ro media-pipeline-tools:local \
  czkawka_cli dup -d /data -f /tmp/report.txt
```

Note: `czkawka_cli`'s default `--minimal-file-size` is 8192 bytes — files smaller than that
are skipped unless you pass `-m 1` (or another explicit minimum). Also note its exit code is
not a simple 0/non-zero success flag: it returns `0` when no duplicates are found, and a
non-zero count-like code when duplicates *are* found. Anything that wraps this command under
`set -euo pipefail` (as `scripts/05_cleanup_scan.sh` already does today, unrelated to this PR)
needs to account for that — flagged here for Phase 2 awareness, not fixed in this PR since it's
pre-existing Bash-script behavior, out of scope for a container-only change.

## Bumping a pinned tool version

Mirrors the version-bump discipline in `.github/workflows/gitleaks.yml`'s inline comments.

1. **`exiftool` / `ffmpeg`** (apt packages): decide whether to bump the base image or just the
   package pin.
   - To pick up a Debian security update at the *same* Debian release: run
     `docker run --rm debian:bookworm-slim bash -c "apt-get update -qq && apt-cache policy libimage-exiftool-perl ffmpeg"`
     against a fresh `debian:bookworm-slim` pull, note the new candidate versions, and update
     `EXIFTOOL_APT_VERSION` / `FFMPEG_APT_VERSION` in the `Dockerfile` to match.
   - Also re-pin the `FROM debian:bookworm-slim@sha256:...` digest to the freshly pulled image
     (`docker inspect debian:bookworm-slim --format '{{.RepoDigests}}'`) so the two stay in sync.
2. **`rclone`**: check the latest stable release (`curl -s https://downloads.rclone.org/version.txt`
   or the GitHub releases page), then fetch its published checksums:
   `curl -s https://downloads.rclone.org/vX.Y.Z/SHA256SUMS | grep -E 'linux-amd64.zip|linux-arm64.zip'`
   and update `RCLONE_VERSION`, `RCLONE_SHA256_AMD64`, `RCLONE_SHA256_ARM64` in the `Dockerfile`.
3. **`czkawka_cli`**: check the latest tag at `https://github.com/qarmin/czkawka/releases`,
   download both `linux_czkawka_cli_x86_64` and `linux_czkawka_cli_arm64` for that tag, compute
   `sha256sum` on each yourself (czkawka does not publish a checksums file — this is a
   trust-on-first-use pin, so download over HTTPS from the official repo only), and update
   `CZKAWKA_VERSION`, `CZKAWKA_SHA256_AMD64`, `CZKAWKA_SHA256_ARM64` in the `Dockerfile`.
4. **`sha256sum` / GNU coreutils** (transitive, via the base image — see "GNU coreutils /
   `sha256sum`" above): whenever step 1 re-pins the `FROM debian:bookworm-slim@sha256:...`
   digest, re-run `docker run --rm media-pipeline-tools:local bash -c "sha256sum --version |
   head -1; dpkg -s coreutils | grep Version"` against the rebuilt image and update the
   version numbers in the table and that section if they changed. No separate `Dockerfile`
   change is needed (there is no explicit coreutils pin to update) — this step is purely
   about keeping this document's recorded version accurate, not about changing pinning
   behavior.
5. Rebuild both platforms locally (see above), re-run the version checks and a synthetic
   `czkawka_cli dup` scan (see "Debugging" above) before merging — a checksum mismatch fails
   the build loudly (`sha256sum -c -` exits non-zero), but a *wrong* pinned checksum copied from
   the wrong asset would not be caught by the build itself.
6. Update this table and the "Deviations" section above if the new version changes the
   deviation rationale.
