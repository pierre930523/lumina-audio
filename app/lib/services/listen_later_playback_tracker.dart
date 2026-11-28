import 'dart:async';

import '../models/playback_state.dart';
import '../models/recommendation_models.dart';
import '../models/studio_models.dart';
import 'audio_service.dart';
import 'library_settings_controller.dart';

/// Watches [AudioService.stateStream] and [AudioService.positionStream] and
/// automatically marks pending [ListenLaterItem]s as `listened` when:
/// - A matching track reaches `> 70%` played (or ends), OR
/// - Strictly `> 50%` of distinct tracks in a matching album have been played.
///
/// Controlled by [LibrarySettingsController.autoMarkListenLaterListened]
/// (default `true`).
class ListenLaterPlaybackTracker {
  static const double trackCompletionThreshold = 0.70;
  static const double albumCompletionThreshold = 0.50;

  final AudioService audioService;
  final LibrarySettingsController settings;
  final void Function(ListenLaterItem item)? onAutoMarkedListened;

  StreamSubscription<PlaybackState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;

  String? _activeTrackId;
  int _trackSessionSeq = 0;
  Duration _lastKnownDuration = Duration.zero;
  bool _currentSessionQualified = false;

  final Map<String, Set<String>> _playedTrackIdsByAlbumItemId =
      <String, Set<String>>{};
  final Map<String, int> _resolvedAlbumTrackCounts = <String, int>{};
  final Set<String> _inFlightItemIds = <String>{};
  Future<void> _evalChain = Future<void>.value();
  bool _disposed = false;

  ListenLaterPlaybackTracker({
    required this.audioService,
    required this.settings,
    this.onAutoMarkedListened,
  }) {
    _stateSub = audioService.stateStream.listen(_onPlaybackState);
    _positionSub = audioService.positionStream.listen(_onPositionTick);
    _onPlaybackState(audioService.currentState);
  }

  /// Resolves when all queued Listen Later progress evaluations have settled.
  Future<void> flushPendingChecks() => _evalChain;

  /// Clears in-memory album progress tracking (useful for tests or resets).
  void resetSessionProgress() {
    _playedTrackIdsByAlbumItemId.clear();
    _resolvedAlbumTrackCounts.clear();
    _currentSessionQualified = false;
  }

  void _onPlaybackState(PlaybackState state) {
    if (_disposed) return;
    final track = state.track;
    final nextTrackId = track?.id;

    if (nextTrackId != _activeTrackId) {
      _activeTrackId = nextTrackId;
      _trackSessionSeq++;
      _currentSessionQualified = false;
      _lastKnownDuration = track?.duration ?? Duration.zero;
    } else if (track != null && track.duration > Duration.zero) {
      _lastKnownDuration = track.duration;
    }

    if (track == null || !settings.autoMarkListenLaterListened) return;

    if (state.status == PlaybackStatus.ended) {
      _qualifyCurrentTrack(track);
      return;
    }
    if (state.status == PlaybackStatus.playing) {
      _checkProgressThreshold(track, state.position);
    }
  }

  void _onPositionTick(Duration position) {
    if (_disposed || !settings.autoMarkListenLaterListened) return;
    final state = audioService.currentState;
    final track = state.track;
    if (track == null || state.status != PlaybackStatus.playing) return;
    if (track.id != _activeTrackId) {
      _activeTrackId = track.id;
      _trackSessionSeq++;
      _currentSessionQualified = false;
      _lastKnownDuration = track.duration;
    } else if (track.duration > Duration.zero) {
      _lastKnownDuration = track.duration;
    }
    _checkProgressThreshold(track, position);
  }

  void _checkProgressThreshold(TrackInfo track, Duration position) {
    if (_currentSessionQualified) return;
    final duration = track.duration > Duration.zero
        ? track.duration
        : _lastKnownDuration;
    if (duration <= Duration.zero || position <= Duration.zero) return;
    final ratio = position.inMilliseconds / duration.inMilliseconds;
    if (ratio > trackCompletionThreshold) {
      _qualifyCurrentTrack(track);
    }
  }

  void _qualifyCurrentTrack(TrackInfo track) {
    if (_currentSessionQualified || _disposed) return;
    _currentSessionQualified = true;
    final capturedSession = _trackSessionSeq;
    _evalChain = _evalChain.then(
      (_) => _evaluateQualifiedTrack(track, capturedSession),
    );
  }

  Future<void> _evaluateQualifiedTrack(
    TrackInfo track,
    int capturedSession,
  ) async {
    if (_disposed || !settings.autoMarkListenLaterListened) return;
    // Note: intentionally continue even if playback moved on while async DB
    // lookup was running, since this track already crossed >70% or ended.
    final _ = capturedSession;

    final List<ListenLaterItem> pending;
    try {
      pending = await audioService.listListenLater(status: 'pending');
    } catch (_) {
      return;
    }
    if (_disposed || pending.isEmpty) return;

    for (final item in pending) {
      if (_disposed || !item.isPending || _inFlightItemIds.contains(item.id)) {
        continue;
      }
      if (item.isTrack && _matchesTrackItem(item, track)) {
        await _markListened(item);
        continue;
      }
      if (item.isAlbum && _matchesAlbumItem(item, track)) {
        final played = _playedTrackIdsByAlbumItemId.putIfAbsent(
          item.id,
          () => <String>{},
        );
        final trackKey = _canonicalTrackKey(track);
        played.add(trackKey);

        final totalTracks = await _resolveTotalTrackCount(item);
        if (_disposed) return;
        if (totalTracks != null &&
            totalTracks > 0 &&
            (played.length / totalTracks) > albumCompletionThreshold) {
          await _markListened(item);
        }
      }
    }
  }

