import 'package:flutter/foundation.dart';

import '../models/studio/step4_models.dart';
import 'audio_service.dart';

/// Reactive controller managing Dynamic Bookmarks persisted via [AudioService].
class BookmarksController extends ChangeNotifier {
  final AudioService audioService;
  final List<BookmarkItem> _bookmarks = <BookmarkItem>[];
  String? _activeBookmarkId;
  bool _loading = false;
  bool _disposed = false;

  BookmarksController(this.audioService);

  List<BookmarkItem> get bookmarks => List.unmodifiable(_bookmarks);
  String? get activeBookmarkId => _activeBookmarkId;
  bool get loading => _loading;

  void setActiveBookmarkId(String? id, {bool notify = true}) {
    if (_disposed || _activeBookmarkId == id) return;
    _activeBookmarkId = id;
    if (notify) {
      notifyListeners();
    }
  }

  BookmarkItem? findById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final b in _bookmarks) {
      if (b.id == id) return b;
    }
    return null;
  }

  Future<void> load() async {
    if (_disposed) return;
    _loading = true;
    try {
      final list = await audioService.listBookmarks();
      if (_disposed) return;
      _bookmarks
        ..clear()
        ..addAll(list);
    } catch (_) {
      // Keep current snapshot on transient error.
    } finally {
      _loading = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  Future<BookmarkItem?> create({
    required String name,
    required String targetRoute,
    String? focusQueryJson,
    String? viewStateJson,
  }) async {
    final created = await audioService.createBookmark(
      name: name.trim(),
      targetRoute: targetRoute,
      focusQueryJson: focusQueryJson,
      viewStateJson: viewStateJson,
    );
    if (created != null && !_disposed) {
      _activeBookmarkId = created.id;
      await load();
    }
    return created;
  }

  Future<BookmarkItem?> update(
    String id, {
    String? name,
    String? targetRoute,
    String? focusQueryJson,
    String? viewStateJson,
  }) async {
    final updated = await audioService.updateBookmark(
      id,
      name: name?.trim(),
      targetRoute: targetRoute,
      focusQueryJson: focusQueryJson,
      viewStateJson: viewStateJson,
    );
    if (updated != null && !_disposed) {
      await load();
    }
    return updated;
  }

  Future<bool> delete(String id) async {
    final ok = await audioService.deleteBookmark(id);
    if (ok && !_disposed) {
      _bookmarks.removeWhere((b) => b.id == id);
      notifyListeners();
    }
    return ok;
  }

  Future<bool> moveBookmark(String id, int delta) async {
    final idx = _bookmarks.indexWhere((b) => b.id == id);
    if (idx < 0) return false;
    final targetIdx = idx + delta;
    if (targetIdx < 0 || targetIdx >= _bookmarks.length) return false;
    final reordered = List<BookmarkItem>.from(_bookmarks);
    final moved = reordered.removeAt(idx);
    reordered.insert(targetIdx, moved);
    _bookmarks
      ..clear()
      ..addAll(reordered);
    notifyListeners();
    final ok = await audioService.reorderBookmarks(
      reordered.map((b) => b.id).toList(growable: false),
    );
    if (ok && !_disposed) {
      await load();
    }
    return ok;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
