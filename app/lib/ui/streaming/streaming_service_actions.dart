part of 'streaming_service_view.dart';

extension _StreamingServiceActions on _StreamingServiceViewState {
  void _scheduleAutoFetchRecommendations() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sm = widget.streamingManager;
      final kind = widget.provider.kind;
      final provider = sm?.providerFor(kind);
      final canBrowse = provider != null &&
          (provider.authState == StreamingAuthState.connected ||
              provider.supportsGuestMode);
      if (sm == null || !canBrowse) {
        return;
      }
      final existing = sm.recommendationsFor(kind);
      if (existing == null &&
          !sm.isLoadingRecommendations(kind) &&
          sm.recommendationErrorFor(kind) == null) {
        unawaited(sm.refreshRecommendationsFor(kind, force: false));
      }
    });
  }

  Future<void> _handleRefreshRecommendations({
    bool showToastOnError = true,
  }) async {
    final sm = widget.streamingManager;
    if (sm == null) return;
    final kind = widget.provider.kind;
    final rec = await sm.refreshRecommendationsFor(kind, force: true);
    if (!mounted) return;
    final err = sm.recommendationErrorFor(kind) ?? rec.errorMessage;
    if (showToastOnError && err != null && err.trim().isNotEmpty) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(
        SnackBar(
          key: Key('streaming_rec_toast_error_$kind'),
          backgroundColor: LuminaTokens.glassDialogBg,
          content: Text(
            '${widget.provider.name} 重新整理推薦失敗：${err.trim()}',
            style: const TextStyle(color: LuminaTokens.textPrimary),
          ),
        ),
      );
    }
  }

  Future<void> _syncCatalog() async {
    if (_isGuestMode) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(
        SnackBar(
          key: const Key('streaming_guest_sync_snackbar'),
          content: Text(
            '登入 ${widget.provider.name} 帳號即可同步個人收藏曲目與歌單。',
          ),
          action: SnackBarAction(
            label: '前往登入',
            textColor: LuminaTokens.glassTextPrimary,
            onPressed: widget.onOpenProviderSettings,
          ),
        ),
      );
      return;
    }
    _setState(() {
      _syncing = true;
      _errorMessage = null;
      _syncNotice = null;
    });
    try {
      final mgr = widget.streamingManager;
      if (mgr != null && mgr.providerFor(widget.provider.kind) != null) {
        final catalog = await mgr.syncProvider(widget.provider.kind);
        widget.onLibraryUpdated?.call();
        if (!mounted) return;
        _setState(() {
          _syncNotice =
              '已完成 ${widget.provider.name} 曲庫同步（${catalog.tracks.length} 首曲目、${catalog.playlists.length} 個歌單、${catalog.albums.length} 張專輯）';
        });
      } else {
        final result = await widget.audioService.syncProvider(
          widget.provider.kind,
        );
        widget.onLibraryUpdated?.call();
        if (!mounted) return;
        final count = (result['tracks_count'] as num?)?.toInt();
        _setState(() {
          _syncNotice = count != null
              ? '已完成 ${widget.provider.name} 曲庫同步（目前共有 $count 首曲目）'
              : '已完成 ${widget.provider.name} 曲庫同步';
        });
      }
    } on StreamingException catch (e) {
      if (!mounted) return;
      _setState(() {
        _errorMessage = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      _setState(() {
        _errorMessage = '同步曲庫失敗：$e';
      });
    } finally {
      if (mounted) {
        _setState(() => _syncing = false);
      }
    }
  }

  Future<void> _openPlaylist(StreamingPlaylist playlist) async {
    final provider = _liveProvider;
    _setState(() {
      _activePlaylist = playlist;
      _loadingPlaylist = true;
      _playlistError = null;
      _playlistTracks = playlist.tracks;
    });

    if (provider == null) {
      _setState(() => _loadingPlaylist = false);
      return;
    }

    try {
      final tracks = await widget.streamingManager!.fetchPlaylistTracks(
        widget.provider.kind,
        playlist.id,
      );
      if (!mounted) return;
      _setState(() {
        _playlistTracks = tracks;
        _loadingPlaylist = false;
      });
    } on StreamingException catch (e) {
      if (!mounted) return;
      _setState(() {
        _playlistError = e.message;
        _loadingPlaylist = false;
      });
    } catch (e) {
      if (!mounted) return;
      _setState(() {
        _playlistError = '載入歌單曲目失敗：$e';
        _loadingPlaylist = false;
      });
    }
  }

  Future<void> _playTrack(
    TrackInfo track, {
    List<TrackInfo>? queueContext,
  }) async {
    if (widget.onPlayStreamingTrackWithContext != null) {
      await widget.onPlayStreamingTrackWithContext!(
        track,
        queueContext ?? const <TrackInfo>[],
      );
      return;
    }
    if (widget.onPlayStreamingTrack != null) {
      await widget.onPlayStreamingTrack!(track);
      return;
    }
    await widget.audioService.play(track: track);
  }
}
