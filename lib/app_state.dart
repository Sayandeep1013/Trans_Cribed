/// Single owner of engine, models, options, recordings and diagnostics.
///
/// The UI is throwaway demo scaffolding; this holds the state it renders. Kept
/// as one [ChangeNotifier] rather than a state-management package so nothing
/// here implies a dependency the main app would have to adopt.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'bench/bench_runner.dart';
import 'bench/passages.dart';
import 'bench/wer.dart';
import 'diag/resource_monitor.dart';
import 'diag/session_log.dart';
import 'engine/engine_options.dart';
import 'models/model_catalog.dart';
import 'models/model_store.dart';
import 'transcriber/sherpa_onnx_transcriber.dart';
import 'transcriber/transcriber.dart';

enum Phase {
  catalog,
  downloading,
  preparing,
  ready,
  recording,
  finalizing,
  done,
  error,
}

/// A completed recording, kept with its audio so it can be re-decoded.
class RecordedSession {
  RecordedSession({
    required this.id,
    required this.at,
    required this.modelId,
    required this.modelName,
    required this.wavPath,
    required this.audioDuration,
    required this.text,
    required this.segments,
    required this.optionsLabel,
    this.referenceText = '',
    this.passageId,
  });

  final String id;
  final DateTime at;
  final String modelId;
  final String modelName;

  /// Null when audio retention was off for this session.
  final String? wavPath;
  final Duration audioDuration;

  /// Transcript from the live run (the model named above).
  final String text;
  final List<TranscriptSegment> segments;
  final String optionsLabel;

  /// Ground truth, either typed in or taken from a read-aloud passage.
  String referenceText;
  String? passageId;

  /// Re-decodes of this same audio by other models / option sets.
  final List<BenchResult> benchRuns = [];

  bool get hasAudio => wavPath != null;
  bool get hasReference => referenceText.trim().isNotEmpty;

  ErrorRate? get liveWer =>
      hasReference ? wordErrorRate(referenceText, text) : null;
  ErrorRate? get liveCer =>
      hasReference ? characterErrorRate(referenceText, text) : null;

  ErrorRate? werFor(BenchResult run) =>
      hasReference ? wordErrorRate(referenceText, run.text) : null;
  ErrorRate? cerFor(BenchResult run) =>
      hasReference ? characterErrorRate(referenceText, run.text) : null;

  Map<String, Object?> toIndexJson() => {
        'id': id,
        'at': at.toIso8601String(),
        'modelId': modelId,
        'modelName': modelName,
        'wavPath': wavPath,
        'audioMs': audioDuration.inMilliseconds,
        'text': text,
        'optionsLabel': optionsLabel,
        'referenceText': referenceText,
        'passageId': passageId,
      };

  static RecordedSession fromIndexJson(Map<String, Object?> json) {
    return RecordedSession(
      id: json['id'] as String,
      at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
      modelId: json['modelId'] as String? ?? '',
      modelName: json['modelName'] as String? ?? 'unknown',
      wavPath: json['wavPath'] as String?,
      audioDuration:
          Duration(milliseconds: (json['audioMs'] as num?)?.toInt() ?? 0),
      text: json['text'] as String? ?? '',
      segments: const [],
      optionsLabel: json['optionsLabel'] as String? ?? '',
      referenceText: json['referenceText'] as String? ?? '',
      passageId: json['passageId'] as String?,
    );
  }
}

class AppState extends ChangeNotifier {
  final ModelStore store = ModelStore();
  final SessionLog log = SessionLog();
  final ResourceMonitor resources = ResourceMonitor();

  Phase phase = Phase.catalog;
  String stage = 'Starting…';
  String errorMessage = '';
  bool micDenied = false;

  Map<String, bool> installed = {};
  ModelSpec? activeSpec;
  Transcriber? _transcriber;
  TranscriberStats? stats;

  EngineOptions options = const EngineOptions();

