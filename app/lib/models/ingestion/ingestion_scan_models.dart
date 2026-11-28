import 'package:flutter/foundation.dart';

/// Structured reason why a local/NAS audio file was quarantined during scan.
enum SkipReason {
  corruptHeader,
  permissionDenied,
  unsupportedFormat,
  unsplitCueOrIso,
  garbledTags,
  ioError;

  String toJson() => switch (this) {
    SkipReason.corruptHeader => 'corrupt_header',
    SkipReason.permissionDenied => 'permission_denied',
    SkipReason.unsupportedFormat => 'unsupported_format',
    SkipReason.unsplitCueOrIso => 'unsplit_cue_or_iso',
    SkipReason.garbledTags => 'garbled_tags',
    SkipReason.ioError => 'io_error',
  };

  static SkipReason fromJson(String? raw) => switch (raw?.trim().toLowerCase()) {
    'corrupt_header' => SkipReason.corruptHeader,
    'permission_denied' => SkipReason.permissionDenied,
    'unsupported_format' => SkipReason.unsupportedFormat,
    'unsplit_cue_or_iso' => SkipReason.unsplitCueOrIso,
    'garbled_tags' => SkipReason.garbledTags,
    'io_error' => SkipReason.ioError,
    _ => SkipReason.ioError,
  };

  String get displayLabel => switch (this) {
    SkipReason.corruptHeader => '音訊標頭損毀',
    SkipReason.permissionDenied => '權限不足',
    SkipReason.unsupportedFormat => '不支援的格式',
    SkipReason.unsplitCueOrIso => '未分割的 CUE / ISO 映像',
    SkipReason.garbledTags => '標籤編碼異常',
    SkipReason.ioError => '檔案讀取錯誤',
  };
}

/// Quarantine record for a file skipped during directory ingestion.
@immutable
class SkippedFileRecord {
  final String id;
  final String providerId;
  final String filePath;
  final SkipReason reason;
  final String detail;
  final int? fileSize;
  final int? fileMtime;
  final String firstSeenAt;
  final String lastSeenAt;
  final bool dismissed;

  const SkippedFileRecord({
    required this.id,
    required this.providerId,
    required this.filePath,
    required this.reason,
    required this.detail,
    this.fileSize,
    this.fileMtime,
    required this.firstSeenAt,
    required this.lastSeenAt,
    this.dismissed = false,
  });

  factory SkippedFileRecord.fromJson(Map<String, dynamic> json) =>
      SkippedFileRecord(
        id: json['id']?.toString() ?? '',
        providerId: json['provider_id']?.toString() ?? 'local',
        filePath: json['file_path']?.toString() ?? '',
        reason: SkipReason.fromJson(json['reason']?.toString()),
        detail: json['detail']?.toString() ?? '',
        fileSize: (json['file_size'] as num?)?.toInt(),
        fileMtime: (json['file_mtime'] as num?)?.toInt(),
        firstSeenAt: json['first_seen_at']?.toString() ?? '',
        lastSeenAt: json['last_seen_at']?.toString() ?? '',
        dismissed: json['dismissed'] == true || json['dismissed'] == 1,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'provider_id': providerId,
    'file_path': filePath,
    'reason': reason.toJson(),
    'detail': detail,
    if (fileSize != null) 'file_size': fileSize,
    if (fileMtime != null) 'file_mtime': fileMtime,
    'first_seen_at': firstSeenAt,
    'last_seen_at': lastSeenAt,
    'dismissed': dismissed,
  };
}

/// Lifecycle phase of an asynchronous library scan / watch session.
enum ScanLifecycleState {
  idle,
  discovering,
  probing,
  persisting,
  watching,
  completed,
  failed;

  String toJson() => name;

  static ScanLifecycleState fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'idle' => ScanLifecycleState.idle,
        'discovering' => ScanLifecycleState.discovering,
        'probing' => ScanLifecycleState.probing,
        'persisting' => ScanLifecycleState.persisting,
        'watching' => ScanLifecycleState.watching,
        'completed' => ScanLifecycleState.completed,
        'failed' => ScanLifecycleState.failed,
        _ => ScanLifecycleState.idle,
      };
}

/// Incremental scan telemetry emitted over FFI callbacks and WebSocket events.
@immutable
class ScanProgressEvent {
  final String scanId;
  final String rootPath;
  final ScanLifecycleState state;
  final int scanned;
  final int added;
  final int updated;
  final int unchanged;
  final int skipped;
  final int pruned;
  final int? totalEstimated;
  final String? currentPath;
  final String? message;

  const ScanProgressEvent({
    required this.scanId,
    required this.rootPath,
    required this.state,
    this.scanned = 0,
    this.added = 0,
    this.updated = 0,
    this.unchanged = 0,
    this.skipped = 0,
    this.pruned = 0,
    this.totalEstimated,
    this.currentPath,
    this.message,
  });

