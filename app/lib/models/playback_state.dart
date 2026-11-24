import 'audio_format.dart';

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
  });

  String? get artworkUrl =>
      (coverUrl != null && coverUrl!.trim().isNotEmpty)
          ? coverUrl
          : ((albumArtUrl != null && albumArtUrl!.trim().isNotEmpty)
                ? albumArtUrl
                : null);

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
  });

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
  }) {
    return PlaybackState(
      status: status ?? this.status,
      track: track ?? this.track,
      position: position ?? this.position,
      volume: volume ?? this.volume,
      isMuted: isMuted ?? this.isMuted,
      seekEpoch: seekEpoch ?? this.seekEpoch,
      isSeeking: isSeeking ?? this.isSeeking,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      deviceLost: deviceLost ?? this.deviceLost,
      clockSource: clockSource ?? this.clockSource,
    );
  }
}
