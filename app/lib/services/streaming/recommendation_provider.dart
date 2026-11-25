import '../../models/recommendation_models.dart';
import '../../models/stream_source_spec.dart';
import '../../models/streaming_models.dart';

/// Unified capability-driven interface implemented by streaming and external
/// metadata providers that supply Track Radio, Personalized Feeds, or Track
/// Matching.
abstract interface class RecommendationProvider {
  String get recommendationProviderId;
  ProviderCapabilities get capabilities;

  Future<RadioPage> getTrackRadio(
    TrackMetadata seed, {
    int limit = 10,
    String? cursor,
    CancellationToken? cancel,
  });

  Future<List<FeedSection>> getPersonalizedFeed({
    CancellationToken? cancel,
  });

  Future<TrackMetadata?> matchTrack(
    TrackMatchQuery query, {
    CancellationToken? cancel,
  });
}
