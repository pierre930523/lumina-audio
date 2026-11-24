import '../../models/audio_format.dart';
import '../../models/playback_state.dart';
import '../../models/stream_source_spec.dart';
import '../../models/streaming_models.dart';
import 'streaming_provider.dart';

/// Unified stream-resolution interface implemented by all playback sources.
abstract interface class StreamResolver {
  String get providerId;
  ProviderCapabilities get capabilities;

  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  });
}

/// Built-in resolver for local filesystem tracks (`providerId: 'local'`).
class LocalStreamResolver implements StreamResolver {
  const LocalStreamResolver();

  @override
  String get providerId => 'local';

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities.local;

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    final path = key.trackId.trim();
    if (path.isEmpty) {
      throw const StreamingException('本地音軌缺少有效的檔案路徑');
    }
    return LocalFileSpec(key: key, path: path);
  }
}

/// Built-in resolver for external RSS podcast audio URLs (`providerId: 'podcast_rss'`).
///
/// Emits a [DirectRangeSpec] with standard browser `User-Agent` and `Accept`
/// headers plus inferred MIME/extension hints so Rust `ChunkedStreamProxy`
/// handles redirects, range seeking, and Symphonia probing reliably without
/// ever requiring account login or YouTube `videoId` parsing.
class ExternalPodcastRssResolver implements StreamResolver {
  static const String defaultBrowserUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static const Map<String, String> defaultBrowserHeaders = <String, String>{
    'User-Agent': defaultBrowserUserAgent,
    'Accept': '*/*',
    'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8',
  };

  const ExternalPodcastRssResolver();

  @override
  String get providerId => 'podcast_rss';

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities.podcastRss;

  /// Extracts a clean `http://` or `https://` URL from a prefixed or raw track ID.
  static String extractUrl(String raw) {
    var candidate = raw.trim();
    for (final prefix in const <String>[
      'streaming:podcast_rss:',
      'podcast_rss:',
      'rss:',
    ]) {
      if (candidate.startsWith(prefix)) {
        candidate = candidate.substring(prefix.length).trim();
        break;
      }
    }
    return candidate;
  }

  static ({String? mimeType, String? hintExtension, AudioFormat? audioFormat})
      inferAudioMetadata(String url) {
    final uri = Uri.tryParse(url);
    final path = (uri?.path ?? url).toLowerCase();
    if (path.endsWith('.mp3') || path.contains('.mp3/')) {
      return (
        mimeType: 'audio/mpeg',
        hintExtension: 'mp3',
        audioFormat: const AudioFormat(
          codec: AudioCodec.mp3,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
        ),
      );
    }
    if (path.endsWith('.m4a') || path.endsWith('.mp4')) {
      return (
        mimeType: 'audio/mp4',
        hintExtension: 'm4a',
        audioFormat: const AudioFormat(
          codec: AudioCodec.aac,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
        ),
      );
    }
    if (path.endsWith('.aac')) {
      return (
        mimeType: 'audio/aac',
        hintExtension: 'aac',
        audioFormat: const AudioFormat(
          codec: AudioCodec.aac,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
        ),
      );
    }
    if (path.endsWith('.webm')) {
      return (
        mimeType: 'audio/webm',
        hintExtension: 'webm',
        audioFormat: const AudioFormat(
          codec: AudioCodec.opus,
          sampleRateHz: 48000,
          bitDepth: 16,
          channels: 2,
        ),
      );
    }
    if (path.endsWith('.opus') || path.endsWith('.ogg') || path.endsWith('.oga')) {
      return (
        mimeType: 'audio/ogg',
        hintExtension: 'ogg',
        audioFormat: const AudioFormat(
          codec: AudioCodec.opus,
          sampleRateHz: 48000,
          bitDepth: 16,
          channels: 2,
        ),
      );
    }
    if (path.endsWith('.flac')) {
      return (
        mimeType: 'audio/flac',
        hintExtension: 'flac',
        audioFormat: const AudioFormat(
          codec: AudioCodec.flac,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
        ),
      );
    }
    if (path.endsWith('.wav')) {
      return (
        mimeType: 'audio/wav',
        hintExtension: 'wav',
        audioFormat: const AudioFormat(
          codec: AudioCodec.wav,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
        ),
      );
    }
    // Redirecting podcast CDN URLs (e.g. Podtrac/Megaphone/Anchor) may not carry
    // a file extension in the path; leave mimeType/hintExtension null so Rust
    // probes the redirected stream cleanly.
    return (mimeType: null, hintExtension: null, audioFormat: null);
  }

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    final cleanUrl = extractUrl(key.trackId);
    final uri = Uri.tryParse(cleanUrl);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw StreamingException('無效的外部 Podcast 音訊網址：$cleanUrl');
    }

    final meta = inferAudioMetadata(cleanUrl);
    return DirectRangeSpec(
      key: StreamKey(providerId, cleanUrl, key.qualityKey),
      url: cleanUrl,
      headers: defaultBrowserHeaders,
      mimeType: meta.mimeType,
      hintExtension: meta.hintExtension,
      audioFormat: meta.audioFormat,
    );
  }
}

/// Adapter that bridges legacy [StreamingProvider] mocks/fakes (which do not
/// directly implement [StreamResolver]) into [StreamResolverRegistry].
class LegacyStreamingProviderResolver implements StreamResolver {
  final StreamingProvider provider;
  @override
  final ProviderCapabilities capabilities;

  LegacyStreamingProviderResolver(
    this.provider, {
    ProviderCapabilities? capabilities,
  }) : capabilities = capabilities ?? _defaultCapabilitiesFor(provider.kind);

  @override
  String get providerId => provider.kind;

  static ProviderCapabilities _defaultCapabilitiesFor(String kind) {
    return switch (kind) {
      'youtube_music' => ProviderCapabilities.youtubeMusic,
      'qobuz' => ProviderCapabilities.qobuz,
      'tidal' => ProviderCapabilities.tidal,
      'deezer' => ProviderCapabilities.deezer,
      // Legacy fake apple_music providers in unit tests expect L1 caching.
      'apple_music' => const ProviderCapabilities(
        supportsL1UrlCache: true,
        supportsL2HeadCache: false,
        requiresRangeChunking: false,
        needsNetworkEpochReset: false,
        defaultL1SafetyMarginSec: 0,
      ),
      _ => ProviderCapabilities.local,
    };
  }

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) {
    final syntheticTrack = TrackInfo(
      id: '${key.providerId}:${key.trackId}',
      title: key.trackId,
      artist: '',
      album: '',
      duration: Duration.zero,
      format: const AudioFormat(
        codec: AudioCodec.flac,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
      ),
      providerName: provider.meta.name,
    );
    return resolveWithTrack(key, syntheticTrack, cancelToken: cancelToken);
  }

  Future<StreamSourceSpec> resolveWithTrack(
    StreamKey key,
    TrackInfo track, {
    CancellationToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    final result = await provider.resolveStream(track, cancel: cancelToken);
    cancelToken?.throwIfCancelled();

    final uri = Uri.tryParse(result.url);
    final expireParam = uri?.queryParameters['expire'];
    final expireAt = expireParam != null ? int.tryParse(expireParam) : null;

    return DirectRangeSpec(
      key: key,
      url: result.url,
      headers: result.headers,
      hintExtension: result.hintExtension,
      expireAt: expireAt,
      audioFormat: result.format,
      isPreviewOnly: result.isPreviewOnly,
      notice: result.drmNotice,
      externalWebUrl: result.externalWebUrl,
    );
  }
}

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
