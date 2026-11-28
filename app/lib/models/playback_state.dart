import 'audio_format.dart';
import 'protocol/lumina_error.dart';
import 'protocol/protocol_models.dart';
import 'recommendation_models.dart';

enum PlaybackStatus {
  uninitialized,
  stopped,
  playing,
  paused,
  error,
  loading,
  seeking,
  buffering,
  ended;

  static PlaybackStatus fromCode(int code) => switch (code) {
        0 => PlaybackStatus.uninitialized,
        1 => PlaybackStatus.stopped,
        2 => PlaybackStatus.playing,
        3 => PlaybackStatus.paused,
        4 => PlaybackStatus.error,
        5 => PlaybackStatus.loading,
        6 => PlaybackStatus.seeking,
        7 => PlaybackStatus.buffering,
        8 => PlaybackStatus.ended,
        _ => PlaybackStatus.stopped,
      };

  int get code => switch (this) {
        PlaybackStatus.uninitialized => 0,
        PlaybackStatus.stopped => 1,
        PlaybackStatus.playing => 2,
        PlaybackStatus.paused => 3,
        PlaybackStatus.error => 4,
        PlaybackStatus.loading => 5,
        PlaybackStatus.seeking => 6,
        PlaybackStatus.buffering => 7,
        PlaybackStatus.ended => 8,
      };
}

class TrackInfo {
  final String id;
  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final String? albumArtUrl;
  final AudioFormat format;
  final String providerName;
  final String? filePath;
  final String? albumArtist;
  final String? genre;
  final int? year;
  final int? trackNumber;
  final int? discNumber;
  final String? composer;
  final String? coverUrl;
  final String? artworkCacheKey;
  final bool hasLyrics;
  final String? isrc;
  final String? qualityLabel;
  final String? artistId;
  final int preference;
  final String? albumGroupId;
  final String? externalAlbumId;

  const TrackInfo({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    this.albumArtUrl,
    required this.format,
    this.providerName = 'Qobuz Hi-Res',
    this.filePath,
    this.albumArtist,
    this.genre,
    this.year,
    this.trackNumber,
    this.discNumber,
    this.composer,
    this.coverUrl,
    this.artworkCacheKey,
    this.hasLyrics = false,
    this.isrc,
    this.qualityLabel,
    this.artistId,
    this.preference = 0,
    this.albumGroupId,
    this.externalAlbumId,
  });

