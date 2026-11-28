part of 'podcasts_view.dart';

extension _PodcastsSections on _PodcastsViewState {
  List<Widget> _buildSearchSlivers({
    required double availW,
    required PlaybackState playbackState,
  }) {
    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              const Icon(
                Icons.search_rounded,
                size: 17,
                color: LuminaTokens.glassTextSecondary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '「$_searchQuery」的 Podcast 搜尋結果',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton.icon(
                key: const Key('btn_podcast_exit_search'),
                onPressed: _clearSearch,
                style: TextButton.styleFrom(
                  foregroundColor: LuminaTokens.glassTextPrimary,
                ),
                icon: const Icon(Icons.arrow_back_rounded, size: 15),
                label: const Text('返回列表', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
        ),
      ),
    ];

    if (_searching && _searchShows.isEmpty && _searchEpisodes.isEmpty) {
      slivers.add(
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: CircularProgressIndicator(
              key: Key('podcast_search_loading'),
              strokeWidth: 2.2,
              color: LuminaTokens.glassTextPrimary,
            ),
          ),
        ),
      );
      return slivers;
    }

    if (_searchError != null &&
        _searchShows.isEmpty &&
        _searchEpisodes.isEmpty) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text(
              _searchError!,
              style: const TextStyle(
                color: LuminaTokens.statusError,
                fontSize: 13,
              ),
            ),
          ),
        ),
      );
      return slivers;
    }

    if (_searchShows.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildSectionHeader(
            icon: Icons.podcasts_rounded,
            title: 'Podcast 節目（${_searchShows.length}）',
          ),
        ),
      );
      slivers.add(
        _buildShowsGridSliver(shows: _searchShows, availW: availW),
      );
    }

    if (_searchEpisodes.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: _searchShows.isNotEmpty ? 18 : 0),
            child: _buildSectionHeader(
              icon: Icons.headphones_rounded,
              title: '單集節目（${_searchEpisodes.length}）',
            ),
          ),
        ),
      );
      slivers.add(
        SliverList.builder(
          itemCount: _searchEpisodes.length,
          itemBuilder: (context, index) => _buildEpisodeTile(
            episode: _searchEpisodes[index],
            contextEpisodes: _searchEpisodes,
            playbackState: playbackState,
            isCompact: availW < 520,
          ),
        ),
      );
    }

    if (_searchShows.isEmpty && _searchEpisodes.isEmpty) {
      slivers.add(
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text(
              '找不到符合的 Podcast 節目或單集',
              style: TextStyle(
                color: LuminaTokens.textMuted,
                fontSize: 13,
              ),
            ),
          ),
        ),
      );
    }

    return slivers;
  }

  Widget _buildGuestLoginPromptCard() {
    return Container(
      key: const Key('podcast_guest_login_card'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        border: Border.all(color: LuminaTokens.glassCardBorder),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 10,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cloud_sync_outlined,
                size: 20,
                color: LuminaTokens.glassTextPrimary,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Text(
                      '登入 YouTube Music 同步訂閱節目與最新單集',
                      style: TextStyle(
                        color: LuminaTokens.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '未登入時仍可直接於「探索推薦」或搜尋收藏節目並即時播放所有單集。',
                      style: TextStyle(
                        color: LuminaTokens.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.onOpenLogin != null)
                FilledButton.icon(
                  key: const Key('btn_podcast_open_login'),
                  onPressed: widget.onOpenLogin,
                  icon: const Icon(Icons.login_rounded, size: 16),
                  label: const Text(
                    '登入 YouTube Music',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: LuminaTokens.glassSwitchOnTrack,
                    foregroundColor: LuminaTokens.onAccentDark,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 8,
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                key: const Key('btn_podcast_switch_to_explore'),
                onPressed: () => _setState(() {
                  _userSelectedTab = true;
                  _selectedTab = 1;
                }),
                icon: const Icon(Icons.explore_outlined, size: 16),
                label: const Text(
                  '探索推薦',
                  style: TextStyle(fontSize: 12.5),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: LuminaTokens.glassTextPrimary,
                  backgroundColor: LuminaTokens.glassPillBg,
                  side: const BorderSide(color: LuminaTokens.glassPillBorder),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyMyShowsCard() {
    return Container(
      key: const Key('podcast_empty_my_shows_card'),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        border: Border.all(color: LuminaTokens.glassCardBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.podcasts_rounded,
            size: 36,
            color: LuminaTokens.textMuted,
          ),
          const SizedBox(height: 10),
          const Text(
            '尚無收藏或訂閱的 Podcast 節目',
            style: TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '前往「探索推薦」或使用上方搜尋框發掘感興趣的 YouTube Music Podcast 節目並加入收藏。',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: LuminaTokens.textSecondary,
              fontSize: 12.5,
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            key: const Key('btn_empty_go_explore'),
            onPressed: () => _setState(() {
              _userSelectedTab = true;
              _selectedTab = 1;
            }),
            icon: const Icon(Icons.explore_rounded, size: 16),
            label: const Text('瀏覽探索推薦'),
            style: OutlinedButton.styleFrom(
              foregroundColor: LuminaTokens.glassTextPrimary,
              backgroundColor: LuminaTokens.glassPillBg,
              side: const BorderSide(color: LuminaTokens.glassPillBorder),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader({
    required IconData icon,
    required String title,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, size: 17, color: LuminaTokens.glassTextSecondary),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
