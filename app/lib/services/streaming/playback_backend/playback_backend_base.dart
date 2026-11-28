import '../../../models/playback_state.dart';
import '../../../models/stream_source_spec.dart';
import '../../audio_service.dart';

/// Optional transport capability allowing [NativePlaybackBackend] to forward
/// monotonic command epochs on seek without breaking minimal [AudioService]
/// fakes.
abstract interface class EpochAwareSeekAudioService {
  Future<void> seekAtEpoch(Duration position, {required int epoch});
}

/// Unified playback backend abstraction isolating native Rust/AudioService
/// playback from external DRM-hosted players (e.g. Apple Music MusicKit JS).
abstract class PlaybackBackend {
  Future<void> play(
    StreamSourceSpec spec,
    TrackInfo track, {
    required int epoch,
  });

  Future<void> pause();
  Future<void> resume();
  Future<void> seek(Duration position, {required int epoch});
  Future<void> setVolume(double volume);
  Future<void> stop({required int epoch});

  Stream<PlaybackState> get stateStream;
  PlaybackState get currentState;

  void dispose();
}

/// Optional dual-deck pre-decode & zero-latency manual skip capability
/// implemented by backends supporting standby track preparation.
abstract interface class DualDeckPlaybackBackend {
  Future<void> prepareStandby(
    StreamSourceSpec spec,
    TrackInfo track, {
    required int epoch,
  });

  Future<bool> skipToStandby({required int epoch});

  bool get isStandbyReady;
}

/// Safe dual-deck extension forwarding calls when the backend implements
/// [DualDeckPlaybackBackend] without breaking `implements PlaybackBackend` fakes.
extension PlaybackBackendDualDeckExt on PlaybackBackend {
  Future<void> prepareStandby(
    StreamSourceSpec spec,
    TrackInfo track, {
    required int epoch,
  }) async {
    if (this is DualDeckPlaybackBackend) {
      await (this as DualDeckPlaybackBackend).prepareStandby(
        spec,
        track,
        epoch: epoch,
      );
    }
  }

  Future<bool> skipToStandby({required int epoch}) async {
    if (this is DualDeckPlaybackBackend) {
      return (this as DualDeckPlaybackBackend).skipToStandby(epoch: epoch);
    }
    return false;
  }

  bool get isStandbyReady {
    if (this is DualDeckPlaybackBackend) {
      return (this as DualDeckPlaybackBackend).isStandbyReady;
    }
    return false;
  }
}

/// Safe debounced-play extension forwarding [debounced] metadata when supported
/// without breaking `implements PlaybackBackend` fakes.
extension PlaybackBackendDebouncedExt on PlaybackBackend {
  Future<void> playWithDebounced(
    StreamSourceSpec spec,
    TrackInfo track, {
    required int epoch,
    bool debounced = false,
  }) {
    if (this is NativePlaybackBackend) {
      return (this as NativePlaybackBackend).playWithDebounced(
        spec,
        track,
        epoch: epoch,
        debounced: debounced,
      );
    }
    return play(spec, track, epoch: epoch);
  }
}

/// Native Rust audio engine backend backed by [AudioService].
class NativePlaybackBackend extends PlaybackBackend
    implements DualDeckPlaybackBackend {
  final AudioService audioService;
  bool _nextPlayDebounced = false;
  bool _isInvokingStop = false;
  bool Function(int epoch)? shouldAllowStopAtEpoch;

  bool get isInvokingStop => _isInvokingStop;

  NativePlaybackBackend(this.audioService);

  @override
  Stream<PlaybackState> get stateStream => audioService.stateStream;

  @override
  PlaybackState get currentState => audioService.currentState;

  Future<void> playWithDebounced(
    StreamSourceSpec spec,
    TrackInfo track, {
    required int epoch,
    required bool debounced,
  }) async {
    _nextPlayDebounced = debounced;
    try {
      await play(spec, track, epoch: epoch);
    } finally {
      _nextPlayDebounced = false;
    }
  }

  @override
  Future<void> play(
    StreamSourceSpec spec,
    TrackInfo track, {
    required int epoch,
  }) {
    if (spec is ExternalBackendSpec) {
      throw StateError(
        'NativePlaybackBackend cannot play ExternalBackendSpec '
        '(${spec.providerId})',
      );
    }
    final debounced = _nextPlayDebounced;
    _nextPlayDebounced = false;
    return audioService.playStreamSpecWithOptions(
      track,
      spec,
      epoch: epoch,
      debounced: debounced,
    );
  }

  @override
  Future<void> prepareStandby(
    StreamSourceSpec spec,
    TrackInfo track, {
    required int epoch,
  }) {
    if (spec is ExternalBackendSpec) {
      throw StateError(
        'NativePlaybackBackend cannot prepare ExternalBackendSpec '
        '(${spec.providerId})',
      );
    }
    return audioService.prepareStandbySpecAsync(track, spec, epoch: epoch);
  }

  @override
  Future<bool> skipToStandby({required int epoch}) =>
      audioService.skipToStandby(epoch: epoch);

  @override
  bool get isStandbyReady => audioService.isStandbyDeckReady;

  @override
  Future<void> pause() => audioService.pause();

  @override
  Future<void> resume() => audioService.resume();

  @override
  Future<void> seek(Duration position, {required int epoch}) {
    final svc = audioService;
    if (svc is EpochAwareSeekAudioService) {
      return (svc as EpochAwareSeekAudioService).seekAtEpoch(
        position,
        epoch: epoch,
      );
    }
    return svc.seek(position);
  }

  @override
  Future<void> setVolume(double volume) => audioService.setVolume(volume);

  @override
  Future<void> stop({required int epoch}) async {
    await audioService.cancelPendingPlaybackAtEpoch(epoch);
    final guard = shouldAllowStopAtEpoch;
    if (guard != null && !guard(epoch)) {
      return;
    }
    _isInvokingStop = true;
    try {
      await audioService.stop();
    } finally {
      _isInvokingStop = false;
    }
  }

  @override
  void dispose() {
    // AudioService lifetime is managed by its owner (HomeScreen or test).
  }
}
