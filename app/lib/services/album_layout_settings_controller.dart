import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

enum AlbumViewMode { grid, list }

enum AlbumCoverSizePreset {
  compact(148.0, '緊湊'),
  standard(192.0, '標準'),
  large(248.0, '大圖');

  final double targetExtent;
  final String label;
  const AlbumCoverSizePreset(this.targetExtent, this.label);
}

enum AlbumGridSpacingPreset {
  narrow(10.0, '窄'),
  medium(18.0, '適中'),
  wide(28.0, '寬');

  final double spacing;
  final String label;
  const AlbumGridSpacingPreset(this.spacing, this.label);
}

class AlbumLayoutSettingsController extends ChangeNotifier {
  static const double minCoverExtent = 130.0;
  static const double maxCoverExtent = 280.0;
  static const double _defaultCoverExtent = 192.0;

  final File? prefsFileOverride;

  double _coverTargetExtent = _defaultCoverExtent;
  AlbumGridSpacingPreset _spacingPreset = AlbumGridSpacingPreset.medium;
  AlbumViewMode _viewMode = AlbumViewMode.grid;
  bool _showCardContainer = false;
  bool _showHiddenAlbums = false;
  bool _disposed = false;
  bool _isSaving = false;
  String? _pendingSavePayload;
  Completer<void>? _activeSaveCompleter;

  Future<void>? get currentSaveFuture => _activeSaveCompleter?.future;

  AlbumLayoutSettingsController({this.prefsFileOverride});

  double get coverTargetExtent => _coverTargetExtent;

  AlbumCoverSizePreset? get activeCoverPreset {
    for (final preset in AlbumCoverSizePreset.values) {
      if ((_coverTargetExtent - preset.targetExtent).abs() <= 4.0) {
        return preset;
      }
    }
    return null;
  }

  AlbumGridSpacingPreset get spacingPreset => _spacingPreset;

  double get spacing => _spacingPreset.spacing;

  AlbumViewMode get viewMode => _viewMode;

  bool get showCardContainer => _showCardContainer;

  bool get showHiddenAlbums => _showHiddenAlbums;

  bool get showHiddenItems => _showHiddenAlbums;

  void setShowHiddenItems(bool enabled) => setShowHiddenAlbums(enabled);

  int computeCrossAxisCount(double availableWidth) {
    if (!availableWidth.isFinite || availableWidth <= 0) {
      return 2;
    }
    return ((availableWidth + spacing) / (_coverTargetExtent + spacing))
        .floor()
        .clamp(2, 9);
  }

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
        '$localAppData${Platform.pathSeparator}LuminaAudio${Platform.pathSeparator}album_layout_prefs.json',
      );
    }
    return File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}lumina_album_layout_prefs.json',
    );
  }

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

      final rawExtent = (decoded['cover_target_extent'] as num?)?.toDouble();
      if (rawExtent != null && rawExtent.isFinite) {
        _coverTargetExtent =
            rawExtent.clamp(minCoverExtent, maxCoverExtent).toDouble();
      }

      final rawSpacing = decoded['spacing_preset']?.toString();
      if (rawSpacing != null) {
        for (final preset in AlbumGridSpacingPreset.values) {
          if (preset.name == rawSpacing) {
            _spacingPreset = preset;
            break;
          }
        }
      }

      final rawMode = decoded['view_mode']?.toString();
      if (rawMode != null) {
        for (final mode in AlbumViewMode.values) {
          if (mode.name == rawMode) {
            _viewMode = mode;
            break;
          }
        }
      }

      final rawShowCard = decoded['show_card_container'];
      if (rawShowCard is bool) {
        _showCardContainer = rawShowCard;
      }

      final rawShowHidden = decoded['show_hidden_albums'];
      if (rawShowHidden is bool) {
        _showHiddenAlbums = rawShowHidden;
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
      'cover_target_extent': _coverTargetExtent,
      'spacing_preset': _spacingPreset.name,
      'view_mode': _viewMode.name,
      'show_card_container': _showCardContainer,
      'show_hidden_albums': _showHiddenAlbums,
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

  void setCoverTargetExtent(double extent) {
    if (!extent.isFinite) return;
    final clamped = extent.clamp(minCoverExtent, maxCoverExtent).toDouble();
    if ((clamped - _coverTargetExtent).abs() < 0.001) return;
    _coverTargetExtent = clamped;
    notifyListeners();
    _save();
  }

  void setCoverSizePreset(AlbumCoverSizePreset preset) {
    setCoverTargetExtent(preset.targetExtent);
  }

  void setSpacingPreset(AlbumGridSpacingPreset preset) {
    if (_spacingPreset == preset) return;
    _spacingPreset = preset;
    notifyListeners();
    _save();
  }

  void setViewMode(AlbumViewMode mode) {
    if (_viewMode == mode) return;
    _viewMode = mode;
    notifyListeners();
    _save();
  }

  void setShowCardContainer(bool enabled) {
    if (_showCardContainer == enabled) return;
    _showCardContainer = enabled;
    notifyListeners();
    _save();
  }

  void setShowHiddenAlbums(bool enabled) {
    if (_showHiddenAlbums == enabled) return;
    _showHiddenAlbums = enabled;
    notifyListeners();
    _save();
  }

  void resetToDefaults() {
    final alreadyDefault =
        (_coverTargetExtent - _defaultCoverExtent).abs() < 0.001 &&
        _spacingPreset == AlbumGridSpacingPreset.medium &&
        _viewMode == AlbumViewMode.grid &&
        !_showCardContainer &&
        !_showHiddenAlbums;
    if (alreadyDefault) return;

    _coverTargetExtent = _defaultCoverExtent;
    _spacingPreset = AlbumGridSpacingPreset.medium;
    _viewMode = AlbumViewMode.grid;
    _showCardContainer = false;
    _showHiddenAlbums = false;
    notifyListeners();
    _save();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
