/// The model catalog: every entry the app can download and run.
///
/// All Moonshine variants share the exact same engine code - only the file
/// URLs/paths differ (see SherpaMoonshineTranscriber). Weights are inference-
/// only and read-only: nothing is trained or modified on device; the INT8
/// quantization was applied upstream before these files were published.
///
/// Sources are the official sherpa-onnx model mirrors (k2-fsa project).
library;

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
    required this.files,
  });

  final String id;
  final String displayName;
  final String description;

  /// Approximate total download size, for the UI only.
  final int approxMb;
  final List<RemoteFile> files;
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
  files: _moonshineFiles('tiny'),
);

final ModelSpec moonshineBase = ModelSpec(
  id: 'moonshine-base-en-int8',
  displayName: 'Moonshine Base (English)',
  description: 'Best accuracy. Recommended for most phones.',
  approxMb: 170,
  files: _moonshineFiles('base'),
);

final List<ModelSpec> modelCatalog = [moonshineBase, moonshineTiny];
