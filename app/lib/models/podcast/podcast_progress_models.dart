import 'package:flutter/foundation.dart';

import 'podcast_media_models.dart';

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
