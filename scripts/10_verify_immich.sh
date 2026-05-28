#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../config/pipeline_config.sh"

cd "$IMMICH_APP"

echo "==> Docker containers"
docker compose ps

echo
echo "==> Mounted paths inside immich-server"
docker inspect immich_server --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' || true

echo
echo "==> External library visibility"
docker compose exec immich-server find /library -type f | head -n 20 || true
printf 'Files visible in /library: '
docker compose exec immich-server find /library -type f | wc -l || true

echo
echo "==> Read test"
docker compose exec immich-server sh -c 'f=$(find /library -type f | head -n 1); echo "$f"; ls -lh "$f"; head -c 10 "$f" >/dev/null && echo "read ok"' || true

echo
echo "==> Recent server logs"
docker compose logs --tail=120 immich-server
