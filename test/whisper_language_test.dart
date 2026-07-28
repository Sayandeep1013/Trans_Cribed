import 'package:flutter_test/flutter_test.dart';
import 'package:picaku_stt_demo/engine/engine_options.dart';
import 'package:picaku_stt_demo/models/model_catalog.dart';

/// These tests exist because the failure they guard against is not an
/// exception. sherpa-onnx resolves the configured Whisper language against the
/// model's own table and, on a miss, calls `SHERPA_ONNX_EXIT(-1)` -> `_Exit(-1)`.
/// That terminates the process immediately: no Dart error, no crash dialog, no
/// log line. A bad language code is therefore indistinguishable from the app
/// being force-stopped, which is close to undebuggable in the field.
void main() {
  group('language sanitizing', () {
    test('accepts every code sherpa-onnx knows', () {
      for (final code in whisperLanguages.keys) {
        expect(sanitizeWhisperLanguage(code), code, reason: 'rejected $code');
      }
    });

    test('empty string stays empty, meaning auto-detect', () {
      expect(sanitizeWhisperLanguage(''), '');
      expect(sanitizeWhisperLanguage(null), '');
    });

    test('unknown codes degrade to auto-detect rather than reaching native', () {
      // 'eng' and 'en-US' are the plausible mistakes: both are valid language
      // tags elsewhere, neither is a Whisper code.
      for (final bad in ['eng', 'en-US', 'english', 'xx', '  ', '12']) {
        expect(sanitizeWhisperLanguage(bad), '', reason: 'let "$bad" through');
      }
    });

    test('normalizes case and surrounding whitespace', () {
      expect(sanitizeWhisperLanguage(' DE '), 'de');
      expect(sanitizeWhisperLanguage('Hi'), 'hi');
    });

    test('non-string input cannot crash the sanitizer', () {
      expect(sanitizeWhisperLanguage(42), '');
      expect(sanitizeWhisperLanguage(<String>['de']), '');
    });
  });

  group('task sanitizing', () {
    test('keeps the two tasks Whisper defines', () {
      expect(sanitizeWhisperTask('transcribe'), 'transcribe');
      expect(sanitizeWhisperTask('translate'), 'translate');
    });

    test('anything else falls back to transcribe', () {
      for (final bad in ['', null, 'summarize', 'TRANSLATE_TO_FRENCH']) {
        expect(sanitizeWhisperTask(bad), 'transcribe');
      }
    });

    test('is case-insensitive', () {
      expect(sanitizeWhisperTask('Translate'), 'translate');
    });
  });

  group('options round-trip', () {
    test('language and task survive persistence', () {
      const original = EngineOptions(
        whisperLanguage: 'hi',
        whisperTask: 'translate',
      );
      final restored = EngineOptions.fromJson(original.toJson());
      expect(restored.whisperLanguage, 'hi');
      expect(restored.whisperTask, 'translate');
    });

    test('a corrupted options file cannot smuggle in a bad language', () {
      final restored = EngineOptions.fromJson({
        'whisperLanguage': 'klingon',
        'whisperTask': 'interpret',
      });
      expect(restored.whisperLanguage, '');
      expect(restored.whisperTask, 'transcribe');
    });

    test('options written before this feature existed still load', () {
      final restored = EngineOptions.fromJson({'minSilenceMs': 400});
      expect(restored.whisperLanguage, '');
      expect(restored.whisperTask, 'transcribe');
      expect(restored.minSilenceMs, 400);
    });
  });

  group('catalog', () {
    test('exactly the multilingual Whisper builds offer a language choice', () {
      final multilingual =
          modelCatalog.where((s) => s.supportsLanguageChoice).map((s) => s.id);
      expect(
        multilingual,
        unorderedEquals(<String>['whisper-base-int8', 'whisper-tiny-int8']),
      );
    });

    test('English-only models never claim language support', () {
      for (final spec in modelCatalog.where((s) => !s.isMultilingual)) {
        expect(spec.supportsLanguageChoice, isFalse, reason: spec.id);
      }
    });

    test('the ".en" Whisper builds are not marked multilingual', () {
      // The trap this guards: they load, run, and emit fluent English-looking
      // text for German input. Nothing fails loudly.
      expect(whisperTinyEn.isMultilingual, isFalse);
      expect(whisperBaseEn.isMultilingual, isFalse);
      expect(whisperTinyMulti.isMultilingual, isTrue);
      expect(whisperBaseMulti.isMultilingual, isTrue);
    });

    test('every model id is unique', () {
      final ids = modelCatalog.map((s) => s.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('whisper builds all declare the three files the engine looks up', () {
      for (final spec
          in modelCatalog.where((s) => s.type == EngineType.whisper)) {
        final names = spec.files.map((f) => f.localName).toSet();
        expect(names, containsAll(['encoder.onnx', 'decoder.onnx', 'tokens.txt']),
            reason: spec.id);
      }
    });

    test('language table matches the 99 codes sherpa-onnx compiles in', () {
      expect(whisperLanguages.length, 99);
    });
  });
}
