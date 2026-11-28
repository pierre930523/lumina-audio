part of '../streaming_playback_coordinator.dart';

enum _YtmPlaybackStage {
  directInitial,
  directFreshRetry,
  ffmpegFallback,
}

class _YtmPlaybackAttempt {
  final int requestId;
  final TrackInfo track;
  final String videoId;
  final CancellationToken cancel;
  _YtmPlaybackStage stage;
  String activeUrl;
  Map<String, String> activeHeaders;
  String? hintExtension;
  AudioFormat format;
  bool recovering = false;

  _YtmPlaybackAttempt({
    required this.requestId,
    required this.track,
    required this.videoId,
    required this.cancel,
    required this.stage,
    required this.activeUrl,
    required this.activeHeaders,
    required this.hintExtension,
    required this.format,
  });
}

class _TidalDashPlaybackAttempt {
  final int requestId;
  final TrackInfo track;
  final CancellationToken cancel;
  final List<String> remainingTiers;
  String? initialError;
  bool recovering = false;

  _TidalDashPlaybackAttempt({
    required this.requestId,
    required this.track,
    required this.cancel,
    required this.remainingTiers,
  });
}

class _CachedResolvedStream {
  final ResolvedStreamResult result;
  final DateTime expiresAt;

  const _CachedResolvedStream({
    required this.result,
    required this.expiresAt,
  });
}

class _CachedSpecEntry {
  final String trackId;
  final StreamSourceSpec spec;
  final DateTime expiresAt;

  const _CachedSpecEntry({
    required this.trackId,
    required this.spec,
    required this.expiresAt,
  });
}

bool _tracksReferToSame(TrackInfo? a, TrackInfo? b) {
  if (a == null || b == null) return false;
  if (a.id.isNotEmpty && a.id == b.id) return true;
  if (PlaybackPersistenceService.tracksMatch(a, b)) return true;
  if (a.id.trim().isNotEmpty && b.id.trim().isNotEmpty) {
    return a.responsiveArtworkKey == b.responsiveArtworkKey;
  }
  return false;
}

int _findTrackIndexInList(List<TrackInfo> tracks, TrackInfo target) {
  final exact = PlaybackPersistenceService.findTrackIndex(tracks, target);
  if (exact >= 0) return exact;
  if (target.id.trim().isEmpty) return -1;
  final targetKey = target.responsiveArtworkKey;
  return tracks.indexWhere(
    (t) => t.id.trim().isNotEmpty && t.responsiveArtworkKey == targetKey,
  );
}

bool _isGenericDefaultFormat(AudioFormat f) {
  return f.codec == AudioCodec.flac &&
      f.sampleRateHz == 44100 &&
      f.bitDepth == 16 &&
      f.channels == 2 &&
      !f.isDsd &&
      f.bitrateKbps == null;
}