  /// Retaining audio is what makes model comparison possible. It costs about
  /// 2 MB per minute; the main app will ship with this off.
  bool retainAudio = true;

  DownloadProgress? downloadProgress;
  ModelSpec? downloadingSpec;
  bool cancelRequested = false;

  final List<TranscriptSegment> liveSegments = [];
  TranscriptSegment? interim;
  double level = 0;
  bool speechActive = false;

  final List<RecordedSession> sessions = [];
  RecordedSession? lastSession;

  /// Passage selected for the next read-aloud run, if any.
  Passage? plannedPassage;

  bool benchRunning = false;
  String benchStage = '';

  ResourceSample? latestResource;

  StreamSubscription<TranscriptSegment>? _segmentSub;
  StreamSubscription<double>? _levelSub;
  StreamSubscription<bool>? _speechSub;
  StreamSubscription<ResourceSample>? _resourceSub;

  DateTime? recordingStartedAt;

  Directory? _supportDir;

  // --- lifecycle -----------------------------------------------------------

  Future<void> init() async {
    _supportDir = await getApplicationSupportDirectory();
    await _loadOptions();
    await _loadSessionIndex();

    _resourceSub = resources.samples.listen((sample) {
      latestResource = sample;
      // Only the interesting samples reach the log; a 2 s tick would drown it.
      if (sample.isThrottling || sample.rssMb > 1500) {
        log.add('resource.pressure', sample.toJson());
      }
      notifyListeners();
    });
    resources.start();

    await refreshInstalled();
    final selectedId = await store.getSelectedModelId();
    ModelSpec? toUse;
    for (final spec in modelCatalog) {
      if (installed[spec.id] == true &&
          (toUse == null || spec.id == selectedId)) {
        toUse = spec;
      }
    }
    if (toUse != null) {
      await useModel(toUse);
    } else {
      _setPhase(Phase.catalog);
    }
  }

  @override
  void dispose() {
    unawaited(_segmentSub?.cancel());
    unawaited(_levelSub?.cancel());
    unawaited(_speechSub?.cancel());
    unawaited(_resourceSub?.cancel());
    resources.dispose();
    unawaited(_transcriber?.dispose());
    super.dispose();
  }

  void _setPhase(Phase next) {
    phase = next;
    notifyListeners();
  }

  void _fail(String message, {bool mic = false}) {
    unawaited(WakelockPlus.disable());
    phase = Phase.error;
    micDenied = mic;
    errorMessage = message;
    log.add('error', {'message': message});
    notifyListeners();
  }

  // --- persistence ---------------------------------------------------------

  File _file(String name) =>
      File('${_supportDir!.path}${Platform.pathSeparator}$name');

  Future<void> _loadOptions() async {
    try {
      final f = _file('engine_options.json');
      if (!await f.exists()) return;
      final json = jsonDecode(await f.readAsString()) as Map<String, Object?>;
      options = EngineOptions.fromJson(json);
    } catch (_) {
      // A malformed file must never block startup; defaults are fine.
    }
  }

  Future<void> _saveOptions() async {
    try {
      await _file('engine_options.json').writeAsString(
        jsonEncode(options.toJson()),
      );
    } catch (_) {}
  }

  Future<void> _loadSessionIndex() async {
    try {
      final f = _file('sessions.json');
      if (!await f.exists()) return;
      final list = jsonDecode(await f.readAsString()) as List<dynamic>;
      for (final entry in list) {
        final session =
            RecordedSession.fromIndexJson(entry as Map<String, Object?>);
        // Drop entries whose audio the user (or the OS) has since removed.
        final path = session.wavPath;
        if (path != null && !File(path).existsSync()) continue;
        sessions.add(session);
      }
    } catch (_) {}
  }

  Future<void> _saveSessionIndex() async {
    try {
      await _file('sessions.json').writeAsString(
        jsonEncode(sessions.map((s) => s.toIndexJson()).toList()),
      );
    } catch (_) {}
  }

