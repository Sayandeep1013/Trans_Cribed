/// Every tunable that affects transcription quality or speed, in one place.
///
/// These are the knobs the optimization work will turn. They are deliberately
/// runtime-settable (Lab screen) rather than constants, because the only
/// honest way to pick values is to A/B them on the *same* recording - see
/// `lib/bench/` and MODEL_OPTIMIZATION_STRATEGY.md.
///
/// Two groups, and the difference matters:
///
///  * **Capture-time** (`micAutoGain`, `micNoiseSuppress`, `micEchoCancel`):
///    applied by Android's audio HAL *before* we ever see samples. Changing
///    these requires re-recording; they cannot be A/B'd on stored audio.
///  * **Decode-time** (everything else): applied to audio we already hold, so
///    the same WAV can be re-decoded with different values and compared
///    exactly. This is what makes the benchmark meaningful.
library;

class EngineOptions {
  const EngineOptions({
    this.preRollMs = 200,
    this.postRollMs = 200,
    this.highPass = false,
    this.highPassHz = 80,
    this.rmsNormalize = false,
    this.targetRmsDb = -20,
    this.vadThreshold = 0.5,
    this.minSilenceMs = 350,
    this.minSpeechMs = 250,
    this.maxSpeechMs = 15000,
    this.interimCaptionMs = 6000,
    this.numThreadsOverride,
    this.decodingMethod = 'greedy_search',
    this.maxActivePaths = 4,
    this.blankPenalty = 0.0,
    this.hotwords = '',
    this.hotwordsScore = 1.5,
    this.micAutoGain = true,
    this.micNoiseSuppress = true,
    this.micEchoCancel = true,
  });

  // --- Segment padding (decode-time) ----------------------------------------
  // Silero hands back a segment starting exactly where speech was detected,
  // which shaves word onsets and trailing consonants. Padding the utterance
  // with surrounding audio before decoding is the cheapest accuracy lever we
  // have. Timestamps still report the unpadded VAD boundaries.
  final int preRollMs;
  final int postRollMs;

  // --- Optional signal conditioning (decode-time) ---------------------------
  /// One-pole high-pass: removes DC offset and handling rumble.
  final bool highPass;
  final double highPassHz;

  /// Normalize each utterance to [targetRmsDb] before decoding. Helps quiet or
  /// distant speakers; can amplify noise in silence-heavy audio.
  final bool rmsNormalize;
  final double targetRmsDb;

  // --- VAD (decode-time) ----------------------------------------------------
  /// Silero speech probability threshold. Lower = more sensitive (catches soft
  /// speech, also more false triggers).
  final double vadThreshold;

  /// Silence needed to close an utterance. This is the dominant term in caption
  /// latency: lower = snappier captions, more mid-sentence splits.
  final int minSilenceMs;

  /// Utterances shorter than this are discarded as noise.
  final int minSpeechMs;

  /// Hard cap on a single utterance. The VAD force-closes speech here even
  /// with no pause, so a monologue still produces final segments.
  final int maxSpeechMs;

  /// Guaranteed caption rhythm. While an utterance is still open, the engine
  /// re-decodes what it has every [interimCaptionMs] and emits a provisional
  /// caption (`TranscriptSegment.isInterim`), replaced by the real one when the
  /// utterance closes.
  ///
  /// This is what makes captions arrive on a clock instead of only at pauses -
  /// fluent, pause-free speech otherwise shows nothing until [maxSpeechMs].
  /// Costs one extra decode per interval. 0 disables it.
  final int interimCaptionMs;

  // --- Decoder (decode-time) ------------------------------------------------
  /// Null uses the per-model recommendation from the catalog.
  final int? numThreadsOverride;

  /// `greedy_search` or `modified_beam_search`. Beam search is transducer-only
  /// (Parakeet); attention models (Moonshine, Whisper) ignore or reject it, so
  /// the engine forces greedy for those.
  final String decodingMethod;
  final int maxActivePaths;
  final double blankPenalty;

  /// Contextual biasing: one phrase per line, boosts names and jargon.
  /// Transducer + `modified_beam_search` only - the single biggest lever for
  /// meeting-specific vocabulary.
  final String hotwords;
  final double hotwordsScore;

  // --- Capture-time (requires re-recording to compare) ----------------------
  final bool micAutoGain;
  final bool micNoiseSuppress;
  final bool micEchoCancel;

  bool get usesHotwords =>
      hotwords.trim().isNotEmpty && decodingMethod == 'modified_beam_search';

