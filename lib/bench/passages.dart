/// Read-aloud passages with known reference text.
///
/// Why these exist: to score accuracy you must know what was actually said.
/// You can type that in after the fact, but then every tester transcribes
/// their own speech by hand and no two runs are comparable. A fixed passage
/// removes both problems - hand the same paragraph to five people with
/// different accents, and the spread in their WER *is* the accent measurement.
///
/// The first set is drawn from the Harvard Sentences (IEEE Recommended
/// Practice for Speech Quality Measurements, 1969), the standard phonetically
/// balanced material for exactly this purpose.
library;

class Passage {
  const Passage({
    required this.id,
    required this.title,
    required this.purpose,
    required this.text,
  });

  final String id;
  final String title;

  /// What this passage is designed to expose.
  final String purpose;
  final String text;

  int get wordCount => text.split(RegExp(r'\s+')).length;

  /// Rough read time at a relaxed 140 words per minute.
  Duration get approxDuration =>
      Duration(seconds: (wordCount / 140 * 60).round());
}

const List<Passage> passages = [
  Passage(
    id: 'harvard',
    title: 'Harvard sentences',
    purpose:
        'Phonetically balanced, deliberately plain vocabulary. The neutral '
        'baseline: differences here are the model, not the words.',
    text:
        'The birch canoe slid on the smooth planks. '
        'Glue the sheet to the dark blue background. '
        "It's easy to tell the depth of a well. "
        'These days a chicken leg is a rare dish. '
        'Rice is often served in round bowls. '
        'The juice of lemons makes fine punch. '
        'The box was thrown beside the parked truck. '
        'The hogs were fed chopped corn and garbage. '
        'Four hours of steady work faced us. '
        'A large size in stockings is hard to sell.',
  ),
  Passage(
    id: 'meeting',
    title: 'Meeting-style paragraph',
    purpose:
        'Natural connected speech with the filler and hedging of real '
        'meetings - the register the app actually has to transcribe.',
    text:
        'Okay, so quick update on where we are. We shipped the onboarding '
        'changes on Tuesday, and the drop-off on the second screen went from '
        'about forty percent down to twenty-six. I think that is mostly the '
        'copy change rather than the layout. The one thing I want to flag is '
        'that the sync job is still timing out for accounts with more than a '
        'thousand notes, so if anyone hits that this week, just let me know '
        'and I will look at it. Otherwise we are roughly on track for the '
        'end of the month.',
  ),
  Passage(
    id: 'hard',
    title: 'Names, numbers and jargon',
    purpose:
        'The stress test: proper nouns, acronyms, digits and technical terms '
        'are where on-device models fall apart, and the only case hotwords '
        'can rescue.',
    text:
        'The Picaku build runs sherpa-onnx with Moonshine base quantized to '
        'int eight. Sayandeep pushed the change at four fifteen on the '
        'twenty-third. We need Parakeet TDT zero point six B benchmarked '
        'against Whisper base dot en before Friday. The API returns a four '
        'zero three when the JWT expires, and Supabase logs it as an RLS '
        'violation. Drift migration version three is still failing on '
        'Android fourteen.',
  ),
];

Passage? passageById(String id) {
  for (final p in passages) {
    if (p.id == id) return p;
  }
  return null;
}