  Future<String> _writeHotwordsFile() async {
    final text = options.hotwords.trim();
    if (text.isEmpty) return '';
    final f = _file('hotwords.txt');
    await f.writeAsString('$text\n');
    return f.path;
  }

  // --- models --------------------------------------------------------------

  Future<void> refreshInstalled() async {
    final map = <String, bool>{};
    for (final spec in modelCatalog) {
      map[spec.id] = await store.isInstalled(spec);
    }
    installed = map;
    notifyListeners();
  }

  List<ModelSpec> get installedSpecs =>
      modelCatalog.where((s) => installed[s.id] == true).toList();

  Future<void> downloadModel(ModelSpec spec) async {
    phase = Phase.downloading;
    downloadingSpec = spec;
    downloadProgress = null;
    cancelRequested = false;
    notifyListeners();
    log.add('model.download.start', {'model': spec.id, 'mb': spec.approxMb});

    final watch = Stopwatch()..start();
    try {
      await store.download(
        spec,
        onProgress: (progress) {
          downloadProgress = progress;
          notifyListeners();
        },
        isCancelled: () => cancelRequested,
      );
      watch.stop();
      log.add('model.download.done', {
        'model': spec.id,
        'ms': watch.elapsedMilliseconds,
      });
      await refreshInstalled();
      await store.setSelectedModelId(spec.id);
      await useModel(spec);
    } on DownloadCancelled {
      log.add('model.download.cancelled', {'model': spec.id});
      _setPhase(Phase.catalog);
    } catch (e) {
      _fail(
        'Download failed: $e\n\nCheck your connection and retry - finished '
        'files are kept, so it resumes where it stopped.',
      );
    }
  }

  Future<void> useModel(ModelSpec spec) async {
    phase = Phase.preparing;
    stage = 'Loading ${spec.displayName}…';
    notifyListeners();

    try {
      await _segmentSub?.cancel();
      await _levelSub?.cancel();
      await _speechSub?.cancel();
      await _transcriber?.dispose();
      _transcriber = null;

      final model = await store.installedFor(spec);
      final transcriber = SherpaOnnxTranscriber(
        model: model,
        options: options,
        hotwordsFile: await _writeHotwordsFile(),
        sessionWavPath: null, // set per session in startRecording()
      );

      _wireStreams(transcriber);

      final loaded = await transcriber.prepare(
        onProgress: (s) {
          stage = s;
          notifyListeners();
        },
      );
      await store.setSelectedModelId(spec.id);

      _transcriber = transcriber;
      activeSpec = spec;
      stats = loaded;
      phase = Phase.ready;
      log.add('model.ready', {
        'model': spec.id,
        'loadMs': loaded.modelLoad.inMilliseconds,
        'warmupMs': loaded.warmup.inMilliseconds,
        'threads': options.numThreadsOverride ?? spec.numThreads,
      });
      notifyListeners();
    } catch (e) {
      _fail('Engine failed to load: $e');
    }
  }

  void _wireStreams(Transcriber transcriber) {
    _segmentSub = transcriber.segments.listen(
      (segment) {
        if (segment.isInterim) {
          interim = segment;
        } else {
          interim = null;
          liveSegments.insert(0, segment);
        }
        log.add('segment', {
          'interim': segment.isInterim,
          'startMs': segment.start.inMilliseconds,
          'endMs': segment.end.inMilliseconds,
          'decodeMs': segment.decodeTime.inMilliseconds,
          'latencyMs': segment.captionLatency.inMilliseconds,
          'rtf': segment.rtf,
          'rmsDb': segment.rmsDb,
          'chars': segment.text.length,
        });
        notifyListeners();
      },
      onError: (Object e) => _fail('Engine error during session: $e'),
    );
    _levelSub = transcriber.audioLevel.listen((value) {
      level = value;
      if (phase == Phase.recording) notifyListeners();
    });
    _speechSub = transcriber.speechActive.listen((active) {
      speechActive = active;
      if (!active) interim = null;
      notifyListeners();
    });
  }

