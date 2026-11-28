part of 'streaming_service_view.dart';

extension _StreamingPlaylistsAlbumsTabs on _StreamingServiceViewState {
  List<Widget> _buildPlaylistsSlivers({
    required double availW,
    required StreamingProvider? liveProvider,
  }) {
    final query = _filterCtrl.text.trim().toLowerCase();
    final activePlaylist = _activePlaylist;
    if (activePlaylist != null) {
      final visibleTracks = _filterTracks(_playlistTracks, query);
      final slivers = <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: LuminaTokens.spaceSm),
            child: Row(
              children: [
                OutlinedButton.icon(
                  key: const Key('btn_back_to_playlists'),
                  onPressed: () => _setState(() {
                    _activePlaylist = null;
                    _playlistError = null;
                  }),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: LuminaTokens.glassTextPrimary,
                    backgroundColor: LuminaTokens.glassPillBg,
                    side: const BorderSide(color: LuminaTokens.glassPillBorder),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  icon: const Icon(Icons.arrow_back_rounded, size: 16),
                  label: const Text('返回歌單'),
                ),
                const SizedBox(width: LuminaTokens.spaceSm),
                Expanded(
                  child: Text(
                    activePlaylist.title,
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
          ),
        ),
      ];

      if (_playlistError != null) {
        slivers.add(
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: LuminaTokens.spaceSm),
              child: _buildErrorBanner(_playlistError!),
            ),
          ),
        );
      }

      if (_loadingPlaylist) {
        slivers.add(
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 36),
              child: Center(
                child: CircularProgressIndicator(
                  color: LuminaTokens.glassTextPrimary,
                ),
              ),
            ),
          ),
        );
      } else if (visibleTracks.isEmpty) {
        slivers.add(
          SliverToBoxAdapter(
            child: _buildCompactBanner(
              bannerKey: const Key('streaming_playlist_empty_banner'),
              icon: Icons.queue_music_rounded,
              iconColor: LuminaTokens.textMuted,
              title: query.isNotEmpty
                  ? '歌單中找不到符合「${_filterCtrl.text.trim()}」的曲目'
                  : '此歌單目前沒有可顯示的曲目',
              subtitle: '您可以回到歌單列表或重新同步曲庫。',
              actionLabel: query.isNotEmpty ? '清除篩選' : null,
              onAction: query.isNotEmpty
                  ? () {
                      _filterCtrl.clear();
                      _setState(() {});
                    }
                  : null,
            ),
          ),
        );
      } else {
        slivers.add(
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _buildTrackRow(
                visibleTracks[index],
                availW: availW,
                queueContext: visibleTracks,
              ),
              childCount: visibleTracks.length,
            ),
          ),
        );
      }

      return slivers;
    }

    final allPlaylists =
        liveProvider?.catalog.playlists ?? const <StreamingPlaylist>[];
    final playlists = query.isEmpty
        ? allPlaylists
        : allPlaylists.where((pl) {
            return pl.title.toLowerCase().contains(query) ||
                (pl.description?.toLowerCase().contains(query) ?? false);
          }).toList(growable: false);

    if (allPlaylists.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: _isGuestMode
              ? _buildCompactBanner(
                  bannerKey: const Key('streaming_guest_login_banner'),
                  icon: Icons.person_outline_rounded,
                  iconColor: LuminaTokens.glassTextSecondary,
                  title: '登入 ${widget.provider.name} 以存取個人歌單',
                  subtitle: '免登入模式仍可於「探索推薦」與搜尋直接播放曲目。',
                  actionLabel: '前往登入',
                  onAction: widget.onOpenProviderSettings,
                )
              : _buildCompactBanner(
                  bannerKey: const Key('streaming_playlists_empty_banner'),
                  icon: Icons.queue_music_rounded,
                  iconColor: LuminaTokens.glassTextSecondary,
                  title: '目前尚無已同步的 ${widget.provider.name} 歌單',
                  subtitle: '點擊右側「立即同步」以載入您的線上歌單。',
                  actionLabel: '立即同步',
                  onAction: _syncing ? null : _syncCatalog,
                ),
        ),
      ];
    }

    if (playlists.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: _buildCompactBanner(
            bannerKey: const Key('streaming_playlists_filter_empty'),
            icon: Icons.search_off_rounded,
            iconColor: LuminaTokens.textMuted,
            title: '找不到符合「${_filterCtrl.text.trim()}」的歌單',
            subtitle: '請嘗試調整關鍵字或清除篩選。',
            actionLabel: '清除篩選',
            onAction: () {
              _filterCtrl.clear();
              _setState(() {});
            },
          ),
        ),
      ];
    }

    return <Widget>[
      SliverToBoxAdapter(
        child: _buildSectionHeader(title: '歌單', count: playlists.length),
      ),
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final pl = playlists[index];
            final subtitle =
                pl.description != null && pl.description!.trim().isNotEmpty
                    ? pl.description!
                    : '${pl.trackCount} 首曲目';
            return Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: Key('streaming_playlist_${pl.id}'),
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                hoverColor: LuminaTokens.glassRowHoverBg,
                onTap: () => _openPlaylist(pl),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  child: Row(
                    children: [
                      _buildThumbnail(
                        pl.coverUrl,
                        size: 40,
                        fallbackIcon: Icons.queue_music_rounded,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              pl.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: LuminaTokens.textPrimary,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: LuminaTokens.textMuted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: LuminaTokens.textSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
          childCount: playlists.length,
        ),
      ),
    ];
  }

  List<Widget> _buildAlbumsSlivers({
    required double availW,
    required StreamingProvider? liveProvider,
  }) {
    final query = _filterCtrl.text.trim().toLowerCase();
    final allAlbums =
        liveProvider?.catalog.albums ?? const <StreamingAlbum>[];
    final albums = _filterAlbums(allAlbums, query);

    if (allAlbums.isEmpty) {
      final recAlbums = _filterAlbums(
        widget.streamingManager
                ?.recommendationsFor(widget.provider.kind)
                ?.albums ??
            const <StreamingAlbum>[],
        query,
      );
      return <Widget>[
        SliverToBoxAdapter(
          child: _isGuestMode
              ? _buildCompactBanner(
                  bannerKey: const Key('streaming_guest_login_banner'),
                  icon: Icons.person_outline_rounded,
                  iconColor: LuminaTokens.glassTextSecondary,
                  title: '登入 ${widget.provider.name} 以同步收藏專輯',
                  subtitle: '免登入模式仍可自由瀏覽並播放下方推薦專輯。',
                  actionLabel: '前往登入',
                  onAction: widget.onOpenProviderSettings,
                )
              : _buildCompactBanner(
                  bannerKey: const Key('streaming_albums_empty_banner'),
                  icon: Icons.album_outlined,
                  iconColor: LuminaTokens.glassTextSecondary,
                  title: '目前尚無已同步的 ${widget.provider.name} 專輯',
                  subtitle: '點擊右側「立即同步」以載入您收藏的串流專輯。',
                  actionLabel: '立即同步',
                  onAction: _syncing ? null : _syncCatalog,
                ),
        ),
        if (recAlbums.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SizedBox(height: 14)),
          SliverToBoxAdapter(
            child: _buildSectionHeader(
              title: '為你推薦的專輯',
              count: recAlbums.length,
            ),
          ),
          _buildAlbumsSliverGrid(recAlbums),
        ],
      ];
    }

    if (albums.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: _buildCompactBanner(
            bannerKey: const Key('streaming_albums_filter_empty'),
            icon: Icons.search_off_rounded,
            iconColor: LuminaTokens.textMuted,
            title: '找不到符合「${_filterCtrl.text.trim()}」的專輯',
            subtitle: '請嘗試調整關鍵字或清除篩選。',
            actionLabel: '清除篩選',
            onAction: () {
              _filterCtrl.clear();
              _setState(() {});
            },
          ),
        ),
      ];
    }

    return <Widget>[
      SliverToBoxAdapter(
        child: _buildSectionHeader(title: '專輯', count: albums.length),
      ),
      _buildAlbumsSliverGrid(
        albums,
        keyPrefix: 'streaming_album_',
      ),
    ];
  }
}
