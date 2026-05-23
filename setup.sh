[200~#!/usr/bin/env bash
set -euo pipefail

HD_PATH="/mnt/storage_2tb"
IMMICH_DIR="$HD_PATH/immich_app"

echo "==> 1. Installing System Dependencies..."
sudo apt-get update -qq
sudo apt-get install -y ca-certificates curl gnupg lsb-release rclone libimage-exiftool-perl python3-pip unzip wget

echo "==> 2. Installing Python Packages for Timezone Calculation..."
pip install timezonefinder pytz --break-system-packages

echo "==> 3. Installing Docker..."
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
	  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -qq
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker "$USER"

echo "==> 4. Installing Czkawka CLI..."
CZKAWKA_VERSION=$(curl -s https://api.github.com/repos/qarmin/czkawka/releases/latest | grep tag_name | cut -d '"' -f4)
curl -L "https://github.com/qarmin/czkawka/releases/download/${CZKAWKA_VERSION}/linux_czkawka_cli" -o /tmp/czkawka_cli
sudo install -m 755 /tmp/czkawka_cli /usr/local/bin/czkawka_cli

echo "==> 5. Building 2TB HD Directory Structure..."
mkdir -p "$HD_PATH"/{raw_gdrive,raw_takeout_zips,takeout_extracted,cleaning_staging,media_trash,immich_library}
mkdir -p "$IMMICH_DIR"

echo "==> 6. Downloading Immich Configurations..."
cd "$IMMICH_DIR"
wget -qO docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
wget -qO .env https://github.com/immich-app/immich/releases/latest/download/example.env
sed -i "s|UPLOAD_LOCATION=./library|UPLOAD_LOCATION=$HD_PATH/immich_library|g" .env
sed -i "s|DB_DATA_LOCATION=./postgres|DB_DATA_LOCATION=$HOME/immich_postgres|g" .env

echo "Setup complete. Please log out and back in, or run 'newgrp docker'."
