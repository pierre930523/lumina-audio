import '../../../models/playback_state.dart';
import '../../../models/stream_source_spec.dart';
import '../../../models/streaming_models.dart';
import 'stream_resolver_base.dart';

class _PrefixRule {
  final String prefix;
  final String providerId;
  final bool stripPrefix;

  const _PrefixRule({
    required this.prefix,
    required this.providerId,
    required this.stripPrefix,
  });
}

class _ProviderSourceRule {
  final String tokenLower;
  final String providerId;

  const _ProviderSourceRule({
    required this.tokenLower,
    required this.providerId,
  });
}

/// Registry mapping `providerId`, track ID prefixes, and provider source names
/// to [StreamResolver]s without hardcoded platform branching in coordinators.
class StreamResolverRegistry {
  final Map<String, StreamResolver> _resolvers = <String, StreamResolver>{};
  final List<_PrefixRule> _prefixRules = <_PrefixRule>[];
  final List<_ProviderSourceRule> _sourceRules = <_ProviderSourceRule>[];
  final Map<String, String Function(TrackInfo track)> _trackIdExtractors =
      <String, String Function(TrackInfo track)>{};
  final Map<String, String Function(TrackInfo track)> _qualityExtractors =
      <String, String Function(TrackInfo track)>{};

  StreamResolverRegistry({bool includeLocalDefault = true}) {
    if (includeLocalDefault) {
      register(
        const LocalStreamResolver(),
        idPrefixes: const <String>['local:'],
        providerNames: const <String>['local library', 'local'],
        trackIdExtractor: (track) {
          final fp = track.filePath?.trim();
          if (fp != null && fp.isNotEmpty) return fp;
          return track.id.startsWith('local:')
              ? track.id.substring('local:'.length)
              : track.id;
        },
      );
    }
  }

  /// Registers [resolver] and optionally associates track ID prefixes and
  /// `TrackInfo.providerName` match tokens.
  void register(
    StreamResolver resolver, {
    List<String> idPrefixes = const <String>[],
    List<String> providerNames = const <String>[],
    bool stripMatchedPrefix = true,
    String Function(TrackInfo track)? trackIdExtractor,
    String Function(TrackInfo track)? qualityKeyExtractor,
  }) {
    final pid = resolver.providerId;
    _resolvers[pid] = resolver;
    registerMappings(
      pid,
      idPrefixes: idPrefixes,
      providerNames: providerNames,
      stripMatchedPrefix: stripMatchedPrefix,
      trackIdExtractor: trackIdExtractor,
      qualityKeyExtractor: qualityKeyExtractor,
    );
  }

  /// Associates track ID prefixes and `providerName` tokens with [providerId].
  void registerMappings(
    String providerId, {
    List<String> idPrefixes = const <String>[],
    List<String> providerNames = const <String>[],
    bool stripMatchedPrefix = true,
    String Function(TrackInfo track)? trackIdExtractor,
    String Function(TrackInfo track)? qualityKeyExtractor,
  }) {
    for (final prefix in idPrefixes) {
      if (prefix.isEmpty) continue;
      _prefixRules.removeWhere((r) => r.prefix == prefix);
      _prefixRules.add(
        _PrefixRule(
          prefix: prefix,
          providerId: providerId,
          stripPrefix: stripMatchedPrefix,
        ),
      );
    }
    _prefixRules.sort((a, b) => b.prefix.length.compareTo(a.prefix.length));

    for (final name in providerNames) {
      final token = name.trim().toLowerCase();
      if (token.isEmpty) continue;
      _sourceRules.removeWhere((r) => r.tokenLower == token);
      _sourceRules.add(
        _ProviderSourceRule(tokenLower: token, providerId: providerId),
      );
    }
    _sourceRules.sort(
      (a, b) => b.tokenLower.length.compareTo(a.tokenLower.length),
    );

    if (trackIdExtractor != null) {
      _trackIdExtractors[providerId] = trackIdExtractor;
    }
    if (qualityKeyExtractor != null) {
      _qualityExtractors[providerId] = qualityKeyExtractor;
    }
  }

