import 'package:flutter_test/flutter_test.dart';
import 'package:media_pipeline_app/src/duplicate_report.dart';

void main() {
  group('parseDuplicateDryRunOutput', () {
    test('extracts a keep/trash pair for a single group', () {
      const output = '''
SAFETY NOTICE
-------------
This script NEVER permanently deletes files.

DRY RUN MODE: no files will be moved

==> Processing duplicate report: /home/leo/czkawka_reports/duplicate_files.txt
Keep: /mnt/target_drive/cleaning_staging/a.jpg
Would trash: /mnt/target_drive/cleaning_staging/b.jpg

Done.
Dry-run complete. Review the output. Do NOT blindly run --confirm.
''';

      final result = parseDuplicateDryRunOutput(output);

      expect(result.pairs, [
        const DuplicateReviewPair(
          keepPath: '/mnt/target_drive/cleaning_staging/a.jpg',
          trashPath: '/mnt/target_drive/cleaning_staging/b.jpg',
        ),
      ]);
      expect(result.orphanTrashLineCount, 0);
    });

    test('pairs one keep with multiple trash files in the same group', () {
      const output = '''
Keep: /staging/keep.jpg
Would trash: /staging/dup1.jpg
Would trash: /staging/dup2.jpg
Would trash: /staging/dup3.jpg

''';

      final result = parseDuplicateDryRunOutput(output);

      expect(result.pairs.length, 3);
      expect(result.pairs.every((p) => p.keepPath == '/staging/keep.jpg'), isTrue);
      expect(result.pairs.map((p) => p.trashPath), [
        '/staging/dup1.jpg',
        '/staging/dup2.jpg',
        '/staging/dup3.jpg',
      ]);
    });

    test('handles multiple groups without leaking keep across a blank line', () {
      const output = '''
Keep: /staging/groupA/keep.jpg
Would trash: /staging/groupA/trash.jpg

Keep: /staging/groupB/keep.jpg
Would trash: /staging/groupB/trash.jpg

''';

      final result = parseDuplicateDryRunOutput(output);

      expect(result.pairs, [
        const DuplicateReviewPair(
          keepPath: '/staging/groupA/keep.jpg',
          trashPath: '/staging/groupA/trash.jpg',
        ),
        const DuplicateReviewPair(
          keepPath: '/staging/groupB/keep.jpg',
          trashPath: '/staging/groupB/trash.jpg',
        ),
      ]);
    });

    test(
      'never treats report headers, banners, or diagnostics as paths',
      () {
        const output = '''
SAFETY NOTICE
-------------
This script NEVER permanently deletes files. It moves selected duplicate files
from cleaning_staging into media_trash. You must inspect the dry-run output
before using --confirm.

DRY RUN MODE: no files will be moved

==> Processing duplicate report: /home/leo/czkawka_reports/duplicate_images.txt
Found 12 images which have similar friends
1000x800 - 2.3 MiB
Refusing outside staging: /etc/passwd
Missing, skipping: /mnt/target_drive/cleaning_staging/gone.jpg
Keep: /mnt/target_drive/cleaning_staging/a.jpg
Would trash: /mnt/target_drive/cleaning_staging/b.jpg

Done.
Dry-run complete. Review the output. Do NOT blindly run --confirm.
''';

        final result = parseDuplicateDryRunOutput(output);

        expect(result.pairs.length, 1);
        expect(result.pairs.single.keepPath, endsWith('/a.jpg'));
        expect(result.pairs.single.trashPath, endsWith('/b.jpg'));
        // None of the header/diagnostic lines ever leak into a pair's path.
        for (final pair in result.pairs) {
          expect(pair.keepPath, isNot(contains('Found')));
          expect(pair.keepPath, isNot(contains('MiB')));
          expect(pair.trashPath, isNot(contains('/etc/passwd')));
          expect(pair.trashPath, isNot(contains('gone.jpg')));
        }
      },
    );

    test(
      'counts an orphan "Would trash" line without pairing it to a stale keep',
      () {
        const output = '''
Would trash: /staging/orphan.jpg

Keep: /staging/keep.jpg
Would trash: /staging/trash.jpg
''';

        final result = parseDuplicateDryRunOutput(output);

        expect(result.orphanTrashLineCount, 1);
        expect(result.pairs, [
          const DuplicateReviewPair(
            keepPath: '/staging/keep.jpg',
            trashPath: '/staging/trash.jpg',
          ),
        ]);
      },
    );

    test('ignores a relative-looking "Would trash" line (never a real path)', () {
      const output = '''
Keep: /staging/keep.jpg
Would trash: relative/not/absolute.jpg
''';

      final result = parseDuplicateDryRunOutput(output);

      expect(result.pairs, isEmpty);
      expect(result.orphanTrashLineCount, 0);
    });

    test('returns no pairs for empty input', () {
      final result = parseDuplicateDryRunOutput('');

      expect(result.pairs, isEmpty);
      expect(result.orphanTrashLineCount, 0);
    });
  });

  group('sampleDuplicateReviewPairs', () {
    List<DuplicateReviewPair> makePairs(int n) => [
      for (var i = 0; i < n; i++)
        DuplicateReviewPair(keepPath: '/keep$i', trashPath: '/trash$i'),
    ];

    test('returns every pair unsampled when under the max', () {
      final pairs = makePairs(5);

      final sample = sampleDuplicateReviewPairs(pairs, maxPairs: 20);

      expect(sample.shown, pairs);
      expect(sample.totalPairs, 5);
      expect(sample.isSampled, isFalse);
    });

    test('samples down to maxPairs and reports the true total honestly', () {
      final pairs = makePairs(143);

      final sample = sampleDuplicateReviewPairs(pairs, maxPairs: 20);

      expect(sample.shown.length, 20);
      expect(sample.totalPairs, 143);
      expect(sample.isSampled, isTrue);
      // Every sampled pair really came from the original list.
      for (final pair in sample.shown) {
        expect(pairs, contains(pair));
      }
    });

    test('is reproducible for the same seed', () {
      final pairs = makePairs(143);

      final first = sampleDuplicateReviewPairs(pairs, maxPairs: 20, seed: 7);
      final second = sampleDuplicateReviewPairs(pairs, maxPairs: 20, seed: 7);

      expect(first.shown, second.shown);
    });
  });

  group('isDisplayableImagePath', () {
    test('accepts common still-image extensions case-insensitively', () {
      expect(isDisplayableImagePath('/a/b.jpg'), isTrue);
      expect(isDisplayableImagePath('/a/b.JPEG'), isTrue);
      expect(isDisplayableImagePath('/a/b.png'), isTrue);
      expect(isDisplayableImagePath('/a/b.WEBP'), isTrue);
    });

    test('rejects video and other non-thumbnailable formats', () {
      expect(isDisplayableImagePath('/a/b.mp4'), isFalse);
      expect(isDisplayableImagePath('/a/b.mov'), isFalse);
      expect(isDisplayableImagePath('/a/b.heic'), isFalse);
      expect(isDisplayableImagePath('/a/b'), isFalse);
    });
  });

  group('duplicateReviewFileName', () {
    test('returns the last path segment', () {
      expect(
        duplicateReviewFileName('/mnt/target_drive/cleaning_staging/a.jpg'),
        'a.jpg',
      );
    });

    test('handles a trailing slash without crashing', () {
      expect(duplicateReviewFileName('/mnt/target_drive/'), 'target_drive');
    });
  });
}
