import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'duplicate_report.dart';
import 'guided_run_checkpoint_store.dart';
import 'immich_connection.dart';
import 'memory_curator.dart';
import 'memory_feedback.dart';
import 'memory_write_flow.dart';
import 'immich_phone_checklist_store.dart';
import 'pipeline_models.dart';
import 'pipeline_runner.dart';

class MediaPipelineApp extends StatelessWidget {
  const MediaPipelineApp({
    super.key,
    this.immichClient,
    this.checklistStore,
    this.guidedRunCheckpointStore,
    this.memoryPreviewState = MemoryPreviewDisplayState.sampleReady,
    this.memoryPreviewMessage,
    this.runner,
  });

  final ImmichApiClient? immichClient;
  final ImmichChecklistStore? checklistStore;
  // Test-only seam: lets widget tests substitute an in-memory-backed store
  // (a temp-directory-backed GuidedRunCheckpointStore) instead of the real
  // app's local app-data directory. Left null in the real app.
  final GuidedRunCheckpointStore? guidedRunCheckpointStore;
  final MemoryPreviewDisplayState memoryPreviewState;
  final String? memoryPreviewMessage;
  // Test-only seam: lets widget tests substitute a fake PipelineRunner
  // instead of spawning real pipeline scripts, so the delete-confirm
  // thumbnail-review gate (#49) can be exercised end-to-end without side
  // effects. Left null in the real app, which builds its own runner.
  final PipelineRunner? runner;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Media Pipeline',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff2f6f73),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        visualDensity: VisualDensity.compact,
      ),
      home: PipelineHomePage(
        immichClient: immichClient,
        checklistStore: checklistStore,
        guidedRunCheckpointStore: guidedRunCheckpointStore,
        memoryPreviewState: memoryPreviewState,
        memoryPreviewMessage: memoryPreviewMessage,
        runner: runner,
      ),
    );
  }
}

class PipelineHomePage extends StatefulWidget {
  const PipelineHomePage({
    super.key,
    this.immichClient,
    this.checklistStore,
    this.guidedRunCheckpointStore,
    this.memoryPreviewState = MemoryPreviewDisplayState.sampleReady,
    this.memoryPreviewMessage,
    this.runner,
  });

  final ImmichApiClient? immichClient;
  final ImmichChecklistStore? checklistStore;
  final GuidedRunCheckpointStore? guidedRunCheckpointStore;
  final MemoryPreviewDisplayState memoryPreviewState;
  final String? memoryPreviewMessage;
  final PipelineRunner? runner;

  @override
  State<PipelineHomePage> createState() => _PipelineHomePageState();
}

class _PipelineHomePageState extends State<PipelineHomePage> {
  final List<PipelineStep> _steps = buildPipelineSteps();
  final Map<String, StepRunState> _states = {};
  late final PipelineRunner _runner;
  late final GuidedRunController _guidedRunController;
  // Resolved via buildGuidedRunSteps(), which throws if the chain ever
  // includes a PipelineRisk.confirmRequired step. Looking guided-run steps
  // up through this map (instead of _steps directly) keeps that safety
  // check live in the running app, not just exercised by tests that call
  // buildGuidedRunSteps() in isolation.
  late final Map<String, PipelineStep> _guidedRunStepsById;
  late final List<List<String>> _guidedSegments;
  int _guidedSegmentIndex = 0;
  bool _guidedRunning = false;
  GuidedRunResult? _guidedLastResult;
  // How many steps at the start of the *current* segment (index
  // _guidedSegmentIndex) have already succeeded, across possibly more than
  // one _runNextGuidedSegment() call. Reset to 0 whenever the segment
  // advances or a retry's settings differ from the failed attempt's. Lets a
  // retry after a step failure resume from the failed step instead of
  // re-running the whole segment from the top (issue #51, item 2).
  int _guidedSegmentCompletedCount = 0;
  // The PipelineSettings snapshot the current segment's steps have actually
  // been run against so far. A retry only skips already-succeeded steps
  // when this still matches the settings in effect for the retry — if the
  // user edited hdPath/reportDir in between, those earlier successes ran
  // against a different target and can no longer be trusted, so the
  // segment restarts from its first step instead.
  PipelineSettings? _guidedSegmentAttemptSettings;
  late final ImmichApiClient _immichClient;
  late final ImmichChecklistStore _checklistStore;
  late final GuidedRunCheckpointStore _guidedRunCheckpointStore;
  late final TextEditingController _hdPathController;
  late final TextEditingController _immichApiKeyController;
  late final TextEditingController _immichUrlController;
  late final TextEditingController _reportDirController;
  late PipelineSettings _settings;
  List<ImmichPhoneBackupChecklist> _phoneChecklists = [];
  bool _loadingPhoneChecklists = true;
  int _selectedIndex = 0;
  _AppMode _mode = _AppMode.workflow;
  String? _runningStepId;
  bool _checkingImmich = false;
  ImmichConnectionReport? _immichReport;
  ImmichConnectionException? _immichFailure;
  // Whether a human has opened the thumbnail-diff duplicate review screen
  // (issue #49) for the *current* "delete-dry-run" output at least once.
  // Reset to false whenever that dry-run step starts running again, so a
  // stale acknowledgment can never carry over to a new (possibly
  // different) duplicate set. Read by canRunStep() as an additional,
  // additive gate on top of the existing dry-run-succeeded requirement for
  // "delete-confirm" — see PipelineStep.requiresDuplicateThumbnailReview.
  bool _dedupReviewAcknowledged = false;

  // Union of original-report indices (see `DuplicateReviewSample.
  // shownIndices`) the human has actually had displayed in the thumbnail
  // review dialog for the *current* "delete-dry-run" output, across
  // possibly more than one sample batch (issue #53). Reset together with
  // `_dedupReviewAcknowledged` whenever a fresh dry-run starts, for the
  // same reason: a new duplicate set invalidates any prior coverage.
  // Purely informational — it never gates `canRunStep()`, which still only
  // requires `_dedupReviewAcknowledged` (opening the dialog once), so this
  // is additive framing on top of an unchanged gate, not a new gate.
  Set<int> _dedupReviewedIndices = {};

  PipelineStep get _selectedStep => _steps[_selectedIndex];

  @override
  void initState() {
    super.initState();
    _settings = PipelineSettings.defaults();
    _runner =
        widget.runner ?? PipelineRunner(workingDirectory: Directory.current.path);
    _guidedRunController = GuidedRunController(runner: _runner);
    _guidedRunStepsById = {
      for (final step in buildGuidedRunSteps()) step.id: step,
    };
    _guidedSegments = buildGuidedRunSegments();
    _immichClient = widget.immichClient ?? ImmichApiClient();
    _checklistStore = widget.checklistStore ?? ImmichChecklistStore();
    _guidedRunCheckpointStore =
        widget.guidedRunCheckpointStore ?? GuidedRunCheckpointStore();
    _hdPathController = TextEditingController(text: _settings.hdPath);
    _immichUrlController = TextEditingController(text: 'http://localhost:2283');
    _immichApiKeyController = TextEditingController();
    _reportDirController = TextEditingController(text: _settings.reportDir);
    _phoneChecklists = [
      ImmichPhoneBackupChecklist.empty(id: _newChecklistId()),
    ];
    for (final step in _steps) {
      _states[step.id] = const StepRunState();
    }
    unawaited(_loadPhoneChecklists());
    unawaited(_loadGuidedRunCheckpoint());
  }

  /// Restores `_guidedSegmentIndex` from a previously persisted checkpoint
  /// (issue #51, item 1), so an app restart mid-guided-run shows "Continue
  /// Guided Run" at the right point instead of silently resetting to
  /// segment 0. A missing, corrupt, or stale (see
  /// `GuidedRunCheckpoint.isStale`) checkpoint just leaves the guided run
  /// starting fresh, same as before this existed.
  Future<void> _loadGuidedRunCheckpoint() async {
    try {
      final checkpoint = await _guidedRunCheckpointStore.load();
      if (!mounted || checkpoint == null) {
        return;
      }
      if (checkpoint.isStale(
        currentHdPath: _settings.hdPath,
        currentReportDir: _settings.reportDir,
      )) {
        unawaited(_guidedRunCheckpointStore.clear());
        return;
      }
      final restoredIndex = checkpoint.segmentIndex
          .clamp(0, _guidedSegments.length)
          .toInt();
      if (restoredIndex <= 0) {
        return;
      }
      setState(() {
        _guidedSegmentIndex = restoredIndex;
      });
    } catch (_) {
      // Non-fatal: a corrupt/unreadable checkpoint file just means the
      // guided run starts from segment 0, same as if none existed.
    }
  }

  @override
  void dispose() {
    _hdPathController.dispose();
    _immichApiKeyController.dispose();
    _immichUrlController.dispose();
    _reportDirController.dispose();
    super.dispose();
  }

