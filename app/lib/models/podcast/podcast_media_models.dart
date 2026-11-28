import 'package:flutter/foundation.dart';

import '../audio_format.dart';
import '../playback_state.dart';
import '../streaming_models.dart';

String? _upgradePodcastArtworkUrl(Object? value) {
  final raw = value?.toString().trim();
  if (raw == null || raw.isEmpty) return raw;
  return upgradeStreamingCoverUrl(raw) ?? raw;
}

/// Represents a YouTube Music Podcast show (`browseId` such as `MPSPPL...`).
@immutable
class PodcastShow {
  final String id;
  final String title;
  final String author;
  final String? artworkUrl;
  final String? description;
  final String? episodeCountLabel;
  final String? latestEpisodeTitle;

  const PodcastShow({
    required this.id,
    required this.title,
    this.author = '',
    this.artworkUrl,
    this.description,
    this.episodeCountLabel,
    this.latestEpisodeTitle,
  });

  PodcastShow copyWith({
    String? id,
    String? title,
    String? author,
    String? artworkUrl,
    String? description,
    String? episodeCountLabel,
    String? latestEpisodeTitle,
  }) {
    return PodcastShow(
      id: id ?? this.id,
      title: title ?? this.title,
      author: author ?? this.author,
      artworkUrl: artworkUrl ?? this.artworkUrl,
      description: description ?? this.description,
      episodeCountLabel: episodeCountLabel ?? this.episodeCountLabel,
      latestEpisodeTitle: latestEpisodeTitle ?? this.latestEpisodeTitle,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'author': author,
        if (artworkUrl != null) 'artworkUrl': artworkUrl,
        if (description != null) 'description': description,
        if (episodeCountLabel != null) 'episodeCountLabel': episodeCountLabel,
        if (latestEpisodeTitle != null)
          'latestEpisodeTitle': latestEpisodeTitle,
      };

  factory PodcastShow.fromJson(Map<String, dynamic> json) {
    return PodcastShow(
      id: json['id']?.toString().trim() ?? '',
      title: json['title']?.toString().trim() ?? '',
      author: json['author']?.toString().trim() ?? '',
      artworkUrl: _upgradePodcastArtworkUrl(json['artworkUrl']),
      description: json['description']?.toString().trim(),
      episodeCountLabel: json['episodeCountLabel']?.toString().trim(),
      latestEpisodeTitle: json['latestEpisodeTitle']?.toString().trim(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PodcastShow &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          title == other.title &&
          author == other.author &&
          artworkUrl == other.artworkUrl &&
          description == other.description &&
          episodeCountLabel == other.episodeCountLabel &&
          latestEpisodeTitle == other.latestEpisodeTitle;

  @override
  int get hashCode => Object.hash(
        id,
        title,
        author,
        artworkUrl,
        description,
        episodeCountLabel,
        latestEpisodeTitle,
      );
}

/// Represents a playable Podcast episode backed either by an 11-char YouTube
/// `videoId` or an external RSS audio URL (`audioUrl`).
@immutable
class PodcastEpisode {
  final String videoId;
  final String showId;
  final String showTitle;
  final String title;
  final String author;
  final String? artworkUrl;
  final String? publishedLabel;
  final Duration duration;
  final String? description;
  final String? audioUrl;

  const PodcastEpisode({
    required this.videoId,
    this.showId = '',
    this.showTitle = '',
    required this.title,
    this.author = '',
    this.artworkUrl,
    this.publishedLabel,
    this.duration = Duration.zero,
    this.description,
    this.audioUrl,
  });

  static bool _isExternalHttpAudioUrl(String raw) {
    final trimmed = raw.trim();
    final lower = trimmed.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return false;
    }
    final uri = Uri.tryParse(trimmed);
    final host = uri?.host.toLowerCase() ?? '';
    if (host == 'youtube.com' ||
        host.endsWith('.youtube.com') ||
        host == 'youtu.be' ||
        host.endsWith('.youtu.be')) {
      return false;
    }
    return true;
  }

  /// Effective external RSS audio URL when this episode is hosted outside YouTube.
  String? get externalAudioUrl {
    final explicit = audioUrl?.trim();
    if (explicit != null && _isExternalHttpAudioUrl(explicit)) {
      return explicit;
    }
    final fallback = videoId.trim();
    if (_isExternalHttpAudioUrl(fallback)) {
      return fallback;
    }
    return null;
  }

  /// True when this episode points to an external RSS enclosure audio URL rather
  /// than a YouTube `videoId`.
  bool get isExternalRssAudio => externalAudioUrl != null;

  /// Converts this episode to a [TrackInfo] that routes through the unified
  /// `StreamResolver` + Rust `ChunkedStreamProxy` pipeline (`youtube_music` for
  /// YouTube Podcasts, `podcast_rss` for external RSS audio URLs).
  TrackInfo toTrack() {
    final cleanAuthor = author.trim();
    final cleanShow = showTitle.trim();
    final effectiveArtist = cleanAuthor.isNotEmpty
        ? cleanAuthor
        : (cleanShow.isNotEmpty ? cleanShow : 'YouTube Music Podcast');
    final effectiveAlbum =
        cleanShow.isNotEmpty ? cleanShow : effectiveArtist;

    final rssUrl = externalAudioUrl;
    if (rssUrl != null) {
      final lowerPath = (Uri.tryParse(rssUrl)?.path ?? rssUrl).toLowerCase();
      final AudioCodec codec;
      if (lowerPath.endsWith('.mp3')) {
        codec = AudioCodec.mp3;
      } else if (lowerPath.endsWith('.opus') ||
          lowerPath.endsWith('.webm') ||
          lowerPath.endsWith('.ogg')) {
        codec = AudioCodec.opus;
      } else if (lowerPath.endsWith('.flac')) {
        codec = AudioCodec.flac;
      } else if (lowerPath.endsWith('.wav')) {
        codec = AudioCodec.wav;
      } else {
        codec = AudioCodec.aac;
      }
      return TrackInfo(
        id: 'podcast_rss:$rssUrl',
        title: title,
        artist: effectiveArtist,
        album: effectiveAlbum,
        duration: duration,
        albumArtUrl: artworkUrl,
        coverUrl: artworkUrl,
        format: AudioFormat(
          codec: codec,
          sampleRateHz: codec == AudioCodec.opus ? 48000 : 44100,
          bitDepth: 16,
          channels: 2,
        ),
        providerName: 'Podcast',
      );
    }

    return TrackInfo(
      id: 'ytm:$videoId',
      title: title,
      artist: effectiveArtist,
      album: effectiveAlbum,
      duration: duration,
      albumArtUrl: artworkUrl,
      coverUrl: artworkUrl,
      format: const AudioFormat(
        codec: AudioCodec.opus,
        sampleRateHz: 48000,
        bitDepth: 16,
        channels: 2,
      ),
      providerName: 'Podcast',
    );
  }

  PodcastEpisode copyWith({
    String? videoId,
    String? showId,
    String? showTitle,
    String? title,
    String? author,
    String? artworkUrl,
    String? publishedLabel,
    Duration? duration,
    String? description,
    String? audioUrl,
  }) {
    return PodcastEpisode(
      videoId: videoId ?? this.videoId,
      showId: showId ?? this.showId,
      showTitle: showTitle ?? this.showTitle,
      title: title ?? this.title,
      author: author ?? this.author,
      artworkUrl: artworkUrl ?? this.artworkUrl,
      publishedLabel: publishedLabel ?? this.publishedLabel,
      duration: duration ?? this.duration,
      description: description ?? this.description,
      audioUrl: audioUrl ?? this.audioUrl,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'videoId': videoId,
        'showId': showId,
        'showTitle': showTitle,
        'title': title,
        'author': author,
        if (artworkUrl != null) 'artworkUrl': artworkUrl,
        if (publishedLabel != null) 'publishedLabel': publishedLabel,
        'durationSeconds': duration.inSeconds,
        if (description != null) 'description': description,
        if (audioUrl != null) 'audioUrl': audioUrl,
      };

  factory PodcastEpisode.fromJson(Map<String, dynamic> json) {
    final durSec = (json['durationSeconds'] as num?)?.toInt() ?? 0;
    return PodcastEpisode(
      videoId: json['videoId']?.toString().trim() ?? '',
      showId: json['showId']?.toString().trim() ?? '',
      showTitle: json['showTitle']?.toString().trim() ?? '',
      title: json['title']?.toString().trim() ?? '',
      author: json['author']?.toString().trim() ?? '',
      artworkUrl: _upgradePodcastArtworkUrl(json['artworkUrl']),
      publishedLabel: json['publishedLabel']?.toString().trim(),
      duration: Duration(seconds: durSec < 0 ? 0 : durSec),
      description: json['description']?.toString().trim(),
      audioUrl: json['audioUrl']?.toString().trim(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PodcastEpisode &&
          runtimeType == other.runtimeType &&
          videoId == other.videoId &&
          showId == other.showId &&
          showTitle == other.showTitle &&
          title == other.title &&
          author == other.author &&
          artworkUrl == other.artworkUrl &&
          publishedLabel == other.publishedLabel &&
          duration == other.duration &&
          description == other.description &&
          audioUrl == other.audioUrl;

  @override
  int get hashCode => Object.hash(
        videoId,
        showId,
        showTitle,
        title,
        author,
        artworkUrl,
        publishedLabel,
        duration,
        description,
        audioUrl,
      );
}
