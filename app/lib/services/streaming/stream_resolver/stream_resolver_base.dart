import '../../../models/audio_format.dart';
import '../../../models/playback_state.dart';
import '../../../models/stream_source_spec.dart';
import '../../../models/streaming_models.dart';
import '../streaming_provider.dart';

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
