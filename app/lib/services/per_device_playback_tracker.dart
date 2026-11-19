import '../models/playback_state.dart';
import '../models/studio_models.dart';

/// Shared R4 helper tracking independent playback states per output device and per zone.
class PerDevicePlaybackTracker {
  String? _activeDeviceId;
  final Map<String, PlaybackState> _deviceStates = {};
  final Map<String, int> _deviceQueueIndices = {};
  final Map<String, PlaybackState> _zoneStates = {};

  String? get activeDeviceId => _activeDeviceId;

  /// Ensures [activeDeviceId] tracks the default device once devices are known.
  void syncActiveFromDevices(List<AudioDeviceInfo> devices) {
    if (_activeDeviceId != null &&
        devices.any((d) => d.id == _activeDeviceId)) {
      return;
    }
    final chosen =
        devices.where((d) => d.isDefault).firstOrNull ?? devices.firstOrNull;
    if (chosen != null) {
      _activeDeviceId = chosen.id;
    }
  }

  /// Ensures every zone has an initial [PlaybackState] carrying its configured volume.
  void syncZones(List<AudioZoneInfo> zones, {PlaybackState? activeLocalState}) {
    for (final z in zones) {
      final existing = _zoneStates[z.id];
      if (existing == null) {
        _zoneStates[z.id] = PlaybackState(
          status: PlaybackStatus.stopped,
          volume: z.volume.clamp(0.0, 1.0),
        );
      } else {
        _zoneStates[z.id] = existing.copyWith(volume: z.volume.clamp(0.0, 1.0));
      }
      if (z.id == 'zone-local' && activeLocalState != null) {
        _zoneStates[z.id] = activeLocalState.copyWith(
          volume: z.volume.clamp(0.0, 1.0),
        );
      }
    }
  }

  Map<String, PlaybackState> snapshotDevices(PlaybackState currentState) {
    final map = Map<String, PlaybackState>.from(_deviceStates);
    final active = _activeDeviceId;
    if (active != null) {
      map[active] = currentState;
    }
    return Map.unmodifiable(map);
  }

  Map<String, PlaybackState> snapshotZones({PlaybackState? activeLocalState}) {
    final map = Map<String, PlaybackState>.from(_zoneStates);
    if (activeLocalState != null && map.containsKey('zone-local')) {
      final localVol = map['zone-local']!.volume;
      map['zone-local'] = activeLocalState.copyWith(volume: localVol);
    }
    return Map.unmodifiable(map);
  }

  /// Saves current active device state (pausing if playing) and restores target state.
  ({PlaybackState restoredState, int queueIndex, bool switched}) switchDevice({
    required String? nextDeviceId,
    required PlaybackState currentState,
    required int currentQueueIndex,
  }) {
    if (nextDeviceId == null || nextDeviceId.isEmpty) {
      return (
        restoredState: currentState,
        queueIndex: currentQueueIndex,
        switched: false,
      );
    }
    final prev = _activeDeviceId;
    if (prev == nextDeviceId) {
      return (
        restoredState: currentState,
        queueIndex: currentQueueIndex,
        switched: false,
      );
    }
    if (prev != null) {
      _deviceStates[prev] = currentState.status == PlaybackStatus.playing
          ? currentState.copyWith(status: PlaybackStatus.paused)
          : currentState;
      _deviceQueueIndices[prev] = currentQueueIndex;
    }
    _activeDeviceId = nextDeviceId;
    final restored =
        _deviceStates[nextDeviceId] ??
        const PlaybackState(status: PlaybackStatus.stopped);
    final idx = _deviceQueueIndices[nextDeviceId] ?? 0;
    return (restoredState: restored, queueIndex: idx, switched: true);
  }

  void updateActiveDeviceState(PlaybackState state, {int? queueIndex}) {
    final active = _activeDeviceId;
    if (active == null) return;
    _deviceStates[active] = state;
    if (queueIndex != null) {
      _deviceQueueIndices[active] = queueIndex;
    }
  }

  void setDeviceVolume(String deviceId, double volume) {
    final clamped = volume.clamp(0.0, 1.0);
    final existing =
        _deviceStates[deviceId] ??
        const PlaybackState(status: PlaybackStatus.stopped);
    _deviceStates[deviceId] = existing.copyWith(
      volume: clamped,
      isMuted: clamped == 0.0,
    );
  }

  void setZoneVolume(String zoneId, double volume) {
    final clamped = volume.clamp(0.0, 1.0);
    final existing =
        _zoneStates[zoneId] ??
        const PlaybackState(status: PlaybackStatus.stopped);
    _zoneStates[zoneId] = existing.copyWith(
      volume: clamped,
      isMuted: clamped == 0.0,
    );
  }

  void updateZoneAction(String zoneId, String action, {TrackInfo? track}) {
    final existing =
        _zoneStates[zoneId] ??
        const PlaybackState(status: PlaybackStatus.stopped);
    final nextStatus = switch (action.toLowerCase()) {
      'play' => PlaybackStatus.playing,
      'pause' => PlaybackStatus.paused,
      'stop' => PlaybackStatus.stopped,
      _ => existing.status,
    };
    _zoneStates[zoneId] = existing.copyWith(
      status: nextStatus,
      track: track ?? existing.track,
      position: nextStatus == PlaybackStatus.stopped
          ? Duration.zero
          : existing.position,
    );
  }
}
