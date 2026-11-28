import 'package:flutter/foundation.dart';

import '../playback_state.dart';
import 'json_reader.dart';
import 'protocol_enums.dart';
import 'protocol_track_metadata.dart';

/// Canonical queue item matching Rust `core_types::QueueItem`.
@immutable
class QueueItem {
  final String itemId;
  final ProtocolTrackMetadata track;
  final bool isUserQueued;

  const QueueItem({
    required this.itemId,
    required this.track,
    this.isUserQueued = false,
  });

  factory QueueItem.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    final trackMap = r.optionalMap('track') ?? const <String, Object?>{};
    return QueueItem(
      itemId: r.requiredString('item_id'),
      track: ProtocolTrackMetadata.fromJson(trackMap),
      isUserQueued: r.requiredBool('is_user_queued', fallback: false),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'item_id': itemId,
      'track': track.toJson(),
      'is_user_queued': isUserQueued,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is QueueItem &&
        other.itemId == itemId &&
        other.track == track &&
        other.isUserQueued == isUserQueued;
  }

  @override
  int get hashCode => Object.hash(itemId, track, isUserQueued);
}

/// Canonical queue state matching Rust `core_types::QueueState`.
@immutable
class QueueState {
  final List<QueueItem> items;
  final int? currentIndex;
  final RepeatMode repeatMode;
  final bool shuffle;
  final int queueEpoch;
  final int timestampMs;

  const QueueState({
    this.items = const <QueueItem>[],
    this.currentIndex,
    this.repeatMode = RepeatMode.off,
    this.shuffle = false,
    this.queueEpoch = 0,
    this.timestampMs = 0,
  });

  static const QueueState empty = QueueState();

  factory QueueState.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    return QueueState(
      items: r.mapList('items', QueueItem.fromJson),
      currentIndex: r.optionalInt('current_index'),
      repeatMode: RepeatMode.fromWireName(r.optionalString('repeat_mode')),
      shuffle: r.requiredBool('shuffle', fallback: false),
      queueEpoch: r.requiredInt('queue_epoch', fallback: 0),
      timestampMs: r.requiredInt('timestamp_ms', fallback: 0),
    );
  }

  QueueItem? get currentItem {
    final idx = currentIndex;
    if (idx == null || idx < 0 || idx >= items.length) return null;
    return items[idx];
  }

  List<TrackInfo> toTrackInfoList() {
    return List<TrackInfo>.unmodifiable(
      items.map((item) => item.track.toTrackInfo()),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'items': items.map((e) => e.toJson()).toList(growable: false),
      if (currentIndex != null) 'current_index': currentIndex,
      'repeat_mode': repeatMode.wireName,
      'shuffle': shuffle,
      'queue_epoch': queueEpoch,
      'timestamp_ms': timestampMs,
    };
  }

  QueueState copyWith({
    List<QueueItem>? items,
    int? currentIndex,
    bool clearCurrentIndex = false,
    RepeatMode? repeatMode,
    bool? shuffle,
    int? queueEpoch,
    int? timestampMs,
  }) {
    return QueueState(
      items: items != null ? List<QueueItem>.unmodifiable(items) : this.items,
      currentIndex:
          clearCurrentIndex ? null : (currentIndex ?? this.currentIndex),
      repeatMode: repeatMode ?? this.repeatMode,
      shuffle: shuffle ?? this.shuffle,
      queueEpoch: queueEpoch ?? this.queueEpoch,
      timestampMs: timestampMs ?? this.timestampMs,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is QueueState &&
        listEquals(other.items, items) &&
        other.currentIndex == currentIndex &&
        other.repeatMode == repeatMode &&
        other.shuffle == shuffle &&
        other.queueEpoch == queueEpoch &&
        other.timestampMs == timestampMs;
  }

  @override
  int get hashCode => Object.hash(
        Object.hashAll(items),
        currentIndex,
        repeatMode,
        shuffle,
        queueEpoch,
        timestampMs,
      );
}
