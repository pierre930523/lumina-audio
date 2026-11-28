part of '../ffi_audio_service.dart';

AudioCodec _ffiParseCodec(String? raw) => AudioCodec.fromString(raw);

int? _ffiParseBitrateKbps(Map<String, dynamic> item) {
  final kbps = (item['bitrate_kbps'] as num?)?.toInt();
  if (kbps != null && kbps > 0) return kbps;
  final raw =
      (item['bitrate_bps'] as num?)?.toInt() ??
      (item['bitrate'] as num?)?.toInt();
  if (raw == null || raw <= 0) return null;
  return raw > 10000 ? (raw / 1000.0).round() : raw;
}

SignalQuality _ffiParseQuality(String? raw) => switch (raw?.toLowerCase()) {
      'lossless' => SignalQuality.lossless,
      'enhanced' => SignalQuality.enhanced,
      _ => SignalQuality.highQuality,
    };

List<TrackInfo> _ffiParseTrackListJson(String? rawJson) {
  if (rawJson == null || rawJson.isEmpty) {
    return const [];
  }
  final decoded = jsonDecode(rawJson);
  if (decoded is! List) {
    return const [];
  }
  final tracks = <TrackInfo>[];
  for (final item in decoded) {
    if (item is Map<String, dynamic>) {
      tracks.add(
        TrackInfo(
          id: item['id']?.toString() ?? '',
          title: item['title']?.toString() ?? '未知曲目',
          artist: item['artist_name']?.toString() ??
              item['artist']?.toString() ??
              '未知藝術家',
          album: item['album']?.toString() ?? '未知專輯',
          duration: Duration(
            milliseconds: (item['duration_ms'] as num?)?.toInt() ?? 0,
          ),
          format: AudioFormat(
            codec: _ffiParseCodec(item['codec']?.toString()),
            sampleRateHz: (item['sample_rate_hz'] as num?)?.toInt() ?? 44100,
            bitDepth: (item['bit_depth'] as num?)?.toInt() ?? 16,
            channels: (item['channels'] as num?)?.toInt() ?? 2,
            isDsd: item['is_dsd'] == true,
            bitrateKbps: _ffiParseBitrateKbps(item),
          ),
          providerName: 'Local Library',
          filePath: item['file_path']?.toString(),
          albumArtist: item['album_artist']?.toString(),
          genre: item['genre']?.toString(),
          year: (item['year'] as num?)?.toInt(),
          trackNumber: (item['track_number'] as num?)?.toInt(),
          discNumber: (item['disc_number'] as num?)?.toInt(),
          composer: item['composer']?.toString(),
          coverUrl: item['cover_url']?.toString(),
          artworkCacheKey: item['artwork_cache_key']?.toString(),
          hasLyrics: item['has_lyrics'] == true,
          preference: (item['preference'] as num?)?.toInt() ?? 0,
          albumGroupId: _ffiNonEmptyString(item['album_group_id']),
          externalAlbumId: _ffiNonEmptyString(item['external_album_id']),
        ),
      );
    }
  }
  return tracks;
}

List<LyricLine> _ffiParseLyricsJson(String rawJson) {
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, dynamic> || decoded['found'] != true) {
      return const [];
    }
    final rawLines = decoded['lines'] as List<dynamic>? ?? const [];
    final lines = <LyricLine>[];
    for (final l in rawLines) {
      if (l is Map<String, dynamic>) {
        final words = <LyricWord>[];
        if (l['words'] is List) {
          for (final w in l['words']) {
            if (w is Map<String, dynamic>) {
              words.add(
                LyricWord(
                  text: w['text']?.toString() ?? '',
                  start: Duration(
                    milliseconds: (w['start_ms'] as num?)?.toInt() ?? 0,
                  ),
                  end: Duration(
                    milliseconds: (w['end_ms'] as num?)?.toInt() ?? 0,
                  ),
                ),
              );
            }
          }
        }
        final startMs = (l['start_ms'] as num?)?.toInt();
        final endMs = (l['end_ms'] as num?)?.toInt();
        lines.add(
          LyricLine(
            start: Duration(milliseconds: startMs ?? 0),
            end: Duration(milliseconds: endMs ?? 0),
            text: l['text']?.toString() ?? '',
            words: words,
            isSynced: startMs != null || words.isNotEmpty,
          ),
        );
      }
    }
    return lines;
  } catch (_) {
    return const [];
  }
}

