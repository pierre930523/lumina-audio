import 'package:flutter/foundation.dart';

import 'json_reader.dart';
import 'lumina_error.dart';
import 'protocol_audio_device_info.dart';
import 'protocol_playback_state.dart';
import 'protocol_signal_path.dart';
import 'protocol_snapshot.dart';
import 'protocol_zone_info.dart';
import 'queue_models.dart';

/// Canonical WebSocket server->client event union matching Rust
/// `#[serde(tag = "type", content = "payload")] pub enum WsServerEvent`.
@immutable
sealed class WsServerEvent {
  const WsServerEvent();

  String get eventType;

  Map<String, Object?> toJson();

  static WsServerEvent? tryFromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    final type = r.nonEmptyString('type');
    if (type == null) return null;
    switch (type) {
      case 'Snapshot':
        final payload = r.optionalMap('payload');
        if (payload == null) return null;
        return SnapshotEvent(ProtocolSnapshot.fromJson(payload));
      case 'PlaybackStateChanged':
        final payload = r.optionalMap('payload');
        if (payload == null) return null;
        return PlaybackStateChangedEvent(ProtocolPlaybackState.fromJson(payload));
      case 'QueueStateChanged':
        final payload = r.optionalMap('payload');
        if (payload == null) return null;
        return QueueStateChangedEvent(QueueState.fromJson(payload));
      case 'SignalPathUpdated':
        final payload = r.optionalMap('payload');
        if (payload == null) return null;
        return SignalPathUpdatedEvent(ProtocolSignalPath.fromJson(payload));
      case 'DevicesChanged':
        final list = r.optionalList('payload');
        if (list == null) return null;
        final devices = <ProtocolAudioDeviceInfo>[];
        for (final item in list) {
          final m = JsonReader.asMapOrNull(item);
          if (m != null) {
            devices.add(ProtocolAudioDeviceInfo.fromJson(m));
          }
        }
        return DevicesChangedEvent(List<ProtocolAudioDeviceInfo>.unmodifiable(devices));
      case 'ZonesChanged':
        final list = r.optionalList('payload');
        if (list == null) return null;
        final zones = <ProtocolZoneInfo>[];
        for (final item in list) {
          final m = JsonReader.asMapOrNull(item);
          if (m != null) {
            zones.add(ProtocolZoneInfo.fromJson(m));
          }
        }
        return ZonesChangedEvent(List<ProtocolZoneInfo>.unmodifiable(zones));
      case 'Error':
        final payload = r.optionalMap('payload');
        if (payload == null) return null;
        return ErrorEvent(LuminaError.fromJson(payload));
      default:
        return null;
    }
  }
}

@immutable
final class SnapshotEvent extends WsServerEvent {
  final ProtocolSnapshot snapshot;

  const SnapshotEvent(this.snapshot);

  @override
  String get eventType => 'Snapshot';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'type': eventType,
        'payload': snapshot.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SnapshotEvent && other.snapshot == snapshot);

  @override
  int get hashCode => Object.hash(eventType, snapshot);
}

@immutable
final class PlaybackStateChangedEvent extends WsServerEvent {
  final ProtocolPlaybackState state;

  const PlaybackStateChangedEvent(this.state);

  @override
  String get eventType => 'PlaybackStateChanged';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'type': eventType,
        'payload': state.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlaybackStateChangedEvent && other.state == state);

  @override
  int get hashCode => Object.hash(eventType, state);
}

@immutable
final class QueueStateChangedEvent extends WsServerEvent {
  final QueueState queue;

  const QueueStateChangedEvent(this.queue);

  @override
  String get eventType => 'QueueStateChanged';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'type': eventType,
        'payload': queue.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is QueueStateChangedEvent && other.queue == queue);

  @override
  int get hashCode => Object.hash(eventType, queue);
}

@immutable
final class SignalPathUpdatedEvent extends WsServerEvent {
  final ProtocolSignalPath signalPath;

  const SignalPathUpdatedEvent(this.signalPath);

  @override
  String get eventType => 'SignalPathUpdated';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'type': eventType,
        'payload': signalPath.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SignalPathUpdatedEvent && other.signalPath == signalPath);

  @override
  int get hashCode => Object.hash(eventType, signalPath);
}

@immutable
final class DevicesChangedEvent extends WsServerEvent {
  final List<ProtocolAudioDeviceInfo> devices;

  const DevicesChangedEvent(this.devices);

  @override
  String get eventType => 'DevicesChanged';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'type': eventType,
        'payload': devices.map((d) => d.toJson()).toList(growable: false),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DevicesChangedEvent && listEquals(other.devices, devices));

  @override
  int get hashCode => Object.hash(eventType, Object.hashAll(devices));
}

@immutable
final class ZonesChangedEvent extends WsServerEvent {
  final List<ProtocolZoneInfo> zones;

  const ZonesChangedEvent(this.zones);

  @override
  String get eventType => 'ZonesChanged';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'type': eventType,
        'payload': zones.map((z) => z.toJson()).toList(growable: false),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ZonesChangedEvent && listEquals(other.zones, zones));

  @override
  int get hashCode => Object.hash(eventType, Object.hashAll(zones));
}

@immutable
final class ErrorEvent extends WsServerEvent {
  final LuminaError error;

  const ErrorEvent(this.error);

  @override
  String get eventType => 'Error';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'type': eventType,
        'payload': error.toJson(),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is ErrorEvent && other.error == error);

  @override
  int get hashCode => Object.hash(eventType, error);
}
