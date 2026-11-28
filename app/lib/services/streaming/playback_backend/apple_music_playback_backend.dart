import 'dart:async';

import '../../../models/playback_state.dart';
import '../../../models/stream_source_spec.dart';
import 'external_playback_bridge.dart';
import 'playback_backend_base.dart';

/// Isolated Apple Music / external DRM playback backend.
///
/// Completely decoupled from `AudioService`, Rust `ByteStreamSource`, and any
/// localhost HTTP/FFmpeg proxy.
class AppleMusicPlaybackBackend extends PlaybackBackend
    implements DualDeckPlaybackBackend {
  final ExternalPlaybackBridge bridge;
  final bool _ownsBridge;
  final AppleMusicCredentials? Function()? credentialsProvider;

  final StreamController<PlaybackState> _stateController =
      StreamController<PlaybackState>.broadcast();

  PlaybackState _currentState = const PlaybackState(
    status: PlaybackStatus.stopped,
    clockSource: 'external_musickit',
  );
  int _activeEpoch = 0;
  TrackInfo? _activeTrack;
  AppleMusicCredentials? _lastConfiguredCredentials;
  double _savedVolume = 0.85;
  bool _externalHandoffPrepared = false;
  String? _preparedExternalTrackId;
  int _preparedExternalEpoch = 0;
  bool _disposed = false;

  AppleMusicPlaybackBackend({
    ExternalPlaybackBridge? bridge,
    this.credentialsProvider,
  }) : _ownsBridge = bridge == null,
       bridge = bridge ?? MethodChannelExternalPlaybackBridge() {
    this.bridge.setStateHandler(_onBridgeEvent);
  }

  bool get isExternalHandoffPrepared => _externalHandoffPrepared;
  String? get preparedExternalTrackId => _preparedExternalTrackId;
  int get preparedExternalEpoch => _preparedExternalEpoch;

  /// Marks external DRM handoff readiness without touching native Rust standby
  /// buffers or L1/L2 caches.
  Future<void> prepareExternalHandoff(
    TrackInfo track, {
    required int epoch,
  }) async {
    if (_disposed) return;
    _externalHandoffPrepared = true;
    _preparedExternalTrackId = track.id;
    _preparedExternalEpoch = epoch;
  }

  void clearExternalHandoff() {
    _externalHandoffPrepared = false;
    _preparedExternalTrackId = null;
    _preparedExternalEpoch = 0;
  }

  @override
  Future<void> prepareStandby(
    StreamSourceSpec spec,
    TrackInfo track, {
    required int epoch,
  }) async {
    // Apple Music / external DRM tracks MUST NEVER enter Native Standby Engine.
  }

  @override
  Future<bool> skipToStandby({required int epoch}) async => false;

  @override
  bool get isStandbyReady => false;

  @override
  Stream<PlaybackState> get stateStream => _stateController.stream;

  @override
  PlaybackState get currentState => _currentState;

  void _emit(PlaybackState next) {
    _currentState = next;
    if (!_disposed && !_stateController.isClosed) {
      _stateController.add(next);
    }
  }

  static PlaybackStatus _mapStatus(String status) {
    return switch (status.trim().toLowerCase()) {
      'loading' => PlaybackStatus.loading,
      'playing' => PlaybackStatus.playing,
      'paused' => PlaybackStatus.paused,
      'seeking' => PlaybackStatus.seeking,
      'buffering' => PlaybackStatus.buffering,
      'ended' => PlaybackStatus.ended,
      'error' => PlaybackStatus.error,
      _ => PlaybackStatus.stopped,
    };
  }

  void _onBridgeEvent(ExternalPlaybackEvent event) {
    if (_disposed) return;
    if (event.epoch > 0 && _activeEpoch > 0 && event.epoch != _activeEpoch) {
      return;
    }
    final status = _mapStatus(event.status);
    final track = (_activeTrack != null && event.durationMs > 0)
        ? _activeTrack!.copyWith(
            duration: Duration(milliseconds: event.durationMs),
          )
        : _activeTrack;
    if (track != null) {
      _activeTrack = track;
    }
    final pos = Duration(
      milliseconds: event.positionMs < 0 ? 0 : event.positionMs,
    );
    _emit(
      _currentState.copyWith(
        status: status,
        track: track,
        position: pos,
        playbackEpoch: _activeEpoch,
        lastError: status == PlaybackStatus.error ? event.error : null,
        clearLastError: status != PlaybackStatus.error,
        clockSource: 'external_musickit',
      ),
    );
  }

  @override
  Future<void> play(
    StreamSourceSpec spec,
    TrackInfo track, {
    required int epoch,
  }) async {
    if (_disposed) return;
    if (spec is! ExternalBackendSpec) {
      throw StateError(
        'AppleMusicPlaybackBackend only supports ExternalBackendSpec '
        '(received ${spec.kind})',
      );
    }
    if (epoch < _activeEpoch) return;

    _activeEpoch = epoch;
    _activeTrack = track;
    clearExternalHandoff();
    _emit(
      _currentState.copyWith(
        status: PlaybackStatus.loading,
        track: track,
        position: Duration.zero,
        playbackEpoch: _activeEpoch,
        clearLastError: true,
        clockSource: 'external_musickit',
      ),
    );

    final creds = credentialsProvider?.call();
    if (creds != null &&
        creds.developerToken.isNotEmpty &&
        creds.musicUserToken.isNotEmpty &&
        creds != _lastConfiguredCredentials) {
      await bridge.configure(
        developerToken: creds.developerToken,
        musicUserToken: creds.musicUserToken,
        storefront: creds.storefront,
      );
      if (_disposed || epoch != _activeEpoch) return;
      _lastConfiguredCredentials = creds;
    }

    await bridge.play(
      trackUri: spec.trackUri,
      previewUrl: spec.previewUrl,
      epoch: epoch,
      externalWebUrl: spec.externalWebUrl,
    );
  }

  @override
  Future<void> pause() async {
    if (_disposed) return;
    await bridge.pause(epoch: _activeEpoch);
    if (_disposed) return;
    _emit(
      _currentState.copyWith(
        status: PlaybackStatus.paused,
        playbackEpoch: _activeEpoch,
      ),
    );
  }

  @override
  Future<void> resume() async {
    if (_disposed) return;
    await bridge.resume(epoch: _activeEpoch);
    if (_disposed) return;
    _emit(
      _currentState.copyWith(
        status: PlaybackStatus.playing,
        playbackEpoch: _activeEpoch,
      ),
    );
  }

  @override
  Future<void> seek(Duration position, {required int epoch}) async {
    if (_disposed || epoch < _activeEpoch) return;
    _activeEpoch = epoch;
    final trackDur = _activeTrack?.duration;
    final maxDur = (trackDur != null && trackDur > Duration.zero)
        ? trackDur
        : const Duration(hours: 24);
    final clamped = position < Duration.zero
        ? Duration.zero
        : (position > maxDur ? maxDur : position);
    await bridge.seek(position: clamped, epoch: epoch);
    if (_disposed || epoch != _activeEpoch) return;
    _emit(
      _currentState.copyWith(position: clamped, playbackEpoch: _activeEpoch),
    );
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    final clamped = volume.clamp(0.0, 1.0);
    if (clamped > 0.0) {
      _savedVolume = clamped;
    }
    await bridge.setVolume(clamped);
    if (_disposed) return;
    _emit(
      _currentState.copyWith(
        volume: clamped,
        isMuted: clamped == 0.0,
        playbackEpoch: _activeEpoch,
      ),
    );
  }

  Future<void> toggleMute() async {
    if (_disposed) return;
    final nextMuted = !_currentState.isMuted;
    final targetVol = nextMuted
        ? 0.0
        : (_savedVolume > 0.0 ? _savedVolume : 0.85);
    await bridge.setVolume(targetVol);
    if (_disposed) return;
    _emit(
      _currentState.copyWith(
        volume: targetVol,
        isMuted: nextMuted,
        playbackEpoch: _activeEpoch,
      ),
    );
  }

  @override
  Future<void> stop({required int epoch}) async {
    if (_disposed || epoch < _activeEpoch) return;
    _activeEpoch = epoch;
    clearExternalHandoff();
    await bridge.stop(epoch: epoch);
    if (_disposed || epoch != _activeEpoch) return;
    _emit(
      _currentState.copyWith(
        status: PlaybackStatus.stopped,
        position: Duration.zero,
        playbackEpoch: _activeEpoch,
        clearLastError: true,
      ),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    clearExternalHandoff();
    bridge.setStateHandler(null);
    if (_ownsBridge) {
      bridge.dispose();
    }
    if (!_stateController.isClosed) {
      unawaited(_stateController.close());
    }
  }
}
