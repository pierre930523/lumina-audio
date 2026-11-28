import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../models/audio_format.dart';
import '../../../models/playback_state.dart';
import '../../../models/recommendation_models.dart';
import '../../../models/stream_source_spec.dart';
import '../../../models/streaming_models.dart';
import '../../../models/studio_models.dart';
import '../recommendation_provider.dart';
import '../stream_resolver.dart';
import '../streaming_provider.dart';
import '../track_matcher.dart';

part 'qobuz/qobuz_auth.dart';
part 'qobuz/qobuz_catalog.dart';
part 'qobuz/qobuz_parsers.dart';
part 'qobuz/qobuz_recommendations.dart';
part 'qobuz/qobuz_stream.dart';

/// Real Qobuz API v0.2 provider supporting MD5 credential login, token
/// verification, Hi-Res catalog sync, and MD5 `request_sig` stream signing.
class QobuzProvider extends BaseStreamingProvider
    implements StreamResolver, RecommendationProvider {
  static const List<int> _preferredFormatIds = <int>[27, 7, 6, 5];

  final String baseUrl;

  String? _appId;
  String? _appSecret;
  String? _userAuthToken;

  QobuzProvider({
    required super.credentialStore,
    super.httpClientFactory,
    super.requestTimeout,
    super.clock,
    this.baseUrl = 'https://www.qobuz.com/api.json/0.2',
  });

  static const String missingAppSecretNotice =
      '目前以網頁／權杖授權登入（未含 app_secret），帳戶驗證與歌單同步已就緒；若需解析 Hi-Res 串流播放簽章，請於「進階／手動輸入 Token」補填 App Secret 或改用帳號密碼登入。';

  @override
  String get kind => 'qobuz';

  @override
  String get providerId => kind;

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities.qobuz;

  bool get hasAppSecret =>
      _appSecret != null && _appSecret!.trim().isNotEmpty;

  Map<String, String> _authHeaders({bool includeToken = true}) =>
      <String, String>{
        if (_appId != null && _appId!.isNotEmpty) 'X-App-Id': _appId!,
        if (includeToken &&
            _userAuthToken != null &&
            _userAuthToken!.isNotEmpty)
          'X-User-Auth-Token': _userAuthToken!,
        'Accept': 'application/json',
      };

  static String computePasswordMd5(String password) =>
      md5.convert(utf8.encode(password)).toString();

  static String computeRequestSignature({
    required int formatId,
    required String trackId,
    required String timestampSec,
    required String appSecret,
  }) {
    final payload =
        'trackgetFileUrlformat_id${formatId}intentstreamtrack_id$trackId$timestampSec$appSecret';
    return md5.convert(utf8.encode(payload)).toString();
  }

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
    // Qobuz user_auth_token does not use OAuth refresh tokens.
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
