import 'package:flutter_test/flutter_test.dart';
import 'package:picaku_stt_demo/transcriber/transcriber.dart';

TranscriptSegment seg(String text, int startMs, int endMs, int decodeMs) {
  return TranscriptSegment(
    text: text,
    start: Duration(milliseconds: startMs),
    end: Duration(milliseconds: endMs),
    decodeTime: Duration(milliseconds: decodeMs),
  );
}

void main() {
  group('assembleTranscript', () {
    test('joins segments with single spaces and trims each', () {
      final segments = [
        seg('  Hello there.', 0, 1200, 100),
        seg('This is a test. ', 1500, 3200, 150),
      ];
      expect(assembleTranscript(segments), 'Hello there. This is a test.');
    });

    test('skips empty and whitespace-only segments', () {
      final segments = [
        seg('One.', 0, 800, 50),
        seg('   ', 900, 1000, 5),
        seg('', 1100, 1200, 5),
        seg('Two.', 1300, 2000, 60),
      ];
      expect(assembleTranscript(segments), 'One. Two.');
    });

    test('empty input yields empty transcript', () {
      expect(assembleTranscript(const []), '');
    });

    test('drops interim captions so their audio is not counted twice', () {
      final segments = [
        seg('One.', 0, 800, 50),
        TranscriptSegment(
          text: 'Two is still bei',
          start: const Duration(milliseconds: 900),
          end: const Duration(milliseconds: 1600),
          decodeTime: const Duration(milliseconds: 40),
          isInterim: true,
        ),
        seg('Two is still being said.', 900, 2400, 90),
      ];
      expect(assembleTranscript(segments), 'One. Two is still being said.');
    });
  });

  group('TranscriptSegment.rtf', () {
    test('computes decode time over audio time', () {
      expect(seg('x', 0, 2000, 200).rtf, closeTo(0.1, 1e-9));
    });

    test('zero-length audio does not divide by zero', () {
      expect(seg('x', 1000, 1000, 50).rtf, 0);
    });
  });

  group('TranscriptResult', () {
    test('durationSeconds reflects audio duration for the sync payload', () {
      const result = TranscriptResult(
        text: 'hi',
        segments: [],
        audioDuration: Duration(milliseconds: 92500),
      );
      expect(result.durationSeconds, closeTo(92.5, 1e-9));
    });
  });
}