  Future<void> _loadPhoneChecklists() async {
    try {
      final loaded = await _checklistStore.load();
      if (!mounted) {
        return;
      }
      setState(() {
        _phoneChecklists = loaded.isEmpty
            ? [ImmichPhoneBackupChecklist.empty(id: _newChecklistId())]
            : loaded;
        _loadingPhoneChecklists = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _loadingPhoneChecklists = false);
    }
  }

  void _persistPhoneChecklists() {
    unawaited(_checklistStore.save(_phoneChecklists));
  }

  void _upsertPhoneChecklist(ImmichPhoneBackupChecklist updated) {
    setState(() {
      final index = _phoneChecklists.indexWhere(
        (item) => item.id == updated.id,
      );
      if (index == -1) {
        _phoneChecklists = [..._phoneChecklists, updated];
      } else {
        final next = [..._phoneChecklists];
        next[index] = updated;
        _phoneChecklists = next;
      }
    });
    _persistPhoneChecklists();
  }

  void _addPhoneChecklist() {
    setState(() {
      _phoneChecklists = [
        ..._phoneChecklists,
        ImmichPhoneBackupChecklist.empty(id: _newChecklistId()),
      ];
    });
    _persistPhoneChecklists();
  }

  void _removePhoneChecklist(String id) {
    setState(() {
      _phoneChecklists = [
        for (final item in _phoneChecklists)
          if (item.id != id) item,
      ];
      if (_phoneChecklists.isEmpty) {
        _phoneChecklists = [
          ImmichPhoneBackupChecklist.empty(id: _newChecklistId()),
        ];
      }
    });
    _persistPhoneChecklists();
  }

  Future<void> _runSelectedStep() async {
    final step = _selectedStep;
    final canRun = canRunStep(
      step: step,
      states: _states,
      duplicateThumbnailReviewAcknowledged: _dedupReviewAcknowledged,
    );
    if (_runningStepId != null || !canRun) {
      return;
    }

    setState(() {
      _settings = _settings.copyWith(
        hdPath: _hdPathController.text.trim(),
        reportDir: _reportDirController.text.trim(),
      );
      _runningStepId = step.id;
      _states[step.id] = const StepRunState(status: PipelineStepStatus.running);
      if (step.id == 'delete-dry-run') {
        // A fresh dry-run can produce a different duplicate set, so any
        // earlier thumbnail-review acknowledgment — and any sample-coverage
        // tracking (#53) — no longer applies.
        _dedupReviewAcknowledged = false;
        _dedupReviewedIndices = {};
      }
    });

    final result = await _runner.run(
      step,
      _settings,
      onLog: (chunk) {
        if (!mounted) {
          return;
        }
        setState(() {
          final current = _states[step.id] ?? const StepRunState();
          _states[step.id] = current.copyWith(log: current.log + chunk);
        });
      },
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _runningStepId = null;
      _states[step.id] = (_states[step.id] ?? const StepRunState()).copyWith(
        status: result.succeeded
            ? PipelineStepStatus.succeeded
            : PipelineStepStatus.failed,
        exitCode: result.exitCode,
        log: result.output,
        stdoutLog: result.stdoutOutput,
      );
    });
  }

  /// Resolves a guided-run step id via [_guidedRunStepsById] (built from
  /// [buildGuidedRunSteps]) rather than [_steps] directly, so every guided
  /// step the app actually runs has passed that function's confirm-gate
  /// safety check.
  PipelineStep _guidedStepById(String id) {
    final step = _guidedRunStepsById[id];
    if (step == null) {
      throw StateError(
        'Guided run segment references step id "$id" that is not part of '
        'the validated guided run chain.',
      );
    }
    return step;
  }

  bool get _guidedRunFinished => _guidedSegmentIndex >= _guidedSegments.length;

  bool get _canRunNextGuidedSegment {
    if (_guidedRunning || _runningStepId != null || _guidedRunFinished) {
      return false;
    }
    return _guidedSegments[_guidedSegmentIndex]
        .map(_guidedStepById)
        .every(isStepSupportedOnCurrentPlatform);
  }

  String get _guidedRunButtonLabel {
    if (_guidedRunFinished) {
      return 'Guided Run Complete';
    }
    return _guidedSegmentIndex == 0 ? 'Run Guided Pipeline' : 'Continue Guided Run';
  }

  String get _guidedRunStatusMessage {
    if (_guidedRunning) {
      return 'Guided run in progress…';
    }

    final lastResult = _guidedLastResult;
    if (lastResult == null) {
      return 'Chains the safe/review steps (system check through duplicate '
          'scan, the dedup dry-run, cleanup verification, and Immich sync) '
          'automatically. It always stops before "Move Duplicates To Trash" '
          'and before an Immich rescan for an explicit manual step.';
    }

    if (lastResult.outcome == GuidedRunOutcome.stepFailed) {
      return 'Guided run stopped: "${lastResult.failedStepId}" failed '
          '(exit ${lastResult.failedExitCode}). Review its log, fix the '
          'issue, then continue — it resumes from this step, not the start '
          'of the segment (unless you changed the HD path or report '
          'directory, which restarts the segment from its first step).';
    }

    if (lastResult.outcome == GuidedRunOutcome.aborted) {
      return 'Guided run was cancelled before finishing this segment.';
    }

    // outcome == completed
    if (_guidedRunFinished) {
      return 'Guided run finished through the Immich library sync. Review '
          'it, then continue manually with the Immich rescan / setup and '
          'verification steps in the list.';
    }

    final justFinishedCheckpoint = _guidedSegments[_guidedSegmentIndex - 1].last;
    if (justFinishedCheckpoint == 'delete-dry-run') {
      return 'Checkpoint reached: review the duplicate move plan in the '
          '"Review Duplicate Move Plan" step\'s output. Manually run "Move '
          'Duplicates To Trash" if you want to delete, or skip it — then '
          'continue the guided run.';
    }
    return 'Guided run segment finished. Continue when ready.';
  }

  Future<void> _runNextGuidedSegment() async {
    if (!_canRunNextGuidedSegment) {
      return;
    }

    final fullSegmentStepIds = _guidedSegments[_guidedSegmentIndex];
    final attemptSettings = _settings.copyWith(
      hdPath: _hdPathController.text.trim(),
      reportDir: _reportDirController.text.trim(),
    );

    // Resume from the step that failed last time instead of re-running the
    // whole segment from the top (issue #51, item 2) — but only when the
    // settings driving this attempt are unchanged from the failed one.
    // Earlier steps in this segment already succeeded against
    // _guidedSegmentAttemptSettings; if the human edited the HD path or
    // report directory before retrying, those successes no longer describe
    // the target this attempt will actually run against, so re-validate by
    // restarting the segment from its first step instead of trusting them.
    final previousAttemptSettings = _guidedSegmentAttemptSettings;
    final settingsUnchanged =
        previousAttemptSettings != null &&
        previousAttemptSettings.hdPath == attemptSettings.hdPath &&
        previousAttemptSettings.reportDir == attemptSettings.reportDir;
    final resumeFromIndex = settingsUnchanged
        ? _guidedSegmentCompletedCount
              .clamp(0, fullSegmentStepIds.length)
              .toInt()
        : 0;
    final segmentStepIds = fullSegmentStepIds.sublist(resumeFromIndex);
    final segmentSteps = segmentStepIds.map(_guidedStepById).toList();

    setState(() {
      _settings = attemptSettings;
      _guidedSegmentAttemptSettings = attemptSettings;
      _guidedRunning = true;
    });

    final result = await _guidedRunController.run(
      steps: segmentSteps,
      settings: _settings,
      onStepStart: (step) {
        if (!mounted) {
          return;
        }
        setState(() {
          _runningStepId = step.id;
          _states[step.id] = const StepRunState(
            status: PipelineStepStatus.running,
          );
          if (step.id == 'delete-dry-run') {
            // Same invalidation rule as the manual single-step run path.
            _dedupReviewAcknowledged = false;
            _dedupReviewedIndices = {};
          }
        });
      },
      onStepComplete: (step, stepResult) {
        if (!mounted) {
          return;
        }
        setState(() {
          _runningStepId = null;
          _states[step.id] = (_states[step.id] ?? const StepRunState())
              .copyWith(
                status: stepResult.succeeded
                    ? PipelineStepStatus.succeeded
                    : PipelineStepStatus.failed,
                exitCode: stepResult.exitCode,
                log: stepResult.output,
                stdoutLog: stepResult.stdoutOutput,
              );
        });
      },
      onLog: (chunk) {
        final currentStepId = _runningStepId;
        if (!mounted || currentStepId == null) {
          return;
        }
        setState(() {
          final current = _states[currentStepId] ?? const StepRunState();
          _states[currentStepId] = current.copyWith(log: current.log + chunk);
        });
      },
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _guidedRunning = false;
      _guidedLastResult = result;
      _guidedSegmentCompletedCount =
          resumeFromIndex + result.completedStepIds.length;
      if (result.outcome == GuidedRunOutcome.completed) {
        _guidedSegmentIndex += 1;
        _guidedSegmentCompletedCount = 0;
        _guidedSegmentAttemptSettings = null;
      }
    });

