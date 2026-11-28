import 'package:flutter/foundation.dart';

import 'json_reader.dart';
import 'protocol_enums.dart';
import 'protocol_track_metadata.dart';

part 'playback_command_queue.dart';

/// Canonical playback command sealed union matching Rust
/// `#[serde(tag = "command", rename_all = "snake_case")] pub enum PlaybackCommand`.
@immutable
sealed class PlaybackCommand {
  const PlaybackCommand();

  String get commandName;

  Map<String, Object?> toJson();

  factory PlaybackCommand.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    final tag = r.requiredString('command').trim().toLowerCase();
    return switch (tag) {
      'play' => PlayCommand(
          track: ProtocolTrackMetadata.fromJson(
            r.optionalMap('track') ?? const <String, Object?>{},
          ),
          startPositionMs: r.optionalInt('start_position_ms'),
          playbackEpoch: r.optionalInt('playback_epoch'),
        ),
      'pause' => const PauseCommand(),
      'resume' => const ResumeCommand(),
      'stop' => const StopCommand(),
      'seek' => SeekCommand(
          positionMs: r.requiredInt('position_ms', fallback: 0),
        ),
      'next' => const NextCommand(),
      'previous' => const PreviousCommand(),
      'set_volume' => SetVolumeCommand(
          volume: r.requiredDouble('volume', fallback: 1.0),
        ),
      'set_mute' => SetMuteCommand(
          muted: r.requiredBool('muted', fallback: false),
        ),
      'set_repeat_mode' => SetRepeatModeCommand(
          mode: RepeatMode.fromWireName(r.optionalString('mode')),
        ),
      'set_shuffle' => SetShuffleCommand(
          enabled: r.requiredBool('enabled', fallback: false),
        ),
      'set_output_device' => SetOutputDeviceCommand(
          deviceId: r.requiredString('device_id'),
          backend: r.nonEmptyString('backend'),
        ),
      'set_active_zone' => SetActiveZoneCommand(
          zoneId: r.requiredString('zone_id'),
        ),
      'load_queue' => LoadQueueCommand(
          items: r.mapList('items', ProtocolTrackMetadata.fromJson),
          startIndex: r.requiredInt('start_index', fallback: 0),
          autoPlay: r.requiredBool('auto_play', fallback: true),
        ),
      'enqueue' => EnqueueCommand(
          items: r.mapList('items', ProtocolTrackMetadata.fromJson),
          playNext: r.requiredBool('play_next', fallback: false),
        ),
      'remove_queue_item' => RemoveQueueItemCommand(
          index: r.requiredInt('index', fallback: 0),
        ),
      'reorder_queue' => ReorderQueueCommand(
          fromIndex: r.requiredInt('from_index', fallback: 0),
          toIndex: r.requiredInt('to_index', fallback: 0),
        ),
      'clear_queue' => const ClearQueueCommand(),
      'clear_upcoming_queue' => const ClearUpcomingQueueCommand(),
      'reconnect_device' => const ReconnectDeviceCommand(),
      _ => throw FormatException('Unknown PlaybackCommand tag: $tag'),
    };
  }
}

@immutable
final class PlayCommand extends PlaybackCommand {
  final ProtocolTrackMetadata track;
  final int? startPositionMs;
  final int? playbackEpoch;

  const PlayCommand({
    required this.track,
    this.startPositionMs,
    this.playbackEpoch,
  });

  @override
  String get commandName => 'play';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'command': commandName,
        'track': track.toJson(),
        if (startPositionMs != null) 'start_position_ms': startPositionMs,
        if (playbackEpoch != null) 'playback_epoch': playbackEpoch,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PlayCommand &&
          other.track == track &&
          other.startPositionMs == startPositionMs &&
          other.playbackEpoch == playbackEpoch);

  @override
  int get hashCode => Object.hash(commandName, track, startPositionMs, playbackEpoch);
}

@immutable
final class PauseCommand extends PlaybackCommand {
  const PauseCommand();

  @override
  String get commandName => 'pause';

  @override
  Map<String, Object?> toJson() => <String, Object?>{'command': commandName};

  @override
  bool operator ==(Object other) => other is PauseCommand;

