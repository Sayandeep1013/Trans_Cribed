import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../diag/resource_monitor.dart';
import 'widgets.dart';

/// What the app costs the phone, and how long it can keep going.
///
/// "How long can it run without interruption" is not one number - it is five
/// separate limits, and this page shows each so the binding one is obvious.
class DiagnosticsPage extends StatelessWidget {
  const DiagnosticsPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final sample = state.latestResource;
    final history = state.resources.history;
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        MetricsCard(
          title: 'Right now',
          rows: sample == null
              ? {'Sampling': 'starting…'}
              : {
                  'App RAM (RSS)': '${sample.rssMb.toStringAsFixed(0)} MB',
                  'Peak RAM': '${sample.peakRssMb.toStringAsFixed(0)} MB',
                  'CPU (whole device)':
                      '${sample.cpuPercentOfDevice.toStringAsFixed(1)} %',
                  'CPU (of one core)':
                      '${sample.cpuPercentOfCore.toStringAsFixed(0)} %',
                  'Threads': '${sample.threads}',
                  if (sample.deviceTotalMb != null)
                    'Device RAM free':
                        '${sample.deviceAvailMb} / ${sample.deviceTotalMb} MB',
                  'Thermal status': sample.thermalLabel,
                  if (sample.batteryPercent != null)
                    'Battery': '${sample.batteryPercent} %',
                  if (sample.batteryCurrentUa != null)
                    'Battery draw':
                        '${(sample.batteryCurrentUa!.abs() / 1000).toStringAsFixed(0)} mA',
                  if (sample.batteryTempC != null)
                    'Battery temp':
                        '${sample.batteryTempC!.toStringAsFixed(1)} °C',
                },
          footnote: 'GPU is not listed because inference never uses it: '
              'sherpa-onnx runs on CPU via XNNPACK, with no NNAPI or GPU '
              'delegate in these builds.',
        ),
        const SizedBox(height: 8),
        _EnduranceCard(history: history),
        const SizedBox(height: 8),
        _LatencyCard(state: state),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => unawaited(_export(context)),
                icon: const Icon(Icons.download),
                label: const Text('Copy full log JSON'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  state.log.clear();
                  state.resources.clearHistory();
                },
                icon: const Icon(Icons.clear_all),
                label: const Text('Clear'),
              ),
            ),
          ],
        ),
        const SectionHeader(
          title: 'Event log',
          explanation:
              'Newest first. Every model load, utterance, decode and error '
              'with its timing, so "captions feel late" can be traced to the '
              'stage that actually caused it.',
        ),
        for (final event in state.log.reversed.take(300))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 88,
                  child: Text(
                    formatClock(event.at),
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        event.kind,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      Text(
                        _describe(event.data),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 32),
      ],
    );
  }

  static String _describe(Map<String, Object?> data) {
    if (data.isEmpty) return '—';
    return data.entries
        .where((e) => e.value != null)
        .map((e) => '${e.key}=${_short(e.value)}')
        .join('  ');
  }

  static String _short(Object? value) {
    if (value is double) return value.toStringAsFixed(3);
    final text = value.toString();
    return text.length > 60 ? '${text.substring(0, 57)}…' : text;
  }

  Future<void> _export(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final json = state.exportDiagnostics();
    await Clipboard.setData(ClipboardData(text: json));
    messenger.showSnackBar(
      SnackBar(
        content: Text('${(json.length / 1024).toStringAsFixed(0)} KB of '
            'diagnostics copied'),
      ),
    );
  }
}

class _EnduranceCard extends StatelessWidget {
  const _EnduranceCard({required this.history});

  final List<ResourceSample> history;

  @override
  Widget build(BuildContext context) {
    if (history.length < 2) {
      return const MetricsCard(
        title: 'Endurance',
        rows: {'Status': 'Collecting samples…'},
        footnote: 'Leave the app open (ideally recording) for a few minutes '
            'to get a trend.',
      );
    }

    final first = history.first;
    final last = history.last;
    final hours = last.at.difference(first.at).inMilliseconds / 3600000;

    final ramGrowth = hours > 0 ? (last.rssMb - first.rssMb) / hours : 0.0;

    String batteryLine = 'Not enough data';
    String runtimeEstimate = '—';
    if (first.batteryPercent != null && last.batteryPercent != null && hours > 0) {
      final drained = first.batteryPercent! - last.batteryPercent!;
      final perHour = drained / hours;
      batteryLine = '${perHour.toStringAsFixed(1)} %/hour';
      if (perHour > 0.5) {
        runtimeEstimate =
            '${(last.batteryPercent! / perHour).toStringAsFixed(1)} h '
            'to empty at this rate';
      }
    }

    final throttled = history.where((s) => s.isThrottling).length;

    return MetricsCard(
      title: 'Endurance',
      rows: {
        'Observed for': '${(hours * 60).toStringAsFixed(0)} min',
        'RAM trend': '${ramGrowth >= 0 ? '+' : ''}'
            '${ramGrowth.toStringAsFixed(1)} MB/hour',
        'Battery drain': batteryLine,
        'Estimated runtime': runtimeEstimate,
        'Throttled samples': '$throttled of ${history.length}',
        'Worst thermal state': thermalStatusLabel(
          history
              .map((s) => s.thermalStatus ?? 0)
              .fold<int>(0, (a, b) => a > b ? a : b),
        ),
      },
      footnote: 'A steadily climbing RAM trend means a leak. Throttled samples '
          'mean the CPU is being clocked down, which shows up as rising RTF. '
          'Note the demo has no foreground service: with the screen off, '
          'Android will suspend capture regardless of these numbers.',
    );
  }
}

/// Where caption lag actually comes from, split into the parts we control.
class _LatencyCard extends StatelessWidget {
  const _LatencyCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final decodes = <int>[];
    final latencies = <int>[];
    for (final event in state.log.events) {
      if (event.kind != 'segment') continue;
      if (event.data['interim'] == true) continue;
      final decode = (event.data['decodeMs'] as num?)?.toInt();
      final latency = (event.data['latencyMs'] as num?)?.toInt();
      if (decode != null) decodes.add(decode);
      if (latency != null && latency > 0) latencies.add(latency);
    }

    if (latencies.isEmpty) {
      return const MetricsCard(
        title: 'Caption latency',
        rows: {'Status': 'No finalized captions yet'},
      );
    }

    latencies.sort();
    decodes.sort();
    int p(List<int> values, double fraction) =>
        values[((values.length - 1) * fraction).round()];

    final medianLatency = p(latencies, 0.5);
    final medianDecode = decodes.isEmpty ? 0 : p(decodes, 0.5);
    final vadWait = state.options.minSilenceMs;
    final unexplained = medianLatency - medianDecode - vadWait;

    return MetricsCard(
      title: 'Caption latency breakdown (median)',
      rows: {
        'End of speech → caption': '$medianLatency ms',
        'of which VAD silence wait': '$vadWait ms',
        'of which decode': '$medianDecode ms',
        'unaccounted (queue, IPC, UI)':
            '${unexplained > 0 ? unexplained : 0} ms',
        'p95 latency': '${p(latencies, 0.95)} ms',
        'Captions measured': '${latencies.length}',
      },
      footnote: 'If the silence wait dominates, lower "Silence to end an '
          'utterance" in Lab. If decode dominates, use a smaller model or '
          'more threads.',
    );
  }
}
