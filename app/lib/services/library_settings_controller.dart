import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../models/ingestion_models.dart';

class MusicFolderEntry {
  final String path;
  final int lastTrackCount;
  final DateTime? lastScannedAt;

  const MusicFolderEntry({
    required this.path,
    this.lastTrackCount = 0,
    this.lastScannedAt,
  });

  factory MusicFolderEntry.fromJson(Map<String, dynamic> json) {
    final rawDate = json['last_scanned_at']?.toString();
    return MusicFolderEntry(
      path: json['path']?.toString() ?? '',
      lastTrackCount: (json['last_track_count'] as num?)?.toInt() ?? 0,
      lastScannedAt: rawDate != null ? DateTime.tryParse(rawDate) : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'path': path,
    'last_track_count': lastTrackCount,
    'last_scanned_at': lastScannedAt?.toIso8601String(),
  };
}

class LibrarySettingsController extends ChangeNotifier {
  /// Infers default [WatchMode] from a directory root path (UNC/SMB/WebDAV
  /// paths use `nasPolling`, local filesystem paths use `nativeOs`).
  static WatchMode inferWatchModeForPath(String rawPath) {
    final trimmed = rawPath.trim();
    final lower = trimmed.toLowerCase();
    if (trimmed.startsWith(r'\\') ||
        lower.startsWith('smb://') ||
        lower.startsWith('dav://') ||
        lower.startsWith('davs://')) {
      return WatchMode.nasPolling;
    }
    return WatchMode.nativeOs;
  }

  static const List<String> allAudioExtensions = [
    '.flac',
    '.mp3',
    '.m4a',
    '.aac',
    '.ogg',
    '.opus',
    '.wav',
    '.aiff',
    '.aif',
    '.ape',
    '.wv',
    '.mpc',
    '.tak',
    '.dsf',
    '.dff',
    '.iso',
    '.cue',
  ];

  final List<MusicFolderEntry> _folders = [];
  bool _importEntireFolderOnDrop = false;
  bool _importArchives = false;
  bool _autoImportArchivesOnScan = false;
  int _cacheLimitGb = 4;
  int _cacheUsedBytes = 0;
  bool _rescanOnStartup = true;
  bool _verifyDbIntegrity = false;
  String _backgroundTaskSpeed = 'auto';
  Set<String> _excludedExtensions = <String>{};
  bool _mergeMultiDiscSets = true;
  bool _autoMarkListenLaterListened = true;
  int _removedTrackCount = 0;

  List<MusicFolderEntry> get folders => List.unmodifiable(_folders);
  bool get importEntireFolderOnDrop => _importEntireFolderOnDrop;
  bool get importArchives => _importArchives;
  bool get autoImportArchivesOnScan => _autoImportArchivesOnScan;
  int get cacheLimitGb => _cacheLimitGb;
  int get cacheUsedBytes => _cacheUsedBytes;
  bool get rescanOnStartup => _rescanOnStartup;
  bool get verifyDbIntegrity => _verifyDbIntegrity;
  String get backgroundTaskSpeed => _backgroundTaskSpeed;
  Set<String> get excludedExtensions => Set.unmodifiable(_excludedExtensions);
  bool get mergeMultiDiscSets => _mergeMultiDiscSets;
  bool get autoMarkListenLaterListened => _autoMarkListenLaterListened;
  int get removedTrackCount => _removedTrackCount;