bool _ffiHasDualDeckFields(Map<String, dynamic> json) {
  return json.containsKey('active_deck') ||
      json.containsKey('deck_a_state') ||
      json.containsKey('deck_b_state') ||
      json.containsKey('standby_buffered_ms') ||
      json.containsKey('gapless_transitions') ||
      json.containsKey('manual_zero_latency_switches') ||
      json.containsKey('format_mismatch_recoveries') ||
      json.containsKey('swap_generation') ||
      json.containsKey('swapGeneration') ||
      json.containsKey('current_track') ||
      json.containsKey('active_track') ||
      json['dual_deck'] is Map;
}

String _ffiProviderDisplayName(String? providerId) {
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
        : 'Local Library',
  };
}

String _ffiNormalizedTrackKey(String rawId, {String? providerId}) {
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
    providerName: _ffiProviderDisplayName(providerId),
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

bool _ffiTracksReferToSame(
  TrackInfo? current,
  String reportedId,
  String? reportedProviderId,
) {
  if (current == null) return false;
  if (current.id == reportedId) return true;
  final normCurrent = current.responsiveArtworkKey;
  final normReported = _ffiNormalizedTrackKey(
    reportedId,
    providerId: reportedProviderId,
  );
  return normCurrent == normReported;
}

String? _ffiNonEmptyString(dynamic raw) {
  final s = raw?.toString().trim();
  return (s != null && s.isNotEmpty) ? s : null;
}

TrackInfo? _ffiTrackFromCurrentTrackMap(
  Map<String, dynamic> map, {
  int fallbackDurationMs = 0,
}) {
  final rawId =
      _ffiNonEmptyString(map['track_id']) ??
      _ffiNonEmptyString(map['id']) ??
      _ffiNonEmptyString(map['external_track_id']);
  if (rawId == null) return null;
  final providerId = _ffiNonEmptyString(map['provider_id']);
  final title = _ffiNonEmptyString(map['title']) ?? '未知曲目';
  final artist = _ffiNonEmptyString(map['artist']) ?? '未知藝術家';
  final album = _ffiNonEmptyString(map['album']) ?? '';
  final coverUrl =
      _ffiNonEmptyString(map['cover_url']) ??
      _ffiNonEmptyString(map['album_art_url']) ??
      _ffiNonEmptyString(map['artwork_url']);
  final mapDurMs = (map['duration_ms'] as num?)?.toInt() ?? 0;
  final effDurMs = mapDurMs > 0 ? mapDurMs : fallbackDurationMs;
  final canonicalId =
      (providerId != null && providerId != 'local' && !rawId.contains(':'))
          ? TrackMetadata(
              providerId: providerId,
              trackId: rawId,
              title: title,
              artist: artist,
            ).toTrackInfo().id
          : rawId;
  return TrackInfo(
    id: canonicalId,
    title: title,
    artist: artist,
    album: album,
    duration: Duration(milliseconds: effDurMs > 0 ? effDurMs : 0),
    coverUrl: coverUrl,
    albumArtUrl: coverUrl,
    providerName: _ffiProviderDisplayName(providerId),
    preference: (map['preference'] as num?)?.toInt() ?? 0,
    albumGroupId: _ffiNonEmptyString(map['album_group_id']),
    externalAlbumId: _ffiNonEmptyString(map['external_album_id']),
    format: const AudioFormat(
      codec: AudioCodec.flac,
      sampleRateHz: 44100,
      bitDepth: 16,
      channels: 2,
    ),
  );
}

TrackInfo? _ffiMergeTrackInfo(
  TrackInfo? base,
  TrackInfo? jsonTrack, {
  int liveDurationMs = 0,
}) {
  if (base == null && jsonTrack == null) return null;
  if (base == null) {
    return liveDurationMs > 0
        ? jsonTrack!.copyWith(duration: Duration(milliseconds: liveDurationMs))
        : jsonTrack;
  }
  if (jsonTrack == null) {
    return liveDurationMs > 0
        ? base.copyWith(duration: Duration(milliseconds: liveDurationMs))
        : base;
  }
  final mergedTitle =
      (base.title.trim().isNotEmpty && base.title.trim() != '未知曲目')
          ? base.title
          : jsonTrack.title;
  final mergedArtist =
      (base.artist.trim().isNotEmpty && base.artist.trim() != '未知藝術家')
          ? base.artist
          : jsonTrack.artist;
  final mergedAlbum = base.album.trim().isNotEmpty
      ? base.album
      : jsonTrack.album;
  final mergedCover =
      (base.coverUrl != null && base.coverUrl!.trim().isNotEmpty)
          ? base.coverUrl
          : jsonTrack.coverUrl;
  final mergedAlbumArt =
      (base.albumArtUrl != null && base.albumArtUrl!.trim().isNotEmpty)
          ? base.albumArtUrl
          : (jsonTrack.albumArtUrl ?? mergedCover);
  final mergedDuration = liveDurationMs > 0
      ? Duration(milliseconds: liveDurationMs)
      : (base.duration > Duration.zero ? base.duration : jsonTrack.duration);
  final mergedProvider = base.providerName.trim().isNotEmpty
      ? base.providerName
      : jsonTrack.providerName;
  return base.copyWith(
    title: mergedTitle,
    artist: mergedArtist,
    album: mergedAlbum,
    coverUrl: mergedCover,
    albumArtUrl: mergedAlbumArt,
    duration: mergedDuration,
    providerName: mergedProvider,
    preference: base.preference != 0 ? base.preference : jsonTrack.preference,
    albumGroupId: base.albumGroupId ?? jsonTrack.albumGroupId,
    externalAlbumId: base.externalAlbumId ?? jsonTrack.externalAlbumId,
  );
}

({
  String? streamUrl,
  String? filePath,
  Map<String, String> headers,
  String? hintExtension,
}) _ffiLegacyFieldsForSpec(StreamSourceSpec spec) {
  return switch (spec) {
    DirectRangeSpec() => (
      streamUrl: spec.url,
      filePath: null,
      headers: spec.headers,
      hintExtension: spec.hintExtension,
    ),
    EncryptedRangeSpec() => (
      streamUrl: spec.url,
      filePath: null,
      headers: spec.headers,
      hintExtension: spec.hintExtension,
    ),
    SegmentedManifestSpec() => (
      streamUrl: null,
      filePath: null,
      headers: spec.headers,
      hintExtension: spec.format == ManifestFormat.dash ? 'mpd' : 'm3u8',
    ),
    LocalFileSpec() => (
      streamUrl: null,
      filePath: spec.path,
      headers: const <String, String>{},
      hintExtension: null,
    ),
    ExternalBackendSpec() => throw StateError(
      'ExternalBackendSpec cannot be serialized for native playback',
    ),
  };
}

String _ffiEncodeTrackPayload(
  TrackInfo target, {
  String? streamUrl,
  String? filePathOverride,
  Map<String, String> headers = const {},
  String? hintExtension,
  StreamSourceSpec? sourceSpec,
  int? epoch,
  bool debounced = false,
}) {
  final effectivePath = filePathOverride ?? target.filePath;
  final meta = TrackMetadata.fromTrackInfo(target);
  final coverUrl = (target.artworkUrl ?? target.coverUrl)?.trim();
  final albumArtUrl = target.albumArtUrl?.trim();
  return jsonEncode({
    'id': target.id,
    if (target.id.isNotEmpty) 'track_id': target.id,
    if (meta.providerId.isNotEmpty) 'provider_id': meta.providerId,
    'title': target.title,
    'artist': target.artist,
    'album': target.album,
    if (coverUrl != null && coverUrl.isNotEmpty) 'cover_url': coverUrl,
    if (albumArtUrl != null && albumArtUrl.isNotEmpty)
      'album_art_url': albumArtUrl,
    if (target.duration.inMilliseconds > 0)
      'duration_ms': target.duration.inMilliseconds,
    'codec': target.format.codec.name,
    'sample_rate_hz': target.format.sampleRateHz,
    'bit_depth': target.format.bitDepth,
    'channels': target.format.channels,
    'is_dsd': target.format.isDsd,
    if (effectivePath != null && effectivePath.isNotEmpty)
      'file_path': effectivePath,
    if (streamUrl != null && streamUrl.isNotEmpty) 'stream_url': streamUrl,
    if (headers.isNotEmpty) 'headers': headers,
    if (hintExtension != null && hintExtension.isNotEmpty)
      'hint_extension': hintExtension,
    'playback_epoch': ?epoch,
    'epoch': ?epoch,
    if (debounced) 'debounced': true,
    if (sourceSpec != null) 'source_spec': sourceSpec.toJson(),
    'source': target.providerName,
  });
}
