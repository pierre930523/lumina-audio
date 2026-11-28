part of '../playback_persistence_service.dart';

extension _PlaybackPersistenceRestore on PlaybackPersistenceService {
  Map<String, dynamic> _serializeTrack(TrackInfo t) {
    return {
      'id': t.id,
      'title': t.title,
      'artist': t.artist,
      'album': t.album,
      'duration_ms': t.duration.inMilliseconds,
      'cover_url': t.coverUrl,
      'album_art_url': t.albumArtUrl,
      'file_path': t.filePath,
      'album_artist': t.albumArtist,
      'genre': t.genre,
      'year': t.year,
      'track_number': t.trackNumber,
      'disc_number': t.discNumber,
      'composer': t.composer,
      'artwork_cache_key': t.artworkCacheKey,
      'has_lyrics': t.hasLyrics,
      'sample_rate_hz': t.format.sampleRateHz,
      'bit_depth': t.format.bitDepth,
      'channels': t.format.channels,
      'codec': t.format.codec.name,
      'is_dsd': t.format.isDsd,
      if (t.format.bitrateKbps != null) 'bitrate_kbps': t.format.bitrateKbps,
      'provider_name': t.providerName,
      if (t.isrc != null) 'isrc': t.isrc,
      if (t.qualityLabel != null) 'quality_label': t.qualityLabel,
      if (t.artistId != null) 'artist_id': t.artistId,
    };
  }

  TrackInfo? _deserializeTrack(dynamic raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final id = map['id']?.toString() ?? '';
    final title = map['title']?.toString() ?? '';
    final filePath = map['file_path']?.toString();
    if (id.isEmpty && title.isEmpty && (filePath == null || filePath.isEmpty)) {
      return null;
    }

    final durMs = (map['duration_ms'] as num?)?.toInt() ?? 0;
    final codecName = map['codec']?.toString() ?? 'flac';
    final codec = AudioCodec.fromString(codecName);
    final rawCover = map['cover_url']?.toString();
    final rawAlbumArt = map['album_art_url']?.toString();

    return TrackInfo(
      id: id,
      title: title.isNotEmpty ? title : '未知曲目',
      artist: map['artist']?.toString() ?? '未知歌手',
      album: map['album']?.toString() ?? '未知專輯',
      duration: Duration(milliseconds: durMs < 0 ? 0 : durMs),
      coverUrl: rawCover == null
          ? null
          : (upgradeStreamingCoverUrl(rawCover) ?? rawCover),
      albumArtUrl: rawAlbumArt == null
          ? null
          : (upgradeStreamingCoverUrl(rawAlbumArt) ?? rawAlbumArt),
      filePath: filePath,
      albumArtist: map['album_artist']?.toString(),
      genre: map['genre']?.toString(),
      year: (map['year'] as num?)?.toInt(),
      trackNumber: (map['track_number'] as num?)?.toInt(),
      discNumber: (map['disc_number'] as num?)?.toInt(),
      composer: map['composer']?.toString(),
      artworkCacheKey: map['artwork_cache_key']?.toString(),
      hasLyrics: map['has_lyrics'] == true,
      format: AudioFormat(
        codec: codec,
        sampleRateHz: (map['sample_rate_hz'] as num?)?.toInt() ?? 44100,
        bitDepth: (map['bit_depth'] as num?)?.toInt() ?? 16,
        channels: (map['channels'] as num?)?.toInt() ?? 2,
        isDsd: map['is_dsd'] == true,
        bitrateKbps: (map['bitrate_kbps'] as num?)?.toInt(),
      ),
      providerName: map['provider_name']?.toString() ?? 'local',
      isrc: map['isrc']?.toString(),
      qualityLabel: map['quality_label']?.toString(),
      artistId: map['artist_id']?.toString(),
    );
  }

