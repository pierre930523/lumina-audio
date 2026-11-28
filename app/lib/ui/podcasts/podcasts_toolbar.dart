part of 'podcasts_view.dart';

extension _PodcastsToolbar on _PodcastsViewState {
  Widget _buildFrostedToolbar({required double availW}) {
    final isWideSingleRow = availW >= 860;
    final isConnected = _isConnected;

    return FrostedGlassContainer(
      key: const Key('podcasts_compact_toolbar'),
      blurSigma: LuminaTokens.glassPillBlur,
      color: LuminaTokens.glassSidebarBg,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: LuminaTokens.glassSidebarBorder),
      padding: EdgeInsets.symmetric(
        horizontal: availW < 540 ? 10 : 14,
        vertical: isWideSingleRow ? 9 : 10,
      ),
      child: isWideSingleRow
          ? Row(
              children: [
                _buildToolbarTitleBadge(isConnected: isConnected),
                const SizedBox(width: 12),
                _buildSegmentedTabs(availW: availW),
                const SizedBox(width: 12),
                Expanded(child: _buildSearchField()),
                const SizedBox(width: 8),
                _buildQuickSearchAddButton(compact: availW < 1040),
                const SizedBox(width: 6),
                _buildRefreshButton(),
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _buildToolbarTitleBadge(
                        isConnected: isConnected,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: _buildSegmentedTabs(availW: availW),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _buildRefreshButton(),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _buildSearchField()),
                    const SizedBox(width: 8),
                    _buildQuickSearchAddButton(compact: availW < 520),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _buildToolbarTitleBadge({required bool isConnected}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: LuminaTokens.glassPillBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: LuminaTokens.glassPillBorder),
          ),
          child: const Icon(
            Icons.podcasts_rounded,
            size: 18,
            color: LuminaTokens.glassTextPrimary,
          ),
        ),
        const SizedBox(width: 9),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Flexible(
                    child: Text(
                      'Podcast',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: LuminaTokens.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: isConnected
                          ? LuminaTokens.statusSuccess
                          : LuminaTokens.glassTextSecondary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 1),
              Text(
                isConnected
                    ? 'YouTube Music 已連線 · 同步訂閱與單集'
                    : 'YouTube Music 免登入探索與即時播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 11,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSegmentedTabs({required double availW}) {
    final showIcons = availW >= 720;
    final horizontalPad = availW >= 840 ? 12.0 : 9.0;

    return Container(
      height: 34,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: LuminaTokens.glassSegmentTrackBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        border: Border.all(color: LuminaTokens.glassSegmentTrackBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final tab in _PodcastsViewState._tabs)
            Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: Key(tab.keyName),
                borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
                onTap: () {
                  _setState(() {
                    _userSelectedTab = true;
                    _selectedTab = tab.idx;
                    if (_searchQuery.isNotEmpty) {
                      _clearSearch();
                    }
                  });
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  height: 28,
                  padding: EdgeInsets.symmetric(horizontal: horizontalPad),
                  decoration: BoxDecoration(
                    borderRadius:
                        BorderRadius.circular(LuminaTokens.radiusPill),
                    color: (_selectedTab == tab.idx && _searchQuery.isEmpty)
                        ? LuminaTokens.glassSegmentSelectedBg
                        : Colors.transparent,
                    border: (_selectedTab == tab.idx && _searchQuery.isEmpty)
                        ? Border.all(
                            color: LuminaTokens.glassSegmentSelectedBorder,
                          )
                        : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showIcons) ...[
                        Icon(
                          tab.icon,
                          size: 13.5,
                          color:
                              (_selectedTab == tab.idx && _searchQuery.isEmpty)
                                  ? Colors.white
                                  : LuminaTokens.glassTextSecondary,
                        ),
                        const SizedBox(width: 5),
                      ],
                      Text(
                        tab.label,
                        style: TextStyle(
                          color:
                              (_selectedTab == tab.idx && _searchQuery.isEmpty)
                                  ? Colors.white
                                  : LuminaTokens.glassTextSecondary,
                          fontSize: 12,
                          fontWeight:
                              (_selectedTab == tab.idx && _searchQuery.isEmpty)
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    final hasFocus = _searchFocusNode.hasFocus;
    final hasText = _searchCtrl.text.isNotEmpty;

    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: LuminaTokens.glassPillBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        border: Border.all(
          color: hasFocus ? LuminaTokens.focusRing : LuminaTokens.glassPillBorder,
          width: hasFocus ? 1.4 : 1.0,
        ),
      ),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 10, right: 6),
            child: Icon(
              Icons.search_rounded,
              size: 15,
              color: LuminaTokens.textSecondary,
            ),
          ),
          Expanded(
            child: TextField(
              key: const Key('podcast_search_input'),
              controller: _searchCtrl,
              focusNode: _searchFocusNode,
              onChanged: _onSearchChanged,
              onSubmitted: _performSearch,
              maxLines: 1,
              textAlignVertical: TextAlignVertical.center,
              style: const TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 12.5,
                height: 1.2,
              ),
              cursorColor: LuminaTokens.glassTextPrimary,
              decoration: const InputDecoration(
                isDense: true,
                isCollapsed: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: '搜尋 YouTube Music Podcast 節目或單集...',
                hintStyle: TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 12,
                ),
                contentPadding: EdgeInsets.symmetric(vertical: 4),
              ),
            ),
          ),
          if (hasText)
            IconButton(
              key: const Key('btn_podcast_search_clear'),
              tooltip: '清除搜尋',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              icon: const Icon(
                Icons.close_rounded,
                size: 15,
                color: LuminaTokens.textSecondary,
              ),
              onPressed: _clearSearch,
            ),
        ],
      ),
    );
  }

  Widget _buildQuickSearchAddButton({required bool compact}) {
    if (compact) {
      return IconButton(
        key: const Key('btn_podcast_focus_search'),
        tooltip: '搜尋／新增 Podcast',
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        padding: EdgeInsets.zero,
        icon: const Icon(
          Icons.add_circle_outline_rounded,
          size: 18,
          color: LuminaTokens.glassTextPrimary,
        ),
        onPressed: _focusSearch,
      );
    }
    return OutlinedButton.icon(
      key: const Key('btn_podcast_focus_search'),
      onPressed: _focusSearch,
      icon: const Icon(Icons.add_rounded, size: 15),
      label: const Text(
        '搜尋／新增 Podcast',
        style: TextStyle(fontSize: 12),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: LuminaTokens.glassTextPrimary,
        backgroundColor: LuminaTokens.glassPillBg,
        side: const BorderSide(color: LuminaTokens.glassPillBorder),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
    );
  }

  Widget _buildRefreshButton() {
    final isLoading = _loadingExplore || _loadingMyPodcasts || _searching;
    return IconButton(
      key: const Key('btn_podcast_refresh'),
      tooltip: '重新整理 Podcast',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      icon: isLoading
          ? const SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: LuminaTokens.glassTextPrimary,
              ),
            )
          : const Icon(
              Icons.refresh_rounded,
              size: 18,
              color: LuminaTokens.textSecondary,
            ),
      onPressed: isLoading
          ? null
          : () {
              if (_searchQuery.isNotEmpty) {
                _performSearch(_searchQuery);
              } else {
                _refreshFeeds();
              }
            },
    );
  }
}
