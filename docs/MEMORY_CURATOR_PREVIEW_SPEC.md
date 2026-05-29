# Memory Curator Preview Spec

This spec defines the first version of the Immich memory-curator work as a read-only preview. It is intentionally limited so the app can explain candidate memories without creating or modifying anything in Immich.

## Scope

- Read private Immich assets through the API.
- Build preview-only memory candidates.
- Explain why each candidate was chosen.
- Allow the user to review candidates before any future write path exists.

## Candidate Sources

- This day or week in prior years.
- Event clusters.
- Location clusters.
- People or faces when Immich exposes them.
- Favorites and album membership.
- Quality and duplicate penalties.

## Default Exclusions

- Screenshots.
- Receipts.
- Blurry images.
- Near-duplicates when detection is available.

## Output

Each preview candidate should show:

- a title;
- the assets used to build it;
- the scoring factors that contributed to the result;
- the reasons a candidate was excluded, when relevant.

## Privacy And Safety Constraints

- Do not write memories to Immich in this phase.
- Do not upload media or sidecar files.
- Do not enable notifications as part of the core preview.
- Keep all candidate scoring local unless the user explicitly exports it.
- Avoid collecting training feedback until a later opt-in phase.

## Acceptance Criteria

- The preview can be run against a private Immich server.
- The user can inspect candidate scores and explanations.
- No Immich data is modified during preview generation.
- The implementation stays rules-based.
- A future write path remains separate and explicitly approved.
