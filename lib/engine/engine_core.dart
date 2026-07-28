/// The actual sherpa-onnx pipeline, isolated from *how* audio arrives.
///
/// Deliberately plugin-free (no path_provider, no method channels) so the same
/// code runs in the live capture isolate and in the benchmark isolate. That
/// shared use is the point: a re-decode of stored audio goes through the exact
/// path a live session does, so benchmark numbers are not a separate
/// approximation of reality.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../models/model_catalog.dart';
import '../util/dsp.dart';
import 'engine_options.dart';

const int engineSampleRate = 16000;

/// Silero requires exactly 512-sample windows at 16 kHz.
const int vadWindowSize = 512;

/// One decoded utterance, in engine terms (absolute sample indices).
class RawSegment {
  const RawSegment({
    required this.text,
    required this.startSample,
    required this.endSample,
    required this.decodeMs,
    required this.decodedSamples,
    required this.rmsDb,
    this.isInterim = false,
  });

  final String text;

  /// VAD boundaries - the *unpadded* speech, so timestamps stay truthful even
  /// when extra audio was fed to the decoder.
  final int startSample;
  final int endSample;

  final int decodeMs;

  /// How many samples the decoder actually saw (includes pre/post-roll).
  final int decodedSamples;

  /// Level of the decoded audio; low values explain bad transcriptions.
  final double rmsDb;

  /// Provisional caption for an utterance still in progress.
  final bool isInterim;

  int get audioMs => (endSample - startSample) * 1000 ~/ engineSampleRate;
}

class EngineCore {
  sherpa.OfflineRecognizer? _recognizer;
  sherpa.VoiceActivityDetector? _vad;

  EngineOptions _options = const EngineOptions();
  late AudioRing _ring;

  final List<double> _pending = <double>[];
  int _totalFed = 0;
  bool _speechActive = false;

  /// Absolute sample where the currently open utterance is estimated to start.
  int _openUtteranceStart = 0;

  /// Absolute sample at which the last interim caption was produced.
  int _lastInterimAt = 0;

  int loadMs = 0;
  int warmupMs = 0;

  EngineOptions get options => _options;
  bool get speechActive => _speechActive;
  int get totalSamples => _totalFed;

  int _msToSamples(int ms) => ms * engineSampleRate ~/ 1000;

