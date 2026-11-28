import 'package:flutter/foundation.dart';

import '../playback_state.dart';
import 'audio_quality_info.dart';
import 'json_reader.dart';
import 'lumina_error.dart';
import 'protocol_audio_device_info.dart';
import 'protocol_enums.dart';
import 'protocol_track_metadata.dart';

/// Canonical playback state matching Rust `core_types::PlaybackState`.
@immutable
class ProtocolPlaybackState {
  final PlaybackLifecycleState status;
  final int? _stateCode;
  final String? _stateName;
  final ProtocolTrackMetadata? track;
  final int positionMs;
  final int durationMs;
  final int timestampMs;
  final double volume;
  final bool isMuted;
  final RepeatMode repeatMode;
  final bool shuffle;
  final AudioQualityInfo? audioQuality;
  final ProtocolAudioDeviceInfo? activeDevice;
  final String? activeZoneId;
  final String clockSource;
  final int seekEpoch;
  final bool isSeeking;
  final bool dspBypassed;
  final bool strictBitPerfect;
  final bool deviceLost;
  final int swapGeneration;
  final int playbackEpoch;
  final LuminaError? error;
  final String? trackId;
  final String? currentTrackId;
  final String? lastError;
  final String? lastErrorCode;
  final String? lastErrorProvider;

  int get stateCode => _stateCode ?? status.code;
  String get stateName => _stateName ?? status.legacyStateName;

  const ProtocolPlaybackState({
    this.status = PlaybackLifecycleState.stopped,
    int? stateCode,
    String? stateName,
    this.track,
    this.positionMs = 0,
    this.durationMs = 0,
    this.timestampMs = 0,
    this.volume = 1.0,
    this.isMuted = false,
    this.repeatMode = RepeatMode.off,
    this.shuffle = false,
    this.audioQuality,
    this.activeDevice,
    this.activeZoneId,
    this.clockSource = 'system',
    this.seekEpoch = 0,
    this.isSeeking = false,
    this.dspBypassed = true,
    this.strictBitPerfect = false,
    this.deviceLost = false,
    this.swapGeneration = 0,
    this.playbackEpoch = 0,
    this.error,
    this.trackId,
    this.currentTrackId,
    this.lastError,
    this.lastErrorCode,
    this.lastErrorProvider,
    // ignore: prefer_initializing_formals
  })  : _stateCode = stateCode,
        // ignore: prefer_initializing_formals
        _stateName = stateName;

  static const ProtocolPlaybackState initial = ProtocolPlaybackState();

