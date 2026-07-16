# Contributing

Thank you for helping improve Media Pipeline. This project exists because personal photo and video archives are messy, duplicated, multilingual, and emotionally important. Contributions are welcome, but safety comes first.

## Ways to contribute

You can help by:

- testing the workflow on different Linux distributions;
- improving Google Photos Takeout parsing;
- improving duplicate-detection safety;
- adding support for more archive layouts or languages;
- improving Immich setup and troubleshooting;
- improving documentation, screenshots, examples, and error messages;
- reporting real-world edge cases with clear logs and anonymized paths.

Please do **not** upload personal media, Google Takeout archives, `.env` files, rclone configs, access tokens, or private logs to issues or pull requests.

## Safety principles

This repository handles personal media. Every change must follow these principles:

1. **No permanent deletion by default.** Scripts must use dry-run behavior or move files to `media_trash`.
2. **`--confirm` must be explicit.** Never hide confirmation flags inside wrapper scripts, CI, aliases, examples, or automation.
3. **Trash first, delete later.** The pipeline may move duplicates to a recoverable trash folder, but permanent deletion must remain a separate manual decision.
4. **Parsers must be strict.** Tool reports such as Czkawka output are untrusted input. Scripts must not treat headers, summaries, or metadata lines as file paths.
5. **Paths must be quoted.** Assume filenames may contain spaces, quotes, accents, emojis, and non-English characters.
6. **Immich originals should be protected.** External libraries should be mounted read-only unless there is a documented reason not to.
7. **Recovery must be documented.** Any risky workflow needs rollback instructions.

## Development setup

Clone the repository and install development tools:

```bash
git clone https://github.com/YOUR_USER/media-pipeline.git
cd media-pipeline

sudo apt update
sudo apt install -y shellcheck shfmt python3 python3-venv python3-pip yamllint
python3 -m pip install --user ruff
```

Make scripts executable:

```bash
chmod +x scripts/*.sh
```

Run the local checks:

```bash
shellcheck scripts/*.sh config/*.sh
shfmt -d scripts/*.sh config/*.sh
python3 -m compileall scripts config
ruff check scripts config
yamllint .
```

Validate the Immich Compose file:

```bash
cp immich/env.template /tmp/media-pipeline-immich.env
mkdir -p /tmp/media-pipeline-upload /tmp/media-pipeline-postgres /tmp/media-pipeline-library
sed -i 's|^UPLOAD_LOCATION=.*|UPLOAD_LOCATION=/tmp/media-pipeline-upload|' /tmp/media-pipeline-immich.env
sed -i 's|^DB_DATA_LOCATION=.*|DB_DATA_LOCATION=/tmp/media-pipeline-postgres|' /tmp/media-pipeline-immich.env
sed -i 's|^EXTERNAL_LIBRARY_LOCATION=.*|EXTERNAL_LIBRARY_LOCATION=/tmp/media-pipeline-library|' /tmp/media-pipeline-immich.env

docker compose --env-file /tmp/media-pipeline-immich.env -f immich/docker-compose.yml config >/tmp/media-pipeline-compose.yml
```

## Testing changes safely

Use a small disposable test folder, never your real photo archive:

```bash
mkdir -p /tmp/media-pipeline-test/raw_takeout_zips
mkdir -p /tmp/media-pipeline-test/raw_gdrive
mkdir -p /tmp/media-pipeline-test/cleaning_staging
mkdir -p /tmp/media-pipeline-test/media_trash
```

For deletion-related changes, run dry-run mode and inspect the output:

```bash
./scripts/06_delete_duplicates.sh | tee /tmp/delete-dry-run.txt

grep -E "^(Keep:|Would trash:)" /tmp/delete-dry-run.txt | head -n 100
```

A pull request that changes deletion behavior should explain:

- what duplicate report format was tested;
- which file was kept and why;
- which files would be moved to trash;
- how the user can restore from trash;
- why the parser cannot accidentally parse report headers as files.

## Pull request checklist

Before opening a PR, please confirm:

- [ ] I ran the local checks listed above.
- [ ] I did not commit personal media, Takeout archives, `.env` files, tokens, rclone configs, or logs.
- [ ] Destructive actions still default to dry-run.
- [ ] Any new confirmation behavior requires an explicit user action.
- [ ] I updated `README.md`, `INSTRUCTIONS.md`, or `docs/` if user-facing behavior changed.
- [ ] I added troubleshooting notes for any new known failure mode.
- [ ] I tested paths with spaces or non-English characters where relevant.

## Issue guidelines

When opening a bug report, include:

- operating system and version;
- output of `bash --version`, `python3 --version`, and `docker compose version` if relevant;
- the exact command run;
- the last 50 to 150 lines of output;
- anonymized paths if the original paths include private names.

Do not include private media, private archive names, OAuth credentials, API keys, `.env` files, rclone configs, or full logs containing personal file paths.

## Automated PR review

Every PR gets an automated safety-focused review (see [`docs/CI.md`](docs/CI.md)). Its feedback is welcome, but safety-sensitive changes still need human review. In particular, deletion, parsing, metadata writing, Docker volume mounts, and permission changes should be reviewed manually even if automated checks pass.

## License

By contributing to this repository, you agree that your contribution will be licensed under the same license as the project: the MIT License. See [`LICENSE`](LICENSE).
