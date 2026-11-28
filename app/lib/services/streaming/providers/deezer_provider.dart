import 'dart:convert';

import '../../../models/audio_format.dart';
import '../../../models/playback_state.dart';
import '../../../models/recommendation_models.dart';
import '../../../models/stream_source_spec.dart';
import '../../../models/streaming_models.dart';
import '../../../models/studio_models.dart';
import '../oauth_helper.dart';
import '../recommendation_provider.dart';
import '../stream_resolver.dart';
import '../streaming_provider.dart';
import '../track_matcher.dart';

part 'deezer/deezer_auth.dart';
part 'deezer/deezer_gateway_api.dart';
part 'deezer/deezer_catalog.dart';
part 'deezer/deezer_recommendations.dart';
part 'deezer/deezer_stream_resolver.dart';
part 'deezer/deezer_parsers.dart';
part 'deezer/deezer_radio_feed.dart';

/// Real Deezer ARL (`gw-light.php` + `media.deezer.com`) & OAuth 2.0 provider.
class DeezerProvider extends BaseStreamingProvider
    implements StreamResolver, RecommendationProvider {
  static const String _previewNotice =
      '目前僅提供 Deezer 官方 30 秒 MP3 試聽片段；完整無損串流需有效付費 ARL 工作階段與授權金鑰。';

  final String gwUrl;
  final String oauthBaseUrl;
  final String apiBaseUrl;
  final String mediaBaseUrl;
  final int oauthCallbackPort;
  final Future<bool> Function(String url)? urlOpener;

  String _authMode = 'arl';
  String? _arl;
  String? _accessToken;
  String? _userId;
  String? _apiToken;
  String? _licenseToken;
  bool _webLossless = false;
  bool _webHq = false;
  Future<void>? _inFlightRefresh;

  final Map<String, String> _previewUrlCache = <String, String>{};

  DeezerProvider({
    required super.credentialStore,
    super.httpClientFactory,
    super.requestTimeout,
    super.clock,
    this.gwUrl = 'https://www.deezer.com/ajax/gw-light.php',
    this.oauthBaseUrl = 'https://connect.deezer.com',
    this.apiBaseUrl = 'https://api.deezer.com',
    this.mediaBaseUrl = 'https://media.deezer.com/v1/get_url',
    this.oauthCallbackPort = 0,
    this.urlOpener,
  });

  @override
  String get kind => 'deezer';

  @override
  String get providerId => kind;

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities.deezer;

  @override
  bool get supportsSilentRefresh =>
      _authMode == 'arl' && (_arl?.trim().isNotEmpty ?? false);

  @override
  Future<void> forceRefreshSession() => refreshSessionIfNeeded(force: true);

  @override
  Future<void> restoreFromStorage() => _restoreFromStorageImpl();

  @override
  Future<void> authenticate(
    Map<String, dynamic> params, {
    CancellationToken? cancel,
    void Function(String statusMsg)? onProgress,
  }) => _authenticateImpl(params, cancel: cancel, onProgress: onProgress);

  @override
  Future<void> refreshSessionIfNeeded({bool force = false}) =>
      _refreshSessionIfNeededImpl(force: force);

  @override
  Future<void> logout() => _logoutImpl();

  @override
  Future<StreamingCatalog> syncLibrary({CancellationToken? cancel}) =>
      _syncLibraryImpl(cancel: cancel);

  @override
  Future<StreamingRecommendations> fetchRecommendations({
    CancellationToken? cancel,
    bool forceRefresh = false,
    int batchIndex = 0,
    Set<String> excludeAlbumIds = const <String>{},
    Set<String> excludeTrackIds = const <String>{},
  }) => _fetchRecommendationsImpl(
    cancel: cancel,
    forceRefresh: forceRefresh,
    batchIndex: batchIndex,
    excludeAlbumIds: excludeAlbumIds,
    excludeTrackIds: excludeTrackIds,
  );

  @override
  Future<CanonicalAlbumDetail?> fetchAlbumDetail(
    String albumId, {
    CancellationToken? cancel,
  }) => _fetchAlbumDetailImpl(albumId, cancel: cancel);

  @override
  Future<List<TrackInfo>> fetchPlaylistTracks(String playlistId) =>
      _fetchPlaylistTracksImpl(playlistId);

  @override
  Future<StreamingCatalog> search(String query, {CancellationToken? cancel}) =>
      _searchImpl(query, cancel: cancel);

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) => _resolveImpl(key, cancelToken: cancelToken);

  @override
  Future<ResolvedStreamResult> resolveStream(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
  }) => _resolveStreamImpl(
    track,
    cancel: cancel,
    timeout: timeout,
    playRequestId: playRequestId,
  );

  AudioFormat get _catalogTrackFormat {
    if (_authMode == 'arl' && _webLossless) {
      return const AudioFormat(
        codec: AudioCodec.flac,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
      );
    }
    return const AudioFormat(
      codec: AudioCodec.mp3,
      sampleRateHz: 44100,
      bitDepth: 16,
      channels: 2,
    );
  }

  // ─── RecommendationProvider ────────────────────────────────────────────────

  @override
  String get recommendationProviderId => kind;

  @override
  Future<RadioPage> getTrackRadio(
    TrackMetadata seed, {
    int limit = 10,
    String? cursor,
    CancellationToken? cancel,
  }) => _getTrackRadioImpl(seed, limit: limit, cursor: cursor, cancel: cancel);

  @override
  Future<List<FeedSection>> getPersonalizedFeed({CancellationToken? cancel}) =>
      _getPersonalizedFeedImpl(cancel: cancel);

  @override
  Future<TrackMetadata?> matchTrack(
    TrackMatchQuery query, {
    CancellationToken? cancel,
  }) => _matchTrackImpl(query, cancel: cancel);
}
