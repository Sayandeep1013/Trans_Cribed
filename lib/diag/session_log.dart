/// A timestamped event log for everything the engine does.
///
/// The point is to make timing arguable with evidence instead of impressions.
/// "Captions feel late" becomes a row saying speech ended at 00:12.480 and the
/// caption landed 1,240 ms later, of which 310 ms was decode - so the delay is
/// the VAD's min-silence wait, not the model.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

class LogEvent {
  const LogEvent({
    required this.at,
    required this.kind,
    required this.data,
  });

  final DateTime at;

  /// Short machine-readable tag, e.g. `segment`, `model.load`, `resource`.
  final String kind;
  final Map<String, Object?> data;

  Map<String, Object?> toJson() => {
        'at': at.toIso8601String(),
        'kind': kind,
        ...data,
      };
}

class SessionLog extends ChangeNotifier {
  SessionLog({this.limit = 5000});

  /// Oldest events are dropped past this, so a soak test cannot exhaust RAM.
  final int limit;

  final List<LogEvent> _events = [];

  List<LogEvent> get events => List.unmodifiable(_events);
  int get length => _events.length;

  void add(String kind, [Map<String, Object?> data = const {}]) {
    _events.add(LogEvent(at: DateTime.now(), kind: kind, data: data));
    if (_events.length > limit) _events.removeAt(0);
    notifyListeners();
  }

  void clear() {
    _events.clear();
    notifyListeners();
  }

  /// Events newest-first, for display.
  List<LogEvent> get reversed => _events.reversed.toList(growable: false);

  String exportJson({Map<String, Object?> context = const {}}) {
    return const JsonEncoder.withIndent('  ').convert({
      'exportedAt': DateTime.now().toIso8601String(),
      ...context,
      'events': _events.map((e) => e.toJson()).toList(),
    });
  }
}
