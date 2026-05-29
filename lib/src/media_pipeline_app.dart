import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'immich_connection.dart';
import 'immich_phone_checklist_store.dart';
import 'pipeline_models.dart';
import 'pipeline_runner.dart';

class MediaPipelineApp extends StatelessWidget {
  const MediaPipelineApp({super.key, this.immichClient, this.checklistStore});

  final ImmichApiClient? immichClient;
  final ImmichChecklistStore? checklistStore;

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
      ),
    );
  }
}

class PipelineHomePage extends StatefulWidget {
  const PipelineHomePage({super.key, this.immichClient, this.checklistStore});

  final ImmichApiClient? immichClient;
  final ImmichChecklistStore? checklistStore;

  @override
  State<PipelineHomePage> createState() => _PipelineHomePageState();
}

class _PipelineHomePageState extends State<PipelineHomePage> {
  final List<PipelineStep> _steps = buildPipelineSteps();
  final Map<String, StepRunState> _states = {};
  late final PipelineRunner _runner;
  late final ImmichApiClient _immichClient;
  late final ImmichChecklistStore _checklistStore;
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

  PipelineStep get _selectedStep => _steps[_selectedIndex];

  @override
  void initState() {
    super.initState();
    _settings = PipelineSettings.defaults();
    _runner = PipelineRunner(workingDirectory: Directory.current.path);
    _immichClient = widget.immichClient ?? ImmichApiClient();
    _checklistStore = widget.checklistStore ?? ImmichChecklistStore();
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
    if (_runningStepId != null || !canRunStep(step: step, states: _states)) {
      return;
    }

    setState(() {
      _settings = _settings.copyWith(
        hdPath: _hdPathController.text.trim(),
        reportDir: _reportDirController.text.trim(),
      );
      _runningStepId = step.id;
      _states[step.id] = const StepRunState(status: PipelineStepStatus.running);
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
      );
    });
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
                          itemCount: _steps.length,
                          itemBuilder: (context, index) {
                            final step = _steps[index];
                            return _StepTile(
                              step: step,
                              state: _states[step.id] ?? const StepRunState(),
                              selected: index == _selectedIndex,
                              onTap: () =>
                                  setState(() => _selectedIndex = index),
                            );
                          },
                        ),
                        _AppMode.immich => const _ImmichNav(),
                        _AppMode.help => const _HelpNav(),
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
                      canRunStep(step: _selectedStep, states: _states),
                  running: _runningStepId == _selectedStep.id,
                  onRun: _runSelectedStep,
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
              },
            ),
          ],
        ),
      ),
    );
  }
}

enum _AppMode { workflow, immich, help }

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
    final totalChecklistsProgress = checklists.length * checklistProgressTotalCount;
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
              'Future app work should connect to the private Immich API.',
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
  });

  final PipelineStep step;
  final StepRunState state;
  final bool canRun;
  final bool running;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final blockedReason = _blockedReason(step, canRun: canRun);
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
  return ([step.command.executable, ...step.command.arguments]).join(' ');
}

String _newChecklistId() {
  return DateTime.now().microsecondsSinceEpoch.toString();
}

String? _blockedReason(PipelineStep step, {required bool canRun}) {
  if (step.linuxOnly && !Platform.isLinux) {
    return 'This step is enabled only on Linux or ChromeOS Linux in v1.';
  }
  if (step.requiresDryRunStepId != null && !canRun) {
    return 'This confirm step is locked until its dry-run step succeeds in this app session.';
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
