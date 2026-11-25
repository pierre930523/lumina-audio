import 'dart:math' as math;

import '../../models/audio_format.dart';
import '../../models/recommendation_models.dart';

/// Cross-platform track matching, normalization, similarity scoring, and
/// quality ranking utilities.
class TrackMatcher {
  static const int maxDurationDeltaMs = 5000;

  static final RegExp _bracketEditionRegex = RegExp(
    r'\s*[\(\[\{【][^)\]}】]*\b(?:'
    r'(?:re)?master(?:ed)?|'
    r'deluxe(?:\s+(?:edition|version))?|'
    r'super\s+deluxe|'
    r'expanded(?:\s+edition)?|'
    r'special(?:\s+edition)?|'
    r'anniversary(?:\s+edition)?|'
    r"collector'?s?\s+edition|"
    r'bonus\s+track(?:\s+version)?|'
    r'(?:limited|standard|digital)\s+edition|'
    r'official(?:\s+(?:(?:music|lyric)\s+)?(?:audio|video|mv|visualizer))?|'
    r'(?:music|lyric)\s+video|'
    r'audio\s+only|'
    r'visualizer|'
    r'explicit|'
    r'clean|'
    r'radio\s+edit|'
    r'(?:single|album|original)\s+version|'
    r'mono|'
    r'stereo|'
    r'hi-res|'
    r'spatial\s+audio|'
    r'dolby\s+atmos|'
    r'feat\.?|ft\.?|featuring'
    r')\b[^)\]}】]*[\)\]}】]',
    caseSensitive: false,
  );

  static final RegExp _dashEditionRegex = RegExp(
    r'\s+[-–—]\s+.*?\b(?:'
    r'(?:re)?master(?:ed)?|'
    r'deluxe|expanded|special|anniversary|'
    r'official(?:\s+(?:audio|video|mv))?|'
    r'explicit|clean|'
    r'radio\s+edit|'
    r'(?:single|album|original)\s+version|'
    r'edition|mono|stereo'
    r')\b.*$',
    caseSensitive: false,
  );

  static final RegExp _trailingFeatTitleRegex = RegExp(
    r'\s+(?:feat\.|ft\.|featuring)\s+.*$',
    caseSensitive: false,
  );

  static final RegExp _apostropheRegex = RegExp(r"['’`]");
  static final RegExp _nonAlnumSpaceRegex = RegExp(
    r'[^\p{L}\p{N}\s]',
    unicode: true,
  );
  static final RegExp _multiSpaceRegex = RegExp(r'\s+');

  /// Normalizes an ISRC by trimming, removing hyphens/whitespace, and uppercasing.
  /// Returns `null` if the normalized value is empty.
  static String? normalizeIsrc(String? raw) {
    if (raw == null) return null;
    final cleaned = raw.replaceAll(RegExp(r'[-\s]+'), '').trim().toUpperCase();
    return cleaned.isEmpty ? null : cleaned;
  }

  /// Converts full-width ASCII (`U+FF01..U+FF5E`) and full-width spaces
  /// (`U+3000`, `U+00A0`) to ASCII, lowercases, and collapses whitespace.
  static String normalizeWidthAndCase(String input) {
    return normalizeWidthPreserveCase(input).toLowerCase();
  }

  /// Extracts the primary artist (normalized width & case), stripping featuring
  /// markers first and then splitting on collaborative delimiters.
  static String extractPrimaryArtist(String artist) {
    return extractPrimaryArtistDisplay(artist).toLowerCase();
  }

  /// Normalizes a track title by folding width/case, stripping edition/noise
  /// tags (`Remastered`, `Deluxe Edition`, `Official Audio`, `Explicit`, `feat.`,
  /// etc.), and removing punctuation.
  static String normalizeTitleForMatching(String title) {
    var s = normalizeWidthAndCase(title);
    if (s.isEmpty) return '';

    // Loop until fixed point in case multiple edition tags appear consecutively.
    String prev;
    do {
      prev = s;
      s = s.replaceAll(_bracketEditionRegex, ' ');
      s = s.replaceFirst(_dashEditionRegex, '');
      s = s.replaceFirst(_trailingFeatTitleRegex, '');
      s = s.replaceAll(_multiSpaceRegex, ' ').trim();
    } while (s != prev);

    s = s.replaceAll(_apostropheRegex, '');
    s = s.replaceAll(_nonAlnumSpaceRegex, ' ');
    return s.replaceAll(_multiSpaceRegex, ' ').trim();
  }

