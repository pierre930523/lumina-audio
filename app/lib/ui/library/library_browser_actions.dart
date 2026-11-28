part of 'library_browser_view.dart';

extension _LibraryBrowserActions on _LibraryBrowserViewState {
  void _restoreViewState(String? raw) {
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded['search'] is String) {
        _searchController.text = decoded['search'] as String;
      }
    } catch (_) {}
  }

  String? _encodeViewState() {
    final search = _searchController.text.trim();
    if (search.isEmpty) return null;
    return jsonEncode(<String, dynamic>{'search': search});
  }

  void _handleTrackPreferenceUpdated(TrackInfo track, int nextPref) {
    _setState(() {
      _visibleTracks = _visibleTracks
          .map((t) => t.id == track.id ? t.copyWith(preference: nextPref) : t)
          .toList(growable: false);
    });
    if (_focusController.isActive || _focusController.drawerOpen) {
      unawaited(_focusController.refresh(immediate: true));
    }
  }

  void _onLibraryCacheChanged() {
    if (!mounted) return;
    final nextHidden = widget.libraryCache?.includeHidden ?? false;
    if (nextHidden != _lastIncludeHidden) {
      _lastIncludeHidden = nextHidden;
      _focusController.setIncludeHidden(nextHidden);
    }
    unawaited(_refreshLibraryTracksView());
  }

  Future<void> _refreshLibraryTracksView() async {
    if (!mounted) return;
    if (_focusController.isActive || _focusController.drawerOpen) {
      unawaited(_focusController.refresh(immediate: true));
    }
    final q = _searchController.text.trim();
    if (q.isEmpty) {
      await _loadLibraryTracks();
    } else {
      await _executeSearch(q, ++_searchSeq);
    }
  }

  void _toggleMultiSelectMode() {
    _setState(() {
      _multiSelectMode = !_multiSelectMode;
      if (!_multiSelectMode) {
        _selectedTrackIds.clear();
        _lastSelectedIndex = null;
      }
    });
  }

  void _clearSelection() {
    _setState(() {
      _selectedTrackIds.clear();
      _lastSelectedIndex = null;
      _multiSelectMode = false;
    });
  }

  void _toggleTrackSelection(int index, TrackInfo track) {
    _setState(() {
      _multiSelectMode = true;
      if (!_selectedTrackIds.remove(track.id)) {
        _selectedTrackIds.add(track.id);
      }
      _lastSelectedIndex = index;
    });
  }

  void _handleTrackTap(int index, TrackInfo track, List<TrackInfo> tracks) {
    final kb = HardwareKeyboard.instance;
    if (kb.isShiftPressed && _lastSelectedIndex != null) {
      final start = math.min(_lastSelectedIndex!, index);
      final end = math.max(_lastSelectedIndex!, index);
      _setState(() {
        _multiSelectMode = true;
        for (var i = start; i <= end; i++) {
          if (i >= 0 && i < tracks.length) {
            _selectedTrackIds.add(tracks[i].id);
          }
        }
        _lastSelectedIndex = index;
      });
      return;
    }
    if (kb.isControlPressed || kb.isMetaPressed || _multiSelectMode) {
      _toggleTrackSelection(index, track);
      return;
    }
    // Explicit single-track click always plays even if preference == -1.
    unawaited(widget.audioService.play(track: track));
  }

  Future<void> _addTracksToQueue(List<TrackInfo> tracks) async {
    if (tracks.isEmpty) return;
    final added = await widget.audioService.enqueueTracks(
      tracks,
      excludeBanned: true,
    );
    if (!mounted) return;
    final msg = added == 0
        ? '所選曲目皆已封鎖或已在佇列中'
        : (added == 1
              ? '已將 1 首曲目加入播放佇列'
              : '已將 $added 首曲目加入播放佇列');
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _playSelectedTracks(List<TrackInfo> selected) async {
    if (selected.isEmpty) return;
    final playable = selected
        .where((t) => t.preference != -1)
        .toList(growable: false);
    if (playable.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('所選曲目皆已封鎖')),
      );
      return;
    }
    await widget.audioService.playQueue(selected, excludeBanned: true);
  }

  Future<void> _manageTrackTags(List<TrackInfo> targets) async {
    if (targets.isEmpty) return;
    final ids = targets.map((t) => t.id).toSet().toList(growable: false);
    final changed = await showTagPickerDialog(
      context: context,
      audioService: widget.audioService,
      entityType: TagEntityType.track,
      entityIds: ids,
      title: ids.length == 1
          ? '管理「${targets.first.title}」的標籤'
          : '批次管理 ${ids.length} 首曲目的標籤',
    );
    if (!mounted || !changed) return;
    if (_focusController.isActive || _focusController.drawerOpen) {
      unawaited(_focusController.refresh(immediate: true));
    }
  }

  Future<void> _bulkEditTracks(List<TrackInfo> targets) async {
    if (targets.isEmpty) return;
    final ids = targets.map((t) => t.id).toSet().toList(growable: false);
    final result = await showBulkEditDialog(
      context: context,
      audioService: widget.audioService,
      entityType: BulkEditEntityType.track,
      entityIds: ids,
    );
    if (!mounted || result == null) return;
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      await _loadLibraryTracks();
    } else {
      await _executeSearch(query, ++_searchSeq);
    }
    if (widget.libraryCache != null) {
      unawaited(widget.libraryCache!.refresh(widget.audioService));
    }
    if (_focusController.isActive || _focusController.drawerOpen) {
      unawaited(_focusController.refresh(immediate: true));
    }
    if (!mounted) return;
    _clearSelection();
    final msg = result.revertedCount > 0
        ? '已還原 ${result.revertedCount} 首曲目的原始檔案標籤'
        : '已完成 ${ids.length} 首曲目的批量編輯';
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _exportTracks(List<TrackInfo> targets) async {
    if (targets.isEmpty) return;
    final ids = targets.map((t) => t.id).toSet().toList(growable: false);
    await LibraryExportDialog.show(
      context,
      audioService: widget.audioService,
      initialSource: CatalogExportTracksSource(ids),
      defaultPlaylistName: 'Selected Tracks',
    );
  }

  Future<void> _exportActiveFocus() async {
    await LibraryExportDialog.show(
      context,
      audioService: widget.audioService,
      initialSource: CatalogExportFocusQuerySource(_focusController.query),
      defaultPlaylistName: 'Focus Selection',
    );
  }

  List<Widget> _buildFocusTrailingWidgets(bool showSaveSmartBtn) {
    final pillStyle = OutlinedButton.styleFrom(
      backgroundColor: LuminaTokens.glassPillBg,
      foregroundColor: LuminaTokens.glassTextPrimary,
      side: const BorderSide(color: LuminaTokens.glassPillBorder),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    );
    return <Widget>[
      if (showSaveSmartBtn)
        OutlinedButton.icon(
          key: const Key('btn_save_focus_as_smart_playlist'),
          onPressed: _saveFocusAsSmartPlaylist,
          style: pillStyle,
          icon: const Icon(Icons.auto_awesome_rounded, size: 15),
          label: const Text('存為智慧歌單', style: TextStyle(fontSize: 12)),
        ),
      if (_focusController.isActive)
        OutlinedButton.icon(
          key: const Key('btn_export_focus_query'),
          onPressed: () => unawaited(_exportActiveFocus()),
          style: pillStyle,
          icon: const Icon(Icons.ios_share_rounded, size: 15),
          label: const Text('匯出目前篩選', style: TextStyle(fontSize: 12)),
        ),
    ];
  }

  void _openAlbumForTrack(TrackInfo track) {
    final cb = widget.onOpenAlbumDetail;
    if (cb == null) return;
    final albumId = widget.libraryCache?.resolveAlbumIdForTrack(track);
    if (albumId != null && albumId.isNotEmpty) {
      cb(albumId);
    }
  }

  Future<void> _saveFocusAsSmartPlaylist() async {
    final svc = widget.playlistService;
    if (svc == null) return;
    final created = await SmartPlaylistsView.showCreateDialog(
      context: context,
      service: svc,
      initialFocusQuery: _focusController.query,
    );
    if (created != null && mounted) {
      widget.onSavedSmartPlaylist?.call(created);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('已儲存智慧歌單「${created.name}」')),
      );
    }
  }

  Future<void> _updateEditingSmartPlaylistRules() async {
    final svc = widget.playlistService;
    final editId = widget.editingSmartPlaylistId;
    if (svc == null || editId == null) return;
    final jsonQuery = jsonEncode(
      _focusController.query.copyWith(entity: FocusEntity.tracks).toJson(),
    );
    final updated = await svc.updatePlaylist(
      editId,
      focusQueryJson: jsonQuery,
    );
    if (!mounted) return;
    if (updated != null) {
      widget.onSavedSmartPlaylist?.call(updated);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('已更新「${updated.name}」的篩選規則')),
      );
    }
  }

  Widget _buildEditingSmartPlaylistBanner() {
    return Container(
      key: const Key('editing_smart_playlist_banner'),
      margin: const EdgeInsets.only(bottom: LuminaTokens.spaceXs),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: LuminaTokens.accentBlue.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(
          color: LuminaTokens.accentBlue.withValues(alpha: 0.55),
        ),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 6,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.auto_awesome_rounded,
                size: 16,
                color: LuminaTokens.accentBlue,
              ),
              SizedBox(width: 8),
              Text(
                '正在編輯智慧歌單規則（調整下方 Focus 條件後點選更新）',
                style: TextStyle(
                  color: LuminaTokens.glassTextPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                key: const Key('btn_cancel_edit_smart_rules'),
                onPressed: widget.onCancelEditSmartPlaylist,
                child: const Text('取消'),
              ),
              const SizedBox(width: 6),
              FilledButton.icon(
                key: const Key('btn_update_smart_playlist_rules'),
                onPressed: _updateEditingSmartPlaylistRules,
                style: FilledButton.styleFrom(
                  backgroundColor: LuminaTokens.glassSwitchOnTrack,
                  foregroundColor: LuminaTokens.onAccentDark,
                ),
                icon: const Icon(Icons.save_rounded, size: 15),
                label: const Text('更新智慧歌單規則', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    return TextField(
      key: const Key('library_search_input'),
      controller: _searchController,
      onChanged: _onSearchChanged,
      style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 13),
      decoration: InputDecoration(
        prefixIcon: const Icon(
          Icons.search_rounded,
          color: LuminaTokens.textMuted,
          size: 18,
        ),
        suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _searchController,
          builder: (context, value, _) {
            if (value.text.isEmpty) return const SizedBox.shrink();
            return IconButton(
              key: const Key('btn_library_search_clear'),
              tooltip: '清除搜尋',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: const EdgeInsets.only(right: 4),
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(
                Icons.close_rounded,
                color: LuminaTokens.textMuted,
                size: 17,
              ),
              onPressed: _clearSearch,
            );
          },
        ),
        hintText: '搜尋藝術家、專輯或曲目...',
        hintStyle: const TextStyle(color: LuminaTokens.textMuted),
        filled: true,
        fillColor: LuminaTokens.glassPillBg,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: LuminaTokens.spaceSm,
          vertical: LuminaTokens.spaceSm,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
          borderSide: const BorderSide(color: LuminaTokens.glassPillBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
          borderSide: const BorderSide(color: LuminaTokens.glassPillBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
          borderSide: const BorderSide(
            color: LuminaTokens.focusRing,
            width: 1.5,
          ),
        ),
      ),
    );
  }

  Widget _buildTracksListView(List<TrackInfo> tracks, double bottomPad) {
    return SmoothScrollWrapper(
      controller: _scrollController,
      child: ListView.builder(
        key: const Key('track_queue_list'),
        controller: _scrollController,
        padding: EdgeInsets.fromLTRB(
          LuminaTokens.spaceLg,
          0,
          LuminaTokens.spaceLg,
          bottomPad,
        ),
        itemCount: tracks.length,
        itemBuilder: (context, index) {
          final item = tracks[index];
          final resolvedAlbumId = widget.libraryCache?.resolveAlbumIdForTrack(
            item,
          );
          return LibraryTrackRow(
            track: item,
            isPlayingTrack: widget.activeTrackId == item.id,
            multiSelectMode: _multiSelectMode,
            isSelected: _selectedTrackIds.contains(item.id),
            audioService: widget.audioService,
            libraryCache: widget.libraryCache,
            onTap: () => _handleTrackTap(index, item, tracks),
            onToggleSelect: () => _toggleTrackSelection(index, item),
            onPlay: () => unawaited(widget.audioService.play(track: item)),
            onAddToQueue: () => unawaited(_addTracksToQueue([item])),
            onOpenAlbum:
                (widget.onOpenAlbumDetail != null && resolvedAlbumId != null)
                ? () => _openAlbumForTrack(item)
                : null,
            onOpenArtist: widget.onOpenArtist != null
                ? () => widget.onOpenArtist!(item.artist)
                : null,
            onManageTags: () => unawaited(_manageTrackTags([item])),
            onPreferenceChanged: (nextPref) =>
                _handleTrackPreferenceUpdated(item, nextPref),
          );
        },
      ),
    );
  }
}
