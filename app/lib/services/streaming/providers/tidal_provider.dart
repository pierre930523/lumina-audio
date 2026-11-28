import 'dart:convert';

import 'package:flutter/foundation.dart';

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
import '../yt_dlp_service.dart';

part 'tidal/tidal_auth.dart';
part 'tidal/tidal_auth_flows.dart';
part 'tidal/tidal_catalog.dart';
part 'tidal/tidal_recommendations.dart';
part 'tidal/tidal_recommendations_parser.dart';
part 'tidal/tidal_stream_tiers.dart';
part 'tidal/tidal_stream_resolver.dart';
part 'tidal/tidal_parsers.dart';
part 'tidal/tidal_radio_match.dart';
part 'tidal/tidal_personalized_feed.dart';

/// Real Tidal OAuth 2.0 (PKCE + Device Flow) and Hi-Res FLAC streaming provider.
class TidalProvider extends BaseStreamingProvider
    implements StreamResolver, RecommendationProvider {
  static const String defaultScopes = 'r_usr w_usr w_sub';
  static const String byokCredentialStorageKey = 'streaming:tidal:byok';

  final String authBaseUrl;
  final String tokenBaseUrl;
  final String apiBaseUrl;
  final int oauthCallbackPort;
  final Future<bool> Function(String url)? urlOpener;
  final YtDlpService? _ytDlpService;

  String? _clientId;
  String? _clientSecret;
  String? _accessToken;
  String? _refreshToken;
  DateTime? _expiresAt;
  String? _userId;
  String _countryCode = 'US';
  int _fallbackRequestCounter = -1;
  Future<void>? _inFlightRefresh;
  final List<String> _recentRecAlbumIds = <String>[];
  final List<String> _recentRecTrackIds = <String>[];

  TidalProvider({
    required super.credentialStore,
    super.httpClientFactory,
    super.requestTimeout,
    super.clock,
    this.authBaseUrl = 'https://login.tidal.com',
    this.tokenBaseUrl = 'https://auth.tidal.com',
    this.apiBaseUrl = 'https://api.tidal.com/v1',
    this.oauthCallbackPort = 0,
    this.urlOpener,
    YtDlpService? ytDlpService,
    // ignore: prefer_initializing_formals
  }) : _ytDlpService = ytDlpService;

  @override
  String get kind => 'tidal';

  @override
  String get providerId => kind;

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities.tidal;

  @override
  bool get supportsSilentRefresh =>
      _refreshToken != null && _refreshToken!.trim().isNotEmpty;

  @override
  Future<void> forceRefreshSession() => refreshSessionIfNeeded(force: true);

  Map<String, String> get _authHeaders => <String, String>{
    'Authorization': 'Bearer ${_accessToken ?? ''}',
    'Accept': 'application/json',
  };

  @override
  Future<void> restoreFromStorage() => _restoreFromStorageImpl();

  /// Reads user-supplied BYOK Client ID / Secret persisted locally via DPAPI.
  Future<({String clientId, String clientSecret})?> readRememberedByok() =>
      _readRememberedByokImpl();

  Future<void> saveRememberedByok({
    required String clientId,
    String? clientSecret,
  }) => _saveRememberedByokImpl(clientId: clientId, clientSecret: clientSecret);

  Future<void> clearRememberedByok() => _clearRememberedByokImpl();

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

  /// Checks whether a Tidal DASH MPD manifest contains any `<ContentProtection`
  /// element indicating Widevine/PlayReady/CENC DRM protection.
  static bool isDashMpdDrmProtected(String mpdXml) =>
      _isDashMpdDrmProtected(mpdXml);

  /// Extracts a Unix epoch expiry timestamp (seconds) from signed CDN URLs
  /// (e.g. CloudFront `Expires`, Akamai `exp`, or generic `expire` query params).
  @visibleForTesting
  static int? extractUrlExpireAt(String rawUrl) => _extractUrlExpireAt(rawUrl);

  /// Extracts the earliest signed CDN expiry timestamp (Unix seconds) embedded
  /// in `<BaseURL>`, `initialization="..."`, or `media="..."` URLs of a Tidal
  /// DASH MPD XML manifest.
  @visibleForTesting
  static int? extractDashMpdExpireAt(String mpdXml) =>
      _extractDashMpdExpireAt(mpdXml);

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
    String maxQuality = 'HI_RES_LOSSLESS',
  }) => _resolveStreamImpl(
    track,
    cancel: cancel,
    timeout: timeout,
    playRequestId: playRequestId,
    maxQuality: maxQuality,
  );

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
