part of 'audio_service.dart';

/// Shared default visualizer constants retained for backward compatibility.
/// Instance visualizer methods now live directly on [AudioService] with full
/// static typing (zero `dynamic` dispatch).
extension AudioServiceVisualizerExt on AudioService {
  static final Float32List zeroBands64 = Float32List(64);
  static final ValueNotifier<Float32List> defaultVisualizerNotifier =
      ValueNotifier<Float32List>(zeroBands64);
}

/// Optional Dual-Deck pre-decode and zero-latency skip capability for
/// [AudioService] implementations supporting standby track preparation.
abstract interface class DualDeckAudioService {
  Future<void> prepareStandbySpecAsync(
    TrackInfo track,
    StreamSourceSpec spec, {
    int? epoch,
  });

  Future<bool> skipToStandby({int? epoch});

  bool get isStandbyDeckReady;
}

/// Safe dual-deck extension forwarding standby operations to
/// [DualDeckAudioService] implementations without breaking remote/server contracts.
extension AudioServiceDualDeckExt on AudioService {
  Future<void> prepareStandbySpecAsync(
    TrackInfo track,
    StreamSourceSpec spec, {
    int? epoch,
  }) async {
    if (this is DualDeckAudioService) {
      await (this as DualDeckAudioService).prepareStandbySpecAsync(
        track,
        spec,
        epoch: epoch,
      );
    }
  }

  Future<bool> skipToStandby({int? epoch}) async {
    if (this is DualDeckAudioService) {
      return (this as DualDeckAudioService).skipToStandby(epoch: epoch);
    }
    return false;
  }

  bool get isStandbyDeckReady {
    if (this is DualDeckAudioService) {
      return (this as DualDeckAudioService).isStandbyDeckReady;
    }
    return false;
  }
}

/// Optional capability for [AudioService] implementations that expose raw
/// SQLite/local library tracks separately from the active playback [queue].
abstract interface class LibraryTracksAudioService {
  List<TrackInfo> get libraryTracks;
  Future<List<TrackInfo>> getLibraryTracks({int limit = 10000});
}

/// Safe library-tracks accessor that bypasses streaming/podcast playback queues
/// on coordinating facades while falling back to [AudioService.queue] in mocks.
extension AudioServiceLibraryTracksExt on AudioService {
  List<TrackInfo> get libraryTracks {
    if (this is LibraryTracksAudioService) {
      return (this as LibraryTracksAudioService).libraryTracks;
    }
    return queue;
  }

  Future<List<TrackInfo>> getLibraryTracks({int limit = 10000}) async {
    if (this is LibraryTracksAudioService) {
      return (this as LibraryTracksAudioService).getLibraryTracks(limit: limit);
    }
    return List<TrackInfo>.from(queue);
  }
}
