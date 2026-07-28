/// The model catalog: every entry the app can download and run.
///
/// Weights are inference-only and read-only: nothing is trained or modified
/// on device; quantization was applied upstream before publication.
///
/// ## Where these files come from
///
/// Everything is served by the official **k2-fsa / sherpa-onnx** distribution,
/// which has two halves:
///
///  * **Hugging Face**, user `csukuangfj` (Fangjun Kuang, the sherpa-onnx
///    maintainer) - one repo per exported model, e.g.
///    `huggingface.co/csukuangfj/sherpa-onnx-moonshine-base-en-int8`.
///    We link individual files via `/resolve/main/<file>`.
///  * **GitHub releases** on `k2-fsa/sherpa-onnx`, tag `asr-models` - used for
///    the shared Silero VAD.
///
/// The canonical human-readable index of everything available is
/// <https://k2-fsa.github.io/sherpa/onnx/pretrained_models/index.html>.
///
/// This catalog is a **compile-time list**: URLs are pinned in the binary, so
/// adding a model today means shipping an app update. See
/// MODEL_OPTIMIZATION_STRATEGY.md for the remote-manifest alternative.
library;

/// Which sherpa-onnx config the engine must build for a model. Every model of
/// the same type runs through identical engine code - only file paths differ.
enum EngineType {
  /// Moonshine encoder-decoder (preprocess/encode/uncached/cached decode).
  /// Variable-length input: cost scales with actual utterance length.
  moonshine,

  /// NeMo transducer (encoder/decoder/joiner) - e.g. NVIDIA Parakeet TDT.
  /// The only family here that supports hotwords / beam search.
  nemoTransducer,

  /// OpenAI Whisper (encoder/decoder). Note: the encoder is **fixed at 30
  /// seconds** - every utterance is zero-padded to 30 s before inference, so a
  /// 2-second utterance costs the same as a 30-second one. That is precisely
  /// the inefficiency Moonshine was designed to remove, and it makes Whisper
  /// the slowest option in a VAD-gated pipeline like this one.
  ///
  /// Whisper is also the **only** family here that can do a language other
  /// than English - and only in its multilingual builds. See [ModelSpec.isMultilingual].
  whisper,
}

/// The 99 language codes Whisper's multilingual builds accept, mapped to
/// display names.
///
/// This list is not cosmetic. sherpa-onnx looks the configured code up in the
/// model's own `lang2id` table and, on a miss, calls `SHERPA_ONNX_EXIT(-1)` -
/// which expands to `_Exit(-1)`, killing the process outright with no Dart
/// exception and no crash handler. A typo in a language code is therefore an
/// instant, unexplained app death. Everything that sets a language must
/// validate against [isWhisperLanguage] first.
///
/// Source: `GetAllWhisperLanguageCodes()` in sherpa-onnx
/// `csrc/offline-whisper-model-config.cc`.
const Map<String, String> whisperLanguages = {
  'en': 'English', 'zh': 'Chinese', 'de': 'German', 'es': 'Spanish',
  'ru': 'Russian', 'ko': 'Korean', 'fr': 'French', 'ja': 'Japanese',
  'pt': 'Portuguese', 'tr': 'Turkish', 'pl': 'Polish', 'ca': 'Catalan',
  'nl': 'Dutch', 'ar': 'Arabic', 'sv': 'Swedish', 'it': 'Italian',
  'id': 'Indonesian', 'hi': 'Hindi', 'fi': 'Finnish', 'vi': 'Vietnamese',
  'he': 'Hebrew', 'uk': 'Ukrainian', 'el': 'Greek', 'ms': 'Malay',
  'cs': 'Czech', 'ro': 'Romanian', 'da': 'Danish', 'hu': 'Hungarian',
  'ta': 'Tamil', 'no': 'Norwegian', 'th': 'Thai', 'ur': 'Urdu',
  'hr': 'Croatian', 'bg': 'Bulgarian', 'lt': 'Lithuanian', 'la': 'Latin',
  'mi': 'Maori', 'ml': 'Malayalam', 'cy': 'Welsh', 'sk': 'Slovak',
  'te': 'Telugu', 'fa': 'Persian', 'lv': 'Latvian', 'bn': 'Bengali',
  'sr': 'Serbian', 'az': 'Azerbaijani', 'sl': 'Slovenian', 'kn': 'Kannada',
  'et': 'Estonian', 'mk': 'Macedonian', 'br': 'Breton', 'eu': 'Basque',
  'is': 'Icelandic', 'hy': 'Armenian', 'ne': 'Nepali', 'mn': 'Mongolian',
  'bs': 'Bosnian', 'kk': 'Kazakh', 'sq': 'Albanian', 'sw': 'Swahili',
  'gl': 'Galician', 'mr': 'Marathi', 'pa': 'Punjabi', 'si': 'Sinhala',
  'km': 'Khmer', 'sn': 'Shona', 'yo': 'Yoruba', 'so': 'Somali',
  'af': 'Afrikaans', 'oc': 'Occitan', 'ka': 'Georgian', 'be': 'Belarusian',
  'tg': 'Tajik', 'sd': 'Sindhi', 'gu': 'Gujarati', 'am': 'Amharic',
  'yi': 'Yiddish', 'lo': 'Lao', 'uz': 'Uzbek', 'fo': 'Faroese',
  'ht': 'Haitian Creole', 'ps': 'Pashto', 'tk': 'Turkmen', 'nn': 'Nynorsk',
  'mt': 'Maltese', 'sa': 'Sanskrit', 'lb': 'Luxembourgish', 'my': 'Burmese',
  'bo': 'Tibetan', 'tl': 'Tagalog', 'mg': 'Malagasy', 'as': 'Assamese',
  'tt': 'Tatar', 'haw': 'Hawaiian', 'ln': 'Lingala', 'ha': 'Hausa',
  'ba': 'Bashkir', 'jw': 'Javanese', 'su': 'Sundanese',
};

