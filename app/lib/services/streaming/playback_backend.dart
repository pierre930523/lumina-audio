import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../models/playback_state.dart';
import '../../models/stream_source_spec.dart';
import '../audio_service.dart';

/// Per-deck lifecycle state matching Rust `core_types::DeckState`.
enum DeckState {
  idle,
  resolving,
  prebuffering,
  standbyReady,
  playing,
  seeking,
  recovering403,
  draining;

  String get wireValue => switch (this) {
    DeckState.idle => 'IDLE',
    DeckState.resolving => 'RESOLVING',
    DeckState.prebuffering => 'PREBUFFERING',
    DeckState.standbyReady => 'STANDBY_READY',
    DeckState.playing => 'PLAYING',
    DeckState.seeking => 'SEEKING',
    DeckState.recovering403 => 'RECOVERING_403',
    DeckState.draining => 'DRAINING',
  };
}

/// Parses wire strings (e.g. `"STANDBY_READY"`, `"standbyReady"`, `"0"`..`"7"`)
/// into [DeckState], falling back to [DeckState.idle].
DeckState parseDeckState(String? raw) {
  if (raw == null) return DeckState.idle;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return DeckState.idle;
  final numeric = int.tryParse(trimmed);
  if (numeric != null && numeric >= 0 && numeric < DeckState.values.length) {
    return DeckState.values[numeric];
  }
  final normalized = trimmed.toLowerCase().replaceAll('_', '').replaceAll('-', '');
  return switch (normalized) {
    'idle' => DeckState.idle,
    'resolving' => DeckState.resolving,
    'prebuffering' => DeckState.prebuffering,
    'standbyready' => DeckState.standbyReady,
    'playing' => DeckState.playing,
    'seeking' => DeckState.seeking,
    'recovering403' => DeckState.recovering403,
    'draining' => DeckState.draining,
    _ => DeckState.idle,
  };
}

/// Dual-Deck snapshot parsed from Rust `lumina_playback_get_state_json()`.
@immutable
class DualDeckStatus {
  final String activeDeck;
  final DeckState deckAState;
  final DeckState deckBState;
  final int standbyBufferedMs;
  final int gaplessTransitions;
  final int manualZeroLatencySwitches;
  final int formatMismatchRecoveries;
  final StreamKey? deckAKey;
  final StreamKey? deckBKey;

  const DualDeckStatus({
    this.activeDeck = 'deck_a',
    this.deckAState = DeckState.idle,
    this.deckBState = DeckState.idle,
    this.standbyBufferedMs = 0,
    this.gaplessTransitions = 0,
    this.manualZeroLatencySwitches = 0,
    this.formatMismatchRecoveries = 0,
    this.deckAKey,
    this.deckBKey,
  });

  static bool _isDeckB(String deck) {
    final normalized = deck.trim().toLowerCase();
    return normalized == 'deck_b' || normalized == 'b' || normalized == '1';
  }

  static String _parseActiveDeck(dynamic raw) {
    if (raw is num) {
      return raw.toInt() == 1 ? 'deck_b' : 'deck_a';
    }
    final str = raw?.toString().trim().toLowerCase() ?? '';
    return _isDeckB(str) ? 'deck_b' : 'deck_a';
  }

  static DeckState _parseStateField(dynamic raw) {
    if (raw is num) {
      final idx = raw.toInt();
      if (idx >= 0 && idx < DeckState.values.length) {
        return DeckState.values[idx];
      }
      return DeckState.idle;
    }
    return parseDeckState(raw?.toString());
  }

  static StreamKey? _parseStreamKey(dynamic raw) {
    if (raw is Map) {
      return StreamKey.fromJson(Map<String, dynamic>.from(raw));
    }
    return null;
  }

