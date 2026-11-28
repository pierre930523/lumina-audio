import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../models/audio_format.dart';
import '../../../models/playback_state.dart';
import '../../../models/podcast_models.dart';
import '../../../models/recommendation_models.dart';
import '../../../models/stream_source_spec.dart';
import '../../../models/streaming_models.dart';
import '../../../models/studio_models.dart';
import '../oauth_helper.dart';
import '../pot_provider.dart';
import '../recommendation_provider.dart';
import '../stream_resolver.dart';
import '../streaming_provider.dart';
import '../track_matcher.dart';
import '../yt_dlp_service.dart';
import '../ytm_resident_resolver.dart';

part 'youtube_music/ytm_auth.dart';
part 'youtube_music/ytm_catalog.dart';
part 'youtube_music/ytm_innertube_audio.dart';
part 'youtube_music/ytm_innertube_client.dart';
part 'youtube_music/ytm_json_helpers.dart';
part 'youtube_music/ytm_music_parsers.dart';
part 'youtube_music/ytm_podcasts_api.dart';
part 'youtube_music/ytm_podcasts_episode_parser.dart';
part 'youtube_music/ytm_podcasts_show_parser.dart';
part 'youtube_music/ytm_recommendations.dart';
part 'youtube_music/ytm_stream_resolver.dart';
part 'youtube_music/ytm_video_id_cookies.dart';
part 'youtube_music/ytm_ytdlp_fallback.dart';

