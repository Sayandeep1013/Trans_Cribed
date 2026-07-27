import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:picaku_stt_demo/util/pcm.dart';

void main() {
  group('pcm16leToFloat32', () {
    test('converts known values with little-endian ordering', () {
      // 0, 16384 (0.5), -16384 (-0.5), 32767 (~1.0), -32768 (-1.0)
      final bytes = Uint8List.fromList([
        0x00, 0x00, //
        0x00, 0x40, //
        0x00, 0xC0, //
        0xFF, 0x7F, //
        0x00, 0x80, //
      ]);
      final floats = pcm16leToFloat32(bytes);

      expect(floats.length, 5);
      expect(floats[0], 0.0);
      expect(floats[1], closeTo(0.5, 1e-4));
      expect(floats[2], closeTo(-0.5, 1e-4));
      expect(floats[3], closeTo(1.0, 1e-3));
      expect(floats[4], -1.0);
    });

    test('ignores a trailing odd byte instead of crashing', () {
      final bytes = Uint8List.fromList([0x00, 0x40, 0x7F]);
      expect(pcm16leToFloat32(bytes).length, 1);
    });

    test('empty input yields empty output', () {
      expect(pcm16leToFloat32(Uint8List(0)), isEmpty);
    });
  });
}