  void init({
    required EngineType engineType,
    required Map<String, String> files,
    required String vadPath,
    required int numThreads,
    required EngineOptions options,
    String hotwordsFile = '',
  }) {
    _options = options;

    final loadWatch = Stopwatch()..start();
    sherpa.initBindings();

    final modelConfig = switch (engineType) {
      EngineType.moonshine => sherpa.OfflineModelConfig(
          moonshine: sherpa.OfflineMoonshineModelConfig(
            preprocessor: files['preprocess.onnx']!,
            encoder: files['encode.onnx']!,
            uncachedDecoder: files['uncached_decode.onnx']!,
            cachedDecoder: files['cached_decode.onnx']!,
          ),
          tokens: files['tokens.txt']!,
          numThreads: numThreads,
          debug: false,
        ),
      EngineType.nemoTransducer => sherpa.OfflineModelConfig(
          transducer: sherpa.OfflineTransducerModelConfig(
            encoder: files['encoder.onnx']!,
            decoder: files['decoder.onnx']!,
            joiner: files['joiner.onnx']!,
          ),
          tokens: files['tokens.txt']!,
          modelType: 'nemo_transducer',
          numThreads: numThreads,
          debug: false,
        ),
      EngineType.whisper => sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder: files['encoder.onnx']!,
            decoder: files['decoder.onnx']!,
            // Sanitized, never passed through raw: an unrecognized code makes
            // sherpa-onnx call _Exit(-1) mid-decode, which kills the app with
            // no Dart exception to catch. See sanitizeWhisperLanguage.
            language: sanitizeWhisperLanguage(options.whisperLanguage),
            task: sanitizeWhisperTask(options.whisperTask),
          ),
          tokens: files['tokens.txt']!,
          numThreads: numThreads,
          debug: false,
        ),
    };

    // Beam search and hotwords exist only for transducer models; asking an
    // attention decoder for them is a config error, so they are dropped.
    final transducer = engineType == EngineType.nemoTransducer;
    final decodingMethod =
        transducer ? options.decodingMethod : 'greedy_search';
    final useHotwords = transducer &&
        hotwordsFile.isNotEmpty &&
        decodingMethod == 'modified_beam_search';

    _recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: modelConfig,
        decodingMethod: decodingMethod,
        maxActivePaths: options.maxActivePaths,
        blankPenalty: options.blankPenalty,
        hotwordsFile: useHotwords ? hotwordsFile : '',
        hotwordsScore: options.hotwordsScore,
      ),
    );

    _vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: vadPath,
          threshold: options.vadThreshold,
          minSilenceDuration: options.minSilenceMs / 1000.0,
          minSpeechDuration: options.minSpeechMs / 1000.0,
          maxSpeechDuration: options.maxSpeechMs / 1000.0,
          windowSize: vadWindowSize,
        ),
        sampleRate: engineSampleRate,
        numThreads: 1,
        debug: false,
      ),
      bufferSizeInSeconds: 60,
    );

    // Ring must outlive the longest utterance plus its padding, or pre-roll
    // and interim captions would read past the retained window.
    final ringSeconds = (options.maxSpeechMs / 1000).ceil() + 8;
    _ring = AudioRing(ringSeconds * engineSampleRate);

    loadWatch.stop();
    loadMs = loadWatch.elapsedMilliseconds;

    // Warm up so the first real utterance does not pay one-time init costs.
    final warmupWatch = Stopwatch()..start();
    _decode(Float32List(engineSampleRate ~/ 2));
    warmupWatch.stop();
    warmupMs = warmupWatch.elapsedMilliseconds;
  }

  String _decode(Float32List samples) {
    final recognizer = _recognizer!;
    final stream = recognizer.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: engineSampleRate);
      recognizer.decode(stream);
      return recognizer.getResult(stream).text;
    } finally {
      stream.free();
    }
  }

  /// Pulls [from, to) out of the ring and applies the decode-time conditioning
  /// chain. Kept in one place so live and benchmark decoding cannot drift.
  Float32List _prepareAudio(int from, int to) {
    var audio = _ring.slice(from, to);
    if (audio.isEmpty) return audio;

    if (_options.highPass) {
      audio = highPassFilter(
        audio,
        cutoffHz: _options.highPassHz,
        sampleRate: engineSampleRate,
      );
    }
    if (_options.rmsNormalize) {
      audio = rmsNormalizeTo(audio, targetDb: _options.targetRmsDb);
    }
    return audio;
  }

  RawSegment? _decodeRange({
    required int speechStart,
    required int speechEnd,
    required bool isInterim,
  }) {
    final from = speechStart - _msToSamples(_options.preRollMs);
    final to = isInterim
        ? speechEnd
        : speechEnd + _msToSamples(_options.postRollMs);

    final audio = _prepareAudio(from, to);
    if (audio.isEmpty) return null;

    final watch = Stopwatch()..start();
    final text = _decode(audio);
    watch.stop();

    if (text.trim().isEmpty) return null;

    return RawSegment(
      text: text.trim(),
      startSample: speechStart,
      endSample: speechEnd,
      decodeMs: watch.elapsedMilliseconds,
      decodedSamples: audio.length,
      rmsDb: toDbfs(rms(audio)),
      isInterim: isInterim,
    );
  }

  /// Feeds captured audio and returns whatever captions became available.
  List<RawSegment> feed(Float32List samples) {
    _ring.add(samples);
    _totalFed += samples.length;
    _pending.addAll(samples);

    final vad = _vad!;
    while (_pending.length >= vadWindowSize) {
      final window = Float32List.fromList(_pending.sublist(0, vadWindowSize));
      _pending.removeRange(0, vadWindowSize);
      vad.acceptWaveform(window);
    }

    final out = <RawSegment>[];

    final active = vad.isDetected();
    if (active != _speechActive) {
      _speechActive = active;
      if (active) {
        // The VAD only reports speech after minSpeechDuration has elapsed, so
        // the utterance really began a little earlier than "now".
        _openUtteranceStart =
            math.max(0, _totalFed - _msToSamples(_options.minSpeechMs));
        _lastInterimAt = _totalFed;
      }
    }

    // Interim caption: keeps captions arriving on a fixed clock during fluent,
    // pause-free speech, which otherwise shows nothing until the VAD closes
    // the utterance at maxSpeechMs.
    if (active && _options.interimCaptionMs > 0) {
      final due = _lastInterimAt + _msToSamples(_options.interimCaptionMs);
      if (_totalFed >= due) {
        _lastInterimAt = _totalFed;
        final interim = _decodeRange(
          speechStart: _openUtteranceStart,
          speechEnd: _totalFed,
          isInterim: true,
        );
        if (interim != null) out.add(interim);
      }
    }

    out.addAll(_drainFinalized());
    return out;
  }

  List<RawSegment> _drainFinalized() {
    final vad = _vad!;
    final out = <RawSegment>[];
    while (!vad.isEmpty()) {
      final speech = vad.front();
      vad.pop();

      final segment = _decodeRange(
        speechStart: speech.start,
        speechEnd: speech.start + speech.samples.length,
        isInterim: false,
      );
      if (segment != null) out.add(segment);

      // A closed utterance restarts the interim clock for whatever follows.
      _lastInterimAt = _totalFed;
      _openUtteranceStart = _totalFed;
    }
    return out;
  }

  /// Closes the session: pads the partial VAD window, flushes, and decodes
  /// whatever was still open so the last words before Stop are not lost.
  List<RawSegment> flush() {
    final vad = _vad!;
    if (_pending.isNotEmpty) {
      final tail = Float32List(vadWindowSize)
        ..setRange(0, _pending.length, _pending);
      _pending.clear();
      vad.acceptWaveform(tail);
      _ring.add(tail);
      _totalFed += vadWindowSize;
    }
    vad.flush();
    final out = _drainFinalized();
    _speechActive = false;
    return out;
  }

  /// Starts a new session on an already-loaded engine (no reload cost).
  void resetSession() {
    _pending.clear();
    _vad?.reset();
    _speechActive = false;
    _openUtteranceStart = _totalFed;
    _lastInterimAt = _totalFed;
  }

  void free() {
    _vad?.free();
    _recognizer?.free();
    _vad = null;
    _recognizer = null;
  }
}
