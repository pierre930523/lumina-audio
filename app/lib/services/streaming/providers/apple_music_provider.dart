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

part 'apple_music/apple_music_auth.dart';
part 'apple_music/apple_music_catalog.dart';
part 'apple_music/apple_music_discover.dart';
part 'apple_music/apple_music_parsers.dart';
part 'apple_music/apple_music_recommendations.dart';
part 'apple_music/apple_music_stream.dart';

/// Real Apple Music API + MusicKit JS v3 provider with honest Windows FairPlay DRM handling.
class AppleMusicProvider extends BaseStreamingProvider
    implements StreamResolver, RecommendationProvider {
  static const String windowsFairPlayDrmNotice =
      'Windows 平台受 Apple FairPlay DRM 保護，無法直接將完整無損 ALAC PCM 串流送入原生 WASAPI/ASIO 管線。'
      'Lumina Audio 支援真實同步個人曲庫、歌單、高解析封面與搜尋，播放時將提供官方 AAC 試聽片段或開啟網頁播放器。';

  final String apiBaseUrl;
  final int oauthCallbackPort;
  final Future<bool> Function(String url)? urlOpener;

  String? _developerToken;
  String? _musicUserToken;
  String _storefront = 'us';
  String? _nextRecommendationsPath;

  final Map<String, String> _catalogIdByTrackId = <String, String>{};
  final Map<String, String> _previewUrlByTrackId = <String, String>{};
  final Map<String, String> _externalWebUrlByTrackId = <String, String>{};

  AppleMusicProvider({
    required super.credentialStore,
    super.httpClientFactory,
    super.requestTimeout,
    super.clock,
    this.apiBaseUrl = 'https://api.music.apple.com',
    this.oauthCallbackPort = 0,
    this.urlOpener,
  });

  @override
  String get kind => 'apple_music';

  @override
  String get providerId => kind;

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities.appleMusic;

  String? get developerToken => _developerToken;
  String? get musicUserToken => _musicUserToken;
  String get storefront => _storefront;

  Map<String, String> get _authHeaders => <String, String>{
    'Authorization': 'Bearer ${_developerToken ?? ''}',
    'Music-User-Token': _musicUserToken ?? '',
    'Accept': 'application/json',
  };

  @override
  Future<void> restoreFromStorage() => _restoreFromStorageImpl();

  @override
  Future<void> authenticate(
    Map<String, dynamic> params, {
    CancellationToken? cancel,
    void Function(String statusMsg)? onProgress,
  }) =>
      _authenticateImpl(params, cancel: cancel, onProgress: onProgress);

  @override
  Future<void> refreshSessionIfNeeded({bool force = false}) async {
    // MusicKit Developer / User tokens are validated live on restore and requests.
  }

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
  }) =>
      _fetchRecommendationsImpl(
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
  }) =>
      _fetchAlbumDetailImpl(albumId, cancel: cancel);

  @override
  Future<List<TrackInfo>> fetchPlaylistTracks(String playlistId) =>
      _fetchPlaylistTracksImpl(playlistId);

  @override
  Future<StreamingCatalog> search(
    String query, {
    CancellationToken? cancel,
  }) =>
      _searchImpl(query, cancel: cancel);

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) =>
      _resolveImpl(key, cancelToken: cancelToken);

  @override
  Future<ResolvedStreamResult> resolveStream(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
  }) =>
      _resolveStreamImpl(
        track,
        cancel: cancel,
        timeout: timeout,
        playRequestId: playRequestId,
      );

  @override
  String get recommendationProviderId => kind;

  @override
  Future<RadioPage> getTrackRadio(
    TrackMetadata seed, {
    int limit = 10,
    String? cursor,
    CancellationToken? cancel,
  }) =>
      _getTrackRadioImpl(
        seed,
        limit: limit,
        cursor: cursor,
        cancel: cancel,
      );

  @override
  Future<List<FeedSection>> getPersonalizedFeed({
    CancellationToken? cancel,
  }) =>
      _getPersonalizedFeedImpl(cancel: cancel);

  @override
  Future<TrackMetadata?> matchTrack(
    TrackMatchQuery query, {
    CancellationToken? cancel,
  }) =>
      _matchTrackImpl(query, cancel: cancel);
}
