part of '../server_audio_service.dart';

String? _serverNonEmptyString(dynamic raw) {
  final s = raw?.toString().trim();
  return (s != null && s.isNotEmpty) ? s : null;
}

String _serverProviderDisplayName(String? providerId) {
  final normalized = providerId?.trim().toLowerCase() ?? '';
  return switch (normalized) {
    'qobuz' => 'Qobuz',
    'tidal' => 'Tidal',
    'deezer' => 'Deezer',
    'youtube_music' || 'ytm' => 'YouTube Music',
    'apple_music' || 'apple' => 'Apple Music',
    'podcast_rss' || 'podcast' => 'Podcast',
    'local' => 'Local Library',
    _ => (providerId != null && providerId.trim().isNotEmpty)
        ? providerId.trim()
        : 'Remote Core',
  };
}

String _serverNormalizedTrackKey(String rawId, {String? providerId}) {
  final probe = TrackInfo(
    id: rawId,
    title: '',
    artist: '',
    album: '',
    duration: Duration.zero,
    format: const AudioFormat(
      codec: AudioCodec.flac,
      sampleRateHz: 44100,
      bitDepth: 16,
      channels: 2,
    ),
    providerName: _serverProviderDisplayName(providerId),
  );
  final meta = TrackMetadata.fromTrackInfo(
    probe,
    providerIdOverride:
        (providerId != null && providerId.trim().isNotEmpty)
            ? providerId.trim()
            : null,
  );
  return '${meta.providerId}:${meta.trackId}';
}

bool _serverTracksReferToSame(TrackInfo? current, TrackInfo? incoming) {
  if (current == null || incoming == null) return false;
  if (current.id == incoming.id) return true;
  if (current.id.isEmpty || incoming.id.isEmpty) return false;
  return current.responsiveArtworkKey == incoming.responsiveArtworkKey;
}

bool _serverTrackMatchesId(
  TrackInfo candidate,
  String reportedId,
  String? providerId,
) {
  if (candidate.id == reportedId) return true;
  if (reportedId.isEmpty) return false;
  return candidate.responsiveArtworkKey ==
      _serverNormalizedTrackKey(reportedId, providerId: providerId);
}

int? _serverParseBitrateKbps(Map<String, dynamic> item) {
  final kbps = (item['bitrate_kbps'] as num?)?.toInt();
  if (kbps != null && kbps > 0) return kbps;
  final raw =
      (item['bitrate_bps'] as num?)?.toInt() ??
      (item['bitrate'] as num?)?.toInt();
  if (raw == null || raw <= 0) return null;
  return raw > 10000 ? (raw / 1000.0).round() : raw;
}

PlaybackStatus _serverParsePlaybackStatus(String? raw) {
  return switch (raw?.trim().toLowerCase()) {
    'playing' => PlaybackStatus.playing,
    'paused' => PlaybackStatus.paused,
    'error' => PlaybackStatus.error,
    'loading' => PlaybackStatus.loading,
    'seeking' => PlaybackStatus.seeking,
    'buffering' => PlaybackStatus.buffering,
    'ended' => PlaybackStatus.ended,
    'uninitialized' => PlaybackStatus.uninitialized,
    _ => PlaybackStatus.stopped,
  };
}

TrackInfo _serverParseTrackFromMap(
  Map<String, dynamic> item, {
  String defaultProvider = 'Remote Core',
  int fallbackDurationMs = 0,
}) {
  final rawId =
      _serverNonEmptyString(item['track_id']) ??
      _serverNonEmptyString(item['id']) ??
      _serverNonEmptyString(item['external_track_id']) ??
      '';
  final providerId = _serverNonEmptyString(item['provider_id']);
  final title = _serverNonEmptyString(item['title']) ?? '';
  final artist =
      _serverNonEmptyString(item['artist_name']) ??
      _serverNonEmptyString(item['artist']) ??
      '';
  final album = _serverNonEmptyString(item['album']) ?? '';
  final coverUrl =
      _serverNonEmptyString(item['cover_url']) ??
      _serverNonEmptyString(item['album_art_url']) ??
      _serverNonEmptyString(item['artwork_url']);
  final durMs = (item['duration_ms'] as num?)?.toInt() ?? fallbackDurationMs;
  final canonicalId =
      (providerId != null &&
              providerId != 'local' &&
              rawId.isNotEmpty &&
              !rawId.contains(':'))
          ? TrackMetadata(
              providerId: providerId,
              trackId: rawId,
              title: title,
              artist: artist,
            ).toTrackInfo().id
          : rawId;
  final providerName =
      _serverNonEmptyString(item['provider_name']) ??
      (providerId != null
          ? _serverProviderDisplayName(providerId)
          : defaultProvider);
  return TrackInfo(
    id: canonicalId,
    title: title,
    artist: artist,
    album: album,
    duration: Duration(milliseconds: durMs > 0 ? durMs : 0),
    format: AudioFormat(
      codec: AudioCodec.fromString(item['codec']?.toString()),
      sampleRateHz: (item['sample_rate_hz'] as num?)?.toInt() ?? 44100,
      bitDepth: (item['bit_depth'] as num?)?.toInt() ?? 16,
      channels: (item['channels'] as num?)?.toInt() ?? 2,
      isDsd: item['is_dsd'] == true,
      bitrateKbps: _serverParseBitrateKbps(item),
    ),
    providerName: providerName,
    filePath: _serverNonEmptyString(item['file_path']),
    albumArtist: _serverNonEmptyString(item['album_artist']),
    genre: _serverNonEmptyString(item['genre']),
    year: (item['year'] as num?)?.toInt(),
    trackNumber: (item['track_number'] as num?)?.toInt(),
    discNumber: (item['disc_number'] as num?)?.toInt(),
    composer: _serverNonEmptyString(item['composer']),
    coverUrl: coverUrl,
    albumArtUrl: coverUrl,
    artworkCacheKey: _serverNonEmptyString(item['artwork_cache_key']),
    hasLyrics: item['has_lyrics'] == true,
    preference: (item['preference'] as num?)?.toInt() ?? 0,
    albumGroupId: _serverNonEmptyString(item['album_group_id']),
    externalAlbumId: _serverNonEmptyString(item['external_album_id']),
  );
}

