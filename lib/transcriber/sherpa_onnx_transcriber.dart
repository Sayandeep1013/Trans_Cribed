import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../audio/mic_capture.dart';
import '../models/model_catalog.dart';
import '../models/model_store.dart';
import 'transcriber.dart';

/// sherpa-onnx implementation of [Transcriber], model-agnostic: builds the
/// right engine config from the model's [EngineType] (Moonshine, NeMo
/// transducer/Parakeet, ...). Every model of the same type runs through
/// identical code - only file paths differ.
///
/// The entire engine (model load, VAD, decoding) lives in a dedicated
/// long-lived background isolate, so the UI thread never blocks: loaders
/// animate during prepare, captions decode without jank, and Stop finalizes
/// behind a live spinner instead of freezing the screen.
///
/// Pipeline (spec: ON_DEVICE_TRANSCRIPTION.md section 7):
///   mic 16 kHz mono -> [isolate] Silero VAD (512-sample windows)
///   -> utterance segments -> offline decode (greedy)
///   -> caption stream + transcript buffer
class SherpaOnnxTranscriber implements Transcriber {
  SherpaOnnxTranscriber({required this.model});

  final InstalledModel model;

  final MicCapture _mic = MicCapture();

  Isolate? _isolate;
  SendPort? _commands;
  StreamSubscription<dynamic>? _replySub;

  final StreamController<TranscriptSegment> _segmentsCtrl =
      StreamController<TranscriptSegment>.broadcast();
  final StreamController<double> _levelCtrl =
      StreamController<double>.broadcast();
  final StreamController<bool> _speechCtrl =
      StreamController<bool>.broadcast();

  final List<TranscriptSegment> _sessionSegments = [];

  Completer<TranscriberStats>? _readyCompleter;
  Completer<int>? _stoppedCompleter; // completes with total session samples

  bool _ready = false;
  bool _recording = false;

  @override
  bool get isReady => _ready;

  @override
  bool get isRecording => _recording;

  @override
  Stream<TranscriptSegment> get segments => _segmentsCtrl.stream;

  @override
  Stream<double> get audioLevel => _levelCtrl.stream;

  @override
  Stream<bool> get speechActive => _speechCtrl.stream;

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

    onProgress?.call('Loading ${model.spec.displayName}…');

    final replies = ReceivePort();
    _isolate = await Isolate.spawn(_engineIsolateMain, replies.sendPort);

    _readyCompleter = Completer<TranscriberStats>();
    _replySub = replies.listen(_onEngineMessage);

    // First message from the isolate is its command port; init follows.
    final stats = await _readyCompleter!.future;
    _ready = true;
    return stats;
  }

  void _onEngineMessage(dynamic message) {
    if (message is SendPort) {
      _commands = message;
      message.send({
        'cmd': 'init',
        'engineType': model.spec.type.name,
        'files': model.files,
        'vad': model.sileroVad,
        'numThreads': model.spec.numThreads,
      });
      return;
    }

    final map = message as Map<dynamic, dynamic>;
    switch (map['type'] as String) {
      case 'ready':
        _readyCompleter?.complete(
          TranscriberStats(
            modelLoad: Duration(milliseconds: map['loadMs'] as int),
            warmup: Duration(milliseconds: map['warmupMs'] as int),
          ),
        );
      case 'initError':
        _readyCompleter?.completeError(StateError(map['error'] as String));
      case 'segment':
        final segment = TranscriptSegment(
          text: map['text'] as String,
          start: Duration(milliseconds: map['startMs'] as int),
          end: Duration(milliseconds: map['endMs'] as int),
          decodeTime: Duration(milliseconds: map['decodeMs'] as int),
        );
        _sessionSegments.add(segment);
        _segmentsCtrl.add(segment);
      case 'level':
        _levelCtrl.add(map['value'] as double);
      case 'speech':
        _speechCtrl.add(map['active'] as bool);
      case 'stopped':
        _stoppedCompleter?.complete(map['totalSamples'] as int);
      case 'error':
        final error = StateError(map['error'] as String);
        if (_stoppedCompleter?.isCompleted == false) {
          _stoppedCompleter!.completeError(error);
        } else {
          _segmentsCtrl.addError(error);
        }
    }
  }

  @override
  Future<void> start() async {
    if (!_ready) throw StateError('prepare() must complete before start()');
    if (_recording) return;
    if (!await _mic.hasPermission()) {
      throw const MicPermissionDeniedException();
    }

    _sessionSegments.clear();
    _commands!.send({'cmd': 'start'});
    _recording = true;
    await _mic.start((frame) {
      if (_recording) _commands?.send(frame);
    });
  }

  @override
  Future<TranscriptResult> stop() async {
    if (!_recording) {
      return TranscriptResult(
        text: assembleTranscript(_sessionSegments),
        segments: List.unmodifiable(_sessionSegments),
        audioDuration: Duration.zero,
      );
    }

    _recording = false;
    await _mic.stop();

    _stoppedCompleter = Completer<int>();
    _commands!.send({'cmd': 'stop'});
    final totalSamples = await _stoppedCompleter!.future;
    _speechCtrl.add(false);
    _levelCtrl.add(0);

    return TranscriptResult(
      text: assembleTranscript(_sessionSegments),
      segments: List.unmodifiable(_sessionSegments),
      audioDuration: Duration(
        microseconds: totalSamples * 1000000 ~/ MicCapture.sampleRate,
      ),
    );
  }

  @override
  Future<void> dispose() async {
    _recording = false;
    await _mic.dispose();
    _commands?.send({'cmd': 'dispose'});
    await _replySub?.cancel();
    _isolate?.kill(priority: Isolate.beforeNextEvent);
    _isolate = null;
    _commands = null;
    await _segmentsCtrl.close();
    await _levelCtrl.close();
    await _speechCtrl.close();
    _ready = false;
  }
}

