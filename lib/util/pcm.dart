import 'dart:typed_data';

/// Converts little-endian 16-bit PCM bytes (as emitted by the `record`
/// package's stream) into normalized Float32 samples in [-1.0, 1.0].
///
/// Uses ByteData rather than Int16List.view so it is safe for byte buffers
/// whose offset is not 2-aligned and explicit about endianness.
Float32List pcm16leToFloat32(Uint8List bytes) {
  final sampleCount = bytes.length ~/ 2;
  final data = ByteData.sublistView(bytes, 0, sampleCount * 2);
  final out = Float32List(sampleCount);
  for (var i = 0; i < sampleCount; i++) {
    out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}
