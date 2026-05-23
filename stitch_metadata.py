#!/usr/bin/env python3
import json
import subprocess
import os
from pathlib import Path
from datetime import datetime, timezone
from timezonefinder import TimezoneFinder
import pytz

TAKEOUT_ZIPS = Path("/mnt/storage_2tb/raw_takeout_zips")
EXTRACT_DIR = Path("/mnt/storage_2tb/takeout_extracted")
STAGING_DIR = Path("/mnt/storage_2tb/cleaning_staging")

print("==> Unzipping Takeout Archives...")
for zip_file in TAKEOUT_ZIPS.glob("*.zip"):
    subprocess.run(["unzip", "-q", "-o", str(zip_file), "-d", str(EXTRACT_DIR)])

print("==> Stitching GPS & Local Timezones...")
tf = TimezoneFinder()

for json_file in EXTRACT_DIR.rglob("*.json"):
    media_name_guess = json_file.name.replace(".json", "")
    media_files = list(json_file.parent.glob(f"{media_name_guess[:40]}*"))
    media_file = next((f for f in media_files if f.suffix.lower() in ['.jpg', '.jpeg', '.png', '.mp4', '.mov', '.heic']), None)
    
    if not media_file:
        continue
    with open(json_file, 'r') as f:
        try: data = json.load(f)
        except: continue

    geo = data.get("geoData", {})
    lat, lon, alt = float(geo.get("latitude", 0.0)), float(geo.get("longitude", 0.0)), float(geo.get("altitude", 0.0))
    has_gps = lat != 0.0 and lon != 0.0

    timestamp = int(data.get("photoTakenTime", {}).get("timestamp", 0))
    if timestamp == 0: continue
    
    utc_dt = datetime.fromtimestamp(timestamp, tz=timezone.utc)
    if has_gps:
        tz_name = tf.timezone_at(lng=lon, lat=lat)
        final_dt = utc_dt.astimezone(pytz.timezone(tz_name)) if tz_name else utc_dt
    else:
        final_dt = utc_dt
        
    formatted_time = final_dt.strftime("%Y:%m:%d %H:%M:%S")
    offset_str = final_dt.strftime("%z")
    formatted_offset = f"{offset_str[:3]}:{offset_str[3:]}" if offset_str else ""

    cmd = ["exiftool", "-overwrite_original", "-q", f"-AllDates={formatted_time}"]
    if formatted_offset: cmd.append(f"-OffsetTimeOriginal={formatted_offset}")
    if has_gps:
        cmd.extend([f"-GPSLatitude={abs(lat)}", f"-GPSLatitudeRef={'N' if lat >= 0 else 'S'}",
                    f"-GPSLongitude={abs(lon)}", f"-GPSLongitudeRef={'E' if lon >= 0 else 'W'}", f"-GPSAltitude={alt}"])
    cmd.append(str(media_file))
    subprocess.run(cmd)
    
    # Move fixed file directly to unified staging area
    os.makedirs(STAGING_DIR / media_file.parent.relative_to(EXTRACT_DIR), exist_ok=True)
    os.rename(str(media_file), str(STAGING_DIR / media_file.relative_to(EXTRACT_DIR)))

print("==> Merging filtered Google Drive downloads into staging...")
subprocess.run(["rsync", "-a", "/mnt/storage_2tb/raw_gdrive/", "/mnt/storage_2tb/cleaning_staging/"])
print("Metadata integration complete.")