  factory TrackInfo.fromJson(Map<String, dynamic> json) {
    final rawBitrateKbps = (json['bitrate_kbps'] as num?)?.toInt();
    final rawBitrateBps =
        (json['bitrate_bps'] as num?)?.toInt() ??
        (json['bitrate'] as num?)?.toInt();
    final resolvedBitrateKbps =
        (rawBitrateKbps != null && rawBitrateKbps > 0)
            ? rawBitrateKbps
            : (rawBitrateBps != null && rawBitrateBps > 0
                  ? (rawBitrateBps > 10000
                        ? (rawBitrateBps / 1000.0).round()
                        : rawBitrateBps)
                  : null);
    final rawProvider =
        json['provider_name']?.toString().trim() ??
        json['provider_id']?.toString().trim() ??
        '';
    final providerName = switch (rawProvider.toLowerCase()) {
      '' || 'local' => 'Local Library',
      'qobuz' => 'Qobuz',
      'tidal' => 'Tidal',
      'deezer' => 'Deezer',
      'youtube_music' || 'ytm' => 'YouTube Music',
      'apple_music' || 'apple' => 'Apple Music',
      _ => rawProvider,
    };
    return TrackInfo(
      id:
          json['id']?.toString() ??
          json['track_id']?.toString() ??
          json['external_track_id']?.toString() ??
          '',
      title: json['title']?.toString() ?? '未知曲目',
      artist:
          json['artist_name']?.toString() ??
          json['artist']?.toString() ??
          '未知藝術家',
      album: json['album']?.toString() ?? json['album_title']?.toString() ?? '未知專輯',
      duration: Duration(
        milliseconds: (json['duration_ms'] as num?)?.toInt() ?? 0,
      ),
      albumArtUrl: json['album_art_url']?.toString(),
      format: AudioFormat(
        codec: AudioCodec.fromString(json['codec']?.toString()),
        sampleRateHz: (json['sample_rate_hz'] as num?)?.toInt() ?? 44100,
        bitDepth: (json['bit_depth'] as num?)?.toInt() ?? 16,
        channels: (json['channels'] as num?)?.toInt() ?? 2,
        isDsd: json['is_dsd'] == true || json['is_dsd'] == 1,
        bitrateKbps: resolvedBitrateKbps,
      ),
      providerName: providerName,
      filePath:
          json['file_path']?.toString() ?? json['external_track_id']?.toString(),
      albumArtist: json['album_artist']?.toString(),
      genre: json['genre']?.toString(),
      year:
          (json['year'] as num?)?.toInt() ??
          (json['release_year'] as num?)?.toInt(),
      trackNumber: (json['track_number'] as num?)?.toInt(),
      discNumber: (json['disc_number'] as num?)?.toInt(),
      composer: json['composer']?.toString(),
      coverUrl:
          json['cover_url']?.toString() ?? json['artwork_url']?.toString(),
      artworkCacheKey: json['artwork_cache_key']?.toString(),
      hasLyrics: json['has_lyrics'] == true || json['has_lyrics'] == 1,
      isrc: json['isrc']?.toString(),
      qualityLabel: json['quality_label']?.toString(),
      artistId: json['artist_id']?.toString(),
      preference: (json['preference'] as num?)?.toInt() ?? 0,
      albumGroupId:
          json['album_group_id']?.toString() ??
          json['alb_id']?.toString() ??
          json['album_id']?.toString(),
      externalAlbumId: json['external_album_id']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'duration_ms': duration.inMilliseconds,
    if (albumArtUrl != null) 'album_art_url': albumArtUrl,
    'codec': format.codec.name,
    'sample_rate_hz': format.sampleRateHz,
    'bit_depth': format.bitDepth,
    'channels': format.channels,
    'is_dsd': format.isDsd,
    if (format.bitrateKbps != null) 'bitrate_kbps': format.bitrateKbps,
    'provider_name': providerName,
    if (filePath != null) 'file_path': filePath,
    if (albumArtist != null) 'album_artist': albumArtist,
    if (genre != null) 'genre': genre,
    if (year != null) 'year': year,
    if (trackNumber != null) 'track_number': trackNumber,
    if (discNumber != null) 'disc_number': discNumber,
    if (composer != null) 'composer': composer,
    if (coverUrl != null) 'cover_url': coverUrl,
    if (artworkCacheKey != null) 'artwork_cache_key': artworkCacheKey,
    'has_lyrics': hasLyrics,
    if (isrc != null) 'isrc': isrc,
    if (qualityLabel != null) 'quality_label': qualityLabel,
    if (artistId != null) 'artist_id': artistId,
    'preference': preference,
    if (albumGroupId != null) 'album_group_id': albumGroupId,
    if (externalAlbumId != null) 'external_album_id': externalAlbumId,
  };

  String? get artworkUrl =>
      (coverUrl != null && coverUrl!.trim().isNotEmpty)
          ? coverUrl
          : ((albumArtUrl != null && albumArtUrl!.trim().isNotEmpty)
                ? albumArtUrl
                : null);

  String get responsiveArtworkKey {
    final meta = TrackMetadata.fromTrackInfo(this);
    return '${meta.providerId}:${meta.trackId}';
  }

  String get effectiveAlbumArtist =>
      (albumArtist != null && albumArtist!.trim().isNotEmpty)
          ? albumArtist!.trim()
          : artist;

  bool get hasDistinctAlbumArtist =>
      albumArtist != null &&
      albumArtist!.trim().isNotEmpty &&
      albumArtist!.trim() != artist.trim();

  TrackInfo copyWith({
    String? id,
    String? title,
    String? artist,
    String? album,
    Duration? duration,
    String? albumArtUrl,
    AudioFormat? format,
    String? providerName,
    String? filePath,
    String? albumArtist,
    String? genre,
    int? year,
    int? trackNumber,
    int? discNumber,
    String? composer,
    String? coverUrl,
    String? artworkCacheKey,
    bool? hasLyrics,
    String? isrc,
    String? qualityLabel,
    String? artistId,
    int? preference,
    String? albumGroupId,
    String? externalAlbumId,
  }) {
    return TrackInfo(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      duration: duration ?? this.duration,
      albumArtUrl: albumArtUrl ?? this.albumArtUrl,
      format: format ?? this.format,
      providerName: providerName ?? this.providerName,
      filePath: filePath ?? this.filePath,
      albumArtist: albumArtist ?? this.albumArtist,
      genre: genre ?? this.genre,
      year: year ?? this.year,
      trackNumber: trackNumber ?? this.trackNumber,
      discNumber: discNumber ?? this.discNumber,
      composer: composer ?? this.composer,
      coverUrl: coverUrl ?? this.coverUrl,
      artworkCacheKey: artworkCacheKey ?? this.artworkCacheKey,
      hasLyrics: hasLyrics ?? this.hasLyrics,
      isrc: isrc ?? this.isrc,
      qualityLabel: qualityLabel ?? this.qualityLabel,
      artistId: artistId ?? this.artistId,
      preference: preference ?? this.preference,
      albumGroupId: albumGroupId ?? this.albumGroupId,
      externalAlbumId: externalAlbumId ?? this.externalAlbumId,
    );
  }
}

class PlaybackState {
  final PlaybackStatus status;
  final TrackInfo? track;
  final Duration position;
  final double volume;
  final bool isMuted;
  final int seekEpoch;
  final bool isSeeking;
  final String? lastError;
  final bool deviceLost;
  final String clockSource;
  final int swapGeneration;
  final int playbackEpoch;
  final int timestampMs;
  final RepeatMode repeatMode;
  final bool shuffle;
  final AudioQualityInfo? audioQuality;
  final String? activeDeviceId;
  final String? activeZoneId;
  final LuminaError? error;

