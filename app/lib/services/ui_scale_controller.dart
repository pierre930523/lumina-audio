import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

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

  UiScaleController({this.prefsFileOverride});

  double _scale = 1.0;
  bool _restoreOnStartup = true;
  bool _restoreOutputOnStartup = true;
  String? _lastOutputDeviceId;
  bool _rememberPlaybackPosition = true;
  bool _notifyOnResample = false;
  bool _enableAudioVisualizer = true;
  bool _minimizeToTrayOnClose = true;

  double get scale => _scale;
  bool get restoreOnStartup => _restoreOnStartup;
  bool get restoreOutputOnStartup => _restoreOutputOnStartup;
  String? get lastOutputDeviceId => _lastOutputDeviceId;
  bool get rememberPlaybackPosition => _rememberPlaybackPosition;
  bool get notifyOnResample => _notifyOnResample;
  bool get enableAudioVisualizer => _enableAudioVisualizer;
  bool get minimizeToTrayOnClose => _minimizeToTrayOnClose;
  int get percentage => (_scale * 100).round();

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

  Future<void> load({AudioService? audioService}) async {
    final file = _prefsFile();
    if (file == null) {
      return;
    }
    try {
      final exists = prefsFileOverride != null
          ? file.existsSync()
          : await file.exists();
      if (exists) {
        final raw = prefsFileOverride != null
            ? file.readAsStringSync()
            : await file.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          final restore = decoded['restore_on_startup'] != false;
          final savedScale = (decoded['scale'] as num?)?.toDouble();
          _restoreOnStartup = restore;
          if (restore && savedScale != null) {
            _scale = savedScale.clamp(minScale, maxScale).toDouble();
          }
          _restoreOutputOnStartup =
              decoded['restore_output_on_startup'] != false;
          _lastOutputDeviceId = decoded['last_output_device_id']?.toString();
          _rememberPlaybackPosition =
              decoded['remember_playback_position'] != false;
          _notifyOnResample = decoded['notify_on_resample'] == true;
          final visualizerVal =
              decoded['enableAudioVisualizer'] ?? decoded['enable_audio_visualizer'];
          _enableAudioVisualizer = visualizerVal is bool ? visualizerVal : true;
          final minimizeToTrayVal =
              decoded['minimize_to_tray_on_close'] ??
              decoded['minimizeToTrayOnClose'];
          _minimizeToTrayOnClose =
              minimizeToTrayVal is bool ? minimizeToTrayVal : true;
          notifyListeners();
        }
      }
      if (audioService != null &&
          _restoreOutputOnStartup &&
          _lastOutputDeviceId != null &&
          _lastOutputDeviceId!.isNotEmpty) {
        final devs = await audioService.listAudioDevices();
        final match = devs.where((d) => d.id == _lastOutputDeviceId).firstOrNull;
        if (match != null) {
          await audioService.selectAudioDevice(match.id);
        }
      }
    } catch (_) {
      // Keep defaults gracefully on unreadable preferences.
    }
  }

  Future<void> _save() async {
    final file = _prefsFile();
    if (file == null) {
      return;
    }
    try {
      final payload = jsonEncode({
        'scale': double.parse(_scale.toStringAsFixed(2)),
        'restore_on_startup': _restoreOnStartup,
        'restore_output_on_startup': _restoreOutputOnStartup,
        'last_output_device_id': _lastOutputDeviceId,
        'remember_playback_position': _rememberPlaybackPosition,
        'notify_on_resample': _notifyOnResample,
        'enableAudioVisualizer': _enableAudioVisualizer,
        'minimize_to_tray_on_close': _minimizeToTrayOnClose,
      });
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
}
