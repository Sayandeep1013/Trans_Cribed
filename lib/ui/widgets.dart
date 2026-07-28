import 'package:flutter/material.dart';

String formatDuration(Duration d) {
  final minutes = d.inMinutes.toString().padLeft(2, '0');
  final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

String formatClock(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}'
      '.${t.millisecond.toString().padLeft(3, '0')}';
}

String formatMb(num mb) => '${mb.toStringAsFixed(0)} MB';

class MetricsCard extends StatelessWidget {
  const MetricsCard({
    super.key,
    required this.title,
    required this.rows,
    this.trailing,
    this.footnote,
  });

  final String title;
  final Map<String, String> rows;
  final Widget? trailing;
  final String? footnote;

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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(entry.key, style: textTheme.bodyMedium),
                    ),
                    Text(
                      entry.value,
                      style: textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            if (footnote != null) ...[
              const SizedBox(height: 8),
              Text(footnote!, style: textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

/// Section header + explanation, used throughout the Lab so every knob says
/// what it actually does rather than relying on the reader knowing.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    required this.explanation,
  });

  final String title;
  final String explanation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 2),
          Text(explanation, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// A slider that commits only when the finger lifts.
///
/// This matters more than it looks: applying an engine option rebuilds the
/// recognizer, so committing on every drag frame would fire dozens of model
/// reloads across a single swipe. The label tracks the finger live; only
/// [onCommit] reaches the engine.
class LabeledSlider extends StatefulWidget {
  const LabeledSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.format,
    required this.onCommit,
    this.help,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;

  /// Renders the current (possibly mid-drag) value.
  final String Function(double value) format;

  final ValueChanged<double> onCommit;
  final String? help;

  @override
  State<LabeledSlider> createState() => _LabeledSliderState();
}

class _LabeledSliderState extends State<LabeledSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = (_dragging ?? widget.value).clamp(widget.min, widget.max);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(widget.label, style: theme.textTheme.bodyMedium),
            ),
            Text(
              widget.format(shown),
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        Slider(
          value: shown,
          min: widget.min,
          max: widget.max,
          divisions: widget.divisions,
          onChanged: (v) => setState(() => _dragging = v),
          onChangeEnd: (v) {
            setState(() => _dragging = null);
            widget.onCommit(v);
          },
        ),
        if (widget.help != null)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Text(widget.help!, style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }
}
