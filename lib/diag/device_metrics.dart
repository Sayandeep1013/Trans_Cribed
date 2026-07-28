/// The two things Android refuses to expose through `/proc` to an ordinary
/// app: thermal throttle state and battery draw.
///
/// Thermal status is the one that answers "how long can this run without
/// interruption" - once the platform reports MODERATE, the CPU governor is
/// already clawing back clocks and RTF starts drifting upward. There is no
/// filesystem path for it (`/sys/class/thermal` is blocked on modern Android),
/// only `PowerManager.getCurrentThermalStatus()`.
///
/// Everything degrades to null rather than throwing, so the app still runs on
/// a platform without the channel.
library;

import 'package:flutter/services.dart';

class DeviceMetricsSnapshot {
  const DeviceMetricsSnapshot({
    this.totalMemMb,
    this.availMemMb,
    this.lowMemory,
    this.thermalStatus,
    this.batteryPercent,
    this.batteryCurrentUa,
    this.batteryTempC,
  });

  static const DeviceMetricsSnapshot empty = DeviceMetricsSnapshot();

  final int? totalMemMb;
  final int? availMemMb;

  /// Android's own judgement that the system is under memory pressure - the
  /// state right before background processes start getting killed.
  final bool? lowMemory;

  final int? thermalStatus;
  final int? batteryPercent;
  final int? batteryCurrentUa;
  final double? batteryTempC;

  bool get isAvailable => thermalStatus != null || totalMemMb != null;
}

class DeviceMetrics {
  static const MethodChannel _channel = MethodChannel('picaku/diag');

  static Future<DeviceMetricsSnapshot> read() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('read');
      if (map == null) return DeviceMetricsSnapshot.empty;
      return DeviceMetricsSnapshot(
        totalMemMb: map['totalMemMb'] as int?,
        availMemMb: map['availMemMb'] as int?,
        lowMemory: map['lowMemory'] as bool?,
        thermalStatus: map['thermalStatus'] as int?,
        batteryPercent: map['batteryPercent'] as int?,
        batteryCurrentUa: (map['batteryCurrentUa'] as num?)?.toInt(),
        batteryTempC: (map['batteryTempC'] as num?)?.toDouble(),
      );
    } catch (_) {
      return DeviceMetricsSnapshot.empty;
    }
  }

  /// Usable free bytes on the volume holding app storage, or null when the
  /// platform will not say.
  ///
  /// Null means "unknown", never "none": callers must treat it as permission
  /// to proceed, or a phone that declines to answer could never download a
  /// model at all.
  static Future<int?> freeBytes() async {
    try {
      final value = await _channel.invokeMethod<Object?>('freeBytes');
      return (value as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }
}
