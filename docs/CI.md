# CI and Code Review

## Workflows

```text
.github/workflows/ci.yml               Shell/Python/YAML lint, Docker Compose config validation
.github/workflows/gitleaks.yml         Secret scanning (diff-aware on PRs)
.github/workflows/pr-review.yml        Automated safety-focused code review on every PR
.github/workflows/release.yml          Builds a release archive on version tags
.github/workflows/add-to-project.yml   Adds new issues to the project board
```

## Automated PR review

Every pull request is reviewed by an automated agent focused on this repo's safety rules: destructive-operation handling, Czkawka report parsing, Immich storage separation, Bash quoting/error handling, and recovery documentation. CRITICAL/HIGH/MEDIUM findings request changes. Configuration lives in `.github/workflows/pr-review.yml`; no separate app install or account setup is required — it runs as a GitHub Actions job with an org-level API credential.

## CI checks

```text
Bash scripts       shellcheck + shfmt
Python scripts     compileall + ruff
YAML files         yamllint
Immich Compose     docker compose config
GitHub Actions     actionlint
Secrets            gitleaks (diff-aware, not whole-tree)
```

## Local checks before pushing

```bash
shellcheck scripts/*.sh config/*.sh
shfmt -d scripts/*.sh config/*.sh
python3 -m compileall scripts config
ruff check scripts config
yamllint .
cp immich/env.template immich/.env
docker compose --env-file immich/.env -f immich/docker-compose.yml config >/tmp/immich-compose.rendered.yml
```

For the Flutter app:

```bash
flutter analyze
flutter test
```

## Release workflow

Push a semantic version tag to trigger a release:

```bash
git tag v1.0.0
git push origin v1.0.0
```

Produces a zipped source archive, a SHA-256 checksum, and a GitHub release.

## Pinning

All third-party GitHub Actions are pinned to a full commit SHA, not a mutable tag — verify this holds for any new workflow or action added.
