import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:picaku_stt_demo/util/dsp.dart';

Float32List sine({
  required double freqHz,
  required int samples,
  double amplitude = 0.5,
  int sampleRate = 16000,
}) {
  final out = Float32List(samples);
  for (var i = 0; i < samples; i++) {
    out[i] = amplitude * math.sin(2 * math.pi * freqHz * i / sampleRate);
  }
  return out;
}

void main() {
  group('rms and dBFS', () {
    test('rms of a sine is amplitude / sqrt(2)', () {
      final tone = sine(freqHz: 440, samples: 16000);
      expect(rms(tone), closeTo(0.5 / math.sqrt2, 0.01));
    });

    test('silence floors instead of returning negative infinity', () {
      expect(toDbfs(0), -100);
    });

    test('dBFS round-trips through fromDbfs', () {
      expect(fromDbfs(toDbfs(0.25)), closeTo(0.25, 1e-6));
    });
  });

  group('highPassFilter', () {
    test('removes a constant DC offset', () {
      final withOffset = Float32List.fromList(List.filled(4000, 0.4));
      final filtered = highPassFilter(
        withOffset,
        cutoffHz: 80,
        sampleRate: 16000,
      );
      // Well past the filter's settling time the output must sit at zero.
      expect(filtered[3999].abs(), lessThan(0.01));
    });

    test('passes a 1 kHz tone essentially untouched', () {
      final tone = sine(freqHz: 1000, samples: 16000);
      final filtered = highPassFilter(tone, cutoffHz: 80, sampleRate: 16000);
      expect(rms(filtered), closeTo(rms(tone), 0.02));
    });

    test('attenuates a 20 Hz rumble', () {
      final rumble = sine(freqHz: 20, samples: 16000);
      final filtered = highPassFilter(rumble, cutoffHz: 80, sampleRate: 16000);
      expect(rms(filtered), lessThan(rms(rumble) * 0.5));
    });
  });

  group('rmsNormalizeTo', () {
    test('brings a quiet signal up to the target level', () {
      final quiet = sine(freqHz: 440, samples: 16000, amplitude: 0.02);
      final normalized = rmsNormalizeTo(quiet, targetDb: -20);
      expect(toDbfs(rms(normalized)), closeTo(-20, 1.0));
    });

    test('does not amplify silence into noise', () {
      final silence = Float32List(1000);
      expect(rms(rmsNormalizeTo(silence, targetDb: -20)), 0);
    });

    test('respects the gain ceiling on near-silent input', () {
      final veryQuiet = sine(freqHz: 440, samples: 16000, amplitude: 0.0005);
      final normalized = rmsNormalizeTo(
        veryQuiet,
        targetDb: -20,
        maxGain: 4,
      );
      expect(rms(normalized), closeTo(rms(veryQuiet) * 4, 1e-4));
    });

    test('never exceeds full scale', () {
      final loud = sine(freqHz: 440, samples: 16000, amplitude: 0.9);
      final normalized = rmsNormalizeTo(loud, targetDb: 0);
      expect(peak(normalized), lessThanOrEqualTo(1.0));
    });
  });

  group('AudioRing', () {
    test('returns samples by absolute index', () {
      final ring = AudioRing(100);
      ring.add(Float32List.fromList([1, 2, 3, 4, 5]));
      expect(ring.slice(1, 4), [2, 3, 4]);
      expect(ring.written, 5);
    });

    test('overwrites the oldest audio once full, and clamps reads', () {
      final ring = AudioRing(4);
      ring.add(Float32List.fromList([1, 2, 3, 4, 5, 6]));
      expect(ring.firstAvailable, 2);
      // Asking for evicted audio silently returns only what survives.
      expect(ring.slice(0, 6), [3, 4, 5, 6]);
    });

    test('reading past the end returns nothing rather than throwing', () {
      final ring = AudioRing(10);
      ring.add(Float32List.fromList([1, 2, 3]));
      expect(ring.slice(5, 9), isEmpty);
    });

    test('spans the wrap point correctly', () {
      final ring = AudioRing(4);
      ring.add(Float32List.fromList([1, 2, 3]));
      ring.add(Float32List.fromList([4, 5]));
      expect(ring.slice(1, 5), [2, 3, 4, 5]);
    });
  });
}
