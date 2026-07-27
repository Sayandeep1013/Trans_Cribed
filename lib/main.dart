import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'models/model_catalog.dart';
import 'models/model_store.dart';
import 'transcriber/sherpa_onnx_transcriber.dart';
import 'transcriber/transcriber.dart';

void main() {
  runApp(const DemoApp());
}

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Picaku STT Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE1614A),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const TranscribeDemoPage(),
    );
  }
}

enum Phase {
  catalog,
  downloading,
  preparing,
  ready,
  recording,
  finalizing,
  done,
  error,
}

class TranscribeDemoPage extends StatefulWidget {
  const TranscribeDemoPage({super.key});

  @override
  State<TranscribeDemoPage> createState() => _TranscribeDemoPageState();
}

class _TranscribeDemoPageState extends State<TranscribeDemoPage> {
  final ModelStore _store = ModelStore();

  Phase _phase = Phase.catalog;
  String _stage = 'Starting…';
  String _errorMessage = '';
  bool _micDenied = false;

  Map<String, bool> _installed = {};
  ModelSpec? _activeSpec;
  Transcriber? _transcriber;
  StreamSubscription<TranscriptSegment>? _segmentSub;
  StreamSubscription<double>? _levelSub;
  StreamSubscription<bool>? _speechSub;
  double _level = 0;
  bool _speechActive = false;
  bool _showTimestamps = false;

  DownloadProgress? _downloadProgress;
  ModelSpec? _downloadingSpec;
  bool _cancelRequested = false;

  TranscriberStats? _stats;
  TranscriptResult? _result;
  final List<TranscriptSegment> _liveSegments = [];

