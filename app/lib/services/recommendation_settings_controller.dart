import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'streaming/secure_credential_store.dart';

/// Persists cross-platform Autoplay & Recommendations user preferences.
class RecommendationSettingsController extends ChangeNotifier {
  static const List<String> defaultPlatformPriority = <String>[
    'local',
    'tidal',
    'qobuz',
    'deezer',
    'youtube_music',
  ];

  static const String lastFmApiKeyCredentialKey =
      'recommendation_lastfm_api_key';

  final File? prefsFileOverride;
  final SecureCredentialStore? credentialStore;

  bool _autoplayEnabled = true;
  bool _crossPlatformRoutingEnabled = true;
  List<String> _platformPriority = List<String>.from(defaultPlatformPriority);
  bool _listenBrainzEnabled = true;
  String _lastFmApiKey = '';

  Future<void> _saveQueue = Future<void>.value();

  RecommendationSettingsController({
    this.prefsFileOverride,
    this.credentialStore,
  });

  bool get autoplayEnabled => _autoplayEnabled;
  bool get crossPlatformRoutingEnabled => _crossPlatformRoutingEnabled;
  List<String> get platformPriority =>
      List<String>.unmodifiable(_platformPriority);
  bool get listenBrainzEnabled => _listenBrainzEnabled;
  String get lastFmApiKey => _lastFmApiKey;

  File? _resolvePrefsFile() {
    if (prefsFileOverride != null) return prefsFileOverride;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return null;

    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.trim().isNotEmpty) {
      final sep = Platform.pathSeparator;
      return File(
        '${localAppData.trim()}${sep}LuminaAudio${sep}recommendation_prefs.json',
      );
    }
    return File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}lumina_recommendation_prefs.json',
    );
  }

  static List<String> _sanitizePriority(Iterable<String> raw) {
    final seen = <String>{};
    final result = <String>[];
    for (final entry in raw) {
      final clean = entry.trim();
      if (clean.isNotEmpty && seen.add(clean)) {
        result.add(clean);
      }
    }
    return result.isEmpty
        ? List<String>.from(defaultPlatformPriority)
        : result;
  }

  /// Loads settings from disk and optional [SecureCredentialStore].
  Future<void> load() async {
    var changed = false;

    final file = _resolvePrefsFile();
    if (file != null) {
      try {
        if (await file.exists()) {
          final raw = await file.readAsString();
          if (raw.trim().isNotEmpty) {
            final decoded = jsonDecode(raw);
            if (decoded is Map) {
              final map = Map<String, dynamic>.from(decoded);
              if (map.containsKey('autoplay_enabled')) {
                _autoplayEnabled = map['autoplay_enabled'] != false;
              }
              if (map.containsKey('cross_platform_routing_enabled')) {
                _crossPlatformRoutingEnabled =
                    map['cross_platform_routing_enabled'] != false;
              }
              final rawPriority = map['platform_priority'];
              if (rawPriority is List) {
                _platformPriority = _sanitizePriority(
                  rawPriority.map((e) => e.toString()),
                );
              }
              if (map.containsKey('listen_brainz_enabled')) {
                _listenBrainzEnabled = map['listen_brainz_enabled'] != false;
              }
              changed = true;
            }
          }
        }
      } catch (_) {
        // Keep defaults gracefully if preferences file is unreadable.
      }
    }

    if (credentialStore != null) {
      try {
        final storedKey = await credentialStore!.read(
          lastFmApiKeyCredentialKey,
        );
        _lastFmApiKey = storedKey?.trim() ?? '';
        changed = true;
      } catch (_) {
        // Keep empty key if secure store read fails.
      }
    }

    if (changed) {
      notifyListeners();
    }
  }

  Future<void> _enqueueSave() {
    final snapshot = <String, dynamic>{
      'autoplay_enabled': _autoplayEnabled,
      'cross_platform_routing_enabled': _crossPlatformRoutingEnabled,
      'platform_priority': List<String>.from(_platformPriority),
      'listen_brainz_enabled': _listenBrainzEnabled,
    };

    _saveQueue = _saveQueue.then((_) async {
      final file = _resolvePrefsFile();
      if (file == null) return;
      try {
        final parent = file.parent;
        if (!await parent.exists()) {
          await parent.create(recursive: true);
        }
        final encoded = const JsonEncoder.withIndent('  ').convert(snapshot);
        final tmpFile = File('${file.path}.tmp');
        try {
          await tmpFile.writeAsString(encoded, flush: true);
          try {
            await tmpFile.rename(file.path);
          } catch (_) {
            if (await file.exists()) {
              await file.delete();
            }
            await tmpFile.rename(file.path);
          }
        } catch (_) {
          try {
            if (await tmpFile.exists()) {
              await tmpFile.delete();
            }
          } catch (_) {}
          await file.writeAsString(encoded, flush: true);
        }
      } catch (_) {
        // Ignore write errors without disturbing UI state.
      }
    });
    return _saveQueue;
  }

  Future<void> setAutoplayEnabled(bool value) {
    if (_autoplayEnabled == value) return _saveQueue;
    _autoplayEnabled = value;
    notifyListeners();
    return _enqueueSave();
  }

  Future<void> setCrossPlatformRoutingEnabled(bool value) {
    if (_crossPlatformRoutingEnabled == value) return _saveQueue;
    _crossPlatformRoutingEnabled = value;
    notifyListeners();
    return _enqueueSave();
  }

  Future<void> setPlatformPriority(List<String> priority) {
    final next = _sanitizePriority(priority);
    if (listEquals(_platformPriority, next)) return _saveQueue;
    _platformPriority = next;
    notifyListeners();
    return _enqueueSave();
  }

  /// Moves a platform entry from [oldIndex] to destination index [newIndex]
  /// (where both indices are in `0..platformPriority.length - 1`).
  Future<void> movePlatformPriority(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _platformPriority.length ||
        newIndex < 0 ||
        newIndex >= _platformPriority.length ||
        oldIndex == newIndex) {
      return _saveQueue;
    }
    final next = List<String>.from(_platformPriority);
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    _platformPriority = next;
    notifyListeners();
    return _enqueueSave();
  }

  Future<void> resetPlatformPriority() {
    return setPlatformPriority(defaultPlatformPriority);
  }

  Future<void> setListenBrainzEnabled(bool value) {
    if (_listenBrainzEnabled == value) return _saveQueue;
    _listenBrainzEnabled = value;
    notifyListeners();
    return _enqueueSave();
  }

  Future<void> setLastFmApiKey(String value) async {
    final trimmed = value.trim();
    final changed = _lastFmApiKey != trimmed;
    _lastFmApiKey = trimmed;
    if (changed) {
      notifyListeners();
    }
    if (credentialStore != null) {
      try {
        if (trimmed.isEmpty) {
          await credentialStore!.delete(lastFmApiKeyCredentialKey);
        } else {
          await credentialStore!.write(lastFmApiKeyCredentialKey, trimmed);
        }
      } catch (_) {
        // Ignore credential store errors so callers never crash.
      }
    }
  }
}