TrackInfo _mergeRichTrack(TrackInfo primary, TrackInfo? enrichment) {
  if (enrichment == null) return primary;
  final mergedId =
      enrichment.id.trim().isNotEmpty ? enrichment.id : primary.id;
  final pTitle = primary.title.trim();
  final eTitle = enrichment.title.trim();
  final mergedTitle = (pTitle.isNotEmpty && pTitle != '未知曲目')
      ? primary.title
      : (eTitle.isNotEmpty ? enrichment.title : primary.title);
  final pArtist = primary.artist.trim();
  final eArtist = enrichment.artist.trim();
  final mergedArtist = (pArtist.isNotEmpty && pArtist != '未知藝術家')
      ? primary.artist
      : (eArtist.isNotEmpty ? enrichment.artist : primary.artist);
  final pAlbum = primary.album.trim();
  final eAlbum = enrichment.album.trim();
  final mergedAlbum = (pAlbum.isNotEmpty && pAlbum != '未知專輯')
      ? primary.album
      : (eAlbum.isNotEmpty ? enrichment.album : primary.album);
  final mergedCover =
      (primary.coverUrl != null && primary.coverUrl!.trim().isNotEmpty)
      ? primary.coverUrl
      : enrichment.coverUrl;
  final mergedAlbumArt =
      (primary.albumArtUrl != null && primary.albumArtUrl!.trim().isNotEmpty)
      ? primary.albumArtUrl
      : (enrichment.albumArtUrl ?? mergedCover);
  final mergedDuration = primary.duration > Duration.zero
      ? primary.duration
      : enrichment.duration;
  final mergedFormat =
      _isGenericDefaultFormat(primary.format) &&
          !_isGenericDefaultFormat(enrichment.format)
      ? enrichment.format
      : primary.format;
  final mergedProvider =
      enrichment.providerName.trim().isNotEmpty &&
          enrichment.providerName != 'Remote Core' &&
          (primary.providerName.trim().isEmpty ||
              primary.providerName == 'Local Library' ||
              primary.providerName == 'Remote Core')
      ? enrichment.providerName
      : primary.providerName;

  return enrichment.copyWith(
    id: mergedId,
    title: mergedTitle,
    artist: mergedArtist,
    album: mergedAlbum,
    duration: mergedDuration,
    coverUrl: mergedCover,
    albumArtUrl: mergedAlbumArt,
    format: mergedFormat,
    providerName: mergedProvider,
    filePath: primary.filePath ?? enrichment.filePath,
    albumArtist: primary.albumArtist ?? enrichment.albumArtist,
    genre: primary.genre ?? enrichment.genre,
    year: primary.year ?? enrichment.year,
    trackNumber: primary.trackNumber ?? enrichment.trackNumber,
    discNumber: primary.discNumber ?? enrichment.discNumber,
    composer: primary.composer ?? enrichment.composer,
    artworkCacheKey: primary.artworkCacheKey ?? enrichment.artworkCacheKey,
    hasLyrics: primary.hasLyrics || enrichment.hasLyrics,
    isrc: primary.isrc ?? enrichment.isrc,
    qualityLabel: primary.qualityLabel ?? enrichment.qualityLabel,
    artistId: primary.artistId ?? enrichment.artistId,
  );
}

bool _listsHaveSameIds(List<TrackInfo> a, List<TrackInfo> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id) return false;
  }
  return true;
}

bool _isLocalTrack(TrackInfo track) {
  final fp = track.filePath?.trim();
  if (fp == null || fp.isEmpty) return false;
  if (AudioService.isStreamingTrackId(track.id)) return false;
  if (AudioService.isStreamingTrackId(fp)) return false;
  return true;
}

bool _isYouTubeMusicTrack(TrackInfo track) {
  final id = track.id;
  return id.startsWith('ytm:') ||
      id.startsWith('ytm_') ||
      id.startsWith('streaming:youtube_music:') ||
      id.startsWith('youtube_music:') ||
      track.providerName == 'YouTube Music' ||
      track.providerName == 'Podcast';
}

bool _isTidalTrack(TrackInfo track) =>
    track.id.startsWith('tidal:') || track.providerName == 'Tidal';

List<String> _remainingTidalTiersForRoute(String? engineRoute) {
  final route = (engineRoute ?? '').toUpperCase();
  if (route.contains('HI_RES_LOSSLESS')) {
    return <String>['LOSSLESS', 'HIGH'];
  }
  if (route.contains('LOSSLESS')) {
    return <String>['HIGH'];
  }
  if (route.contains('HIGH')) {
    return <String>[];
  }
  return <String>['LOSSLESS', 'HIGH'];
}

bool _isLocalhostProxyUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  final host = uri?.host.toLowerCase();
  return host == '127.0.0.1' || host == 'localhost' || host == '::1';
}

bool _isHttp403Error(String message) {
  return RegExp(
    r'HTTP\s*403\b|status(?:\s*code)?\s*[:=]?\s*403\b|\b403\s+Forbidden\b',
    caseSensitive: false,
  ).hasMatch(message);
}

bool _isAuthRequiredError(String message) {
  return RegExp(
    r'\bAUTH_REQUIRED\b|HTTP\s*401\b|status(?:\s*code)?\s*[:=]?\s*401\b|\b401\s+Unauthorized\b',
    caseSensitive: false,
  ).hasMatch(message);
}

