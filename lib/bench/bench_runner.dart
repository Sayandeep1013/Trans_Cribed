/// Re-decode stored audio with an arbitrary model and option set.
///
/// This is the core of honest comparison: instead of recording twice and
/// hoping you said it the same way, one recording is replayed through every
/// engine. Identical input means any difference in output is the model or the
/// settings, and nothing else.
///
/// Each run gets a fresh isolate that loads the model, decodes, reports, and
/// dies - so a 640 MB Parakeet does not stay resident after its row is done.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../engine/engine_core.dart';
import '../engine/engine_options.dart';
import '../models/model_catalog.dart';
import '../models/model_store.dart';
import '../transcriber/transcriber.dart';
import '../util/wav.dart';

class BenchRequest {
  const BenchRequest({
    required this.modelId,
    required this.modelName,
    required this.engineTypeName,
    required this.files,
    required this.vadPath,
    required this.numThreads,
    required this.options,
    required this.wavPath,
    this.hotwordsFile = '',
  });

  factory BenchRequest.forModel({
    required InstalledModel model,
    required EngineOptions options,
    required String wavPath,
    String hotwordsFile = '',
  }) {
    return BenchRequest(
      modelId: model.spec.id,
      modelName: model.spec.displayName,
      engineTypeName: model.spec.type.name,
      files: model.files,
      vadPath: model.sileroVad,
      numThreads: options.numThreadsOverride ?? model.spec.numThreads,
      // Interim captions are a live-UX feature; in a benchmark they would only
      // add decode work and duplicate text.
      options: options.copyWith(interimCaptionMs: 0),
      wavPath: wavPath,
      hotwordsFile: hotwordsFile,
    );
  }

  final String modelId;
  final String modelName;
  final String engineTypeName;
  final Map<String, String> files;
  final String vadPath;
  final int numThreads;
  final EngineOptions options;
  final String wavPath;
  final String hotwordsFile;
}

class BenchSegment {
  const BenchSegment({
    required this.text,
    required this.startMs,
    required this.endMs,
    required this.decodeMs,
    required this.rmsDb,
  });

  final String text;
  final int startMs;
  final int endMs;
  final int decodeMs;
  final double rmsDb;

  int get audioMs => endMs - startMs;
  double get rtf => audioMs == 0 ? 0 : decodeMs / audioMs;
}

class BenchResult {
  const BenchResult({
    required this.modelId,
    required this.modelName,
    required this.optionsLabel,
    required this.loadMs,
    required this.warmupMs,
    required this.decodeWallMs,
    required this.audioMs,
    required this.segments,
    required this.text,
    required this.rssDeltaBytes,
    this.error,
  });

  final String modelId;
  final String modelName;
  final String optionsLabel;

  final int loadMs;
  final int warmupMs;

  /// Wall-clock for the whole decode pass, excluding load and warmup.
  final int decodeWallMs;
  final int audioMs;

  final List<BenchSegment> segments;
  final String text;

  /// Resident memory growth across the run - what this model costs in RAM.
  final int rssDeltaBytes;

  final String? error;

  bool get ok => error == null;

  /// Total decode time over total audio time: the headline speed number.
  double get rtf => audioMs == 0 ? 0 : decodeWallMs / audioMs;

  double get rssDeltaMb => rssDeltaBytes / 1048576;

  Map<String, Object?> toJson() => {
        'modelId': modelId,
        'modelName': modelName,
        'options': optionsLabel,
        'loadMs': loadMs,
        'warmupMs': warmupMs,
        'decodeWallMs': decodeWallMs,
        'audioMs': audioMs,
        'rtf': rtf,
        'rssDeltaBytes': rssDeltaBytes,
        'segments': segments.length,
        'text': text,
        'error': error,
      };
}

/// How much audio is handed to the engine per step. Mirrors a realistic mic
/// frame so VAD behaviour matches a live session.
const int _feedChunkSamples = 1600; // 100 ms

Future<BenchResult> runBenchmark(BenchRequest request) =>
    Isolate.run(() => _benchmarkEntry(request));

BenchResult _benchmarkEntry(BenchRequest request) {
  final engine = EngineCore();
  final rssBefore = _currentRss();
  var rssPeak = rssBefore;

  try {
    final audio = decodeWavBytes(_readFileSync(request.wavPath));

    engine.init(
      engineType: EngineType.values.byName(request.engineTypeName),
      files: request.files,
      vadPath: request.vadPath,
      numThreads: request.numThreads,
      options: request.options,
      hotwordsFile: request.hotwordsFile,
    );

    final collected = <RawSegment>[];
    final watch = Stopwatch()..start();

    for (var offset = 0;
        offset < audio.samples.length;
        offset += _feedChunkSamples) {
      final end = offset + _feedChunkSamples > audio.samples.length
          ? audio.samples.length
          : offset + _feedChunkSamples;
      final chunk = Float32List.sublistView(audio.samples, offset, end);
      collected.addAll(engine.feed(chunk));

      if ((offset ~/ _feedChunkSamples) % 50 == 0) {
        final rss = _currentRss();
        if (rss > rssPeak) rssPeak = rss;
      }
    }
    collected.addAll(engine.flush());
    watch.stop();

    final rssAfter = _currentRss();
    if (rssAfter > rssPeak) rssPeak = rssAfter;

    final segments = [
      for (final s in collected)
        BenchSegment(
          text: s.text,
          startMs: s.startSample * 1000 ~/ engineSampleRate,
          endMs: s.endSample * 1000 ~/ engineSampleRate,
          decodeMs: s.decodeMs,
          rmsDb: s.rmsDb,
        ),
    ];

    return BenchResult(
      modelId: request.modelId,
      modelName: request.modelName,
      optionsLabel: request.options.shortLabel,
      loadMs: engine.loadMs,
      warmupMs: engine.warmupMs,
      decodeWallMs: watch.elapsedMilliseconds,
      audioMs: audio.duration.inMilliseconds,
      segments: segments,
      text: segments.map((s) => s.text.trim()).where((t) => t.isNotEmpty).join(' '),
      rssDeltaBytes: rssPeak - rssBefore,
    );
  } catch (e) {
    return BenchResult(
      modelId: request.modelId,
      modelName: request.modelName,
      optionsLabel: request.options.shortLabel,
      loadMs: 0,
      warmupMs: 0,
      decodeWallMs: 0,
      audioMs: 0,
      segments: const [],
      text: '',
      rssDeltaBytes: 0,
      error: e.toString(),
    );
  } finally {
    engine.free();
  }
}

Uint8List _readFileSync(String path) => File(path).readAsBytesSync();

/// Resident set size of the whole process. Isolates share an address space, so
/// this measures the model's real RAM cost, not just this isolate's heap.
int _currentRss() {
  try {
    return ProcessInfo.currentRss;
  } catch (_) {
    return 0;
  }
}

/// Turns a benchmark result into the same shape the live UI uses, so one set
/// of widgets renders both.
List<TranscriptSegment> benchSegmentsToTranscript(BenchResult result) {
  return [
    for (final s in result.segments)
      TranscriptSegment(
        text: s.text,
        start: Duration(milliseconds: s.startMs),
        end: Duration(milliseconds: s.endMs),
        decodeTime: Duration(milliseconds: s.decodeMs),
        rmsDb: s.rmsDb,
      ),
  ];
}
