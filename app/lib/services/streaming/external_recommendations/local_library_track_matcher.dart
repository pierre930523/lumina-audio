import '../../../models/playback_state.dart';
import '../../../models/recommendation_models.dart';
import '../../../models/streaming_models.dart';
import '../track_matcher.dart';

/// Cross-platform matcher for the user's local audio library, prioritizing
/// lossless (`FLAC` / `ALAC` / `WAV` / `DSD`) local files over remote streams.
class LocalLibraryTrackMatcher {
  final Future<List<TrackInfo>> Function(String query) searchLibrary;

  const LocalLibraryTrackMatcher({required this.searchLibrary});

  Future<TrackMetadata?> matchTrack(
    TrackMatchQuery query, {
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    final title = query.title.trim();
    final artist = query.artist.trim();
    if (title.isEmpty && artist.isEmpty) return null;

    final candidatesById = <String, TrackMetadata>{};

    Future<void> runSearch(String q) async {
      final trimmed = q.trim();
      if (trimmed.isEmpty) return;
      cancel?.throwIfCancelled();
      final hits = await searchLibrary(trimmed);
      cancel?.throwIfCancelled();
      for (final hit in hits) {
        if (hit.preference == -1) continue;
        final meta = TrackMetadata.fromTrackInfo(
          hit,
          providerIdOverride: 'local',
        );
        candidatesById.putIfAbsent(meta.trackId, () => meta);
      }
    }

    if (title.isNotEmpty) {
      await runSearch(title);
    }
    var best = TrackMatcher.selectBestMatch(query, candidatesById.values);
    if (best != null) return best;

    if (artist.isNotEmpty) {
      final combined = title.isNotEmpty ? '$artist $title' : artist;
      await runSearch(combined);
      best = TrackMatcher.selectBestMatch(query, candidatesById.values);
      if (best != null) return best;
    }

    return null;
  }
}
