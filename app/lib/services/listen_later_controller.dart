import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/playback_state.dart';
import '../models/recommendation_models.dart';
import '../models/streaming_models.dart';
import '../models/studio_models.dart';
import 'audio_service.dart';

/// Reactive controller managing Listen Later queue items (library + external
/// streaming snapshots), pending badge count, and external-to-library promotion.
class ListenLaterController extends ChangeNotifier {
  final AudioService audioService;
  final List<ListenLaterItem> _items = <ListenLaterItem>[];
  bool _loading = false;
  bool _disposed = false;

  ListenLaterController(this.audioService);

  List<ListenLaterItem> get allItems => List.unmodifiable(_items);

  List<ListenLaterItem> get pendingItems =>
      List.unmodifiable(_items.where((it) => it.isPending));

  List<ListenLaterItem> get listenedItems =>
      List.unmodifiable(_items.where((it) => it.isListened));

  int get pendingCount => _items.where((it) => it.isPending).length;

  bool get loading => _loading;

  bool isSaved({
    required String entityType,
    String? entityId,
    String? providerId,
    String? externalId,
  }) {
    for (final it in _items) {
      if (it.entityType != entityType) continue;
      if (entityId != null &&
          entityId.isNotEmpty &&
          it.sourceKind == 'library' &&
          it.entityId == entityId) {
        return true;
      }
      if (providerId != null &&
          externalId != null &&
          providerId.isNotEmpty &&
          externalId.isNotEmpty &&
          it.sourceKind == 'external' &&
          it.providerId?.toLowerCase() == providerId.toLowerCase() &&
          it.externalId == externalId) {
        return true;
      }
    }
    return false;
  }

  Future<void> refresh() async {
    if (_disposed) return;
    _loading = true;
    try {
      final list = await audioService.listListenLater();
      if (_disposed) return;
      _items
        ..clear()
        ..addAll(list);
    } catch (_) {
      // Keep existing snapshot on transient error.
    } finally {
      _loading = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  Future<ListenLaterItem?> add({
    required String sourceKind,
    required String entityType,
    String? entityId,
    String? providerId,
    String? externalId,
    required String title,
    String artistName = '',
    String albumTitle = '',
    String? coverUrl,
    int? trackCount,
    String? metadataJson,
    String note = '',
  }) async {
    final created = await audioService.addToListenLater(
      sourceKind: sourceKind,
      entityType: entityType,
      entityId: entityId,
      providerId: providerId,
      externalId: externalId,
      title: title,
      artistName: artistName,
      albumTitle: albumTitle,
      coverUrl: coverUrl,
      trackCount: trackCount,
      metadataJson: metadataJson,
      note: note,
    );
    if (created != null && !_disposed) {
      final idx = _items.indexWhere((it) => it.id == created.id);
      if (idx >= 0) {
        _items[idx] = created;
      } else {
        _items.insert(0, created);
      }
      notifyListeners();
    }
    return created;
  }

  Future<ListenLaterItem?> addLocalAlbum(CanonicalAlbumSummary album) {
    return add(
      sourceKind: 'library',
      entityType: 'album',
      entityId: album.effectiveGroupId,
      title: album.title,
      artistName: album.artist,
      albumTitle: album.title,
      coverUrl: album.coverUrl,
      trackCount: album.trackCount,
    );
  }

  Future<ListenLaterItem?> addLocalTrack(TrackInfo track) {
    return add(
      sourceKind: 'library',
      entityType: 'track',
      entityId: track.id,
      title: track.title,
      artistName: track.artist,
      albumTitle: track.album,
      coverUrl: track.artworkUrl,
    );
  }

  Future<ListenLaterItem?> addStreamingAlbum(
    StreamingAlbum album, {
    CanonicalAlbumDetail? detail,
  }) {
    final ver = detail?.versions.where((v) => v.tracks.isNotEmpty).firstOrNull;
    final embeddedTracks = ver?.tracks
        .map(
          (t) => <String, dynamic>{
            'external_track_id': t.externalTrackId.isNotEmpty
                ? t.externalTrackId
                : t.id,
            'title': t.title,
            'artist_name': detail?.artistName ?? album.artist,
            'disc_number': t.discNumber,
            'track_number': t.trackNumber,
            'duration_ms': t.durationMs,
            'codec': t.codec,
            'sample_rate_hz': t.sampleRateHz,
            'bit_depth': t.bitDepth,
          },
        )
        .toList(growable: false);
    final meta = <String, dynamic>{
      if (album.year != null) 'year': album.year,
      if (album.qualityLabel != null) 'quality_label': album.qualityLabel,
      if (album.trackCount != null) 'track_count': album.trackCount,
      if (embeddedTracks != null && embeddedTracks.isNotEmpty)
        'tracks': embeddedTracks,
    };
    return add(
      sourceKind: 'external',
      entityType: 'album',
      providerId: album.providerKind,
      externalId: album.id,
      title: album.title,
      artistName: album.artist,
      albumTitle: album.title,
      coverUrl: album.coverUrl,
      trackCount: album.trackCount ?? ver?.tracks.length,
      metadataJson: jsonEncode(meta),
    );
  }

  Future<ListenLaterItem?> addStreamingTrack(TrackInfo track) {
    final meta = TrackMetadata.fromTrackInfo(track);
    final payload = <String, dynamic>{
      'duration_ms': track.duration.inMilliseconds,
      'codec': track.format.codec.name,
      'sample_rate_hz': track.format.sampleRateHz,
      'bit_depth': track.format.bitDepth,
      if (track.isrc != null) 'isrc': track.isrc,
      if (track.genre != null) 'genre': track.genre,
      if (track.composer != null) 'composer': track.composer,
      if (track.trackNumber != null) 'track_number': track.trackNumber,
      if (track.discNumber != null) 'disc_number': track.discNumber,
      if (track.year != null) 'year': track.year,
      if (track.externalAlbumId != null)
        'external_album_id': track.externalAlbumId,
    };
    return add(
      sourceKind: 'external',
      entityType: 'track',
      providerId: meta.providerId,
      externalId: meta.trackId,
      title: track.title,
      artistName: track.artist,
      albumTitle: track.album,
      coverUrl: track.artworkUrl,
      metadataJson: jsonEncode(payload),
    );
  }

  Future<ListenLaterItem?> markStatus(String id, String status) async {
    final updated = await audioService.markListenLaterStatus(id, status);
    if (updated != null && !_disposed) {
      _replaceItem(updated);
    }
    return updated;
  }

  Future<ListenLaterItem?> updateNote(String id, String note) async {
    final updated = await audioService.updateListenLaterNote(id, note);
    if (updated != null && !_disposed) {
      _replaceItem(updated);
    }
    return updated;
  }

  Future<bool> remove(String id) async {
    final ok = await audioService.removeListenLater(id);
    if (ok && !_disposed) {
      _items.removeWhere((it) => it.id == id);
      notifyListeners();
    }
    return ok;
  }

  Future<PromoteListenLaterResult?> promote(String id) async {
    final res = await audioService.promoteExternalToLibrary(id);
    if (res != null && !_disposed) {
      _replaceItem(res.item);
    }
    return res;
  }

  void applyAutoMarkedItem(ListenLaterItem updated) {
    if (_disposed) return;
    _replaceItem(updated);
  }

  void _replaceItem(ListenLaterItem updated) {
    final idx = _items.indexWhere((it) => it.id == updated.id);
    if (idx >= 0) {
      _items[idx] = updated;
    } else {
      _items.insert(0, updated);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
