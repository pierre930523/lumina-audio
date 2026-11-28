part of 'albums_and_credits_view.dart';

extension _AlbumsAndCreditsSections on _AlbumsAndCreditsViewState {
  Widget _buildView(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return LayoutBuilder(
      builder: (context, outerConstraints) {
        final availW = math
            .max(120.0, outerConstraints.maxWidth - LuminaTokens.spaceLg * 2)
            .toDouble();

        final topControls = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LuminaTokens.spaceLg,
                vertical: LuminaTokens.spaceXs,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: LuminaTokens.spaceXs,
                      runSpacing: LuminaTokens.spaceXs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ChoiceChip(
                          label: Text(
                            '專輯與發行版本',
                            style: TextStyle(
                              color: !_showCreditsGraph
                                  ? Colors.white
                                  : LuminaTokens.glassTextSecondary,
                              fontWeight: !_showCreditsGraph
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                          selected: !_showCreditsGraph,
                          showCheckmark: false,
                          surfaceTintColor: Colors.transparent,
                          backgroundColor: LuminaTokens.glassPillBg,
                          selectedColor: LuminaTokens.glassSegmentSelectedBg,
                          side: BorderSide(
                            color: !_showCreditsGraph
                                ? LuminaTokens.glassSegmentSelectedBorder
                                : LuminaTokens.glassPillBorder,
                          ),
                          onSelected: (_) =>
                              _setState(() => _showCreditsGraph = false),
                        ),
                        ChoiceChip(
                          label: Text(
                            '製作人員關係圖',
                            style: TextStyle(
                              color: _showCreditsGraph
                                  ? Colors.white
                                  : LuminaTokens.glassTextSecondary,
                              fontWeight: _showCreditsGraph
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                          selected: _showCreditsGraph,
                          showCheckmark: false,
                          surfaceTintColor: Colors.transparent,
                          backgroundColor: LuminaTokens.glassPillBg,
                          selectedColor: LuminaTokens.glassSegmentSelectedBg,
                          side: BorderSide(
                            color: _showCreditsGraph
                                ? LuminaTokens.glassSegmentSelectedBorder
                                : LuminaTokens.glassPillBorder,
                          ),
                          onSelected: (_) =>
                              _setState(() => _showCreditsGraph = true),
                        ),
                        OutlinedButton.icon(
                          key: const Key('btn_deduplicate_albums'),
                          style: OutlinedButton.styleFrom(
                            backgroundColor: LuminaTokens.glassPillBg,
                            foregroundColor: LuminaTokens.glassTextPrimary,
                            side: const BorderSide(
                              color: LuminaTokens.glassPillBorder,
                            ),
                          ),
                          onPressed: _deduplicate,
                          icon: const Icon(Icons.merge_type_rounded, size: 16),
                          label: const Text('合併重複專輯'),
                        ),
                        OutlinedButton.icon(
                          key: const Key('btn_enrich_credits'),
                          style: OutlinedButton.styleFrom(
                            backgroundColor: LuminaTokens.glassPillBg,
                            foregroundColor: LuminaTokens.glassTextPrimary,
                            side: const BorderSide(
                              color: LuminaTokens.glassPillBorder,
                            ),
                          ),
                          onPressed: _enrichCredits,
                          icon: const Icon(
                            Icons.auto_awesome_rounded,
                            size: 16,
                          ),
                          label: const Text('補全製作人員'),
                        ),
                        if (!_showCreditsGraph) ...[
                          OutlinedButton.icon(
                            key: const Key('btn_album_multi_select'),
                            style: OutlinedButton.styleFrom(
                              backgroundColor: _multiSelectMode
                                  ? LuminaTokens.glassSegmentSelectedBg
                                  : LuminaTokens.glassPillBg,
                              foregroundColor: _multiSelectMode
                                  ? Colors.white
                                  : LuminaTokens.glassTextPrimary,
                              side: BorderSide(
                                color: _multiSelectMode
                                    ? LuminaTokens.accentBlue
                                    : LuminaTokens.glassPillBorder,
                              ),
                            ),
                            onPressed: _toggleMultiSelectMode,
                            icon: Icon(
                              _multiSelectMode
                                  ? Icons.check_box_rounded
                                  : Icons.checklist_rounded,
                              size: 16,
                            ),
                            label: Text(_multiSelectMode ? '完成多選' : '多選'),
                          ),
                          ListenableBuilder(
                            listenable: _effectiveLayoutController,
                            builder: (context, _) {
                              final showHidden =
                                  _effectiveLayoutController.showHiddenAlbums;
                              return FilterChip(
                                key: const Key('toggle_show_hidden_albums'),
                                label: Text(
                                  '顯示隱藏與重複版本',
                                  style: TextStyle(
                                    color: showHidden
                                        ? Colors.white
                                        : LuminaTokens.glassTextSecondary,
                                    fontSize: 12.5,
                                    fontWeight: showHidden
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                  ),
                                ),
                                selected: showHidden,
                                showCheckmark: false,
                                avatar: Icon(
                                  showHidden
                                      ? Icons.visibility_rounded
                                      : Icons.visibility_off_outlined,
                                  size: 15,
                                  color: showHidden
                                      ? Colors.white
                                      : LuminaTokens.glassTextSecondary,
                                ),
                                surfaceTintColor: Colors.transparent,
                                backgroundColor: LuminaTokens.glassPillBg,
                                selectedColor:
                                    LuminaTokens.glassSegmentSelectedBg,
                                side: BorderSide(
                                  color: showHidden
                                      ? LuminaTokens.glassSegmentSelectedBorder
                                      : LuminaTokens.glassPillBorder,
                                ),
                                onSelected: _effectiveLayoutController
                                    .setShowHiddenAlbums,
                              );
                            },
                          ),
                        ],
                        if (_statusMessage != null)
                          Text(
                            _statusMessage!,
                            style: const TextStyle(
                              color: LuminaTokens.statusSuccess,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (!_showCreditsGraph) ...[
                    const SizedBox(width: LuminaTokens.spaceXs),
                    AlbumLayoutSettingsButton(
                      controller: _effectiveLayoutController,
                      availableWidth: availW,
                    ),
                  ],
                ],
              ),
            ),
            if (!_showCreditsGraph)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  LuminaTokens.spaceLg,
                  2,
                  LuminaTokens.spaceLg,
                  LuminaTokens.spaceXs,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FocusToolbar(controller: _focusController),
                    FocusFilterDrawer(controller: _focusController),
                  ],
                ),
              ),
          ],
        );

        final compactHeader = outerConstraints.maxHeight.isFinite &&
            outerConstraints.maxHeight < 460;
        final headerWidget = compactHeader
            ? ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: math.max(0.0, outerConstraints.maxHeight * 0.55),
                ),
                child: SmoothScrollWrapper(
                  controller: _compactHeaderScrollController,
                  child: SingleChildScrollView(
                    controller: _compactHeaderScrollController,
                    child: topControls,
                  ),
                ),
              )
            : topControls;

        return Column(
          children: [
            headerWidget,
            Expanded(
              child: _showCreditsGraph
                  ? _buildCreditsGraph()
                  : Stack(
                      children: [
                        Positioned.fill(child: _buildAlbumsCollection()),
                        if (_selectedKeys.isNotEmpty)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: AlbumSelectionBar(
                              selectedAlbums: _selectedAlbumItems,
                              busy: _groupingBusy,
                              onMerge: _handleSelectionMerge,
                              onGroupAsAlternate:
                                  _handleSelectionGroupAsAlternate,
                              onToggleHide: _handleSelectionToggleHide,
                              onManageTags: _handleSelectionManageTags,
                              onBulkEdit: _handleSelectionBulkEdit,
                              onExport: _handleSelectionExport,
                              onClearSelection: _clearSelection,
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildAlbumsCollection() {
    final visibleAlbums = _displayedAlbums;
    if (visibleAlbums.isEmpty) {
      return Center(
        child: Text(
          _focusController.isActive
              ? '目前 Focus 篩選條件下沒有符合的專輯，請調整或清除條件。'
              : '尚未掃描任何音樂專輯，請至設定掃描音樂資料夾。',
          style: const TextStyle(
            color: LuminaTokens.textSecondary,
            fontSize: 13.5,
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final availW = math
            .max(120.0, constraints.maxWidth - LuminaTokens.spaceLg * 2)
            .toDouble();

        return ListenableBuilder(
          listenable: _effectiveLayoutController,
          builder: (context, _) {
            final viewMode = _effectiveLayoutController.viewMode;
            final showCardContainer =
                _effectiveLayoutController.showCardContainer;
            final showHiddenMode = _effectiveLayoutController.showHiddenAlbums;
            final bottomPad = _selectedKeys.isNotEmpty
                ? LuminaTokens.bottomScrollClearance + 80.0
                : LuminaTokens.bottomScrollClearance;

            Key cardKeyFor(int index, CanonicalAlbumSummary album) {
              final hasEarlierSameId = visibleAlbums
                  .take(index)
                  .any((other) => other.id == album.id);
              return hasEarlierSameId
                  ? Key('album_card_${album.id}_${album.selectionKey}')
                  : Key('album_card_${album.id}');
            }

            if (viewMode == AlbumViewMode.list) {
              return SmoothScrollWrapper(
                controller: _scrollController,
                child: ListView.separated(
                  key: const Key('album_list_view'),
                  controller: _scrollController,
                  padding: EdgeInsets.fromLTRB(
                    LuminaTokens.spaceLg,
                    LuminaTokens.spaceMd,
                    LuminaTokens.spaceLg,
                    bottomPad,
                  ),
                  itemCount: visibleAlbums.length,
                  separatorBuilder: (context, index) => showCardContainer
                      ? const SizedBox(height: 8)
                      : const Divider(
                          height: 1,
                          thickness: 1,
                          color: LuminaTokens.glassCardDivider,
                        ),
                  itemBuilder: (context, index) {
                    final album = visibleAlbums[index];
                    return AlbumCollectionListTile(
                      key: cardKeyFor(index, album),
                      album: album,
                      coverRevision: _coverRevision,
                      audioService: widget.audioService,
                      libraryCache: widget.libraryCache,
                      listenLaterController: widget.listenLaterController,
                      showCardContainer: showCardContainer,
                      showHiddenMode: showHiddenMode,
                      multiSelectMode: _multiSelectMode,
                      isSelected: _selectedKeys.contains(album.selectionKey),
                      onOpenAlbumDetail: () =>
                          _openAlbum(album.effectiveGroupId),
                      onTapTile: () => _handleAlbumCardTap(index, album),
                      onToggleSelect: () =>
                          _toggleItemSelection(index, album),
                      onPlayAlbum: () => _playAlbum(album),
                      onAddToQueue: () => _addAlbumToQueue(album),
                      onOpenArtist: () => _openArtistForAlbum(album),
                    );
                  },
                ),
              );
            }

            final crossCount =
                _effectiveLayoutController.computeCrossAxisCount(availW);
            final spacing = _effectiveLayoutController.spacing;
            final itemWidth = math.max(
              80.0,
              (availW - spacing * (crossCount - 1)) / crossCount,
            );
            final mainExtent = itemWidth + (showCardContainer ? 76.0 : 58.0);

            return SmoothScrollWrapper(
              controller: _scrollController,
              child: GridView.builder(
                key: const Key('album_grid_view'),
                controller: _scrollController,
                padding: EdgeInsets.fromLTRB(
                  LuminaTokens.spaceLg,
                  LuminaTokens.spaceLg,
                  LuminaTokens.spaceLg,
                  bottomPad,
                ),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossCount,
                  crossAxisSpacing: spacing,
                  mainAxisSpacing: spacing,
                  mainAxisExtent: mainExtent,
                ),
                itemCount: visibleAlbums.length,
                itemBuilder: (context, index) {
                  final album = visibleAlbums[index];
                  return AlbumCollectionCard(
                    key: cardKeyFor(index, album),
                    album: album,
                    coverRevision: _coverRevision,
                    audioService: widget.audioService,
                    libraryCache: widget.libraryCache,
                    listenLaterController: widget.listenLaterController,
                    showCardContainer: showCardContainer,
                    showHiddenMode: showHiddenMode,
                    multiSelectMode: _multiSelectMode,
                    isSelected: _selectedKeys.contains(album.selectionKey),
                    onOpenAlbumDetail: () => _openAlbum(album.effectiveGroupId),
                    onTapCard: () => _handleAlbumCardTap(index, album),
                    onToggleSelect: () => _toggleItemSelection(index, album),
                    onPlayAlbum: () => _playAlbum(album),
                    onAddToQueue: () => _addAlbumToQueue(album),
                    onOpenArtist: () => _openArtistForAlbum(album),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _handleSelectionBulkEdit() async {
    final selected = _selectedAlbumItems;
    if (selected.isEmpty || _groupingBusy) return;
    final groupIds = selected
        .map((a) => a.effectiveGroupId)
        .toSet()
        .toList(growable: false);
    final result = await showBulkEditDialog(
      context: context,
      audioService: widget.audioService,
      entityType: BulkEditEntityType.album,
      entityIds: groupIds,
    );
    if (!mounted || result == null) return;
    if (_focusController.isActive || _focusController.drawerOpen) {
      unawaited(_focusController.refresh(immediate: true));
    }
    final msg = result.revertedCount > 0
        ? '已還原 ${result.revertedCount} 張專輯的原始檔案標籤'
        : '已完成 ${groupIds.length} 張專輯的批量編輯';
    await _refreshAfterGroupingMutation(msg);
  }

  Future<void> _handleSelectionExport() async {
    final selected = _selectedAlbumItems;
    if (selected.isEmpty || _groupingBusy) return;
    final groupIds = selected
        .map((a) => a.effectiveGroupId)
        .toSet()
        .toList(growable: false);
    await LibraryExportDialog.show(
      context,
      audioService: widget.audioService,
      initialSource: CatalogExportAlbumsSource(groupIds),
      defaultPlaylistName: 'Selected Albums',
    );
  }
}
