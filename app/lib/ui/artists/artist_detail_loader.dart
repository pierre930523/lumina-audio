part of 'artist_detail_page.dart';

extension _ArtistDetailLoader on _ArtistDetailPageState {
  void _primeFromSyncAndRefresh() {
    final token = ++_loadToken;
    final cache = widget.libraryCache;
    final normKey = _lookupKey;

    // 1. Synchronous lookup from LibraryIndexCache for frame-0 zero-flash render.
    final cachedEntry = cache?.getArtistSync(normKey);
    if (cachedEntry != null) {
      _applyEntry(cachedEntry);
      _loading = false;
      if (widget.useAlbumArtworkAsAvatar) {
        _probeAvatarArtworkPreference(token);
      }
      if (cache != null && cache.isPrimed) {
        return;
      }
    } else {
      // Fallback frame-0 seed from in-memory audioService.queue tracks.
      final queueMatches = widget.audioService.queue.where((t) {
        final tk = LibraryIndexCache.normalizeArtistKey(t.artist);
        final aak = LibraryIndexCache.normalizeArtistKey(
          t.effectiveAlbumArtist,
        );
        return tk == normKey || aak == normKey;
      }).toList();

      if (queueMatches.isNotEmpty) {
        _tracks = List<TrackInfo>.unmodifiable(queueMatches);
        _representativeTrack = _pickRepTrack(queueMatches);
        _loading = false;
      } else {
        _loading = true;
      }

      if (widget.useAlbumArtworkAsAvatar) {
        _probeAvatarArtworkPreference(token);
      }
    }

    // 2. Silent asynchronous refresh when cache is cold or unprimed.
    _refreshSilently(token, normKey);
  }

  Future<void> _refreshSilently(int token, String normKey) async {
    final cache = widget.libraryCache;
    if (cache != null) {
      try {
        final entry = await cache.ensureArtistLoaded(
          widget.audioService,
          normKey,
        );
        if (!mounted || token != _loadToken) return;
        if (entry != null) {
          if (!_isEntryUnchanged(entry)) {
            _setState(() {
              _applyEntry(entry);
              _loading = false;
            });
          }
        } else if (_loading) {
          _setState(() {
            _loading = false;
          });
        }
        if (widget.useAlbumArtworkAsAvatar) {
          _probeAvatarArtworkPreference(token);
        }
        return;
      } catch (_) {
        // Fall through to direct service load.
      }
    }

    try {
      final allTracks = widget.audioService.queue;
      final filteredTracks = allTracks.where((t) {
        final tk = LibraryIndexCache.normalizeArtistKey(t.artist);
        final aak = LibraryIndexCache.normalizeArtistKey(
          t.effectiveAlbumArtist,
        );
        return tk == normKey || aak == normKey;
      }).toList();

      final allAlbums = await widget.audioService.getAlbums(limit: 500);
      final filteredAlbums = allAlbums.where((a) {
        if (a.trackCount == 0) return false;
        final ak = LibraryIndexCache.normalizeArtistKey(a.artist);
        final aak = LibraryIndexCache.normalizeArtistKey(a.albumArtist ?? '');
        return ak == normKey || aak == normKey;
      }).toList()
        ..sort(LibraryIndexCache.compareAlbumsNewestFirst);

      if (!mounted || token != _loadToken) return;
      final nextTracks = List<TrackInfo>.unmodifiable(filteredTracks);
      final nextAlbums = List<CanonicalAlbumSummary>.unmodifiable(filteredAlbums);
      final unchanged = !_loading &&
          listEquals(nextTracks, _tracks) &&
          listEquals(nextAlbums, _albums);
      if (!unchanged) {
        _setState(() {
          _tracks = nextTracks;
          _albums = nextAlbums;
          _representativeAlbum = _pickRepAlbum(filteredAlbums);
          _representativeTrack = _pickRepTrack(filteredTracks);
          _loading = false;
        });
      }
      if (widget.useAlbumArtworkAsAvatar) {
        _probeAvatarArtworkPreference(token);
      }
    } catch (_) {
      if (!mounted || token != _loadToken) return;
      if (_loading) {
        _setState(() {
          _loading = false;
        });
      }
    }
  }