    // Persist checkpoint progress (issue #51, item 1) only on a fully
    // completed segment: a step failure or abort doesn't move
    // _guidedSegmentIndex, so there's nothing new to persist there — the
    // in-memory retry-from-failed-step state above already covers resuming
    // within the current app session.
    if (result.outcome == GuidedRunOutcome.completed) {
      if (_guidedRunFinished) {
        unawaited(_guidedRunCheckpointStore.clear());
      } else {
        unawaited(
          _guidedRunCheckpointStore.save(
            GuidedRunCheckpoint(
              segmentIndex: _guidedSegmentIndex,
              hdPath: _settings.hdPath,
              reportDir: _settings.reportDir,
              updatedAt: DateTime.now(),
            ),
          ),
        );
      }
    }
  }

  /// Opens the thumbnail-diff duplicate review dialog (#49) for the current
  /// "delete-dry-run" output and records that it was shown.
  ///
  /// Marking the review acknowledged as soon as the dialog is opened (not
  /// only after it closes) is intentional: opening it is the concrete,
  /// testable user action this gate requires — see
  /// `PipelineStep.requiresDuplicateThumbnailReview` and `canRunStep()`.
  /// This never runs any command and never touches the filesystem beyond
  /// the read-only `Image.file` thumbnails inside the dialog.
  Future<void> _openDedupReviewDialog() async {
    // Stdout-only: the review dialog parses "Keep:"/"Would trash:"
    // announcements, a safety-relevant read that must never be able to pick
    // up an interleaved stderr line — see `StepRunState.stdoutLog` and
    // issue #54.
    final dryRunLog = _states['delete-dry-run']?.stdoutLog ?? '';
    setState(() {
      _dedupReviewAcknowledged = true;
    });
    await showDialog<void>(
      context: context,
      builder: (context) => _DuplicateThumbnailReviewDialog(
        dryRunOutput: dryRunLog,
        initialReviewedIndices: _dedupReviewedIndices,
        // Updated live as the human requests additional sample batches
        // (#53), not only when the dialog closes, so a coverage panel
        // reading `_dedupReviewedIndices` from outside the dialog can never
        // show a stale percentage even if the app is torn down mid-review.
        onReviewedIndicesChanged: (indices) {
          if (!mounted) {
            return;
          }
          setState(() {
            _dedupReviewedIndices = indices;
          });
        },
      ),
    );
  }

  Future<void> _checkImmichConnection() async {
    if (_checkingImmich) {
      return;
    }

    setState(() {
      _checkingImmich = true;
      _immichFailure = null;
      _immichReport = null;
    });

    try {
      final report = await _immichClient.check(
        ImmichConnectionSettings(
          serverUrl: _immichUrlController.text,
          apiKey: _immichApiKeyController.text,
        ),
      );
      if (!mounted) {
        return;
      }
      setState(() => _immichReport = report);
    } on ImmichConnectionException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _immichFailure = error);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(
        () => _immichFailure = ImmichConnectionException(
          ImmichConnectionIssue.unexpectedResponse,
          'Immich check failed: $error',
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _checkingImmich = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            SizedBox(
              width: 340,
              child: ColoredBox(
                color: colorScheme.surfaceContainerHighest,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _AppHeader(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                      child: SegmentedButton<_AppMode>(
                        segments: const [
                          ButtonSegment(
                            value: _AppMode.workflow,
                            icon: Icon(Icons.playlist_play),
                            label: Text('Workflow'),
                          ),
                          ButtonSegment(
                            value: _AppMode.immich,
                            icon: Icon(Icons.dns),
                            label: Text('Immich'),
                          ),
                          ButtonSegment(
                            value: _AppMode.help,
                            icon: Icon(Icons.help_outline),
                            label: Text('Help'),
                          ),
                          ButtonSegment(
                            value: _AppMode.memories,
                            icon: Icon(Icons.auto_awesome),
                            label: Text('Memories'),
                          ),
                        ],
                        selected: {_mode},
                        onSelectionChanged: _runningStepId == null
                            ? (selection) {
                                setState(() => _mode = selection.first);
                              }
                            : null,
                      ),
                    ),
                    _SettingsPanel(
                      hdPathController: _hdPathController,
                      reportDirController: _reportDirController,
                      enabled:
                          _runningStepId == null && _mode == _AppMode.workflow,
                    ),
                    Expanded(
                      child: switch (_mode) {
                        _AppMode.workflow => ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                          // +1: a leading guided-run control card ahead of
                          // the per-step list, kept inside this scrollable
                          // region so it can never overflow the sidebar.
                          itemCount: _steps.length + 1,
                          itemBuilder: (context, index) {
                            if (index == 0) {
                              return _GuidedRunPanel(
                                buttonLabel: _guidedRunButtonLabel,
                                statusMessage: _guidedRunStatusMessage,
                                enabled: _canRunNextGuidedSegment,
                                running: _guidedRunning,
                                onRun: _runNextGuidedSegment,
                              );
                            }
                            final step = _steps[index - 1];
                            return _StepTile(
                              step: step,
                              state: _states[step.id] ?? const StepRunState(),
                              selected: (index - 1) == _selectedIndex,
                              onTap: () =>
                                  setState(() => _selectedIndex = index - 1),
                            );
                          },
                        ),
                        _AppMode.immich => const _ImmichNav(),
                        _AppMode.help => const _HelpNav(),
                        _AppMode.memories => const _MemoriesNav(),
                      },
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: switch (_mode) {
                _AppMode.workflow => _StepDetail(
                  step: _selectedStep,
                  state: _states[_selectedStep.id] ?? const StepRunState(),
                  canRun:
                      _runningStepId == null &&
                      canRunStep(
                        step: _selectedStep,
                        states: _states,
                        duplicateThumbnailReviewAcknowledged:
                            _dedupReviewAcknowledged,
                      ),
                  running: _runningStepId == _selectedStep.id,
                  onRun: _runSelectedStep,
                  dryRunSucceeded: _selectedStep.requiresDryRunStepId == null
                      ? true
                      : _states[_selectedStep.requiresDryRunStepId]?.status ==
                          PipelineStepStatus.succeeded,
                  dedupReviewAcknowledged: _dedupReviewAcknowledged,
                  // Stdout-only for the same reason as `_openDedupReviewDialog`
                  // above — this feeds the pair-count preview through the
                  // same safety-relevant parser.
                  dedupDryRunLog: _states['delete-dry-run']?.stdoutLog,
                  dedupReviewedCount: _dedupReviewedIndices.length,
                  onOpenDedupReview: _selectedStep.requiresDuplicateThumbnailReview
                      ? _openDedupReviewDialog
                      : null,
                ),
                _AppMode.immich => _ImmichConnectionDetail(
                  serverUrlController: _immichUrlController,
                  apiKeyController: _immichApiKeyController,
                  checking: _checkingImmich,
                  report: _immichReport,
                  failure: _immichFailure,
                  phoneChecklists: _phoneChecklists,
                  loadingPhoneChecklists: _loadingPhoneChecklists,
                  checklistStoragePath: _checklistStore.filePath,
                  onAddPhoneChecklist: _addPhoneChecklist,
                  onRemovePhoneChecklist: _removePhoneChecklist,
                  onUpdatePhoneChecklist: _upsertPhoneChecklist,
                  onCheck: _checkImmichConnection,
                ),
                _AppMode.help => const _HelpDetail(),
                _AppMode.memories => _MemoryPreviewDetail(
                  immichClient: _immichClient,
                  serverUrlController: _immichUrlController,
                  apiKeyController: _immichApiKeyController,
                  initialDisplayState: widget.memoryPreviewState,
                  initialMessage: widget.memoryPreviewMessage,
                ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

enum _AppMode { workflow, immich, help, memories }

enum MemoryPreviewDisplayState { sampleReady, loading, empty, error }

class _ImmichNav extends StatelessWidget {
  const _ImmichNav();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      children: const [
        _NavHintTile(
          icon: Icons.dns,
          title: 'Connection check',
          subtitle: 'Ping the server and verify an API key.',
        ),
        _NavHintTile(
          icon: Icons.key,
          title: 'Credentials',
          subtitle: 'Kept in memory only for this app session.',
        ),
        _NavHintTile(
          icon: Icons.phone_android,
          title: 'Phone backup checklist',
          subtitle: 'Track each family phone locally.',
        ),
        _NavHintTile(
          icon: Icons.query_stats,
          title: 'Read-only status',
          subtitle: 'Server info and statistics only.',
        ),
      ],
    );
  }
}

class _NavHintTile extends StatelessWidget {
  const _NavHintTile({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        leading: Icon(icon, size: 20),
        title: Text(title),
        subtitle: Text(subtitle),
      ),
    );
  }
}

class _MemoriesNav extends StatelessWidget {
  const _MemoriesNav();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      children: const [
        _NavHintTile(
          icon: Icons.visibility,
          title: 'Preview only',
          subtitle: 'No Immich writes and no notifications.',
        ),
        _NavHintTile(
          icon: Icons.rule,
          title: 'Rules engine',
          subtitle: 'Prior year, album, and location scoring.',
        ),
        _NavHintTile(
          icon: Icons.filter_alt,
          title: 'Default exclusions',
          subtitle: 'Screenshots, receipts, blurry images, near-duplicates.',
        ),
      ],
    );
  }
}

class _ImmichConnectionDetail extends StatelessWidget {
  const _ImmichConnectionDetail({
    required this.serverUrlController,
    required this.apiKeyController,
    required this.checking,
    required this.report,
    required this.failure,
    required this.phoneChecklists,
    required this.loadingPhoneChecklists,
    required this.checklistStoragePath,
    required this.onAddPhoneChecklist,
    required this.onRemovePhoneChecklist,
    required this.onUpdatePhoneChecklist,
    required this.onCheck,
  });

  final TextEditingController serverUrlController;
  final TextEditingController apiKeyController;
  final bool checking;
  final ImmichConnectionReport? report;
  final ImmichConnectionException? failure;
  final List<ImmichPhoneBackupChecklist> phoneChecklists;
  final bool loadingPhoneChecklists;
  final String checklistStoragePath;
  final VoidCallback onAddPhoneChecklist;
  final void Function(String id) onRemovePhoneChecklist;
  final void Function(ImmichPhoneBackupChecklist updated)
  onUpdatePhoneChecklist;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: ListView(
        children: [
          Text('Immich Connection', style: textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text(
            'Check a private Immich server before future mobile backup and memory-curator work. The API key is kept in memory only and is not written to project files.',
          ),
          const SizedBox(height: 20),
          TextField(
            controller: serverUrlController,
            enabled: !checking,
            decoration: const InputDecoration(
              labelText: 'Immich server URL',
              helperText:
                  'Examples: http://localhost:2283 or http://SERVER_IP:2283',
              prefixIcon: Icon(Icons.dns),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: apiKeyController,
            enabled: !checking,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'API key',
              helperText:
                  'Needs server.about for server info; statistics may need server.statistics.',
              prefixIcon: Icon(Icons.key),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: checking ? null : onCheck,
              icon: Icon(checking ? Icons.hourglass_top : Icons.fact_check),
              label: Text(checking ? 'Checking' : 'Check Connection'),
            ),
          ),
          const SizedBox(height: 20),
          if (failure != null)
            _StatusPanel(
              icon: _failureIcon(failure!.issue),
              title: _failureTitle(failure!.issue),
              lines: [
                failure!.message,
                if (failure!.issue == ImmichConnectionIssue.serverUnavailable)
                  'Try the manual curl checks in the docs to confirm whether the server is reachable.',
                if (failure!.issue == ImmichConnectionIssue.invalidApiKey)
                  'Create a new key in the Immich web app and make sure it can read server.about.',
              ],
              isError: true,
            )
          else if (report != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _StatusPanel(
                  icon: report!.authenticated ? Icons.check_circle : Icons.info,
                  title: report!.statusLabel,
                  lines: [
                    'API base: ${report!.serverUrl}',
                    if (report!.licensed != null)
                      'Licensed: ${report!.licensed! ? 'yes' : 'no'}',
                    if (report!.message != null) report!.message!,
                  ],
                  isError: !report!.pingOk,
                ),
                const SizedBox(height: 12),
                _ImmichStatisticsPanel(report: report!),
              ],
            )
          else
            const _StatusPanel(
              icon: Icons.shield,
              title: 'Ready',
              lines: [
                'This runs public ping and authenticated read-only server checks.',
                'Use LAN or VPN access for a private Docker Immich server.',
              ],
            ),
          const SizedBox(height: 24),
          _PhoneBackupChecklistSection(
            checklists: phoneChecklists,
            loading: loadingPhoneChecklists,
            storagePath: checklistStoragePath,
            onAdd: onAddPhoneChecklist,
            onRemove: onRemovePhoneChecklist,
            onUpdate: onUpdatePhoneChecklist,
          ),
        ],
      ),
    );
  }
}