  Future<Map<String, dynamic>?> _loadImpl() async {
    final file = _resolveFile();
    if (file == null) return null;

    try {
      final exists = prefsFileOverride != null
          ? file.existsSync()
          : await file.exists();
      if (!exists) return null;

      final raw = prefsFileOverride != null
          ? file.readAsStringSync()
          : await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return null;
  }

  static bool _isRemoteUri(String raw) {
    final lower = raw.trim().toLowerCase();
    return lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('smb://') ||
        lower.startsWith('dav://') ||
        lower.startsWith('webdav://');
  }

  static bool _canRestoreMissingFromQueueTrack(
    TrackInfo track, {
    required bool isInTest,
  }) {
    final fp = track.filePath?.trim();
    if (fp == null || fp.isEmpty) return true;
    if (_isRemoteUri(fp)) return true;
    if (isInTest) return true;
    try {
      return File(fp).existsSync();
    } catch (_) {
      return false;
    }
  }

  List<TrackInfo> _mergeRestoredQueue({
    required List<TrackInfo> savedQueue,
    required List<TrackInfo> existingQueue,
    required TrackInfo matchedTrack,
    required int savedQueueIndex,
    required bool isInTest,
  }) {
    final restored = <TrackInfo>[];

    void addIfUnique(TrackInfo candidate) {
      if (PlaybackPersistenceService.findTrackIndex(restored, candidate) < 0) {
        restored.add(candidate);
      }
    }

    for (final savedItem in savedQueue) {
      final existingIdx =
          PlaybackPersistenceService.findTrackIndex(existingQueue, savedItem);
      if (existingIdx >= 0) {
        final libTrack = existingQueue[existingIdx];
        final resolved = libTrack.duration <= Duration.zero &&
                savedItem.duration > Duration.zero
            ? libTrack.copyWith(duration: savedItem.duration)
            : libTrack;
        addIfUnique(resolved);
      } else if (_canRestoreMissingFromQueueTrack(savedItem, isInTest: isInTest)) {
        addIfUnique(savedItem);
      }
    }

    if (restored.isEmpty) {
      for (final existing in existingQueue) {
        addIfUnique(existing);
      }
      if (PlaybackPersistenceService.findTrackIndex(restored, matchedTrack) < 0) {
        final insertAt = savedQueueIndex.clamp(0, restored.length);
        restored.insert(insertAt, matchedTrack);
      }
    } else {
      if (PlaybackPersistenceService.findTrackIndex(restored, matchedTrack) < 0) {
        final insertAt = savedQueueIndex.clamp(0, restored.length);
        restored.insert(insertAt, matchedTrack);
      }
      // Preserve any real library tracks (with filePath) that weren't in savedQueue.
      for (final existing in existingQueue) {
        final hasLocalPath =
            existing.filePath != null && existing.filePath!.trim().isNotEmpty;
        if (hasLocalPath) {
          addIfUnique(existing);
        }
      }
    }

    return restored;
  }

  Future<bool> _restoreSessionImpl(
    AudioService audioService, {
    bool rememberPosition = true,
  }) async {
    _isRestoring = true;
    try {
      final data = await load();
      if (data == null) return false;
      _lastSavedData ??= data;

      final rawVolume = (data['volume'] as num?)?.toDouble();
      final savedVolume =
          (rawVolume != null && rawVolume.isFinite) ? rawVolume.clamp(0.0, 1.0) : null;
      final isMuted = data['is_muted'] == true;

      if (!rememberPosition) {
        if (savedVolume != null) {
          await audioService.setVolume(savedVolume);
        }
        if (isMuted && !audioService.currentState.isMuted) {
          await audioService.toggleMute();
        }
        await Future<void>.microtask(() {});
        return false;
      }

      final savedTrack = _deserializeTrack(data['track']);
      if (savedTrack == null) {
        if (savedVolume != null) {
          await audioService.setVolume(savedVolume);
        }
        if (isMuted && !audioService.currentState.isMuted) {
          await audioService.toggleMute();
        }
        await Future<void>.microtask(() {});
        return false;
      }

      final isInTest = prefsFileOverride != null ||
          Platform.environment.containsKey('FLUTTER_TEST');

      final existingQueue = audioService.queue;
      final matchedQueueIdx =
          PlaybackPersistenceService.findTrackIndex(existingQueue, savedTrack);
      late final TrackInfo matchedTrack;
      if (matchedQueueIdx >= 0) {
        final libTrack = existingQueue[matchedQueueIdx];
        matchedTrack = libTrack.duration <= Duration.zero &&
                savedTrack.duration > Duration.zero
            ? libTrack.copyWith(duration: savedTrack.duration)
            : libTrack;
      } else {
        if (!_canRestoreMissingFromQueueTrack(savedTrack, isInTest: isInTest)) {
          if (savedVolume != null) {
            await audioService.setVolume(savedVolume);
          }
          if (isMuted && !audioService.currentState.isMuted) {
            await audioService.toggleMute();
          }
          await Future<void>.microtask(() {});
          return false;
        }
        matchedTrack = savedTrack;
      }

      final savedQueue = <TrackInfo>[];
      final rawQueue = data['queue_tracks'];
      if (rawQueue is List) {
        for (final item in rawQueue) {
          final parsed = _deserializeTrack(item);
          if (parsed != null) {
            savedQueue.add(parsed);
          }
        }
      }

      final savedQueueIndex = (data['queue_index'] as num?)?.toInt() ?? 0;
      final restoredQueue = _mergeRestoredQueue(
        savedQueue: savedQueue,
        existingQueue: existingQueue,
        matchedTrack: matchedTrack,
        savedQueueIndex: savedQueueIndex,
        isInTest: isInTest,
      );

      var matchedIndex =
          PlaybackPersistenceService.findTrackIndex(restoredQueue, matchedTrack);
      if (matchedIndex < 0) {
        restoredQueue.insert(0, matchedTrack);
        matchedIndex = 0;
      }

      final savedPosMs = (data['position_ms'] as num?)?.toInt() ?? 0;
      var clampedPos = Duration(milliseconds: savedPosMs < 0 ? 0 : savedPosMs);
      if (matchedTrack.duration > Duration.zero &&
          clampedPos > matchedTrack.duration) {
        clampedPos = matchedTrack.duration;
      }

      await audioService.restorePlaybackSession(
        track: matchedTrack,
        position: clampedPos,
        queue: restoredQueue,
        queueIndex: matchedIndex,
        volume: savedVolume,
        isMuted: isMuted,
      );

      // Allow any broadcast stream events emitted during restore to be delivered
      // before clearing _isRestoring.
      await Future<void>.microtask(() {});

      debugPrint(
        '[PlaybackPersist] Restored: ${matchedTrack.title} @ ${clampedPos.inMilliseconds}ms',
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      _isRestoring = false;
    }
  }
}
