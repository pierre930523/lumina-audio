import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../models/smart_playlist.dart';

class SmartPlaylistService extends ChangeNotifier {
  final List<SmartPlaylist> _playlists = List<SmartPlaylist>.from(
    SmartPlaylist.builtInPresets,
  );

  List<SmartPlaylist> get playlists => List.unmodifiable(_playlists);

  File _storageFile() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      return File(
        '$localAppData${Platform.pathSeparator}LuminaAudio${Platform.pathSeparator}smart_playlists.json',
      );
    }
    return File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}lumina_smart_playlists.json',
    );
  }

  Future<void> load() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }
    try {
      final file = _storageFile();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return;
      final custom = decoded
          .whereType<Map<String, dynamic>>()
          .map(SmartPlaylist.fromJson)
          .where((p) => !p.isBuiltIn && p.id.isNotEmpty)
          .toList();
      _playlists
        ..clear()
        ..addAll(SmartPlaylist.builtInPresets)
        ..addAll(custom);
      notifyListeners();
    } catch (_) {
      // Keep default built-in presets cleanly if unreadable.
    }
  }

  Future<void> _save() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return;
    }
    try {
      final file = _storageFile();
      await file.parent.create(recursive: true);
      final customOnly = _playlists.where((p) => !p.isBuiltIn).toList();
      await file.writeAsString(
        jsonEncode(customOnly.map((p) => p.toJson()).toList()),
      );
    } catch (_) {
      // Ignore write failure without interrupting UI state.
    }
  }

  SmartPlaylist createPlaylist({
    required String name,
    String description = '',
    bool losslessOnly = false,
    bool dsdOnly = false,
    int minSampleRateHz = 0,
    int minBitDepth = 0,
    String keyword = '',
  }) {
    final created = SmartPlaylist(
      id: 'sp-custom-${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim(),
      description: description.trim(),
      isBuiltIn: false,
      losslessOnly: losslessOnly,
      dsdOnly: dsdOnly,
      minSampleRateHz: minSampleRateHz,
      minBitDepth: minBitDepth,
      keyword: keyword.trim(),
    );
    _playlists.add(created);
    notifyListeners();
    _save();
    return created;
  }

  void updatePlaylist(SmartPlaylist updated) {
    final idx = _playlists.indexWhere((p) => p.id == updated.id);
    if (idx < 0) return;
    _playlists[idx] = updated;
    notifyListeners();
    _save();
  }

  void deletePlaylist(String id) {
    _playlists.removeWhere((p) => p.id == id && !p.isBuiltIn);
    notifyListeners();
    _save();
  }
}
