import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/pipeline_models.dart';
import 'package:media_pipeline_app/src/pipeline_runner.dart';
import 'package:media_pipeline_app/src/tools_container.dart';

/// Proves the four SAFE/dry-run `PipelineStep`s migrated from `command` to
/// `dartAction` (issue #76) actually work when driven through the real
/// `PipelineRunner` a real `PipelineStep` uses — not just the underlying
/// ported Dart module in isolation (those already have their own tests;
/// this file is about the *wiring*: `buildPipelineSteps()`'s step
/// definitions calling into `PipelineRunner.run()`).
///
/// `delete-dry-run`/`restore-dry-run` cross-checked end-to-end against a
/// real `06_delete_duplicates.sh --confirm` run (proving this port's path
/// conventions match production) already live in
/// `test/app_driven_simulation_test.dart`; this file focuses on the two
/// container-routed steps (`immich-takeout-duplicate-dry-run`,
/// `stitch-metadata`) plus `restore-dry-run`'s failure path, which that
/// file doesn't cover.
///
/// Mirrors `test/tools_container_test.dart`'s own `_dockerAvailable`/
/// `_toolsImageAvailable` exactly (duplicated here rather than shared, per
/// this repo's existing precedent of mirroring, not importing between test
/// files — see `test/clean_takeout_duplicates_test.dart`'s own copy).
bool _dockerAvailable() {
  try {
    final result = Process.runSync('docker', [
      'version',
      '--format',
      '{{.Server.Version}}',
    ]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

bool _toolsImageAvailable() {
  try {
    final result = Process.runSync('docker', [
      'image',
      'inspect',
      kDefaultToolsImage,
    ]);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

final bool _dockerReady = _dockerAvailable();
final bool _imageReady = _dockerReady && _toolsImageAvailable();
const String _dockerSkipReason =
    'Docker or the media-pipeline-tools:local image is not available in '
    'this environment (build it per docker/tools/README.md).';

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp(
      'pipeline-step-actions-',
    );
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  test(
    'restore-dry-run reports a failed run (not an uncaught throw reaching '
    'the caller) when media_trash does not exist yet — same parity-'
    "preserving behavior as the real Bash script's set -e hard failure",
    () async {
      final step = buildPipelineSteps().singleWhere(
        (step) => step.id == 'restore-dry-run',
      );
      final runner = PipelineRunner(workingDirectory: Directory.current.path);
      final settings = PipelineSettings(
        hdPath: tempRoot.path,
        reportDir: '${tempRoot.path}/reports',
      );

      final loggedChunks = <String>[];
      // The real assertion: this awaits to completion instead of throwing
      // out of `runner.run()` — proving `TrashRootNotFoundException` is
      // caught inside `runRestoreDryRunStep`, not left to propagate (see
      // that function's own doc comment on why this one case is a
      // deliberate exception to this file's general "let it propagate"
      // design).
      final result = await runner.run(
        step,
        settings,
        onLog: loggedChunks.add,
      );

      expect(result.succeeded, isFalse);
      expect(result.exitCode, 1);
      expect(result.output, contains('media_trash'));
      expect(loggedChunks.join(), contains('media_trash'));
    },
  );

  test(
    'immich-takeout-duplicate-dry-run runs end-to-end through PipelineRunner '
    'against a real ToolsContainer, correctly verifying a genuine '
    'basename+size+hash duplicate and reporting it as "Would move duplicate"',
    () async {
      final googleFotosDir =
          '${tempRoot.path}/immich_library/Takeout/Google Fotos';
      final canonical = File('$googleFotosDir/2024/IMG_0001.HEIC');
      final duplicate = File('$googleFotosDir/Fotos de 2024/IMG_0001.HEIC');
      await canonical.parent.create(recursive: true);
      await duplicate.parent.create(recursive: true);
      await canonical.writeAsBytes('wired-container-fixture-bytes'.codeUnits);
      await duplicate.writeAsBytes('wired-container-fixture-bytes'.codeUnits);

      final step = buildPipelineSteps().singleWhere(
        (step) => step.id == 'immich-takeout-duplicate-dry-run',
      );
      final runner = PipelineRunner(workingDirectory: Directory.current.path);
      final settings = PipelineSettings(
        hdPath: tempRoot.path,
        reportDir: '${tempRoot.path}/reports',
      );

      final loggedChunks = <String>[];
      final result = await runner.run(
        step,
        settings,
        onLog: loggedChunks.add,
      );

      expect(result.succeeded, isTrue);
      expect(
        result.output,
        contains('Would move duplicate: ${duplicate.path}'),
      );
      expect(result.output, contains('Kept canonical: ${canonical.path}'));
      expect(result.output, contains('Verified duplicates:  1'));
      // Nothing was actually moved — dry-run only.
      expect(await duplicate.exists(), isTrue);
      expect(await canonical.exists(), isTrue);
      // Log visibility: the live onLog stream saw real progress text, not
      // silence until the whole run completed.
      expect(loggedChunks, isNotEmpty);
      expect(loggedChunks.join(), contains('DRY RUN MODE'));
    },
    skip: _imageReady ? false : _dockerSkipReason,
  );

  test(
    'stitch-metadata runs end-to-end through PipelineRunner against a real '
    'ToolsContainer: extracts a real zip archive, applies exiftool metadata '
    'from its JSON sidecar, and stages the media file',
    () async {
      final rawZips = Directory('${tempRoot.path}/raw_takeout_zips');
      await rawZips.create(recursive: true);

      // A minimal real archive: one JPEG with a JSON sidecar carrying a
      // title, built the same way the existing stitch_metadata_test.dart
      // parity fixtures are (a real `zip` binary invocation), so this
      // step's wiring is exercised against a genuine archive, not a
      // hand-rolled in-memory fake.
      final workDir = await Directory.systemTemp.createTemp(
        'stitch-wiring-src-',
      );
      addTearDown(() async {
        if (await workDir.exists()) {
          await workDir.delete(recursive: true);
        }
      });
      final photo = File('${workDir.path}/photo.jpg');
      await photo.writeAsBytes(List<int>.filled(64, 0));
      await File('${workDir.path}/photo.jpg.json').writeAsString(
        '{"title": "Wired stitch-metadata test photo"}',
      );

      final zipResult = await Process.run('zip', [
        '-j',
        '${rawZips.path}/wiring-test.zip',
        photo.path,
        '${photo.path}.json',
      ]);
      expect(
        zipResult.exitCode,
        0,
        reason: 'test fixture setup requires a working `zip` binary',
      );

      final step = buildPipelineSteps().singleWhere(
        (step) => step.id == 'stitch-metadata',
      );
      final runner = PipelineRunner(workingDirectory: Directory.current.path);
      final settings = PipelineSettings(
        hdPath: tempRoot.path,
        reportDir: '${tempRoot.path}/reports',
      );

      final loggedChunks = <String>[];
      final result = await runner.run(
        step,
        settings,
        onLog: loggedChunks.add,
      );

      expect(result.succeeded, isTrue);
      expect(result.output, contains('media moved: 1'));
      final staged = File('${tempRoot.path}/cleaning_staging/photo.jpg');
      expect(await staged.exists(), isTrue);
      // The archive is deleted once staged, mirroring the Python script.
      expect(await File('${rawZips.path}/wiring-test.zip').exists(), isFalse);
      // Log visibility: MetadataStitcher's own `print` progress lines came
      // through live via onLog, not just in the final result.
      expect(loggedChunks.join(), contains('==> Extracting'));
    },
    skip: _imageReady ? false : _dockerSkipReason,
  );
}
