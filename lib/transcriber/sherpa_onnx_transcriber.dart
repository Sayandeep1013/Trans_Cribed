import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../audio/mic_capture.dart';
import '../engine/engine_core.dart';
import '../engine/engine_options.dart';
import '../models/model_catalog.dart';
import '../models/model_store.dart';
import '../util/dsp.dart';
import '../util/pcm.dart';
import '../util/wav.dart';
import 'transcriber.dart';

/// sherpa-onnx implementation of [Transcriber], model-agnostic: the engine
/// builds whatever config the model's [EngineType] needs (Moonshine, NeMo
/// transducer/Parakeet, Whisper). Every model of the same type runs through
/// identical code - only file paths differ.
///
/// The entire engine (model load, VAD, decoding, WAV writing) lives in a
/// dedicated long-lived background isolate, so the UI thread never blocks:
/// loaders animate during prepare, captions decode without jank, and Stop
/// finalizes behind a live spinner instead of freezing the screen.
///
/// Pipeline (spec: ON_DEVICE_TRANSCRIPTION.md section 7):
///   mic 16 kHz mono -> [isolate] Silero VAD (512-sample windows)
///   -> utterance segments (+ padding) -> offline decode
///   -> caption stream + transcript buffer
class SherpaOnnxTranscriber implements Transcriber {
  SherpaOnnxTranscriber({
    required this.model,
    this.options = const EngineOptions(),
    this.hotwordsFile = '',
    this.sessionWavPath,
  });

  final InstalledModel model;
  final EngineOptions options;

  /// Pre-written hotwords file (main isolate owns path resolution).
  final String hotwordsFile;

  /// When set, the session's raw audio is written here so it can be re-decoded
  /// by other models later. Null disables audio retention.
  ///
  /// Mutable on purpose: each session needs its own file, and the path is sent
  /// to the isolate with the `start` command rather than baked in at
  /// construction. Making it final would force a new transcriber - and so a
  /// full model reload - before every single recording.
  String? sessionWavPath;

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
  Completer<Map<dynamic, dynamic>>? _stoppedCompleter;

  bool _ready = false;
  bool _recording = false;

  /// Wall clock at which the current session's audio timeline starts, used to
  /// turn "audio ended at sample N" into a real caption-latency number.
  DateTime? _sessionStartedAt;

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
        'numThreads': options.numThreadsOverride ?? model.spec.numThreads,
        'options': options,
        'hotwordsFile': hotwordsFile,
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
        final start = Duration(milliseconds: map['startMs'] as int);
        final end = Duration(milliseconds: map['endMs'] as int);
        final isInterim = map['isInterim'] as bool;

        // Latency the user actually feels: from the moment the speech ended to
        // the moment the caption reached this isolate.
        var latency = Duration.zero;
        final startedAt = _sessionStartedAt;
        if (startedAt != null) {
          latency = DateTime.now().difference(startedAt.add(end));
          if (latency.isNegative) latency = Duration.zero;
        }

        final segment = TranscriptSegment(
          text: map['text'] as String,
          start: start,
          end: end,
          decodeTime: Duration(milliseconds: map['decodeMs'] as int),
          captionLatency: latency,
          isInterim: isInterim,
          rmsDb: map['rmsDb'] as double,
        );
        if (!isInterim) _sessionSegments.add(segment);
        _segmentsCtrl.add(segment);
      case 'level':
        _levelCtrl.add(map['value'] as double);
      case 'speech':
        _speechCtrl.add(map['active'] as bool);
      case 'stopped':
        _stoppedCompleter?.complete(map);
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
    _commands!.send({'cmd': 'start', 'wavPath': sessionWavPath});
    _recording = true;
    _sessionStartedAt = DateTime.now();
    await _mic.start(
      onBytes: (bytes) {
        if (_recording) _commands?.send(bytes);
      },
      options: options,
    );
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

    _stoppedCompleter = Completer<Map<dynamic, dynamic>>();
    _commands!.send({'cmd': 'stop'});
    final reply = await _stoppedCompleter!.future;
    _speechCtrl.add(false);
    _levelCtrl.add(0);