  Future<void> deleteModel(ModelSpec spec) async {
    if (activeSpec?.id == spec.id) {
      await _segmentSub?.cancel();
      await _transcriber?.dispose();
      _transcriber = null;
      activeSpec = null;
      stats = null;
    }
    await store.delete(spec);
    log.add('model.deleted', {'model': spec.id});
    await refreshInstalled();
  }

  // --- options -------------------------------------------------------------

  /// Applying options means rebuilding the engine: VAD thresholds, thread
  /// count, decoding method and hotwords are all baked in at construction.
  Future<void> applyOptions(EngineOptions next) async {
    final needsReload = _requiresReload(options, next);
    options = next;
    await _saveOptions();
    log.add('options.changed', next.toJson());
    notifyListeners();

    final spec = activeSpec;
    if (needsReload && spec != null && phase != Phase.recording) {
      await useModel(spec);
    }
  }

  static bool _requiresReload(EngineOptions a, EngineOptions b) {
    return a.vadThreshold != b.vadThreshold ||
        a.minSilenceMs != b.minSilenceMs ||
        a.minSpeechMs != b.minSpeechMs ||
        a.maxSpeechMs != b.maxSpeechMs ||
        a.numThreadsOverride != b.numThreadsOverride ||
        a.decodingMethod != b.decodingMethod ||
        a.maxActivePaths != b.maxActivePaths ||
        a.blankPenalty != b.blankPenalty ||
        a.hotwords != b.hotwords ||
        a.hotwordsScore != b.hotwordsScore ||
        a.preRollMs != b.preRollMs ||
        a.postRollMs != b.postRollMs ||
        a.highPass != b.highPass ||
        a.highPassHz != b.highPassHz ||
        a.rmsNormalize != b.rmsNormalize ||
        a.targetRmsDb != b.targetRmsDb ||
        a.interimCaptionMs != b.interimCaptionMs;
  }

  void setRetainAudio(bool value) {
    retainAudio = value;
    notifyListeners();
  }

  void setPlannedPassage(Passage? passage) {
    plannedPassage = passage;
    notifyListeners();
  }

  // --- recording -----------------------------------------------------------

