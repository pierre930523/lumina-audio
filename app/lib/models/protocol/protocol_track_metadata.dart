import 'package:flutter/foundation.dart';

import '../audio_format.dart';
import '../playback_state.dart';
import 'audio_quality_info.dart';
import 'json_reader.dart';

/// Canonical wire track metadata matching Rust `core_types::TrackMetadata`.
@immutable
class ProtocolTrackMetadata {
  final String trackId;
  final String providerId;
  final String title;
  final String artist;
  final String album;
  final String? albumId;
  final String? artistId;
  final String? coverUrl;
  final int durationMs;
  final int? trackNumber;
  final int? discNumber;
  final String? isrc;
  final String? uri;
  final AudioQualityInfo? audioQuality;

  const ProtocolTrackMetadata({
    required this.trackId,
    required this.providerId,
    required this.title,
    required this.artist,
    required this.album,
    this.albumId,
    this.artistId,
    this.coverUrl,
    this.durationMs = 0,
    this.trackNumber,
    this.discNumber,
    this.isrc,
    this.uri,
    this.audioQuality,
  });

  factory ProtocolTrackMetadata.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    final qualityMap = r.optionalMap('audio_quality');
    return ProtocolTrackMetadata(
      trackId: r.nonEmptyString('track_id') ??
          r.nonEmptyString('id') ??
          r.nonEmptyString('external_track_id') ??
          '',
      providerId: r.requiredString('provider_id', fallback: 'local'),
      title: r.requiredString('title'),
      artist: r.requiredString('artist'),
      album: r.requiredString('album'),
      albumId: r.nonEmptyString('album_id'),
      artistId: r.nonEmptyString('artist_id'),
      coverUrl: r.nonEmptyString('cover_url') ?? r.nonEmptyString('album_art_url'),
      durationMs: r.requiredInt('duration_ms', fallback: 0),
      trackNumber: r.optionalInt('track_number'),
      discNumber: r.optionalInt('disc_number'),
      isrc: r.nonEmptyString('isrc'),
      uri: r.nonEmptyString('uri') ?? r.nonEmptyString('file_path'),
      audioQuality:
          qualityMap != null ? AudioQualityInfo.fromJson(qualityMap) : null,
    );
  }

  factory ProtocolTrackMetadata.fromTrackInfo(TrackInfo track) {
    final inferredProvider = _inferProviderId(track.id, track.providerName);
    return ProtocolTrackMetadata(
      trackId: track.id,
      providerId: inferredProvider,
      title: track.title,
      artist: track.artist,
      album: track.album,
      artistId: track.artistId,
      coverUrl: track.artworkUrl,
      durationMs: track.duration.inMilliseconds,
      trackNumber: track.trackNumber,
      discNumber: track.discNumber,
      isrc: track.isrc,
      uri: track.filePath,
      audioQuality: AudioQualityInfo.fromAudioFormat(track.format),
    );
  }

  static String _inferProviderId(String id, String providerName) {
    final lowerId = id.toLowerCase();
    if (lowerId.startsWith('qobuz:')) return 'qobuz';
    if (lowerId.startsWith('tidal:')) return 'tidal';
    if (lowerId.startsWith('deezer:')) return 'deezer';
    if (lowerId.startsWith('ytm:') ||
        lowerId.startsWith('ytm_') ||
        lowerId.startsWith('youtube_music:')) {
      return 'youtube_music';
    }
    if (lowerId.startsWith('apple:') || lowerId.startsWith('apple_music:')) {
      return 'apple_music';
    }
    if (lowerId.startsWith('podcast_rss:') || lowerId.startsWith('rss:')) {
      return 'podcast_rss';
    }
    final lowerName = providerName.trim().toLowerCase();
    if (lowerName.contains('qobuz')) return 'qobuz';
    if (lowerName.contains('tidal')) return 'tidal';
    if (lowerName.contains('deezer')) return 'deezer';
    if (lowerName.contains('youtube')) return 'youtube_music';
    if (lowerName.contains('apple')) return 'apple_music';
    if (lowerName.contains('podcast')) return 'podcast_rss';
    return 'local';
  }

  TrackInfo toTrackInfo() {
    return TrackInfo(
      id: trackId,
      title: title,
      artist: artist,
      album: album,
      duration: Duration(milliseconds: durationMs < 0 ? 0 : durationMs),
      albumArtUrl: coverUrl,
      coverUrl: coverUrl,
      format: audioQuality?.toAudioFormat() ??
          const AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: 44100,
            bitDepth: 16,
            channels: 2,
          ),
      providerName: providerId,
      filePath: uri,
      trackNumber: trackNumber,
      discNumber: discNumber,
      isrc: isrc,
      artistId: artistId,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'track_id': trackId,
      'provider_id': providerId,
      'title': title,
      'artist': artist,
      'album': album,
      if (albumId != null) 'album_id': albumId,
      if (artistId != null) 'artist_id': artistId,
      if (coverUrl != null) 'cover_url': coverUrl,
      'duration_ms': durationMs,
      if (trackNumber != null) 'track_number': trackNumber,
      if (discNumber != null) 'disc_number': discNumber,
      if (isrc != null) 'isrc': isrc,
      if (uri != null) 'uri': uri,
      if (audioQuality != null) 'audio_quality': audioQuality!.toJson(),
    };
  }

  ProtocolTrackMetadata copyWith({
    String? trackId,
    String? providerId,
    String? title,
    String? artist,
    String? album,
    String? albumId,
    String? artistId,
    String? coverUrl,
    int? durationMs,
    int? trackNumber,
    int? discNumber,
    String? isrc,
    String? uri,
    AudioQualityInfo? audioQuality,
  }) {
    return ProtocolTrackMetadata(
      trackId: trackId ?? this.trackId,
      providerId: providerId ?? this.providerId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      albumId: albumId ?? this.albumId,
      artistId: artistId ?? this.artistId,
      coverUrl: coverUrl ?? this.coverUrl,
      durationMs: durationMs ?? this.durationMs,
      trackNumber: trackNumber ?? this.trackNumber,
      discNumber: discNumber ?? this.discNumber,
      isrc: isrc ?? this.isrc,
      uri: uri ?? this.uri,
      audioQuality: audioQuality ?? this.audioQuality,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ProtocolTrackMetadata &&
        other.trackId == trackId &&
        other.providerId == providerId &&
        other.title == title &&
        other.artist == artist &&
        other.album == album &&
        other.albumId == albumId &&
        other.artistId == artistId &&
        other.coverUrl == coverUrl &&
        other.durationMs == durationMs &&
        other.trackNumber == trackNumber &&
        other.discNumber == discNumber &&
        other.isrc == isrc &&
        other.uri == uri &&
        other.audioQuality == audioQuality;
  }

  @override
  int get hashCode => Object.hash(
        trackId,
        providerId,
        title,
        artist,
        album,
        albumId,
        artistId,
        coverUrl,
        durationMs,
        trackNumber,
        discNumber,
        isrc,
        uri,
        audioQuality,
      );
}
