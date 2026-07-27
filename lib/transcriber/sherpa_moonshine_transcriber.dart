import 'dart:async';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../audio/mic_capture.dart';
import 'model_assets.dart';
import 'transcriber.dart';

/// sherpa-onnx + Moonshine INT8 + Silero VAD implementation of [Transcriber].
///
/// Pipeline (spec: ON_DEVICE_TRANSCRIPTION.md section 7):
///   mic 16 kHz mono -> Silero VAD (512-sample windows) -> utterance segments
///   -> Moonshine offline decode (greedy) -> caption stream + transcript buffer
///
/// Load strategy (section 9): prepare() once, warmup inference included, then
/// the recognizer stays resident until dispose(). Never re-init per session.
///
/// Known demo simplification: decoding runs on the main isolate (same as the
/// official sherpa-onnx Flutter examples). Utterances are short so stalls are
/// tens to hundreds of ms. The production integration should move the engine
/// into a long-lived background isolate - noted in the integration plan.
class SherpaMoonshineTranscriber implements Transcriber {
  SherpaMoonshineTranscriber({this.numThreads = 2});

  final int numThreads;

  static const int _sampleRate = MicCapture.sampleRate;
  static const int _vadWindowSize = 512; // Silero v4/v5 requirement at 16 kHz

  sherpa.OfflineRecognizer? _recognizer;
  sherpa.VoiceActivityDetector? _vad;
  final MicCapture _mic = MicCapture();

  final List<double> _pendingSamples = [];
  final List<TranscriptSegment> _segments = [];
  StreamController<TranscriptSegment>? _segmentController;

  bool _ready = false;
  bool _recording = false;
  bool _processing = false;
  int _totalSamples = 0;

  @override
  bool get isReady => _ready;

  @override
  bool get isRecording => _recording;

  @override
  Stream<TranscriptSegment> get segments {
    _segmentController ??= StreamController<TranscriptSegment>.broadcast();
    return _segmentController!.stream;
  }

  @override
  Future<TranscriberStats> prepare({
    void Function(String stage)? onProgress,
  }) async {
    if (_ready) {
      return const TranscriberStats(
        modelLoad: Duration.zero,
        warmup: Duration.zero,
      );
    }

    onProgress?.call('Extracting models…');
    final paths = await extractModelAssets(onProgress: onProgress);

    onProgress?.call('Loading Moonshine…');
    final loadWatch = Stopwatch()..start();

    sherpa.initBindings();

    _recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          moonshine: sherpa.OfflineMoonshineModelConfig(
            preprocessor: paths.preprocessor,
            encoder: paths.encoder,
            uncachedDecoder: paths.uncachedDecoder,
            cachedDecoder: paths.cachedDecoder,
          ),
          tokens: paths.tokens,
          numThreads: numThreads,
          debug: false,
        ),
      ),
    );

    _vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: paths.sileroVad,
          minSilenceDuration: 0.4,
          minSpeechDuration: 0.25,
          maxSpeechDuration: 15.0,
          windowSize: _vadWindowSize,
        ),
        sampleRate: _sampleRate,
        numThreads: 1,
        debug: false,
      ),
      bufferSizeInSeconds: 60,
    );
    loadWatch.stop();

    // Warmup: pay the first-inference cost now, not on the user's first words.
    onProgress?.call('Warming up…');
    final warmupWatch = Stopwatch()..start();
    _decodeSamples(Float32List(_sampleRate ~/ 2)); // 0.5 s of silence
    warmupWatch.stop();

    _ready = true;
    return TranscriberStats(
      modelLoad: loadWatch.elapsed,
      warmup: warmupWatch.elapsed,
    );
  }

  @override
  Future<void> start() async {
    if (!_ready) throw StateError('prepare() must complete before start()');
    if (_recording) return;

    if (!await _mic.hasPermission()) {
      throw const MicPermissionDeniedException();
    }

    _segments.clear();
    _pendingSamples.clear();
    _totalSamples = 0;
    _recording = true;

    await _mic.start(_onFrame);
  }

  void _onFrame(Float32List frame) {
    if (!_recording) return;
    _pendingSamples.addAll(frame);
    _totalSamples += frame.length;
    _scheduleProcessing();
  }

  void _scheduleProcessing() {
    if (_processing) return;
    _processing = true;
    // Runs after the current event so mic callbacks are never blocked by decode.
    scheduleMicrotask(() {
      try {
        _feedVadAndDecode();
      } finally {
        _processing = false;
      }
    });
  }

  /// Feeds buffered audio to the VAD in the window size Silero requires, then
  /// decodes any utterances the VAD has finalized.
  void _feedVadAndDecode() {
    final vad = _vad;
    if (vad == null) return;

    while (_pendingSamples.length >= _vadWindowSize) {
      final window =
          Float32List.fromList(_pendingSamples.sublist(0, _vadWindowSize));
      _pendingSamples.removeRange(0, _vadWindowSize);
      vad.acceptWaveform(window);
    }
    _emitFinalizedSegments(vad);
  }

  void _emitFinalizedSegments(sherpa.VoiceActivityDetector vad) {
    while (!vad.isEmpty()) {
      final speech = vad.front();
      vad.pop();

      final startSample = speech.start;
      final samples = speech.samples;
      final decodeWatch = Stopwatch()..start();
      final text = _decodeSamples(samples);
      decodeWatch.stop();

      final segment = TranscriptSegment(
        text: text,
        start: _samplesToDuration(startSample),
        end: _samplesToDuration(startSample + samples.length),
        decodeTime: decodeWatch.elapsed,
      );
      if (segment.text.trim().isNotEmpty) {
        _segments.add(segment);
        _segmentController?.add(segment);
      }
    }
  }

  String _decodeSamples(Float32List samples) {
    final recognizer = _recognizer;
    if (recognizer == null) return '';
    final stream = recognizer.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: _sampleRate);
      recognizer.decode(stream);
      return recognizer.getResult(stream).text;
    } finally {
      stream.free();
    }
  }

  @override
  Future<TranscriptResult> stop() async {
    if (!_recording) {
      return TranscriptResult(
        text: assembleTranscript(_segments),
        segments: List.unmodifiable(_segments),
        audioDuration: _samplesToDuration(_totalSamples),
      );
    }

    _recording = false;
    await _mic.stop();

    // Flush: push whatever is buffered through the VAD and close the tail
    // segment so the last words before Stop are not lost.
    final vad = _vad;
    if (vad != null) {
      _feedVadAndDecode();
      if (_pendingSamples.isNotEmpty) {
        // Remainder shorter than one VAD window - pad to window size.
        final tail = Float32List(_vadWindowSize)
          ..setRange(0, _pendingSamples.length, _pendingSamples);
        _pendingSamples.clear();
        vad.acceptWaveform(tail);
      }
      vad.flush();
      _emitFinalizedSegments(vad);
    }

    return TranscriptResult(
      text: assembleTranscript(_segments),
      segments: List.unmodifiable(_segments),
      audioDuration: _samplesToDuration(_totalSamples),
    );
  }

  Duration _samplesToDuration(int samples) =>
      Duration(microseconds: samples * 1000000 ~/ _sampleRate);

  @override
  Future<void> dispose() async {
    _recording = false;
    await _mic.dispose();
    await _segmentController?.close();
    _segmentController = null;
    _vad?.free();
    _vad = null;
    _recognizer?.free();
    _recognizer = null;
    _ready = false;
  }
}