  Future<void> _markListened(ListenLaterItem item) async {
    if (_inFlightItemIds.contains(item.id)) return;
    _inFlightItemIds.add(item.id);
    try {
      final updated = await audioService.markListenLaterStatus(
        item.id,
        'listened',
      );
      if (updated != null && !_disposed) {
        _playedTrackIdsByAlbumItemId.remove(item.id);
        onAutoMarkedListened?.call(updated);
      }
    } catch (_) {
      // Keep playback tracker resilient against transient backend failures.
    } finally {
      _inFlightItemIds.remove(item.id);
    }
  }

  Future<int?> _resolveTotalTrackCount(ListenLaterItem item) async {
    if (item.trackCount != null && item.trackCount! > 0) {
      return item.trackCount;
    }
    final cached = _resolvedAlbumTrackCounts[item.id];
    if (cached != null && cached > 0) return cached;

    final meta = item.parseMetadata();
    final metaCount = (meta?['track_count'] as num?)?.toInt();
    if (metaCount != null && metaCount > 0) {
      _resolvedAlbumTrackCounts[item.id] = metaCount;
      return metaCount;
    }

    if (item.isLibrary &&
        item.entityId != null &&
        item.entityId!.trim().isNotEmpty) {
      try {
        final detail = await audioService.getAlbumDetail(item.entityId!);
        final ver =
            detail?.versions.where((v) => v.isPrimary).firstOrNull ??
            detail?.versions.firstOrNull;
        final count = ver?.effectiveTrackCount;
        if (count != null && count > 0) {
          _resolvedAlbumTrackCounts[item.id] = count;
          return count;
        }
      } catch (_) {}
    }
    return null;
  }

  static String _canonicalTrackKey(TrackInfo track) {
    if (track.id.trim().isNotEmpty) return track.id.trim();
    return '${_norm(track.album)}::${_norm(track.title)}::${track.trackNumber ?? 0}';
  }

  static String _norm(String? raw) => (raw ?? '').trim().toLowerCase();

  static bool _matchesTrackItem(ListenLaterItem item, TrackInfo track) {
    if (item.isLibrary) {
      final eid = item.entityId?.trim() ?? '';
      return eid.isNotEmpty && eid == track.id.trim();
    }
    final extId = item.externalId?.trim() ?? '';
    if (extId.isEmpty) return false;
    final meta = TrackMetadata.fromTrackInfo(track);
    final itemProvider = _norm(item.providerId);
    final trackProvider = _norm(meta.providerId);
    if (itemProvider.isNotEmpty &&
        trackProvider.isNotEmpty &&
        itemProvider != trackProvider &&
        trackProvider != 'local') {
      return false;
    }
    if (track.id.trim() == extId || meta.trackId.trim() == extId) {
      return true;
    }
    if (itemProvider.isNotEmpty &&
        track.id.trim().toLowerCase() == '$itemProvider:${extId.toLowerCase()}') {
      return true;
    }
    return false;
  }

  static bool _matchesAlbumItem(ListenLaterItem item, TrackInfo track) {
    if (item.isLibrary) {
      final eid = item.entityId?.trim() ?? '';
      if (eid.isNotEmpty &&
          track.albumGroupId != null &&
          track.albumGroupId!.trim() == eid) {
        return true;
      }
      final itemTitle = _norm(
        item.albumTitle.trim().isNotEmpty ? item.albumTitle : item.title,
      );
      final trackAlbum = _norm(track.album);
      if (itemTitle.isEmpty || trackAlbum.isEmpty) return false;
      final titleMatches =
          trackAlbum == itemTitle || trackAlbum.startsWith('$itemTitle (');
      if (!titleMatches) return false;
      final itemArtist = _norm(item.artistName);
      if (itemArtist.isEmpty) return true;
      return _norm(track.effectiveAlbumArtist) == itemArtist ||
          _norm(track.artist) == itemArtist;
    }

    // External streaming album matching: prefer explicit externalAlbumId, then
    // provider + normalized (album, artist) match.
    final extAlbId = item.externalId?.trim() ?? '';
    final trackExtAlbId = track.externalAlbumId?.trim() ?? '';
    final itemProvider = _norm(item.providerId);
    final trackProvider = _norm(TrackMetadata.fromTrackInfo(track).providerId);
    if (extAlbId.isNotEmpty && trackExtAlbId.isNotEmpty) {
      if (trackExtAlbId == extAlbId ||
          (itemProvider.isNotEmpty &&
              trackExtAlbId.toLowerCase() ==
                  '$itemProvider:${extAlbId.toLowerCase()}')) {
        return true;
      }
    }

    if (itemProvider.isNotEmpty &&
        trackProvider.isNotEmpty &&
        trackProvider != 'local' &&
        itemProvider != trackProvider) {
      return false;
    }

    final itemTitle = _norm(
      item.albumTitle.trim().isNotEmpty ? item.albumTitle : item.title,
    );
    final trackAlbum = _norm(track.album);
    if (itemTitle.isEmpty || trackAlbum.isEmpty || trackAlbum != itemTitle) {
      return false;
    }
    final itemArtist = _norm(item.artistName);
    if (itemArtist.isEmpty) return true;
    return _norm(track.effectiveAlbumArtist) == itemArtist ||
        _norm(track.artist) == itemArtist;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stateSub?.cancel();
    _stateSub = null;
    _positionSub?.cancel();
    _positionSub = null;
  }
}
