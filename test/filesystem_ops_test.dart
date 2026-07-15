import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/filesystem_ops.dart';

void main() {
  group('parentDirectory (dirname port)', () {
    test('returns the parent of a nested path', () {
      expect(parentDirectory('/a/b/c.jpg'), '/a/b');
    });

    test('returns "/" for a top-level path', () {
      expect(parentDirectory('/c.jpg'), '/');
    });

    test('returns "/" for the root path itself', () {
      expect(parentDirectory('/'), '/');
    });
  });

  group('SafeFileMover.moveNoClobber (generic move-safety primitive)', () {
    // These tests exercise SafeFileMover directly, independent of any
    // caller (e.g. TrashRestorer) — the primitive is shared by every
    // confirm-gated destructive script that needs "move this file
    // elsewhere, never overwriting an existing destination, safely across
    // filesystems." restore_from_trash_test.dart still covers the
    // trash-specific round-trip (path reconstruction + this primitive
    // together); these tests cover the primitive in isolation.
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('filesystem_ops_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('moves a file to a destination, creating parent directories as '
        'needed, and reports MoveResult.moved', () async {
      final src = File('${tempDir.path}/src.jpg');
      await src.writeAsString('bytes');
      final dst = File('${tempDir.path}/nested/dir/dst.jpg');

      const mover = SafeFileMover();
      final result = await mover.moveNoClobber(src.path, dst.path);

      expect(result, MoveResult.moved);
      expect(await src.exists(), isFalse);
      expect(await dst.exists(), isTrue);
      expect(await dst.readAsString(), 'bytes');
    });

    test('no-clobber: an existing destination is left untouched and '
        'MoveResult.skippedExisting is returned, matching `mv -n`', () async {
      final src = File('${tempDir.path}/src.jpg');
      await src.writeAsString('new-bytes');
      final dst = File('${tempDir.path}/dst.jpg');
      await dst.writeAsString('existing-bytes');

      const mover = SafeFileMover();
      final result = await mover.moveNoClobber(src.path, dst.path);

      expect(result, MoveResult.skippedExisting);
      // Neither file touched: src stays exactly where it was, dst keeps
      // its original content — nothing overwritten, nothing deleted.
      expect(await src.exists(), isTrue);
      expect(await src.readAsString(), 'new-bytes');
      expect(await dst.readAsString(), 'existing-bytes');
    });
  });

  group('cross-device rename fallback: copyVerifyAndReplace', () {
    // SafeFileMover's private _moveFile tries File.rename first (matching
    // `mv -n`'s fast path) and, only on a cross-device/cross-filesystem
    // failure (EXDEV, errno 18 — detected via
    // FileSystemException.osError.errorCode or a "cross-device" message
    // fallback), falls back to copyVerifyAndReplace(): copy + verify +
    // delete, mirroring what real `mv` does transparently across
    // filesystems.
    //
    // Reproducing a genuine EXDEV to reach this fallback via moveNoClobber
    // itself would require two distinct mounted filesystems/devices, which
    // isn't available in this sandbox or in CI — that specific trigger
    // remains a documented gap (see the last test in this group). But the
    // fallback body itself (copyVerifyAndReplace) is exposed directly and
    // takes an injectable [FileCopier], so its actual copy/verify/cleanup
    // logic — including the failure-cleanup path Cody flagged on PR #82
    // (originally against TrashRestorer, before this logic was extracted
    // here), where a corrupt/partial destination must never be left
    // stranded to silently mask a still-good source file — is fully
    // exercised here without needing EXDEV at all.
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('filesystem_ops_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('happy path: copies, verifies, then deletes the original', () async {
      final src = File('${tempDir.path}/src.jpg');
      final dst = File('${tempDir.path}/dst.jpg');
      await src.writeAsString('original-bytes');

      const mover = SafeFileMover();
      await mover.copyVerifyAndReplace(src.path, dst.path);

      expect(await src.exists(), isFalse);
      expect(await dst.exists(), isTrue);
      expect(await dst.readAsString(), 'original-bytes');
    });

    test('verification-failure cleanup: a corrupt/truncated copy is deleted '
        'before the failure propagates, never left stranded to mask the '
        'still-good original (Cody review finding on PR #82)', () async {
      final src = File('${tempDir.path}/src.jpg');
      final dst = File('${tempDir.path}/dst.jpg');
      await src.writeAsString('original-bytes-longer-than-truncated');

      // Simulate a copy that lands a truncated/corrupt destination file
      // rather than throwing outright — the case a real interrupted
      // cross-device copy could produce.
      final mover = SafeFileMover(
        copier: (srcPath, dstPath) async {
          await File(dstPath).writeAsString('truncated');
        },
      );

      await expectLater(
        mover.copyVerifyAndReplace(src.path, dst.path),
        throwsA(isA<FileSystemException>()),
      );

      // The corrupt partial destination must be gone, not stranded...
      expect(await dst.exists(), isFalse);
      // ...and the original must still be safely intact, since it's only
      // ever deleted after verification succeeds.
      expect(await src.exists(), isTrue);
      expect(await src.readAsString(), 'original-bytes-longer-than-truncated');
    });

    test('copier-throws cleanup: if the copier itself throws after partially '
        'writing dst, the partial file is still cleaned up', () async {
      final src = File('${tempDir.path}/src.jpg');
      final dst = File('${tempDir.path}/dst.jpg');
      await src.writeAsString('original-bytes');

      final mover = SafeFileMover(
        copier: (srcPath, dstPath) async {
          // Simulate a copy that writes a partial file, then fails
          // outright (e.g. a real disk-full or I/O error mid-copy).
          await File(dstPath).writeAsString('partial');
          throw const FileSystemException('simulated mid-copy I/O error');
        },
      );

      await expectLater(
        mover.copyVerifyAndReplace(src.path, dst.path),
        throwsA(isA<FileSystemException>()),
      );

      expect(await dst.exists(), isFalse);
      expect(await src.exists(), isTrue);
      expect(await src.readAsString(), 'original-bytes');
    });

    test(
      'no partial destination to clean up: verification failure when the '
      'copier never created dst at all does not throw a secondary error',
      () async {
        final src = File('${tempDir.path}/src.jpg');
        final dst = File('${tempDir.path}/dst.jpg');
        await src.writeAsString('original-bytes');

        final mover = SafeFileMover(
          copier: (srcPath, dstPath) async {
            // Copier reports success without actually writing anything —
            // an extreme edge case, but must not crash the cleanup step
            // (which only deletes dst if it actually exists).
          },
        );

        await expectLater(
          mover.copyVerifyAndReplace(src.path, dst.path),
          throwsA(isA<FileSystemException>()),
        );

        expect(await dst.exists(), isFalse);
        expect(await src.exists(), isTrue);
      },
    );

    test('documented gap: reaching this fallback via a genuine EXDEV rename '
        'failure (rather than calling copyVerifyAndReplace directly, as the '
        'tests above do) requires two real mounted filesystems, not '
        'exercisable via a single temp directory — flagging for reviewer '
        'awareness (Cody/Astrid) rather than claiming coverage that '
        "doesn't exist", () {
      expect(true, isTrue);
    });
  });

  group('uniqueDestinationPath (Bash unique_destination() parity)', () {
    // Bash-vs-Dart parity: every expected output below was captured by
    // actually running scripts/06_delete_duplicates.sh's/
    // scripts/12_clean_immich_takeout_duplicates.sh's shared
    // `unique_destination()` shell function (reproduced verbatim, sourced
    // fresh) against real files in a dot-free temp directory — not
    // hand-derived from reading the Bash source. This is the mini,
    // single-function-scoped parity test the task brief for this collision-
    // rename fix (part of #76) asked for, in the same spirit as the four
    // full-script Bash-vs-Dart parity tests elsewhere in this suite.
    //
    // Reference Bash function (character-for-character what `06`'s
    // `trash_file()` and `12`'s top-level `unique_destination()` both
    // carry):
    //
    // ```bash
    // unique_destination() {
    // 	local dst="$1"
    // 	if [[ ! -e "$dst" ]]; then
    // 		printf '%s\n' "$dst"
    // 		return
    // 	fi
    // 	local base suffix i candidate
    // 	base="${dst%.*}"
    // 	suffix=".${dst##*.}"
    // 	[[ "$base" == "$dst" ]] && suffix=""
    // 	i=1
    // 	while true; do
    // 		candidate="${base}_$i$suffix"
    // 		if [[ ! -e "$candidate" ]]; then
    // 			printf '%s\n' "$candidate"
    // 			return
    // 		fi
    // 		i=$((i + 1))
    // 	done
    // }
    // ```

    test('no collision: returns the desired path unchanged (Bash: '
        r'`[[ ! -e "$dst" ]]` early return)', () {
      expect(
        uniqueDestinationPath('/tmp/nodottest/a/b/fresh.jpg', (_) => false),
        '/tmp/nodottest/a/b/fresh.jpg',
      );
    });

    test('single collision on a normal extension: appends `_1` before the '
        'extension (Bash-verified: photo.jpg + photo_1.jpg taken -> '
        'photo_2.jpg)', () {
      final existing = {
        '/tmp/nodottest/a/b/photo.jpg',
        '/tmp/nodottest/a/b/photo_1.jpg',
      };
      expect(
        uniqueDestinationPath(
          '/tmp/nodottest/a/b/photo.jpg',
          existing.contains,
        ),
        '/tmp/nodottest/a/b/photo_2.jpg',
      );
    });

    test('dotfile (leading dot counts as "having a dot"): '
        '`.bashrc` splits to base `<dir>/`, suffix `.bashrc` (Bash-verified: '
        '/tmp/nodottest/a/b/.bashrc -> /tmp/nodottest/a/b/_1.bashrc)', () {
      final existing = {'/tmp/nodottest/a/b/.bashrc'};
      expect(
        uniqueDestinationPath('/tmp/nodottest/a/b/.bashrc', existing.contains),
        '/tmp/nodottest/a/b/_1.bashrc',
      );
    });

    test('no dot anywhere in the full path: no suffix is ever appended '
        '(Bash-verified: noext + noext_1 taken -> noext_2, no trailing '
        'characters after the number)', () {
      final existing = {
        '/tmp/nodottest/a/b/noext',
        '/tmp/nodottest/a/b/noext_1',
      };
      expect(
        uniqueDestinationPath('/tmp/nodottest/a/b/noext', existing.contains),
        '/tmp/nodottest/a/b/noext_2',
      );
    });

    test('multi-dot filename: only the LAST dot is the split point '
        '(Bash-verified: archive.tar.gz -> archive.tar_1.gz, not '
        'archive_1.tar.gz)', () {
      final existing = {'/tmp/nodottest/a/b/archive.tar.gz'};
      expect(
        uniqueDestinationPath(
          '/tmp/nodottest/a/b/archive.tar.gz',
          existing.contains,
        ),
        '/tmp/nodottest/a/b/archive.tar_1.gz',
      );
    });

    test('trailing dot with an empty extension: suffix is just `.` '
        '(Bash-verified: trailing. -> trailing_1.)', () {
      final existing = {'/tmp/nodottest/a/b/trailing.'};
      expect(
        uniqueDestinationPath(
          '/tmp/nodottest/a/b/trailing.',
          existing.contains,
        ),
        '/tmp/nodottest/a/b/trailing_1.',
      );
    });

    test('known Bash quirk, reproduced intentionally: a DOT IN A DIRECTORY '
        'COMPONENT (not the filename) still wins the split, because Bash\'s '
        '${r"${dst%.*}"} / ${r"${dst##*.}"} operate on the full path string, '
        'not the basename (Bash-verified: /tmp/nodottest/xy.z/photo -> '
        '/tmp/nodottest/xy_1.z/photo, even though "photo" itself has no '
        'extension) — this is Leo\'s #76/#77 review decision to match Bash '
        'exactly, warts included, not a bug in this port', () {
      final existing = {'/tmp/nodottest/xy.z/photo'};
      expect(
        uniqueDestinationPath('/tmp/nodottest/xy.z/photo', existing.contains),
        '/tmp/nodottest/xy_1.z/photo',
      );
    });

    test('keeps incrementing past a taken numbered candidate until a free '
        'one is found (no upper retry bound, matching Bash\'s unbounded '
        'while-true loop)', () {
      final existing = {
        '/t/f.jpg',
        '/t/f_1.jpg',
        '/t/f_2.jpg',
        '/t/f_3.jpg',
        '/t/f_4.jpg',
      };
      expect(
        uniqueDestinationPath('/t/f.jpg', existing.contains),
        '/t/f_5.jpg',
      );
    });
  });

  group('SafeFileMover.moveRenamingOnCollision (Bash unique_destination() '
      'move semantics)', () {
    // Matches `06_delete_duplicates.sh`, `12_clean_immich_takeout_duplicates.sh`,
    // and `13_dedupe_live_photos.sh`'s real collision behavior: never skip,
    // always resolve a free destination and move there. Contrast with
    // `moveNoClobber`'s `mv -n`/skip semantics above, which matches
    // `11_restore_from_trash.sh`'s real (different) Bash behavior instead.
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('filesystem_ops_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('no collision: moves directly to the desired destination and '
        'reports MoveResult.moved', () async {
      final src = File('${tempDir.path}/src.jpg');
      await src.writeAsString('bytes');
      final dst = File('${tempDir.path}/nested/dir/dst.jpg');

      const mover = SafeFileMover();
      final outcome = await mover.moveRenamingOnCollision(src.path, dst.path);

      expect(outcome.result, MoveResult.moved);
      expect(outcome.destinationPath, dst.path);
      expect(await src.exists(), isFalse);
      expect(await dst.exists(), isTrue);
      expect(await dst.readAsString(), 'bytes');
    });

    test('collision: moves to a numbered-suffix alternative instead of '
        'skipping — the source is always moved, never left in place, '
        'matching Bash\'s guarantee that a move into the trash always '
        'succeeds', () async {
      final src = File('${tempDir.path}/src.jpg');
      await src.writeAsString('new-bytes');
      final dst = File('${tempDir.path}/dst.jpg');
      await dst.writeAsString('existing-bytes');

      const mover = SafeFileMover();
      final outcome = await mover.moveRenamingOnCollision(src.path, dst.path);

      expect(outcome.result, MoveResult.movedWithSuffix);
      expect(outcome.destinationPath, '${tempDir.path}/dst_1.jpg');
      // The source is gone (moved), the original destination is untouched,
      // and the suffixed alternative has the source's bytes.
      expect(await src.exists(), isFalse);
      expect(await dst.readAsString(), 'existing-bytes');
      expect(
        await File('${tempDir.path}/dst_1.jpg').readAsString(),
        'new-bytes',
      );
    });

    test('repeated collisions: increments the numbered suffix until a free '
        'candidate is found', () async {
      final dst = File('${tempDir.path}/dst.jpg');
      await dst.writeAsString('0');
      await File('${tempDir.path}/dst_1.jpg').writeAsString('1');
      await File('${tempDir.path}/dst_2.jpg').writeAsString('2');

      final src = File('${tempDir.path}/src.jpg');
      await src.writeAsString('new');

      const mover = SafeFileMover();
      final outcome = await mover.moveRenamingOnCollision(src.path, dst.path);

      expect(outcome.result, MoveResult.movedWithSuffix);
      expect(outcome.destinationPath, '${tempDir.path}/dst_3.jpg');
      expect(await File('${tempDir.path}/dst_3.jpg').readAsString(), 'new');
    });
  });
}