  factory DualDeckStatus.fromJson(Map<String, dynamic> json) {
    final nested = json['dual_deck'];
    final source = nested is Map
        ? Map<String, dynamic>.from(nested)
        : json;
    return DualDeckStatus(
      activeDeck: _parseActiveDeck(source['active_deck']),
      deckAState: _parseStateField(source['deck_a_state']),
      deckBState: _parseStateField(source['deck_b_state']),
      standbyBufferedMs: (source['standby_buffered_ms'] as num?)?.toInt() ?? 0,
      gaplessTransitions:
          (source['gapless_transitions'] as num?)?.toInt() ?? 0,
      manualZeroLatencySwitches:
          (source['manual_zero_latency_switches'] as num?)?.toInt() ?? 0,
      formatMismatchRecoveries:
          (source['format_mismatch_recoveries'] as num?)?.toInt() ?? 0,
      deckAKey: _parseStreamKey(source['deck_a_key']),
      deckBKey: _parseStreamKey(source['deck_b_key']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'active_deck': activeDeck,
    'deck_a_state': deckAState.wireValue,
    'deck_b_state': deckBState.wireValue,
    'standby_buffered_ms': standbyBufferedMs,
    'gapless_transitions': gaplessTransitions,
    'manual_zero_latency_switches': manualZeroLatencySwitches,
    'format_mismatch_recoveries': formatMismatchRecoveries,
    if (deckAKey != null) 'deck_a_key': deckAKey!.toJson(),
    if (deckBKey != null) 'deck_b_key': deckBKey!.toJson(),
  };

  DeckState get activeDeckState =>
      _isDeckB(activeDeck) ? deckBState : deckAState;

  DeckState get standbyDeckState =>
      _isDeckB(activeDeck) ? deckAState : deckBState;

  bool get isStandbyReady => standbyDeckState == DeckState.standbyReady;

  DualDeckStatus copyWith({
    String? activeDeck,
    DeckState? deckAState,
    DeckState? deckBState,
    int? standbyBufferedMs,
    int? gaplessTransitions,
    int? manualZeroLatencySwitches,
    int? formatMismatchRecoveries,
    StreamKey? deckAKey,
    StreamKey? deckBKey,
  }) {
    return DualDeckStatus(
      activeDeck: activeDeck ?? this.activeDeck,
      deckAState: deckAState ?? this.deckAState,
      deckBState: deckBState ?? this.deckBState,
      standbyBufferedMs: standbyBufferedMs ?? this.standbyBufferedMs,
      gaplessTransitions: gaplessTransitions ?? this.gaplessTransitions,
      manualZeroLatencySwitches:
          manualZeroLatencySwitches ?? this.manualZeroLatencySwitches,
      formatMismatchRecoveries:
          formatMismatchRecoveries ?? this.formatMismatchRecoveries,
      deckAKey: deckAKey ?? this.deckAKey,
      deckBKey: deckBKey ?? this.deckBKey,
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is DualDeckStatus &&
            other.activeDeck == activeDeck &&
            other.deckAState == deckAState &&
            other.deckBState == deckBState &&
            other.standbyBufferedMs == standbyBufferedMs &&
            other.gaplessTransitions == gaplessTransitions &&
            other.manualZeroLatencySwitches == manualZeroLatencySwitches &&
            other.formatMismatchRecoveries == formatMismatchRecoveries &&
            other.deckAKey == deckAKey &&
            other.deckBKey == deckBKey);
  }

  @override
  int get hashCode => Object.hash(
    activeDeck,
    deckAState,
    deckBState,
    standbyBufferedMs,
    gaplessTransitions,
    manualZeroLatencySwitches,
    formatMismatchRecoveries,
    deckAKey,
    deckBKey,
  );

  @override
  String toString() =>
      'DualDeckStatus(active=$activeDeck, a=${deckAState.wireValue}, b=${deckBState.wireValue}, standbyMs=$standbyBufferedMs)';
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

/// Native Rust audio engine backend backed by [AudioService].
class NativePlaybackBackend extends PlaybackBackend
    implements DualDeckPlaybackBackend {
  final AudioService audioService;

  NativePlaybackBackend(this.audioService);

  @override
  Stream<PlaybackState> get stateStream => audioService.stateStream;

  @override
  PlaybackState get currentState => audioService.currentState;

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
    return audioService.playStreamSpecAsync(track, spec, epoch: epoch);
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
  Future<void> seek(Duration position, {required int epoch}) =>
      audioService.seek(position);

  @override
  Future<void> setVolume(double volume) => audioService.setVolume(volume);

  @override
  Future<void> stop({required int epoch}) async {
    await audioService.cancelPendingPlaybackAtEpoch(epoch);
    await audioService.stop();
  }

  @override
  void dispose() {
    // AudioService lifetime is managed by its owner (HomeScreen or test).
  }
}

/// Credentials passed to `lumina/external_playback` `configure`.
@immutable
class AppleMusicCredentials {
  final String developerToken;
  final String musicUserToken;
  final String storefront;

  const AppleMusicCredentials({
    required this.developerToken,
    required this.musicUserToken,
    this.storefront = 'us',
  });

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is AppleMusicCredentials &&
            other.developerToken == developerToken &&
            other.musicUserToken == musicUserToken &&
            other.storefront == storefront);
  }

  @override
  int get hashCode => Object.hash(developerToken, musicUserToken, storefront);
}

/// State update payload emitted from the host external playback bridge.
@immutable
class ExternalPlaybackEvent {
  final int epoch;
  final String status;
  final int positionMs;
  final int durationMs;
  final String? error;

  const ExternalPlaybackEvent({
    required this.epoch,
    required this.status,
    this.positionMs = 0,
    this.durationMs = 0,
    this.error,
  });