  @override
  int get hashCode => commandName.hashCode;
}

@immutable
final class ResumeCommand extends PlaybackCommand {
  const ResumeCommand();

  @override
  String get commandName => 'resume';

  @override
  Map<String, Object?> toJson() => <String, Object?>{'command': commandName};

  @override
  bool operator ==(Object other) => other is ResumeCommand;

  @override
  int get hashCode => commandName.hashCode;
}

@immutable
final class StopCommand extends PlaybackCommand {
  const StopCommand();

  @override
  String get commandName => 'stop';

  @override
  Map<String, Object?> toJson() => <String, Object?>{'command': commandName};

  @override
  bool operator ==(Object other) => other is StopCommand;

  @override
  int get hashCode => commandName.hashCode;
}

@immutable
final class SeekCommand extends PlaybackCommand {
  final int positionMs;

  const SeekCommand({required this.positionMs});

  @override
  String get commandName => 'seek';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'command': commandName,
        'position_ms': positionMs,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SeekCommand && other.positionMs == positionMs);

  @override
  int get hashCode => Object.hash(commandName, positionMs);
}

@immutable
final class NextCommand extends PlaybackCommand {
  const NextCommand();

  @override
  String get commandName => 'next';

  @override
  Map<String, Object?> toJson() => <String, Object?>{'command': commandName};

  @override
  bool operator ==(Object other) => other is NextCommand;

  @override
  int get hashCode => commandName.hashCode;
}

@immutable
final class PreviousCommand extends PlaybackCommand {
  const PreviousCommand();

  @override
  String get commandName => 'previous';

  @override
  Map<String, Object?> toJson() => <String, Object?>{'command': commandName};

  @override
  bool operator ==(Object other) => other is PreviousCommand;

  @override
  int get hashCode => commandName.hashCode;
}

@immutable
final class SetVolumeCommand extends PlaybackCommand {
  final double volume;

  const SetVolumeCommand({required this.volume});

  @override
  String get commandName => 'set_volume';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'command': commandName,
        'volume': volume,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SetVolumeCommand && other.volume == volume);

  @override
  int get hashCode => Object.hash(commandName, volume);
}

@immutable
final class SetMuteCommand extends PlaybackCommand {
  final bool muted;

  const SetMuteCommand({required this.muted});

  @override
  String get commandName => 'set_mute';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'command': commandName,
        'muted': muted,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is SetMuteCommand && other.muted == muted);

  @override
  int get hashCode => Object.hash(commandName, muted);
}

@immutable
final class SetRepeatModeCommand extends PlaybackCommand {
  final RepeatMode mode;

  const SetRepeatModeCommand({required this.mode});

  @override
  String get commandName => 'set_repeat_mode';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'command': commandName,
        'mode': mode.wireName,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SetRepeatModeCommand && other.mode == mode);

  @override
  int get hashCode => Object.hash(commandName, mode);
}

@immutable
final class SetShuffleCommand extends PlaybackCommand {
  final bool enabled;

  const SetShuffleCommand({required this.enabled});

  @override
  String get commandName => 'set_shuffle';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'command': commandName,
        'enabled': enabled,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SetShuffleCommand && other.enabled == enabled);

  @override
  int get hashCode => Object.hash(commandName, enabled);
}

@immutable
final class SetOutputDeviceCommand extends PlaybackCommand {
  final String deviceId;
  final String? backend;

  const SetOutputDeviceCommand({required this.deviceId, this.backend});

  @override
  String get commandName => 'set_output_device';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'command': commandName,
        'device_id': deviceId,
        if (backend != null) 'backend': backend,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SetOutputDeviceCommand &&
          other.deviceId == deviceId &&
          other.backend == backend);

  @override
  int get hashCode => Object.hash(commandName, deviceId, backend);
}

@immutable
final class SetActiveZoneCommand extends PlaybackCommand {
  final String zoneId;

  const SetActiveZoneCommand({required this.zoneId});

  @override
  String get commandName => 'set_active_zone';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'command': commandName,
        'zone_id': zoneId,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SetActiveZoneCommand && other.zoneId == zoneId);

  @override
  int get hashCode => Object.hash(commandName, zoneId);
}