  Future<Directory> _sessionsDir() async {
    final dir = Directory(
      '${_supportDir!.path}${Platform.pathSeparator}sessions',
    );
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> startRecording() async {
    final spec = activeSpec;
    if (spec == null) return;

    try {
      liveSegments.clear();
      interim = null;

      String? wavPath;
      if (retainAudio) {
        final dir = await _sessionsDir();
        final stamp = DateTime.now().millisecondsSinceEpoch;
        wavPath = '${dir.path}${Platform.pathSeparator}session_$stamp.wav';
      }

      final transcriber = _transcriber;
      if (transcriber == null) {
        _fail('No engine loaded. Pick a model first.');
        return;
      }
      // Point the already-warm engine at this session's file. Deliberately not
      // a new transcriber: that would reload the model before every recording,
      // which is exactly the "no visible wait" criterion we have to meet.
      if (transcriber is SherpaOnnxTranscriber) {
        transcriber.sessionWavPath = wavPath;
      }

      await transcriber.start();
      // No foreground service by design (that shell lives in the main app), so
      // the screen must stay on or Android suspends capture.
      await WakelockPlus.enable();
      recordingStartedAt = DateTime.now();
      phase = Phase.recording;
      log.add('session.start', {
        'model': spec.id,
        'retainAudio': retainAudio,
        'options': options.toJson(),
        'passage': plannedPassage?.id,
      });
      notifyListeners();
    } on MicPermissionDeniedException {
      _fail(
        'Microphone permission is required. Grant it in system settings if '
        'the prompt no longer appears, then retry.',
        mic: true,
      );
    } catch (e) {
      _fail('Could not start recording: $e');
    }
  }

  Future<void> stopRecording() async {
    final transcriber = _transcriber;
    final spec = activeSpec;
    if (transcriber == null || spec == null) return;

    phase = Phase.finalizing;
    notifyListeners();
    await WakelockPlus.disable();

    try {
      final watch = Stopwatch()..start();
      final result = await transcriber.stop();
      watch.stop();

      final session = RecordedSession(
        id: 'S${DateTime.now().millisecondsSinceEpoch}',
        at: DateTime.now(),
        modelId: spec.id,
        modelName: spec.displayName,
        wavPath: result.audioPath,
        audioDuration: result.audioDuration,
        text: result.text,
        segments: result.segments,
        optionsLabel: options.shortLabel,
        referenceText: plannedPassage?.text ?? '',
        passageId: plannedPassage?.id,
      );
      sessions.insert(0, session);
      lastSession = session;
      await _saveSessionIndex();

      log.add('session.stop', {
        'model': spec.id,
        'audioMs': result.audioDuration.inMilliseconds,
        'segments': result.segments.length,
        'finalizeMs': watch.elapsedMilliseconds,
        'wav': result.audioPath,
      });

      interim = null;
      phase = Phase.done;
      notifyListeners();
    } catch (e) {
      _fail('Failed to finalize transcript: $e');
    }
  }

  void newSession() {
    liveSegments.clear();
    interim = null;
    phase = _transcriber == null ? Phase.catalog : Phase.ready;
    notifyListeners();
  }

  // --- benchmark -----------------------------------------------------------

  Future<void> setReference(RecordedSession session, String reference) async {
    session.referenceText = reference;
    await _saveSessionIndex();
    notifyListeners();
  }

  /// Re-decodes [session]'s audio with each of [specs], one at a time so peak
  /// RAM stays at a single model and the numbers are not distorted by
  /// contention between two engines.
  Future<void> runComparison(
    RecordedSession session,
    List<ModelSpec> specs, {
    EngineOptions? optionsOverride,
  }) async {
    final wavPath = session.wavPath;
    if (wavPath == null || benchRunning) return;

    benchRunning = true;
    session.benchRuns.clear();
    notifyListeners();

    final used = optionsOverride ?? options;
    final hotwords = await _writeHotwordsFile();

    for (final spec in specs) {
      benchStage = 'Decoding with ${spec.displayName}…';
      notifyListeners();

      final model = await store.installedFor(spec);
      final watch = Stopwatch()..start();
      final result = await runBenchmark(
        BenchRequest.forModel(
          model: model,
          options: used,
          wavPath: wavPath,
          hotwordsFile: hotwords,
        ),
      );
      watch.stop();

      session.benchRuns.add(result);
      log.add('bench.run', {
        ...result.toJson(),
        'wallMs': watch.elapsedMilliseconds,
        'wer': session.werFor(result)?.rate,
      });
      notifyListeners();
    }

    benchStage = '';
    benchRunning = false;
    notifyListeners();
  }

  Future<void> deleteSession(RecordedSession session) async {
    final path = session.wavPath;
    if (path != null) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    sessions.remove(session);
    if (lastSession == session) lastSession = null;
    await _saveSessionIndex();
    notifyListeners();
  }

  // --- export --------------------------------------------------------------

  String exportDiagnostics() {
    return log.exportJson(
      context: {
        'device': {
          'cores': Platform.numberOfProcessors,
          'os': Platform.operatingSystemVersion,
        },
        'activeModel': activeSpec?.id,
        'options': options.toJson(),
        'resources': resources.history.map((s) => s.toJson()).toList(),
        'sessions': [
          for (final s in sessions)
            {
              ...s.toIndexJson(),
              'liveWer': s.liveWer?.toJson(),
              'benchRuns': [
                for (final run in s.benchRuns)
                  {
                    ...run.toJson(),
                    'wer': s.werFor(run)?.toJson(),
                    'cer': s.cerFor(run)?.toJson(),
                  },
              ],
            },
        ],
      },
    );
  }
}
