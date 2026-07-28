/// Word and character error rate against a reference transcript.
///
/// WER is the standard ASR accuracy metric - every leaderboard number quoted
/// for Whisper, Parakeet or Moonshine is one of these. It is the edit distance
/// between reference and hypothesis word sequences, divided by the reference
/// length:
///
///   WER = (substitutions + deletions + insertions) / reference words
///
/// CER is the same at character level. It is the fairer metric when a model is
/// *nearly* right: "Sayandeep" -> "Sayan deep" is one substitution plus one
/// insertion in WER terms (a big hit) but only one character error in CER.
library;

import 'dart:math' as math;
import 'dart:typed_data';

class ErrorRate {
  const ErrorRate({
    required this.substitutions,
    required this.deletions,
    required this.insertions,
    required this.hits,
    required this.referenceLength,
    this.hasBreakdown = true,
  });

  final int substitutions;
  final int deletions;
  final int insertions;
  final int hits;
  final int referenceLength;

  /// False when the inputs were too large to align exactly and only the total
  /// distance was computed. The rate is still correct; the S/D/I split is not.
  final bool hasBreakdown;

  int get errors => substitutions + deletions + insertions;

  /// 0.0 = perfect. Can exceed 1.0 when the hypothesis invents extra words.
  double get rate {
    if (referenceLength == 0) return errors == 0 ? 0 : 1;
    return errors / referenceLength;
  }

  double get accuracy => math.max(0, 1 - rate);

  String get percent => '${(rate * 100).toStringAsFixed(1)}%';

  Map<String, Object?> toJson() => {
        'rate': rate,
        'substitutions': substitutions,
        'deletions': deletions,
        'insertions': insertions,
        'hits': hits,
        'referenceLength': referenceLength,
        'hasBreakdown': hasBreakdown,
      };
}

/// Scoring normalization: case, punctuation and whitespace are not things an
/// ASR model should be penalized for here. Apostrophes are kept because
/// "don't" and "dont" are genuinely different tokens to a model.
String normalizeForScoring(String text) {
  final buffer = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    final ch = String.fromCharCode(rune);
    if (RegExp(r"[a-z0-9']").hasMatch(ch)) {
      buffer.write(ch);
    } else {
      buffer.write(' ');
    }
  }
  return buffer.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
}

List<String> tokenizeWords(String text) {
  final normalized = normalizeForScoring(text);
  if (normalized.isEmpty) return const [];
  return normalized.split(' ');
}

/// Beyond this many DP cells we skip the alignment matrix and compute distance
/// only, to keep a long session from allocating hundreds of MB.
const int _maxAlignmentCells = 8000000;

ErrorRate _align(List<String> reference, List<String> hypothesis) {
  final n = reference.length;
  final m = hypothesis.length;

  if (n == 0) {
    return ErrorRate(
      substitutions: 0,
      deletions: 0,
      insertions: m,
      hits: 0,
      referenceLength: 0,
    );
  }
  if (m == 0) {
    return ErrorRate(
      substitutions: 0,
      deletions: n,
      insertions: 0,
      hits: 0,
      referenceLength: n,
    );
  }

  if ((n + 1) * (m + 1) > _maxAlignmentCells) {
    final distance = _distanceOnly(reference, hypothesis);
    return ErrorRate(
      substitutions: distance,
      deletions: 0,
      insertions: 0,
      hits: math.max(0, n - distance),
      referenceLength: n,
      hasBreakdown: false,
    );
  }

  // 0 = match, 1 = substitution, 2 = deletion (ref word missing from hyp),
  // 3 = insertion (hyp word not in ref).
  final ops = Uint8List((n + 1) * (m + 1));
  var previous = Int32List(m + 1);
  var current = Int32List(m + 1);

  for (var j = 0; j <= m; j++) {
    previous[j] = j;
    ops[j] = 3;
  }
  ops[0] = 0;

  for (var i = 1; i <= n; i++) {
    current[0] = i;
    ops[i * (m + 1)] = 2;
    for (var j = 1; j <= m; j++) {
      final match = reference[i - 1] == hypothesis[j - 1];
      final substitute = previous[j - 1] + (match ? 0 : 1);
      final delete = previous[j] + 1;
      final insert = current[j - 1] + 1;

      var best = substitute;
      var op = match ? 0 : 1;
      if (delete < best) {
        best = delete;
        op = 2;
      }
      if (insert < best) {
        best = insert;
        op = 3;
      }
      current[j] = best;
      ops[i * (m + 1) + j] = op;
    }
    final swap = previous;
    previous = current;
    current = swap;
  }

  var substitutions = 0;
  var deletions = 0;
  var insertions = 0;
  var hits = 0;
  var i = n;
  var j = m;
  while (i > 0 || j > 0) {
    final op = ops[i * (m + 1) + j];
    if (i > 0 && j > 0 && (op == 0 || op == 1)) {
      if (op == 0) {
        hits++;
      } else {
        substitutions++;
      }
      i--;
      j--;
    } else if (i > 0 && op == 2) {
      deletions++;
      i--;
    } else if (j > 0) {
      insertions++;
      j--;
    } else {
      deletions++;
      i--;
    }
  }

  return ErrorRate(
    substitutions: substitutions,
    deletions: deletions,
    insertions: insertions,
    hits: hits,
    referenceLength: n,
  );
}

int _distanceOnly(List<String> reference, List<String> hypothesis) {
  final m = hypothesis.length;
  var previous = Int32List(m + 1);
  var current = Int32List(m + 1);
  for (var j = 0; j <= m; j++) {
    previous[j] = j;
  }
  for (var i = 1; i <= reference.length; i++) {
    current[0] = i;
    for (var j = 1; j <= m; j++) {
      final cost = reference[i - 1] == hypothesis[j - 1] ? 0 : 1;
      var best = previous[j - 1] + cost;
      final delete = previous[j] + 1;
      final insert = current[j - 1] + 1;
      if (delete < best) best = delete;
      if (insert < best) best = insert;
      current[j] = best;
    }
    final swap = previous;
    previous = current;
    current = swap;
  }
  return previous[m];
}

ErrorRate wordErrorRate(String reference, String hypothesis) =>
    _align(tokenizeWords(reference), tokenizeWords(hypothesis));

ErrorRate characterErrorRate(String reference, String hypothesis) {
  final ref = normalizeForScoring(reference).replaceAll(' ', '');
  final hyp = normalizeForScoring(hypothesis).replaceAll(' ', '');
  return _align(ref.split(''), hyp.split(''));
}
