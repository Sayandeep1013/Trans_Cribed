/// The engine-agnostic transcription contract.
///
/// This file is THE integration seam: it is what gets copied into the main
/// Picaku app unchanged. The main app will hold two implementations behind it
/// (this repo's [SherpaMoonshineTranscriber] and the legacy whisper.cpp path
/// as a feature-flagged fallback). UI and repositories must only ever depend
/// on this interface, never on a concrete engine.
library;

import 'dart:async';

/// One finalized speech segment (a VAD-gated utterance).
class TranscriptSegment {
  const TranscriptSegment({
    required this.text,
    required this.start,
    required this.end,
    required this.decodeTime,
  });

  final String text;

  /// Position of the segment within the session's audio timeline.
  final Duration start;
  final Duration end;

  /// Wall-clock time the engine spent decoding this segment.
  final Duration decodeTime;

  Duration get audioLength => end - start;

  /// Real-time factor for this segment: decode time / audio time.
  /// < 1.0 means faster than real time. Target: < 0.3 (spec section 18).
  double get rtf => audioLength.inMilliseconds == 0
      ? 0
      : decodeTime.inMilliseconds / audioLength.inMilliseconds;
}

/// Final result of a transcription session.
class TranscriptResult {
  const TranscriptResult({
    required this.text,
    required this.segments,
    required this.audioDuration,
  });

  /// Plain text - what the main app POSTs to /api/notes/sync as `transcript`.
  final String text;
  final List<TranscriptSegment> segments;

  /// Total captured audio length - what the main app sends as
  /// `duration_seconds` (the referral system depends on it).
  final Duration audioDuration;

  double get durationSeconds => audioDuration.inMilliseconds / 1000.0;
}

/// Engine preparation metrics, surfaced so acceptance criteria are measurable.
class TranscriberStats {
  const TranscriberStats({
    required this.modelLoad,
    required this.warmup,
  });

  final Duration modelLoad;
  final Duration warmup;
}

abstract class Transcriber {
  /// Load models and warm up. Call once (app start / approaching the record
  /// screen), never per session. Safe to call again after [dispose].
  Future<TranscriberStats> prepare({void Function(String stage)? onProgress});

  bool get isReady;
  bool get isRecording;

  /// Live captions: emits each finalized utterance while recording.
  /// Errors on this stream are engine failures during a session.
  Stream<TranscriptSegment> get segments;

  /// Microphone level (RMS, 0..1), throttled to ~10 Hz while recording.
  /// Drives "the app hears you" UI so captions never feel dead.
  Stream<double> get audioLevel;

  /// True while the VAD detects ongoing speech (an utterance is being
  /// captured but not yet finalized). Drives a "transcribing…" pending UI.
  Stream<bool> get speechActive;

  /// Start capturing and transcribing. Throws [StateError] if not prepared,
  /// [MicPermissionDeniedException] if the mic permission is missing.
  Future<void> start();

  /// Stop capturing, flush the VAD tail, and return the assembled result.
  Future<TranscriptResult> stop();

  /// Release native resources. The instance can be [prepare]d again.
  Future<void> dispose();
}

class MicPermissionDeniedException implements Exception {
  const MicPermissionDeniedException();

  @override
  String toString() => 'Microphone permission denied';
}

/// Joins segment texts into the final plain transcript.
String assembleTranscript(Iterable<TranscriptSegment> segments) {
  return segments
      .map((s) => s.text.trim())
      .where((t) => t.isNotEmpty)
      .join(' ')
      .trim();
}