  void _probeAvatarArtworkPreference(int token) {
    if (!widget.useAlbumArtworkAsAvatar) return;
    final alb = _representativeAlbum;
    final trk = _representativeTrack;
    if (alb == null && trk == null) return;

    final cache = widget.libraryCache;
    if (alb != null &&
        ((alb.coverUrl != null && alb.coverUrl!.isNotEmpty) ||
            cache?.getArtworkPathSync(alb.id) != null)) {
      _preferTrackForAvatar = false;
      return;
    }
    if (trk != null &&
        ((trk.coverUrl != null && trk.coverUrl!.isNotEmpty) ||
            (trk.albumArtUrl != null && trk.albumArtUrl!.isNotEmpty) ||
            cache?.getArtworkPathSync(trk.id) != null)) {
      _preferTrackForAvatar = true;
      return;
    }

    // If neither has synchronous metadata URL, check if track has artwork when album does not.
    if (alb != null && trk != null) {
      () async {
        if (cache != null) {
          final albPath = await cache.resolveArtworkPath(
            widget.audioService,
            alb.id,
            maxDim: 0,
          );
          if (!mounted || token != _loadToken || albPath != null) return;
          final trkPath = await cache.resolveArtworkPath(
            widget.audioService,
            trk.id,
            path: trk.filePath,
            maxDim: 0,
          );
          if (!mounted || token != _loadToken) return;
          if (trkPath != null && trkPath.isNotEmpty && !_preferTrackForAvatar) {
            _setState(() {
              _preferTrackForAvatar = true;
            });
          }
          return;
        }

        await Future<void>.microtask(() {});
        if (widget.audioService.isNativeBound) {
          await Future<void>.delayed(const Duration(milliseconds: 8));
        }
        if (!mounted || token != _loadToken) return;
        final albRes = await widget.audioService.getArtwork(alb.id, maxDim: 0);
        if (!mounted || token != _loadToken) return;
        final albFound =
            albRes != null &&
            albRes['found'] == true &&
            (albRes['cache_path']?.toString().isNotEmpty ?? false);
        if (albFound) return;

        final trkRes = await widget.audioService.getArtwork(
          trk.id,
          path: trk.filePath,
          maxDim: 0,
        );
        if (!mounted || token != _loadToken) return;
        final trkFound =
            trkRes != null &&
            trkRes['found'] == true &&
            (trkRes['cache_path']?.toString().isNotEmpty ?? false);
        if (trkFound && !_preferTrackForAvatar) {
          _setState(() {
            _preferTrackForAvatar = true;
          });
        }
      }().catchError((_) {});
    }
  }

  CanonicalAlbumSummary? _pickRepAlbum(List<CanonicalAlbumSummary> albums) {
    if (albums.isEmpty) return null;
    for (final a in albums) {
      if ((a.coverUrl != null && a.coverUrl!.isNotEmpty) ||
          widget.libraryCache?.getArtworkPathSync(a.id) != null) {
        return a;
      }
    }
    return albums.first;
  }

  TrackInfo? _pickRepTrack(List<TrackInfo> tracks) {
    if (tracks.isEmpty) return null;
    for (final t in tracks) {
      if ((t.coverUrl != null && t.coverUrl!.isNotEmpty) ||
          (t.albumArtUrl != null && t.albumArtUrl!.isNotEmpty) ||
          widget.libraryCache?.getArtworkPathSync(t.id) != null) {
        return t;
      }
    }
    return tracks.first;
  }

  CanonicalAlbumSummary? _resolveAlbumForTrack(TrackInfo track) {
    final fromCache = widget.libraryCache?.resolveAlbumForTrack(track);
    if (fromCache != null) return fromCache;

    final trackAlbumTitle = track.album.trim().toLowerCase();
    if (trackAlbumTitle.isEmpty) return null;

    for (final album in _albums) {
      if (album.title.trim().toLowerCase() == trackAlbumTitle) {
        return album;
      }
    }
    for (final album in _albums) {
      final albTitle = album.title.trim().toLowerCase();
      if (albTitle.isNotEmpty &&
          (trackAlbumTitle.startsWith(albTitle) ||
              albTitle.startsWith(trackAlbumTitle))) {
        return album;
      }
    }
    return null;
  }

  String _resolvedArtistId() {
    if (_artistId != null && _artistId!.isNotEmpty) return _artistId!;
    for (final t in _tracks) {
      final id = t.artistId?.trim();
      if (id != null && id.isNotEmpty) return id;
    }
    return _lookupKey;
  }

  Future<void> _playAll() async {
    if (_tracks.isNotEmpty) {
      if (_tracks.every((t) => t.preference == -1)) {
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('此藝術家所有曲目皆已封鎖')),
          );
        }
        return;
      }
      await widget.audioService.playQueue(_tracks, excludeBanned: true);
      return;
    }
    if (_albums.isNotEmpty) {
      final firstAlbum = _albums.first;
      final detail = widget.libraryCache != null
          ? await widget.libraryCache!.loadAlbumDetail(
              widget.audioService,
              firstAlbum.id,
            )
          : await widget.audioService.getAlbumDetail(firstAlbum.id);
      final ver = detail?.versions.where((v) => v.tracks.isNotEmpty).firstOrNull;
      if (detail != null && ver != null) {
        final tracks = ver.orderedTrackEntries
            .map(
              (e) => TrackInfo(
                id: e.track.id,
                title: e.track.title,
                artist: detail.artistName,
                album: detail.title,
                duration: Duration(milliseconds: e.track.durationMs),
                format: AudioFormat(
                  codec: AudioCodec.fromString(e.track.codec),
                  sampleRateHz: e.track.sampleRateHz,
                  bitDepth: e.track.bitDepth,
                  channels: 2,
                  isDsd: ver.isDsd || e.track.isDsd,
                ),
                providerName: ver.provider,
                trackNumber: e.track.trackNumber,
                discNumber: e.track.discNumber,
                coverUrl: detail.coverUrl,
                albumGroupId: detail.id,
                preference: e.track.preference,
              ),
            )
            .toList(growable: false);
        if (tracks.every((t) => t.preference == -1)) {
          if (mounted) {
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              const SnackBar(content: Text('此專輯所有曲目皆已封鎖')),
            );
          }
          return;
        }
        await widget.audioService.playQueue(tracks, excludeBanned: true);
      }
    }
  }
}
