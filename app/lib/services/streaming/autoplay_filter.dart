import '../../models/recommendation_models.dart';
import 'track_matcher.dart';

/// Computes the 3-layer deduplication fingerprint tokens for a [TrackMetadata]:
/// 1. `(providerId, trackId)`
/// 2. normalized `isrc`
/// 3. `normalizedTitle::normalizedPrimaryArtist`
Set<String> _fingerprintsForTrack(TrackMetadata track) {
  final keys = <String>{};

  final pid = track.providerId.trim().toLowerCase();
  final tid = track.trackId.trim();
  if (pid.isNotEmpty && tid.isNotEmpty) {
    keys.add('id:$pid::$tid');
  }

  final isrc = TrackMatcher.normalizeIsrc(track.isrc);
  if (isrc != null) {
    keys.add('isrc:$isrc');
  }

  final normTitle = TrackMatcher.normalizeTitleForMatching(track.title);
  final rawPrimary = track.primaryArtist.trim().isNotEmpty
      ? track.primaryArtist
      : TrackMatcher.extractPrimaryArtist(track.artist);
  final normArtist = TrackMatcher.normalizeArtistForMatching(
    TrackMatcher.extractPrimaryArtist(rawPrimary),
  );
  if (normTitle.isNotEmpty && normArtist.isNotEmpty) {
    keys.add('ta:$normTitle::$normArtist');
  }

  return keys;
}

String _normalizedPrimaryArtistOf(TrackMetadata track) {
  final rawPrimary = track.primaryArtist.trim().isNotEmpty
      ? track.primaryArtist
      : TrackMatcher.extractPrimaryArtist(track.artist);
  return TrackMatcher.normalizeArtistForMatching(
    TrackMatcher.extractPrimaryArtist(rawPrimary),
  );
}

/// Bounded sliding window of recently played tracks with 3-layer fingerprint
/// lookup (`(providerId, trackId)`, normalized ISRC, and normalized title +
/// primary artist).
class RecentHistoryWindow {
  final int maxSize;
  final List<_HistoryEntry> _entries = <_HistoryEntry>[];
  final Map<String, int> _refCounts = <String, int>{};

  RecentHistoryWindow({this.maxSize = 50}) : assert(maxSize > 0);

  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;
  List<TrackMetadata> get entries =>
      List<TrackMetadata>.unmodifiable(_entries.map((e) => e.track));

  void record(TrackMetadata track) {
    final keys = _fingerprintsForTrack(track);
    _entries.add(_HistoryEntry(track: track, keys: keys));
    for (final k in keys) {
      _refCounts[k] = (_refCounts[k] ?? 0) + 1;
    }
    while (_entries.length > maxSize) {
      final evicted = _entries.removeAt(0);
      for (final k in evicted.keys) {
        final next = (_refCounts[k] ?? 1) - 1;
        if (next <= 0) {
          _refCounts.remove(k);
        } else {
          _refCounts[k] = next;
        }
      }
    }
  }

  void add(TrackMetadata track) => record(track);

  void addAll(Iterable<TrackMetadata> tracks) {
    for (final track in tracks) {
      record(track);
    }
  }

  bool contains(TrackMetadata track) {
    for (final key in _fingerprintsForTrack(track)) {
      if (_refCounts.containsKey(key)) {
        return true;
      }
    }
    return false;
  }

  Set<String> snapshotFingerprints() => Set<String>.from(_refCounts.keys);

  void clear() {
    _entries.clear();
    _refCounts.clear();
  }
}

class _HistoryEntry {
  final TrackMetadata track;
  final Set<String> keys;

  const _HistoryEntry({required this.track, required this.keys});
}

/// Tracks qualified autoplay seeds (max 5, round-robin over newest 3) and
/// quick-skipped artist cooldowns (30 minutes).
class EffectiveSeedPool {
  static const int maxSeeds = 5;
  static const int roundRobinWindow = 3;
  static const Duration minQualifiedPlayDuration = Duration(seconds: 45);
  static const double minQualifiedProgressRatio = 0.60;
  static const Duration quickSkipThreshold = Duration(seconds: 10);
  static const Duration artistCooldownDuration = Duration(minutes: 30);

  final List<TrackMetadata> _seeds = <TrackMetadata>[];
  final Set<String> _quickSkippedFingerprints = <String>{};
  final Map<String, DateTime> _artistCooldownUntil = <String, DateTime>{};
  int _roundRobinCursor = 0;

  List<TrackMetadata> get seeds => List<TrackMetadata>.unmodifiable(_seeds);
  bool get isEmpty => _seeds.isEmpty;
  int get length => _seeds.length;

