import 'package:flutter/foundation.dart';

import 'focus_models.dart';

part 'catalog_export_models.dart';

bool _readBool(dynamic raw, {bool fallback = false}) {
  if (raw == null) return fallback;
  if (raw is bool) return raw;
  if (raw is num) return raw != 0;
  final s = raw.toString().trim().toLowerCase();
  if (s == 'true' || s == '1') return true;
  if (s == 'false' || s == '0') return false;
  return fallback;
}

List<String> _readStringList(dynamic raw) =>
    (raw as List<dynamic>? ?? const []).map((e) => e.toString()).toList(growable: false);

Map<String, int> _readIntMap(dynamic raw) {
  final out = <String, int>{};
  if (raw is Map) {
    for (final entry in raw.entries) {
      out[entry.key.toString()] = (entry.value as num?)?.toInt() ?? 0;
    }
  }
  return out;
}

/// How a SQLite database backup snapshot was triggered.
enum BackupTriggerMode {
  manual('manual'),
  scheduled('scheduled'),
  preRestore('pre_restore');

  final String wireName;

  const BackupTriggerMode(this.wireName);

  String toJson() => wireName;

  static BackupTriggerMode fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'scheduled' => BackupTriggerMode.scheduled,
        'pre_restore' => BackupTriggerMode.preRestore,
        _ => BackupTriggerMode.manual,
      };
}

/// Periodic automatic backup cadence.
enum BackupScheduleMode {
  off('off'),
  daily('daily'),
  weekly('weekly');

  final String wireName;

  const BackupScheduleMode(this.wireName);

  String toJson() => wireName;

  static BackupScheduleMode fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'daily' => BackupScheduleMode.daily,
        'weekly' => BackupScheduleMode.weekly,
        _ => BackupScheduleMode.off,
      };
}

/// Persistent database backup configuration & resolved directory path.
@immutable
class BackupSettings {
  final String backupDir;
  final BackupScheduleMode scheduleMode;
  final int maxKeep;
  final String resolvedBackupDir;

  const BackupSettings({
    this.backupDir = '',
    this.scheduleMode = BackupScheduleMode.off,
    this.maxKeep = 10,
    this.resolvedBackupDir = '',
  });

  BackupSettings copyWith({
    String? backupDir,
    BackupScheduleMode? scheduleMode,
    int? maxKeep,
    String? resolvedBackupDir,
  }) => BackupSettings(
    backupDir: backupDir ?? this.backupDir,
    scheduleMode: scheduleMode ?? this.scheduleMode,
    maxKeep: maxKeep ?? this.maxKeep,
    resolvedBackupDir: resolvedBackupDir ?? this.resolvedBackupDir,
  );

  factory BackupSettings.fromJson(Map<String, dynamic> json) => BackupSettings(
    backupDir: json['backup_dir']?.toString() ?? '',
    scheduleMode: BackupScheduleMode.fromJson(json['schedule_mode']?.toString()),
    maxKeep: (json['max_keep'] as num?)?.toInt() ?? 10,
    resolvedBackupDir: json['resolved_backup_dir']?.toString() ?? '',
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'backup_dir': backupDir,
    'schedule_mode': scheduleMode.toJson(),
    'max_keep': maxKeep,
    'resolved_backup_dir': resolvedBackupDir,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackupSettings &&
          other.backupDir == backupDir &&
          other.scheduleMode == scheduleMode &&
          other.maxKeep == maxKeep &&
          other.resolvedBackupDir == resolvedBackupDir;

  @override
  int get hashCode =>
      Object.hash(backupDir, scheduleMode, maxKeep, resolvedBackupDir);
}

/// Sidecar JSON manifest written alongside every SQLite backup file.
@immutable
class BackupManifest {
  final String backupId;
  final String createdAt;
  final BackupTriggerMode triggerMode;
  final String appVersion;
  final int schemaVersion;
  final String dbFilename;
  final String sha256;
  final int sizeBytes;
  final Map<String, int> tableCounts;

  const BackupManifest({
    required this.backupId,
    required this.createdAt,
    required this.triggerMode,
    required this.appVersion,
    required this.schemaVersion,
    required this.dbFilename,
    required this.sha256,
    this.sizeBytes = 0,
    this.tableCounts = const <String, int>{},
  });