class _ImmichStatisticsPanel extends StatelessWidget {
  const _ImmichStatisticsPanel({required this.report});

  final ImmichConnectionReport report;

  @override
  Widget build(BuildContext context) {
    final lines = [
      'Server version: ${report.version ?? 'unavailable'}',
      'Photos: ${_formatNullableCount(report.photos)}',
      'Videos: ${_formatNullableCount(report.videos)}',
      'Storage usage: ${report.usageBytes == null ? 'unavailable' : _formatBytes(report.usageBytes!)}',
    ];
    return _StatusPanel(
      icon: Icons.query_stats,
      title: 'Immich Server Statistics',
      lines: lines,
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({
    required this.icon,
    required this.title,
    required this.lines,
    this.isError = false,
  });

  final IconData icon;
  final String title;
  final List<String> lines;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final foreground = isError ? colorScheme.error : colorScheme.onSurface;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(
          color: isError ? colorScheme.error : colorScheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: foreground),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(
                      context,
                    ).textTheme.titleMedium?.copyWith(color: foreground),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(line),
              ),
          ],
        ),
      ),
    );
  }
}

class _PhoneBackupChecklistSection extends StatelessWidget {
  const _PhoneBackupChecklistSection({
    required this.checklists,
    required this.loading,
    required this.storagePath,
    required this.onAdd,
    required this.onRemove,
    required this.onUpdate,
  });

  final List<ImmichPhoneBackupChecklist> checklists;
  final bool loading;
  final String storagePath;
  final VoidCallback onAdd;
  final void Function(String id) onRemove;
  final void Function(ImmichPhoneBackupChecklist updated) onUpdate;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final completedChecklists = checklists.isEmpty
        ? 0
        : checklists
              .map(checklistProgressCompleteCount)
              .fold<int>(0, (total, count) => total + count);
    final completedPhones = checklists
        .where(
          (checklist) =>
              checklistProgressCompleteCount(checklist) ==
              checklistProgressTotalCount,
        )
        .length;
    final totalChecklistsProgress =
        checklists.length * checklistProgressTotalCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.phone_android,
              size: 20,
              color: textTheme.bodyMedium?.color,
            ),
            const SizedBox(width: 8),
            Text('Phone Backup Checklist', style: textTheme.titleMedium),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Track setup for each family phone. The checklist starts in memory, then saves to a local JSON file when you edit it.',
        ),
        const SizedBox(height: 8),
        Text('Stored locally at: $storagePath', style: textTheme.bodySmall),
        if (checklists.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            'Overall progress: $completedChecklists/$totalChecklistsProgress complete across ${checklists.length} phone${checklists.length == 1 ? '' : 's'}',
            style: textTheme.bodySmall,
          ),
          Text(
            'Completed phones: $completedPhones/${checklists.length}',
            style: textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Add phone'),
          ),
        ),
        if (loading) ...[
          const SizedBox(height: 12),
          Text('Loading saved checklist...', style: textTheme.bodySmall),
        ],
        const SizedBox(height: 12),
        for (final checklist in checklists)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _PhoneBackupChecklistCard(
              key: ValueKey(checklist.id),
              checklist: checklist,
              canRemove: checklists.length > 1,
              onRemove: () => onRemove(checklist.id),
              onChanged: onUpdate,
            ),
          ),
      ],
    );
  }
}

class _PhoneBackupChecklistCard extends StatefulWidget {
  const _PhoneBackupChecklistCard({
    super.key,
    required this.checklist,
    required this.canRemove,
    required this.onRemove,
    required this.onChanged,
  });

  final ImmichPhoneBackupChecklist checklist;
  final bool canRemove;
  final VoidCallback onRemove;
  final void Function(ImmichPhoneBackupChecklist updated) onChanged;

  @override
  State<_PhoneBackupChecklistCard> createState() =>
      _PhoneBackupChecklistCardState();
}

class _PhoneBackupChecklistCardState extends State<_PhoneBackupChecklistCard> {
  late final TextEditingController _phoneNameController;
  late final TextEditingController _notesController;

  @override
  void initState() {
    super.initState();
    _phoneNameController = TextEditingController(
      text: widget.checklist.phoneName,
    );
    _notesController = TextEditingController(text: widget.checklist.notes);
  }

  @override
  void didUpdateWidget(covariant _PhoneBackupChecklistCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.checklist.phoneName != widget.checklist.phoneName &&
        _phoneNameController.text != widget.checklist.phoneName) {
      _phoneNameController.text = widget.checklist.phoneName;
    }
    if (oldWidget.checklist.notes != widget.checklist.notes &&
        _notesController.text != widget.checklist.notes) {
      _notesController.text = widget.checklist.notes;
    }
  }

  @override
  void dispose() {
    _phoneNameController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  void _update({
    String? phoneName,
    bool? appInstalled,
    bool? serverLoginConfirmed,
    bool? albumsSelected,
    bool? backupEnabled,
    bool? firstUploadObserved,
    bool? backgroundPermissionsReviewed,
    String? notes,
  }) {
    widget.onChanged(
      widget.checklist.copyWith(
        phoneName: phoneName ?? widget.checklist.phoneName,
        notes: notes ?? widget.checklist.notes,
        appInstalled: appInstalled ?? widget.checklist.appInstalled,
        serverLoginConfirmed:
            serverLoginConfirmed ?? widget.checklist.serverLoginConfirmed,
        albumsSelected: albumsSelected ?? widget.checklist.albumsSelected,
        backupEnabled: backupEnabled ?? widget.checklist.backupEnabled,
        firstUploadObserved:
            firstUploadObserved ?? widget.checklist.firstUploadObserved,
        backgroundPermissionsReviewed:
            backgroundPermissionsReviewed ??
            widget.checklist.backgroundPermissionsReviewed,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _phoneNameController,
                    decoration: const InputDecoration(
                      labelText: 'Phone name',
                      hintText: 'e.g. Alex iPhone',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) => _update(phoneName: value),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  tooltip: widget.canRemove
                      ? 'Remove phone'
                      : 'Keep at least one phone',
                  onPressed: widget.canRemove ? widget.onRemove : null,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Progress: ${checklistProgressCompleteCount(widget.checklist)}/$checklistProgressTotalCount complete',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              value: widget.checklist.appInstalled,
              onChanged: (value) => _update(appInstalled: value ?? false),
              title: const Text('App installed'),
              contentPadding: EdgeInsets.zero,
            ),
            CheckboxListTile(
              value: widget.checklist.serverLoginConfirmed,
              onChanged: (value) =>
                  _update(serverLoginConfirmed: value ?? false),
              title: const Text('Server login confirmed'),
              contentPadding: EdgeInsets.zero,
            ),
            CheckboxListTile(
              value: widget.checklist.albumsSelected,
              onChanged: (value) => _update(albumsSelected: value ?? false),
              title: const Text('Albums selected'),
              contentPadding: EdgeInsets.zero,
            ),
            CheckboxListTile(
              value: widget.checklist.backupEnabled,
              onChanged: (value) => _update(backupEnabled: value ?? false),
              title: const Text('Backup enabled'),
              contentPadding: EdgeInsets.zero,
            ),
            CheckboxListTile(
              value: widget.checklist.firstUploadObserved,
              onChanged: (value) =>
                  _update(firstUploadObserved: value ?? false),
              title: const Text('First upload observed'),
              contentPadding: EdgeInsets.zero,
            ),
            CheckboxListTile(
              value: widget.checklist.backgroundPermissionsReviewed,
              onChanged: (value) =>
                  _update(backgroundPermissionsReviewed: value ?? false),
              title: const Text('Background permissions reviewed'),
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _notesController,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Notes',
                hintText: 'Optional reminders, issues, or follow-up steps',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => _update(notes: value),
            ),
          ],
        ),
      ),
    );
  }
}