/// True when [code] is safe to hand to sherpa-onnx as a Whisper language.
/// The empty string is also safe - it means "auto-detect".
bool isWhisperLanguage(String code) =>
    code.isEmpty || whisperLanguages.containsKey(code);

/// Sentinel for the language dropdown: let Whisper detect the language itself
/// from the first ~30 s window of each utterance.
const String whisperAutoDetect = '';

class RemoteFile {
  const RemoteFile({required this.localName, required this.url});

  /// Normalized on-disk name, so engine code is identical across variants.
  final String localName;
  final String url;
}

class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.displayName,
    required this.description,
    required this.approxMb,
    required this.type,
    required this.files,
    required this.sourceUrl,
    this.numThreads = 2,
    this.isMultilingual = false,
  });

  final String id;
  final String displayName;
  final String description;

  /// Approximate total download size, for the UI only.
  final int approxMb;
  final EngineType type;
  final List<RemoteFile> files;

  /// Human-browsable home of these weights, shown in the UI for provenance.
  final String sourceUrl;

  /// Decode threads recommended for this model's size.
  final int numThreads;

  /// Whether the weights can transcribe languages other than English.
  ///
  /// This is a property of the **weights**, not of any setting. Whisper's
  /// `.en` builds were trained on English only and their initial-token
  /// sequence is just `[sot]` - sherpa-onnx skips the language/task block
  /// entirely for them (`if (model_->IsMultiLingual())` in
  /// `offline-whisper-greedy-search-decoder.cc`). Pointing one at German audio
  /// does not fail, it produces English-looking nonsense. The only fix is
  /// different weights, which is why the multilingual builds are separate
  /// catalog entries rather than a toggle on the existing ones.
  ///
  /// Moonshine and Parakeet are English-only across the board: Useful Sensors
  /// and NVIDIA have not published multilingual ONNX exports of these sizes.
  final bool isMultilingual;

  /// Hotwords and beam search are transducer-only in sherpa-onnx.
  bool get supportsHotwords => type == EngineType.nemoTransducer;

  /// Whether the language / task settings do anything for this model.
  bool get supportsLanguageChoice =>
      type == EngineType.whisper && isMultilingual;
}

const String _hf = 'https://huggingface.co/csukuangfj';

String _moonshineRepo(String size) => '$_hf/sherpa-onnx-moonshine-$size-en-int8';

List<RemoteFile> _moonshineFiles(String size) {
  final repo = '${_moonshineRepo(size)}/resolve/main';
  return [
    RemoteFile(localName: 'preprocess.onnx', url: '$repo/preprocess.onnx'),
    RemoteFile(localName: 'encode.onnx', url: '$repo/encode.int8.onnx'),
    RemoteFile(
      localName: 'uncached_decode.onnx',
      url: '$repo/uncached_decode.int8.onnx',
    ),
    RemoteFile(
      localName: 'cached_decode.onnx',
      url: '$repo/cached_decode.int8.onnx',
    ),
    RemoteFile(localName: 'tokens.txt', url: '$repo/tokens.txt'),
  ];
}

String _whisperRepo(String size) => '$_hf/sherpa-onnx-whisper-$size';

/// Whisper exports name their files after the model size, so they are renamed
/// on disk to the same `encoder/decoder/tokens` triple every Whisper uses.
List<RemoteFile> _whisperFiles(String size) {
  final repo = '${_whisperRepo(size)}/resolve/main';
  return [
    RemoteFile(localName: 'encoder.onnx', url: '$repo/$size-encoder.int8.onnx'),
    RemoteFile(localName: 'decoder.onnx', url: '$repo/$size-decoder.int8.onnx'),
    RemoteFile(localName: 'tokens.txt', url: '$repo/$size-tokens.txt'),
  ];
}

