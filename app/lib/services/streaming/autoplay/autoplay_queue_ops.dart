part of '../autoplay_controller.dart';

bool _tracksMatch(TrackInfo a, TrackInfo b) {
  if (PlaybackPersistenceService.tracksMatch(a, b)) return true;
  if (a.id.trim().isNotEmpty && b.id.trim().isNotEmpty) {
    return a.responsiveArtworkKey == b.responsiveArtworkKey;
  }
  return false;
}

int _findTrackIndex(List<TrackInfo> tracks, TrackInfo target) {
  final byExact = PlaybackPersistenceService.findTrackIndex(tracks, target);
  if (byExact >= 0) return byExact;
  if (target.id.trim().isEmpty) return -1;
  final targetKey = target.responsiveArtworkKey;
  return tracks.indexWhere(
    (t) => t.id.trim().isNotEmpty && t.responsiveArtworkKey == targetKey,
  );
}

bool _isGenericDefaultFormat(AudioFormat f) {
  return f.codec == AudioCodec.flac &&
      f.sampleRateHz == 44100 &&
      f.bitDepth == 16 &&
      f.channels == 2 &&
      !f.isDsd &&
      f.bitrateKbps == null;
}

TrackInfo _mergeQueueEntryMetadata(
  TrackInfo incoming,
  TrackInfo existing,
) {
  final mergedId = existing.id.trim().isNotEmpty ? existing.id : incoming.id;
  final inTitle = incoming.title.trim();
  final exTitle = existing.title.trim();
  final mergedTitle = (inTitle.isNotEmpty && inTitle != '未知曲目')
      ? incoming.title
      : (exTitle.isNotEmpty ? existing.title : incoming.title);
  final inArtist = incoming.artist.trim();
  final exArtist = existing.artist.trim();
  final mergedArtist = (inArtist.isNotEmpty && inArtist != '未知藝術家')
      ? incoming.artist
      : (exArtist.isNotEmpty ? existing.artist : incoming.artist);
  final inAlbum = incoming.album.trim();
  final exAlbum = existing.album.trim();
  final mergedAlbum = (inAlbum.isNotEmpty && inAlbum != '未知專輯')
      ? incoming.album
      : (exAlbum.isNotEmpty ? existing.album : incoming.album);
  final mergedCover =
      (incoming.coverUrl != null && incoming.coverUrl!.trim().isNotEmpty)
      ? incoming.coverUrl
      : existing.coverUrl;
  final mergedAlbumArt =
      (incoming.albumArtUrl != null &&
          incoming.albumArtUrl!.trim().isNotEmpty)
      ? incoming.albumArtUrl
      : (existing.albumArtUrl ?? mergedCover);
  final mergedDuration = incoming.duration > Duration.zero
      ? incoming.duration
      : existing.duration;
  final mergedFormat =
      _isGenericDefaultFormat(incoming.format) &&
          !_isGenericDefaultFormat(existing.format)
      ? existing.format
      : incoming.format;
  final mergedProvider =
      existing.providerName.trim().isNotEmpty &&
          existing.providerName != 'Remote Core' &&
          (incoming.providerName.trim().isEmpty ||
              incoming.providerName == 'Local Library' ||
              incoming.providerName == 'Remote Core')
      ? existing.providerName
      : incoming.providerName;

  return existing.copyWith(
    id: mergedId,
    title: mergedTitle,
    artist: mergedArtist,
    album: mergedAlbum,
    duration: mergedDuration,
    coverUrl: mergedCover,
    albumArtUrl: mergedAlbumArt,
    format: mergedFormat,
    providerName: mergedProvider,
    filePath: incoming.filePath ?? existing.filePath,
    albumArtist: incoming.albumArtist ?? existing.albumArtist,
    genre: incoming.genre ?? existing.genre,
    year: incoming.year ?? existing.year,
    trackNumber: incoming.trackNumber ?? existing.trackNumber,
    discNumber: incoming.discNumber ?? existing.discNumber,
    composer: incoming.composer ?? existing.composer,
    artworkCacheKey: incoming.artworkCacheKey ?? existing.artworkCacheKey,
    hasLyrics: incoming.hasLyrics || existing.hasLyrics,
    isrc: incoming.isrc ?? existing.isrc,
    qualityLabel: incoming.qualityLabel ?? existing.qualityLabel,
    artistId: incoming.artistId ?? existing.artistId,
    preference: incoming.preference != 0
        ? incoming.preference
        : existing.preference,
    albumGroupId: incoming.albumGroupId ?? existing.albumGroupId,
    externalAlbumId: incoming.externalAlbumId ?? existing.externalAlbumId,
  );
}