  String get formattedCacheUsed {
    if (_cacheUsedBytes <= 0) return '0 B';
    if (_cacheUsedBytes < 1024) return '$_cacheUsedBytes B';
    if (_cacheUsedBytes < 1024 * 1024) {
      return '${(_cacheUsedBytes / 1024).toStringAsFixed(1)} KB';
    }
    if (_cacheUsedBytes < 1024 * 1024 * 1024) {
      return '${(_cacheUsedBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(_cacheUsedBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  bool isTrackExcluded(String? filePath, String formatCodecName) {
    if (_excludedExtensions.isEmpty) return false;
    if (filePath != null && filePath.trim().isNotEmpty) {
      final lower = filePath.toLowerCase();
      for (final ext in _excludedExtensions) {
        if (lower.endsWith(ext)) return true;
      }
    }
    final codecExt = '.${formatCodecName.toLowerCase()}';
    return _excludedExtensions.contains(codecExt);
  }

  File _prefsFile() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      return File(
        '$localAppData${Platform.pathSeparator}LuminaAudio${Platform.pathSeparator}library_prefs.json',
      );
    }
    return File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}lumina_library_prefs.json',
    );
  }

  Future<void> load() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }
    try {
      final file = _prefsFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return;

      final rawFolders = decoded['folders'] as List<dynamic>? ?? const [];
      _folders
        ..clear()
        ..addAll(
          rawFolders
              .whereType<Map<String, dynamic>>()
              .map(MusicFolderEntry.fromJson)
              .where((e) => e.path.trim().isNotEmpty),
        );
      _importEntireFolderOnDrop =
          decoded['import_entire_folder_on_drop'] == true;
      _importArchives = decoded['import_archives'] == true;
      _autoImportArchivesOnScan =
          decoded['auto_import_archives_on_scan'] == true;
      _cacheLimitGb = (decoded['cache_limit_gb'] as num?)?.toInt() ?? 4;
      _cacheUsedBytes = (decoded['cache_used_bytes'] as num?)?.toInt() ?? 0;
      _rescanOnStartup = decoded['rescan_on_startup'] != false;
      _verifyDbIntegrity = decoded['verify_db_integrity'] == true;
      _backgroundTaskSpeed =
          decoded['background_task_speed']?.toString() ?? 'auto';
      final rawExcl = decoded['excluded_extensions'] as List<dynamic>? ?? [];
      _excludedExtensions = rawExcl.map((e) => e.toString()).toSet();
      _mergeMultiDiscSets = decoded['merge_multi_disc_sets'] != false;
      _autoMarkListenLaterListened =
          decoded['auto_mark_listen_later_listened'] != false;
      _removedTrackCount =
          (decoded['removed_track_count'] as num?)?.toInt() ?? 0;
      notifyListeners();
    } catch (_) {
      // Keep defaults gracefully on unreadable file.
    }
  }

  Future<void> _save() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }
    try {
      final file = _prefsFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'folders': _folders.map((e) => e.toJson()).toList(),
          'import_entire_folder_on_drop': _importEntireFolderOnDrop,
          'import_archives': _importArchives,
          'auto_import_archives_on_scan': _autoImportArchivesOnScan,
          'cache_limit_gb': _cacheLimitGb,
          'cache_used_bytes': _cacheUsedBytes,
          'rescan_on_startup': _rescanOnStartup,
          'verify_db_integrity': _verifyDbIntegrity,
          'background_task_speed': _backgroundTaskSpeed,
          'excluded_extensions': _excludedExtensions.toList(),
          'merge_multi_disc_sets': _mergeMultiDiscSets,
          'auto_mark_listen_later_listened': _autoMarkListenLaterListened,
          'removed_track_count': _removedTrackCount,
        }),
      );
    } catch (_) {
      // Ignore write errors without disturbing UI controls.
    }
  }

  void addOrUpdateFolder(String rawPath, int trackCount) {
    final normalized = rawPath.trim();
    if (normalized.isEmpty) return;
    final idx = _folders.indexWhere(
      (f) => f.path.toLowerCase() == normalized.toLowerCase(),
    );
    final entry = MusicFolderEntry(
      path: normalized,
      lastTrackCount: trackCount,
      lastScannedAt: DateTime.now(),
    );
    if (idx >= 0) {
      _folders[idx] = entry;
    } else {
      _folders.add(entry);
    }
    notifyListeners();
    _save();
  }

  void removeFolder(String path) {
    _folders.removeWhere((f) => f.path.toLowerCase() == path.toLowerCase());
    notifyListeners();
    _save();
  }

  void setImportEntireFolderOnDrop(bool value) {
    if (_importEntireFolderOnDrop == value) return;
    _importEntireFolderOnDrop = value;
    notifyListeners();
    _save();
  }

  void setImportArchives(bool value) {
    if (_importArchives == value) return;
    _importArchives = value;
    if (!value) {
      _autoImportArchivesOnScan = false;
    }
    notifyListeners();
    _save();
  }

  void setAutoImportArchivesOnScan(bool value) {
    if (!_importArchives && value) return;
    if (_autoImportArchivesOnScan == value) return;
    _autoImportArchivesOnScan = value;
    notifyListeners();
    _save();
  }

  void setCacheLimitGb(int gb) {
    if (_cacheLimitGb == gb) return;
    _cacheLimitGb = gb;
    notifyListeners();
    _save();
  }

  void clearCache() {
    _cacheUsedBytes = 0;
    notifyListeners();
    _save();
  }

  void setRescanOnStartup(bool value) {
    if (_rescanOnStartup == value) return;
    _rescanOnStartup = value;
    notifyListeners();
    _save();
  }

  void setVerifyDbIntegrity(bool value) {
    if (_verifyDbIntegrity == value) return;
    _verifyDbIntegrity = value;
    notifyListeners();
    _save();
  }

  void setBackgroundTaskSpeed(String speed) {
    if (_backgroundTaskSpeed == speed) return;
    _backgroundTaskSpeed = speed;
    notifyListeners();
    _save();
  }

  void applyExcludedExtensions(Set<String> next) {
    _excludedExtensions = Set<String>.from(next);
    notifyListeners();
    _save();
  }

  void setMergeMultiDiscSets(bool value) {
    if (_mergeMultiDiscSets == value) return;
    _mergeMultiDiscSets = value;
    notifyListeners();
    _save();
  }

  void setAutoMarkListenLaterListened(bool value) {
    if (_autoMarkListenLaterListened == value) return;
    _autoMarkListenLaterListened = value;
    notifyListeners();
    _save();
  }

  void restoreRemovedTracks() {
    _removedTrackCount = 0;
    notifyListeners();
    _save();
  }

  /// Opens native Windows folder picker dialog on desktop runtime (skipped in tests).
  Future<String?> pickFolderNative() async {
    if (!Platform.isWindows || Platform.environment.containsKey('FLUTTER_TEST')) {
      return null;
    }
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-STA',
        '-Command',
        "Add-Type -AssemblyName System.Windows.Forms; "
            "\$dlg = New-Object System.Windows.Forms.FolderBrowserDialog; "
            "\$dlg.Description = '選擇要加入 Lumina Audio 的音樂資料夾'; "
            "\$dlg.ShowNewFolderButton = \$false; "
            "if (\$dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Write-Output \$dlg.SelectedPath }",
      ]);
      if (result.exitCode == 0) {
        final chosen = result.stdout.toString().trim();
        if (chosen.isNotEmpty) return chosen;
      }
    } catch (_) {
      // Fallback cleanly if dialog fails or is cancelled.
    }
    return null;
  }
}
