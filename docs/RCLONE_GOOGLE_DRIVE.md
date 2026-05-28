# Google Drive Import with rclone

## Configure

```bash
./scripts/02_configure_rclone.sh
```

Use remote name:

```text
gdrive
```

## List folders

```bash
rclone lsf gdrive: --dirs-only
```

## Import selected folders

```bash
./scripts/03_import_gdrive.sh "Fotos" "Wedding "
```

Quote folder names. Preserve trailing spaces inside quotes.

## Manual copy example

```bash
rclone copy "gdrive:Wedding " "/mnt/target_drive/raw_gdrive/Wedding" \
  --include "*.{jpg,jpeg,png,heic,heif,webp,gif,mp4,mov,m4v,avi,mkv,3gp,webm,JPG,JPEG,PNG,HEIC,HEIF,WEBP,GIF,MP4,MOV,M4V,AVI,MKV,3GP,WEBM}" \
  --progress
```

## Verify

```bash
du -sh /mnt/target_drive/raw_gdrive
find /mnt/target_drive/raw_gdrive -type f | wc -l
```
