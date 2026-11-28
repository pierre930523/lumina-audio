part of 'playback_command.dart';

@immutable
final class LoadQueueCommand extends PlaybackCommand {
  final List<ProtocolTrackMetadata> items;
  final int startIndex;
  final bool autoPlay;

  const LoadQueueCommand({
    required this.items,
    this.startIndex = 0,
    this.autoPlay = true,
  });

  @override
  String get commandName => 'load_queue';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'command': commandName,
        'items': items.map((e) => e.toJson()).toList(growable: false),
        'start_index': startIndex,
        'auto_play': autoPlay,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LoadQueueCommand &&
          listEquals(other.items, items) &&
          other.startIndex == startIndex &&
          other.autoPlay == autoPlay);

  @override
  int get hashCode =>
      Object.hash(commandName, Object.hashAll(items), startIndex, autoPlay);
}

@immutable
final class EnqueueCommand extends PlaybackCommand {
  final List<ProtocolTrackMetadata> items;
  final bool playNext;

  const EnqueueCommand({required this.items, this.playNext = false});

  @override
  String get commandName => 'enqueue';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'command': commandName,
        'items': items.map((e) => e.toJson()).toList(growable: false),
        'play_next': playNext,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EnqueueCommand &&
          listEquals(other.items, items) &&
          other.playNext == playNext);

  @override
  int get hashCode =>
      Object.hash(commandName, Object.hashAll(items), playNext);
}

@immutable
final class RemoveQueueItemCommand extends PlaybackCommand {
  final int index;

  const RemoveQueueItemCommand({required this.index});

  @override
  String get commandName => 'remove_queue_item';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'command': commandName,
        'index': index,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RemoveQueueItemCommand && other.index == index);

  @override
  int get hashCode => Object.hash(commandName, index);
}

@immutable
final class ReorderQueueCommand extends PlaybackCommand {
  final int fromIndex;
  final int toIndex;

  const ReorderQueueCommand({required this.fromIndex, required this.toIndex});

  @override
  String get commandName => 'reorder_queue';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'command': commandName,
        'from_index': fromIndex,
        'to_index': toIndex,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReorderQueueCommand &&
          other.fromIndex == fromIndex &&
          other.toIndex == toIndex);

  @override
  int get hashCode => Object.hash(commandName, fromIndex, toIndex);
}

@immutable
final class ClearQueueCommand extends PlaybackCommand {
  const ClearQueueCommand();

  @override
  String get commandName => 'clear_queue';

  @override
  Map<String, Object?> toJson() => <String, Object?>{'command': commandName};

  @override
  bool operator ==(Object other) => other is ClearQueueCommand;

  @override
  int get hashCode => commandName.hashCode;
}

@immutable
final class ClearUpcomingQueueCommand extends PlaybackCommand {
  const ClearUpcomingQueueCommand();

  @override
  String get commandName => 'clear_upcoming_queue';

  @override
  Map<String, Object?> toJson() => <String, Object?>{'command': commandName};

  @override
  bool operator ==(Object other) => other is ClearUpcomingQueueCommand;

  @override
  int get hashCode => commandName.hashCode;
}

@immutable
final class ReconnectDeviceCommand extends PlaybackCommand {
  const ReconnectDeviceCommand();

  @override
  String get commandName => 'reconnect_device';

  @override
  Map<String, Object?> toJson() => <String, Object?>{'command': commandName};

  @override
  bool operator ==(Object other) => other is ReconnectDeviceCommand;

  @override
  int get hashCode => commandName.hashCode;
}