  factory ProtocolPlaybackState.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    final rawStatus = r.nonEmptyString('status');
    final rawCode = r.optionalInt('state_code');
    final status = rawStatus != null
        ? PlaybackLifecycleState.fromWireName(rawStatus)
        : (rawCode != null
              ? PlaybackLifecycleState.fromCode(rawCode)
              : PlaybackLifecycleState.stopped);
    final trackMap = r.optionalMap('track') ?? r.optionalMap('current_track');
    final qualityMap = r.optionalMap('audio_quality');
    final deviceMap = r.optionalMap('active_device');
    final errorMap = r.optionalMap('error');
    final parsedTrack =
        trackMap != null ? ProtocolTrackMetadata.fromJson(trackMap) : null;
    final parsedError = errorMap != null
        ? LuminaError.fromJson(errorMap)
        : LuminaError.tryParseJson(
            r.nonEmptyString('last_error') != null ? json : null,
          );
    final epoch = _maxEpoch(
      r.requiredInt('playback_epoch', fallback: 0),
      r.requiredInt('epoch', fallback: 0),
      r.requiredInt('play_request_id', fallback: 0),
    );
    final resolvedTrackId = r.nonEmptyString('track_id') ??
        r.nonEmptyString('current_track_id') ??
        parsedTrack?.trackId;
    return ProtocolPlaybackState(
      status: status,
      stateCode: rawCode ?? status.code,
      stateName: r.nonEmptyString('state_name') ?? status.legacyStateName,
      track: parsedTrack,
      positionMs: r.requiredInt('position_ms', fallback: 0),
      durationMs: r.requiredInt(
        'duration_ms',
        fallback: parsedTrack?.durationMs ?? 0,
      ),
      timestampMs: r.requiredInt('timestamp_ms', fallback: 0),
      volume: r.requiredDouble('volume', fallback: 1.0).clamp(0.0, 1.0),
      isMuted: r.requiredBool('is_muted', fallback: false),
      repeatMode: RepeatMode.fromWireName(r.optionalString('repeat_mode')),
      shuffle: r.requiredBool('shuffle', fallback: false),
      audioQuality: qualityMap != null
          ? AudioQualityInfo.fromJson(qualityMap)
          : parsedTrack?.audioQuality,
      activeDevice: deviceMap != null
          ? ProtocolAudioDeviceInfo.fromJson(deviceMap)
          : null,
      activeZoneId: r.nonEmptyString('active_zone_id'),
      clockSource: r.requiredString('clock_source', fallback: 'system'),
      seekEpoch: r.requiredInt('seek_epoch', fallback: 0),
      isSeeking: r.requiredBool('is_seeking', fallback: false),
      dspBypassed: r.requiredBool('dsp_bypassed', fallback: true),
      strictBitPerfect: r.requiredBool('strict_bit_perfect', fallback: false),
      deviceLost: r.requiredBool('device_lost', fallback: false),
      swapGeneration: r.requiredInt(
        'swap_generation',
        fallback: r.requiredInt('swapGeneration', fallback: 0),
      ),
      playbackEpoch: epoch,
      error: parsedError,
      trackId: resolvedTrackId,
      currentTrackId: r.nonEmptyString('current_track_id') ?? resolvedTrackId,
      lastError: r.nonEmptyString('last_error') ?? parsedError?.message,
      lastErrorCode:
          r.nonEmptyString('last_error_code') ?? parsedError?.code.wireName,
      lastErrorProvider:
          r.nonEmptyString('last_error_provider') ?? parsedError?.provider,
    );
  }

  static int _maxEpoch(int a, int b, int c) {
    var best = a;
    if (b > best) best = b;
    if (c > best) best = c;
    return best;
  }

  factory ProtocolPlaybackState.fromLegacy(
    PlaybackState legacy, {
    int? timestampMs,
    bool dspBypassed = true,
    bool strictBitPerfect = false,
  }) {
    final lifecycle = PlaybackLifecycleState.fromPlaybackStatus(legacy.status);
    final protoTrack = legacy.track != null
        ? ProtocolTrackMetadata.fromTrackInfo(legacy.track!)
        : null;
    return ProtocolPlaybackState(
      status: lifecycle,
      stateCode: lifecycle.code,
      stateName: lifecycle.legacyStateName,
      track: protoTrack,
      positionMs: legacy.position.inMilliseconds,
      durationMs: legacy.track?.duration.inMilliseconds ?? 0,
      timestampMs: timestampMs ?? legacy.timestampMs,
      volume: legacy.volume,
      isMuted: legacy.isMuted,
      repeatMode: legacy.repeatMode,
      shuffle: legacy.shuffle,
      audioQuality: legacy.audioQuality ?? protoTrack?.audioQuality,
      activeZoneId: legacy.activeZoneId,
      clockSource: legacy.clockSource,
      seekEpoch: legacy.seekEpoch,
      isSeeking: legacy.isSeeking,
      dspBypassed: dspBypassed,
      strictBitPerfect: strictBitPerfect,
      deviceLost: legacy.deviceLost,
      swapGeneration: legacy.swapGeneration,
      playbackEpoch: legacy.playbackEpoch,
      error: legacy.error,
      trackId: protoTrack?.trackId,
      currentTrackId: protoTrack?.trackId,
      lastError: legacy.lastError ?? legacy.error?.message,
      lastErrorCode: legacy.error?.code.wireName,
      lastErrorProvider: legacy.error?.provider,
    );
  }

  PlaybackState toLegacy({TrackInfo? fallbackTrack}) {
    final resolvedTrack = track?.toTrackInfo() ?? fallbackTrack;
    final trackWithDuration = (resolvedTrack != null &&
            durationMs > 0 &&
            resolvedTrack.duration.inMilliseconds != durationMs)
        ? resolvedTrack.copyWith(duration: Duration(milliseconds: durationMs))
        : resolvedTrack;
    return PlaybackState(
      status: status.toPlaybackStatus(),
      track: trackWithDuration,
      position: Duration(milliseconds: positionMs < 0 ? 0 : positionMs),
      volume: volume,
      isMuted: isMuted,
      seekEpoch: seekEpoch,
      isSeeking: isSeeking,
      lastError: lastError ?? error?.message,
      deviceLost: deviceLost,
      clockSource: clockSource,
      swapGeneration: swapGeneration,
      playbackEpoch: playbackEpoch,
      timestampMs: timestampMs,
      repeatMode: repeatMode,
      shuffle: shuffle,
      audioQuality: audioQuality,
      activeDeviceId: activeDevice?.id,
      activeZoneId: activeZoneId,
      error: error,
    );
  }

  Map<String, Object?> toJson() {
    final effectiveTrackId = trackId ?? track?.trackId;
    final effectiveCurrentTrackId = currentTrackId ?? effectiveTrackId;
    final effectiveLastError = lastError ?? error?.message;
    final effectiveLastErrorCode = lastErrorCode ?? error?.code.wireName;
    final effectiveLastErrorProvider = lastErrorProvider ?? error?.provider;
    return <String, Object?>{
      'status': status.wireName,
      'state_code': stateCode,
      'state_name': stateName,
      if (track != null) 'track': track!.toJson(),
      'position_ms': positionMs,
      'duration_ms': durationMs,
      'timestamp_ms': timestampMs,
      'volume': volume,
      'is_muted': isMuted,
      'repeat_mode': repeatMode.wireName,
      'shuffle': shuffle,
      if (audioQuality != null) 'audio_quality': audioQuality!.toJson(),
      if (activeDevice != null) 'active_device': activeDevice!.toJson(),
      if (activeZoneId != null) 'active_zone_id': activeZoneId,
      'clock_source': clockSource,
      'seek_epoch': seekEpoch,
      'is_seeking': isSeeking,
      'dsp_bypassed': dspBypassed,
      'strict_bit_perfect': strictBitPerfect,
      'device_lost': deviceLost,
      'swap_generation': swapGeneration,
      'playback_epoch': playbackEpoch,
      if (error != null) 'error': error!.toJson(),
      'track_id': ?effectiveTrackId,
      'current_track_id': ?effectiveCurrentTrackId,
      'last_error': ?effectiveLastError,
      'last_error_code': ?effectiveLastErrorCode,
      'last_error_provider': ?effectiveLastErrorProvider,
    };
  }

  ProtocolPlaybackState copyWith({
    PlaybackLifecycleState? status,
    int? stateCode,
    String? stateName,
    ProtocolTrackMetadata? track,
    bool clearTrack = false,
    int? positionMs,
    int? durationMs,
    int? timestampMs,
    double? volume,
    bool? isMuted,
    RepeatMode? repeatMode,
    bool? shuffle,
    AudioQualityInfo? audioQuality,
    bool clearAudioQuality = false,
    ProtocolAudioDeviceInfo? activeDevice,
    bool clearActiveDevice = false,
    String? activeZoneId,
    bool clearActiveZoneId = false,
    String? clockSource,
    int? seekEpoch,
    bool? isSeeking,
    bool? dspBypassed,
    bool? strictBitPerfect,
    bool? deviceLost,
    int? swapGeneration,
    int? playbackEpoch,
    LuminaError? error,
    bool clearError = false,
    String? trackId,
    String? currentTrackId,
    String? lastError,
    String? lastErrorCode,
    String? lastErrorProvider,
  }) {
    final nextStatus = status ?? this.status;
    final nextTrack = clearTrack ? null : (track ?? this.track);
    final nextError = clearError ? null : (error ?? this.error);
    return ProtocolPlaybackState(
      status: nextStatus,
      stateCode: stateCode ?? nextStatus.code,
      stateName: stateName ?? nextStatus.legacyStateName,
      track: nextTrack,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      timestampMs: timestampMs ?? this.timestampMs,
      volume: volume ?? this.volume,
      isMuted: isMuted ?? this.isMuted,
      repeatMode: repeatMode ?? this.repeatMode,
      shuffle: shuffle ?? this.shuffle,
      audioQuality:
          clearAudioQuality ? null : (audioQuality ?? this.audioQuality),
      activeDevice:
          clearActiveDevice ? null : (activeDevice ?? this.activeDevice),
      activeZoneId:
          clearActiveZoneId ? null : (activeZoneId ?? this.activeZoneId),
      clockSource: clockSource ?? this.clockSource,
      seekEpoch: seekEpoch ?? this.seekEpoch,
      isSeeking: isSeeking ?? this.isSeeking,
      dspBypassed: dspBypassed ?? this.dspBypassed,
      strictBitPerfect: strictBitPerfect ?? this.strictBitPerfect,
      deviceLost: deviceLost ?? this.deviceLost,
      swapGeneration: swapGeneration ?? this.swapGeneration,
      playbackEpoch: playbackEpoch ?? this.playbackEpoch,
      error: nextError,
      trackId: clearTrack ? null : (trackId ?? nextTrack?.trackId ?? this.trackId),
      currentTrackId: clearTrack
          ? null
          : (currentTrackId ?? nextTrack?.trackId ?? this.currentTrackId),
      lastError: clearError ? null : (lastError ?? nextError?.message ?? this.lastError),
      lastErrorCode: clearError
          ? null
          : (lastErrorCode ?? nextError?.code.wireName ?? this.lastErrorCode),
      lastErrorProvider: clearError
          ? null
          : (lastErrorProvider ?? nextError?.provider ?? this.lastErrorProvider),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ProtocolPlaybackState &&
        other.status == status &&
        other.stateCode == stateCode &&
        other.stateName == stateName &&
        other.track == track &&
        other.positionMs == positionMs &&
        other.durationMs == durationMs &&
        other.timestampMs == timestampMs &&
        other.volume == volume &&
        other.isMuted == isMuted &&
        other.repeatMode == repeatMode &&
        other.shuffle == shuffle &&
        other.audioQuality == audioQuality &&
        other.activeDevice == activeDevice &&
        other.activeZoneId == activeZoneId &&
        other.clockSource == clockSource &&
        other.seekEpoch == seekEpoch &&
        other.isSeeking == isSeeking &&
        other.dspBypassed == dspBypassed &&
        other.strictBitPerfect == strictBitPerfect &&
        other.deviceLost == deviceLost &&
        other.swapGeneration == swapGeneration &&
        other.playbackEpoch == playbackEpoch &&
        other.error == error &&
        other.trackId == trackId &&
        other.currentTrackId == currentTrackId &&
        other.lastError == lastError &&
        other.lastErrorCode == lastErrorCode &&
        other.lastErrorProvider == lastErrorProvider;
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
        status,
        stateCode,
        stateName,
        track,
        positionMs,
        durationMs,
        timestampMs,
        volume,
        isMuted,
        repeatMode,
        shuffle,
        audioQuality,
        activeDevice,
        activeZoneId,
        clockSource,
        seekEpoch,
        isSeeking,
        dspBypassed,
        strictBitPerfect,
        deviceLost,
        swapGeneration,
        playbackEpoch,
        error,
        trackId,
        currentTrackId,
        lastError,
        lastErrorCode,
        lastErrorProvider,
      ]);
}
