part of 'home_dashboard_view.dart';

extension _HomeDashboardSections on _HomeDashboardViewState {
  Widget _buildRecentActivitySection(List<_RecentItem> recentCards) {
    return LayoutBuilder(
      key: const Key('home_recent_activity_card'),
      builder: (context, panelConstraints) {
        final innerW = panelConstraints.maxWidth;
        final maxCols = innerW >= 1020
            ? 5
            : (innerW >= 740 ? 4 : (innerW >= 480 ? 3 : 2));
        final maxOffset = math.max(0, recentCards.length - maxCols);
        final safeOffset = _carouselOffset.clamp(0, maxOffset);
        if (safeOffset != _carouselOffset) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _carouselOffset != safeOffset) {
              _refreshState(() => _carouselOffset = safeOffset);
            }
          });
        }
        final slice = recentCards.skip(safeOffset).take(maxCols).toList();
        final showAddSlot = safeOffset == 0 && slice.length < maxCols;
        final displayedTotal = slice.length + (showAddSlot ? 1 : 0);
        final effectiveCols = math.max(1, math.min(maxCols, displayedTotal));
        const spacing = 16.0;
        final itemWidth =
            (innerW - spacing * (effectiveCols - 1)) / effectiveCols;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '近期活動',
                      style: TextStyle(
                        color: LuminaTokens.glassTextPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(width: 20),
                    _ActivityTabButton(
                      label: '已播放',
                      selected: _showPlayedTab,
                      onTap: () => _refreshState(() {
                        _showPlayedTab = true;
                        _carouselOffset = 0;
                      }),
                    ),
                    const SizedBox(width: 14),
                    _ActivityTabButton(
                      label: '已新增',
                      selected: !_showPlayedTab,
                      onTap: () => _refreshState(() {
                        _showPlayedTab = false;
                        _carouselOffset = 0;
                      }),
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '上一頁活動',
                      visualDensity: VisualDensity.compact,
                      onPressed: safeOffset > 0
                          ? () => _refreshState(
                              () => _carouselOffset = math.max(0, safeOffset - 1),
                            )
                          : null,
                      icon: Icon(
                        Icons.chevron_left_rounded,
                        color: safeOffset > 0
                            ? LuminaTokens.glassTextPrimary
                            : LuminaTokens.textDisabled,
                      ),
                    ),
                    IconButton(
                      tooltip: '下一頁活動',
                      visualDensity: VisualDensity.compact,
                      onPressed: safeOffset + maxCols < recentCards.length
                          ? () => _refreshState(
                              () => _carouselOffset = safeOffset + 1,
                            )
                          : null,
                      icon: Icon(
                        Icons.chevron_right_rounded,
                        color: safeOffset + maxCols < recentCards.length
                            ? LuminaTokens.glassTextPrimary
                            : LuminaTokens.textDisabled,
                      ),
                    ),
                    const SizedBox(width: 6),
                    _GlassSectionActionLink(
                      label: '更多',
                      onTap: widget.onOpenAlbums,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (slice.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: Text(
                    '尚未掃描任何音樂專輯，點擊「曲目庫」或「專輯」開始建立曲庫。',
                    style: TextStyle(color: LuminaTokens.glassTextSecondary),
                  ),
                ),
              )
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var idx = 0; idx < slice.length; idx++)
                    Padding(
                      padding: EdgeInsets.only(
                        right: (!showAddSlot && idx == slice.length - 1)
                            ? 0
                            : spacing,
                      ),
                      child: SizedBox(
                        width: itemWidth,
                        child: _buildRecentAlbumCard(
                          slice[idx],
                          _HomeDashboardViewState._coverPalettes[
                              (idx + safeOffset) %
                                  _HomeDashboardViewState._coverPalettes.length],
                        ),
                      ),
                    ),
                  if (showAddSlot)
                    SizedBox(width: itemWidth, child: _buildImportGuideCard()),
                ],
              ),
          ],
        );
      },
    );
  }

  Widget _buildRecentAlbumCard(_RecentItem item, List<Color> palette) {
    final resolvedAlbum =
        item.album ??
        (item.track != null
            ? widget.libraryCache?.resolveAlbumForTrack(item.track!)
            : null);

    final card = _RecentAlbumCard(
      key: resolvedAlbum != null
          ? Key('home_recent_album_${resolvedAlbum.id}')
          : null,
      item: item,
      album: resolvedAlbum,
      palette: palette,
      audioService: widget.audioService,
      libraryCache: widget.libraryCache,
      showTrackArtwork: _showPlayedTab || resolvedAlbum == null,
      onOpenAlbum: resolvedAlbum != null && widget.onOpenAlbumDetail != null
          ? () => widget.onOpenAlbumDetail!(resolvedAlbum.id)
          : () {
              if (item.track != null) {
                widget.audioService.play(track: item.track);
              } else {
                widget.onOpenAlbums();
              }
            },
      onPlayTrack: item.track != null
          ? () => widget.audioService.play(track: item.track)
          : null,
    );
    return TrackHoverPrefetch(
      track: item.track,
      enabled: _showPlayedTab && item.track != null,
      child: card,
    );
  }

  Widget _buildImportGuideCard() {
    return InkWell(
      key: const Key('home_import_guide_card'),
      borderRadius: BorderRadius.circular(12),
      onTap: widget.onOpenLibrary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: FrostedGlassContainer(
              blurSigma: LuminaTokens.glassPillBlur,
              enableBackdropBlur: false,
              borderRadius: BorderRadius.circular(12),
              color: LuminaTokens.glassPillBg,
              border: Border.all(color: LuminaTokens.glassPillBorder),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.create_new_folder_outlined,
                    size: 38,
                    color: LuminaTokens.glassTextSecondary,
                  ),
                  SizedBox(height: 10),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      '掃描新增音樂資料夾',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: LuminaTokens.glassTextPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '匯入本機無損專輯',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: LuminaTokens.glassTextPrimary,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'FLAC / WAV / DSD / ALAC',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: LuminaTokens.glassTextSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecommendedSection(List<TrackInfo> tracks) {
    final playlists = widget.smartPlaylists;
    final items = <({
      String? playlistId,
      String title,
      String subtitle,
      List<Color> colors,
      IconData icon,
      TrackInfo? coverTrack,
      TrackInfo? playTrack,
    })>[];

    if (playlists.isNotEmpty) {
      for (var i = 0; i < math.min(3, playlists.length); i++) {
        final sp = playlists[i];
        final eval = _smartPlaylistEvals[sp.id];
        final matched = eval?.tracks ?? const <TrackInfo>[];
        final count = eval?.totalMatched ?? matched.length;
        final curated = _HomeDashboardViewState
            ._curatedSets[i % _HomeDashboardViewState._curatedSets.length];
        items.add((
          playlistId: sp.id,
          title: sp.name,
          subtitle: sp.description.isNotEmpty
              ? sp.description
              : '$count 首收錄曲目',
          colors: curated.colors,
          icon: curated.icon,
          coverTrack: matched.firstOrNull,
          playTrack: matched.firstOrNull,
        ));
      }
    } else {
      for (var i = 0; i < _HomeDashboardViewState._curatedSets.length; i++) {
        final preset = _HomeDashboardViewState._curatedSets[i];
        TrackInfo? matched;
        for (final t in tracks) {
          final hay = '${t.title} ${t.artist} ${t.album} ${t.genre ?? ''}'
              .toLowerCase();
          if (preset.keywords.any(hay.contains)) {
            matched = t;
            break;
          }
        }
        matched ??= tracks.isNotEmpty ? tracks[i % tracks.length] : null;
        items.add((
          playlistId: null,
          title: preset.title,
          subtitle: preset.subtitle,
          colors: preset.colors,
          icon: preset.icon,
          coverTrack: matched,
          playTrack: matched,
        ));
      }
    }

    return Column(
      key: const Key('home_recommended_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              '為你推薦',
              style: TextStyle(
                color: LuminaTokens.glassTextPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
            _GlassSectionActionLink(
              label: '探索更多 >',
              onTap: widget.onOpenSmartPlaylists ?? widget.onOpenAlbums,
            ),
          ],
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final cols = w >= 460 ? 3 : (w >= 280 ? 2 : 1);
            const gap = 14.0;
            final cardWidth = (w - gap * (cols - 1)) / cols;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (var i = 0; i < items.length; i++)
                  SizedBox(
                    width: cardWidth,
                    child: _RecommendedPlaylistCard(
                      key: Key('home_recommended_card_$i'),
                      title: items[i].title,
                      subtitle: items[i].subtitle,
                      colors: items[i].colors,
                      icon: items[i].icon,
                      coverTrack: items[i].coverTrack,
                      audioService: widget.audioService,
                      libraryCache: widget.libraryCache,
                      onOpen: () {
                        final pid = items[i].playlistId;
                        if (pid != null && widget.onOpenSmartPlaylist != null) {
                          widget.onOpenSmartPlaylist!(pid);
                        } else if (items[i].playTrack != null) {
                          widget.audioService.play(track: items[i].playTrack);
                        } else {
                          (widget.onOpenSmartPlaylists ?? widget.onOpenAlbums)();
                        }
                      },
                      onPlay: () async {
                        final pid = items[i].playlistId;
                        if (pid != null) {
                          final messenger = ScaffoldMessenger.maybeOf(context);
                          final sp = playlists
                              .where((p) => p.id == pid)
                              .firstOrNull;
                          final ev =
                              _smartPlaylistEvals[pid] ??
                              await widget.audioService.evaluateSmartPlaylist(
                                pid,
                              );
                          final tracks = ev?.tracks ?? const <TrackInfo>[];
                          final excludeBanned = sp?.excludeBanned ?? true;
                          final playable = excludeBanned
                              ? tracks.where((t) => t.preference != -1).toList()
                              : tracks;
                          if (playable.isNotEmpty) {
                            await widget.audioService.playQueue(
                              playable,
                              excludeBanned: excludeBanned,
                            );
                          } else {
                            messenger?.showSnackBar(
                              const SnackBar(
                                content: Text('此智慧歌單目前沒有可播放曲目'),
                              ),
                            );
                          }
                          return;
                        }
                        if (items[i].playTrack != null) {
                          await widget.audioService.play(
                            track: items[i].playTrack,
                          );
                        } else {
                          (widget.onOpenSmartPlaylists ??
                              widget.onOpenAlbums)();
                        }
                      },
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