  factory ScanProgressEvent.fromJson(Map<String, dynamic> json) =>
      ScanProgressEvent(
        scanId: json['scan_id']?.toString() ?? '',
        rootPath: json['root_path']?.toString() ?? '',
        state: ScanLifecycleState.fromJson(json['state']?.toString()),
        scanned: (json['scanned'] as num?)?.toInt() ?? 0,
        added: (json['added'] as num?)?.toInt() ?? 0,
        updated: (json['updated'] as num?)?.toInt() ?? 0,
        unchanged: (json['unchanged'] as num?)?.toInt() ?? 0,
        skipped: (json['skipped'] as num?)?.toInt() ?? 0,
        pruned: (json['pruned'] as num?)?.toInt() ?? 0,
        totalEstimated: (json['total_estimated'] as num?)?.toInt(),
        currentPath: json['current_path']?.toString(),
        message: json['message']?.toString(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'scan_id': scanId,
    'root_path': rootPath,
    'state': state.toJson(),
    'scanned': scanned,
    'added': added,
    'updated': updated,
    'unchanged': unchanged,
    'skipped': skipped,
    'pruned': pruned,
    if (totalEstimated != null) 'total_estimated': totalEstimated,
    if (currentPath != null) 'current_path': currentPath,
    if (message != null) 'message': message,
  };
}

/// Strategy used to monitor a configured music library root directory.
enum WatchMode {
  nativeOs,
  nasPolling,
  manual;

  String toJson() => switch (this) {
    WatchMode.nativeOs => 'native_os',
    WatchMode.nasPolling => 'nas_polling',
    WatchMode.manual => 'manual',
  };

  static WatchMode fromJson(String? raw) => switch (raw?.trim().toLowerCase()) {
    'native_os' => WatchMode.nativeOs,
    'nas_polling' => WatchMode.nasPolling,
    'manual' => WatchMode.manual,
    _ => WatchMode.nativeOs,
  };
}

/// Persisted watched folder root and its current monitoring health.
@immutable
class WatchedRootRecord {
  final String id;
  final String providerId;
  final String rootPath;
  final WatchMode watchMode;
  final int pollIntervalSec;
  final bool isOnline;
  final String? lastScanAt;
  final String updatedAt;

  const WatchedRootRecord({
    required this.id,
    required this.providerId,
    required this.rootPath,
    this.watchMode = WatchMode.nativeOs,
    this.pollIntervalSec = 300,
    this.isOnline = true,
    this.lastScanAt,
    required this.updatedAt,
  });

  factory WatchedRootRecord.fromJson(Map<String, dynamic> json) =>
      WatchedRootRecord(
        id: json['id']?.toString() ?? '',
        providerId: json['provider_id']?.toString() ?? 'local',
        rootPath: json['root_path']?.toString() ?? '',
        watchMode: WatchMode.fromJson(json['watch_mode']?.toString()),
        pollIntervalSec: (json['poll_interval_sec'] as num?)?.toInt() ?? 300,
        isOnline: json['is_online'] != false && json['is_online'] != 0,
        lastScanAt: json['last_scan_at']?.toString(),
        updatedAt: json['updated_at']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'provider_id': providerId,
    'root_path': rootPath,
    'watch_mode': watchMode.toJson(),
    'poll_interval_sec': pollIntervalSec,
    'is_online': isOnline,
    if (lastScanAt != null) 'last_scan_at': lastScanAt,
    'updated_at': updatedAt,
  };
}

/// Precedence layer for non-destructive metadata overrides
/// (`fileTag < cloudEnrichment < userEdit`).
enum MetadataLayer {
  fileTag,
  cloudEnrichment,
  userEdit;

  String toJson() => switch (this) {
    MetadataLayer.fileTag => 'file_tag',
    MetadataLayer.cloudEnrichment => 'cloud_enrichment',
    MetadataLayer.userEdit => 'user_edit',
  };

  static MetadataLayer fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'file_tag' => MetadataLayer.fileTag,
        'cloud_enrichment' => MetadataLayer.cloudEnrichment,
        'user_edit' => MetadataLayer.userEdit,
        _ => MetadataLayer.userEdit,
      };
}

/// Non-destructive metadata field override stored in SQLite.
@immutable
class MetadataOverrideRecord {
  final String entityType;
  final String entityId;
  final String fieldName;
  final String valueJson;
  final MetadataLayer sourceLayer;
  final String updatedAt;

  const MetadataOverrideRecord({
    required this.entityType,
    required this.entityId,
    required this.fieldName,
    required this.valueJson,
    this.sourceLayer = MetadataLayer.userEdit,
    required this.updatedAt,
  });

  factory MetadataOverrideRecord.fromJson(Map<String, dynamic> json) =>
      MetadataOverrideRecord(
        entityType: json['entity_type']?.toString() ?? 'track',
        entityId: json['entity_id']?.toString() ?? '',
        fieldName: json['field_name']?.toString() ?? '',
        valueJson: json['value_json']?.toString() ?? '',
        sourceLayer: MetadataLayer.fromJson(json['source_layer']?.toString()),
        updatedAt: json['updated_at']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'entity_type': entityType,
    'entity_id': entityId,
    'field_name': fieldName,
    'value_json': valueJson,
    'source_layer': sourceLayer.toJson(),
    'updated_at': updatedAt,
  };
}
