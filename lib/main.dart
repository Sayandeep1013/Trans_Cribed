import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'transcriber/sherpa_moonshine_transcriber.dart';
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

enum Phase { preparing, ready, recording, finalizing, done, error }

class TranscribeDemoPage extends StatefulWidget {
  const TranscribeDemoPage({super.key});

  @override
  State<TranscribeDemoPage> createState() => _TranscribeDemoPageState();
}

class _TranscribeDemoPageState extends State<TranscribeDemoPage> {
  // Singleton for the app's lifetime - prepared once, reused every session.
  final Transcriber _transcriber = SherpaMoonshineTranscriber();

  Phase _phase = Phase.preparing;
  String _stage = 'Starting…';
  String _errorMessage = '';
  bool _micDenied = false;

  TranscriberStats? _stats;
  TranscriptResult? _result;
  final List<TranscriptSegment> _liveSegments = [];
  StreamSubscription<TranscriptSegment>? _segmentSub;

  DateTime? _recordingStartedAt;
  Timer? _clockTimer;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _segmentSub = _transcriber.segments.listen((segment) {
      if (!mounted) return;
      setState(() => _liveSegments.insert(0, segment));
    });
    unawaited(_prepare());
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    unawaited(_segmentSub?.cancel());
    unawaited(WakelockPlus.disable());
    unawaited(_transcriber.dispose());
    super.dispose();
  }

  Future<void> _prepare() async {
    setState(() {
      _phase = Phase.preparing;
      _stage = 'Starting…';
    });
    try {
      final stats = await _transcriber.prepare(
        onProgress: (stage) {
          if (mounted) setState(() => _stage = stage);
        },
      );
      if (!mounted) return;
      setState(() {
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

  Future<void> _startRecording() async {
    try {
      _liveSegments.clear();
      await _transcriber.start();
      await WakelockPlus.enable();
      _recordingStartedAt = DateTime.now();
      // Wall-clock based elapsed time - immune to timer throttling.
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
    _clockTimer?.cancel();
    _clockTimer = null;
    await WakelockPlus.disable();
    setState(() => _phase = Phase.finalizing);
    try {
      final result = await _transcriber.stop();
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
      _phase = Phase.ready;
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
                'on-device · offline',
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
            Phase.preparing => _buildPreparing(),
            Phase.ready => _buildReady(),
            Phase.recording => _buildRecording(),
            Phase.finalizing => _buildFinalizing(),
            Phase.done => _buildDone(),
            Phase.error => _buildError(),
          },
        ),
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
          const SizedBox(height: 8),
          Text(
            'One-time setup on first launch; instant afterwards.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildReady() {
    final stats = _stats;
    return Column(
      children: [
        if (stats != null)
          _MetricsCard(
            title: 'Engine ready',
            rows: {
              'Model load': '${stats.modelLoad.inMilliseconds} ms',
              'Warmup inference': '${stats.warmup.inMilliseconds} ms',
            },
          ),
        const Spacer(),
        _BigMicButton(onPressed: _startRecording),
        const SizedBox(height: 12),
        const Text('Tap to start transcribing'),
        const Spacer(),
      ],
    );
  }

  Widget _buildRecording() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.fiber_manual_record, color: Colors.redAccent),
            const SizedBox(width: 8),
            Text(
              _formatDuration(_elapsed),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: _liveSegments.isEmpty
              ? Center(
                  child: Text(
                    'Listening… captions appear at natural pauses.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                )
              : ListView.builder(
                  reverse: true,
                  itemCount: _liveSegments.length,
                  itemBuilder: (context, index) {
                    final s = _liveSegments[index];
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
          onPressed: _stopRecording,
          icon: const Icon(Icons.stop),
          label: const Text('Stop'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
          ),
        ),
      ],
    );
  }

  Widget _buildFinalizing() {
    return const Center(child: CircularProgressIndicator());
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
          title: 'Session metrics',
          rows: {
            'Audio duration':
                '${result.durationSeconds.toStringAsFixed(1)} s',
            'Segments': '${result.segments.length}',
            'Avg RTF (target < 0.3)': avgRtf.toStringAsFixed(3),
            'Max segment RTF': maxRtf.toStringAsFixed(3),
          },
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Card(
            child: Padding(
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
                onPressed: _copyTranscript,
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
              if (_micDenied || _transcriber.isReady) {
                _newSession();
              } else {
                unawaited(_prepare());
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
  const _MetricsCard({required this.title, required this.rows});

  final String title;
  final Map<String, String> rows;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: textTheme.titleMedium),
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
