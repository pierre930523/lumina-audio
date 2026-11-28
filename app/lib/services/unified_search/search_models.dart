import 'package:flutter/foundation.dart';

import '../../models/playback_state.dart';
import '../../models/streaming_models.dart';
import '../../models/studio_models.dart';

/// Unified search result wrapper for a track from either local library or a
/// connected streaming provider.
@immutable
class SearchTrackMatch {
  final TrackInfo track;
  final String sourceKind;

  const SearchTrackMatch({
    required this.track,
    required this.sourceKind,
  });

  bool get isLocal => sourceKind == 'local';
}

/// Unified search result wrapper for an album from either local library or a
/// connected streaming provider.
@immutable
class SearchAlbumMatch {
  final String id;
  final String title;
  final String artist;
  final int? year;
  final String? coverUrl;
  final String? qualityLabel;
  final String sourceKind;
  final CanonicalAlbumSummary? localAlbum;
  final StreamingAlbum? streamingAlbum;

  const SearchAlbumMatch({
    required this.id,
    required this.title,
    required this.artist,
    required this.sourceKind,
    this.year,
    this.coverUrl,
    this.qualityLabel,
    this.localAlbum,
    this.streamingAlbum,
  });

  factory SearchAlbumMatch.local(CanonicalAlbumSummary album) {
    return SearchAlbumMatch(
      id: album.id,
      title: album.title,
      artist: album.artist,
      year: album.year,
      coverUrl: album.coverUrl,
      sourceKind: 'local',
      localAlbum: album,
    );
  }

  factory SearchAlbumMatch.streaming(StreamingAlbum album) {
    return SearchAlbumMatch(
      id: album.id,
      title: album.title,
      artist: album.artist,
      year: album.year,
      coverUrl: album.coverUrl,
      qualityLabel: album.qualityLabel,
      sourceKind: album.providerKind,
      streamingAlbum: album,
    );
  }

  bool get isLocal => sourceKind == 'local';
}

/// Unified search result wrapper for an artist extracted from local library
/// or streaming search catalogs.
@immutable
class SearchArtistMatch {
  final String name;
  final List<String> sourceKinds;
  final int albumCount;
  final int trackCount;
  final String? coverUrl;
  final CanonicalAlbumSummary? representativeAlbum;
  final TrackInfo? representativeTrack;

  const SearchArtistMatch({
    required this.name,
    required this.sourceKinds,
    this.albumCount = 0,
    this.trackCount = 0,
    this.coverUrl,
    this.representativeAlbum,
    this.representativeTrack,
  });
}

/// Per-provider streaming search state & results bucket.
@immutable
class ProviderSearchBucket {
  final String providerKind;
  final List<TrackInfo> tracks;
  final List<StreamingAlbum> albums;
  final List<SearchArtistMatch> artists;
  final bool isLoading;
  final String? error;

  const ProviderSearchBucket({
    required this.providerKind,
    this.tracks = const [],
    this.albums = const [],
    this.artists = const [],
    this.isLoading = false,
    this.error,
  });

  int get totalCount => tracks.length + albums.length + artists.length;
  bool get hasError => error != null && error!.trim().isNotEmpty;

  ProviderSearchBucket copyWith({
    List<TrackInfo>? tracks,
    List<StreamingAlbum>? albums,
    List<SearchArtistMatch>? artists,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return ProviderSearchBucket(
      providerKind: providerKind,
      tracks: tracks ?? this.tracks,
      albums: albums ?? this.albums,
      artists: artists ?? this.artists,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}
