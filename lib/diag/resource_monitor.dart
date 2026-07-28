/// What the app is costing the phone, sampled while it runs.
///
/// Two sources, both cheap:
///
///  * `/proc/self/*` and `dart:io`'s [ProcessInfo] - readable by any process
///    for itself, no permission, no plugin. Gives RAM, CPU and thread count.
///  * A tiny platform channel for the two things Android will not expose
///    through the filesystem: thermal throttle state and battery draw.
///
/// A note on GPU: there is nothing to report. sherpa-onnx runs on CPU via
/// XNNPACK (`provider: 'cpu'`) and the Flutter builds ship no NNAPI or GPU
/// delegate, so inference never touches the GPU. Any GPU activity on this app
/// is Flutter drawing the UI.
library;

import 'dart:async';
import 'dart:io';

import 'device_metrics.dart';

class ResourceSample {
  const ResourceSample({
    required this.at,
    required this.rssBytes,
    required this.peakRssBytes,
    required this.cpuPercentOfDevice,
    required this.cpuPercentOfCore,
    required this.threads,
    this.deviceTotalMb,
    this.deviceAvailMb,
    this.thermalStatus,
    this.batteryPercent,
    this.batteryCurrentUa,
    this.batteryTempC,
  });

  final DateTime at;

  /// Resident set size: physical RAM actually held, including native model
  /// memory. This is the number that matters for OOM risk.
  final int rssBytes;

  /// High-water mark since process start.
  final int peakRssBytes;

  /// Share of the whole device's CPU capacity (all cores = 100%).
  final double cpuPercentOfDevice;

  /// Share of a single core (can exceed 100% when decoding multi-threaded).
  final double cpuPercentOfCore;

  final int threads;

  final int? deviceTotalMb;
  final int? deviceAvailMb;

  /// Android PowerManager thermal status, 0 (none) to 6 (shutdown). Null when
  /// unavailable (below API 29, or non-Android).
  final int? thermalStatus;

  final int? batteryPercent;

  /// Instantaneous battery current in microamps. Negative = discharging on
  /// most devices, but sign conventions vary by vendor, so magnitude is the
  /// reliable part.
  final int? batteryCurrentUa;

  final double? batteryTempC;

  double get rssMb => rssBytes / 1048576;
  double get peakRssMb => peakRssBytes / 1048576;

  String get thermalLabel => thermalStatusLabel(thermalStatus);

  /// True once Android has begun throttling - the point at which RTF starts
  /// creeping up and a long session stops being sustainable.
  bool get isThrottling => (thermalStatus ?? 0) >= 2;

  Map<String, Object?> toJson() => {
        'at': at.toIso8601String(),
        'rssBytes': rssBytes,
        'peakRssBytes': peakRssBytes,
        'cpuPercentOfDevice': cpuPercentOfDevice,
        'cpuPercentOfCore': cpuPercentOfCore,
        'threads': threads,
        'deviceTotalMb': deviceTotalMb,
        'deviceAvailMb': deviceAvailMb,
        'thermalStatus': thermalStatus,
        'thermalLabel': thermalLabel,
        'batteryPercent': batteryPercent,
        'batteryCurrentUa': batteryCurrentUa,
        'batteryTempC': batteryTempC,
      };
}

String thermalStatusLabel(int? status) {
  return switch (status) {
    0 => 'None',
    1 => 'Light',
    2 => 'Moderate',
    3 => 'Severe',
    4 => 'Critical',
    5 => 'Emergency',
    6 => 'Shutdown',
    _ => 'Unavailable',
  };
}

class ResourceMonitor {
  ResourceMonitor({this.historyLimit = 2000});

  /// Kept so a long soak test can be exported as a curve, not just a snapshot.
  final int historyLimit;

  final StreamController<ResourceSample> _controller =
      StreamController<ResourceSample>.broadcast();
  final List<ResourceSample> _history = [];

  Timer? _timer;
  int? _lastCpuTicks;
  DateTime? _lastCpuAt;

  Stream<ResourceSample> get samples => _controller.stream;
  List<ResourceSample> get history => List.unmodifiable(_history);
  bool get isRunning => _timer != null;

  void start({Duration interval = const Duration(seconds: 2)}) {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) async {
      final sample = await read();
      if (_controller.isClosed) return;
      _history.add(sample);
      if (_history.length > historyLimit) _history.removeAt(0);
      _controller.add(sample);
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void clearHistory() => _history.clear();

  Future<ResourceSample> read() async {
    final now = DateTime.now();
    final procStat = _readProcSelfStat();
    final device = await DeviceMetrics.read();

    var cpuOfCore = 0.0;
    final ticks = procStat?.cpuTicks;
    if (ticks != null) {
      final lastTicks = _lastCpuTicks;
      final lastAt = _lastCpuAt;
      if (lastTicks != null && lastAt != null) {
        final elapsedSec = now.difference(lastAt).inMicroseconds / 1000000;
        if (elapsedSec > 0) {
          // USER_HZ is 100 on every Android build in practice.
          cpuOfCore = ((ticks - lastTicks) / 100) / elapsedSec * 100;
        }
      }
      _lastCpuTicks = ticks;
      _lastCpuAt = now;
    }

    final cores = Platform.numberOfProcessors;
    return ResourceSample(
      at: now,
      rssBytes: _safeRss(),
      peakRssBytes: _safeMaxRss(),
      cpuPercentOfCore: cpuOfCore,
      cpuPercentOfDevice: cores > 0 ? cpuOfCore / cores : cpuOfCore,
      threads: procStat?.threads ?? 0,
      deviceTotalMb: device.totalMemMb,
      deviceAvailMb: device.availMemMb,
      thermalStatus: device.thermalStatus,
      batteryPercent: device.batteryPercent,
      batteryCurrentUa: device.batteryCurrentUa,
      batteryTempC: device.batteryTempC,
    );
  }

  void dispose() {
    stop();
    unawaited(_controller.close());
  }
}

int _safeRss() {
  try {
    return ProcessInfo.currentRss;
  } catch (_) {
    return 0;
  }
}

int _safeMaxRss() {
  try {
    return ProcessInfo.maxRss;
  } catch (_) {
    return 0;
  }
}

class _ProcStat {
  const _ProcStat({required this.cpuTicks, required this.threads});

  final int cpuTicks;
  final int threads;
}

/// Parses `/proc/self/stat`.
///
/// The process name sits in field 2 wrapped in parentheses and may itself
/// contain spaces, so the only safe parse starts after the *last* ')'. From
/// there, field 3 is the state; utime/stime are fields 14/15 and num_threads
/// is field 20 in the kernel's 1-based numbering.
_ProcStat? _readProcSelfStat() {
  try {
    final raw = File('/proc/self/stat').readAsStringSync();
    final close = raw.lastIndexOf(')');
    if (close < 0) return null;
    final fields = raw.substring(close + 2).trim().split(RegExp(r'\s+'));
    // fields[0] is field 3, so field N lives at index N - 3.
    if (fields.length < 18) return null;
    final utime = int.tryParse(fields[11]) ?? 0;
    final stime = int.tryParse(fields[12]) ?? 0;
    final threads = int.tryParse(fields[17]) ?? 0;
    return _ProcStat(cpuTicks: utime + stime, threads: threads);
  } catch (_) {
    return null;
  }
}
