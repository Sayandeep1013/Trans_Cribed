import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../bench/passages.dart';
import '../models/model_catalog.dart';
import '../transcriber/transcriber.dart';
import 'widgets.dart';

class RecordPage extends StatefulWidget {
  const RecordPage({super.key, required this.state});

  final AppState state;

  @override
  State<RecordPage> createState() => _RecordPageState();
}

class _RecordPageState extends State<RecordPage> {
  Timer? _clock;
  Duration _elapsed = Duration.zero;
  bool _showTimestamps = true;

  AppState get s => widget.state;

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  void _startClock() {
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final startedAt = s.recordingStartedAt;
      if (startedAt == null || !mounted) return;
      setState(() => _elapsed = DateTime.now().difference(startedAt));
    });
  }

  /// Mic tap: with more than one model installed, always ask which to record
  /// with (the loaded one is marked); picking a different one loads it first.
  Future<void> _onMicPressed() async {
    final installedSpecs = s.installedSpecs;
    ModelSpec? chosen = s.activeSpec;

    if (installedSpecs.length > 1) {
      chosen = await showModalBottomSheet<ModelSpec>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: ListView(
            shrinkWrap: true,
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
                  subtitle: spec.id == s.activeSpec?.id
                      ? const Text('Currently loaded — starts instantly')
                      : Text(
                          spec.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                  trailing: spec.id == s.activeSpec?.id
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
      if (chosen == null) return;
    }

    if (chosen == null) return;
    if (chosen.id != s.activeSpec?.id) {
      await s.useModel(chosen);
      if (!mounted) return;
      if (s.phase != Phase.ready || s.activeSpec?.id != chosen.id) return;
    }
    await s.startRecording();
    if (!mounted) return;
    if (s.phase == Phase.recording) {
      setState(() => _elapsed = Duration.zero);
      _startClock();
    }
  }

  Future<void> _stop() async {
    _clock?.cancel();
    _clock = null;
    await s.stopRecording();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: switch (s.phase) {
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
    );
  }

  Widget _buildCatalog() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Models', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          'Download once (Wi-Fi recommended). Transcription runs fully '
          'offline - audio never leaves this phone, and no model is ever '
          'trained or modified on device.',
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
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            if (s.installed[spec.id] == true)
                              const Chip(
                                label: Text('Installed'),
                                visualDensity: VisualDensity.compact,
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        // Language capability is the single most misread thing
                        // about these models, so it gets a badge rather than a
                        // sentence buried in the description.
                        Row(
                          children: [
                            Icon(
                              spec.isMultilingual
                                  ? Icons.language
                                  : Icons.abc,
                              size: 16,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              spec.isMultilingual
                                  ? '99 languages · can translate to English'
                                  : 'English only',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                  ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          spec.description,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '~${spec.approxMb} MB  ·  ${spec.type.name}  ·  '
                          '${spec.numThreads} threads',
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        Text(
                          spec.sourceUrl.replaceFirst('https://', ''),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            if (s.installed[spec.id] == true) ...[
                              FilledButton(
                                onPressed: () => unawaited(s.useModel(spec)),
                                child: Text(
                                  s.activeSpec?.id == spec.id
                                      ? 'Continue'
                                      : 'Use',
                                ),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                onPressed: () => unawaited(s.deleteModel(spec)),
                                child: const Text('Delete'),
                              ),
                            ] else
                              FilledButton.icon(
                                onPressed: () =>
                                    unawaited(s.downloadModel(spec)),
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
    final progress = s.downloadProgress;
    final spec = s.downloadingSpec;
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
            onPressed: () => setState(() => s.cancelRequested = true),
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
          Text(s.stage, style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    );
  }

  Widget _buildReady() {
    final stats = s.stats;
    final passage = s.plannedPassage;
    return ListView(
      children: [
        MetricsCard(
          title: 'Engine ready — ${s.activeSpec?.displayName ?? ''}',
          rows: {
            if (stats != null) ...{
              'Model load': '${stats.modelLoad.inMilliseconds} ms',
              'Warmup inference': '${stats.warmup.inMilliseconds} ms',
            },
            'Settings': s.options.shortLabel,
            'Language': s.activeSpec?.supportsLanguageChoice == true
                ? '${s.options.languageLabel}'
                    '${s.options.whisperTask == 'translate' ? ' → English' : ''}'
                : 'English only (fixed by this model)',
            'Keep audio': s.retainAudio ? 'Yes (enables re-decode)' : 'No',
          },
          trailing: TextButton(
            onPressed: () => setState(() => s.phase = Phase.catalog),
            child: const Text('Models'),
          ),
        ),
        if (passage != null)
          Card(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Read aloud: ${passage.title}',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => s.setPlannedPassage(null),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    passage.text,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Scored automatically against this text when you stop.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 32),
        Center(child: _BigMicButton(onPressed: () => unawaited(_onMicPressed()))),
        const SizedBox(height: 12),
        Center(
          child: Text(
            s.installedSpecs.length > 1
                ? 'Tap to choose a model & start transcribing'
                : 'Tap to start transcribing',
          ),
        ),
        const SizedBox(height: 24),
        if (s.plannedPassage == null)
          Center(
            child: TextButton.icon(
              onPressed: _pickPassage,
              icon: const Icon(Icons.menu_book_outlined),
              label: const Text('Read a scored passage instead'),
            ),
          ),
      ],
    );
  }

  Future<void> _pickPassage() async {
    final chosen = await showModalBottomSheet<Passage>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                'Scored passages',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'The app already knows these words, so accuracy is scored '
                'with no typing. Hand the same passage to different speakers '
                'to measure accent impact.',
                style: Theme.of(sheetContext).textTheme.bodySmall,
              ),
            ),
            for (final p in passages)
              ListTile(
                title: Text(p.title),
                subtitle: Text(
                  '${p.purpose}\n~${p.approxDuration.inSeconds}s · '
                  '${p.wordCount} words',
                ),
                isThreeLine: true,
                onTap: () => Navigator.pop(sheetContext, p),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (chosen != null) s.setPlannedPassage(chosen);
  }

  Widget _buildRecording() {
    final scheme = Theme.of(context).colorScheme;
    final interim = s.interim;
    final pendingSlot = (interim != null || s.speechActive) ? 1 : 0;

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 36,
              height: 36,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 100),
                  width: 12 + 24 * s.level,
                  height: 12 + 24 * s.level,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.redAccent
                        .withValues(alpha: 0.35 + 0.65 * s.level),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatDuration(_elapsed),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: s.liveSegments.isEmpty && pendingSlot == 0
              ? Center(
                  child: Text(
                    'Listening… captions appear as you speak.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                )
              : ListView.builder(
                  reverse: true,
                  itemCount: s.liveSegments.length + pendingSlot,
                  itemBuilder: (context, index) {
                    if (pendingSlot == 1 && index == 0) {
                      return Card(
                        color: scheme.surfaceContainerHighest,
                        child: ListTile(
                          leading: const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          title: Text(
                            interim?.text ?? 'Transcribing…',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                          subtitle: Text(
                            interim == null
                                ? 'listening'
                                : 'live · updates every '
                                    '${(s.options.interimCaptionMs / 1000).round()}s',
                          ),
                        ),
                      );
                    }
                    final segment = s.liveSegments[index - pendingSlot];
                    return _SegmentTile(segment: segment);
                  },
                ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => unawaited(_stop()),
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
    final session = s.lastSession;
    if (session == null) return const SizedBox.shrink();

    final segments = session.segments;
    final totalAudioMs =
        segments.fold<int>(0, (sum, x) => sum + x.audioLength.inMilliseconds);
    final totalDecodeMs =
        segments.fold<int>(0, (sum, x) => sum + x.decodeTime.inMilliseconds);
    final avgRtf = totalAudioMs == 0 ? 0.0 : totalDecodeMs / totalAudioMs;

    final latencies = segments
        .map((x) => x.captionLatency.inMilliseconds)
        .where((ms) => ms > 0)
        .toList()
      ..sort();
    String percentile(double p) {
      if (latencies.isEmpty) return '—';
      final index = ((latencies.length - 1) * p).round();
      return '${latencies[index]} ms';
    }

    final wer = session.liveWer;

    return ListView(
      children: [
        MetricsCard(
          title: 'Session — ${session.modelName}',
          rows: {
            'Audio duration':
                '${(session.audioDuration.inMilliseconds / 1000).toStringAsFixed(1)} s',
            'Segments': '${segments.length}',
            'Avg RTF (target < 0.3)': avgRtf.toStringAsFixed(3),
            'Caption latency p50': percentile(0.5),
            'Caption latency p95': percentile(0.95),
            if (wer != null) 'WER vs reference': wer.percent,
            'Audio kept': session.hasAudio ? 'Yes' : 'No',
          },
          footnote: session.hasAudio
              ? 'Audio saved — open Lab to re-decode this exact recording '
                  'with other models.'
              : 'Audio retention is off, so this recording cannot be '
                  're-decoded. Turn it on in Lab.',
        ),
        const SizedBox(height: 8),
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
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _showTimestamps
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final segment in segments)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${formatDuration(segment.start)} – '
                                '${formatDuration(segment.end)}   ·   '
                                'decode ${segment.decodeTime.inMilliseconds} ms'
                                '   ·   lag '
                                '${segment.captionLatency.inMilliseconds} ms',
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                    ),
                              ),
                              const SizedBox(height: 2),
                              SelectableText(segment.text),
                            ],
                          ),
                        ),
                    ],
                  )
                : SelectableText(
                    session.text.isEmpty
                        ? '(no speech detected)'
                        : session.text,
                  ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => unawaited(_copy(session.text)),
                icon: const Icon(Icons.copy),
                label: const Text('Copy'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                onPressed: s.newSession,
                icon: const Icon(Icons.mic),
                label: const Text('New session'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
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
            child: Text(s.errorMessage, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: s.newSession,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _SegmentTile extends StatelessWidget {
  const _SegmentTile({required this.segment});

  final TranscriptSegment segment;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        title: Text(segment.text),
        subtitle: Text(
          '${formatDuration(segment.start)} – ${formatDuration(segment.end)}'
          '   ·   RTF ${segment.rtf.toStringAsFixed(2)}'
          '   ·   lag ${segment.captionLatency.inMilliseconds} ms',
        ),
      ),
    );
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