// ---------------------------------------------------------------------------
// Engine isolate. Owns all native sherpa-onnx objects for its lifetime.
// ---------------------------------------------------------------------------

const int _sampleRate = MicCapture.sampleRate;
const int _vadWindowSize = 512; // Silero requirement at 16 kHz

void _engineIsolateMain(SendPort replyPort) {
  final commands = ReceivePort();
  replyPort.send(commands.sendPort);

  sherpa.OfflineRecognizer? recognizer;
  sherpa.VoiceActivityDetector? vad;

  final pending = <double>[];
  var totalSamplesFed = 0; // cumulative across sessions (VAD timeline)
  var sessionStartSample = 0;
  var speechWasActive = false;
  var lastLevelPostMs = 0;

  String decode(Float32List samples) {
    final stream = recognizer!.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: _sampleRate);
      recognizer!.decode(stream);
      return recognizer!.getResult(stream).text;
    } finally {
      stream.free();
    }
  }

  int toMs(int samples) => samples * 1000 ~/ _sampleRate;

  void emitFinalizedSegments() {
    final v = vad!;
    while (!v.isEmpty()) {
      final speech = v.front();
      v.pop();

      final watch = Stopwatch()..start();
      final text = decode(speech.samples);
      watch.stop();

      if (text.trim().isNotEmpty) {
        replyPort.send({
          'type': 'segment',
          'text': text,
          'startMs': toMs(speech.start - sessionStartSample),
          'endMs':
              toMs(speech.start + speech.samples.length - sessionStartSample),
          'decodeMs': watch.elapsedMilliseconds,
        });
      }
    }
  }

  void feedAndDecode() {
    final v = vad!;
    while (pending.length >= _vadWindowSize) {
      final window = Float32List.fromList(pending.sublist(0, _vadWindowSize));
      pending.removeRange(0, _vadWindowSize);
      v.acceptWaveform(window);
    }

    final active = v.isDetected();
    if (active != speechWasActive) {
      speechWasActive = active;
      replyPort.send({'type': 'speech', 'active': active});
    }

    emitFinalizedSegments();
  }

  commands.listen((dynamic message) {
    try {
      if (message is Float32List) {
        // Mic frame: level metering (throttled ~10 Hz) + VAD + decode.
        totalSamplesFed += message.length;
        var sumSquares = 0.0;
        for (final sample in message) {
          sumSquares += sample * sample;
        }
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - lastLevelPostMs >= 100) {
          lastLevelPostMs = nowMs;
          final rms = math.sqrt(sumSquares / message.length);
          // Speech RMS rarely exceeds ~0.35; scale to a usable 0..1.
          replyPort.send({
            'type': 'level',
            'value': (rms * 3).clamp(0.0, 1.0),
          });
        }
        pending.addAll(message);
        feedAndDecode();
        return;
      }

      final map = message as Map<dynamic, dynamic>;
      switch (map['cmd'] as String) {
        case 'init':
          try {
            final loadWatch = Stopwatch()..start();
            sherpa.initBindings();

            final files = (map['files'] as Map).cast<String, String>();
            final engineType = EngineType.values.byName(
              map['engineType'] as String,
            );
            final numThreads = map['numThreads'] as int;

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
            };

            recognizer = sherpa.OfflineRecognizer(
              sherpa.OfflineRecognizerConfig(model: modelConfig),
            );

            vad = sherpa.VoiceActivityDetector(
              config: sherpa.VadModelConfig(
                sileroVad: sherpa.SileroVadModelConfig(
                  model: map['vad'] as String,
                  minSilenceDuration: 0.35,
                  minSpeechDuration: 0.25,
                  // Cap utterances so captions land on a steady rhythm even
                  // during monologues (no pause = still a caption every ~8 s).
                  maxSpeechDuration: 8.0,
                  windowSize: _vadWindowSize,
                ),
                sampleRate: _sampleRate,
                numThreads: 1,
                debug: false,
              ),
              bufferSizeInSeconds: 60,
            );
            loadWatch.stop();

            // Warmup: pay the first-inference cost off-screen.
            final warmupWatch = Stopwatch()..start();
            decode(Float32List(_sampleRate ~/ 2));
            warmupWatch.stop();

            replyPort.send({
              'type': 'ready',
              'loadMs': loadWatch.elapsedMilliseconds,
              'warmupMs': warmupWatch.elapsedMilliseconds,
            });
          } catch (e) {
            replyPort.send({'type': 'initError', 'error': e.toString()});
          }
        case 'start':
          pending.clear();
          sessionStartSample = totalSamplesFed;
          speechWasActive = false;
        case 'stop':
          // Flush the VAD tail so the last words before Stop are kept.
          feedAndDecode();
          if (pending.isNotEmpty) {
            final tail = Float32List(_vadWindowSize)
              ..setRange(0, pending.length, pending);
            pending.clear();
            vad!.acceptWaveform(tail);
            totalSamplesFed += _vadWindowSize; // padded tail joins timeline
          }
          vad!.flush();
          emitFinalizedSegments();
          replyPort.send({
            'type': 'stopped',
            'totalSamples': totalSamplesFed - sessionStartSample,
          });
        case 'dispose':
          vad?.free();
          recognizer?.free();
          commands.close();
      }
    } catch (e) {
      replyPort.send({'type': 'error', 'error': e.toString()});
    }
  });
}