  EngineOptions copyWith({
    int? preRollMs,
    int? postRollMs,
    bool? highPass,
    double? highPassHz,
    bool? rmsNormalize,
    double? targetRmsDb,
    double? vadThreshold,
    int? minSilenceMs,
    int? minSpeechMs,
    int? maxSpeechMs,
    int? interimCaptionMs,
    int? numThreadsOverride,
    bool clearNumThreadsOverride = false,
    String? decodingMethod,
    int? maxActivePaths,
    double? blankPenalty,
    String? hotwords,
    double? hotwordsScore,
    bool? micAutoGain,
    bool? micNoiseSuppress,
    bool? micEchoCancel,
  }) {
    return EngineOptions(
      preRollMs: preRollMs ?? this.preRollMs,
      postRollMs: postRollMs ?? this.postRollMs,
      highPass: highPass ?? this.highPass,
      highPassHz: highPassHz ?? this.highPassHz,
      rmsNormalize: rmsNormalize ?? this.rmsNormalize,
      targetRmsDb: targetRmsDb ?? this.targetRmsDb,
      vadThreshold: vadThreshold ?? this.vadThreshold,
      minSilenceMs: minSilenceMs ?? this.minSilenceMs,
      minSpeechMs: minSpeechMs ?? this.minSpeechMs,
      maxSpeechMs: maxSpeechMs ?? this.maxSpeechMs,
      interimCaptionMs: interimCaptionMs ?? this.interimCaptionMs,
      numThreadsOverride: clearNumThreadsOverride
          ? null
          : (numThreadsOverride ?? this.numThreadsOverride),
      decodingMethod: decodingMethod ?? this.decodingMethod,
      maxActivePaths: maxActivePaths ?? this.maxActivePaths,
      blankPenalty: blankPenalty ?? this.blankPenalty,
      hotwords: hotwords ?? this.hotwords,
      hotwordsScore: hotwordsScore ?? this.hotwordsScore,
      micAutoGain: micAutoGain ?? this.micAutoGain,
      micNoiseSuppress: micNoiseSuppress ?? this.micNoiseSuppress,
      micEchoCancel: micEchoCancel ?? this.micEchoCancel,
    );
  }

  /// Restores a persisted option set, falling back to the default for any key
  /// a newer build added since it was written.
  factory EngineOptions.fromJson(Map<String, Object?> json) {
    const defaults = EngineOptions();
    int asInt(String key, int fallback) =>
        (json[key] as num?)?.toInt() ?? fallback;
    double asDouble(String key, double fallback) =>
        (json[key] as num?)?.toDouble() ?? fallback;
    bool asBool(String key, bool fallback) => json[key] as bool? ?? fallback;

    return EngineOptions(
      preRollMs: asInt('preRollMs', defaults.preRollMs),
      postRollMs: asInt('postRollMs', defaults.postRollMs),
      highPass: asBool('highPass', defaults.highPass),
      highPassHz: asDouble('highPassHz', defaults.highPassHz),
      rmsNormalize: asBool('rmsNormalize', defaults.rmsNormalize),
      targetRmsDb: asDouble('targetRmsDb', defaults.targetRmsDb),
      vadThreshold: asDouble('vadThreshold', defaults.vadThreshold),
      minSilenceMs: asInt('minSilenceMs', defaults.minSilenceMs),
      minSpeechMs: asInt('minSpeechMs', defaults.minSpeechMs),
      maxSpeechMs: asInt('maxSpeechMs', defaults.maxSpeechMs),
      interimCaptionMs: asInt('interimCaptionMs', defaults.interimCaptionMs),
      numThreadsOverride: (json['numThreadsOverride'] as num?)?.toInt(),
      decodingMethod: json['decodingMethod'] as String? ?? defaults.decodingMethod,
      maxActivePaths: asInt('maxActivePaths', defaults.maxActivePaths),
      blankPenalty: asDouble('blankPenalty', defaults.blankPenalty),
      hotwords: json['hotwordsText'] as String? ?? defaults.hotwords,
      hotwordsScore: asDouble('hotwordsScore', defaults.hotwordsScore),
      micAutoGain: asBool('micAutoGain', defaults.micAutoGain),
      micNoiseSuppress: asBool('micNoiseSuppress', defaults.micNoiseSuppress),
      micEchoCancel: asBool('micEchoCancel', defaults.micEchoCancel),
    );
  }

  /// Compact form for logs, exports and benchmark result labels.
  Map<String, Object?> toJson() => {
        'preRollMs': preRollMs,
        'postRollMs': postRollMs,
        'highPass': highPass,
        'highPassHz': highPassHz,
        'rmsNormalize': rmsNormalize,
        'targetRmsDb': targetRmsDb,
        'vadThreshold': vadThreshold,
        'minSilenceMs': minSilenceMs,
        'minSpeechMs': minSpeechMs,
        'maxSpeechMs': maxSpeechMs,
        'interimCaptionMs': interimCaptionMs,
        'numThreadsOverride': numThreadsOverride,
        'decodingMethod': decodingMethod,
        'maxActivePaths': maxActivePaths,
        'blankPenalty': blankPenalty,
        // Count for readability in logs, full text so the set round-trips.
        'hotwords': hotwords.trim().isEmpty
            ? null
            : hotwords.trim().split('\n').length,
        'hotwordsText': hotwords,
        'hotwordsScore': hotwordsScore,
        'micAutoGain': micAutoGain,
        'micNoiseSuppress': micNoiseSuppress,
        'micEchoCancel': micEchoCancel,
      };

  /// One-line summary used to label a benchmark row.
  String get shortLabel {
    final parts = <String>[
      if (preRollMs > 0 || postRollMs > 0) 'pad $preRollMs/${postRollMs}ms',
      if (highPass) 'hp${highPassHz.round()}',
      if (rmsNormalize) 'norm',
      'sil${minSilenceMs}ms',
      'thr${vadThreshold.toStringAsFixed(2)}',
      if (decodingMethod != 'greedy_search') 'beam$maxActivePaths',
      if (usesHotwords) 'hotwords',
    ];
    return parts.join(' · ');
  }
}