/// Real YouTube Music InnerTube + Google OAuth 2.0 Device Flow + yt-dlp provider.
class YouTubeMusicProvider extends BaseStreamingProvider
    implements StreamResolver, RecommendationProvider {
  static const String _ytMusicOrigin = 'https://music.youtube.com';
  static const String _ytWebOrigin = 'https://www.youtube.com';
  static const String _youtubeScope =
      'https://www.googleapis.com/auth/youtube.readonly';
  static const String _webRemixClientNameHeader = '67';
  static const String _webRemixClientVersion = '1.20241120.01.00';
  static const String _desktopChromeUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  /// Live-probed YouTube Music InnerTube `search` filter params for Podcast
  /// shows (`Podcast` chip) and episodes (`單集節目` chip).
  static const String podcastShowsSearchParams =
      'EgWKAQJQAWoSEBEQEBAFEAMQBBAKEAkQFRAO';
  static const String podcastEpisodesSearchParams =
      'EgWKAQJIAWoSEBEQEBAFEAMQBBAKEAkQFRAO';

  final String baseUrl;
  final String oauthBaseUrl;
  final Future<bool> Function(String url)? urlOpener;
  final YtDlpService _ytDlpService;
  late final YtmResidentResolver _residentResolver;
  final bool _ownsResidentResolver;

  String _authMode = 'cookie';
  String? _cookie;
  String? _clientId;
  String? _clientSecret;
  String? _accessToken;
  String? _refreshToken;
  DateTime? _expiresAt;
  String? _visitorData;
  String? _nextHomeContinuation;
  String? _nextExploreContinuation;
  final List<String> _recentSeedVideoIds = <String>[];
  int _fallbackRequestCounter = 0;
  Future<void>? _inFlightRefresh;

  YouTubeMusicProvider({
    required super.credentialStore,
    HttpClient Function()? httpClientFactory,
    Duration requestTimeout = const Duration(seconds: 15),
    super.clock,
    this.baseUrl = _ytMusicOrigin,
    this.oauthBaseUrl = 'https://oauth2.googleapis.com',
    this.urlOpener,
    YtDlpService? ytDlpService,
    YtmResidentResolver? residentResolver,
    PotProvider? potProvider,
    bool ownsPotProvider = false,
    VoidCallback? onHttp2Warmup,
  }) : _ytDlpService = ytDlpService ?? YtDlpService.instance,
       _ownsResidentResolver = residentResolver == null,
       super(
         httpClientFactory: httpClientFactory,
         requestTimeout: requestTimeout,
       ) {
    _residentResolver = residentResolver ??
        YtmResidentResolver(
          httpClient: httpClientFactory?.call(),
          authProvider: () => _currentResidentAuthImpl(),
          potProvider: potProvider,
          ownsPotProvider: ownsPotProvider,
          onHttp2Warmup: onHttp2Warmup,
          fallbackResolver: ({
            required key,
            required videoId,
            required auth,
            required gvsToken,
            required playerToken,
            required visitorData,
            cancelToken,
          }) => _resolveSpecViaYtDlpFallback(
            key: key,
            videoId: videoId,
            auth: auth,
            gvsToken: gvsToken,
            playerToken: playerToken,
            visitorData: visitorData,
            cancelToken: cancelToken,
          ),
          webBaseUrl: baseUrl == _ytMusicOrigin
              ? YtmResidentResolver.defaultWebOrigin
              : baseUrl,
          musicBaseUrl: baseUrl,
          requestTimeout: requestTimeout,
          clock: clock,
        );
  }

  @override
  String get kind => 'youtube_music';

  @override
  String get providerId => kind;

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities.youtubeMusic;

  @override
  bool get supportsSilentRefresh =>
      _authMode == 'oauth_device' &&
      (_refreshToken?.trim().isNotEmpty ?? false) &&
      (_clientId?.trim().isNotEmpty ?? false);

  @override
  Future<void> forceRefreshSession() => refreshSessionIfNeeded(force: true);

  @visibleForTesting
  YtmResidentResolver get residentResolver => _residentResolver;

  /// Async background warmup pre-warming InnerTube TLS/HTTP2 pools, session
  /// `visitorData`, and Session-level GVS PO Token via [YtmResidentResolver].
  Future<void> warmup({bool force = false}) =>
      _residentResolver.warmup(force: force);

  /// Resets the resident HTTP client and invalidates cached session `visitorData`
  /// & GVS PO Token after a network interface / IP transition.
  void handleNetworkEpochChanged() {
    _residentResolver.resetHttpClient();
    _residentResolver.invalidateSession();
  }

  /// Notifies the resident resolver that authentication state has been restored
  /// so any guest-mode session context or GVS PO Token is invalidated.
  void onAuthSessionRestored() {
    if (authState == StreamingAuthState.connected) {
      _residentResolver.invalidateSession();
    }
  }

  Future<void> disposeAsync() async {
    if (_ownsResidentResolver) {
      await _residentResolver.disposeAsync();
    }
  }

  void dispose() {
    if (_ownsResidentResolver) {
      _residentResolver.dispose();
    }
  }

  @override
  bool get supportsGuestMode => true;

  @visibleForTesting
  String? get visitorData => _visitorData;

  /// Parses `SAPISID` / `__Secure-3PAPISID` / `__Secure-1PAPISID` from a browser
  /// Cookie header and computes the Google `SAPISIDHASH` Authorization value.
  static String? extractSapisidFromCookie(String cookieHeader) =>
      _ytmExtractSapisidFromCookie(cookieHeader);

  static String computeSapisidHash(
    String sapisid, {
    required int timestampSeconds,
    String origin = _ytMusicOrigin,
  }) => _ytmComputeSapisidHash(
    sapisid,
    timestampSeconds: timestampSeconds,
    origin: origin,
  );

  /// Non-throwing variant of [extractCleanVideoId] for background preloaders.
  static String? tryExtractCleanVideoId(String rawId, {String? filePath}) =>
      _ytmTryExtractCleanVideoId(rawId, filePath: filePath);

  /// Strips internal prefixes (`ytm:`, `ytm_`, `streaming:youtube_music:`,
  /// `youtube_music:`), extracts the `v` param or `youtu.be/<id>` segment from
  /// YouTube URLs, and strictly validates a pure 11-char YouTube Video ID.
  ///
  /// Rejects `browseId` (`MPREb_`, `VL`, `FE`, `UC`) and `playlistId` (`PL`,
  /// `RD`, `OLAK`) values with a descriptive [StreamingException].
  @visibleForTesting
  static String extractCleanVideoId(String rawId, {String? filePath}) =>
      _ytmExtractCleanVideoId(rawId, filePath: filePath);

  /// Converts a browser `Cookie` header into a valid Netscape HTTP Cookie File
  /// covering `.youtube.com` and `music.youtube.com` for `yt-dlp --cookies`.
  @visibleForTesting
  static String buildNetscapeCookiesContent(
    String cookieHeader, {
    DateTime? now,
  }) => _ytmBuildNetscapeCookiesContent(cookieHeader, now: now);

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) => _resolveImpl(key, cancelToken: cancelToken);

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

  /// Clears cached stream URLs for [videoIdOrTrackId] (raw 11-char ID or
  /// prefixed track ID), or clears all cached YTM stream URLs when omitted.
  void clearStreamCache([String? videoIdOrTrackId]) =>
      _clearStreamCacheImpl(videoIdOrTrackId);

  /// Triggers low-priority background preloading for [track] via [YtDlpService]
  /// without interrupting foreground playback.
  Future<void> preloadTrack(TrackInfo track) => _preloadTrackImpl(track);

  @override
  Future<ResolvedStreamResult> resolveStream(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
    bool bypassCache = false,
  }) => _resolveStreamImpl(
    track,
    cancel: cancel,
    timeout: timeout,
    playRequestId: playRequestId,
    bypassCache: bypassCache,
  );

  /// Fetches the user's personal subscribed Podcast shows and new episodes.
  ///
  /// When authenticated, queries `FEmusic_library_non_music_audio_list` (and
  /// `VLSE` / embedded shelves for latest episodes). When unauthenticated,
  /// returns an empty [PodcastLibraryResult] so the UI can merge local
  /// bookmarks and show a compact login card.
  Future<PodcastLibraryResult> fetchMyPodcasts({CancellationToken? cancel}) =>
      _fetchMyPodcastsImpl(cancel: cancel);

  /// Fetches the Podcast Explore & Latest Episodes feed.
  ///
  /// Works in BOTH Guest Mode and Logged-in Mode. Calls `FEmusic_podcasts`,
  /// falling back to `FEmusic_non_music_audio` and then a filtered Podcast
  /// search fallback when the user's locale returns 404 or sparse data.
  Future<PodcastExploreResult> fetchExplorePodcasts({
    String? continuation,
    CancellationToken? cancel,
  }) => _fetchExplorePodcastsImpl(continuation: continuation, cancel: cancel);

  /// Searches YouTube Music specifically for Podcast shows and episodes.
  Future<PodcastSearchResult> searchPodcasts(
    String query, {
    CancellationToken? cancel,
  }) => _searchPodcastsImpl(query, cancel: cancel);

  /// Fetches full show metadata, ordered episodes, and continuation token for
  /// a YouTube Music Podcast show (`browseId` such as `MPSPPL...`).
  Future<PodcastShowDetail> fetchPodcastShowDetail(
    String showBrowseId, {
    String? continuation,
    CancellationToken? cancel,
  }) => _fetchPodcastShowDetailImpl(
    showBrowseId,
    continuation: continuation,
    cancel: cancel,
  );

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