  /// Normalizes an artist name for matching (width/case + punctuation removal).
  static String normalizeArtistForMatching(String artist) {
    var s = normalizeWidthAndCase(artist);
    if (s.isEmpty) return '';
    s = s.replaceAll(_apostropheRegex, '');
    s = s.replaceAll(_nonAlnumSpaceRegex, ' ');
    return s.replaceAll(_multiSpaceRegex, ' ').trim();
  }

  /// Computes a hybrid normalized Levenshtein + token Dice similarity in `[0.0, 1.0]`.
  static double similarity(String a, String b) {
    final na = normalizeWidthAndCase(a);
    final nb = normalizeWidthAndCase(b);
    if (na.isEmpty && nb.isEmpty) return 1.0;
    if (na.isEmpty || nb.isEmpty) return 0.0;
    if (na == nb) return 1.0;

    final maxLen = math.max(na.length, nb.length);
    final levDistance = _levenshtein(na, nb);
    final levSim = 1.0 - (levDistance / maxLen);

    final tokensA = na.split(' ').where((t) => t.isNotEmpty).toList();
    final tokensB = nb.split(' ').where((t) => t.isNotEmpty).toList();
    final double tokenDice;
    if (tokensA.isEmpty || tokensB.isEmpty) {
      tokenDice = 0.0;
    } else {
      final countsB = <String, int>{};
      for (final tok in tokensB) {
        countsB[tok] = (countsB[tok] ?? 0) + 1;
      }
      var intersection = 0;
      for (final tok in tokensA) {
        final remaining = countsB[tok] ?? 0;
        if (remaining > 0) {
          intersection++;
          countsB[tok] = remaining - 1;
        }
      }
      tokenDice = (2.0 * intersection) / (tokensA.length + tokensB.length);
    }

    return ((0.5 * levSim) + (0.5 * tokenDice)).clamp(0.0, 1.0);
  }

