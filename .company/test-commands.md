# Test & CI Commands — media-pipeline

> Owner: Sofie · Reviewer: Cody/Theo.

## Local

```bash
flutter pub get && flutter analyze && flutter test   # desktop app
ruff check scripts                                   # Python lint
python -m pytest tests                               # Python tests (where present)
# Pipeline scripts default to DRY-RUN; never run destructive steps without the confirmation gate
```

## CI (GitHub Actions, pinned SHAs)

- `ci.yml` — lint/test.
- `gitleaks.yml` — secret scan.
- `pr-review.yml` — automated **Cody** review (correctness/security + the safety rules: dry-run, no permanent delete, dedup-path parsing, Immich storage separation); CRITICAL/HIGH/MEDIUM request changes.
- `release.yml` — release (Leo-gated).

CI green before review; no self-merge.