    final totalSamples = reply['totalSamples'] as int;
    return TranscriptResult(
      text: assembleTranscript(_sessionSegments),
      segments: List.unmodifiable(_sessionSegments),
      audioDuration: Duration(
        microseconds: totalSamples * 1000000 ~/ MicCapture.sampleRate,
      ),
      audioPath: reply['wavPath'] as String?,
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

void _engineIsolateMain(SendPort replyPort) {
  final commands = ReceivePort();
  replyPort.send(commands.sendPort);

  final engine = EngineCore();
  var sessionStartSample = 0;
  var lastLevelPostMs = 0;
  var speechWasActive = false;

  WavWriter? wavWriter;
  final pendingWrites = <Uint8List>[];
  var writing = false;

  // Serializes appends so mic frames never interleave mid-write.
  void pumpWrites() {
    if (writing || wavWriter == null || pendingWrites.isEmpty) return;
    writing = true;
    final chunk = pendingWrites.removeAt(0);
    wavWriter!.write(chunk).whenComplete(() {
      writing = false;
      pumpWrites();
    });
  }

  int toMs(int samples) => samples * 1000 ~/ engineSampleRate;

  void emit(List<RawSegment> segments) {
    for (final s in segments) {
      replyPort.send({
        'type': 'segment',
        'text': s.text,
        'startMs': toMs(s.startSample - sessionStartSample),
        'endMs': toMs(s.endSample - sessionStartSample),
        'decodeMs': s.decodeMs,
        'rmsDb': s.rmsDb,
        'isInterim': s.isInterim,
      });
    }
  }

  commands.listen((dynamic message) {
    try {
      if (message is Uint8List) {
        // Raw PCM16 from the mic: persist verbatim, then convert and decode.
        if (wavWriter != null) {
          pendingWrites.add(message);
          pumpWrites();
        }

        final frame = pcm16leToFloat32(message);

        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - lastLevelPostMs >= 100) {
          lastLevelPostMs = nowMs;
          // Speech RMS rarely exceeds ~0.35; scale to a usable 0..1.
          replyPort.send({
            'type': 'level',
            'value': (rms(frame) * 3).clamp(0.0, 1.0),
          });
        }

        final segments = engine.feed(frame);
        if (engine.speechActive != speechWasActive) {
          speechWasActive = engine.speechActive;
          replyPort.send({'type': 'speech', 'active': speechWasActive});
        }
        emit(segments);
        return;
      }

      final map = message as Map<dynamic, dynamic>;
      switch (map['cmd'] as String) {
        case 'init':
          try {
            engine.init(
              engineType: EngineType.values.byName(map['engineType'] as String),
              files: (map['files'] as Map).cast<String, String>(),
              vadPath: map['vad'] as String,
              numThreads: map['numThreads'] as int,
              options: map['options'] as EngineOptions,
              hotwordsFile: map['hotwordsFile'] as String,
            );
            replyPort.send({
              'type': 'ready',
              'loadMs': engine.loadMs,
              'warmupMs': engine.warmupMs,
            });
          } catch (e) {
            replyPort.send({'type': 'initError', 'error': e.toString()});
          }

        case 'start':
          sessionStartSample = engine.totalSamples;
          speechWasActive = false;
          engine.resetSession();

          final wavPath = map['wavPath'] as String?;
          if (wavPath != null) {
            WavWriter.create(wavPath, sampleRate: engineSampleRate)
                .then((writer) {
              wavWriter = writer;
              pumpWrites();
            });
          }

        case 'stop':
          emit(engine.flush());
          final totalSamples = engine.totalSamples - sessionStartSample;

          Future<void> finish() async {
            // Drain queued audio before sealing the RIFF header, or the tail
            // of the recording would be missing from the saved file.
            while (pendingWrites.isNotEmpty || writing) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
            final path = wavWriter?.path;
            await wavWriter?.close();
            wavWriter = null;
            replyPort.send({
              'type': 'stopped',
              'totalSamples': totalSamples,
              'wavPath': path,
            });
          }

          unawaited(finish());

        case 'dispose':
          unawaited(wavWriter?.close());
          wavWriter = null;
          engine.free();
          commands.close();
      }
    } catch (e) {
      replyPort.send({'type': 'error', 'error': e.toString()});
    }
  });
}