TrackInfo? _serverHydrateTrackFromPayload(
  Map<String, dynamic> payload, {
  required List<TrackInfo> queue,
  required TrackInfo? currentTrack,
  int fallbackDurationMs = 0,
}) {
  final rawTrackObj =
      payload['track'] ?? payload['current_track'] ?? payload['active_track'];
  final rawTrackMap =
      rawTrackObj is Map ? Map<String, dynamic>.from(rawTrackObj) : null;
  final reportedId =
      _serverNonEmptyString(rawTrackMap?['track_id']) ??
      _serverNonEmptyString(rawTrackMap?['id']) ??
      _serverNonEmptyString(payload['track_id']) ??
      _serverNonEmptyString(payload['current_track_id']);
  final reportedProviderId =
      _serverNonEmptyString(rawTrackMap?['provider_id']) ??
      _serverNonEmptyString(payload['provider_id']);
  final mapDurMs =
      (rawTrackMap?['duration_ms'] as num?)?.toInt() ??
      (payload['duration_ms'] as num?)?.toInt() ??
      fallbackDurationMs;

  TrackInfo? baseMatch;
  if (reportedId != null) {
    for (final q in queue) {
      if (_serverTrackMatchesId(q, reportedId, reportedProviderId)) {
        baseMatch = q;
        break;
      }
    }
    if (baseMatch == null &&
        currentTrack != null &&
        _serverTrackMatchesId(currentTrack, reportedId, reportedProviderId)) {
      baseMatch = currentTrack;
    }
  }

  TrackInfo? parsedPayloadTrack;
  if (rawTrackMap != null) {
    parsedPayloadTrack = _serverParseTrackFromMap(
      rawTrackMap,
      fallbackDurationMs: mapDurMs,
    );
  } else if (reportedId != null || _serverNonEmptyString(payload['title']) != null) {
    parsedPayloadTrack = _serverParseTrackFromMap(<String, dynamic>{
      'track_id': ?reportedId,
      'provider_id': ?reportedProviderId,
      if (payload['title'] != null) 'title': payload['title'],
      if (payload['artist'] != null) 'artist': payload['artist'],
      if (payload['album'] != null) 'album': payload['album'],
      if (payload['cover_url'] != null) 'cover_url': payload['cover_url'],
      if (payload['album_art_url'] != null)
        'album_art_url': payload['album_art_url'],
      if (mapDurMs > 0) 'duration_ms': mapDurMs,
    }, fallbackDurationMs: mapDurMs);
  }

  if (baseMatch == null && parsedPayloadTrack == null) {
    if (currentTrack != null && mapDurMs > 0) {
      return currentTrack.copyWith(
        duration: Duration(milliseconds: mapDurMs),
      );
    }
    return currentTrack;
  }
  if (baseMatch == null) {
    final p = parsedPayloadTrack!;
    if (p.title.isEmpty) {
      return p.copyWith(
        title: p.id.isNotEmpty ? p.id : '未知曲目',
        artist: p.artist.isEmpty ? '未知藝術家' : p.artist,
      );
    }
    return p;
  }
  if (parsedPayloadTrack == null) {
    return mapDurMs > 0
        ? baseMatch.copyWith(duration: Duration(milliseconds: mapDurMs))
        : baseMatch;
  }

  final mergedTitle = parsedPayloadTrack.title.isNotEmpty
      ? parsedPayloadTrack.title
      : baseMatch.title;
  final mergedArtist = parsedPayloadTrack.artist.isNotEmpty
      ? parsedPayloadTrack.artist
      : baseMatch.artist;
  final mergedAlbum = parsedPayloadTrack.album.isNotEmpty
      ? parsedPayloadTrack.album
      : baseMatch.album;
  final mergedCover =
      (parsedPayloadTrack.coverUrl != null &&
              parsedPayloadTrack.coverUrl!.isNotEmpty)
          ? parsedPayloadTrack.coverUrl
          : baseMatch.coverUrl;
  final mergedAlbumArt =
      (parsedPayloadTrack.albumArtUrl != null &&
              parsedPayloadTrack.albumArtUrl!.isNotEmpty)
          ? parsedPayloadTrack.albumArtUrl
          : (baseMatch.albumArtUrl ?? mergedCover);
  final mergedDur = mapDurMs > 0
      ? Duration(milliseconds: mapDurMs)
      : (parsedPayloadTrack.duration > Duration.zero
            ? parsedPayloadTrack.duration
            : baseMatch.duration);
  final mergedProvider = baseMatch.providerName.isNotEmpty &&
          baseMatch.providerName != 'Remote Core'
      ? baseMatch.providerName
      : parsedPayloadTrack.providerName;

  return baseMatch.copyWith(
    title: mergedTitle,
    artist: mergedArtist,
    album: mergedAlbum,
    coverUrl: mergedCover,
    albumArtUrl: mergedAlbumArt,
    duration: mergedDur,
    providerName: mergedProvider,
    preference: baseMatch.preference != 0
        ? baseMatch.preference
        : parsedPayloadTrack.preference,
    albumGroupId: baseMatch.albumGroupId ?? parsedPayloadTrack.albumGroupId,
    externalAlbumId:
        baseMatch.externalAlbumId ?? parsedPayloadTrack.externalAlbumId,
  );
}