extension _AutoplayQueueOps on AutoplayController {
  void _setUserQueueImpl(
    List<TrackInfo> tracks, {
    TrackInfo? currentTrack,
    int? currentIndex,
    bool bumpEpoch = true,
  }) {
    if (_disposed) return;

    final prevCurrentId = _currentTrack?.id;
    if (bumpEpoch) {
      _queueEpoch++;
      _cancelActiveRefill();
      _autoQueue.clear();
      _radioCursors.clear();
      _consecutiveAutoFailures = 0;
    }

    _userQueue
      ..clear()
      ..addAll(tracks);

    if (currentIndex != null &&
        currentIndex >= 0 &&
        currentIndex < _userQueue.length) {
      _userCursorIndex = currentIndex;
      _currentTrack = currentTrack ?? _userQueue[currentIndex];
      _currentFromAutoQueue = false;
    } else if (currentTrack != null) {
      final idx = PlaybackPersistenceService.findTrackIndex(
        _userQueue,
        currentTrack,
      );
      if (idx >= 0) {
        _userCursorIndex = idx;
        _currentTrack = currentTrack;
        _currentFromAutoQueue = false;
      } else if (_currentFromAutoQueue &&
          _currentTrack?.id == currentTrack.id) {
        _userCursorIndex = _userQueue.length - 1;
        _currentTrack = currentTrack;
        _currentFromAutoQueue = true;
      } else {
        _userCursorIndex = -1;
        _currentTrack = currentTrack;
        _currentFromAutoQueue = false;
      }
    } else {
      _userCursorIndex = -1;
      _currentTrack = null;
      _currentFromAutoQueue = false;
    }

    if (_currentTrack != null && _currentTrack!.id != prevCurrentId) {
      _recordRecent(_currentTrack!);
      _resetTrackProgressTimer();
    } else if (_currentTrack == null) {
      _resetTrackProgressTimer();
    }

    _emitChange();
    if (needsRefill) {
      unawaited(maybeTriggerRefill());
    }
  }

  void _clearAllImpl() {
    if (_disposed) return;
    _queueEpoch++;
    _cancelActiveRefill();
    _userQueue.clear();
    _autoQueue.clear();
    _radioCursors.clear();
    _currentTrack = null;
    _currentFromAutoQueue = false;
    _userCursorIndex = -1;
    _consecutiveAutoFailures = 0;
    _resetTrackProgressTimer();
    _emitChange();
  }

  void _setEnabledImpl(bool value) {
    if (_disposed) return;
    if (_enabled == value) return;
    _enabled = value;
    if (!value) {
      _queueEpoch++;
      _cancelActiveRefill();
      _autoQueue.clear();
      _consecutiveAutoFailures = 0;
      _emitChange();
    } else {
      _emitChange();
      if (needsRefill) {
        unawaited(maybeTriggerRefill());
      }
    }
    if (settings != null && settings!.autoplayEnabled != value) {
      unawaited(settings!.setAutoplayEnabled(value));
    }
  }

  void _clearAutoQueueImpl() {
    if (_disposed) return;
    _queueEpoch++;
    _cancelActiveRefill();
    _autoQueue.clear();
    _consecutiveAutoFailures = 0;
    _emitChange();
  }

  int _clearUpcomingImpl() {
    if (_disposed) return 0;
    final keepUserCount = _userCursorIndex >= 0
        ? (_userCursorIndex + 1).clamp(0, _userQueue.length)
        : 0;
    final removedUserCount = _userQueue.length - keepUserCount;
    final removedAutoCount = _autoQueue.length;
    final removedTotal = removedUserCount + removedAutoCount;

    if (removedTotal == 0 && _inFlightRefillCancel == null) {
      return 0;
    }

    _queueEpoch++;
    _cancelActiveRefill();
    if (removedUserCount > 0) {
      _userQueue.length = keepUserCount;
    }
    _autoQueue.clear();
    _consecutiveAutoFailures = 0;
    _emitChange();
    return removedTotal;
  }

  void _removeAutoTrackImpl(String trackId) {
    if (_disposed) return;
    final beforeLen = _autoQueue.length;
    _autoQueue.removeWhere((t) => t.id == trackId);
    if (_autoQueue.length != beforeLen) {
      _emitChange();
      if (needsRefill) {
        unawaited(maybeTriggerRefill());
      }
    }
  }

  void _promoteAutoTrackToUserQueueImpl(
    String trackId, {
    int? targetUserIndex,
  }) {
    if (_disposed) return;
    final autoIdx = _autoQueue.indexWhere((t) => t.id == trackId);
    if (autoIdx < 0) return;

    final promoted = _autoQueue.removeAt(autoIdx);
    if (targetUserIndex == null) {
      _userQueue.add(promoted);
    } else {
      final insertIdx = targetUserIndex.clamp(0, _userQueue.length);
      _userQueue.insert(insertIdx, promoted);
      if (!_currentFromAutoQueue &&
          _userCursorIndex >= 0 &&
          insertIdx <= _userCursorIndex) {
        _userCursorIndex++;
      }
    }
    _emitChange();
    if (needsRefill) {
      unawaited(maybeTriggerRefill());
    }
  }

