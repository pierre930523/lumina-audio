part of 'podcasts_view.dart';

extension _PodcastsTabs on _PodcastsViewState {
  Widget _buildMainScrollView({
    required double availW,
    required PlaybackState playbackState,
  }) {
    final slivers = <Widget>[];

    if (_searchQuery.isNotEmpty) {
      slivers.addAll(
        _buildSearchSlivers(
          availW: availW,
          playbackState: playbackState,
        ),
      );
    } else if (_selectedTab == 0) {
      slivers.addAll(
        _buildMyShowsSlivers(
          availW: availW,
          playbackState: playbackState,
        ),
      );
    } else if (_selectedTab == 1) {
      slivers.addAll(
        _buildExploreSlivers(
          availW: availW,
          playbackState: playbackState,
        ),
      );
    } else {
      slivers.addAll(
        _buildLatestEpisodesSlivers(
          availW: availW,
          playbackState: playbackState,
        ),
      );
    }

    slivers.add(
      const SliverToBoxAdapter(
        child: SizedBox(height: LuminaTokens.bottomScrollClearance),
      ),
    );

    return SmoothScrollWrapper(
      controller: _scrollController,
      child: CustomScrollView(
        key: const Key('podcasts_list_view'),
        controller: _scrollController,
        slivers: slivers,
      ),
    );
  }

  List<Widget> _buildMyShowsSlivers({
    required double availW,
    required PlaybackState playbackState,
  }) {
    final slivers = <Widget>[];
    final isConnected = _isConnected;
    final mergedShows = _store.mergeWithRemoteShows(_remoteMyShows);

    if (!isConnected) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: _buildGuestLoginPromptCard(),
          ),
        ),
      );
    }

    if (_loadingMyPodcasts && mergedShows.isEmpty) {
      slivers.add(
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: LuminaTokens.glassTextPrimary,
            ),
          ),
        ),
      );
      return slivers;
    }

    if (mergedShows.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildSectionHeader(
            icon: Icons.bookmarks_rounded,
            title: isConnected
                ? '已訂閱與收藏節目（${mergedShows.length}）'
                : '已收藏節目（${mergedShows.length}）',
          ),
        ),
      );
      slivers.add(
        _buildShowsGridSliver(shows: mergedShows, availW: availW),
      );
    } else {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildEmptyMyShowsCard(),
        ),
      );
    }

    if (_remoteMyEpisodes.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 18),
            child: _buildSectionHeader(
              icon: Icons.headphones_rounded,
              title: '訂閱節目最新單集',
            ),
          ),
        ),
      );
      slivers.add(
        SliverList.builder(
          itemCount: _remoteMyEpisodes.length,
          itemBuilder: (context, index) => _buildEpisodeTile(
            episode: _remoteMyEpisodes[index],
            contextEpisodes: _remoteMyEpisodes,
            playbackState: playbackState,
            isCompact: availW < 520,
          ),
        ),
      );
    }

    return slivers;
  }

  List<Widget> _buildExploreSlivers({
    required double availW,
    required PlaybackState playbackState,
  }) {
    final slivers = <Widget>[];

    if (_loadingExplore &&
        _exploreShows.isEmpty &&
        _exploreEpisodes.isEmpty) {
      slivers.add(
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: CircularProgressIndicator(
              key: Key('podcast_explore_loading'),
              strokeWidth: 2.2,
              color: LuminaTokens.glassTextPrimary,
            ),
          ),
        ),
      );
      return slivers;
    }

    if (_feedError != null &&
        _exploreShows.isEmpty &&
        _exploreEpisodes.isEmpty) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _feedError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: LuminaTokens.statusError,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  key: const Key('btn_podcast_explore_retry'),
                  onPressed: _refreshFeeds,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: LuminaTokens.glassTextPrimary,
                    backgroundColor: LuminaTokens.glassPillBg,
                    side: const BorderSide(
                      color: LuminaTokens.glassPillBorder,
                    ),
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('重試'),
                ),
              ],
            ),
          ),
        ),
      );
      return slivers;
    }

    if (_exploreShows.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildSectionHeader(
            icon: Icons.explore_rounded,
            title: '熱門與精選 Podcast 節目',
          ),
        ),
      );
      slivers.add(
        _buildShowsGridSliver(shows: _exploreShows, availW: availW),
      );
    }

    if (_exploreEpisodes.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: _exploreShows.isNotEmpty ? 18 : 0),
            child: _buildSectionHeader(
              icon: Icons.bolt_rounded,
              title: '精選單集即時聽',
            ),
          ),
        ),
      );
      slivers.add(
        SliverList.builder(
          itemCount: _exploreEpisodes.length,
          itemBuilder: (context, index) => _buildEpisodeTile(
            episode: _exploreEpisodes[index],
            contextEpisodes: _exploreEpisodes,
            playbackState: playbackState,
            isCompact: availW < 520,
          ),
        ),
      );
    }

    if (_exploreShows.isEmpty && _exploreEpisodes.isEmpty) {
      slivers.add(
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text(
              '目前尚無推薦 Podcast，請點擊上方重新整理或直接搜尋節目',
              style: TextStyle(
                color: LuminaTokens.textMuted,
                fontSize: 13,
              ),
            ),
          ),
        ),
      );
    } else if (_exploreContinuation != null &&
        _exploreContinuation!.trim().isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: OutlinedButton.icon(
                key: const Key('btn_podcast_explore_load_more'),
                onPressed: _loadingMoreExplore ? null : _loadMoreExplore,
                icon: const Icon(Icons.expand_more_rounded, size: 18),
                label: Text(_loadingMoreExplore ? '載入更多中...' : '載入更多推薦'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: LuminaTokens.glassTextPrimary,
                  backgroundColor: LuminaTokens.glassPillBg,
                  side: const BorderSide(color: LuminaTokens.glassPillBorder),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return slivers;
  }

  List<Widget> _buildLatestEpisodesSlivers({
    required double availW,
    required PlaybackState playbackState,
  }) {
    final episodes = _combinedLatestEpisodes;
    if ((_loadingExplore || _loadingMyPodcasts) && episodes.isEmpty) {
      return <Widget>[
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: LuminaTokens.glassTextPrimary,
            ),
          ),
        ),
      ];
    }

    if (episodes.isEmpty) {
      return <Widget>[
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text(
              '目前尚無最新單集，請使用上方搜尋探索節目',
              style: TextStyle(
                color: LuminaTokens.textMuted,
                fontSize: 13,
              ),
            ),
          ),
        ),
      ];
    }

    return <Widget>[
      SliverToBoxAdapter(
        child: _buildSectionHeader(
          icon: Icons.new_releases_rounded,
          title: '最新單集（${episodes.length}）',
        ),
      ),
      SliverList.builder(
        itemCount: episodes.length,
        itemBuilder: (context, index) => _buildEpisodeTile(
          episode: episodes[index],
          contextEpisodes: episodes,
          playbackState: playbackState,
          isCompact: availW < 520,
        ),
      ),
    ];
  }
}