class _HelpNav extends StatelessWidget {
  const _HelpNav();

  @override
  Widget build(BuildContext context) {
    final entries = const [
      (Icons.dns, 'Private Docker server'),
      (Icons.phone_android, 'Phone backup'),
      (Icons.photo_library, 'External libraries'),
      (Icons.auto_awesome, 'Memories'),
      (Icons.notifications_active, 'Notifications'),
      (Icons.backup, 'Backup safety'),
    ];
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
            leading: Icon(entry.$1, size: 20),
            title: Text(entry.$2),
          ),
        );
      },
    );
  }
}

class _HelpDetail extends StatelessWidget {
  const _HelpDetail();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: ListView(
        children: [
          Text('Immich Help', style: textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text(
            'Use this checklist when connecting phones, scanning the cleaned library, and planning private memories.',
          ),
          const SizedBox(height: 20),
          const _HelpSection(
            icon: Icons.dns,
            title: 'Private Docker Server',
            bullets: [
              'Use a private URL your phone can reach, such as http://SERVER_IP:2283.',
              'LAN or VPN access is the default assumption; public exposure is not required.',
              'Create API keys only for future app integrations and never commit them.',
            ],
          ),
          const _HelpSection(
            icon: Icons.phone_android,
            title: 'Phone Backup',
            bullets: [
              'Install the Immich mobile app and log in to your private server.',
              'Open the cloud backup screen, select albums, then enable backup.',
              'Optionally enable album synchronization to mirror phone albums on the server.',
              'Keep the app open for the first large upload and review server job queues.',
            ],
          ),
          const _HelpSection(
            icon: Icons.settings_cell,
            title: 'Mobile Background Rules',
            bullets: [
              'Android may require disabling battery optimization for Immich.',
              'iPhone requires Background App Refresh; iOS still decides when background tasks run.',
              'Wi-Fi-only backup is the safer default unless mobile data usage is acceptable.',
            ],
          ),
          const _HelpSection(
            icon: Icons.build_circle,
            title: 'Backup Troubleshooting',
            bullets: [
              'If uploads stall, keep the app foregrounded and confirm the first upload starts before relying on background sync.',
              'On Android, disable battery optimization and review manufacturer-specific background restrictions for Immich.',
              'On iPhone, avoid Low Power Mode and keep Background App Refresh enabled for Immich.',
              'If the server URL is wrong, make sure it reaches your private LAN, VPN, or localhost Immich server on port 2283.',
            ],
          ),
          const _HelpSection(
            icon: Icons.photo_library,
            title: 'External Library',
            bullets: [
              'Mount the cleaned project library into Immich as /library, read-only.',
              'Do not use /data as an external library path; it is Immich upload storage.',
              'Rescan the external library after files change outside Immich.',
            ],
          ),
          const _HelpSection(
            icon: Icons.collections,
            title: 'Takeout Duplicates',
            bullets: [
              'Google Takeout can create both canonical year folders and localized duplicates such as Fotos de 2024.',
              'Immich scans each filesystem path as a separate asset, so both folders can appear in the timeline.',
              'Use the dry-run duplicate cleanup step to review only the localized Fotos de YYYY copies before any move.',
            ],
          ),
          const _HelpSection(
            icon: Icons.auto_awesome,
            title: 'Memories Direction',
            bullets: [
              'The Memory Curator Preview can load live read-only assets from Immich on demand.',
              'Start with explainable memory scoring before training a personal model.',
              'Preview memory candidates before creating anything in Immich.',
            ],
          ),
          const _HelpSection(
            icon: Icons.notifications_active,
            title: 'Notifications',
            bullets: [
              'Use optional providers such as ntfy, Gotify, Pushover, Home Assistant, or desktop notifications.',
              'Send notifications only after memory candidates are approved or created.',
              'Use VPN or private-network delivery when possible.',
            ],
          ),
          const _HelpSection(
            icon: Icons.backup,
            title: 'Backup Safety',
            bullets: [
              'Immich database backups do not include photos and videos.',
              'Back up both the database and the original media files.',
              'Do not manually edit Immich-managed asset folders.',
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Full help library: docs/IMMICH_HELP_LIBRARY.md\nMajor plan: docs/MEMORIES_AND_MOBILE_PLAN.md',
            style: textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _MemoryPreviewDetail extends StatefulWidget {
  const _MemoryPreviewDetail({
    required this.immichClient,
    required this.serverUrlController,
    required this.apiKeyController,
    required this.initialDisplayState,
    this.initialMessage,
  });

  final ImmichApiClient immichClient;
  final TextEditingController serverUrlController;
  final TextEditingController apiKeyController;
  final MemoryPreviewDisplayState initialDisplayState;
  final String? initialMessage;

  @override
  State<_MemoryPreviewDetail> createState() => _MemoryPreviewDetailState();
}

class _MemoryPreviewDetailState extends State<_MemoryPreviewDetail> {
  static final DateTime _referenceDate = DateTime(2026, 5, 29);

  late MemoryPreviewDisplayState _displayState;
  late String _previewSourceLabel;
  String? _message;
  late List<MemoryPreviewAsset> _assets;
  final List<MemoryWriteDraft> _pendingDrafts = [];
  final List<MemoryFeedbackEvent> _feedbackEvents = [];
  bool _collectingFeedback = false;
  bool _loadingLiveAssets = false;

  @override
  void initState() {
    super.initState();
    _displayState = widget.initialDisplayState;
    _previewSourceLabel = 'sample data';
    _message = widget.initialMessage?.trim();
    _assets = widget.initialDisplayState == MemoryPreviewDisplayState.sampleReady
        ? buildMemoryPreviewSampleAssets()
        : const [];
  }

  Future<void> _loadLivePreviewAssets() async {
    if (_loadingLiveAssets) {
      return;
    }

    setState(() {
      _loadingLiveAssets = true;
      _displayState = MemoryPreviewDisplayState.loading;
      _message = null;
    });

    try {
      final assets = await widget.immichClient.loadMemoryPreviewAssets(
        ImmichConnectionSettings(
          serverUrl: widget.serverUrlController.text,
          apiKey: widget.apiKeyController.text,
        ),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingLiveAssets = false;
        _previewSourceLabel = 'live Immich assets';
        _assets = assets;
        if (assets.isEmpty) {
          _displayState = MemoryPreviewDisplayState.empty;
          _message = 'The read-only adapter returned no assets for the preview.';
        } else {
          _displayState = MemoryPreviewDisplayState.sampleReady;
          _message = 'Loaded ${assets.length} live assets from Immich.';
        }
      });
    } on ImmichConnectionException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingLiveAssets = false;
        _displayState = MemoryPreviewDisplayState.error;
        _message = error.message;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadingLiveAssets = false;
        _displayState = MemoryPreviewDisplayState.error;
        _message = 'Immich preview load failed: $error';
      });
    }
  }

  Future<void> _prepareMemoryWriteDraft(
    MemoryPreviewCandidate candidate,
  ) async {
    final draft = await showDialog<MemoryWriteDraft?>(
      context: context,
      builder: (context) =>
          _MemoryWriteApprovalDialog(candidate: candidate),
    );
    if (draft == null || !mounted) {
      return;
    }

    setState(() {
      _pendingDrafts.insert(0, draft);
    });
  }

  void _toggleFeedbackCollection(bool enabled) {
    setState(() {
      _collectingFeedback = enabled;
    });
  }

  void _recordFeedback(
    MemoryPreviewCandidate candidate,
    MemoryFeedbackEventType type,
  ) {
    if (!_collectingFeedback) {
      return;
    }

    setState(() {
      _feedbackEvents.insert(
        0,
        MemoryFeedbackEvent(
          candidateTitle: candidate.title,
          assetIds: List.unmodifiable(candidate.assetIds),
          type: type,
          recordedAt: DateTime.now(),
        ),
      );
    });
  }

  List<MemoryPreviewCandidate> _rankCandidatesWithFeedback(
    List<MemoryPreviewCandidate> candidates,
  ) {
    final rankedCandidates = [...candidates];
    rankedCandidates.sort((left, right) {
      final leftScore = left.score +
          memoryFeedbackScoreAdjustment(
            candidate: left,
            events: _feedbackEvents,
          );
      final rightScore = right.score +
          memoryFeedbackScoreAdjustment(
            candidate: right,
            events: _feedbackEvents,
          );
      final scoreOrder = rightScore.compareTo(leftScore);
      if (scoreOrder != 0) {
        return scoreOrder;
      }
      return left.title.compareTo(right.title);
    });
    return rankedCandidates;
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final preview = _displayState == MemoryPreviewDisplayState.loading
        ? null
        : buildMemoryPreviewCandidates(
            referenceDate: _referenceDate,
            assets: _assets,
          );
    final rankedCandidates = preview == null
        ? const <MemoryPreviewCandidate>[]
        : _rankCandidatesWithFeedback(preview.candidates);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: ListView(
        children: [
          Text('Memory Curator Preview', style: textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text('Preview-only mode.'),
          const SizedBox(height: 4),
          const Text('This does not write to Immich.'),
          const SizedBox(height: 12),
          Text(
            'Preview source: $_previewSourceLabel',
            style: textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: _loadingLiveAssets ? null : _loadLivePreviewAssets,
            icon: Icon(
              _loadingLiveAssets ? Icons.hourglass_bottom : Icons.cloud_download,
            ),
            label: Text(
              _previewSourceLabel == 'sample data'
                  ? 'Load from Immich'
                  : 'Reload from Immich',
            ),
          ),
          const SizedBox(height: 8),
          _StatusPanel(
            icon: switch (_displayState) {
              MemoryPreviewDisplayState.sampleReady => Icons.visibility,
              MemoryPreviewDisplayState.loading => Icons.hourglass_bottom,
              MemoryPreviewDisplayState.empty => Icons.inbox,
              MemoryPreviewDisplayState.error => Icons.error_outline,
            },
            title: 'Preview status',
            lines: [
              switch (_displayState) {
                MemoryPreviewDisplayState.sampleReady =>
                  'Rules-based scoring only.',
                MemoryPreviewDisplayState.loading =>
                  'Loading real Immich assets...',
                MemoryPreviewDisplayState.empty =>
                  'No preview assets available yet.',
                MemoryPreviewDisplayState.error =>
                  'Unable to load preview assets.',
              },
              if (_displayState == MemoryPreviewDisplayState.sampleReady)
                'Reference date: 2026-05-29',
              if (_displayState == MemoryPreviewDisplayState.sampleReady)
                '${preview!.candidates.length} candidates, ${preview.exclusions.length} excluded assets in $_previewSourceLabel.',
              if (_message != null && _message!.trim().isNotEmpty)
                _message!.trim(),
            ],
          ),
          const SizedBox(height: 12),
          SwitchListTile.adaptive(
            value: _collectingFeedback,
            onChanged: _toggleFeedbackCollection,
            title: const Text('Collect local ranking feedback'),
            subtitle: const Text(
              'Opt-in only. Feedback stays on this device for now.',
            ),
          ),
          const SizedBox(height: 8),
          _RankingFeedbackPanel(
            enabled: _collectingFeedback,
            events: _feedbackEvents,
          ),
          if (_displayState == MemoryPreviewDisplayState.sampleReady &&
              preview != null &&
              preview.candidates.isNotEmpty) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => _prepareMemoryWriteDraft(preview.candidates.first),
              icon: const Icon(Icons.edit_note),
              label: const Text('Prepare top memory write draft'),
            ),
          ],
          const SizedBox(height: 16),
          if (_displayState == MemoryPreviewDisplayState.loading)
            const _MemoryPreviewPlaceholder(
              icon: Icons.hourglass_bottom,
              title: 'Loading preview',
              subtitle:
                  'Fetching read-only metadata from Immich before scoring locally.',
            )
          else if (_displayState == MemoryPreviewDisplayState.empty)
            const _MemoryPreviewPlaceholder(
              icon: Icons.inbox,
              title: 'No preview candidates yet',
              subtitle:
                  'Connect a private Immich server with readable assets to populate this preview.',
            )
          else if (_displayState == MemoryPreviewDisplayState.error)
            const _MemoryPreviewPlaceholder(
              icon: Icons.error_outline,
              title: 'Preview unavailable',
              subtitle:
                  'Check the read-only adapter contract and retry the connection.',
            )
          else ...[
            if (_pendingDrafts.isNotEmpty) ...[
              _MemoryWriteDraftPanel(drafts: _pendingDrafts),
              const SizedBox(height: 12),
            ],
            for (final candidate in rankedCandidates)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _MemoryPreviewCandidateCard(
                  candidate: candidate,
                  feedbackEnabled: _collectingFeedback,
                  feedbackAdjustment: memoryFeedbackScoreAdjustment(
                    candidate: candidate,
                    events: _feedbackEvents,
                  ),
                  onFeedbackSelected: (type) => _recordFeedback(candidate, type),
                  onPrepareWrite: () => _prepareMemoryWriteDraft(candidate),
                ),
              ),
            _MemoryPreviewExclusionPanel(exclusions: preview!.exclusions),
          ],
        ],
      ),
    );
  }
}