  void _reorderDualQueueImpl(int oldCombinedIndex, int newCombinedIndex) {
    if (_disposed) return;
    final combined = combinedQueue;
    if (oldCombinedIndex < 0 ||
        oldCombinedIndex >= combined.length ||
        newCombinedIndex < 0 ||
        newCombinedIndex >= combined.length ||
        oldCombinedIndex == newCombinedIndex) {
      return;
    }

    final hasCurAuto = _currentFromAutoQueue && _currentTrack != null;
    final playedEnd = (_userCursorIndex + 1).clamp(0, _userQueue.length);
    final curAutoCombinedIdx = hasCurAuto ? playedEnd : -1;
    final autoStartIdx = _userQueue.length + (hasCurAuto ? 1 : 0);

    // Do not drag the currently playing auto track out from under playback.
    if (hasCurAuto && oldCombinedIndex == curAutoCombinedIdx) {
      return;
    }

    if (oldCombinedIndex < autoStartIdx) {
      // Moving an item that is already in _userQueue.
      final oldUserIdx = (hasCurAuto && oldCombinedIndex > curAutoCombinedIdx)
          ? oldCombinedIndex - 1
          : oldCombinedIndex;
      if (oldUserIdx < 0 || oldUserIdx >= _userQueue.length) return;

      final moved = _userQueue.removeAt(oldUserIdx);
      final maxUserDest = _userQueue.length;
      final rawDest = (hasCurAuto && newCombinedIndex > curAutoCombinedIdx)
          ? newCombinedIndex - 1
          : newCombinedIndex;
      final destUserIdx = rawDest.clamp(0, maxUserDest);
      _userQueue.insert(destUserIdx, moved);

      if (!_currentFromAutoQueue && _currentTrack != null) {
        final refreshedIdx = PlaybackPersistenceService.findTrackIndex(
          _userQueue,
          _currentTrack!,
        );
        if (refreshedIdx >= 0) {
          _userCursorIndex = refreshedIdx;
        }
      }
      _emitChange();
      return;
    }

    // Moving an item from _autoQueue: moving into or up to the user-queue
    // boundary automatically promotes it into _userQueue.
    final oldAutoIdx = oldCombinedIndex - autoStartIdx;
    if (oldAutoIdx < 0 || oldAutoIdx >= _autoQueue.length) return;

    final moved = _autoQueue.removeAt(oldAutoIdx);
    if (newCombinedIndex <= autoStartIdx) {
      final int destUserIdx;
      if (hasCurAuto && newCombinedIndex >= curAutoCombinedIdx) {
        // Place in remaining user queue (after already-played user tracks).
        destUserIdx = (newCombinedIndex - 1).clamp(playedEnd, _userQueue.length);
      } else {
        destUserIdx = newCombinedIndex.clamp(0, _userQueue.length);
        if (!_currentFromAutoQueue &&
            _userCursorIndex >= 0 &&
            destUserIdx <= _userCursorIndex) {
          _userCursorIndex++;
        }
      }
      _userQueue.insert(destUserIdx, moved);
    } else {
      final destAutoIdx = (newCombinedIndex - autoStartIdx).clamp(
        0,
        _autoQueue.length,
      );
      _autoQueue.insert(destAutoIdx, moved);
    }

    _emitChange();
    if (needsRefill) {
      unawaited(maybeTriggerRefill());
    }
  }

  int _appendToUserQueueImpl(List<TrackInfo> tracks, {bool playNext = false}) {
    if (_disposed || tracks.isEmpty) return 0;
    var added = 0;
    if (playNext) {
      var insertAt = (_userCursorIndex + 1).clamp(0, _userQueue.length);
      for (final t in tracks) {
        if (!_userQueue.any((e) => e.id == t.id)) {
          _userQueue.insert(insertAt, t);
          _autoQueue.removeWhere((e) => e.id == t.id);
          insertAt++;
          added++;
        }
      }
    } else {
      for (final t in tracks) {
        if (!_userQueue.any((e) => e.id == t.id)) {
          _userQueue.add(t);
          added++;
        }
      }
    }
    if (added > 0) {
      _emitChange();
      if (needsRefill) {
        unawaited(maybeTriggerRefill());
      }
    }
    return added;
  }

  void _syncTrackPreferenceImpl(String trackId, int preference) {
    if (_disposed || trackId.isEmpty) return;
    TrackInfo? matched;
    for (var i = 0; i < _userQueue.length; i++) {
      if (_userQueue[i].id == trackId) {
        _userQueue[i] = _userQueue[i].copyWith(preference: preference);
        matched ??= _userQueue[i];
      }
    }
    for (var i = 0; i < _autoQueue.length; i++) {
      if (_autoQueue[i].id == trackId) {
        _autoQueue[i] = _autoQueue[i].copyWith(preference: preference);
        matched ??= _autoQueue[i];
      }
    }
    if (_currentTrack?.id == trackId) {
      _currentTrack = _currentTrack!.copyWith(preference: preference);
      matched ??= _currentTrack;
    }
    if (preference == -1) {
      _autoQueue.removeWhere((t) => t.id == trackId);
    }
    if (matched != null) {
      filter.setBannedTrack(
        TrackMetadata.fromTrackInfo(matched),
        preference == -1,
      );
      _emitChange();
    }
  }
}
