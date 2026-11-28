import 'package:flutter/foundation.dart';

import '../models/studio/step4_models.dart';
import 'audio_service.dart';

/// Reactive controller managing DB-backed [SmartPlaylistItem]s via [AudioService].
class SmartPlaylistService extends ChangeNotifier {
  final AudioService audioService;
  final List<SmartPlaylistItem> _playlists = <SmartPlaylistItem>[];
  bool _loading = false;
  bool _loadedOnce = false;
  bool _disposed = false;

  SmartPlaylistService(this.audioService);

  List<SmartPlaylistItem> get playlists => List.unmodifiable(_playlists);

  List<SmartPlaylistItem> get pinnedPlaylists => List.unmodifiable(
    _playlists.where((p) => p.isPinned),
  );

  bool get loading => _loading;
  bool get loadedOnce => _loadedOnce;

  Future<void> load() async {
    if (_disposed) return;
    _loading = true;
    try {
      final items = await audioService.listSmartPlaylists();
      if (_disposed) return;
      _playlists
        ..clear()
        ..addAll(items);
      _loadedOnce = true;
    } catch (_) {
      // Keep existing state resilient on transient backend failures.
    } finally {
      _loading = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  Future<SmartPlaylistItem?> createPlaylist({
    required String name,
    String description = '',
    required String focusQueryJson,
    bool excludeBanned = true,
    int? limitCount,
    bool isPinned = true,
  }) async {
    final created = await audioService.createSmartPlaylist(
      name: name.trim(),
      description: description.trim(),
      focusQueryJson: focusQueryJson,
      excludeBanned: excludeBanned,
      limitCount: limitCount,
      isPinned: isPinned,
    );
    if (created != null && !_disposed) {
      await load();
    }
    return created;
  }

  Future<SmartPlaylistItem?> updatePlaylist(
    String id, {
    String? name,
    String? description,
    String? focusQueryJson,
    bool? excludeBanned,
    int? limitCount,
    bool clearLimitCount = false,
    bool? isPinned,
    int? sortOrder,
  }) async {
    final updated = await audioService.updateSmartPlaylist(
      id,
      name: name?.trim(),
      description: description?.trim(),
      focusQueryJson: focusQueryJson,
      excludeBanned: excludeBanned,
      limitCount: limitCount,
      clearLimitCount: clearLimitCount,
      isPinned: isPinned,
      sortOrder: sortOrder,
    );
    if (updated != null && !_disposed) {
      await load();
    }
    return updated;
  }

  Future<SmartPlaylistItem?> togglePin(SmartPlaylistItem item) {
    return updatePlaylist(item.id, isPinned: !item.isPinned);
  }

  Future<SmartPlaylistItem?> duplicatePlaylist(String id) async {
    final dup = await audioService.duplicateSmartPlaylist(id);
    if (dup != null && !_disposed) {
      await load();
    }
    return dup;
  }

  Future<bool> deletePlaylist(String id) async {
    final ok = await audioService.deleteSmartPlaylist(id);
    if (ok && !_disposed) {
      _playlists.removeWhere((p) => p.id == id);
      notifyListeners();
    }
    return ok;
  }

  Future<SmartPlaylistEvaluation?> evaluatePlaylist(String id) {
    return audioService.evaluateSmartPlaylist(id);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
