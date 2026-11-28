import 'package:flutter/foundation.dart';

import '../../models/playback_state.dart';
import '../../models/studio_models.dart';

/// Aggregated synchronous index record for an artist across albums and tracks.
@immutable
class ArtistIndexEntry {
  final String key;
  final String displayName;
  final String? artistId;
  final int preference;
  final List<CanonicalAlbumSummary> albums;
  final List<TrackInfo> tracks;
  final CanonicalAlbumSummary? representativeAlbum;
  final TrackInfo? representativeTrack;

  const ArtistIndexEntry({
    required this.key,
    required this.displayName,
    this.artistId,
    this.preference = 0,
    this.albums = const [],
    this.tracks = const [],
    this.representativeAlbum,
    this.representativeTrack,
  });

  int get albumCount => albums.length;
  int get trackCount => tracks.length;
  int get totalTrackCount => tracks.length;
}
