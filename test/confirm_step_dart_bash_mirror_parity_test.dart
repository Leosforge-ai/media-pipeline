import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/pipeline_models.dart';
import 'package:media_pipeline_app/src/pipeline_runner.dart';

/// Mirror-image parity test for the two confirm-gated destructive steps
/// wired to `dartAction` by this PR (issue #76): `delete-confirm` and
/// `restore-confirm`.
///
/// `test/app_driven_simulation_test.dart` (pre-existing, unmodified by this
/// PR) already proves the OTHER half of this pipeline: a Dart-native
/// `delete-dry-run`'s output is exactly what the real, still-live-in-
/// production Bash `06_delete_duplicates.sh --confirm` acts on. This file
/// proves the half that only exists once this PR lands: that the real Dart
/// `delete-confirm`/`restore-confirm` `dartAction`s — run against the real
/// Dart `delete-dry-run`/`restore-dry-run` output from the prior PR in this
/// sequence — produce a `media_trash`/restored-file layout that is
/// bit-for-bit identical to what the OLD Bash `06_delete_duplicates.sh
/// --confirm`/`11_restore_from_trash.sh --confirm` scripts produce from an
/// identically-shaped fixture. "Looks similar" is not good enough here —
/// every relative path AND every byte of file content is compared.
///
/// Two independent, identically-shaped fixture roots are built (`dartRoot`,
/// `bashRoot`) rather than sharing one root, so the Dart side is driven
/// entirely through [PipelineRunner]/[buildPipelineSteps] (the real,
/// currently-wired app path) while the Bash side is driven by directly
/// invoking the real, untouched shell scripts — never mixing the two
/// mechanisms against the same files, and never taking a shortcut that
/// would make this less than a genuine cross-implementation check. Every
/// snapshot comparison strips each side's own fixture-root path first (via
/// [_snapshotFiles]'s `rootPrefixToStrip`), so a matching relative layout is
/// compared, not two coincidentally-identical `/tmp/...NNNNNN` absolute
/// paths.
///
/// The `delete-confirm` fixture deliberately includes a destination
/// collision (a file pre-seeded at the exact spot a trash-candidate would
/// land) so the numbered-suffix-rename path
/// ([SafeFileMover.moveRenamingOnCollision]) is exercised and cross-checked
/// against Bash's own `unique_destination()`, not just the trivial
/// no-collision case.
///
/// The `restore-confirm` fixture deliberately does NOT include a collision
/// in the shared Bash-comparison case — see this file's second group for
/// why: a real, newly-discovered divergence in the *current, unmodified*
/// Bash script makes that comparison meaningless for a collision case (the
/// Bash side doesn't produce a completed layout to compare against at all).
void main() {
  test(
    'delete-confirm dartAction mirrors the real Bash '
    '06_delete_duplicates.sh --confirm layout, driven from the real Dart '
    'delete-dry-run output',
    () async {
      final repoRoot = _findRepoRoot();
      final dartRoot = await Directory.systemTemp.createTemp(
        'confirm_mirror_dart_',
      );
      final bashRoot = await Directory.systemTemp.createTemp(
        'confirm_mirror_bash_',
      );
      addTearDown(() async {
        for (final dir in [dartRoot, bashRoot]) {
          if (await dir.exists()) {
            await dir.delete(recursive: true);
          }
        }
      });

      await _seedDeleteFixture(dartRoot);
      await _seedDeleteFixture(bashRoot);

      // --- Dart side: real PipelineRunner, real dry-run then real confirm.
      final steps = buildPipelineSteps();
      final dryRunStep = steps.singleWhere(
        (step) => step.id == 'delete-dry-run',
      );
      final confirmStep = steps.singleWhere(
        (step) => step.id == 'delete-confirm',
      );
      final dartSettings = PipelineSettings(
        hdPath: dartRoot.path,
        reportDir: '${dartRoot.path}/reports',
      );
      final runner = PipelineRunner(workingDirectory: repoRoot.path);

      final dartDryRun = await runner.run(dryRunStep, dartSettings);
      expect(dartDryRun.succeeded, isTrue);
      expect(dartDryRun.output, contains('Would trash:'));

      final dartConfirm = await runner.run(confirmStep, dartSettings);
      expect(dartConfirm.succeeded, isTrue);
      expect(dartConfirm.output, contains('CONFIRM MODE'));
      expect(dartConfirm.output, contains('Trashed (renamed to avoid'));

      // --- Bash side: the real, untouched shell script, --confirm only
      // (its own dry-run behavior is already covered by the pre-existing
      // parity tests in test/delete_duplicates_test.dart).
      final bashResult = await Process.run(
        'bash',
        ['${repoRoot.path}/scripts/06_delete_duplicates.sh', '--confirm'],
        environment: {
          ...Platform.environment,
          'HD_PATH': bashRoot.path,
          'REPORT_DIR': '${bashRoot.path}/reports',
        },
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(bashResult.exitCode, 0, reason: bashResult.stderr as String);

      // --- Cross-check: identical media_trash layout, bit-for-bit,
      // relative to each side's own fixture root (suffix-renames included).
      final dartTrash = await _snapshotFiles(
        Directory('${dartRoot.path}/media_trash'),
        dartRoot.path,
      );
      final bashTrash = await _snapshotFiles(
        Directory('${bashRoot.path}/media_trash'),
        bashRoot.path,
      );
      expect(
        dartTrash.keys.toSet(),
        bashTrash.keys.toSet(),
        reason:
            'Dart delete-confirm and Bash 06_delete_duplicates.sh --confirm '
            'must move the exact same set of files (by relative path) into '
            'media_trash, suffix-renames included.',
      );
      expect(dartTrash.keys, hasLength(3), reason: 'b.jpg, d.jpg, d_1.jpg.');
      for (final relativePath in dartTrash.keys) {
        expect(
          dartTrash[relativePath],
          bashTrash[relativePath],
          reason: 'Content mismatch for media_trash$relativePath',
        );
      }

      // --- Cross-check: identical staging survivors (the kept files).
      final dartStaging = await _snapshotFiles(
        Directory('${dartRoot.path}/cleaning_staging'),
        dartRoot.path,
      );
      final bashStaging = await _snapshotFiles(
        Directory('${bashRoot.path}/cleaning_staging'),
        bashRoot.path,
      );
      expect(dartStaging.keys.toSet(), bashStaging.keys.toSet());
      expect(dartStaging.keys, hasLength(2), reason: 'a.jpg, c.jpg.');
    },
    skip: !Platform.isLinux && !Platform.isMacOS,
  );

  test(
    'restore-confirm dartAction mirrors the real Bash '
    '11_restore_from_trash.sh --confirm layout, driven from the real Dart '
    'restore-dry-run output (no-collision case)',
    () async {
      final repoRoot = _findRepoRoot();
      final dartRoot = await Directory.systemTemp.createTemp(
        'restore_mirror_dart_',
      );
      final bashRoot = await Directory.systemTemp.createTemp(
        'restore_mirror_bash_',
      );
      addTearDown(() async {
        for (final dir in [dartRoot, bashRoot]) {
          if (await dir.exists()) {
            await dir.delete(recursive: true);
          }
        }
      });

      await _seedRestoreFixture(dartRoot, includeCollision: false);
      await _seedRestoreFixture(bashRoot, includeCollision: false);

      final steps = buildPipelineSteps();
      final dryRunStep = steps.singleWhere(
        (step) => step.id == 'restore-dry-run',
      );
      final confirmStep = steps.singleWhere(
        (step) => step.id == 'restore-confirm',
      );
      final dartSettings = PipelineSettings(
        hdPath: dartRoot.path,
        reportDir: '${dartRoot.path}/reports',
      );
      final runner = PipelineRunner(workingDirectory: repoRoot.path);

      final dartDryRun = await runner.run(dryRunStep, dartSettings);
      expect(dartDryRun.succeeded, isTrue);
      expect(dartDryRun.output, contains('Would restore:'));

      final dartConfirm = await runner.run(confirmStep, dartSettings);
      expect(dartConfirm.succeeded, isTrue);
      expect(dartConfirm.output, contains('CONFIRM MODE'));
      expect(dartConfirm.output, contains('Restored:'));

      final bashResult = await Process.run(
        'bash',
        ['${repoRoot.path}/scripts/11_restore_from_trash.sh', '--confirm'],
        environment: {
          ...Platform.environment,
          'HD_PATH': bashRoot.path,
          'REPORT_DIR': '${bashRoot.path}/reports',
        },
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(bashResult.exitCode, 0, reason: bashResult.stderr as String);

      // --- Cross-check: media_trash is empty on both sides (everything was
      // restored, nothing collided).
      final dartTrash = await _snapshotFiles(
        Directory('${dartRoot.path}/media_trash'),
        dartRoot.path,
      );
      final bashTrash = await _snapshotFiles(
        Directory('${bashRoot.path}/media_trash'),
        bashRoot.path,
      );
      expect(dartTrash, isEmpty);
      expect(bashTrash, isEmpty);

      // --- Cross-check: identical restored-file layout under
      // cleaning_staging (the reconstructed original location for this
      // fixture's files), bit-for-bit.
      final dartRestored = await _snapshotFiles(
        Directory('${dartRoot.path}/cleaning_staging'),
        dartRoot.path,
      );
      final bashRestored = await _snapshotFiles(
        Directory('${bashRoot.path}/cleaning_staging'),
        bashRoot.path,
      );
      expect(dartRestored.keys.toSet(), bashRestored.keys.toSet());
      expect(dartRestored.keys, hasLength(1), reason: 'restorable.jpg.');
      for (final relativePath in dartRestored.keys) {
        expect(dartRestored[relativePath], bashRestored[relativePath]);
      }
    },
    skip: !Platform.isLinux && !Platform.isMacOS,
  );

  test(
    'DISCOVERY: the real, unmodified 11_restore_from_trash.sh --confirm '
    'aborts the whole restore batch on its first destination collision '
    '(coreutils 9.x `mv -n` exits 1 on skip, and the script runs under '
    '`set -e`) — the Dart restore-confirm dartAction does not inherit this '
    'bug; it skips the one colliding file and finishes restoring every '
    'other file',
    () async {
      final repoRoot = _findRepoRoot();
      final bashRoot = await Directory.systemTemp.createTemp(
        'restore_mirror_bash_abort_',
      );
      addTearDown(() async {
        if (await bashRoot.exists()) {
          await bashRoot.delete(recursive: true);
        }
      });
      await _seedRestoreFixture(bashRoot, includeCollision: true);

      // Confirms the discovery empirically against the real, untouched
      // script — this is not a hypothetical or a misreading of `mv --help`;
      // it is what actually happens on this environment's coreutils.
      final bashResult = await Process.run(
        'bash',
        ['${repoRoot.path}/scripts/11_restore_from_trash.sh', '--confirm'],
        environment: {
          ...Platform.environment,
          'HD_PATH': bashRoot.path,
          'REPORT_DIR': '${bashRoot.path}/reports',
        },
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(
        bashResult.exitCode,
        isNot(0),
        reason:
            'Documents the discovery: `mv -n` on an existing destination '
            'exits 1 on this coreutils version, and `set -euo pipefail` '
            'turns that into a hard script failure — a real, pre-existing '
            'production risk in the still-live Bash script, unrelated to '
            'and not introduced by this PR (restore_from_trash.dart itself '
            'predates this PR; only its dartAction wiring is new here).',
      );

      final dartRoot = await Directory.systemTemp.createTemp(
        'restore_mirror_dart_continues_',
      );
      addTearDown(() async {
        if (await dartRoot.exists()) {
          await dartRoot.delete(recursive: true);
        }
      });
      await _seedRestoreFixture(dartRoot, includeCollision: true);

      final steps = buildPipelineSteps();
      final confirmStep = steps.singleWhere(
        (step) => step.id == 'restore-confirm',
      );
      final dartSettings = PipelineSettings(
        hdPath: dartRoot.path,
        reportDir: '${dartRoot.path}/reports',
      );
      final runner = PipelineRunner(workingDirectory: repoRoot.path);

      final dartConfirm = await runner.run(confirmStep, dartSettings);

      // Unlike the Bash script, the dartAction never aborts on a skip: it
      // reports the collision truthfully and keeps going.
      expect(dartConfirm.succeeded, isTrue);
      expect(dartConfirm.output, contains('Skipped (destination already'));
      expect(dartConfirm.output, contains('Restored:'));

      final dartTrash = await _snapshotFiles(
        Directory('${dartRoot.path}/media_trash'),
        dartRoot.path,
      );
      // Only the colliding file remains — everything else was restored,
      // even though it comes alphabetically after the collision.
      expect(dartTrash.keys, hasLength(1));
      expect(dartTrash.keys.single, contains('collides.jpg'));

      final dartRestored = await _snapshotFiles(
        Directory('${dartRoot.path}/cleaning_staging'),
        dartRoot.path,
      );
      expect(
        dartRestored.keys.where((k) => k.contains('restorable.jpg')),
        hasLength(1),
        reason:
            'The non-colliding file was restored despite the earlier '
            'collision — no batch-wide abort.',
      );
    },
    skip: !Platform.isLinux && !Platform.isMacOS,
  );
}

/// Builds a `delete-confirm` fixture under [root]: two duplicate groups
/// under `cleaning_staging`, one of which is pre-seeded to force a
/// destination collision in `media_trash` (exercising
/// [SafeFileMover.moveRenamingOnCollision]'s numbered-suffix path).
Future<void> _seedDeleteFixture(Directory root) async {
  final staging = Directory('${root.path}/cleaning_staging');
  final fotos = Directory('${staging.path}/Fotos');
  final reports = Directory('${root.path}/reports');
  await fotos.create(recursive: true);
  await reports.create(recursive: true);

  // Group 1: plain staging file (score 5) kept over a `Fotos/` copy
  // (score 20) — no collision.
  final keepA = File('${staging.path}/a.jpg');
  final trashB = File('${fotos.path}/b.jpg');
  await keepA.writeAsString('group-1-bytes');
  await trashB.writeAsString('group-1-bytes');

  // Group 2: same shape, but this fixture pre-seeds media_trash with a
  // file already occupying trashD's exact destination, forcing a numbered
  // suffix rename in both implementations.
  final keepC = File('${staging.path}/c.jpg');
  final trashD = File('${fotos.path}/d.jpg');
  await keepC.writeAsString('group-2-bytes');
  await trashD.writeAsString('group-2-bytes');

  final trashRoot = Directory('${root.path}/media_trash');
  final collisionPath = '${trashRoot.path}${trashD.path}';
  await Directory(File(collisionPath).parent.path).create(recursive: true);
  await File(collisionPath).writeAsString('pre-existing-trash-occupant');

  final reportContent =
      '"${keepA.path}" - 10 KiB\n'
      '"${trashB.path}" - 10 KiB\n'
      '\n'
      '"${keepC.path}" - 10 KiB\n'
      '"${trashD.path}" - 10 KiB\n'
      '\n';
  await File(
    '${reports.path}/duplicate_files.txt',
  ).writeAsString(reportContent);
}

/// Builds a `restore-confirm` fixture under [root]: a `media_trash`
/// containing `restorable.jpg` (always restorable) and, when
/// [includeCollision] is true, `collides.jpg` — whose reconstructed
/// original location is pre-occupied, forcing a skip
/// ([SafeFileMover.moveNoClobber]).
Future<void> _seedRestoreFixture(
  Directory root, {
  required bool includeCollision,
}) async {
  final staging = Directory('${root.path}/cleaning_staging');
  await staging.create(recursive: true);

  final trashRoot = Directory('${root.path}/media_trash');
  final trashedOk = File('${trashRoot.path}${staging.path}/restorable.jpg');
  await Directory(trashedOk.parent.path).create(recursive: true);
  await trashedOk.writeAsString('restorable-bytes');

  if (!includeCollision) {
    return;
  }

  final trashedCollision = File(
    '${trashRoot.path}${staging.path}/collides.jpg',
  );
  await trashedCollision.writeAsString('collision-trash-bytes');

  // Pre-seed the reconstructed original destination for `collides.jpg` so
  // the restore is forced to skip it (mv -n / moveNoClobber semantics).
  final existingDestination = File('${staging.path}/collides.jpg');
  await existingDestination.writeAsString('already-restored-bytes');
}

/// Recursively snapshots every regular file under [root]: a relative path
/// (with [rootPrefixToStrip] — this fixture's own root, e.g. a random temp
/// dir — removed everywhere it appears, not just as a leading prefix, since
/// a trashed/restored file's reconstructed path embeds the *original*
/// absolute path, which itself starts with [rootPrefixToStrip]) -> raw
/// bytes. This is what makes two independently-generated temp roots
/// (`dartRoot`, `bashRoot`) comparable at all: without stripping, every key
/// would differ solely because of the two temp dirs' random names, never
/// because of an actual behavioral difference. Returns an empty map if
/// [root] doesn't exist (e.g. `media_trash` never got created).
Future<Map<String, List<int>>> _snapshotFiles(
  Directory root,
  String rootPrefixToStrip,
) async {
  if (!await root.exists()) {
    return {};
  }
  final snapshot = <String, List<int>>{};
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is! File) {
      continue;
    }
    final relative = entity.path.replaceAll(rootPrefixToStrip, '');
    snapshot[relative] = await entity.readAsBytes();
  }
  return snapshot;
}

/// Finds the repo root by walking up from this test file's directory until
/// `scripts/06_delete_duplicates.sh` is found — mirrors
/// `test/delete_duplicates_test.dart`'s `_findRepoRoot`.
Directory _findRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/scripts/06_delete_duplicates.sh').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('Could not locate repo root from ${Directory.current}');
}
