# Immich External Library Setup

This pipeline keeps Immich's own upload storage separate from the cleaned media library.

Container paths:

```text
/data      Immich upload/storage folder
/library   cleaned media library, mounted read-only
```

Host paths:

```text
/mnt/target_drive/immich_app/upload    -> /data
/mnt/target_drive/immich_library       -> /library:ro
```

## Start Immich

```bash
./scripts/09_setup_immich.sh
```

Open:

```text
http://localhost:2283
```

## Add external library

In Immich UI:

```text
Administration -> External Libraries -> New External Library
```

Add folder:

```text
/library
```

Do not add `/data`.

Then select:

```text
Scan All Library Files
```

## Verify from shell

```bash
./scripts/10_verify_immich.sh
```

## If thumbnails do not load

Wait for Jobs to finish:

```text
Administration -> Jobs
```

Check logs:

```bash
cd /mnt/target_drive/immich_app
docker compose logs -f immich-server
```

Fix permissions:

```bash
sudo chmod -R a+rX /mnt/target_drive/immich_library
cd /mnt/target_drive/immich_app
docker compose restart immich-server
```