  DateTime? _recordingStartedAt;
  Timer? _clockTimer;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    unawaited(_initModels());
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    unawaited(_segmentSub?.cancel());
    unawaited(_levelSub?.cancel());
    unawaited(_speechSub?.cancel());
    unawaited(WakelockPlus.disable());
    unawaited(_transcriber?.dispose());
    super.dispose();
  }

  Future<void> _initModels() async {
    await _refreshInstalled();
    final selectedId = await _store.getSelectedModelId();
    ModelSpec? toUse;
    for (final spec in modelCatalog) {
      if (_installed[spec.id] == true &&
          (toUse == null || spec.id == selectedId)) {
        toUse = spec;
      }
    }
    if (toUse != null) {
      await _useModel(toUse);
    } else {
      if (mounted) setState(() => _phase = Phase.catalog);
    }
  }

  Future<void> _refreshInstalled() async {
    final installed = <String, bool>{};
    for (final spec in modelCatalog) {
      installed[spec.id] = await _store.isInstalled(spec);
    }
    if (mounted) setState(() => _installed = installed);
  }

  Future<void> _downloadModel(ModelSpec spec) async {
    setState(() {
      _phase = Phase.downloading;
      _downloadingSpec = spec;
      _downloadProgress = null;
      _cancelRequested = false;
    });
    await WakelockPlus.enable();
    try {
      await _store.download(
        spec,
        onProgress: (progress) {
          if (mounted) setState(() => _downloadProgress = progress);
        },
        isCancelled: () => _cancelRequested,
      );
      await _refreshInstalled();
      await _store.setSelectedModelId(spec.id);
      await _useModel(spec);
    } on DownloadCancelled {
      if (mounted) setState(() => _phase = Phase.catalog);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = Phase.error;
        _micDenied = false;
        _errorMessage =
            'Download failed: $e\n\nCheck your connection and retry - '
            'finished files are kept, so it resumes where it stopped.';
      });
    } finally {
      if (_phase != Phase.recording) await WakelockPlus.disable();
    }
  }

  Future<void> _useModel(ModelSpec spec) async {
    if (mounted) {
      setState(() {
        _phase = Phase.preparing;
        _stage = 'Loading ${spec.displayName}…';
      });
    }
    try {
      await _segmentSub?.cancel();
      await _levelSub?.cancel();
      await _speechSub?.cancel();
      await _transcriber?.dispose();

      final installed = await _store.installedFor(spec);
      final transcriber = SherpaOnnxTranscriber(model: installed);
      _segmentSub = transcriber.segments.listen(
        (segment) {
          if (!mounted) return;
          setState(() => _liveSegments.insert(0, segment));
        },
        onError: (Object e) {
          if (!mounted) return;
          setState(() {
            _phase = Phase.error;
            _micDenied = false;
            _errorMessage = 'Engine error during session: $e';
          });
        },
      );
      _levelSub = transcriber.audioLevel.listen((level) {
        if (mounted && _phase == Phase.recording) {
          setState(() => _level = level);
        }
      });
      _speechSub = transcriber.speechActive.listen((active) {
        if (mounted) setState(() => _speechActive = active);
      });

      final stats = await transcriber.prepare(
        onProgress: (stage) {
          if (mounted) setState(() => _stage = stage);
        },
      );
      await _store.setSelectedModelId(spec.id);
      if (!mounted) return;
      setState(() {
        _transcriber = transcriber;
        _activeSpec = spec;
        _stats = stats;
        _phase = Phase.ready;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = Phase.error;
        _micDenied = false;
        _errorMessage = 'Engine failed to load: $e';
      });
    }
  }

  Future<void> _deleteModel(ModelSpec spec) async {
    if (_activeSpec?.id == spec.id) {
      await _segmentSub?.cancel();
      _segmentSub = null;
      await _transcriber?.dispose();
      _transcriber = null;
      _activeSpec = null;
    }
    await _store.delete(spec);
    await _refreshInstalled();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${spec.displayName} deleted')),
      );
    }
  }

  /// Mic tap: when more than one model is installed, always ask which one to
  /// record with (the loaded one is marked); picking a different one loads it
  /// first, then recording starts.
  Future<void> _onMicPressed() async {
    final installedSpecs =
        modelCatalog.where((s) => _installed[s.id] == true).toList();
    ModelSpec? chosen = _activeSpec;

    if (installedSpecs.length > 1) {
      chosen = await showModalBottomSheet<ModelSpec>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Transcribe with',
                  style: Theme.of(sheetContext).textTheme.titleMedium,
                ),
              ),
              for (final spec in installedSpecs)
                ListTile(
                  title: Text(spec.displayName),
                  subtitle: spec.id == _activeSpec?.id
                      ? const Text('Currently loaded — starts instantly')
                      : Text(
                          spec.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  trailing: spec.id == _activeSpec?.id
                      ? Icon(
                          Icons.check_circle,
                          color: Theme.of(sheetContext).colorScheme.primary,
                        )
                      : null,
                  onTap: () => Navigator.pop(sheetContext, spec),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
      if (chosen == null) return; // sheet dismissed
    }

    if (chosen == null) return;
    if (chosen.id != _activeSpec?.id) {
      await _useModel(chosen);
      // Only proceed if the switch actually landed in a ready state.
      if (_phase != Phase.ready || _activeSpec?.id != chosen.id) return;
    }
    await _startRecording();
  }

  Future<void> _startRecording() async {
    final transcriber = _transcriber;
    if (transcriber == null) return;
    try {
      _liveSegments.clear();
      await transcriber.start();
      await WakelockPlus.enable();
      _recordingStartedAt = DateTime.now();
      _clockTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        final startedAt = _recordingStartedAt;
        if (startedAt == null || !mounted) return;
        setState(() => _elapsed = DateTime.now().difference(startedAt));
      });
      setState(() {
        _phase = Phase.recording;
        _elapsed = Duration.zero;
      });
    } on MicPermissionDeniedException {
      setState(() {
        _phase = Phase.error;
        _micDenied = true;
        _errorMessage =
            'Microphone permission is required. Grant it in system settings '
            'if the prompt no longer appears, then retry.';
      });
    } catch (e) {
      setState(() {
        _phase = Phase.error;
        _micDenied = false;
        _errorMessage = 'Could not start recording: $e';
      });
    }
  }

  Future<void> _stopRecording() async {
    final transcriber = _transcriber;
    if (transcriber == null) return;
    _clockTimer?.cancel();
    _clockTimer = null;
    await WakelockPlus.disable();
    setState(() => _phase = Phase.finalizing);
    try {
      final result = await transcriber.stop();
      if (!mounted) return;
      setState(() {
        _result = result;
        _phase = Phase.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = Phase.error;
        _micDenied = false;
        _errorMessage = 'Failed to finalize transcript: $e';
      });
    }
  }

  Future<void> _copyTranscript() async {
    final text = _result?.text ?? '';
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Transcript copied to clipboard')),
    );
  }

  void _newSession() {
    setState(() {
      _result = null;
      _liveSegments.clear();
      _elapsed = Duration.zero;
      _phase = _transcriber == null ? Phase.catalog : Phase.ready;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Picaku STT Demo'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                'on-device STT',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: switch (_phase) {
            Phase.catalog => _buildCatalog(),
            Phase.downloading => _buildDownloading(),
            Phase.preparing => _buildPreparing(),
            Phase.ready => _buildReady(),
            Phase.recording => _buildRecording(),
            Phase.finalizing => const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Finalizing transcript…'),
                  ],
                ),
              ),
            Phase.done => _buildDone(),
            Phase.error => _buildError(),
          },
        ),
      ),
    );
  }

  Widget _buildCatalog() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Models', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Download once (Wi-Fi recommended). Transcription itself runs '
          'fully offline - audio never leaves this phone, and no model is '
          'ever trained or modified on device.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView(
            children: [
              for (final spec in modelCatalog)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                spec.displayName,
                                style:
                                    Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            if (_installed[spec.id] == true)
                              const Chip(
                                label: Text('Installed'),
                                visualDensity: VisualDensity.compact,
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${spec.description}  ·  ~${spec.approxMb} MB',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            if (_installed[spec.id] == true) ...[
                              FilledButton(
                                onPressed: () => unawaited(_useModel(spec)),
                                child: Text(
                                  _activeSpec?.id == spec.id
                                      ? 'Continue'
                                      : 'Use',
                                ),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                onPressed: () =>
                                    unawaited(_deleteModel(spec)),
                                child: const Text('Delete'),
                              ),
                            ] else
                              FilledButton.icon(
                                onPressed: () =>
                                    unawaited(_downloadModel(spec)),
                                icon: const Icon(Icons.download),
                                label: const Text('Download'),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDownloading() {
    final progress = _downloadProgress;
    final spec = _downloadingSpec;
    final mb = progress == null
        ? ''
        : '${(progress.receivedBytes / 1048576).toStringAsFixed(1)} MB'
            '${progress.totalBytes != null ? ' / ${(progress.totalBytes! / 1048576).toStringAsFixed(1)} MB' : ''}';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Downloading ${spec?.displayName ?? 'model'}…',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(value: progress?.fileFraction),
          const SizedBox(height: 12),
          Text(
            progress == null
                ? 'Connecting…'
                : '${progress.fileName} '
                    '(${progress.fileIndex}/${progress.fileCount})\n$mb',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: () => setState(() => _cancelRequested = true),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _buildPreparing() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 24),
          Text(_stage, style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    );
  }

  Widget _buildReady() {
    final stats = _stats;
    return Column(
      children: [
        _MetricsCard(
          title: 'Engine ready — ${_activeSpec?.displayName ?? ''}',
          rows: {
            if (stats != null) ...{
              'Model load': '${stats.modelLoad.inMilliseconds} ms',
              'Warmup inference': '${stats.warmup.inMilliseconds} ms',
            },
          },
          trailing: TextButton(
            onPressed: () => setState(() => _phase = Phase.catalog),
            child: const Text('Switch model'),
          ),
        ),
        const Spacer(),
        _BigMicButton(onPressed: () => unawaited(_onMicPressed())),
        const SizedBox(height: 12),
        Text(
          modelCatalog.where((s) => _installed[s.id] == true).length > 1
              ? 'Tap to choose a model & start transcribing'
              : 'Tap to start transcribing',
        ),
        const Spacer(),
      ],
    );
  }

  Widget _buildRecording() {
    final scheme = Theme.of(context).colorScheme;
    // Pending "speaking" bubble occupies slot 0 while the VAD hears speech,
    // so the screen reacts instantly - captions finalize at pauses.
    final pendingSlot = _speechActive ? 1 : 0;
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Level-driven pulse: proves the app hears you before any text.
            SizedBox(
              width: 36,
              height: 36,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 100),
                  width: 12 + 24 * _level,
                  height: 12 + 24 * _level,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.redAccent
                        .withValues(alpha: 0.35 + 0.65 * _level),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _formatDuration(_elapsed),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: _liveSegments.isEmpty && !_speechActive
              ? Center(
                  child: Text(
                    'Listening… speak and captions appear at pauses.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                )
              : ListView.builder(
                  reverse: true,
                  itemCount: _liveSegments.length + pendingSlot,
                  itemBuilder: (context, index) {
                    if (_speechActive && index == 0) {
                      return Card(
                        color: scheme.surfaceContainerHighest,
                        child: ListTile(
                          leading: const SizedBox(
                            width: 18,
                            height: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          ),
                          title: Text(
                            'Transcribing…',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                          subtitle:
                              Text('started ${_formatDuration(_elapsed)}'),
                        ),
                      );
                    }
                    final s = _liveSegments[index - pendingSlot];
                    return Card(
                      child: ListTile(
                        title: Text(s.text),
                        subtitle: Text(
                          '${_formatDuration(s.start)} - '
                          '${_formatDuration(s.end)}   ·   '
                          'RTF ${s.rtf.toStringAsFixed(2)}',
                        ),
                      ),
                    );
                  },
                ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => unawaited(_stopRecording()),
          icon: const Icon(Icons.stop),
          label: const Text('Stop'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
          ),
        ),
      ],
    );
  }

  Widget _buildDone() {
    final result = _result;
    if (result == null) return const SizedBox.shrink();

    final totalAudioMs = result.segments.fold<int>(
      0,
      (sum, s) => sum + s.audioLength.inMilliseconds,
    );
    final totalDecodeMs = result.segments.fold<int>(
      0,
      (sum, s) => sum + s.decodeTime.inMilliseconds,
    );
    final avgRtf = totalAudioMs == 0 ? 0.0 : totalDecodeMs / totalAudioMs;
    final maxRtf = result.segments.isEmpty
        ? 0.0
        : result.segments.map((s) => s.rtf).reduce((a, b) => a > b ? a : b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MetricsCard(
          title: 'Session metrics — ${_activeSpec?.displayName ?? ''}',
          rows: {
            'Audio duration':
                '${result.durationSeconds.toStringAsFixed(1)} s',
            'Segments': '${result.segments.length}',
            'Avg RTF (target < 0.3)': avgRtf.toStringAsFixed(3),
            'Max segment RTF': maxRtf.toStringAsFixed(3),
          },
        ),
        const SizedBox(height: 12),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Plain')),
            ButtonSegment(value: true, label: Text('Timestamped')),
          ],
          selected: {_showTimestamps},
          onSelectionChanged: (selection) =>
              setState(() => _showTimestamps = selection.first),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Card(
            child: _showTimestamps
                ? ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: result.segments.length,
                    itemBuilder: (context, index) {
                      final s = result.segments[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 6,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${_formatDuration(s.start)} - '
                              '${_formatDuration(s.end)}',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                  ),
                            ),
                            const SizedBox(height: 2),
                            SelectableText(s.text),
                          ],
                        ),
                      );
                    },
                  )
                : Padding(
                    padding: const EdgeInsets.all(12),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        result.text.isEmpty
                            ? '(no speech detected)'
                            : result.text,
                      ),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => unawaited(_copyTranscript()),
                icon: const Icon(Icons.copy),
                label: const Text('Copy'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: _newSession,
                icon: const Icon(Icons.mic),
                label: const Text('New session'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(_errorMessage, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () {
              if (_micDenied || _transcriber != null) {
                _newSession();
              } else {
                setState(() => _phase = Phase.catalog);
              }
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _BigMicButton extends StatelessWidget {
  const _BigMicButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primary,
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(36),
          child: Icon(Icons.mic, size: 48, color: scheme.onPrimary),
        ),
      ),
    );
  }
}

class _MetricsCard extends StatelessWidget {
  const _MetricsCard({required this.title, required this.rows, this.trailing});

  final String title;
  final Map<String, String> rows;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: textTheme.titleMedium)),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 8),
            for (final entry in rows.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(entry.key, style: textTheme.bodyMedium),
                    Text(
                      entry.value,
                      style: textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
