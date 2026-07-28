import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../engine/engine_options.dart';
import '../models/model_catalog.dart';
import 'widgets.dart';

/// Where the actual experiments happen: turn a knob, re-decode the same
/// recording, read the WER delta. Nothing here is guesswork-friendly by
/// design - every control is paired with a way to measure whether it helped.
class LabPage extends StatefulWidget {
  const LabPage({super.key, required this.state});

  final AppState state;

  @override
  State<LabPage> createState() => _LabPageState();
}

class _LabPageState extends State<LabPage> {
  AppState get s => widget.state;

  bool _showAdvanced = false;

  Future<void> _update(EngineOptions next) => s.applyOptions(next);

  @override
  Widget build(BuildContext context) {
    final options = s.options;
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Changing any decode setting reloads the engine (about as long '
              'as a model load). Capture settings at the bottom need a fresh '
              'recording to compare, because Android applies them before the '
              'app receives audio.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ),

        // --- captions ------------------------------------------------------
        const SectionHeader(
          title: 'Caption rhythm',
          explanation:
              'Captions normally appear only when you pause. Interim captions '
              'add a fixed clock on top, so fluent speech still updates the '
              'screen. Costs one extra decode per interval.',
        ),
        LabeledSlider(
          label: 'Interim caption interval',
          value: options.interimCaptionMs.toDouble(),
          min: 0,
          max: 20000,
          divisions: 20,
          format: (v) => v == 0 ? 'Off' : '${(v / 1000).round()} s',
          help: options.interimCaptionMs == 0
              ? 'Off: nothing appears until you pause or hit the max '
                  'utterance length.'
              : 'A provisional caption every '
                  '${(options.interimCaptionMs / 1000).round()} s while you '
                  'keep talking, replaced by the final text at the pause.',
          onCommit: (v) =>
              _update(options.copyWith(interimCaptionMs: v.round())),
        ),
        LabeledSlider(
          label: 'Max utterance length',
          value: options.maxSpeechMs.toDouble(),
          min: 4000,
          max: 30000,
          divisions: 26,
          format: (v) => '${(v / 1000).round()} s',
          help: 'Hard cut for pause-free speech. Longer gives the model more '
              'context (better accuracy) but a slower final decode.',
          onCommit: (v) => _update(options.copyWith(maxSpeechMs: v.round())),
        ),
        LabeledSlider(
          label: 'Silence to end an utterance',
          value: options.minSilenceMs.toDouble(),
          min: 100,
          max: 1500,
          divisions: 28,
          format: (v) => '${v.round()} ms',
          help: 'The dominant term in caption lag. Lower feels snappier and '
              'splits sentences more often.',
          onCommit: (v) => _update(options.copyWith(minSilenceMs: v.round())),
        ),

        // --- accuracy ------------------------------------------------------
        const SectionHeader(
          title: 'Accuracy levers',
          explanation:
              'Applied to audio the app already holds, so the same recording '
              'can be re-decoded with different values and compared exactly.',
        ),
        LabeledSlider(
          label: 'Pre-roll padding',
          value: options.preRollMs.toDouble(),
          min: 0,
          max: 600,
          divisions: 12,
          format: (v) => '${v.round()} ms',
          help: 'Audio kept from *before* the VAD triggered. Without it, word '
              'onsets get clipped - the most likely cause of dropped first '
              'words.',
          onCommit: (v) => _update(options.copyWith(preRollMs: v.round())),
        ),
        LabeledSlider(
          label: 'Post-roll padding',
          value: options.postRollMs.toDouble(),
          min: 0,
          max: 600,
          divisions: 12,
          format: (v) => '${v.round()} ms',
          help: 'Audio kept after speech ends, so trailing consonants survive.',
          onCommit: (v) => _update(options.copyWith(postRollMs: v.round())),
        ),
        LabeledSlider(
          label: 'VAD sensitivity threshold',
          value: options.vadThreshold,
          min: 0.1,
          max: 0.9,
          divisions: 16,
          format: (v) => v.toStringAsFixed(2),
          help: 'Lower catches soft or distant speech, at the cost of '
              'triggering on noise.',
          onCommit: (v) => _update(options.copyWith(vadThreshold: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('High-pass filter'),
          subtitle: Text(
            'Removes DC offset and handling rumble below '
            '${options.highPassHz.round()} Hz.',
          ),
          value: options.highPass,
          onChanged: (v) => _update(options.copyWith(highPass: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Normalize utterance level'),
          subtitle: Text(
            'Scales each utterance to ${options.targetRmsDb.round()} dBFS. '
            'Helps quiet speakers; can lift noise.',
          ),
          value: options.rmsNormalize,
          onChanged: (v) => _update(options.copyWith(rmsNormalize: v)),
        ),

        // --- advanced ------------------------------------------------------
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
          icon: Icon(_showAdvanced ? Icons.expand_less : Icons.expand_more),
          label: Text(_showAdvanced ? 'Hide advanced' : 'Advanced decoding'),
        ),
        if (_showAdvanced) ..._buildAdvanced(options),

        // --- capture -------------------------------------------------------
        const SectionHeader(
          title: 'Capture DSP (needs re-recording to compare)',
          explanation:
              'Android applies these before the app sees any audio, so they '
              'cannot be A/B tested on a stored recording. They are tuned for '
              'phone calls, and suppression in particular can smear speech in '
              'ways ASR models dislike - worth testing off.',
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Automatic gain control'),
          value: options.micAutoGain,
          onChanged: (v) => _update(options.copyWith(micAutoGain: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Noise suppression'),
          value: options.micNoiseSuppress,
          onChanged: (v) => _update(options.copyWith(micNoiseSuppress: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Echo cancellation'),
          value: options.micEchoCancel,
          onChanged: (v) => _update(options.copyWith(micEchoCancel: v)),
        ),

        // --- storage -------------------------------------------------------
        const SectionHeader(
          title: 'Audio retention',
          explanation:
              'Keeping session audio (~2 MB per minute) is what makes model '
              'comparison possible at all. The main app ships with this off.',
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Keep session audio'),
          value: s.retainAudio,
          onChanged: s.setRetainAudio,
        ),

        // --- recordings ----------------------------------------------------
        const SectionHeader(
          title: 'Recordings',
          explanation:
              'Re-decode a saved recording with other models. Identical audio '
              'in means any difference in the text out is the model, not how '
              'you happened to speak that time.',
        ),
        if (s.benchRunning)
          Card(
            child: ListTile(
              leading: const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              title: Text(s.benchStage),
              subtitle: const Text('Loading and decoding, one model at a time'),
            ),
          ),
        if (s.sessions.isEmpty)
          const Card(
            child: ListTile(
              title: Text('No recordings yet'),
              subtitle: Text(
                'Record something on the Record tab with audio retention on.',
              ),
            ),
          ),
        for (final session in s.sessions)
          _SessionCard(
            state: s,
            session: session,
            onRefresh: () => setState(() {}),
          ),
        const SizedBox(height: 32),
      ],
    );
  }

  List<Widget> _buildAdvanced(EngineOptions options) {
    final transducerActive = s.activeSpec?.type == EngineType.nemoTransducer;
    return [
      LabeledSlider(
        label: 'Min utterance length',
        value: options.minSpeechMs.toDouble(),
        min: 50,
        max: 800,
        divisions: 15,
        format: (v) => '${v.round()} ms',
        help: 'Anything shorter is discarded as noise.',
        onCommit: (v) => _update(options.copyWith(minSpeechMs: v.round())),
      ),
      LabeledSlider(
        label: 'Decode threads',
        value: (options.numThreadsOverride ?? 0).toDouble(),
        min: 0,
        max: 8,
        divisions: 8,
        format: (v) => v.round() == 0
            ? 'Model default (${s.activeSpec?.numThreads ?? 2})'
            : '${v.round()}',
        help: 'More threads cut decode time until memory bandwidth or thermal '
            'limits bite - past that they only add heat.',
        onCommit: (v) => _update(
          v.round() == 0
              ? options.copyWith(clearNumThreadsOverride: true)
              : options.copyWith(numThreadsOverride: v.round()),
        ),
      ),
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Transducer-only options',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                transducerActive
                    ? 'Available: ${s.activeSpec!.displayName} is a transducer.'
                    : 'Ignored for ${s.activeSpec?.displayName ?? 'this model'}'
                        ' — beam search and hotwords exist only for transducer '
                        'models (Parakeet). Moonshine and Whisper are '
                        'attention decoders and always run greedy.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Beam search'),
                subtitle: const Text(
                  'Slower than greedy, usually a small accuracy gain, and '
                  'required for hotwords to work.',
                ),
                value: options.decodingMethod == 'modified_beam_search',
                onChanged: (v) => _update(
                  options.copyWith(
                    decodingMethod:
                        v ? 'modified_beam_search' : 'greedy_search',
                  ),
                ),
              ),
              TextFormField(
                initialValue: options.hotwords,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Hotwords (one phrase per line)',
                  helperText:
                      'Contextual biasing for names, products and jargon — '
                      'the biggest single accuracy lever for meeting speech.',
                  border: OutlineInputBorder(),
                ),
                onFieldSubmitted: (value) =>
                    _update(options.copyWith(hotwords: value)),
              ),
            ],
          ),
        ),
      ),
    ];
  }
}

