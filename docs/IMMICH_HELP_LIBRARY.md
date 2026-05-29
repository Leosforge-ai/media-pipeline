# Immich Help Library

This help library summarizes the Immich setup information needed by the desktop app. It is intentionally practical and safety-focused.

## Private Docker Immich

A private Docker Immich server can be used without making it public. Phones and the desktop app only need to reach the server URL:

```text
http://localhost:2283
http://SERVER_IP:2283
http://HOSTNAME.local:2283
http://TAILSCALE_OR_VPN_IP:2283
```

Use LAN or VPN access first. `localhost` only works on the machine running Immich; phones usually need the server's LAN IP, local DNS name, or VPN address. If a phone works on home Wi-Fi but fails on cellular, check whether the configured URL is private-only and whether the VPN is connected.

Avoid exposing Immich directly to the public internet unless you understand TLS, reverse proxying, authentication, updates, and backup risk. Public exposure also raises the cost of keeping server and mobile app versions current.

## Phone Backup Setup

1. Install the Immich mobile app.
2. Log in with your server URL, for example `http://SERVER_IP:2283`.
3. Open the backup screen from the cloud icon.
4. Select the albums to back up.
5. Enable backup.
6. Optionally enable album synchronization so phone albums are mirrored on the server.
7. Keep the app open for the first large upload and check Immich job queues while the server processes files.

Immich can automatically upload selected albums when the app opens/resumes and periodically in the background. Background behavior still depends on iOS/Android rules.

The desktop app also keeps a local phone checklist so you can track which devices are ready without storing secrets. The checklist is saved as JSON in the app's local data folder.

## Android Backup Notes

- Disable battery optimization for Immich if background backup stalls or only runs while the app is open.
- Review manufacturer-specific background restrictions, especially on phones with aggressive battery managers.
- Keep Wi-Fi-only backup unless mobile data usage is acceptable for large photo and video queues.
- Open Immich after taking new photos during initial validation so you can confirm uploads start before relying on background scheduling.
- Leave the phone charging and keep the app open for the first large upload; this avoids treating background scheduling as the first test.
- If backing up chat/media folders such as WhatsApp, do not use phone cleanup features until you understand how local deletion affects those apps and their own backup flows.

## iPhone Backup Notes

- Enable Background App Refresh for Immich.
- Avoid Low Power Mode when expecting background backup.
- iOS decides when background tasks run; Immich cannot force a precise background upload schedule.
- Opening the app more often improves upload opportunities, especially after travel or a long offline period.
- If iCloud Photos is enabled with optimized storage, Immich may need to temporarily download originals before it can upload them.
- Be careful with any cleanup/free-space action because iCloud Photos is a two-way sync, not a separate backup copy.
- For the first backup, keep the app foregrounded and the phone charging until you have observed at least one successful upload in Immich.

## External Libraries

External libraries let Immich scan media stored outside its upload folder. In this project, the cleaned library is mounted into Immich as `/library` and should be read-only.

Use `/library` as the Immich external-library path. Do not use `/data` as an external library path because `/data` is Immich's upload/storage folder.

The project mounts `/library` read-only on purpose. Do not remove the read-only mount unless you explicitly want Immich to write metadata sidecars or delete files in that external library.

If files in an external library change outside Immich, rescan the library. If files disappear from disk, Immich may treat those assets as missing on rescan, so validate your filesystem backup before reorganizing or deleting the original library.

Keep Immich upload storage and external-library storage conceptually separate:

- `/data` is Immich-managed upload/storage.
- `/library` is this project's cleaned external library.
- backups must include both if you depend on both.

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

For this project, also preserve `cleaning_staging`, `media_trash`, and the original Takeout/Drive sources until you have verified Immich, external-library scans, and your independent backups.

Do not manually edit or delete files inside Immich-managed asset folders. Use the Immich web/mobile interface for changes and use filesystem backups for disaster recovery.

Test restores before you need them. A useful restore check confirms that:

- database restore works;
- uploaded media files are present;
- external-library mount paths still match the restored Immich configuration;
- `/library` can be scanned again from inside the Immich container.

## Source Links

- Mobile backup: https://docs.immich.app/features/mobile-backup
- Mobile app: https://docs.immich.app/features/mobile-app
- External libraries: https://docs.immich.app/features/libraries
- Backup and restore: https://docs.immich.app/administration/backup-and-restore/
- API endpoints: https://api.immich.app/endpoints
