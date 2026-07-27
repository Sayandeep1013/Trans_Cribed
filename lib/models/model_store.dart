import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'model_catalog.dart';

/// Resolved on-disk locations the engine needs. Filenames are normalized by
/// [RemoteFile.localName], so this is identical for every Moonshine variant.
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

class DownloadCancelled implements Exception {
  const DownloadCancelled();

  @override
  String toString() => 'Download cancelled';
}

class DownloadProgress {
  const DownloadProgress({
    required this.fileName,
    required this.fileIndex,
    required this.fileCount,
    required this.receivedBytes,
    required this.totalBytes,
  });

  final String fileName;

  /// 1-based index of the file currently downloading.
  final int fileIndex;
  final int fileCount;
  final int receivedBytes;

  /// Null when the server did not report a content length.
  final int? totalBytes;

  double? get fileFraction {
    final total = totalBytes;
    if (total == null || total == 0) return null;
    return receivedBytes / total;
  }
}

/// Download-once-and-cache store for model files (spec section 12: never
/// block the first meeting on a download; here the demo simply gates the
/// record button on an installed model).
///
/// Layout: {appSupport}/models/{modelId}/<files> + a `.complete` marker,
/// and {appSupport}/models/shared/silero_vad.onnx for the VAD.
class ModelStore {
  static const _markerName = '.complete';
  static const _selectedFileName = 'selected_model';

  Future<Directory> _modelsRoot() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}${Platform.pathSeparator}models');
    await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _dirFor(String id) async {
    final root = await _modelsRoot();
    final dir = Directory('${root.path}${Platform.pathSeparator}$id');
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _vadTarget() async {
    final shared = await _dirFor('shared');
    return File('${shared.path}${Platform.pathSeparator}${vadFile.localName}');
  }

  Future<bool> isInstalled(ModelSpec spec) async {
    final dir = await _dirFor(spec.id);
    final marker = File('${dir.path}${Platform.pathSeparator}$_markerName');
    if (!await marker.exists()) return false;
    for (final f in spec.files) {
      if (!await File('${dir.path}${Platform.pathSeparator}${f.localName}')
          .exists()) {
        return false;
      }
    }
    return (await _vadTarget()).exists();
  }

  /// Downloads all files for [spec] (plus the shared VAD if missing).
  /// Files that already finished downloading are skipped, so a failed or
  /// cancelled download resumes at the file level on retry.
  Future<void> download(
    ModelSpec spec, {
    required void Function(DownloadProgress progress) onProgress,
    bool Function()? isCancelled,
  }) async {
    final dir = await _dirFor(spec.id);
    final vadTarget = await _vadTarget();

    final work = <(RemoteFile, File)>[
      for (final f in spec.files)
        (f, File('${dir.path}${Platform.pathSeparator}${f.localName}')),
      if (!await vadTarget.exists()) (vadFile, vadTarget),
    ];

    final client = http.Client();
    try {
      for (var i = 0; i < work.length; i++) {
        final (remote, target) = work[i];
        await _downloadFile(
          client,
          remote,
          target,
          onChunk: (received, total) => onProgress(
            DownloadProgress(
              fileName: remote.localName,
              fileIndex: i + 1,
              fileCount: work.length,
              receivedBytes: received,
              totalBytes: total,
            ),
          ),
          isCancelled: isCancelled,
        );
      }
    } finally {
      client.close();
    }

    await File('${dir.path}${Platform.pathSeparator}$_markerName')
        .writeAsString(DateTime.now().toIso8601String());
  }

  Future<void> _downloadFile(
    http.Client client,
    RemoteFile remote,
    File target, {
    required void Function(int received, int? total) onChunk,
    bool Function()? isCancelled,
  }) async {
    if (await target.exists()) return; // finished in an earlier attempt

    final tmp = File('${target.path}.part');
    final response =
        await client.send(http.Request('GET', Uri.parse(remote.url)));
    if (response.statusCode != 200) {
      throw HttpException(
        'HTTP ${response.statusCode} downloading ${remote.localName}',
        uri: Uri.parse(remote.url),
      );
    }

    final sink = tmp.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        if (isCancelled?.call() ?? false) {
          throw const DownloadCancelled();
        }
        received += chunk.length;
        sink.add(chunk);
        onChunk(received, response.contentLength);
      }
      await sink.flush();
      await sink.close();
      await tmp.rename(target.path);
    } catch (_) {
      await sink.close();
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }
  }

  Future<ModelPaths> pathsFor(ModelSpec spec) async {
    final dir = await _dirFor(spec.id);
    String p(String name) => '${dir.path}${Platform.pathSeparator}$name';
    return ModelPaths(
      preprocessor: p('preprocess.onnx'),
      encoder: p('encode.onnx'),
      uncachedDecoder: p('uncached_decode.onnx'),
      cachedDecoder: p('cached_decode.onnx'),
      tokens: p('tokens.txt'),
      sileroVad: (await _vadTarget()).path,
    );
  }

  Future<void> delete(ModelSpec spec) async {
    final dir = await _dirFor(spec.id);
    if (await dir.exists()) await dir.delete(recursive: true);
    final selected = await getSelectedModelId();
    if (selected == spec.id) await setSelectedModelId(null);
  }

  Future<File> _selectedFile() async {
    final root = await _modelsRoot();
    return File('${root.path}${Platform.pathSeparator}$_selectedFileName');
  }

  Future<String?> getSelectedModelId() async {
    final f = await _selectedFile();
    if (!await f.exists()) return null;
    final id = (await f.readAsString()).trim();
    return id.isEmpty ? null : id;
  }

  Future<void> setSelectedModelId(String? id) async {
    final f = await _selectedFile();
    if (id == null) {
      if (await f.exists()) await f.delete();
    } else {
      await f.writeAsString(id);
    }
  }
}
