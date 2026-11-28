import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/playback_state.dart';
import '../../models/streaming_models.dart';
import '../../models/streaming_provider_meta.dart';
import '../../models/studio_models.dart';
import 'secure_credential_store.dart';

part 'streaming_provider/http_client.dart';
part 'streaming_provider/base_provider.dart';

/// Unified interface implemented by every real streaming service backend.
abstract class StreamingProvider {
  String get kind;
  StreamingProviderMeta get meta;
  StreamingAuthState get authState;
  StreamingAccountInfo? get accountInfo;
  String? get lastError;
  StreamingCatalog get catalog;
  bool get supportsGuestMode => false;

  Future<void> restoreFromStorage();
  Future<void> authenticate(
    Map<String, dynamic> params, {
    CancellationToken? cancel,
    void Function(String statusMsg)? onProgress,
  });
  Future<void> refreshSessionIfNeeded();
  Future<void> logout();
  Future<StreamingCatalog> syncLibrary({CancellationToken? cancel});
  Future<StreamingRecommendations> fetchRecommendations({
    CancellationToken? cancel,
    bool forceRefresh = false,
    int batchIndex = 0,
    Set<String> excludeAlbumIds = const <String>{},
    Set<String> excludeTrackIds = const <String>{},
  });
  Future<CanonicalAlbumDetail?> fetchAlbumDetail(
    String albumId, {
    CancellationToken? cancel,
  });
  Future<List<TrackInfo>> fetchPlaylistTracks(String playlistId);
  Future<StreamingCatalog> search(String query, {CancellationToken? cancel});
  Future<ResolvedStreamResult> resolveStream(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
  });
}

/// Optional authentication-lifecycle capability implemented by providers that
/// support silent token/session refresh and circuit-breaker `authRequired` state.
abstract interface class AuthAwareStreamingProvider
    implements StreamingProvider {
  bool get supportsSilentRefresh;
  Future<void> forceRefreshSession();
  void markAuthRequired(String reason);
  void clearAuthRequired();
}
