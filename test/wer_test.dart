import 'package:flutter_test/flutter_test.dart';
import 'package:picaku_stt_demo/bench/wer.dart';

void main() {
  group('normalizeForScoring', () {
    test('ignores case, punctuation and repeated whitespace', () {
      expect(
        normalizeForScoring('Hello,   THERE!  How are you?'),
        'hello there how are you',
      );
    });

    test('keeps apostrophes, which are a real token difference', () {
      expect(normalizeForScoring("don't"), "don't");
    });
  });

  group('wordErrorRate', () {
    test('identical text scores zero', () {
      final r = wordErrorRate('the quick brown fox', 'The quick brown fox.');
      expect(r.rate, 0);
      expect(r.hits, 4);
    });

    test('counts a substitution', () {
      final r = wordErrorRate('the quick brown fox', 'the quick brown box');
      expect(r.substitutions, 1);
      expect(r.deletions, 0);
      expect(r.insertions, 0);
      expect(r.rate, closeTo(0.25, 1e-9));
    });

    test('counts a deletion', () {
      final r = wordErrorRate('the quick brown fox', 'the quick fox');
      expect(r.deletions, 1);
      expect(r.rate, closeTo(0.25, 1e-9));
    });

    test('counts an insertion', () {
      final r = wordErrorRate('the quick fox', 'the quick brown fox');
      expect(r.insertions, 1);
      expect(r.rate, closeTo(1 / 3, 1e-9));
    });

    test('empty hypothesis deletes every reference word', () {
      final r = wordErrorRate('one two three', '');
      expect(r.deletions, 3);
      expect(r.rate, 1);
    });

    test('rate can exceed 1 when the model invents words', () {
      final r = wordErrorRate('yes', 'yes and also quite a lot more');
      expect(r.rate, greaterThan(1));
    });

    test('empty reference with empty hypothesis is not an error', () {
      expect(wordErrorRate('', '').rate, 0);
    });
  });

  group('characterErrorRate', () {
    test('is gentler than WER on a word split', () {
      const reference = 'sayandeep pushed the change';
      const hypothesis = 'sayan deep pushed the change';
      final wer = wordErrorRate(reference, hypothesis);
      final cer = characterErrorRate(reference, hypothesis);
      expect(cer.rate, lessThan(wer.rate));
    });

    test('spaces are ignored so only characters count', () {
      expect(characterErrorRate('abc def', 'abcdef').rate, 0);
    });
  });
}