  static int _levenshtein(String a, String b) {
    final m = a.length;
    final n = b.length;
    if (m == 0) return n;
    if (n == 0) return m;

    var prev = List<int>.generate(n + 1, (j) => j, growable: false);
    var curr = List<int>.filled(n + 1, 0, growable: false);

    for (var i = 1; i <= m; i++) {
      curr[0] = i;
      final ca = a.codeUnitAt(i - 1);
      for (var j = 1; j <= n; j++) {
        final cost = ca == b.codeUnitAt(j - 1) ? 0 : 1;
        final del = prev[j] + 1;
        final ins = curr[j - 1] + 1;
        final sub = prev[j - 1] + cost;
        curr[j] = math.min(del, math.min(ins, sub));
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[n];
  }

  /// Scores how well [candidate] satisfies [query].
  /// Returns `1.0` on exact normalized ISRC match, `null` when rejected by
  /// duration delta or matching thresholds, and `[0.80..1.0]` otherwise.
  static double? scoreMatch(TrackMatchQuery query, TrackMetadata candidate) {
    final qIsrc = normalizeIsrc(query.isrc);
    final cIsrc = normalizeIsrc(candidate.isrc);
    if (qIsrc != null && cIsrc != null && qIsrc == cIsrc) {
      return 1.0;
    }

    if (query.durationMs != null &&
        query.durationMs! > 0 &&
        candidate.durationMs > 0) {
      final delta = (query.durationMs! - candidate.durationMs).abs();
      if (delta > maxDurationDeltaMs) {
        return null;
      }
    }

    final qTitle = normalizeTitleForMatching(query.title);
    final cTitle = normalizeTitleForMatching(candidate.title);
    if (qTitle.isEmpty || cTitle.isEmpty) {
      return null;
    }
    final titleScore = similarity(qTitle, cTitle);

    final qFullArtist = normalizeArtistForMatching(query.artist);
    final qPrimArtist = normalizeArtistForMatching(
      extractPrimaryArtist(query.artist),
    );
    final cFullArtist = normalizeArtistForMatching(candidate.artist);
    final cPrimArtist = normalizeArtistForMatching(
      candidate.primaryArtist.trim().isNotEmpty
          ? extractPrimaryArtist(candidate.primaryArtist)
          : extractPrimaryArtist(candidate.artist),
    );

    if ((qFullArtist.isEmpty && qPrimArtist.isEmpty) ||
        (cFullArtist.isEmpty && cPrimArtist.isEmpty)) {
      return null;
    }

    var artistScore = 0.0;
    for (final qa in <String>[qFullArtist, qPrimArtist]) {
      if (qa.isEmpty) continue;
      for (final ca in <String>[cFullArtist, cPrimArtist]) {
        if (ca.isEmpty) continue;
        artistScore = math.max(artistScore, similarity(qa, ca));
      }
    }

    final weighted = (0.65 * titleScore) + (0.35 * artistScore);
    final passes = (titleScore >= 0.78 && artistScore >= 0.70) ||
        (weighted >= 0.80 && artistScore >= 0.65);
    if (!passes) {
      return null;
    }
    return weighted.clamp(0.0, 1.0);
  }

  /// Ranks playback quality so Hi-Res lossless > CD lossless > high-bitrate
  /// lossy > low-bitrate lossy, with local lossless prioritized within tier.
  static int qualityRank(TrackMetadata candidate) {
    final fmt = candidate.format;
    final label = candidate.qualityLabel?.trim().toUpperCase() ?? '';
    final isLocal = candidate.providerId == 'local' ||
        (candidate.filePath != null && candidate.filePath!.trim().isNotEmpty);

    final isDsd = fmt.isDsd ||
        fmt.codec == AudioCodec.dsf ||
        fmt.codec == AudioCodec.dsdiff ||
        label.contains('DSD');

    final isHiResLabel = label.contains('HI_RES') ||
        label.contains('HI-RES') ||
        label.contains('HIRES') ||
        label.contains('MASTER') ||
        label.contains('STUDIO');

    final isHiResPcm = fmt.codec.isLossless &&
        ((fmt.bitDepth >= 24 && fmt.sampleRateHz >= 88200) ||
            fmt.sampleRateHz >= 88200);

    final localBonus = (isLocal && (fmt.codec.isLossless || isDsd)) ? 50 : 0;

    if (isDsd || isHiResPcm || (isHiResLabel && fmt.codec.isLossless)) {
      final bitBonus = fmt.bitDepth >= 24 ? 20 : 0;
      final rateBonus = isDsd
          ? 45
          : (fmt.sampleRateHz ~/ 1000).clamp(0, 40);
      return 400 + bitBonus + rateBonus + localBonus;
    }

    final isLosslessLabel = label.contains('LOSSLESS') ||
        label.contains('HIFI') ||
        label.contains('FLAC') ||
        label.contains('ALAC');

    if (fmt.codec.isLossless || isLosslessLabel) {
      final bitBonus = fmt.bitDepth >= 24 ? 10 : 0;
      return 300 + bitBonus + localBonus;
    }

    final kbps = fmt.bitrateKbps ?? 0;
    final isHighLossy = kbps >= 192 ||
        (fmt.codec == AudioCodec.opus && kbps >= 128) ||
        label.contains('HIGH') ||
        label.contains('320') ||
        label.contains('256');
    if (isHighLossy) {
      final effectiveKbps = kbps > 0 ? kbps : 192;
      return 200 + (effectiveKbps ~/ 32).clamp(0, 20);
    }

    final effectiveKbps = kbps > 0 ? kbps : 96;
    return 100 + (effectiveKbps ~/ 32).clamp(0, 10);
  }

  /// Selects the best match from [candidates]: exact normalized ISRC matches
  /// always win (ranked by [qualityRank]), else highest [scoreMatch] then
  /// highest [qualityRank].
  static TrackMetadata? selectBestMatch(
    TrackMatchQuery query,
    Iterable<TrackMetadata> candidates,
  ) {
    final qIsrc = normalizeIsrc(query.isrc);
    if (qIsrc != null) {
      TrackMetadata? bestIsrcMatch;
      var bestIsrcQuality = -1;
      for (final candidate in candidates) {
        final cIsrc = normalizeIsrc(candidate.isrc);
        if (cIsrc != null && cIsrc == qIsrc) {
          final rank = qualityRank(candidate);
          if (bestIsrcMatch == null || rank > bestIsrcQuality) {
            bestIsrcMatch = candidate;
            bestIsrcQuality = rank;
          }
        }
      }
      if (bestIsrcMatch != null) {
        return bestIsrcMatch;
      }
    }

    TrackMetadata? best;
    var bestScore = -1.0;
    var bestQuality = -1;

    for (final candidate in candidates) {
      final score = scoreMatch(query, candidate);
      if (score == null) continue;
      final quality = qualityRank(candidate);

      if (best == null ||
          score > bestScore + 1e-6 ||
          ((score - bestScore).abs() <= 1e-6 && quality > bestQuality)) {
        best = candidate;
        bestScore = score;
        bestQuality = quality;
      }
    }

    return best;
  }
}
