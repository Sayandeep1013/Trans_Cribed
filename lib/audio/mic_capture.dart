import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../util/pcm.dart';

/// Thin wrapper over the `record` package: 16 kHz mono PCM16 stream converted
/// to Float32 frames. Same package and config as the main Picaku app, minus
/// the DSP flags (kept default here; tune during benchmarking).
class MicCapture {
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;

  static const int sampleRate = 16000;

  Future<bool> hasPermission() => _recorder.hasPermission();

  /// Starts streaming; [onFrame] receives normalized Float32 samples.
  Future<void> start(void Function(Float32List frame) onFrame) async {
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
      ),
    );
    _sub = stream.listen((bytes) => onFrame(pcm16leToFloat32(bytes)));
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    await _recorder.stop();
  }

  Future<void> dispose() async {
    await stop();
    await _recorder.dispose();
  }
}
