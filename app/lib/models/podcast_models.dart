import 'package:flutter/foundation.dart';

import 'audio_format.dart';
import 'playback_state.dart';
import 'streaming_models.dart';

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

/// Full show detail payload including ordered episode list and pagination token.
@immutable
class PodcastShowDetail {
  final PodcastShow show;
  final List<PodcastEpisode> episodes;
  final String? continuationToken;

  const PodcastShowDetail({
    required this.show,
    this.episodes = const <PodcastEpisode>[],
    this.continuationToken,
  });

  PodcastShowDetail copyWith({
    PodcastShow? show,
    List<PodcastEpisode>? episodes,
    String? continuationToken,
    bool clearContinuation = false,
  }) {
    return PodcastShowDetail(
      show: show ?? this.show,
      episodes: episodes ?? this.episodes,
      continuationToken: clearContinuation
          ? null
          : (continuationToken ?? this.continuationToken),
    );
  }
}

/// Explore feed result containing recommended podcast shows and episodes.
@immutable
class PodcastExploreResult {
  final List<PodcastShow> shows;
  final List<PodcastEpisode> episodes;
  final String? continuationToken;

  const PodcastExploreResult({
    this.shows = const <PodcastShow>[],
    this.episodes = const <PodcastEpisode>[],
    this.continuationToken,
  });

  bool get isEmpty => shows.isEmpty && episodes.isEmpty;
}

/// Personal podcast library result containing subscribed shows and new episodes.
@immutable
class PodcastLibraryResult {
  final List<PodcastShow> shows;
  final List<PodcastEpisode> episodes;
  final String? continuationToken;

  const PodcastLibraryResult({
    this.shows = const <PodcastShow>[],
    this.episodes = const <PodcastEpisode>[],
    this.continuationToken,
  });

  bool get isEmpty => shows.isEmpty && episodes.isEmpty;
}

/// Podcast search result containing matching shows and episodes.
@immutable
class PodcastSearchResult {
  final List<PodcastShow> shows;
  final List<PodcastEpisode> episodes;
  final String? continuationToken;

  const PodcastSearchResult({
    this.shows = const <PodcastShow>[],
    this.episodes = const <PodcastEpisode>[],
    this.continuationToken,
  });

  bool get isEmpty => shows.isEmpty && episodes.isEmpty;
}

/// Persisted per-episode listening progress.
@immutable
class PodcastEpisodeProgress {
  final String videoId;
  final int positionSeconds;
  final int durationSeconds;
  final DateTime updatedAt;
  final bool completed;

  const PodcastEpisodeProgress({
    required this.videoId,
    required this.positionSeconds,
    required this.durationSeconds,
    required this.updatedAt,
    required this.completed,
  });

  /// Auto-marks completed when `durationSeconds > 0` and either
  /// `positionSeconds >= durationSeconds - 10` (for episodes > 10s) or `>= 95%`.
  static bool shouldMarkCompleted({
    required int positionSeconds,
    required int durationSeconds,
  }) {
    if (durationSeconds <= 0 || positionSeconds <= 0) return false;
    if (durationSeconds > 10 && positionSeconds >= durationSeconds - 10) {
      return true;
    }
    return (positionSeconds / durationSeconds) >= 0.95;
  }

  double get progressFraction {
    if (completed) return 1.0;
    if (durationSeconds <= 0 || positionSeconds <= 0) return 0.0;
    return (positionSeconds / durationSeconds).clamp(0.0, 1.0);
  }

  String get formattedPosition => formatSeconds(positionSeconds);

  static String formatSeconds(int totalSeconds) {
    final clamped = totalSeconds < 0 ? 0 : totalSeconds;
    final hrs = clamped ~/ 3600;
    final mins = (clamped % 3600) ~/ 60;
    final secs = clamped % 60;
    if (hrs > 0) {
      return '$hrs:${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  PodcastEpisodeProgress copyWith({
    String? videoId,
    int? positionSeconds,
    int? durationSeconds,
    DateTime? updatedAt,
    bool? completed,
  }) {
    return PodcastEpisodeProgress(
      videoId: videoId ?? this.videoId,
      positionSeconds: positionSeconds ?? this.positionSeconds,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      updatedAt: updatedAt ?? this.updatedAt,
      completed: completed ?? this.completed,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'videoId': videoId,
        'positionSeconds': positionSeconds,
        'durationSeconds': durationSeconds,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'completed': completed,
      };

  factory PodcastEpisodeProgress.fromJson(Map<String, dynamic> json) {
    final posSec = (json['positionSeconds'] as num?)?.toInt() ?? 0;
    final durSec = (json['durationSeconds'] as num?)?.toInt() ?? 0;
    final rawCompleted = json['completed'] == true;
    return PodcastEpisodeProgress(
      videoId: json['videoId']?.toString().trim() ?? '',
      positionSeconds: posSec < 0 ? 0 : posSec,
      durationSeconds: durSec < 0 ? 0 : durSec,
      updatedAt:
          DateTime.tryParse(json['updatedAt']?.toString() ?? '')?.toUtc() ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      completed: rawCompleted ||
          shouldMarkCompleted(
            positionSeconds: posSec,
            durationSeconds: durSec,
          ),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PodcastEpisodeProgress &&
          runtimeType == other.runtimeType &&
          videoId == other.videoId &&
          positionSeconds == other.positionSeconds &&
          durationSeconds == other.durationSeconds &&
          completed == other.completed;

  @override
  int get hashCode => Object.hash(
        videoId,
        positionSeconds,
        durationSeconds,
        completed,
      );
}
