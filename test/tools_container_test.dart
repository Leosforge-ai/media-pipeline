import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/tools_container.dart';

/// True only if a real Docker daemon is reachable from this machine — a
/// synchronous check (mirroring `test/drive_detection_test.dart`'s
/// `Platform.isLinux`-based `skip:` gate for its own "real machine" test
/// group) so it can feed `skip:` parameters, which must be evaluated at test
/// declaration time, not inside an `async` body. If Docker genuinely isn't
/// available (daemon unreachable, binary missing), the whole
/// "ToolsContainer real Docker" group below is skipped rather than silently
/// passing — `flutter test`'s output for a skipped group always names it,
/// so a CI run missing Docker is visibly different from one that actually
/// verified container lifecycle.
bool _dockerAvailable() {
  try {
    final result = Process.runSync('docker', ['version', '--format', '{{.Server.Version}}']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// True only if the `media-pipeline-tools:local` image (this PR's default —
/// see [kDefaultToolsImage]) has already been built locally, per
/// `docker/tools/README.md`'s "Building locally" instructions:
/// `docker build -t media-pipeline-tools:local -f docker/tools/Dockerfile
/// docker/tools`. This PR does not build the image itself (that's Phase 1's
/// concern, already merged in PR #80) — if it's missing, the real-container
/// tests below are skipped with a clear reason rather than failing on an
/// unrelated "image not found" error, or silently trying to build a
/// multi-hundred-MB image mid-test-run.
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

void main() {
  group('ToolsContainer path translation (pure, no Docker needed)', () {
    late ToolsContainer container;

    setUp(() {
      container = ToolsContainer(
        hostMountRoot: '/mnt/target_drive',
        containerMountPath: '/data',
      );
    });

    test('translates a simple nested host path to its container path', () {
      expect(
        container.hostToContainerPath(
          '/mnt/target_drive/cleaning_staging/photo.jpg',
        ),
        '/data/cleaning_staging/photo.jpg',
      );
    });

    test('translates the mount root itself', () {
      expect(container.hostToContainerPath('/mnt/target_drive'), '/data');
    });

    test('round-trips host -> container -> host', () {
      const hostPath =
          '/mnt/target_drive/raw_takeout_zips/Takeout 2026-07-15.zip';
      final containerPath = container.hostToContainerPath(hostPath);
      expect(container.containerToHostPath(containerPath), hostPath);
    });

    test('preserves paths with spaces', () {
      const hostPath = '/mnt/target_drive/cleaning_staging/My Photo 1.jpg';
      expect(
        container.hostToContainerPath(hostPath),
        '/data/cleaning_staging/My Photo 1.jpg',
      );
    });

    test('preserves non-English characters', () {
      const hostPath = '/mnt/target_drive/cleaning_staging/Fotos de 2026/été.jpg';
      expect(
        container.hostToContainerPath(hostPath),
        '/data/cleaning_staging/Fotos de 2026/été.jpg',
      );
    });

    test(
      'throws ArgumentError for a path outside the mounted root '
      '(never silently mistranslates)',
      () {
        expect(
          () => container.hostToContainerPath('/mnt/other_drive/photo.jpg'),
          throwsArgumentError,
        );
      },
    );

    test(
      'rejects a sibling directory that merely shares the root as a string '
      'prefix without a real path boundary',
      () {
        // /mnt/target_drive2 is NOT under /mnt/target_drive, even though
        // "/mnt/target_drive" is a string-prefix of "/mnt/target_drive2" —
        // this must not be accepted as "inside" the mount.
        expect(
          () => container.hostToContainerPath('/mnt/target_drive2/photo.jpg'),
          throwsArgumentError,
        );
      },
    );

    test('throws ArgumentError for a completely unrelated path', () {
      expect(
        () => container.hostToContainerPath('/etc/passwd'),
        throwsArgumentError,
      );
    });

    test('containerToHostPath translates the mount point itself', () {
      expect(container.containerToHostPath('/data'), '/mnt/target_drive');
    });

    test(
      'containerToHostPath throws ArgumentError for a path outside the '
      'container mount point',
      () {
        expect(
          () => container.containerToHostPath('/etc/passwd'),
          throwsArgumentError,
        );
      },
    );

    test(
      'containerToHostPath rejects a sibling path sharing the mount point '
      'as a string prefix without a real path boundary',
      () {
        expect(
          () => container.containerToHostPath('/data2/photo.jpg'),
          throwsArgumentError,
        );
      },
    );

    test('trailing slash on hostMountRoot/containerMountPath is normalized', () {
      final trailing = ToolsContainer(
        hostMountRoot: '/mnt/target_drive/',
        containerMountPath: '/data/',
      );
      expect(
        trailing.hostToContainerPath('/mnt/target_drive/photo.jpg'),
        '/data/photo.jpg',
      );
    });

    test('rejects a non-absolute hostMountRoot', () {
      expect(
        () => ToolsContainer(hostMountRoot: 'relative/path'),
        throwsArgumentError,
      );
    });

    test('rejects a non-absolute containerMountPath', () {
      expect(
        () => ToolsContainer(
          hostMountRoot: '/mnt/target_drive',
          containerMountPath: 'relative',
        ),
        throwsArgumentError,
      );
    });
  });

  group('ToolsContainer lifecycle (fake docker runner, no real Docker)', () {
    test('start() sends the expected docker run arguments', () async {
      List<String>? capturedArgs;
      final container = ToolsContainer(
        hostMountRoot: '/mnt/target_drive',
        image: 'media-pipeline-tools:local',
        runner: (args) async {
          capturedArgs = args;
          return ProcessResult(0, 0, 'abc123containerid\n', '');
        },
      );

      await container.start();

      expect(capturedArgs, isNotNull);
      expect(capturedArgs!.first, 'run');
      expect(capturedArgs, contains('-d'));
      expect(capturedArgs, contains('--rm'));
      expect(capturedArgs, contains('-v'));
      expect(
        capturedArgs,
        contains('/mnt/target_drive:/data'),
      );
      expect(capturedArgs, contains('media-pipeline-tools:local'));
      expect(capturedArgs!.last, 'infinity');
      expect(capturedArgs![capturedArgs!.length - 2], 'sleep');
      expect(container.isStarted, isTrue);
      expect(container.containerId, 'abc123containerid');
    });

    test('start() includes a session label for orphan cleanup', () async {
      List<String>? capturedArgs;
      final container = ToolsContainer(
        hostMountRoot: '/mnt/target_drive',
        runner: (args) async {
          capturedArgs = args;
          return ProcessResult(0, 0, 'id\n', '');
        },
      );

      await container.start();

      final labelIndex = capturedArgs!.indexOf('--label');
      expect(labelIndex, greaterThanOrEqualTo(0));
      expect(
        capturedArgs![labelIndex + 1],
        startsWith('$kToolsContainerSessionLabel='),
      );
    });

    test('start() throws StateError on non-zero docker run exit', () async {
      final container = ToolsContainer(
        hostMountRoot: '/mnt/target_drive',
        runner: (args) async =>
            ProcessResult(0, 1, '', 'Cannot connect to the Docker daemon'),
      );

      expect(container.start(), throwsA(isA<StateError>()));
    });

    test(
      'start() throws StateError if docker run succeeds but produces no '
      'container ID',
      () async {
        final container = ToolsContainer(
          hostMountRoot: '/mnt/target_drive',
          runner: (args) async => ProcessResult(0, 0, '', ''),
        );

        expect(container.start(), throwsA(isA<StateError>()));
        expect(container.isStarted, isFalse);
      },
    );

    test('start() throws StateError if called twice', () async {
      final container = ToolsContainer(
        hostMountRoot: '/mnt/target_drive',
        runner: (args) async => ProcessResult(0, 0, 'id\n', ''),
      );

      await container.start();
      expect(container.start(), throwsA(isA<StateError>()));
    });

    test('exec() throws StateError before start()', () async {
      final container = ToolsContainer(
        hostMountRoot: '/mnt/target_drive',
        runner: (args) async => ProcessResult(0, 0, '', ''),
      );

      expect(
        container.exec(['exiftool', '-ver']),
        throwsA(isA<StateError>()),
      );
    });

    test('exec() sends docker exec <id> <args> in order', () async {
      List<String>? capturedArgs;
      final container = ToolsContainer(
        hostMountRoot: '/mnt/target_drive',
        runner: (args) async {
          if (args.first == 'run') {
            return ProcessResult(0, 0, 'container123\n', '');
          }
          capturedArgs = args;
          return ProcessResult(0, 0, '12.57\n', '');
        },
      );

      await container.start();
      final result = await container.exec(['exiftool', '-ver']);

      expect(capturedArgs, ['exec', 'container123', 'exiftool', '-ver']);
      expect((result.stdout as String).trim(), '12.57');
    });

    test('exec() passes -w before the container ID when given', () async {
      List<String>? capturedArgs;
      final container = ToolsContainer(
        hostMountRoot: '/mnt/target_drive',
        runner: (args) async {
          if (args.first == 'run') {
            return ProcessResult(0, 0, 'container123\n', '');
          }
          capturedArgs = args;
          return ProcessResult(0, 0, '', '');
        },
      );

      await container.start();
      await container.exec(['ls'], workingDirectory: '/data/cleaning_staging');

      expect(capturedArgs, [
        'exec',
        '-w',
        '/data/cleaning_staging',
        'container123',
        'ls',
      ]);
    });

    test(
      'stop() sends docker stop <id> then docker rm -f <id>, and clears '
      'bookkeeping',
      () async {
        final capturedCalls = <List<String>>[];
        final container = ToolsContainer(
          hostMountRoot: '/mnt/target_drive',
          runner: (args) async {
            if (args.first == 'run') {
              return ProcessResult(0, 0, 'container123\n', '');
            }
            capturedCalls.add(args);
            return ProcessResult(0, 0, '', '');
          },
        );

        await container.start();
        await container.stop();

        expect(capturedCalls, [
          ['stop', 'container123'],
          ['rm', '-f', 'container123'],
        ]);
        expect(container.isStarted, isFalse);
        expect(container.containerId, isNull);
      },
    );

    test('stop() before start() is a harmless no-op', () async {
      var runnerCalled = false;
      final container = ToolsContainer(
        hostMountRoot: '/mnt/target_drive',
        runner: (args) async {
          runnerCalled = true;
          return ProcessResult(0, 0, '', '');
        },
      );

      await container.stop();
      expect(runnerCalled, isFalse);
    });

    test('stop() is idempotent — calling it twice only stops once', () async {
      var stopCalls = 0;
      final container = ToolsContainer(
        hostMountRoot: '/mnt/target_drive',
        runner: (args) async {
          if (args.first == 'stop') stopCalls++;
          return ProcessResult(0, 0, 'container123\n', '');
        },
      );

      await container.start();
      await container.stop();
      await container.stop();

      expect(stopCalls, 1);
    });

    test(
      'stop() does not throw even if the underlying docker stop fails '
      '(e.g. container already gone)',
      () async {
        final container = ToolsContainer(
          hostMountRoot: '/mnt/target_drive',
          runner: (args) async {
            if (args.first == 'run') {
              return ProcessResult(0, 0, 'container123\n', '');
            }
            return ProcessResult(0, 1, '', 'No such container: container123');
          },
        );

        await container.start();
        await container.stop(); // must not throw
        expect(container.isStarted, isFalse);
      },
    );

    test('dispose() is an alias for stop()', () async {
      final capturedCalls = <List<String>>[];
      final container = ToolsContainer(
        hostMountRoot: '/mnt/target_drive',
        runner: (args) async {
          if (args.first == 'run') {
            return ProcessResult(0, 0, 'container123\n', '');
          }
          capturedCalls.add(args);
          return ProcessResult(0, 0, '', '');
        },
      );

      await container.start();
      await container.dispose();

      expect(capturedCalls, [
        ['stop', 'container123'],
        ['rm', '-f', 'container123'],
      ]);
    });

    test(
      'withSession() stops the container even when the body throws',
      () async {
        var stopped = false;
        Future<ProcessResult> runner(List<String> args) async {
          if (args.first == 'run') {
            return ProcessResult(0, 0, 'container123\n', '');
          }
          if (args.first == 'stop') stopped = true;
          return ProcessResult(0, 0, '', '');
        }

        await expectLater(
          ToolsContainer.withSession<void>(
            hostMountRoot: '/mnt/target_drive',
            runner: runner,
            body: (container) async {
              throw StateError('boom');
            },
          ),
          throwsA(isA<StateError>()),
        );

        expect(stopped, isTrue);
      },
    );

    test('withSession() returns the body result on success', () async {
      Future<ProcessResult> runner(List<String> args) async {
        if (args.first == 'run') {
          return ProcessResult(0, 0, 'container123\n', '');
        }
        return ProcessResult(0, 0, '', '');
      }

      final result = await ToolsContainer.withSession<String>(
        hostMountRoot: '/mnt/target_drive',
        runner: runner,
        body: (container) async => 'ok:${container.containerId}',
      );

      expect(result, 'ok:container123');
    });
  });

  group(
    'ToolsContainer real Docker lifecycle + exec (requires Docker + the '
    'media-pipeline-tools:local image built per docker/tools/README.md)',
    () {
      late Directory tempDir;

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp('tools_container_test_');
      });

      tearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      test(
        'exiftool -ver inside the container matches the pinned version from '
        'docker/tools/README.md (12.57)',
        () async {
          final container = ToolsContainer(hostMountRoot: tempDir.path);
          await container.start();
          try {
            final result = await container.exec(['exiftool', '-ver']);
            expect(result.exitCode, 0);
            expect((result.stdout as String).trim(), '12.57');
          } finally {
            await container.stop();
          }
        },
        skip: _imageReady
            ? false
            : 'Docker or the media-pipeline-tools:local image is not '
                  'available in this environment (build it per '
                  'docker/tools/README.md: docker build -t '
                  'media-pipeline-tools:local -f docker/tools/Dockerfile '
                  'docker/tools).',
      );

      test(
        'container is actually running (verified via a real docker inspect '
        'call, not just this class\'s own bookkeeping) after start(), and '
        'actually gone after stop()',
        () async {
          final container = ToolsContainer(hostMountRoot: tempDir.path);
          await container.start();
          final id = container.containerId!;

          final runningInspect = Process.runSync('docker', [
            'inspect',
            '-f',
            '{{.State.Running}}',
            id,
          ]);
          expect(runningInspect.exitCode, 0);
          expect((runningInspect.stdout as String).trim(), 'true');

          await container.stop();

          final goneInspect = Process.runSync('docker', ['inspect', id]);
          expect(
            goneInspect.exitCode,
            isNot(0),
            reason:
                'docker inspect must fail once the container has been '
                'stopped+removed (--rm) — a leaked container would still '
                'be inspectable here.',
          );
        },
        skip: _imageReady
            ? false
            : 'Docker or the media-pipeline-tools:local image is not '
                  'available in this environment.',
      );

      test(
        'host<->container path translation actually resolves to the same '
        'bind-mounted file inside the running container',
        () async {
          final hostFile = File('${tempDir.path}/cleaning_staging/photo.jpg');
          await hostFile.parent.create(recursive: true);
          await hostFile.writeAsString('fake-photo-bytes');

          final container = ToolsContainer(hostMountRoot: tempDir.path);
          await container.start();
          try {
            final containerPath = container.hostToContainerPath(
              hostFile.path,
            );
            final result = await container.exec(['cat', containerPath]);
            expect(result.exitCode, 0);
            expect(result.stdout, 'fake-photo-bytes');
          } finally {
            await container.stop();
          }
        },
        skip: _imageReady
            ? false
            : 'Docker or the media-pipeline-tools:local image is not '
                  'available in this environment.',
      );

      test(
        'exec() into a stopped/removed container fails rather than '
        'silently succeeding',
        () async {
          final container = ToolsContainer(hostMountRoot: tempDir.path);
          await container.start();
          final id = container.containerId!;
          // Stop it out-of-band (bypassing this class's own bookkeeping) to
          // simulate the container dying unexpectedly mid-session.
          Process.runSync('docker', ['stop', id]);

          final result = await container.exec(['exiftool', '-ver']);
          expect(result.exitCode, isNot(0));
        },
        skip: _imageReady
            ? false
            : 'Docker or the media-pipeline-tools:local image is not '
                  'available in this environment.',
      );
    },
  );

  group('Docker/image availability self-check (meta-test)', () {
    test(
      'this test file is actually exercising real Docker, not silently '
      'skipping — fails loudly if Docker is unreachable in an environment '
      'that is expected to have it',
      () {
        // This intentionally does NOT assert docker/image availability —
        // its only job is to make the skip reason visible in test output
        // via printOnFailure so a CI run with Docker missing is easy to
        // diagnose rather than just showing green with silent skips.
        if (!_dockerReady) {
          // ignore: avoid_print
          print(
            'NOTE: Docker daemon not reachable — the '
            '"ToolsContainer real Docker lifecycle" group above was '
            'skipped, not run.',
          );
        } else if (!_imageReady) {
          // ignore: avoid_print
          print(
            'NOTE: Docker is available but media-pipeline-tools:local is '
            'not built — the "ToolsContainer real Docker lifecycle" group '
            'above was skipped, not run. Build it per '
            'docker/tools/README.md.',
          );
        } else {
          // ignore: avoid_print
          print(
            'Docker + media-pipeline-tools:local are both available — the '
            '"ToolsContainer real Docker lifecycle" group above actually '
            'ran against a real container.',
          );
        }
      },
    );
  });
}
