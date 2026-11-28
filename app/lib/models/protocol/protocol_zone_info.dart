import 'package:flutter/foundation.dart';

import '../studio_models.dart';
import 'json_reader.dart';
import 'protocol_enums.dart';

/// Canonical zone info matching Rust `core_types::ZoneInfo` (16 existing fields + 3 new).
@immutable
class ProtocolZoneInfo {
  final String id;
  final String name;
  final String backend;
  final String? deviceId;
  final String? endpointUrl;
  final String? controlUrl;
  final String? renderingUrl;
  final String? clockSyncAddr;
  final String? groupId;
  final bool exclusiveMode;
  final bool dspBypass;
  final double volume;
  final bool isActive;
  final int clockOffsetUs;
  final int rttUs;
  final double driftPpm;
  final bool isMuted;
  final String? activeDeviceId;
  final PlaybackLifecycleState? playbackStatus;

  const ProtocolZoneInfo({
    required this.id,
    required this.name,
    required this.backend,
    this.deviceId,
    this.endpointUrl,
    this.controlUrl,
    this.renderingUrl,
    this.clockSyncAddr,
    this.groupId,
    this.exclusiveMode = false,
    this.dspBypass = false,
    this.volume = 1.0,
    this.isActive = false,
    this.clockOffsetUs = 0,
    this.rttUs = 0,
    this.driftPpm = 0.0,
    this.isMuted = false,
    this.activeDeviceId,
    this.playbackStatus,
  });

  factory ProtocolZoneInfo.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    final rawStatus = r.nonEmptyString('playback_status');
    return ProtocolZoneInfo(
      id: r.requiredString('id'),
      name: r.requiredString('name'),
      backend: r.requiredString('backend', fallback: 'windows_wasapi_shared'),
      deviceId: r.nonEmptyString('device_id'),
      endpointUrl: r.nonEmptyString('endpoint_url'),
      controlUrl: r.nonEmptyString('control_url'),
      renderingUrl: r.nonEmptyString('rendering_url'),
      clockSyncAddr: r.nonEmptyString('clock_sync_addr'),
      groupId: r.nonEmptyString('group_id'),
      exclusiveMode: r.requiredBool('exclusive_mode', fallback: false),
      dspBypass: r.requiredBool('dsp_bypass', fallback: false),
      volume: r.requiredDouble('volume', fallback: 1.0),
      isActive: r.requiredBool('is_active', fallback: false),
      clockOffsetUs: r.requiredInt('clock_offset_us', fallback: 0),
      rttUs: r.requiredInt('rtt_us', fallback: 0),
      driftPpm: r.requiredDouble('drift_ppm', fallback: 0.0),
      isMuted: r.requiredBool('is_muted', fallback: false),
      activeDeviceId: r.nonEmptyString('active_device_id'),
      playbackStatus: rawStatus != null
          ? PlaybackLifecycleState.fromWireName(rawStatus)
          : null,
    );
  }

  factory ProtocolZoneInfo.fromLegacy(AudioZoneInfo legacy) {
    return ProtocolZoneInfo(
      id: legacy.id,
      name: legacy.name,
      backend: legacy.backend,
      groupId: legacy.groupId,
      volume: legacy.volume,
      isActive: legacy.isActive,
      clockOffsetUs: legacy.clockOffsetUs,
      rttUs: legacy.rttUs,
      driftPpm: legacy.driftPpm,
    );
  }

  AudioZoneInfo toLegacy() {
    return AudioZoneInfo(
      id: id,
      name: name,
      backend: backend,
      groupId: groupId,
      volume: volume,
      isActive: isActive,
      clockOffsetUs: clockOffsetUs,
      rttUs: rttUs,
      driftPpm: driftPpm,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'backend': backend,
      if (deviceId != null) 'device_id': deviceId,
      if (endpointUrl != null) 'endpoint_url': endpointUrl,
      if (controlUrl != null) 'control_url': controlUrl,
      if (renderingUrl != null) 'rendering_url': renderingUrl,
      if (clockSyncAddr != null) 'clock_sync_addr': clockSyncAddr,
      if (groupId != null) 'group_id': groupId,
      'exclusive_mode': exclusiveMode,
      'dsp_bypass': dspBypass,
      'volume': volume,
      'is_active': isActive,
      'clock_offset_us': clockOffsetUs,
      'rtt_us': rttUs,
      'drift_ppm': driftPpm,
      'is_muted': isMuted,
      if (activeDeviceId != null) 'active_device_id': activeDeviceId,
      if (playbackStatus != null) 'playback_status': playbackStatus!.wireName,
    };
  }

  ProtocolZoneInfo copyWith({
    String? id,
    String? name,
    String? backend,
    String? deviceId,
    String? endpointUrl,
    String? controlUrl,
    String? renderingUrl,
    String? clockSyncAddr,
    String? groupId,
    bool? exclusiveMode,
    bool? dspBypass,
    double? volume,
    bool? isActive,
    int? clockOffsetUs,
    int? rttUs,
    double? driftPpm,
    bool? isMuted,
    String? activeDeviceId,
    PlaybackLifecycleState? playbackStatus,
  }) {
    return ProtocolZoneInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      backend: backend ?? this.backend,
      deviceId: deviceId ?? this.deviceId,
      endpointUrl: endpointUrl ?? this.endpointUrl,
      controlUrl: controlUrl ?? this.controlUrl,
      renderingUrl: renderingUrl ?? this.renderingUrl,
      clockSyncAddr: clockSyncAddr ?? this.clockSyncAddr,
      groupId: groupId ?? this.groupId,
      exclusiveMode: exclusiveMode ?? this.exclusiveMode,
      dspBypass: dspBypass ?? this.dspBypass,
      volume: volume ?? this.volume,
      isActive: isActive ?? this.isActive,
      clockOffsetUs: clockOffsetUs ?? this.clockOffsetUs,
      rttUs: rttUs ?? this.rttUs,
      driftPpm: driftPpm ?? this.driftPpm,
      isMuted: isMuted ?? this.isMuted,
      activeDeviceId: activeDeviceId ?? this.activeDeviceId,
      playbackStatus: playbackStatus ?? this.playbackStatus,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ProtocolZoneInfo &&
        other.id == id &&
        other.name == name &&
        other.backend == backend &&
        other.deviceId == deviceId &&
        other.endpointUrl == endpointUrl &&
        other.controlUrl == controlUrl &&
        other.renderingUrl == renderingUrl &&
        other.clockSyncAddr == clockSyncAddr &&
        other.groupId == groupId &&
        other.exclusiveMode == exclusiveMode &&
        other.dspBypass == dspBypass &&
        other.volume == volume &&
        other.isActive == isActive &&
        other.clockOffsetUs == clockOffsetUs &&
        other.rttUs == rttUs &&
        other.driftPpm == driftPpm &&
        other.isMuted == isMuted &&
        other.activeDeviceId == activeDeviceId &&
        other.playbackStatus == playbackStatus;
  }

  @override
  int get hashCode => Object.hash(
        id,
        name,
        backend,
        deviceId,
        endpointUrl,
        controlUrl,
        renderingUrl,
        clockSyncAddr,
        groupId,
        exclusiveMode,
        dspBypass,
        volume,
        isActive,
        clockOffsetUs,
        rttUs,
        driftPpm,
        isMuted,
        activeDeviceId,
        playbackStatus,
      );
}