const String _parakeetRepo =
    '$_hf/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8';

/// Silero VAD is a shared component: downloaded once, used with every model.
const RemoteFile vadFile = RemoteFile(
  localName: 'silero_vad.onnx',
  url:
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx',
);

final ModelSpec moonshineTiny = ModelSpec(
  id: 'moonshine-tiny-en-int8',
  displayName: 'Moonshine Tiny (English)',
  description: 'Fastest, lowest RAM. Good for budget phones.',
  approxMb: 75,
  type: EngineType.moonshine,
  files: _moonshineFiles('tiny'),
  sourceUrl: _moonshineRepo('tiny'),
);

final ModelSpec moonshineBase = ModelSpec(
  id: 'moonshine-base-en-int8',
  displayName: 'Moonshine Base (English)',
  description: 'Balanced speed and accuracy. Recommended default.',
  approxMb: 170,
  type: EngineType.moonshine,
  files: _moonshineFiles('base'),
  sourceUrl: _moonshineRepo('base'),
);

final ModelSpec parakeetTdt06b = ModelSpec(
  id: 'parakeet-tdt-0.6b-v2-int8',
  displayName: 'NVIDIA Parakeet TDT 0.6B (English)',
  description:
      'Highest accuracy (open-model leaderboard leader), and the only model '
      'here that supports hotwords. Heavy - needs a recent phone with 8 GB+ '
      'RAM.',
  approxMb: 640,
  type: EngineType.nemoTransducer,
  numThreads: 4,
  files: const [
    RemoteFile(
      localName: 'encoder.onnx',
      url: '$_parakeetRepo/resolve/main/encoder.int8.onnx',
    ),
    RemoteFile(
      localName: 'decoder.onnx',
      url: '$_parakeetRepo/resolve/main/decoder.int8.onnx',
    ),
    RemoteFile(
      localName: 'joiner.onnx',
      url: '$_parakeetRepo/resolve/main/joiner.int8.onnx',
    ),
    RemoteFile(
      localName: 'tokens.txt',
      url: '$_parakeetRepo/resolve/main/tokens.txt',
    ),
  ],
  sourceUrl: _parakeetRepo,
);

final ModelSpec whisperTinyEn = ModelSpec(
  id: 'whisper-tiny.en-int8',
  displayName: 'Whisper Tiny.en (English only)',
  description:
      'The family the main app already uses (via whisper.cpp). Bigger and '
      'slower than Moonshine Tiny at similar accuracy - here as the baseline '
      'to beat, not as a recommendation. English only: it cannot be made to '
      'transcribe another language.',
  approxMb: 104,
  type: EngineType.whisper,
  files: _whisperFiles('tiny.en'),
  sourceUrl: _whisperRepo('tiny.en'),
);

final ModelSpec whisperBaseEn = ModelSpec(
  id: 'whisper-base.en-int8',
  displayName: 'Whisper Base.en (English only)',
  description:
      'Size-matched to Moonshine Base for a fair comparison. Expect notably '
      'worse RTF: the 30-second encoder pads every short utterance. English '
      'only.',
  approxMb: 161,
  type: EngineType.whisper,
  files: _whisperFiles('base.en'),
  sourceUrl: _whisperRepo('base.en'),
);

final ModelSpec whisperTinyMulti = ModelSpec(
  id: 'whisper-tiny-int8',
  displayName: 'Whisper Tiny (99 languages)',
  description:
      'Same size as Tiny.en but trained on 99 languages, so it can transcribe '
      'non-English speech and translate any of them into English. Accuracy on '
      'English is slightly worse than Tiny.en - multilingual capacity is '
      'spent on other languages.',
  approxMb: 104,
  type: EngineType.whisper,
  isMultilingual: true,
  files: _whisperFiles('tiny'),
  sourceUrl: _whisperRepo('tiny'),
);

final ModelSpec whisperBaseMulti = ModelSpec(
  id: 'whisper-base-int8',
  displayName: 'Whisper Base (99 languages)',
  description:
      'The recommended pick when meetings are not in English. Handles 99 '
      'languages, can auto-detect which one is being spoken, and can '
      'translate straight to English. Slowest option here - the 30-second '
      'encoder still pads every utterance.',
  approxMb: 161,
  type: EngineType.whisper,
  isMultilingual: true,
  files: _whisperFiles('base'),
  sourceUrl: _whisperRepo('base'),
);

final List<ModelSpec> modelCatalog = [
  moonshineBase,
  moonshineTiny,
  parakeetTdt06b,
  whisperBaseMulti,
  whisperTinyMulti,
  whisperBaseEn,
  whisperTinyEn,
];

ModelSpec? modelSpecById(String id) {
  for (final spec in modelCatalog) {
    if (spec.id == id) return spec;
  }
  return null;
}