  /// True iff [played] meets `>= 45s` or `>= 60%` of [total].
  static bool isQualifiedSeed(Duration played, Duration total) {
    if (played >= minQualifiedPlayDuration) return true;
    if (total > Duration.zero && played > Duration.zero) {
      return (played.inMilliseconds / total.inMilliseconds) >=
          minQualifiedProgressRatio;
    }
    return false;
  }

  /// Records a track as a qualified seed, deduplicating by 3-layer fingerprint
  /// and keeping the newest [maxSeeds] (5) entries.
  void recordQualifiedSeed(TrackMetadata track) {
    final incomingKeys = _fingerprintsForTrack(track);
    _quickSkippedFingerprints.removeAll(incomingKeys);

    _seeds.removeWhere((existing) {
      final existingKeys = _fingerprintsForTrack(existing);
      return existingKeys.any(incomingKeys.contains);
    });
    _seeds.add(track);

    while (_seeds.length > maxSeeds) {
      _seeds.removeAt(0);
    }
    _roundRobinCursor = 0;
  }

  /// Rotates through the newest up to [roundRobinWindow] (3) effective seeds.
  /// Falls back to [fallbackSeed] ONLY when the effective pool is empty and
  /// [fallbackSeed] was not quick-skipped.
  TrackMetadata? nextSeedForRefill({TrackMetadata? fallbackSeed}) {
    if (_seeds.isEmpty) {
      if (fallbackSeed == null) return null;
      final fallbackKeys = _fingerprintsForTrack(fallbackSeed);
      if (fallbackKeys.any(_quickSkippedFingerprints.contains)) {
        return null;
      }
      return fallbackSeed;
    }

    final windowCount =
        _seeds.length < roundRobinWindow ? _seeds.length : roundRobinWindow;
    // Rotate newest-first across the most recent up to 3 seeds.
    final recentNewestFirst = _seeds.reversed.take(windowCount).toList();
    final idx = _roundRobinCursor % recentNewestFirst.length;
    _roundRobinCursor = (idx + 1) % recentNewestFirst.length;
    return recentNewestFirst[idx];
  }

  /// Records a quick-skip (`< 10s`) on an auto-queued track: never promotes it
  /// to the seed pool, blocks it as a fallback seed, and sets a 30-minute
  /// downrank for its normalized primary artist.
  void recordQuickSkip(TrackMetadata autoTrack, DateTime now) {
    _quickSkippedFingerprints.addAll(_fingerprintsForTrack(autoTrack));
    final artistKey = _normalizedPrimaryArtistOf(autoTrack);
    if (artistKey.isNotEmpty) {
      _artistCooldownUntil[artistKey] = now.add(artistCooldownDuration);
    }
  }

  /// Returns `true` while [artist] is within its 30-minute quick-skip cooldown.
  bool isArtistDownranked(String artist, DateTime now) {
    final fullKey = TrackMatcher.normalizeArtistForMatching(artist);
    final primaryKey = TrackMatcher.normalizeArtistForMatching(
      TrackMatcher.extractPrimaryArtist(artist),
    );
    for (final key in <String>{fullKey, primaryKey}) {
      if (key.isEmpty) continue;
      final until = _artistCooldownUntil[key];
      if (until != null && now.isBefore(until)) {
        return true;
      }
    }
    return false;
  }

  void clear() {
    _seeds.clear();
    _quickSkippedFingerprints.clear();
    _artistCooldownUntil.clear();
    _roundRobinCursor = 0;
  }
}

/// Filters and orders autoplay candidates using 3-layer deduplication,
/// variant tag rejection, 3-consecutive primary artist cooldown, and
/// quick-skip artist downranking.
class AutoplayFilter {
  final RecentHistoryWindow recentHistory;
  final EffectiveSeedPool seedPool;

  AutoplayFilter({
    RecentHistoryWindow? recentHistory,
    EffectiveSeedPool? seedPool,
  })  : recentHistory = recentHistory ?? RecentHistoryWindow(),
        seedPool = seedPool ?? EffectiveSeedPool();

  static final RegExp _bracketLiveRegex = RegExp(
    r'[\(\[\{【][^)\]}】]*\blive\b[^)\]}】]*[\)\]}】]',
    caseSensitive: false,
  );
  static final RegExp _dashLiveRegex = RegExp(
    r'(?:^|\s)[-–—|/]\s*[^-–—|/]*\blive\b',
    caseSensitive: false,
  );
  static final RegExp _phraseLiveRegex = RegExp(
    r'(?:\s+live$|\blive\s+(?:version|ver\.?|edit|mix|recording|session|performance|concert|tour|acoustic|at|from|in|on)\b)',
    caseSensitive: false,
  );

