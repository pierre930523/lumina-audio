part of 'albums_and_credits_view.dart';

extension _AlbumsAndCreditsGroupingActions on _AlbumsAndCreditsViewState {
  void _applyInitialViewState(String? raw) {
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final modeName = decoded['view_mode']?.toString();
      if (modeName == AlbumViewMode.list.name) {
        _effectiveLayoutController.setViewMode(AlbumViewMode.list);
      } else if (modeName == AlbumViewMode.grid.name) {
        _effectiveLayoutController.setViewMode(AlbumViewMode.grid);
      }
      if (decoded['show_hidden_albums'] is bool) {
        _effectiveLayoutController.setShowHiddenAlbums(
          decoded['show_hidden_albums'] as bool,
        );
      }
      if (decoded['show_card_container'] is bool) {
        _effectiveLayoutController.setShowCardContainer(
          decoded['show_card_container'] as bool,
        );
      }
    } catch (_) {}
  }

  String _encodeViewState() {
    return jsonEncode(<String, dynamic>{
      'view_mode': _effectiveLayoutController.viewMode.name,
      'show_hidden_albums': _effectiveLayoutController.showHiddenAlbums,
      'show_card_container': _effectiveLayoutController.showCardContainer,
    });
  }

  void _onLayoutControllerChanged() {
    if (!mounted) return;
    widget.onViewStateChanged?.call(_encodeViewState());
    final nextShowHidden = _effectiveLayoutController.showHiddenAlbums;
    if (nextShowHidden != _lastShowHiddenAlbums) {
      _lastShowHiddenAlbums = nextShowHidden;
      _selectedKeys.clear();
      _lastSelectedIndex = null;
      _focusController.setIncludeHidden(nextShowHidden);
      final cache = widget.libraryCache;
      if (cache != null) {
        unawaited(cache.setIncludeHidden(widget.audioService, nextShowHidden));
      } else {
        unawaited(_loadData());
      }
    }
  }

  TrackInfo _toTrackInfo(
    CanonicalAlbumDetail detail,
    AlbumVersionInfo version,
    AlbumVersionTrackInfo vTrack,
  ) {
    final ext = vTrack.externalTrackId;
    final hasUri =
        ext.contains('/') ||
        ext.contains('\\') ||
        ext.startsWith('http://') ||
        ext.startsWith('https://');
    return TrackInfo(
      id: vTrack.id,
      title: vTrack.title,
      artist: detail.artistName,
      album: detail.title,
      duration: Duration(milliseconds: vTrack.durationMs),
      format: AudioFormat(
        codec: AudioCodec.fromString(vTrack.codec),
        sampleRateHz: vTrack.sampleRateHz,
        bitDepth: vTrack.bitDepth,
        channels: 2,
        isDsd: version.isDsd || vTrack.isDsd,
      ),
      providerName: version.provider,
      trackNumber: vTrack.trackNumber,
      discNumber: vTrack.discNumber,
      coverUrl: detail.coverUrl,
      filePath: hasUri ? ext : null,
      albumGroupId: detail.id,
      preference: vTrack.preference,
    );
  }

  Future<List<TrackInfo>> _resolveAlbumTracks(
    CanonicalAlbumSummary album,
  ) async {
    final q = widget.audioService.queue;
    final detail =
        widget.libraryCache?.albumDetailsById[album.id] ??
        await widget.audioService.getAlbumDetail(album.id);
    final ver = detail?.versions.where((v) => v.tracks.isNotEmpty).firstOrNull;
    if (detail != null && ver != null) {
      final ordered = ver.orderedTrackEntries;
      if (ordered.isNotEmpty) {
        return ordered.map((entry) {
          final vTrack = entry.track;
          final existing = q.where((t) => t.id == vTrack.id).firstOrNull;
          return existing ?? _toTrackInfo(detail, ver, vTrack);
        }).toList();
      }
    }
    final lowerTitle = album.title.toLowerCase();
    return q
        .where(
          (t) =>
              t.album == album.title ||
              t.album.toLowerCase().startsWith(lowerTitle),
        )
        .toList();
  }

  Future<void> _playAlbum(CanonicalAlbumSummary album) async {
    final tracks = await _resolveAlbumTracks(album);
    if (!mounted) return;
    if (tracks.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('音樂庫中找不到此專輯的可播放曲目')),
      );
      return;
    }
    final playable = tracks
        .where((t) => t.preference != -1)
        .toList(growable: false);
    if (playable.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('此合輯所有曲目皆已封鎖')),
      );
      return;
    }
    await widget.audioService.playQueue(tracks, excludeBanned: true);
  }

  Future<void> _addAlbumToQueue(CanonicalAlbumSummary album) async {
    final tracks = await _resolveAlbumTracks(album);
    if (!mounted) return;
    final added = await widget.audioService.enqueueTracks(
      tracks,
      excludeBanned: true,
    );
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          added > 0
              ? '已將「${album.title}」加入播放佇列（$added 首）'
              : (tracks.every((t) => t.preference == -1)
                  ? '「${album.title}」所有曲目皆已封鎖，未加入播放佇列'
                  : '「${album.title}」曲目已在清單中，無需重複加入播放佇列'),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _toggleMultiSelectMode() {
    _setState(() {
      _multiSelectMode = !_multiSelectMode;
      if (!_multiSelectMode) {
        _selectedKeys.clear();
        _lastSelectedIndex = null;
      }
    });
  }

  void _clearSelection() {
    _setState(() {
      _selectedKeys.clear();
      _lastSelectedIndex = null;
      _multiSelectMode = false;
    });
  }

  void _toggleItemSelection(int index, CanonicalAlbumSummary album) {
    final key = album.selectionKey;
    _setState(() {
      _multiSelectMode = true;
      if (_selectedKeys.contains(key)) {
        _selectedKeys.remove(key);
      } else {
        _selectedKeys.add(key);
      }
      _lastSelectedIndex = index;
    });
  }

  void _handleAlbumCardTap(int index, CanonicalAlbumSummary album) {
    final keyboard = HardwareKeyboard.instance;
    final isShift = keyboard.isShiftPressed;
    final isCtrlOrMeta = keyboard.isControlPressed || keyboard.isMetaPressed;

    if (isShift && _lastSelectedIndex != null) {
      final start = math.min(_lastSelectedIndex!, index);
      final end = math.max(_lastSelectedIndex!, index);
      final visible = _displayedAlbums;
      _setState(() {
        _multiSelectMode = true;
        for (var i = start; i <= end; i++) {
          if (i >= 0 && i < visible.length) {
            _selectedKeys.add(visible[i].selectionKey);
          }
        }
        _lastSelectedIndex = index;
      });
      return;
    }

    if (isCtrlOrMeta || _multiSelectMode) {
      _toggleItemSelection(index, album);
      return;
    }

    _openAlbum(album.effectiveGroupId);
  }

  List<CanonicalAlbumSummary> get _selectedAlbumItems => _displayedAlbums
      .where((a) => _selectedKeys.contains(a.selectionKey))
      .toList(growable: false);

  Future<void> _handleSelectionManageTags() async {
    final selected = _selectedAlbumItems;
    if (selected.isEmpty || _groupingBusy) return;
    final groupIds = selected
        .map((a) => a.effectiveGroupId)
        .toSet()
        .toList(growable: false);
    final changed = await showTagPickerDialog(
      context: context,
      audioService: widget.audioService,
      entityType: TagEntityType.albumGroup,
      entityIds: groupIds,
      title: groupIds.length == 1
          ? '管理「${selected.first.title}」的標籤'
          : '批次管理 ${groupIds.length} 張專輯的標籤',
    );
    if (!mounted || !changed) return;
    if (_focusController.isActive || _focusController.drawerOpen) {
      unawaited(_focusController.refresh(immediate: true));
    }
    _setState(() {
      _statusMessage = '已更新 ${groupIds.length} 張專輯的標籤';
    });
  }

  Future<void> _refreshAfterGroupingMutation(String message) async {
    final cache = widget.libraryCache;
    if (cache != null) {
      await cache.refresh(widget.audioService);
    } else {
      await _loadData();
    }
    if (!mounted) return;
    _setState(() {
      _selectedKeys.clear();
      _lastSelectedIndex = null;
      _multiSelectMode = false;
      _groupingBusy = false;
      _statusMessage = message;
    });
  }

  Future<void> _handleSelectionMerge() async {
    final selected = _selectedAlbumItems;
    if (selected.length < 2 || _groupingBusy) return;
    final dialogResult = await showDialog<AlbumMergeDialogResult>(
      context: context,
      barrierColor: LuminaTokens.scrimBg,
      builder: (_) => AlbumMergeDialog(selectedVersions: selected),
    );
    if (dialogResult == null || !mounted) return;
    _setState(() => _groupingBusy = true);
    try {
      final res = await widget.audioService.mergeAlbumVersions(
        targetVersionId: dialogResult.targetVersionId,
        sourceVersionIds: dialogResult.sourceVersionIds,
        newEditionLabel: dialogResult.newEditionLabel,
        discMapping: dialogResult.discMapping,
      );
      await _refreshAfterGroupingMutation(
        '已合併專輯（搬移 ${res.movedTracks} 首曲目，清理 ${res.prunedVersions} 個空版本）',
      );
    } finally {
      if (mounted && _groupingBusy) {
        _setState(() => _groupingBusy = false);
      }
    }
  }

  Future<void> _handleSelectionGroupAsAlternate() async {
    final selected = _selectedAlbumItems;
    if (selected.length < 2 || _groupingBusy) return;
    _setState(() => _groupingBusy = true);
    try {
      final ids = selected.map((e) => e.selectionKey).toList(growable: false);
      await widget.audioService.groupAsAlternateVersions(
        versionIds: ids,
        targetGroupId: selected.first.effectiveGroupId,
      );
      await _refreshAfterGroupingMutation(
        '已將 ${selected.length} 個版本歸類至同一專輯群組',
      );
    } finally {
      if (mounted && _groupingBusy) {
        _setState(() => _groupingBusy = false);
      }
    }
  }

  Future<void> _handleSelectionToggleHide() async {
    final selected = _selectedAlbumItems;
    if (selected.isEmpty || _groupingBusy) return;
    final shouldHide = !selected.every((a) => a.isHidden);
    _setState(() => _groupingBusy = true);
    try {
      for (final item in selected) {
        await widget.audioService.setVersionHidden(
          item.selectionKey,
          isHidden: shouldHide,
        );
      }
      await _refreshAfterGroupingMutation(
        shouldHide
            ? '已隱藏 ${selected.length} 個專輯版本'
            : '已取消隱藏 ${selected.length} 個專輯版本',
      );
    } finally {
      if (mounted && _groupingBusy) {
        _setState(() => _groupingBusy = false);
      }
    }
  }
}