String _resolveYtmVideoIdForTrack(
  TrackInfo track, {
  ResolvedStreamResult? result,
}) {
  final fromResult = result?.videoId?.trim();
  if (fromResult != null && fromResult.isNotEmpty) {
    return fromResult;
  }
  final clean = YouTubeMusicProvider.tryExtractCleanVideoId(
    track.id,
    filePath: track.filePath,
  );
  if (clean != null && clean.isNotEmpty) {
    return clean;
  }
  var raw = track.id.trim();
  for (final prefix in const <String>[
    'streaming:youtube_music:',
    'youtube_music:',
    'ytm:',
    'ytm_',
  ]) {
    if (raw.startsWith(prefix)) {
      raw = raw.substring(prefix.length).trim();
      break;
    }
  }
  return raw.isEmpty ? track.id : raw;
}

String _formatEngineLabel(
  ResolvedStreamResult result, {
  required bool isFfmpegProxy,
}) {
  final explicit = result.engineRoute?.trim();
  if (explicit != null && explicit.isNotEmpty) {
    return explicit;
  }
  if (isFfmpegProxy) {
    return 'bundled yt-dlp + ffmpeg fallback';
  }
  final ext = result.hintExtension?.trim().toLowerCase() ?? '';
  if (ext == 'm4a' ||
      ext == 'aac' ||
      ext == 'mp4' ||
      result.format.codec == AudioCodec.aac) {
    return 'bundled yt-dlp (direct M4A)';
  }
  if (ext.isNotEmpty) {
    return 'bundled yt-dlp (direct ${ext.toUpperCase()})';
  }
  return 'bundled yt-dlp (direct ${result.format.codec.name.toUpperCase()})';
}

ResolvedStreamResult? _toResolvedResultForCache(StreamSourceSpec spec) {
  final fallbackFmt = spec.audioFormat ??
      const AudioFormat(
        codec: AudioCodec.flac,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
      );
  return switch (spec) {
    DirectRangeSpec() => ResolvedStreamResult(
      url: spec.url,
      headers: spec.headers,
      hintExtension: spec.hintExtension,
      format: fallbackFmt,
      isPreviewOnly: spec.isPreviewOnly,
      drmNotice: spec.notice,
      externalWebUrl: spec.externalWebUrl,
    ),
    EncryptedRangeSpec() => ResolvedStreamResult(
      url: spec.url,
      headers: spec.headers,
      hintExtension: spec.hintExtension,
      format: fallbackFmt,
    ),
    SegmentedManifestSpec() => ResolvedStreamResult(
      url: spec.manifestUrlOrXml,
      headers: spec.headers,
      hintExtension: spec.format == ManifestFormat.dash ? 'mpd' : 'm3u8',
      format: fallbackFmt,
    ),
    LocalFileSpec() => ResolvedStreamResult(
      url: spec.path,
      format: fallbackFmt,
    ),
    ExternalBackendSpec() => null,
  };
}

AppleMusicCredentials? _appleCredentialsForImpl(StreamingManager manager) {
  final provider = manager.providerFor('apple_music');
  if (provider is AppleMusicProvider &&
      provider.developerToken != null &&
      provider.developerToken!.isNotEmpty &&
      provider.musicUserToken != null &&
      provider.musicUserToken!.isNotEmpty) {
    return AppleMusicCredentials(
      developerToken: provider.developerToken!,
      musicUserToken: provider.musicUserToken!,
      storefront: provider.storefront,
    );
  }
  return null;
}

Duration _computeCacheTtlImpl(
  TrackInfo track,
  String resolvedUrl,
  DateTime now,
) {
  if (_isLocalhostProxyUrl(resolvedUrl)) return Duration.zero;
  final id = track.id;
  if (_isYouTubeMusicTrack(track)) {
    final uri = Uri.tryParse(resolvedUrl);
    final expireRaw = uri?.queryParameters['expire'];
    final expireSec = expireRaw != null ? int.tryParse(expireRaw) : null;
    if (expireSec != null && expireSec > 0) {
      final expireAt =
          DateTime.fromMillisecondsSinceEpoch(expireSec * 1000);
      final usableFor =
          expireAt.difference(now) - const Duration(seconds: 60);
      return usableFor > const Duration(seconds: 5) ? usableFor : Duration.zero;
    }
    return const Duration(minutes: 45);
  }
  if (id.startsWith('apple:')) return const Duration(minutes: 30);
  return const Duration(minutes: 10);
}