  factory ExternalPlaybackEvent.fromMap(Map<Object?, Object?> map) {
    return ExternalPlaybackEvent(
      epoch: (map['epoch'] as num?)?.toInt() ?? 0,
      status: map['status']?.toString().trim().toLowerCase() ?? 'stopped',
      positionMs: (map['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
      error: map['error']?.toString(),
    );
  }
}

/// Injectable platform bridge interface for external DRM playback hosts.
abstract interface class ExternalPlaybackBridge {
  void setStateHandler(void Function(ExternalPlaybackEvent event)? handler);
  Future<bool> isAvailable();
  Future<void> configure({
    required String developerToken,
    required String musicUserToken,
    String storefront = 'us',
  });
  Future<void> play({
    required String trackUri,
    String? previewUrl,
    required int epoch,
    String? externalWebUrl,
  });
  Future<void> pause({required int epoch});
  Future<void> resume({required int epoch});
  Future<void> seek({required Duration position, required int epoch});
  Future<void> setVolume(double volume);
  Future<void> stop({required int epoch});
  void dispose();
}

/// Default `MethodChannel('lumina/external_playback')` bridge communicating
/// with Win32 `ExternalMusicHost`. Gracefully handles [MissingPluginException]
/// when running headless or in tests.
class MethodChannelExternalPlaybackBridge implements ExternalPlaybackBridge {
  static const String channelName = 'lumina/external_playback';

  final MethodChannel _channel;
  void Function(ExternalPlaybackEvent event)? _stateHandler;
  bool _disposed = false;

  MethodChannelExternalPlaybackBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_handleHostCall);
  }

  Future<dynamic> _handleHostCall(MethodCall call) async {
    if (_disposed) return null;
    if (call.method == 'onState' && call.arguments is Map) {
      final event = ExternalPlaybackEvent.fromMap(
        call.arguments as Map<Object?, Object?>,
      );
      _stateHandler?.call(event);
    }
    return null;
  }

  @override
  void setStateHandler(void Function(ExternalPlaybackEvent event)? handler) {
    _stateHandler = handler;
  }

  @override
  Future<bool> isAvailable() async {
    if (_disposed) return false;
    try {
      final result = await _channel.invokeMethod<bool>('isAvailable');
      return result == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> configure({
    required String developerToken,
    required String musicUserToken,
    String storefront = 'us',
  }) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>('configure', <String, dynamic>{
        'developerToken': developerToken,
        'musicUserToken': musicUserToken,
        'storefront': storefront,
      });
    } on MissingPluginException {
      // Headless / unsupported platform: fail gracefully.
    } on PlatformException {
      // Ignore host config failures; surfaced if play is invoked.
    }
  }

  @override
  Future<void> play({
    required String trackUri,
    String? previewUrl,
    required int epoch,
    String? externalWebUrl,
  }) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>('play', <String, dynamic>{
        'trackUri': trackUri,
        'previewUrl': ?previewUrl,
        'epoch': epoch,
        'externalWebUrl': ?externalWebUrl,
      });
    } on MissingPluginException {
      _stateHandler?.call(
        ExternalPlaybackEvent(
          epoch: epoch,
          status: 'error',
          error: 'Apple Music 外部播放宿主在此環境尚未就緒',
        ),
      );
    } on PlatformException catch (e) {
      _stateHandler?.call(
        ExternalPlaybackEvent(
          epoch: epoch,
          status: 'error',
          error: e.message ?? 'Apple Music 外部播放失敗',
        ),
      );
    }
  }

  @override
  Future<void> pause({required int epoch}) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>('pause', <String, dynamic>{
        'epoch': epoch,
      });
    } on MissingPluginException {
      // Headless / unsupported platform.
    } on PlatformException {
      // Ignore transient host errors on pause.
    }
  }

  @override
  Future<void> resume({required int epoch}) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>('resume', <String, dynamic>{
        'epoch': epoch,
      });
    } on MissingPluginException {
      // Headless / unsupported platform.
    } on PlatformException {
      // Ignore transient host errors on resume.
    }
  }

  @override
  Future<void> seek({required Duration position, required int epoch}) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>('seek', <String, dynamic>{
        'positionMs': position.inMilliseconds < 0 ? 0 : position.inMilliseconds,
        'epoch': epoch,
      });
    } on MissingPluginException {
      // Headless / unsupported platform.
    } on PlatformException {
      // Ignore transient host errors on seek.
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>('setVolume', <String, dynamic>{
        'volume': volume.clamp(0.0, 1.0),
      });
    } on MissingPluginException {
      // Headless / unsupported platform.
    } on PlatformException {
      // Ignore transient host errors on setVolume.
    }
  }

  @override
  Future<void> stop({required int epoch}) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>('stop', <String, dynamic>{
        'epoch': epoch,
      });
    } on MissingPluginException {
      // Headless / unsupported platform.
    } on PlatformException {
      // Ignore transient host errors on stop.
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stateHandler = null;
    _channel.setMethodCallHandler(null);
  }
}

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
    _emit(_currentState.copyWith(status: PlaybackStatus.paused));
  }

  @override
  Future<void> resume() async {
    if (_disposed) return;
    await bridge.resume(epoch: _activeEpoch);
    if (_disposed) return;
    _emit(_currentState.copyWith(status: PlaybackStatus.playing));
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
    _emit(_currentState.copyWith(position: clamped));
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
    _emit(_currentState.copyWith(volume: clamped, isMuted: clamped == 0.0));
  }

  Future<void> toggleMute() async {
    if (_disposed) return;
    final nextMuted = !_currentState.isMuted;
    final targetVol = nextMuted
        ? 0.0
        : (_savedVolume > 0.0 ? _savedVolume : 0.85);
    await bridge.setVolume(targetVol);
    if (_disposed) return;
    _emit(_currentState.copyWith(volume: targetVol, isMuted: nextMuted));
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