class _MemoryPreviewPlaceholder extends StatelessWidget {
  const _MemoryPreviewPlaceholder({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return _StatusPanel(
      icon: icon,
      title: title,
      lines: [subtitle],
    );
  }
}

class _MemoryPreviewCandidateCard extends StatelessWidget {
  const _MemoryPreviewCandidateCard({
    required this.candidate,
    required this.feedbackEnabled,
    required this.feedbackAdjustment,
    required this.onFeedbackSelected,
    required this.onPrepareWrite,
  });

  final MemoryPreviewCandidate candidate;
  final bool feedbackEnabled;
  final int feedbackAdjustment;
  final ValueChanged<MemoryFeedbackEventType> onFeedbackSelected;
  final VoidCallback onPrepareWrite;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    candidate.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text('Score ${candidate.score + feedbackAdjustment}'),
              ],
            ),
            if (feedbackAdjustment != 0) ...[
              const SizedBox(height: 4),
              Text(
                'Local feedback adjustment: ${feedbackAdjustment > 0 ? '+' : ''}$feedbackAdjustment',
              ),
            ],
            const SizedBox(height: 8),
            Text('Assets: ${candidate.assetIds.join(', ')}'),
            const SizedBox(height: 8),
            for (final reason in candidate.reasons)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('- $reason'),
              ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: onPrepareWrite,
                icon: const Icon(Icons.edit_note),
                label: const Text('Prepare memory write draft'),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final type in MemoryFeedbackEventType.values)
                  OutlinedButton(
                    key: ValueKey<String>(
                      'feedback-${candidate.title}-${type.name}',
                    ),
                    onPressed: feedbackEnabled
                        ? () => onFeedbackSelected(type)
                        : null,
                    child: Text(type.label),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RankingFeedbackPanel extends StatelessWidget {
  const _RankingFeedbackPanel({
    required this.enabled,
    required this.events,
  });

  final bool enabled;
  final List<MemoryFeedbackEvent> events;

  @override
  Widget build(BuildContext context) {
    return _StatusPanel(
      icon: Icons.rate_review_outlined,
      title: 'Local ranking feedback',
      lines: [
        if (enabled)
          'Feedback collection is on. The app stores events locally only.'
        else
          'Feedback collection is off until you opt in.',
        if (events.isEmpty)
          'No feedback events recorded yet.'
        else
          for (final event in events)
            '${event.type.label}: ${event.candidateTitle}',
      ],
    );
  }
}

class _MemoryWriteDraftPanel extends StatelessWidget {
  const _MemoryWriteDraftPanel({required this.drafts});

  final List<MemoryWriteDraft> drafts;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: _StatusPanel(
        icon: Icons.pending_actions,
        title: 'Pending memory approvals',
        lines: [
          if (drafts.isEmpty)
            'No memory write drafts have been approved yet.'
          else
            '${drafts.length} local draft${drafts.length == 1 ? '' : 's'} waiting for the future remote write step.',
          if (drafts.isNotEmpty)
            for (final draft in drafts) '• ${draft.candidateTitle} (${draft.state.name})',
        ],
      ),
    );
  }
}

class _MemoryWriteApprovalDialog extends StatefulWidget {
  const _MemoryWriteApprovalDialog({required this.candidate});

  final MemoryPreviewCandidate candidate;

  @override
  State<_MemoryWriteApprovalDialog> createState() =>
      _MemoryWriteApprovalDialogState();
}

class _MemoryWriteApprovalDialogState extends State<_MemoryWriteApprovalDialog> {
  final TextEditingController _approvalController = TextEditingController();
  String? _errorText;

  @override
  void dispose() {
    _approvalController.dispose();
    super.dispose();
  }

  void _approve() {
    final typed = _approvalController.text.trim();
    if (typed != memoryWriteApprovalPhrase) {
      setState(() {
        _errorText = 'Type $memoryWriteApprovalPhrase to continue.';
      });
      return;
    }

    Navigator.of(context).pop(
      createPendingMemoryWriteDraft(
        candidate: widget.candidate,
        createdAt: DateTime.now(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Approve memory write draft'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This creates a local pending record only. The remote write step is not wired yet.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Text('Candidate: ${widget.candidate.title}'),
            Text('Assets: ${widget.candidate.assetIds.join(', ')}'),
            const SizedBox(height: 12),
            TextField(
              controller: _approvalController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Type approval phrase',
                hintText: memoryWriteApprovalPhrase,
                errorText: _errorText,
              ),
              onSubmitted: (_) => _approve(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _approve,
          child: const Text('Approve'),
        ),
      ],
    );
  }
}

class _MemoryPreviewExclusionPanel extends StatelessWidget {
  const _MemoryPreviewExclusionPanel({required this.exclusions});

  final List<MemoryPreviewExclusion> exclusions;

  @override
  Widget build(BuildContext context) {
    return _StatusPanel(
      icon: Icons.filter_alt,
      title: 'Excluded assets',
      lines: [
        if (exclusions.isEmpty) 'No assets excluded in this preview.',
        for (final exclusion in exclusions)
          '${exclusion.assetId}: ${_exclusionLabel(exclusion.reason)}',
      ],
    );
  }
}

class _HelpSection extends StatelessWidget {
  const _HelpSection({
    required this.icon,
    required this.title,
    required this.bullets,
  });

  final IconData icon;
  final String title;
  final List<String> bullets;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Text(title, style: textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 6),
          for (final bullet in bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: 4, left: 28),
              child: Text('- $bullet'),
            ),
        ],
      ),
    );
  }
}

