import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// Filenames are normalized by CI (see .github/workflows/build-apk.yml), so
/// the Dart code is identical for Moonshine tiny/base - only the bytes differ.
class ModelPaths {
  const ModelPaths({
    required this.preprocessor,
    required this.encoder,
    required this.uncachedDecoder,
    required this.cachedDecoder,
    required this.tokens,
    required this.sileroVad,
  });

  final String preprocessor;
  final String encoder;
  final String uncachedDecoder;
  final String cachedDecoder;
  final String tokens;
  final String sileroVad;
}

const _assetFiles = [
  'assets/models/moonshine/preprocess.onnx',
  'assets/models/moonshine/encode.onnx',
  'assets/models/moonshine/uncached_decode.onnx',
  'assets/models/moonshine/cached_decode.onnx',
  'assets/models/moonshine/tokens.txt',
  'assets/models/vad/silero_vad.onnx',
];

/// sherpa-onnx needs real file paths, so bundled assets are copied to the
/// app-support directory once. Existing copies with the right size are reused,
/// so this is only slow on first launch.
Future<ModelPaths> extractModelAssets({
  void Function(String stage)? onProgress,
}) async {
  final dir = await getApplicationSupportDirectory();
  final out = <String, String>{};

  for (final asset in _assetFiles) {
    final name = asset.split('/').last;
    final target = File('${dir.path}${Platform.pathSeparator}$name');
    final data = await rootBundle.load(asset);

    if (!await target.exists() || await target.length() != data.lengthInBytes) {
      onProgress?.call('Extracting $name…');
      await target.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    out[name] = target.path;
  }

  return ModelPaths(
    preprocessor: out['preprocess.onnx']!,
    encoder: out['encode.onnx']!,
    uncachedDecoder: out['uncached_decode.onnx']!,
    cachedDecoder: out['cached_decode.onnx']!,
    tokens: out['tokens.txt']!,
    sileroVad: out['silero_vad.onnx']!,
  );
}
