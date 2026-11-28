import 'package:flutter/foundation.dart';

import 'json_reader.dart';
import 'protocol_audio_device_info.dart';
import 'protocol_playback_state.dart';
import 'protocol_signal_path.dart';
import 'protocol_zone_info.dart';
import 'queue_models.dart';

/// Atomic state snapshot matching Rust `core_types::ProtocolSnapshot`.
@immutable
class ProtocolSnapshot {
  final ProtocolPlaybackState playback;
  final QueueState queue;
  final ProtocolSignalPath? signalPath;
  final List<ProtocolAudioDeviceInfo> devices;
  final List<ProtocolZoneInfo> zones;
  final int serverTimeMs;
  final int sequence;

  const ProtocolSnapshot({
    required this.playback,
    required this.queue,
    this.signalPath,
    this.devices = const <ProtocolAudioDeviceInfo>[],
    this.zones = const <ProtocolZoneInfo>[],
    this.serverTimeMs = 0,
    this.sequence = 0,
  });

  factory ProtocolSnapshot.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    final playbackMap = r.optionalMap('playback') ?? const <String, Object?>{};
    final queueMap = r.optionalMap('queue') ?? const <String, Object?>{};
    final signalPathMap = r.optionalMap('signal_path');
    return ProtocolSnapshot(
      playback: ProtocolPlaybackState.fromJson(playbackMap),
      queue: QueueState.fromJson(queueMap),
      signalPath: signalPathMap != null
          ? ProtocolSignalPath.fromJson(signalPathMap)
          : null,
      devices: r.mapList('devices', ProtocolAudioDeviceInfo.fromJson),
      zones: r.mapList('zones', ProtocolZoneInfo.fromJson),
      serverTimeMs: r.requiredInt('server_time_ms', fallback: 0),
      sequence: r.requiredInt('sequence', fallback: 0),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'playback': playback.toJson(),
      'queue': queue.toJson(),
      if (signalPath != null) 'signal_path': signalPath!.toJson(),
      'devices': devices.map((d) => d.toJson()).toList(growable: false),
      'zones': zones.map((z) => z.toJson()).toList(growable: false),
      'server_time_ms': serverTimeMs,
      'sequence': sequence,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ProtocolSnapshot &&
        other.playback == playback &&
        other.queue == queue &&
        other.signalPath == signalPath &&
        listEquals(other.devices, devices) &&
        listEquals(other.zones, zones) &&
        other.serverTimeMs == serverTimeMs &&
        other.sequence == sequence;
  }

  @override
  int get hashCode => Object.hash(
        playback,
        queue,
        signalPath,
        Object.hashAll(devices),
        Object.hashAll(zones),
        serverTimeMs,
        sequence,
      );
}