class _AppHeader extends StatelessWidget {
  const _AppHeader();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Media Pipeline', style: textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Desktop controller for the existing safe cleanup scripts.',
            style: textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _GuidedRunPanel extends StatelessWidget {
  const _GuidedRunPanel({
    required this.buttonLabel,
    required this.statusMessage,
    required this.enabled,
    required this.running,
    required this.onRun,
  });

  final String buttonLabel;
  final String statusMessage;
  final bool enabled;
  final bool running;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.playlist_add_check, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('Guided Run', style: textTheme.titleSmall),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(statusMessage, style: textTheme.bodySmall),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: enabled ? onRun : null,
                icon: Icon(running ? Icons.hourglass_top : Icons.fast_forward),
                label: Text(running ? 'Running…' : buttonLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsPanel extends StatelessWidget {
  const _SettingsPanel({
    required this.hdPathController,
    required this.reportDirController,
    required this.enabled,
  });

  final TextEditingController hdPathController;
  final TextEditingController reportDirController;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          TextField(
            controller: hdPathController,
            enabled: enabled,
            decoration: const InputDecoration(
              labelText: 'HD_PATH',
              prefixIcon: Icon(Icons.storage),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: reportDirController,
            enabled: enabled,
            decoration: const InputDecoration(
              labelText: 'REPORT_DIR',
              prefixIcon: Icon(Icons.folder_copy),
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({
    required this.step,
    required this.state,
    required this.selected,
    required this.onTap,
  });

  final PipelineStep step;
  final StepRunState state;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: selected ? colorScheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: ListTile(
          selected: selected,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          leading: Icon(_statusIcon(state.status), size: 20),
          title: Text(step.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            _riskLabel(step),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _StepDetail extends StatelessWidget {
  const _StepDetail({
    required this.step,
    required this.state,
    required this.canRun,
    required this.running,
    required this.onRun,
    this.dryRunSucceeded = true,
    this.dedupReviewAcknowledged = false,
    this.dedupDryRunLog,
    this.dedupReviewedCount = 0,
    this.onOpenDedupReview,
  });

  final PipelineStep step;
  final StepRunState state;
  final bool canRun;
  final bool running;
  final VoidCallback onRun;

  /// Whether the dry-run step this step depends on (per
  /// `requiresDryRunStepId`) has succeeded. Defaults to `true` for steps
  /// with no dry-run dependency.
  final bool dryRunSucceeded;

  /// Whether the thumbnail-diff duplicate review (#49) has been shown for
  /// the current dry-run output. Only meaningful when
  /// `step.requiresDuplicateThumbnailReview` is true.
  final bool dedupReviewAcknowledged;

  /// The "delete-dry-run" step's captured stdout, used to show a pair
  /// count / preview summary without opening the review dialog. Only read
  /// when `step.requiresDuplicateThumbnailReview` is true.
  final String? dedupDryRunLog;

  /// Count of distinct pairs the human has actually had displayed across
  /// every sample batch reviewed so far for the current dry-run output
  /// (#53). Only meaningful when `step.requiresDuplicateThumbnailReview`
  /// is true; purely informational, never a gate input.
  final int dedupReviewedCount;

  /// Opens the thumbnail-diff review dialog. Non-null only when
  /// `step.requiresDuplicateThumbnailReview` is true.
  final VoidCallback? onOpenDedupReview;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final blockedReason = _blockedReason(
      step,
      canRun: canRun,
      dryRunSucceeded: dryRunSucceeded,
      dedupReviewAcknowledged: dedupReviewAcknowledged,
    );
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(step.title, style: textTheme.headlineSmall),
                    const SizedBox(height: 8),
                    Text(step.description),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _InfoChip(
                          icon: Icons.terminal,
                          label: _commandLabel(step),
                        ),
                        _InfoChip(icon: Icons.shield, label: _riskLabel(step)),
                        if (step.requiredTools.isNotEmpty)
                          _InfoChip(
                            icon: Icons.build,
                            label: step.requiredTools.join(', '),
                          ),
                        if (step.linuxOnly)
                          const _InfoChip(
                            icon: Icons.desktop_windows,
                            label: 'Linux only',
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              FilledButton.icon(
                onPressed: canRun ? onRun : null,
                icon: Icon(running ? Icons.hourglass_top : Icons.play_arrow),
                label: Text(running ? 'Running' : _buttonLabel(step)),
              ),
            ],
          ),
          if (step.requiresDuplicateThumbnailReview) ...[
            const SizedBox(height: 16),
            _DedupReviewPanel(
              dryRunSucceeded: dryRunSucceeded,
              acknowledged: dedupReviewAcknowledged,
              pairCount: parseDuplicateDryRunOutput(
                dedupDryRunLog ?? '',
              ).pairs.length,
              reviewedCount: dedupReviewedCount,
              onOpenReview: onOpenDedupReview,
            ),
          ],
          if (blockedReason != null) ...[
            const SizedBox(height: 12),
            Text(
              blockedReason,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 20),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xff101418),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  state.log.isEmpty ? 'No output yet.' : state.log,
                  style: const TextStyle(
                    color: Color(0xffd6dde3),
                    fontFamily: 'monospace',
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(icon, size: 16),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

IconData _statusIcon(PipelineStepStatus status) {
  return switch (status) {
    PipelineStepStatus.idle => Icons.radio_button_unchecked,
    PipelineStepStatus.running => Icons.sync,
    PipelineStepStatus.succeeded => Icons.check_circle,
    PipelineStepStatus.failed => Icons.error,
    PipelineStepStatus.blocked => Icons.block,
  };
}

String _riskLabel(PipelineStep step) {
  return switch (step.risk) {
    PipelineRisk.safe => 'Safe',
    PipelineRisk.reviewRequired => 'Review output',
    PipelineRisk.confirmRequired => 'Explicit confirm',
  };
}

String _buttonLabel(PipelineStep step) {
  return switch (step.risk) {
    PipelineRisk.confirmRequired => 'Run Confirm',
    _ => 'Run Step',
  };
}

String _commandLabel(PipelineStep step) {
  final command = step.command;
  if (command == null) {
    // Dart-native step (see `PipelineStep.dartAction`, issue #76 plumbing)
    // — no subprocess command line to show. No real step uses this path
    // yet, but the UI must not crash once one does.
    return '(runs in-process)';
  }
  return ([command.executable, ...command.arguments]).join(' ');
}

String _newChecklistId() {
  return DateTime.now().microsecondsSinceEpoch.toString();
}

String? _blockedReason(
  PipelineStep step, {
  required bool canRun,
  bool dryRunSucceeded = true,
  bool dedupReviewAcknowledged = false,
}) {
  if (step.linuxOnly && !Platform.isLinux) {
    return 'This step is enabled only on Linux or ChromeOS Linux in v1.';
  }
  if (canRun || step.requiresDryRunStepId == null) {
    return null;
  }
  if (!dryRunSucceeded) {
    return 'This confirm step is locked until its dry-run step succeeds in this app session.';
  }
  if (step.requiresDuplicateThumbnailReview && !dedupReviewAcknowledged) {
    return 'This confirm step is locked until you review the duplicate-thumbnail '
        'comparison below at least once.';
  }
  return null;
}

String _formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  final decimals = value >= 10 || unitIndex == 0 ? 0 : 1;
  return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
}

String _formatNullableCount(int? value) => value?.toString() ?? 'unavailable';

String _exclusionLabel(MemoryPreviewExclusionReason reason) {
  return switch (reason) {
    MemoryPreviewExclusionReason.screenshot => 'screenshot',
    MemoryPreviewExclusionReason.receipt => 'receipt',
    MemoryPreviewExclusionReason.blurry => 'blurry image',
    MemoryPreviewExclusionReason.nearDuplicate => 'near-duplicate',
  };
}

IconData _failureIcon(ImmichConnectionIssue issue) {
  return switch (issue) {
    ImmichConnectionIssue.invalidServerUrl => Icons.link_off,
    ImmichConnectionIssue.serverUnavailable => Icons.cloud_off,
    ImmichConnectionIssue.invalidApiKey => Icons.key_off,
    ImmichConnectionIssue.missingPermission => Icons.no_accounts,
    ImmichConnectionIssue.unexpectedResponse => Icons.warning_amber,
  };
}

String _failureTitle(ImmichConnectionIssue issue) {
  return switch (issue) {
    ImmichConnectionIssue.invalidServerUrl => 'Check the server URL',
    ImmichConnectionIssue.serverUnavailable => 'Server unreachable',
    ImmichConnectionIssue.invalidApiKey => 'API key rejected',
    ImmichConnectionIssue.missingPermission => 'Missing permission',
    ImmichConnectionIssue.unexpectedResponse => 'Unexpected response',
  };
}

/// Inline summary + entry point for the thumbnail-diff duplicate review
/// (#49), shown on the "delete-confirm" step's detail panel — directly
/// above the "Run Confirm" button, so it's the last thing seen before the
/// confirm action, not something a skim past a dialog header could miss.
///
/// Per #53 (follow-up from Astrid's #52 review): once reviewed, this panel
/// always states the reviewed-vs-total pair count as an explicit
/// percentage right here, and a coverage chip color-codes how much of the
/// duplicate set that percentage represents. This is framing only — it
/// never changes what unlocks "Run Confirm"; the gate mechanics in
/// `canRunStep()` are unchanged (still just "was the dialog opened").
class _DedupReviewPanel extends StatelessWidget {
  const _DedupReviewPanel({
    required this.dryRunSucceeded,
    required this.acknowledged,
    required this.pairCount,
    required this.reviewedCount,
    required this.onOpenReview,
  });

  final bool dryRunSucceeded;
  final bool acknowledged;
  final int pairCount;

  /// Distinct pairs actually displayed across every sample batch reviewed
  /// so far for the current dry-run output.
  final int reviewedCount;
  final VoidCallback? onOpenReview;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final coveragePercent = duplicateReviewCoveragePercent(
      reviewedCount,
      pairCount,
    );

    final String message;
    if (!dryRunSucceeded) {
      message =
          'Run "Review Duplicate Move Plan" successfully first to unlock the '
          'thumbnail review.';
    } else if (acknowledged) {
      message =
          'Re-run the dry-run step if the duplicate set changes; re-review '
          'before confirming again.';
    } else {
      message =
          'Before you can confirm, review side-by-side thumbnails of every '
          'proposed keep/trash pair ($pairCount found, or a sample for '
          'large runs) so you can trust the move plan without reading raw '
          'Czkawka text output.';
    }

    // Coverage-severity color: this is purely a visual trust signal (never
    // a gate) so a human weighing "should I look at more before I confirm"
    // has an immediate, hard-to-miss read at a glance.
    final Color coverageColor;
    if (!acknowledged) {
      coverageColor = colorScheme.error;
    } else if (coveragePercent >= 100) {
      coverageColor = colorScheme.primary;
    } else if (coveragePercent >= 50) {
      coverageColor = Colors.orange;
    } else {
      coverageColor = colorScheme.error;
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(
          color: acknowledged ? colorScheme.outlineVariant : colorScheme.error,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  acknowledged ? Icons.check_circle : Icons.image_search,
                  size: 18,
                  color: acknowledged ? colorScheme.primary : colorScheme.error,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    acknowledged
                        ? 'Duplicate thumbnail review: reviewed'
                        : 'Duplicate thumbnail review required',
                    style: textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            if (acknowledged) ...[
              const SizedBox(height: 8),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: coverageColor.withValues(alpha: 0.12),
                  border: Border.all(color: coverageColor),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.pie_chart, size: 16, color: coverageColor),
                      const SizedBox(width: 6),
                      Text(
                        'You reviewed $reviewedCount of $pairCount pairs '
                        '($coveragePercent%) before confirming.',
                        style: textTheme.bodyMedium?.copyWith(
                          color: coverageColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(message, style: textTheme.bodySmall),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: dryRunSucceeded ? onOpenReview : null,
              icon: const Icon(Icons.compare),
              label: Text(
                acknowledged
                    ? 'Review Duplicate Thumbnails Again'
                    : 'Review Duplicate Thumbnails',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Modal thumbnail-diff review for the "delete-dry-run" output (#49).
///
/// Parses the dry-run stdout with [parseDuplicateDryRunOutput] (never the
/// bash script's own Czkawka-report parsing) and renders a sampled subset
/// via [sampleDuplicateReviewPairs], always showing an honest "N of M"
/// count so nothing is silently hidden from large runs.
///
/// #53: for a large duplicate set, the initial sample alone can cover a
/// small slice of the total (e.g. 20 of 143 ≈ 14%). This dialog now also
/// tracks cumulative reviewed coverage across every batch shown so far —
/// starting from [initialReviewedIndices], which lets a re-opened dialog
/// resume from where a prior review session left off instead of resetting
/// — and offers a "Review Another Sample" button so a human who wants more
/// confidence than the first batch gives can page through additional,
/// non-overlapping batches before confirming. This is opt-in, extra
/// context: it never changes when the confirm gate unlocks (still "the
/// dialog was opened at least once" — see `canRunStep()`), only how
/// informed the human can choose to be before they use that unlock.
class _DuplicateThumbnailReviewDialog extends StatefulWidget {
  const _DuplicateThumbnailReviewDialog({
    required this.dryRunOutput,
    this.initialReviewedIndices = const {},
    this.onReviewedIndicesChanged,
  });

  final String dryRunOutput;
  final Set<int> initialReviewedIndices;
  final ValueChanged<Set<int>>? onReviewedIndicesChanged;

  @override
  State<_DuplicateThumbnailReviewDialog> createState() =>
      _DuplicateThumbnailReviewDialogState();
}

class _DuplicateThumbnailReviewDialogState
    extends State<_DuplicateThumbnailReviewDialog> {
  late final List<DuplicateReviewPair> _allPairs;
  late Set<int> _reviewedIndices;
  late DuplicateReviewSample _sample;
  int _batchNumber = 0;

  @override
  void initState() {
    super.initState();
    _allPairs = parseDuplicateDryRunOutput(widget.dryRunOutput).pairs;
    _reviewedIndices = {...widget.initialReviewedIndices};
    // Always show a fresh batch on open rather than re-displaying whatever
    // was on screen last time — draws from indices not yet reviewed first,
    // so re-opening the dialog after a partial review keeps making
    // progress instead of repeating the same pairs.
    _sample = sampleAdditionalDuplicateReviewPairs(
      _allPairs,
      _reviewedIndices,
      batchNumber: _batchNumber,
    );
    _reviewedIndices.addAll(_sample.shownIndices);
    // Deferred to after this frame: initState() runs while the framework
    // is still building the dialog's route, so calling setState() on the
    // ancestor _PipelineHomePageState synchronously here would hit a
    // "setState() called during build" error. A post-frame callback is
    // safe because by then the current build pass has finished.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _notifyReviewedIndicesChanged(),
    );
  }

  void _notifyReviewedIndicesChanged() {
    widget.onReviewedIndicesChanged?.call({..._reviewedIndices});
  }

  bool get _hasMoreToReview => _reviewedIndices.length < _allPairs.length;

  void _reviewAnotherSample() {
    setState(() {
      _batchNumber += 1;
      _sample = sampleAdditionalDuplicateReviewPairs(
        _allPairs,
        _reviewedIndices,
        batchNumber: _batchNumber,
      );
      _reviewedIndices.addAll(_sample.shownIndices);
    });
    _notifyReviewedIndicesChanged();
  }

  @override
  Widget build(BuildContext context) {
    final parsedOrphanCount = parseDuplicateDryRunOutput(
      widget.dryRunOutput,
    ).orphanTrashLineCount;
    final sample = _sample;
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final cumulativeCoveragePercent = duplicateReviewCoveragePercent(
      _reviewedIndices.length,
      _allPairs.length,
    );

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Review Duplicate Move Plan',
                      style: textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                sample.totalPairs == 0
                    ? 'No keep/trash pairs were found in the dry-run output.'
                    : sample.isSampled
                    ? 'Showing ${sample.shown.length} of ${sample.totalPairs} '
                          'pairs (batch ${_batchNumber + 1}) — full list in '
                          'the dry-run report.'
                    : 'Showing all ${sample.shown.length} '
                          'pair${sample.shown.length == 1 ? '' : 's'}.',
                style: textTheme.bodySmall,
              ),
              if (sample.totalPairs > 0) ...[
                const SizedBox(height: 6),
                Text(
                  'Cumulative: reviewed ${_reviewedIndices.length} of '
                  '${_allPairs.length} pairs ($cumulativeCoveragePercent%) '
                  'across every batch you\'ve opened.',
                  style: textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: cumulativeCoveragePercent >= 100
                        ? colorScheme.primary
                        : colorScheme.error,
                  ),
                ),
              ],
              if (parsedOrphanCount > 0) ...[
                const SizedBox(height: 4),
                Text(
                  '$parsedOrphanCount "Would trash" line'
                  '${parsedOrphanCount == 1 ? '' : 's'} could not '
                  'be matched to a kept file and are not shown here; open '
                  'the dry-run report to inspect them.',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: sample.shown.isEmpty
                    ? const Center(child: Text('Nothing to review.'))
                    : ListView.separated(
                        itemCount: sample.shown.length,
                        separatorBuilder: (context, index) =>
                            const Divider(height: 24),
                        itemBuilder: (context, index) {
                          return _DuplicateReviewPairRow(
                            pair: sample.shown[index],
                          );
                        },
                      ),
              ),
              if (_hasMoreToReview) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _reviewAnotherSample,
                  icon: const Icon(Icons.refresh),
                  label: Text(
                    'Review Another Sample '
                    '(${_allPairs.length - _reviewedIndices.length} pairs '
                    'not yet reviewed)',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DuplicateReviewPairRow extends StatelessWidget {
  const _DuplicateReviewPairRow({required this.pair});

  final DuplicateReviewPair pair;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _DuplicateReviewThumbnail(
            label: 'Keep',
            path: pair.keepPath,
            color: colorScheme.primary,
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 32),
          child: Icon(Icons.arrow_forward),
        ),
        Expanded(
          child: _DuplicateReviewThumbnail(
            label: 'Would trash',
            path: pair.trashPath,
            color: colorScheme.error,
          ),
        ),
      ],
    );
  }
}

/// Renders one path in the review dialog: an `Image.file` preview for
/// still-image formats, or a file icon + filename for video/unsupported
/// formats (no video-thumbnail-generation dependency is added for this).
class _DuplicateReviewThumbnail extends StatelessWidget {
  const _DuplicateReviewThumbnail({
    required this.label,
    required this.path,
    required this.color,
  });

  final String label;
  final String path;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final fileName = duplicateReviewFileName(path);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: color),
        ),
        const SizedBox(height: 4),
        AspectRatio(
          aspectRatio: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: color),
              borderRadius: BorderRadius.circular(4),
            ),
            child: isDisplayableImagePath(path)
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.file(
                      File(path),
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) =>
                          _DuplicateReviewFileFallback(fileName: fileName),
                    ),
                  )
                : _DuplicateReviewFileFallback(fileName: fileName),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _DuplicateReviewFileFallback extends StatelessWidget {
  const _DuplicateReviewFileFallback({required this.fileName});

  final String fileName;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insert_drive_file, size: 32),
            const SizedBox(height: 4),
            Text(
              fileName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
