/// Minimal 16-bit PCM mono WAV read/write.
///
/// Session audio is kept so the *same waveform* can be re-decoded by a
/// different model or with different options. Without this, every model
/// comparison is confounded by the speaker saying it differently the second
/// time - which is what made earlier accuracy impressions unreliable.
///
/// Pure `dart:io`, no plugins, so it works inside the engine isolate.
library;

import 'dart:io';
import 'dart:typed_data';

import 'pcm.dart';

const int wavHeaderBytes = 44;

/// Builds a canonical 44-byte RIFF/WAVE header for [dataBytes] of PCM payload.
Uint8List buildWavHeader(
  int dataBytes, {
  int sampleRate = 16000,
  int channels = 1,
  int bitsPerSample = 16,
}) {
  final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  final blockAlign = channels * bitsPerSample ~/ 8;

  final header = ByteData(wavHeaderBytes);
  void ascii(int offset, String tag) {
    for (var i = 0; i < tag.length; i++) {
      header.setUint8(offset + i, tag.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little); // PCM fmt chunk size
  header.setUint16(20, 1, Endian.little); // format = PCM
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, byteRate, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, dataBytes, Endian.little);

  return header.buffer.asUint8List();
}

/// Streams PCM16 straight to disk while recording, then patches the RIFF sizes
/// on [close]. Memory stays flat regardless of session length, which is the
/// point - a 60-minute meeting must not be held in RAM.
class WavWriter {
  WavWriter._(this._file, this.path, this.sampleRate);

  final RandomAccessFile _file;
  final String path;
  final int sampleRate;

  int _dataBytes = 0;
  bool _closed = false;

  int get dataBytes => _dataBytes;
  Duration get duration => Duration(
        microseconds: _dataBytes ~/ 2 * 1000000 ~/ sampleRate,
      );

  static Future<WavWriter> create(String path, {int sampleRate = 16000}) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final raf = await file.open(mode: FileMode.write);
    // Placeholder header; sizes are patched in close().
    await raf.writeFrom(buildWavHeader(0, sampleRate: sampleRate));
    return WavWriter._(raf, path, sampleRate);
  }

  Future<void> write(Uint8List pcm16le) async {
    if (_closed) return;
    await _file.writeFrom(pcm16le);
    _dataBytes += pcm16le.length;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _file.setPosition(0);
    await _file.writeFrom(buildWavHeader(_dataBytes, sampleRate: sampleRate));
    await _file.close();
  }
}

class WavAudio {
  const WavAudio({required this.samples, required this.sampleRate});

  final Float32List samples;
  final int sampleRate;

  Duration get duration => Duration(
        microseconds: samples.length * 1000000 ~/ sampleRate,
      );
}

/// Reads a 16-bit PCM WAV. Walks the chunk list rather than assuming a 44-byte
/// header, since some writers insert LIST/fact chunks before `data`.
///
/// Multi-channel input is downmixed to mono by averaging.
WavAudio decodeWavBytes(Uint8List bytes) {
  if (bytes.length < 12) {
    throw const FormatException('Not a WAV file: too short');
  }
  final data = ByteData.sublistView(bytes);
  String tag(int offset) => String.fromCharCodes(bytes, offset, offset + 4);

  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') {
    throw const FormatException('Not a RIFF/WAVE file');
  }

  var sampleRate = 16000;
  var channels = 1;
  var bitsPerSample = 16;
  var offset = 12;
  Uint8List? payload;

  while (offset + 8 <= bytes.length) {
    final chunkId = tag(offset);
    final chunkSize = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;

    if (chunkId == 'fmt ' && body + 16 <= bytes.length) {
      channels = data.getUint16(body + 2, Endian.little);
      sampleRate = data.getUint32(body + 4, Endian.little);
      bitsPerSample = data.getUint16(body + 14, Endian.little);
    } else if (chunkId == 'data') {
      final end = (body + chunkSize).clamp(body, bytes.length);
      payload = Uint8List.sublistView(bytes, body, end);
      break;
    }
    // Chunks are word-aligned.
    offset = body + chunkSize + (chunkSize.isOdd ? 1 : 0);
  }

  if (payload == null) throw const FormatException('WAV has no data chunk');
  if (bitsPerSample != 16) {
    throw FormatException('Only 16-bit PCM is supported, got $bitsPerSample');
  }

  final interleaved = pcm16leToFloat32(payload);
  if (channels <= 1) {
    return WavAudio(samples: interleaved, sampleRate: sampleRate);
  }

  final frames = interleaved.length ~/ channels;
  final mono = Float32List(frames);
  for (var i = 0; i < frames; i++) {
    var sum = 0.0;
    for (var c = 0; c < channels; c++) {
      sum += interleaved[i * channels + c];
    }
    mono[i] = sum / channels;
  }
  return WavAudio(samples: mono, sampleRate: sampleRate);
}

Future<WavAudio> readWavFile(String path) async {
  final bytes = await File(path).readAsBytes();
  return decodeWavBytes(bytes);
}
