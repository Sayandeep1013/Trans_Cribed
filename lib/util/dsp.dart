/// Small, dependency-free signal helpers used by the decode path.
///
/// Everything here runs on audio we already hold, so any change can be
/// re-measured on a stored recording instead of guessed at.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Root-mean-square level of [samples] (0..1 for normalized float audio).
double rms(Float32List samples) {
  if (samples.isEmpty) return 0;
  var sum = 0.0;
  for (final s in samples) {
    sum += s * s;
  }
  return math.sqrt(sum / samples.length);
}

/// Peak absolute amplitude.
double peak(Float32List samples) {
  var maxAbs = 0.0;
  for (final s in samples) {
    final a = s.abs();
    if (a > maxAbs) maxAbs = a;
  }
  return maxAbs;
}

/// Linear amplitude to dBFS. Silence floors at -100 dB instead of -infinity.
double toDbfs(double amplitude) {
  if (amplitude <= 1e-5) return -100;
  return 20 * (math.log(amplitude) / math.ln10);
}

/// dBFS back to linear amplitude.
double fromDbfs(double db) => math.pow(10, db / 20).toDouble();

/// One-pole high-pass. Removes DC offset and low-frequency handling rumble
/// below [cutoffHz]. Cheap (one multiply-add per sample) and phase-benign at
/// the frequencies speech models actually look at.
Float32List highPassFilter(
  Float32List samples, {
  required double cutoffHz,
  required int sampleRate,
}) {
  if (samples.isEmpty || cutoffHz <= 0) return samples;
  final rc = 1.0 / (2 * math.pi * cutoffHz);
  final dt = 1.0 / sampleRate;
  final alpha = rc / (rc + dt);

  final out = Float32List(samples.length);
  var prevIn = samples[0];
  var prevOut = 0.0;
  out[0] = 0;
  for (var i = 1; i < samples.length; i++) {
    final x = samples[i];
    prevOut = alpha * (prevOut + x - prevIn);
    prevIn = x;
    out[i] = prevOut;
  }
  return out;
}

/// Scales [samples] so their RMS lands on [targetDb].
///
/// Gain is clamped to [maxGain] so near-silent input is not blown up into
/// noise, and the result is hard-limited to [-1, 1] to avoid wrap-around.
Float32List rmsNormalizeTo(
  Float32List samples, {
  required double targetDb,
  double maxGain = 12.0,
}) {
  final current = rms(samples);
  if (current <= 1e-6) return samples;

  var gain = fromDbfs(targetDb) / current;
  if (gain > maxGain) gain = maxGain;
  if (gain < 1 / maxGain) gain = 1 / maxGain;

  final out = Float32List(samples.length);
  for (var i = 0; i < samples.length; i++) {
    out[i] = (samples[i] * gain).clamp(-1.0, 1.0);
  }
  return out;
}

/// A fixed-size window over the most recent audio, addressed by *absolute*
/// sample index since capture began.
///
/// This is what makes pre-roll padding possible: when the VAD finally reports
/// "speech ran from sample N to sample M", the audio just before N has already
/// gone past, and only a ring like this still has it.
class AudioRing {
  AudioRing(this.capacity) : _buffer = Float32List(capacity);

  final int capacity;
  final Float32List _buffer;

  /// Total samples ever written - also the exclusive absolute end index.
  int _written = 0;

  int get written => _written;

  /// Oldest absolute index still retained.
  int get firstAvailable => math.max(0, _written - capacity);

  void add(Float32List samples) {
    for (var i = 0; i < samples.length; i++) {
      _buffer[(_written + i) % capacity] = samples[i];
    }
    _written += samples.length;
  }

  void clear() {
    _written = 0;
  }

  /// Samples in absolute range [from, to). Silently clamps to what is still
  /// retained, so callers never have to bounds-check.
  Float32List slice(int from, int to) {
    final start = math.max(from, firstAvailable);
    final end = math.min(to, _written);
    if (end <= start) return Float32List(0);

    final out = Float32List(end - start);
    for (var i = 0; i < out.length; i++) {
      out[i] = _buffer[(start + i) % capacity];
    }
    return out;
  }
}
