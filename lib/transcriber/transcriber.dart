/// The engine-agnostic transcription contract.
///
/// This file is THE integration seam: it is what gets copied into the main
/// Picaku app unchanged. The main app will hold two implementations behind it
/// (this repo's [SherpaMoonshineTranscriber] and the legacy whisper.cpp path
/// as a feature-flagged fallback). UI and repositories must only ever depend
/// on this interface, never on a concrete engine.
library;

import 'dart:async';

/// One speech segment (a VAD-gated utterance, or a provisional slice of one).
class TranscriptSegment {
  const TranscriptSegment({
    required this.text,
    required this.start,
    required this.end,
    required this.decodeTime,
    this.captionLatency = Duration.zero,
    this.isInterim = false,
    this.rmsDb = 0,
  });

  final String text;

  /// Position of the segment within the session's audio timeline.
  final Duration start;
  final Duration end;

  /// Wall-clock time the engine spent decoding this segment.
  final Duration decodeTime;

  /// End of the spoken audio to caption available - what the user actually
  /// perceives as lag. Includes the VAD's min-silence wait, queueing and
  /// decode, so it is always larger than [decodeTime].
  final Duration captionLatency;

  /// A provisional caption for an utterance still in progress. Replaced by the
  /// final segment covering the same audio when the utterance closes. Callers
  /// that only want finished text should filter these out.
  final bool isInterim;

  /// Level of the audio that was decoded, in dBFS. Very low values (below
  /// about -45) usually explain a bad transcription better than the model does.
  final double rmsDb;

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
    this.audioPath,
  });

  /// Plain text - what the main app POSTs to /api/notes/sync as `transcript`.
  final String text;
  final List<TranscriptSegment> segments;

  /// Total captured audio length - what the main app sends as
  /// `duration_seconds` (the referral system depends on it).
  final Duration audioDuration;

  /// Where the session's 16 kHz mono WAV was written, when audio retention is
  /// on. This is what lets the same speech be re-decoded by another model.
  /// The main app will normally leave retention off.
  final String? audioPath;

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
///
/// Interim captions are dropped: they are provisional views of audio that a
/// final segment also covers, so including them would duplicate text.
String assembleTranscript(Iterable<TranscriptSegment> segments) {
  return segments
      .where((s) => !s.isInterim)
      .map((s) => s.text.trim())
      .where((t) => t.isNotEmpty)
      .join(' ')
      .trim();
}
