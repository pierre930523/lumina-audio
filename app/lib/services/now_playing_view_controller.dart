import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

/// Display modes supported by the immersive Now Playing overlay.
enum NowPlayingViewMode { split, lyrics, cover }

/// Shared state controller for the Now Playing overlay, lyrics preferences,
/// and ephemeral per-session scrollable offsets.
class NowPlayingViewController extends ChangeNotifier {
  static const double minLyricsFontScale = 0.7;
  static const double maxLyricsFontScale = 1.6;
  static const double _defaultLyricsFontScale = 1.0;

  final File? prefsFileOverride;

  NowPlayingViewMode _mode = NowPlayingViewMode.split;
  double _lyricsFontScale = _defaultLyricsFontScale;
  bool _lyricsSettingsExpanded = false;
  bool _queueDrawerOpen = false;
  final Map<String, Duration> _lyricsDisplayOffsets = <String, Duration>{};
  final Map<String, double> _lyricsScrollOffsets = <String, double>{};
  double _queueScrollOffset = 0.0;
  bool _signalPathShowDetails = true;
  bool _disposed = false;
  bool _isSaving = false;
  String? _pendingSavePayload;
  Completer<void>? _activeSaveCompleter;

  Future<void>? get currentSaveFuture => _activeSaveCompleter?.future;

  NowPlayingViewController({this.prefsFileOverride});

  NowPlayingViewMode get mode => _mode;

  double get lyricsFontScale => _lyricsFontScale;

  bool get lyricsSettingsExpanded => _lyricsSettingsExpanded;

  bool get queueDrawerOpen => _queueDrawerOpen;

  double get queueScrollOffset => _queueScrollOffset;

  bool get signalPathShowDetails => _signalPathShowDetails;

  static String _trackKey(String? trackId) =>
      (trackId == null || trackId.isEmpty) ? '__default__' : trackId;

  Duration lyricsDisplayOffsetFor(String? trackId) =>
      _lyricsDisplayOffsets[_trackKey(trackId)] ?? Duration.zero;

  double lyricsScrollOffsetFor(String? trackId) =>
      _lyricsScrollOffsets[_trackKey(trackId)] ?? 0.0;

  File? _resolvePrefsFile() {
    if (prefsFileOverride != null) {
      return prefsFileOverride;
    }
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return null;
    }
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      return File(
        '$localAppData${Platform.pathSeparator}LuminaAudio${Platform.pathSeparator}now_playing_view_prefs.json',
      );
    }
    return File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}lumina_now_playing_view_prefs.json',
    );
  }

  /// Loads persisted view mode and lyrics font scale from disk, keeping
  /// defaults safely if the file is missing or corrupt.
  Future<void> load() async {
    final file = _resolvePrefsFile();
    if (file == null) return;

    try {
      final exists = prefsFileOverride != null
          ? file.existsSync()
          : await file.exists();
      if (!exists) return;

      final raw = prefsFileOverride != null
          ? file.readAsStringSync()
          : await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;

      final rawMode = decoded['mode']?.toString();
      if (rawMode != null) {
        for (final candidate in NowPlayingViewMode.values) {
          if (candidate.name == rawMode) {
            _mode = candidate;
            break;
          }
        }
      }

      final rawFontScale = decoded['lyrics_font_scale'];
      if (rawFontScale is num) {
        final value = rawFontScale.toDouble();
        if (value.isFinite) {
          _lyricsFontScale = value
              .clamp(minLyricsFontScale, maxLyricsFontScale)
              .toDouble();
        }
      }

      if (!_disposed) {
        notifyListeners();
      }
    } catch (_) {
      // Keep defaults gracefully on corrupt or unreadable preferences.
    }
  }

  void _save() {
    if (_disposed) return;
    final file = _resolvePrefsFile();
    if (file == null) return;

    final payload = jsonEncode({
      'mode': _mode.name,
      'lyrics_font_scale': _lyricsFontScale,
    });

    if (prefsFileOverride != null) {
      try {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(payload);
      } catch (_) {
        // Ignore write failures cleanly without blocking UI interaction.
      }
      return;
    }

    if (_isSaving) {
      _pendingSavePayload = payload;
      return;
    }

    _isSaving = true;
    _activeSaveCompleter = Completer<void>();
    _runSaveWorker(file, payload);
  }

  Future<void> _runSaveWorker(File file, String initialPayload) async {
    String? current = initialPayload;
    try {
      while (current != null && !_disposed) {
        final toSave = current;
        _pendingSavePayload = null;
        try {
          if (!await file.parent.exists()) {
            await file.parent.create(recursive: true);
          }
          await file.writeAsString(toSave);
        } catch (_) {
          // Ignore write failures cleanly without blocking UI interaction.
        }
        current = _pendingSavePayload;
      }
    } finally {
      _isSaving = false;
      _activeSaveCompleter?.complete();
      _activeSaveCompleter = null;
    }
  }

  void setMode(NowPlayingViewMode value) {
    if (_mode == value) return;
    _mode = value;
    if (!_disposed) {
      notifyListeners();
    }
    _save();
  }

  void setLyricsFontScale(double value) {
    if (!value.isFinite) return;
    final clamped = value
        .clamp(minLyricsFontScale, maxLyricsFontScale)
        .toDouble();
    if ((clamped - _lyricsFontScale).abs() < 0.001) return;
    _lyricsFontScale = clamped;
    if (!_disposed) {
      notifyListeners();
    }
    _save();
  }

  void setLyricsSettingsExpanded(bool expanded) {
    if (_lyricsSettingsExpanded == expanded) return;
    _lyricsSettingsExpanded = expanded;
    if (!_disposed) {
      notifyListeners();
    }
  }

  void setQueueDrawerOpen(bool open) {
    if (_queueDrawerOpen == open) return;
    _queueDrawerOpen = open;
    if (!_disposed) {
      notifyListeners();
    }
  }

  void toggleQueueDrawer() {
    setQueueDrawerOpen(!_queueDrawerOpen);
  }

  void setLyricsDisplayOffset(String? trackId, Duration offset) {
    final key = _trackKey(trackId);
    final current = _lyricsDisplayOffsets[key] ?? Duration.zero;
    if (current == offset) return;
    if (offset == Duration.zero) {
      _lyricsDisplayOffsets.remove(key);
    } else {
      _lyricsDisplayOffsets[key] = offset;
    }
    if (!_disposed) {
      notifyListeners();
    }
  }

  void saveLyricsScrollOffset(String? trackId, double offset) {
    if (!offset.isFinite) return;
    _lyricsScrollOffsets[_trackKey(trackId)] = offset < 0.0 ? 0.0 : offset;
  }

  void saveQueueScrollOffset(double offset) {
    if (!offset.isFinite) return;
    _queueScrollOffset = offset < 0.0 ? 0.0 : offset;
  }

  void setSignalPathShowDetails(bool value) {
    if (_signalPathShowDetails == value) return;
    _signalPathShowDetails = value;
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
