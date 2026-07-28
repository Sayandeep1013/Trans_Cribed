import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:picaku_stt_demo/util/wav.dart';

Uint8List pcm16(List<int> samples) {
  final bytes = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    bytes.setInt16(i * 2, samples[i], Endian.little);
  }
  return bytes.buffer.asUint8List();
}

Uint8List wavFile(List<int> samples, {int sampleRate = 16000, int channels = 1}) {
  final payload = pcm16(samples);
  final header = buildWavHeader(
    payload.length,
    sampleRate: sampleRate,
    channels: channels,
  );
  return Uint8List.fromList([...header, ...payload]);
}

void main() {
  group('buildWavHeader', () {
    test('writes a canonical 44-byte RIFF/WAVE header', () {
      final header = buildWavHeader(1000);
      expect(header.length, wavHeaderBytes);
      expect(String.fromCharCodes(header, 0, 4), 'RIFF');
      expect(String.fromCharCodes(header, 8, 12), 'WAVE');
      expect(String.fromCharCodes(header, 36, 40), 'data');

      final view = ByteData.sublistView(header);
      expect(view.getUint32(4, Endian.little), 1036); // 36 + payload
      expect(view.getUint32(40, Endian.little), 1000);
      expect(view.getUint16(22, Endian.little), 1); // mono
      expect(view.getUint32(24, Endian.little), 16000);
      expect(view.getUint32(28, Endian.little), 32000); // byte rate
    });
  });

  group('decodeWavBytes', () {
    test('round-trips PCM16 samples to normalized floats', () {
      final decoded = decodeWavBytes(wavFile([0, 16384, -16384, 32767]));
      expect(decoded.sampleRate, 16000);
      expect(decoded.samples.length, 4);
      expect(decoded.samples[0], 0);
      expect(decoded.samples[1], closeTo(0.5, 1e-4));
      expect(decoded.samples[2], closeTo(-0.5, 1e-4));
      expect(decoded.samples[3], closeTo(1.0, 1e-4));
    });

    test('reports duration from sample count and rate', () {
      final decoded = decodeWavBytes(wavFile(List.filled(16000, 0)));
      expect(decoded.duration.inMilliseconds, 1000);
    });

    test('downmixes stereo to mono by averaging', () {
      // Interleaved L/R: (0.5, -0.5) then (1.0, 0.0).
      final decoded = decodeWavBytes(
        wavFile([16384, -16384, 32767, 0], channels: 2),
      );
      expect(decoded.samples.length, 2);
      expect(decoded.samples[0], closeTo(0, 1e-4));
      expect(decoded.samples[1], closeTo(0.5, 1e-4));
    });

    test('skips unknown chunks before data', () {
      final payload = pcm16([16384]);
      final header = buildWavHeader(payload.length);
      // Insert a LIST chunk between fmt and data.
      const listChunk = [
        0x4C, 0x49, 0x53, 0x54, // 'LIST'
        0x04, 0x00, 0x00, 0x00, // size 4
        0x61, 0x62, 0x63, 0x64, // body
      ];
      final bytes = Uint8List.fromList([
        ...header.sublist(0, 36),
        ...listChunk,
        ...header.sublist(36),
        ...payload,
      ]);
      final decoded = decodeWavBytes(bytes);
      expect(decoded.samples.length, 1);
      expect(decoded.samples[0], closeTo(0.5, 1e-4));
    });

    test('rejects files that are not RIFF/WAVE', () {
      expect(
        () => decodeWavBytes(Uint8List.fromList(List.filled(64, 0))),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