  StreamResolver? resolverFor(String providerId) => _resolvers[providerId];

  ProviderCapabilities? capabilitiesFor(String providerId) =>
      _resolvers[providerId]?.capabilities;

  List<StreamResolver> get resolvers =>
      List<StreamResolver>.unmodifiable(_resolvers.values);

  bool hasStreamingMapping(TrackInfo track) {
    final pid = _matchProviderId(track)?.providerId;
    return pid != null && pid != 'local';
  }

  /// True only when [track.id] matches a registered non-local streaming ID
  /// prefix (and the track does not carry a local filesystem [TrackInfo.filePath]).
  /// This distinguishes genuine streaming tracks from demo/library tracks that
  /// merely carry display `providerName` metadata (e.g. `MockAudioService` `trk-001`).
  bool hasPrefixStreamingMapping(TrackInfo track) {
    if (track.filePath != null && track.filePath!.trim().isNotEmpty) {
      return false;
    }
    for (final rule in _prefixRules) {
      if (track.id.startsWith(rule.prefix)) {
        return rule.providerId != 'local';
      }
    }
    return false;
  }

  ({String providerId, _PrefixRule? matchedPrefix})? _matchProviderId(
    TrackInfo track,
  ) {
    for (final rule in _prefixRules) {
      if (track.id.startsWith(rule.prefix)) {
        return (providerId: rule.providerId, matchedPrefix: rule);
      }
    }
    final providerLower = track.providerName.trim().toLowerCase();
    if (providerLower.isNotEmpty) {
      for (final rule in _sourceRules) {
        if (providerLower == rule.tokenLower ||
            providerLower.contains(rule.tokenLower)) {
          return (providerId: rule.providerId, matchedPrefix: null);
        }
      }
    }
    if (track.filePath != null &&
        track.filePath!.trim().isNotEmpty &&
        _resolvers.containsKey('local')) {
      return (providerId: 'local', matchedPrefix: null);
    }
    return null;
  }

  /// Derives a canonical composite [StreamKey] from [track] using registered
  /// prefix/provider mappings without any hardcoded platform branching.
  StreamKey deriveKey(TrackInfo track, {String? qualityKey}) {
    final match = _matchProviderId(track);
    if (match == null) {
      throw StreamingException(
        '找不到對應的串流解析器（id=${track.id}, provider=${track.providerName}）',
      );
    }
    final providerId = match.providerId;
    final customExtractor = _trackIdExtractors[providerId];
    final String cleanTrackId;
    if (customExtractor != null) {
      cleanTrackId = customExtractor(track);
    } else if (match.matchedPrefix != null && match.matchedPrefix!.stripPrefix) {
      cleanTrackId = track.id.substring(match.matchedPrefix!.prefix.length);
    } else {
      var candidate = track.id;
      for (final rule in _prefixRules) {
        if (rule.providerId == providerId &&
            rule.stripPrefix &&
            candidate.startsWith(rule.prefix)) {
          candidate = candidate.substring(rule.prefix.length);
          break;
        }
      }
      cleanTrackId = candidate;
    }

    final resolvedQuality =
        qualityKey ??
        _qualityExtractors[providerId]?.call(track) ??
        'default';

    return StreamKey(providerId, cleanTrackId, resolvedQuality);
  }

  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    final resolver = _resolvers[key.providerId];
    if (resolver == null) {
      throw StreamingException('未註冊的串流解析器：${key.providerId}');
    }
    return resolver.resolve(key, cancelToken: cancelToken);
  }

  Future<StreamSourceSpec> resolveTrack(
    TrackInfo track, {
    String? qualityKey,
    CancellationToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    final key = deriveKey(track, qualityKey: qualityKey);
    final resolver = _resolvers[key.providerId];
    if (resolver == null) {
      throw StreamingException('未註冊的串流解析器：${key.providerId}');
    }
    if (resolver is LegacyStreamingProviderResolver) {
      return resolver.resolveWithTrack(key, track, cancelToken: cancelToken);
    }
    return resolver.resolve(key, cancelToken: cancelToken);
  }
}
