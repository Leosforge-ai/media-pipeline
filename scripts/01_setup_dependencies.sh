#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../config/pipeline_config.sh"

require_sudo() {
	if [[ $EUID -eq 0 ]]; then
		SUDO=""
	else
		SUDO="sudo"
	fi
}

install_czkawka() {
	if command -v czkawka_cli >/dev/null 2>&1; then
		echo "==> czkawka_cli already installed: $(command -v czkawka_cli)"
		return
	fi

	local arch asset url tmp
	arch="$(uname -m)"
	case "$arch" in
	x86_64 | amd64) asset="linux_czkawka_cli_x86_64" ;;
	aarch64 | arm64) asset="linux_czkawka_cli_arm64" ;;
	*)
		echo "ERROR: unsupported architecture for automatic Czkawka install: $arch"
		exit 1
		;;
	esac

	url="https://github.com/qarmin/czkawka/releases/latest/download/$asset"
	tmp="$(mktemp)"
	echo "==> Downloading Czkawka CLI: $url"
	curl -fsSL "$url" -o "$tmp"
	chmod +x "$tmp"
	$SUDO install -m 755 "$tmp" /usr/local/bin/czkawka_cli
	rm -f "$tmp"
	echo "==> Installed: $(czkawka_cli --help | head -n 1)"
}

install_docker() {
	if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
		echo "==> Docker and Docker Compose plugin already installed"
		return
	fi

	echo "==> Installing Docker using Ubuntu packages"
	$SUDO apt-get update
	$SUDO apt-get install -y ca-certificates curl gnupg lsb-release
	$SUDO install -m 0755 -d /etc/apt/keyrings
	curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
	$SUDO chmod a+r /etc/apt/keyrings/docker.gpg
	echo \
		"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |
		$SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
	$SUDO apt-get update
	$SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
	$SUDO usermod -aG docker "$USER" || true
	echo "NOTE: log out and back in, or run 'newgrp docker', if docker requires sudo."
}

require_sudo

echo "==> Installing OS dependencies"
$SUDO apt-get update
$SUDO apt-get install -y \
	bash coreutils findutils gawk sed grep curl wget unzip tar rsync jq \
	python3 python3-pip python3-venv \
	exiftool ffmpeg imagemagick rclone \
	util-linux ca-certificates

install_czkawka
install_docker

echo "==> Creating pipeline directories"
mkdir -p "$RAW_GDRIVE" "$RAW_TAKEOUT_ZIPS" "$TAKEOUT_EXTRACTED" "$CLEANING_STAGING" "$MEDIA_TRASH" "$IMMICH_LIBRARY" "$IMMICH_APP" "$REPORT_DIR"

echo "==> Dependency setup complete"