  static final List<({String tag, RegExp pattern})> _otherVariantPatterns = [
    (tag: 'karaoke', pattern: RegExp(r'\bkaraoke\b', caseSensitive: false)),
    (
      tag: 'instrumental',
      pattern: RegExp(r'\binstrumental\b', caseSensitive: false),
    ),
    (tag: 'slowed', pattern: RegExp(r'\bslowed\b', caseSensitive: false)),
    (
      tag: 'sped_up',
      pattern: RegExp(r'\bsped\s+up\b', caseSensitive: false),
    ),
    (
      tag: 'nightcore',
      pattern: RegExp(r'\bnightcore\b', caseSensitive: false),
    ),
    (
      tag: '8d',
      pattern: RegExp(r'\b8d(?:\s+audio)?\b', caseSensitive: false),
    ),
  ];

  static Set<String> _extractVariantTags(String title) {
    final normalized = TrackMatcher.normalizeWidthAndCase(title);
    if (normalized.isEmpty) return const <String>{};

    final tags = <String>{};
    if (_bracketLiveRegex.hasMatch(normalized) ||
        _dashLiveRegex.hasMatch(normalized) ||
        _phraseLiveRegex.hasMatch(normalized)) {
      tags.add('live');
    }
    for (final entry in _otherVariantPatterns) {
      if (entry.pattern.hasMatch(normalized)) {
        tags.add(entry.tag);
      }
    }
    return tags;
  }

  /// Returns `true` iff [candidateTitle] contains a variant tag (`live`,
  /// `karaoke`, `instrumental`, `slowed`, `sped up`, `nightcore`, `8d audio`,
  /// `8d`) not present in [seedTitle].
  static bool isDisallowedVariant(
    String candidateTitle, {
    required String seedTitle,
  }) {
    final candidateTags = _extractVariantTags(candidateTitle);
    if (candidateTags.isEmpty) return false;
    final seedTags = _extractVariantTags(seedTitle);
    return candidateTags.difference(seedTags).isNotEmpty;
  }

  /// Filters [candidates] against [recentHistory], [activeQueueTail],
  /// disallowed variants, quick-skipped artist cooldowns, and the rolling
  /// 3-consecutive primary artist cooldown.
  List<TrackMetadata> filterCandidates({
    required List<TrackMetadata> candidates,
    required TrackMetadata seed,
    required List<TrackMetadata> activeQueueTail,
    required DateTime now,
    int? limit,
  }) {
    if (limit != null && limit <= 0) return const <TrackMetadata>[];
    if (candidates.isEmpty) return const <TrackMetadata>[];

    final seenKeys = recentHistory.snapshotFingerprints()
      ..addAll(_fingerprintsForTrack(seed));
    for (final queued in activeQueueTail) {
      seenKeys.addAll(_fingerprintsForTrack(queued));
    }

    final rollingArtists = <String>[];
    final tailStart = activeQueueTail.length > 2
        ? activeQueueTail.length - 2
        : 0;
    for (var i = tailStart; i < activeQueueTail.length; i++) {
      final artistKey = _normalizedPrimaryArtistOf(activeQueueTail[i]);
      if (artistKey.isNotEmpty) {
        rollingArtists.add(artistKey);
      }
    }

    final eligible = <TrackMetadata>[];
    for (final candidate in candidates) {
      final candidateKeys = _fingerprintsForTrack(candidate);
      if (candidateKeys.any(seenKeys.contains)) {
        continue;
      }
      seenKeys.addAll(candidateKeys);

      if (isDisallowedVariant(candidate.title, seedTitle: seed.title)) {
        continue;
      }

      final artistKey = _normalizedPrimaryArtistOf(candidate);
      if (artistKey.isNotEmpty && seedPool.isArtistDownranked(artistKey, now)) {
        continue;
      }

      eligible.add(candidate);
    }

    final selected = <TrackMetadata>[];
    final remaining = List<TrackMetadata>.from(eligible);

    while (remaining.isNotEmpty && (limit == null || selected.length < limit)) {
      var pickedIndex = -1;
      for (var i = 0; i < remaining.length; i++) {
        final artistKey = _normalizedPrimaryArtistOf(remaining[i]);
        if (artistKey.isEmpty || !rollingArtists.contains(artistKey)) {
          pickedIndex = i;
          break;
        }
      }
      if (pickedIndex < 0) {
        break;
      }

      final chosen = remaining.removeAt(pickedIndex);
      selected.add(chosen);

      final artistKey = _normalizedPrimaryArtistOf(chosen);
      if (artistKey.isNotEmpty) {
        rollingArtists.add(artistKey);
        if (rollingArtists.length > 2) {
          rollingArtists.removeAt(0);
        }
      }
    }

    return selected;
  }
}
