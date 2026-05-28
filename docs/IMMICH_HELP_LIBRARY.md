# Immich Help Library

This help library summarizes the Immich setup information needed by the desktop app. It is intentionally practical and safety-focused.

## Private Docker Immich

A private Docker Immich server can be used without making it public. Phones and the desktop app only need to reach the server URL:

```text
http://localhost:2283
http://SERVER_IP:2283
http://TAILSCALE_OR_VPN_IP:2283
```

Use LAN/VPN access first. Avoid exposing Immich directly to the public internet unless you understand TLS, reverse proxying, authentication, updates, and backup risk.

## Phone Backup Setup

1. Install the Immich mobile app.
2. Log in with your server URL, for example `http://SERVER_IP:2283`.
3. Open the backup screen from the cloud icon.
4. Select the albums to back up.
5. Enable backup.
6. Optionally enable album synchronization so phone albums are mirrored on the server.
7. Keep the app open for the first large upload and check Immich job queues while the server processes files.

Immich can automatically upload selected albums when the app opens/resumes and periodically in the background. Background behavior still depends on iOS/Android rules.

## Android Backup Notes

- Disable battery optimization for Immich if background backup stalls.
- Review manufacturer-specific background restrictions.
- Keep Wi-Fi-only backup unless mobile data usage is acceptable.
- If backing up chat/media folders such as WhatsApp, do not use phone cleanup features until you understand how local deletion affects those apps.

## iPhone Backup Notes

- Enable Background App Refresh for Immich.
- Avoid Low Power Mode when expecting background backup.
- iOS decides when background tasks run; opening the app more often improves backup opportunities.
- If iCloud Photos is enabled, Immich may need to temporarily download originals to upload them.
- Be careful with any cleanup/free-space action because iCloud is a two-way sync.

## External Libraries

External libraries let Immich scan media stored outside its upload folder. In this project, the cleaned library is mounted into Immich as `/library` and should be read-only.

Use `/library` as the Immich external-library path. Do not use `/data` as an external library path because `/data` is Immich's upload/storage folder.

If files in an external library change outside Immich, rescan the library. If files disappear from disk, Immich may move those assets to trash on rescan.

## Memories

Immich can show memories from server-side assets. The planned app memory-curator feature will build on this by:

- reading assets from the private Immich API;
- creating explainable memory candidates;
- previewing them before any write;
- optionally creating memories through the Immich API;
- optionally sending notifications through a provider such as ntfy, Gotify, Pushover, Home Assistant, or local desktop notifications.

The first implementation should use rules and scoring. A trained personal ranking model should come later, after local feedback exists.

## Backup Safety

Immich database backups do not contain the actual photos and videos. A complete backup must include both:

- the Immich database or database backups;
- the original media files in Immich upload/storage folders and any external library media you depend on.

Do not manually edit or delete files inside Immich-managed asset folders. Use the Immich web/mobile interface for changes and use filesystem backups for disaster recovery.

## Source Links

- Mobile backup: https://docs.immich.app/features/mobile-backup
- Mobile app: https://docs.immich.app/features/mobile-app
- External libraries: https://docs.immich.app/features/libraries
- Backup and restore: https://docs.immich.app/administration/backup-and-restore/
- API endpoints: https://api.immich.app/endpoints
