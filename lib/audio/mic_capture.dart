import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../engine/engine_options.dart';

/// Thin wrapper over the `record` package: 16 kHz mono PCM16.
///
/// Raw bytes are handed on untouched so the engine isolate can both persist
/// them verbatim (for later re-decoding) and convert them for inference.
///
/// The platform voice-processing DSP (AGC / noise suppression / echo cancel)
/// is configurable rather than assumed: it is tuned for telephony and can
/// smear speech in ways ASR models dislike, so whether it helps is an
/// empirical question per device - see MODEL_OPTIMIZATION_STRATEGY.md. These
/// are the only settings that need a *re-recording* to compare, because
/// Android applies them before we ever receive samples.
class MicCapture {
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;

  static const int sampleRate = 16000;

  Future<bool> hasPermission() => _recorder.hasPermission();

  /// Starts streaming; [onBytes] receives raw little-endian PCM16 frames.
  Future<void> start({
    required void Function(Uint8List bytes) onBytes,
    EngineOptions options = const EngineOptions(),
  }) async {
    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        autoGain: options.micAutoGain,
        echoCancel: options.micEchoCancel,
        noiseSuppress: options.micNoiseSuppress,
      ),
    );
    _sub = stream.listen(onBytes);
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
