import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../models/home_layout_preset.dart';
import 'audio_service.dart';

class UiScaleController extends ChangeNotifier {
  static const double minScale = 0.75;
  static const double maxScale = 1.60;
  static const List<double> presets = [
    0.80,
    0.90,
    1.00,
    1.15,
    1.25,
    1.40,
    1.50,
  ];

  final File? prefsFileOverride;

  UiScaleController({
    this.prefsFileOverride,
    HomeLayoutPreset initialHomeLayoutPreset = HomeLayoutPreset.auraQuickResume,
    ThemeMode initialThemeMode = ThemeMode.dark,
  }) : _homeLayoutPreset = initialHomeLayoutPreset,
       _themeMode = initialThemeMode;

  double _scale = 1.0;
  bool _restoreOnStartup = true;
  bool _restoreOutputOnStartup = true;
  String? _lastOutputDeviceId;
  bool _rememberPlaybackPosition = true;
  bool _notifyOnResample = false;
  bool _enableAudioVisualizer = true;
  bool _minimizeToTrayOnClose = true;
  HomeLayoutPreset _homeLayoutPreset;
  ThemeMode _themeMode;
  bool _auraFollowCover = true;
  bool _minimalCoverMode = false;
  bool _disposed = false;

  double get scale => _scale;
  bool get restoreOnStartup => _restoreOnStartup;
  bool get restoreOutputOnStartup => _restoreOutputOnStartup;
  String? get lastOutputDeviceId => _lastOutputDeviceId;
  bool get rememberPlaybackPosition => _rememberPlaybackPosition;
  bool get notifyOnResample => _notifyOnResample;
  bool get enableAudioVisualizer => _enableAudioVisualizer;
  bool get minimizeToTrayOnClose => _minimizeToTrayOnClose;
  HomeLayoutPreset get homeLayoutPreset => _homeLayoutPreset;
  ThemeMode get themeMode => _themeMode;
  bool get auraFollowCover => _auraFollowCover;
  bool get minimalCoverMode => _minimalCoverMode;
  int get percentage => (_scale * 100).round();

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  File? _prefsFile() {
    if (prefsFileOverride != null) return prefsFileOverride;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return null;
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      return File(
        '$localAppData${Platform.pathSeparator}LuminaAudio${Platform.pathSeparator}ui_prefs.json',
      );
    }
    return File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}lumina_ui_prefs.json',
    );
  }

  static ThemeMode _parseThemeMode(dynamic raw, ThemeMode fallback) {
    if (raw is! String) return fallback;
    return switch (raw.trim().toLowerCase()) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => fallback,
    };
  }

  ({bool changed, bool migratedPreset}) _applyDecodedPrefs(
    Map<String, dynamic> decoded,
  ) {
    final prevScale = _scale;
    final prevRestoreOnStartup = _restoreOnStartup;
    final prevRestoreOutputOnStartup = _restoreOutputOnStartup;
    final prevLastOutputDeviceId = _lastOutputDeviceId;
    final prevRememberPlaybackPosition = _rememberPlaybackPosition;
    final prevNotifyOnResample = _notifyOnResample;
    final prevEnableAudioVisualizer = _enableAudioVisualizer;
    final prevMinimizeToTrayOnClose = _minimizeToTrayOnClose;
    final prevHomeLayoutPreset = _homeLayoutPreset;
    final prevThemeMode = _themeMode;
    final prevAuraFollowCover = _auraFollowCover;
    final prevMinimalCoverMode = _minimalCoverMode;

    final restore = decoded['restore_on_startup'] != false;
    final savedScale = (decoded['scale'] as num?)?.toDouble();
    _restoreOnStartup = restore;
    if (restore && savedScale != null) {
      _scale = savedScale.clamp(minScale, maxScale).toDouble();
    }
    _restoreOutputOnStartup = decoded['restore_output_on_startup'] != false;
    _lastOutputDeviceId = decoded['last_output_device_id']?.toString();
    _rememberPlaybackPosition = decoded['remember_playback_position'] != false;
    _notifyOnResample = decoded['notify_on_resample'] == true;
    final visualizerVal =
        decoded['enableAudioVisualizer'] ?? decoded['enable_audio_visualizer'];
    _enableAudioVisualizer = visualizerVal is bool ? visualizerVal : true;
    final minimizeToTrayVal =
        decoded['minimize_to_tray_on_close'] ??
        decoded['minimizeToTrayOnClose'];
    _minimizeToTrayOnClose =
        minimizeToTrayVal is bool ? minimizeToTrayVal : true;

    var migratedPreset = false;
    final hasPresetKey =
        decoded.containsKey('homeLayoutPreset') ||
        decoded.containsKey('home_layout_preset');
    final presetVal =
        decoded['homeLayoutPreset'] ?? decoded['home_layout_preset'];
    if (hasPresetKey) {
      final parsed = presetVal is String
          ? HomeLayoutPreset.tryParseStorageKey(presetVal)
          : null;
      if (parsed != null) {
        _homeLayoutPreset = parsed;
      } else {
        // Migrate deprecated 'frosted-minimal' or invalid preset keys to AJ.
        _homeLayoutPreset = HomeLayoutPreset.auraQuickResume;
        migratedPreset = true;
      }
    }
    final themeModeVal = decoded['themeMode'] ?? decoded['theme_mode'];
    if (themeModeVal != null) {
      _themeMode = _parseThemeMode(themeModeVal, _themeMode);
    }
    final auraFollowVal =
        decoded['auraFollowCover'] ?? decoded['aura_follow_cover'];
    if (auraFollowVal is bool) {
      _auraFollowCover = auraFollowVal;
    } else if (auraFollowVal != null) {
      _auraFollowCover = true;
    }
    final minimalCoverVal =
        decoded['minimalCoverMode'] ?? decoded['minimal_cover_mode'];
    if (minimalCoverVal is bool) {
      _minimalCoverMode = minimalCoverVal;
    } else if (minimalCoverVal != null) {
      _minimalCoverMode = false;
    }

    final changed =
        prevScale != _scale ||
        prevRestoreOnStartup != _restoreOnStartup ||
        prevRestoreOutputOnStartup != _restoreOutputOnStartup ||
        prevLastOutputDeviceId != _lastOutputDeviceId ||
        prevRememberPlaybackPosition != _rememberPlaybackPosition ||
        prevNotifyOnResample != _notifyOnResample ||
        prevEnableAudioVisualizer != _enableAudioVisualizer ||
        prevMinimizeToTrayOnClose != _minimizeToTrayOnClose ||
        prevHomeLayoutPreset != _homeLayoutPreset ||
        prevThemeMode != _themeMode ||
        prevAuraFollowCover != _auraFollowCover ||
        prevMinimalCoverMode != _minimalCoverMode;
    return (changed: changed, migratedPreset: migratedPreset);
  }

  /// Synchronously reads persisted UI preferences before frame 0 to prevent
  /// theme/layout flash of unstyled content (FOUC).
  void loadSync() {
    final file = _prefsFile();
    if (file == null) return;
    try {
      if (!file.existsSync()) return;
      final raw = file.readAsStringSync();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final result = _applyDecodedPrefs(decoded);
        if (result.migratedPreset) {
          _saveSyncBestEffort();
        }
      }
    } catch (_) {
      // Keep defaults gracefully on unreadable preferences.
    }
  }

  Future<void> load({AudioService? audioService}) async {
    final file = _prefsFile();
    if (file == null) {
      return;
    }
    try {
      final exists = prefsFileOverride != null
          ? file.existsSync()
          : await file.exists();
      if (_disposed) return;
      if (exists) {
        final raw = prefsFileOverride != null
            ? file.readAsStringSync()
            : await file.readAsString();
        if (_disposed) return;
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          final result = _applyDecodedPrefs(decoded);
          if (result.migratedPreset) {
            await _save();
            if (_disposed) return;
          }
          if (result.changed) {
            // Yield a microtask so synchronous prefsFileOverride loads invoked
            // during initState/build never call notifyListeners() synchronously.
            await Future<void>.value();
            if (!_disposed) {
              notifyListeners();
            }
          }
        }
      }
      if (!_disposed &&
          audioService != null &&
          _restoreOutputOnStartup &&
          _lastOutputDeviceId != null &&
          _lastOutputDeviceId!.isNotEmpty) {
        final devs = await audioService.listAudioDevices();
        if (_disposed) return;
        final match = devs.where((d) => d.id == _lastOutputDeviceId).firstOrNull;
        if (match != null) {
          await audioService.selectAudioDevice(match.id);
        }
      }
    } catch (_) {
      // Keep defaults gracefully on unreadable preferences.
    }
  }

  String _encodePayload() {
    return jsonEncode({
      'scale': double.parse(_scale.toStringAsFixed(2)),
      'restore_on_startup': _restoreOnStartup,
      'restore_output_on_startup': _restoreOutputOnStartup,
      'last_output_device_id': _lastOutputDeviceId,
      'remember_playback_position': _rememberPlaybackPosition,
      'notify_on_resample': _notifyOnResample,
      'enableAudioVisualizer': _enableAudioVisualizer,
      'minimize_to_tray_on_close': _minimizeToTrayOnClose,
      'homeLayoutPreset': _homeLayoutPreset.storageKey,
      'themeMode': _themeMode.name,
      'auraFollowCover': _auraFollowCover,
      'minimalCoverMode': _minimalCoverMode,
    });
  }

  void _saveSyncBestEffort() {
    final file = _prefsFile();
    if (file == null) return;
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(_encodePayload());
    } catch (_) {
      // Ignore write failures cleanly without blocking UI startup.
    }
  }

  Future<void> _save() async {
    final file = _prefsFile();
    if (file == null) {
      return;
    }
    try {
      final payload = _encodePayload();
      if (prefsFileOverride != null) {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(payload);
        return;
      }
      await file.parent.create(recursive: true);
      await file.writeAsString(payload);
    } catch (_) {
      // Ignore write failures cleanly without blocking UI interaction.
    }
  }

  void setScale(double next) {
    final clamped =
        double.parse(next.clamp(minScale, maxScale).toStringAsFixed(2));
    if ((clamped - _scale).abs() < 0.005) return;
    _scale = clamped;
    notifyListeners();
    _save();
  }

  void stepBy(double delta) => setScale(_scale + delta);

  void reset() => setScale(1.0);

  void setRestoreOnStartup(bool enabled) {
    if (_restoreOnStartup == enabled) return;
    _restoreOnStartup = enabled;
    notifyListeners();
    _save();
  }

  void setRestoreOutputOnStartup(bool enabled) {
    if (_restoreOutputOnStartup == enabled) return;
    _restoreOutputOnStartup = enabled;
    notifyListeners();
    _save();
  }

  void setLastOutputDeviceId(String? deviceId) {
    if (_lastOutputDeviceId == deviceId) return;
    _lastOutputDeviceId = deviceId;
    notifyListeners();
    _save();
  }

  void setRememberPlaybackPosition(bool enabled) {
    if (_rememberPlaybackPosition == enabled) return;
    _rememberPlaybackPosition = enabled;
    notifyListeners();
    _save();
  }

  void setNotifyOnResample(bool enabled) {
    if (_notifyOnResample == enabled) return;
    _notifyOnResample = enabled;
    notifyListeners();
    _save();
  }

  void setEnableAudioVisualizer(bool enabled) {
    if (_enableAudioVisualizer == enabled) return;
    _enableAudioVisualizer = enabled;
    notifyListeners();
    _save();
  }

  void setMinimizeToTrayOnClose(bool enabled) {
    if (_minimizeToTrayOnClose == enabled) return;
    _minimizeToTrayOnClose = enabled;
    notifyListeners();
    _save();
  }

  void setHomeLayoutPreset(HomeLayoutPreset preset) {
    if (_homeLayoutPreset == preset) return;
    _homeLayoutPreset = preset;
    notifyListeners();
    _save();
  }

  void setThemeMode(ThemeMode mode) {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    _save();
  }

  void setAuraFollowCover(bool enabled) {
    if (_auraFollowCover == enabled) return;
    _auraFollowCover = enabled;
    notifyListeners();
    _save();
  }

  void setMinimalCoverMode(bool enabled) {
    if (_minimalCoverMode == enabled) return;
    _minimalCoverMode = enabled;
    notifyListeners();
    _save();
  }
}
