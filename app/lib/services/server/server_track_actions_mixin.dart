part of '../server_audio_service.dart';

/// Implements single-track inspection, visibility, rescan, reidentify,
/// reanalyze, deletion, and filtered library queries over REST.
mixin _ServerTrackActionsMixin on _ServerAudioServiceBase {
  @override
  Future<TrackFileInfo?> getTrackFileInfo(String trackId) async {
    final enc = Uri.encodeComponent(trackId);
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/tracks/$enc/file-info',
    );
    if (code == 200 && data is Map) {
      return TrackFileInfo.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<TrackVisibilityResult?> setTrackHidden(
    String trackId,
    bool isHidden,
  ) async {
    final enc = Uri.encodeComponent(trackId);
    final (code, data) = await _requestJson(
      'PUT',
      '/api/v1/library/tracks/$enc/hidden',
      body: <String, dynamic>{'is_hidden': isHidden},
    );
    if (code == 200 && data is Map) {
      unawaited(_scheduleReloadTracksFromServer());
      return TrackVisibilityResult.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<TrackFileInfo?> rescanTrack(String trackId) async {
    final enc = Uri.encodeComponent(trackId);
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/tracks/$enc/rescan',
      timeout: const Duration(seconds: 30),
    );
    if (code == 200 && data is Map) {
      unawaited(_scheduleReloadTracksFromServer());
      return TrackFileInfo.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<ReidentifyTrackResult?> reidentifyTrack(String trackId) async {
    final enc = Uri.encodeComponent(trackId);
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/tracks/$enc/reidentify',
      body: const <String, dynamic>{},
      timeout: const Duration(seconds: 30),
    );
    if (code == 200 && data is Map) {
      unawaited(_scheduleReloadTracksFromServer());
      return ReidentifyTrackResult.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<TrackAnalysisResult?> reanalyzeTrack(String trackId) async {
    final enc = Uri.encodeComponent(trackId);
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/tracks/$enc/reanalyze',
      timeout: const Duration(seconds: 45),
    );
    if (code == 200 && data is Map) {
      unawaited(_scheduleReloadTracksFromServer());
      return TrackAnalysisResult.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<DeleteTrackResult?> deleteTrack(
    String trackId, {
    TrackDeleteMode mode = TrackDeleteMode.libraryOnly,
  }) async {
    final enc = Uri.encodeComponent(trackId);
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/tracks/$enc/delete',
      body: <String, dynamic>{'mode': mode.toJson()},
    );
    if (code == 200 && data is Map) {
      unawaited(_scheduleReloadTracksFromServer());
      return DeleteTrackResult.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<List<TrackInfo>> getLibraryTracksFiltered({
    int limit = 200,
    bool includeHidden = false,
  }) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/tracks?limit=$limit&include_hidden=$includeHidden',
    );
    if (code == 200 && data is List) {
      return data
          .whereType<Map>()
          .map((item) => _serverParseTrackFromMap(Map<String, dynamic>.from(item)))
          .toList(growable: false);
    }
    return const <TrackInfo>[];
  }

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetailFiltered(
    String albumId, {
    bool includeHidden = false,
  }) async {
    final enc = Uri.encodeComponent(albumId);
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/albums/$enc?include_hidden=$includeHidden',
    );
    if (code == 200 && data is Map) {
      final detail = CanonicalAlbumDetail.fromJson(Map<String, dynamic>.from(data));
      final nonEmptyVersions = detail.versions
          .where((v) => v.tracks.isNotEmpty)
          .toList(growable: false);
      if (nonEmptyVersions.isEmpty) return null;
      if (nonEmptyVersions.length == detail.versions.length) return detail;
      return detail.copyWith(versions: nonEmptyVersions);
    }
    return null;
  }

  @override
  Future<bool> revealTrackFolder(String filePath) async {
    if (_mode != ConnectionMode.localOrUsbDac) {
      return false;
    }
    return revealFileInFolder(filePath);
  }
}
