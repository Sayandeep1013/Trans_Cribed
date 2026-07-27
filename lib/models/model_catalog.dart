/// The model catalog: every entry the app can download and run.
///
/// Weights are inference-only and read-only: nothing is trained or modified
/// on device; quantization was applied upstream before publication.
///
/// Sources are the official sherpa-onnx model mirrors (k2-fsa project).
library;

/// Which sherpa-onnx config the engine must build for a model. Every model of
/// the same type runs through identical engine code - only file paths differ.
enum EngineType {
  /// Moonshine encoder-decoder (preprocess/encode/uncached/cached decode).
  moonshine,

  /// NeMo transducer (encoder/decoder/joiner) - e.g. NVIDIA Parakeet TDT.
  nemoTransducer,
}

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
    this.numThreads = 2,
  });

  final String id;
  final String displayName;
  final String description;

  /// Approximate total download size, for the UI only.
  final int approxMb;
  final EngineType type;
  final List<RemoteFile> files;

  /// Decode threads recommended for this model's size.
  final int numThreads;
}

const String _hf = 'https://huggingface.co/csukuangfj';

List<RemoteFile> _moonshineFiles(String size) => [
      RemoteFile(
        localName: 'preprocess.onnx',
        url: '$_hf/sherpa-onnx-moonshine-$size-en-int8/resolve/main/preprocess.onnx',
      ),
      RemoteFile(
        localName: 'encode.onnx',
        url: '$_hf/sherpa-onnx-moonshine-$size-en-int8/resolve/main/encode.int8.onnx',
      ),
      RemoteFile(
        localName: 'uncached_decode.onnx',
        url: '$_hf/sherpa-onnx-moonshine-$size-en-int8/resolve/main/uncached_decode.int8.onnx',
      ),
      RemoteFile(
        localName: 'cached_decode.onnx',
        url: '$_hf/sherpa-onnx-moonshine-$size-en-int8/resolve/main/cached_decode.int8.onnx',
      ),
      RemoteFile(
        localName: 'tokens.txt',
        url: '$_hf/sherpa-onnx-moonshine-$size-en-int8/resolve/main/tokens.txt',
      ),
    ];

const String _parakeetRepo =
    '$_hf/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8/resolve/main';

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
);

final ModelSpec moonshineBase = ModelSpec(
  id: 'moonshine-base-en-int8',
  displayName: 'Moonshine Base (English)',
  description: 'Balanced speed and accuracy. Recommended default.',
  approxMb: 170,
  type: EngineType.moonshine,
  files: _moonshineFiles('base'),
);

final ModelSpec parakeetTdt06b = ModelSpec(
  id: 'parakeet-tdt-0.6b-v2-int8',
  displayName: 'NVIDIA Parakeet TDT 0.6B (English)',
  description:
      'Highest accuracy (open-model leaderboard leader). Heavy - needs a '
      'recent phone with 8 GB+ RAM.',
  approxMb: 640,
  type: EngineType.nemoTransducer,
  numThreads: 4,
  files: const [
    RemoteFile(localName: 'encoder.onnx', url: '$_parakeetRepo/encoder.int8.onnx'),
    RemoteFile(localName: 'decoder.onnx', url: '$_parakeetRepo/decoder.int8.onnx'),
    RemoteFile(localName: 'joiner.onnx', url: '$_parakeetRepo/joiner.int8.onnx'),
    RemoteFile(localName: 'tokens.txt', url: '$_parakeetRepo/tokens.txt'),
  ],
);

final List<ModelSpec> modelCatalog = [
  moonshineBase,
  moonshineTiny,
  parakeetTdt06b,
];