  factory BackupManifest.fromJson(Map<String, dynamic> json) => BackupManifest(
    backupId: json['backup_id']?.toString() ?? '',
    createdAt: json['created_at']?.toString() ?? '',
    triggerMode: BackupTriggerMode.fromJson(json['trigger_mode']?.toString()),
    appVersion: json['app_version']?.toString() ?? '',
    schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 0,
    dbFilename: json['db_filename']?.toString() ?? '',
    sha256: json['sha256']?.toString() ?? '',
    sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
    tableCounts: _readIntMap(json['table_counts']),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'backup_id': backupId,
    'created_at': createdAt,
    'trigger_mode': triggerMode.toJson(),
    'app_version': appVersion,
    'schema_version': schemaVersion,
    'db_filename': dbFilename,
    'sha256': sha256,
    'size_bytes': sizeBytes,
    'table_counts': tableCounts,
  };
}

/// History entry for a recorded SQLite database backup.
@immutable
class BackupHistoryRecord {
  final String id;
  final BackupTriggerMode triggerMode;
  final String backupPath;
  final String manifestPath;
  final String sha256;
  final int sizeBytes;
  final int schemaVersion;
  final String status;
  final String? errorMessage;
  final String createdAt;
  final bool existsOnDisk;

  const BackupHistoryRecord({
    required this.id,
    required this.triggerMode,
    required this.backupPath,
    required this.manifestPath,
    required this.sha256,
    this.sizeBytes = 0,
    this.schemaVersion = 0,
    required this.status,
    this.errorMessage,
    required this.createdAt,
    this.existsOnDisk = false,
  });

  factory BackupHistoryRecord.fromJson(Map<String, dynamic> json) =>
      BackupHistoryRecord(
        id: json['id']?.toString() ?? '',
        triggerMode: BackupTriggerMode.fromJson(json['trigger_mode']?.toString()),
        backupPath: json['backup_path']?.toString() ?? '',
        manifestPath: json['manifest_path']?.toString() ?? '',
        sha256: json['sha256']?.toString() ?? '',
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 0,
        status: json['status']?.toString() ?? '',
        errorMessage: json['error_message']?.toString(),
        createdAt: json['created_at']?.toString() ?? '',
        existsOnDisk: _readBool(json['exists_on_disk']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'trigger_mode': triggerMode.toJson(),
    'backup_path': backupPath,
    'manifest_path': manifestPath,
    'sha256': sha256,
    'size_bytes': sizeBytes,
    'schema_version': schemaVersion,
    'status': status,
    if (errorMessage != null) 'error_message': errorMessage,
    'created_at': createdAt,
    'exists_on_disk': existsOnDisk,
  };
}

/// Summary returned after restoring a backup and hot-swapping the SQLite pool.
@immutable
class RestoreBackupResult {
  final String restoredBackupId;
  final String? preRestoreBackupId;
  final String restoredFromPath;
  final int schemaVersion;
  final Map<String, int> tableCounts;
  final bool reloadRequired;

  const RestoreBackupResult({
    required this.restoredBackupId,
    this.preRestoreBackupId,
    required this.restoredFromPath,
    this.schemaVersion = 0,
    this.tableCounts = const <String, int>{},
    this.reloadRequired = true,
  });

  factory RestoreBackupResult.fromJson(Map<String, dynamic> json) =>
      RestoreBackupResult(
        restoredBackupId: json['restored_backup_id']?.toString() ?? '',
        preRestoreBackupId: json['pre_restore_backup_id']?.toString(),
        restoredFromPath: json['restored_from_path']?.toString() ?? '',
        schemaVersion: (json['schema_version'] as num?)?.toInt() ?? 0,
        tableCounts: _readIntMap(json['table_counts']),
        reloadRequired: _readBool(json['reload_required'], fallback: true),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'restored_backup_id': restoredBackupId,
    if (preRestoreBackupId != null) 'pre_restore_backup_id': preRestoreBackupId,
    'restored_from_path': restoredFromPath,
    'schema_version': schemaVersion,
    'table_counts': tableCounts,
    'reload_required': reloadRequired,
  };
}
