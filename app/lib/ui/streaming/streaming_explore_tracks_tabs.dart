part of 'streaming_service_view.dart';

extension _StreamingExploreTracksTabs on _StreamingServiceViewState {
  List<Widget> _buildExploreSlivers({required double availW}) {
    final sm = widget.streamingManager;
    final kind = widget.provider.kind;
    final rec = sm?.recommendationsFor(kind);
    final isLoading = sm?.isLoadingRecommendations(kind) ?? false;
    final recError = sm?.recommendationErrorFor(kind);
    final query = _filterCtrl.text.trim().toLowerCase();

    final recAlbums = _filterAlbums(
      rec?.albums ?? const <StreamingAlbum>[],
      query,
    );
    final recTracks = _filterTracks(
      rec?.tracks ?? const <TrackInfo>[],
      query,
    );

    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: _buildSectionHeader(
          title: '為你推薦的專輯',
          trailing: _buildRefreshRecButton(
            buttonKey: const Key('btn_streaming_refresh_recommendations'),
            isLoading: isLoading,
          ),
        ),
      ),
    ];

    if (recError != null && recError.trim().isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: LuminaTokens.spaceSm),
            child: _buildRecErrorBanner(kind, recError),
          ),
        ),
      );
    }

    if (isLoading && recAlbums.isEmpty && recTracks.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildRecommendedAlbumsSkeleton(availW),
        ),
      );
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 18)));
      slivers.add(
        SliverToBoxAdapter(
          child: _buildSectionHeader(title: '推薦歌曲'),
        ),
      );
      slivers.add(
        SliverToBoxAdapter(
          child: _buildRecommendedTracksSkeleton(),
        ),
      );
      return slivers;
    }

    if (recAlbums.isEmpty &&
        recTracks.isEmpty &&
        (recError == null || recError.trim().isEmpty)) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildCompactBanner(
            bannerKey: const Key('streaming_explore_empty_banner'),
            icon: Icons.explore_outlined,
            iconColor: LuminaTokens.glassTextSecondary,
            title: query.isNotEmpty
                ? '找不到符合「${_filterCtrl.text.trim()}」的推薦內容'
                : '尚無 ${widget.provider.name} 個人化推薦項目',
            subtitle: query.isNotEmpty
                ? '請清除篩選條件或嘗試其他關鍵字。'
                : '點擊右側「換一批」向 ${widget.provider.name} 取得最新推薦專輯與曲目。',
            actionLabel: query.isNotEmpty
                ? '清除篩選'
                : (sm != null ? '重新取得推薦' : null),
            onAction: query.isNotEmpty
                ? () {
                    _filterCtrl.clear();
                    _setState(() {});
                  }
                : (sm != null ? _handleRefreshRecommendations : null),
          ),
        ),
      );
      return slivers;
    }

    if (isLoading && recAlbums.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildRecommendedAlbumsSkeleton(availW),
        ),
      );
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 18)));
    } else if (recAlbums.isNotEmpty) {
      slivers.add(_buildAlbumsSliverGrid(recAlbums));
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 18)));
    }

    if (isLoading && recTracks.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildSectionHeader(title: '推薦歌曲'),
        ),
      );
      slivers.add(
        SliverToBoxAdapter(
          child: _buildRecommendedTracksSkeleton(),
        ),
      );
    } else if (recTracks.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildSectionHeader(
            title: '推薦歌曲',
            count: recTracks.length,
          ),
        ),
      );
      slivers.add(
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => _buildTrackRow(
              recTracks[index],
              availW: availW,
              queueContext: recTracks,
            ),
            childCount: recTracks.length,
          ),
        ),
      );
    }

    return slivers;
  }

  List<Widget> _buildTracksSlivers({
    required double availW,
    required StreamingProvider? liveProvider,
  }) {
    final query = _filterCtrl.text.trim().toLowerCase();
    final allTracks = _resolveCatalogTracks(liveProvider);
    final filtered = _filterTracks(allTracks, query);
    final sm = widget.streamingManager;
    final kind = widget.provider.kind;
    final rec = sm?.recommendationsFor(kind);
    final recAlbums = rec?.albums ?? const <StreamingAlbum>[];
    final recTracks = rec?.tracks ?? const <TrackInfo>[];
    final isRecLoading = sm?.isLoadingRecommendations(kind) ?? false;
    final hasManualRecRefresh =
        sm?.hasManualRecommendationRefresh(kind) ?? false;
    final recError = sm?.recommendationErrorFor(kind);
    final hasRecError = recError != null && recError.trim().isNotEmpty;

    final slivers = <Widget>[];

    // Show top recommended albums strip on 收藏曲目 when albums exist, an error occurred, or manual 換一批 is loading.
    if (query.isEmpty &&
        (recAlbums.isNotEmpty ||
            hasRecError ||
            (isRecLoading && hasManualRecRefresh))) {
      slivers.add(
        SliverToBoxAdapter(
          key: const Key('streaming_recommended_albums_strip'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSectionHeader(
                title: '為你推薦的專輯',
                trailing: _buildRefreshRecButton(
                  buttonKey: const Key('btn_streaming_strip_refresh'),
                  isLoading: isRecLoading,
                ),
              ),
              if (hasRecError) ...[
                _buildRecErrorBanner(kind, recError),
                if (recAlbums.isNotEmpty || isRecLoading)
                  const SizedBox(height: 12),
              ],
              if (recAlbums.isEmpty && isRecLoading)
                _buildRecommendedAlbumsSkeleton(availW)
              else if (recAlbums.isNotEmpty)
                _buildSingleRowAlbumStrip(recAlbums, availW: availW),
              const SizedBox(height: 18),
            ],
          ),
        ),
      );
    }

    if (allTracks.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: _isGuestMode
              ? _buildCompactBanner(
                  bannerKey: const Key('streaming_guest_login_banner'),
                  icon: Icons.person_outline_rounded,
                  iconColor: LuminaTokens.glassTextSecondary,
                  title: '目前為 ${widget.provider.name} 免登入瀏覽模式',
                  subtitle: '您可自由使用「探索推薦」、搜尋與播放；登入帳號後即可同步個人收藏曲目。',
                  actionLabel: '前往登入',
                  onAction: widget.onOpenProviderSettings,
                )
              : _buildCompactBanner(
                  bannerKey: const Key('streaming_empty_sync_banner'),
                  icon: Icons.library_music_outlined,
                  iconColor: LuminaTokens.glassTextSecondary,
                  title: '目前尚無已同步的 ${widget.provider.name} 收藏曲目',
                  subtitle: '點擊右側「立即同步」即可匯入您的串流收藏與高解析曲目。',
                  actionLabel: '立即同步',
                  onAction: _syncing ? null : _syncCatalog,
                ),
        ),
      );

      // Keep the page browsable even before first sync when recommendations exist.
      if (recAlbums.isNotEmpty && query.isNotEmpty) {
        final matchedRecAlbums = _filterAlbums(recAlbums, query);
        if (matchedRecAlbums.isNotEmpty) {
          slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 14)));
          slivers.add(
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text(
                  '為你推薦的專輯',
                  style: TextStyle(
                    color: LuminaTokens.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          );
          slivers.add(_buildAlbumsSliverGrid(matchedRecAlbums));
        }
      }

      if (recTracks.isNotEmpty) {
        final visibleRecTracks = _filterTracks(recTracks, query);
        if (visibleRecTracks.isNotEmpty) {
          slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 14)));
          slivers.add(
            SliverToBoxAdapter(
              child: _buildSectionHeader(
                title: '推薦歌曲',
                count: visibleRecTracks.length,
              ),
            ),
          );
          slivers.add(
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildTrackRow(
                  visibleRecTracks[index],
                  availW: availW,
                  queueContext: visibleRecTracks,
                ),
                childCount: visibleRecTracks.length,
              ),
            ),
          );
        }
      }

      return slivers;
    }

    slivers.add(
      SliverToBoxAdapter(
        child: _buildSectionHeader(
          title: '收藏曲目',
          count: filtered.length,
        ),
      ),
    );

    if (filtered.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildCompactBanner(
            bannerKey: const Key('streaming_filter_empty_banner'),
            icon: Icons.search_off_rounded,
            iconColor: LuminaTokens.textMuted,
            title: '找不到符合「${_filterCtrl.text.trim()}」的曲目',
            subtitle: '請嘗試調整關鍵字或清除篩選條件。',
            actionLabel: '清除篩選',
            onAction: () {
              _filterCtrl.clear();
              _setState(() {});
            },
          ),
        ),
      );
      return slivers;
    }

    slivers.add(
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildTrackRow(
            filtered[index],
            availW: availW,
            queueContext: filtered,
          ),
          childCount: filtered.length,
        ),
      ),
    );

    return slivers;
  }
}
