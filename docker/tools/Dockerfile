# media-pipeline-tools — Phase 1 of #76 (Cross-platform via Container Runtime)
#
# Bundles the four external CLI tools the pipeline scripts already shell out to
# (exiftool, ffmpeg/ffprobe, rclone, czkawka) at pinned, verified versions, in one
# multi-arch (linux/amd64, linux/arm64) image. This image is NOT wired into the
# pipeline yet — that is Phase 2 of #76, a separate PR. This Dockerfile only
# proves the tools exist, at known versions, and actually run.
#
# Build (multi-arch): see docker/tools/README.md for the full buildx command and
# the version-bump procedure (same pattern as .github/workflows/gitleaks.yml's
# pinned-version bump comments).

FROM debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818

# --- Pin versions here. Bump procedure is documented in docker/tools/README.md. ---
# exiftool / ffmpeg: pinned to exact Debian bookworm package versions (the same
# baseline scripts/01_setup_dependencies.sh installs via apt on the host today),
# so containerized behavior matches the existing Bash pipeline's expectations.
ARG EXIFTOOL_APT_VERSION=12.57+dfsg-1
ARG FFMPEG_APT_VERSION=7:5.1.9-0+deb12u1
# rclone: Debian bookworm's apt version (1.60.1) is several years behind upstream
# and missing fixes/features in active use for Google Drive remotes, so this is
# pinned to an upstream release binary instead (deviation from apt, documented in
# docker/tools/README.md), verified against the official published SHA256SUMS.
ARG RCLONE_VERSION=v1.74.4
# czkawka: not in Debian's apt repos at all. scripts/01_setup_dependencies.sh
# already installs it from a GitHub release binary — but from "latest", which is
# not reproducible. This pins an exact tag instead, verified by a checksum
# recorded at pin time (czkawka does not publish a SHA256SUMS file).
ARG CZKAWKA_VERSION=12.0.0
ARG CZKAWKA_SHA256_AMD64=ad21a5428aee09fad88fb6d35fb1c656b9e0b8cdafee2de107618ddb5a9997ff
ARG CZKAWKA_SHA256_ARM64=2d7a66cf626d64ae578e2ef502df5ea9e82aeab3d890853a2e15118c430d8a37
ARG RCLONE_SHA256_AMD64=fe435e0c36228e7c2f116a8701f01127bb1f694005fc11d1f27186c8bca4115d
ARG RCLONE_SHA256_ARM64=97685285c9ad6a0cf17d5844115d2a67245af6444db672187074bd9c358de419

# sha256sum: NOT explicitly installed below — it ships as part of GNU coreutils,
# which is `Essential: yes` in Debian and therefore present in every Debian/
# bookworm-slim image, including this one, without any apt-get install line.
# There is deliberately no explicit `apt-get install coreutils` here: an
# "Essential: yes" package cannot be absent from ANY debian:bookworm-slim
# image, so pinning an explicit version for it here would be pinning theater,
# not a real safety improvement — the FROM line's own digest pin already
# fixes coreutils' version exactly as effectively as an explicit ARG would.
# See docker/tools/README.md's "GNU coreutils / sha256sum" section for the
# verified version this currently resolves to and how to re-check it after a
# base-image bump.

# Set by buildx automatically for each platform in `--platform linux/amd64,linux/arm64`.
ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        unzip \
        "libimage-exiftool-perl=${EXIFTOOL_APT_VERSION}" \
        "ffmpeg=${FFMPEG_APT_VERSION}"; \
    rm -rf /var/lib/apt/lists/*

# --- rclone: download, verify, install ---
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) RCLONE_ARCH=amd64; RCLONE_SHA256="${RCLONE_SHA256_AMD64}" ;; \
        arm64) RCLONE_ARCH=arm64; RCLONE_SHA256="${RCLONE_SHA256_ARM64}" ;; \
        *) echo "ERROR: unsupported TARGETARCH for rclone: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    tmpdir="$(mktemp -d)"; \
    curl -fsSL -o "${tmpdir}/rclone.zip" \
        "https://downloads.rclone.org/${RCLONE_VERSION}/rclone-${RCLONE_VERSION}-linux-${RCLONE_ARCH}.zip"; \
    echo "${RCLONE_SHA256}  ${tmpdir}/rclone.zip" | sha256sum -c -; \
    unzip -q "${tmpdir}/rclone.zip" -d "${tmpdir}"; \
    install -m 755 "${tmpdir}/rclone-${RCLONE_VERSION}-linux-${RCLONE_ARCH}/rclone" /usr/local/bin/rclone; \
    rm -rf "${tmpdir}"

# --- czkawka_cli: download, verify, install ---
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) CZKAWKA_ASSET=linux_czkawka_cli_x86_64; CZKAWKA_SHA256="${CZKAWKA_SHA256_AMD64}" ;; \
        arm64) CZKAWKA_ASSET=linux_czkawka_cli_arm64; CZKAWKA_SHA256="${CZKAWKA_SHA256_ARM64}" ;; \
        *) echo "ERROR: unsupported TARGETARCH for czkawka: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    tmp="$(mktemp)"; \
    curl -fsSL -o "${tmp}" \
        "https://github.com/qarmin/czkawka/releases/download/${CZKAWKA_VERSION}/${CZKAWKA_ASSET}"; \
    echo "${CZKAWKA_SHA256}  ${tmp}" | sha256sum -c -; \
    install -m 755 "${tmp}" /usr/local/bin/czkawka_cli; \
    rm -f "${tmp}"

# Non-root: Phase 2 bind-mounts host media in; run as a fixed unprivileged user
# by default so files this container creates aren't root-owned when the image
# is run standalone (e.g. the "Debugging" section in docker/tools/README.md).
# #76 Phase 3 (lib/src/tools_container.dart's ToolsContainer.start()) overrides
# this uid at `docker run` time with `--user <host-uid>:<host-gid>` for the real
# bind-mount use case, so this baked-in uid is only ever the *fallback*, not the
# uid real pipeline runs actually execute as on Linux/macOS.
RUN useradd --create-home --uid 10000 --shell /bin/bash tools
USER tools
WORKDIR /work

CMD ["bash"]