  const PlaybackState({
    required this.status,
    this.track,
    this.position = Duration.zero,
    this.volume = 0.85,
    this.isMuted = false,
    this.seekEpoch = 0,
    this.isSeeking = false,
    this.lastError,
    this.deviceLost = false,
    this.clockSource = 'system',
    this.swapGeneration = 0,
    this.playbackEpoch = 0,
    this.timestampMs = 0,
    this.repeatMode = RepeatMode.off,
    this.shuffle = false,
    this.audioQuality,
    this.activeDeviceId,
    this.activeZoneId,
    this.error,
  });

  factory PlaybackState.fromProtocol(
    ProtocolPlaybackState protocol, {
    TrackInfo? fallbackTrack,
  }) =>
      protocol.toLegacy(fallbackTrack: fallbackTrack);

  ProtocolPlaybackState toProtocol({
    int? timestampMs,
    bool dspBypassed = true,
    bool strictBitPerfect = false,
  }) =>
      ProtocolPlaybackState.fromLegacy(
        this,
        timestampMs: timestampMs,
        dspBypassed: dspBypassed,
        strictBitPerfect: strictBitPerfect,
      );

  static int parsePlaybackEpoch(Map<String, dynamic> json) {
    final p1 = (json['playback_epoch'] as num?)?.toInt() ?? 0;
    final p2 = (json['playbackEpoch'] as num?)?.toInt() ?? 0;
    final p3 = (json['epoch'] as num?)?.toInt() ?? 0;
    final p4 = (json['play_request_id'] as num?)?.toInt() ?? 0;
    var best = p1;
    if (p2 > best) best = p2;
    if (p3 > best) best = p3;
    if (p4 > best) best = p4;
    return best;
  }

  PlaybackState copyWith({
    PlaybackStatus? status,
    TrackInfo? track,
    Duration? position,
    double? volume,
    bool? isMuted,
    int? seekEpoch,
    bool? isSeeking,
    String? lastError,
    bool clearLastError = false,
    bool? deviceLost,
    String? clockSource,
    int? swapGeneration,
    int? playbackEpoch,
    int? timestampMs,
    RepeatMode? repeatMode,
    bool? shuffle,
    AudioQualityInfo? audioQuality,
    bool clearAudioQuality = false,
    String? activeDeviceId,
    bool clearActiveDeviceId = false,
    String? activeZoneId,
    bool clearActiveZoneId = false,
    LuminaError? error,
    bool clearError = false,
  }) {
    final resolvedError =
        (clearError || clearLastError) ? null : (error ?? this.error);
    return PlaybackState(
      status: status ?? this.status,
      track: track ?? this.track,
      position: position ?? this.position,
      volume: volume ?? this.volume,
      isMuted: isMuted ?? this.isMuted,
      seekEpoch: seekEpoch ?? this.seekEpoch,
      isSeeking: isSeeking ?? this.isSeeking,
      lastError: clearLastError
          ? null
          : (lastError ?? resolvedError?.message ?? this.lastError),
      deviceLost: deviceLost ?? this.deviceLost,
      clockSource: clockSource ?? this.clockSource,
      swapGeneration: swapGeneration ?? this.swapGeneration,
      playbackEpoch: playbackEpoch ?? this.playbackEpoch,
      timestampMs: timestampMs ?? this.timestampMs,
      repeatMode: repeatMode ?? this.repeatMode,
      shuffle: shuffle ?? this.shuffle,
      audioQuality:
          clearAudioQuality ? null : (audioQuality ?? this.audioQuality),
      activeDeviceId:
          clearActiveDeviceId ? null : (activeDeviceId ?? this.activeDeviceId),
      activeZoneId:
          clearActiveZoneId ? null : (activeZoneId ?? this.activeZoneId),
      error: resolvedError,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PlaybackState &&
        other.status == status &&
        other.track == track &&
        other.position == position &&
        other.volume == volume &&
        other.isMuted == isMuted &&
        other.seekEpoch == seekEpoch &&
        other.isSeeking == isSeeking &&
        other.lastError == lastError &&
        other.deviceLost == deviceLost &&
        other.clockSource == clockSource &&
        other.swapGeneration == swapGeneration &&
        other.playbackEpoch == playbackEpoch &&
        other.timestampMs == timestampMs &&
        other.repeatMode == repeatMode &&
        other.shuffle == shuffle &&
        other.audioQuality == audioQuality &&
        other.activeDeviceId == activeDeviceId &&
        other.activeZoneId == activeZoneId &&
        other.error == error;
  }

  @override
  int get hashCode => Object.hash(
    status,
    track,
    position,
    volume,
    isMuted,
    seekEpoch,
    isSeeking,
    lastError,
    deviceLost,
    clockSource,
    swapGeneration,
    playbackEpoch,
    timestampMs,
    repeatMode,
    shuffle,
    audioQuality,
    activeDeviceId,
    activeZoneId,
    error,
  );
}