class _SessionCard extends StatefulWidget {
  const _SessionCard({
    required this.state,
    required this.session,
    required this.onRefresh,
  });

  final AppState state;
  final RecordedSession session;
  final VoidCallback onRefresh;

  @override
  State<_SessionCard> createState() => _SessionCardState();
}

class _SessionCardState extends State<_SessionCard> {
  late final TextEditingController _reference =
      TextEditingController(text: widget.session.referenceText);
  bool _editingReference = false;

  @override
  void dispose() {
    _reference.dispose();
    super.dispose();
  }

  Future<void> _compare() async {
    final specs = widget.state.installedSpecs;
    if (specs.isEmpty) return;

    final chosen = await showDialog<List<ModelSpec>>(
      context: context,
      builder: (dialogContext) => _ModelPickerDialog(specs: specs),
    );
    if (chosen == null || chosen.isEmpty) return;
    await widget.state.runComparison(widget.session, chosen);
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${session.modelName} · '
                    '${(session.audioDuration.inMilliseconds / 1000).toStringAsFixed(1)}s',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () =>
                      unawaited(widget.state.deleteSession(session)),
                ),
              ],
            ),
            Text(
              '${formatClock(session.at)} · ${session.optionsLabel}',
              style: theme.textTheme.labelSmall,
            ),
            const SizedBox(height: 8),
            Text(
              session.text.isEmpty ? '(no speech detected)' : session.text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),

            // Reference text: typed in, or already known from a passage.
            if (session.passageId != null && !_editingReference)
              Text(
                'Reference: read-aloud passage "${session.passageId}" — '
                'scored automatically.',
                style: theme.textTheme.labelSmall,
              )
            else if (!_editingReference)
              TextButton.icon(
                onPressed: () => setState(() => _editingReference = true),
                icon: const Icon(Icons.rule),
                label: Text(
                  session.hasReference
                      ? 'Edit reference text'
                      : 'Add reference text to score accuracy',
                ),
              )
            else ...[
              TextField(
                controller: _reference,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'What was actually said',
                  helperText:
                      'Type it exactly; punctuation and case are ignored '
                      'when scoring.',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  FilledButton(
                    onPressed: () async {
                      await widget.state
                          .setReference(session, _reference.text);
                      if (mounted) setState(() => _editingReference = false);
                    },
                    child: const Text('Save'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () =>
                        setState(() => _editingReference = false),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ],

            if (session.hasReference) ...[
              const SizedBox(height: 4),
              Builder(
                builder: (context) {
                  final wer = session.liveWer!;
                  final cer = session.liveCer!;
                  return Text(
                    'Live run: WER ${wer.percent} · CER ${cer.percent}'
                    '${wer.hasBreakdown ? ' (${wer.substitutions}S '
                        '${wer.deletions}D ${wer.insertions}I)' : ''}',
                    style: theme.textTheme.labelMedium,
                  );
                },
              ),
            ],

            const SizedBox(height: 8),
            if (session.hasAudio)
              FilledButton.tonalIcon(
                onPressed: widget.state.benchRunning ? null : _compare,
                icon: const Icon(Icons.compare_arrows),
                label: const Text('Re-decode with other models'),
              )
            else
              Text(
                'No audio kept for this session — cannot re-decode.',
                style: theme.textTheme.labelSmall,
              ),

            if (session.benchRuns.isNotEmpty) ...[
              const SizedBox(height: 12),
              _BenchTable(session: session),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => unawaited(_copyResults(session)),
                icon: const Icon(Icons.copy),
                label: const Text('Copy comparison'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _copyResults(RecordedSession session) async {
    final buffer = StringBuffer()
      ..writeln('Picaku STT comparison — ${formatClock(session.at)}')
      ..writeln('Audio: '
          '${(session.audioDuration.inMilliseconds / 1000).toStringAsFixed(1)}s')
      ..writeln('Settings: ${session.optionsLabel}')
      ..writeln();
    for (final run in session.benchRuns) {
      final wer = session.werFor(run);
      buffer
        ..writeln('## ${run.modelName}')
        ..writeln('load ${run.loadMs} ms · warmup ${run.warmupMs} ms · '
            'RTF ${run.rtf.toStringAsFixed(3)} · '
            'RAM +${run.rssDeltaMb.toStringAsFixed(0)} MB'
            '${wer != null ? ' · WER ${wer.percent}' : ''}')
        ..writeln(run.error ?? run.text)
        ..writeln();
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Comparison copied')),
    );
  }
}

class _BenchTable extends StatelessWidget {
  const _BenchTable({required this.session});

  final RecordedSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columnSpacing: 18,
            headingRowHeight: 32,
            dataRowMinHeight: 32,
            dataRowMaxHeight: 44,
            columns: const [
              DataColumn(label: Text('Model')),
              DataColumn(label: Text('RTF')),
              DataColumn(label: Text('Load')),
              DataColumn(label: Text('RAM')),
              DataColumn(label: Text('WER')),
            ],
            rows: [
              for (final run in session.benchRuns)
                DataRow(
                  cells: [
                    DataCell(Text(run.modelName, style: theme.textTheme.bodySmall)),
                    DataCell(Text(run.ok ? run.rtf.toStringAsFixed(3) : '—')),
                    DataCell(Text(run.ok ? '${run.loadMs} ms' : '—')),
                    DataCell(
                      Text(
                        run.ok
                            ? '+${run.rssDeltaMb.toStringAsFixed(0)} MB'
                            : '—',
                      ),
                    ),
                    DataCell(
                      Text(session.werFor(run)?.percent ?? '—'),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        for (final run in session.benchRuns)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(run.modelName, style: theme.textTheme.labelMedium),
                SelectableText(
                  run.error != null
                      ? 'Failed: ${run.error}'
                      : (run.text.isEmpty ? '(no speech detected)' : run.text),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ModelPickerDialog extends StatefulWidget {
  const _ModelPickerDialog({required this.specs});

  final List<ModelSpec> specs;

  @override
  State<_ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _ModelPickerDialogState extends State<_ModelPickerDialog> {
  late final Set<String> _selected = widget.specs.map((s) => s.id).toSet();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Re-decode with'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Each model loads, decodes the same audio, then unloads. Large '
            'models take a while.',
          ),
          const SizedBox(height: 8),
          for (final spec in widget.specs)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(spec.displayName),
              subtitle: Text('~${spec.approxMb} MB'),
              value: _selected.contains(spec.id),
              onChanged: (value) => setState(() {
                if (value == true) {
                  _selected.add(spec.id);
                } else {
                  _selected.remove(spec.id);
                }
              }),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            widget.specs.where((s) => _selected.contains(s.id)).toList(),
          ),
          child: const Text('Run'),
        ),
      ],
    );
  }
}
