part of 'podcast_detail_page.dart';

extension _PodcastDetailHero on _PodcastDetailPageState {
  Widget _buildDetailScrollView({
    required PodcastShow effectiveShow,
    required PlaybackState playbackState,
    required double availW,
    required double coverSize,
    required bool isWide,
  }) {
    return SmoothScrollWrapper(
      controller: _scrollController,
      child: CustomScrollView(
        key: const Key('podcast_detail_scroll_view'),
        controller: _scrollController,
        slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            isWide ? 16 : 8,
            12,
            isWide ? 16 : 8,
            16,
          ),
          sliver: SliverToBoxAdapter(
            child: _buildHeroSection(
              show: effectiveShow,
              coverSize: coverSize,
              isWide: isWide,
            ),
          ),
        ),
        if (_loading && _episodes.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: CircularProgressIndicator(
                key: Key('podcast_detail_loading'),
                strokeWidth: 2.2,
                color: LuminaTokens.glassTextPrimary,
              ),
            ),
          )
        else if (_error != null && _episodes.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: LuminaTokens.statusError,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      key: const Key('btn_podcast_detail_retry'),
                      onPressed: _loadShowDetail,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: LuminaTokens.glassTextPrimary,
                        backgroundColor: LuminaTokens.glassPillBg,
                        side: const BorderSide(
                          color: LuminaTokens.glassPillBorder,
                        ),
                      ),
                      icon: const Icon(
                        Icons.refresh_rounded,
                        size: 16,
                      ),
                      label: const Text('重試'),
                    ),
                  ],
                ),
              ),
            ),
          )
        else if (_episodes.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Text(
                '此節目目前尚無可播放的單集',
                style: TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 13,
                ),
              ),
            ),
          )
        else ...[
          SliverPadding(
            padding: EdgeInsets.symmetric(
              horizontal: isWide ? 16 : 8,
            ),
            sliver: SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    const Icon(
                      Icons.format_list_bulleted_rounded,
                      size: 17,
                      color: LuminaTokens.glassTextSecondary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '所有單集（${_episodes.length}）',
                      style: const TextStyle(
                        color: LuminaTokens.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.symmetric(
              horizontal: isWide ? 16 : 8,
            ),
            sliver: SliverList.builder(
              itemCount: _episodes.length,
              itemBuilder: (context, index) {
                final ep = _episodes[index];
                return _buildEpisodeRow(
                  episode: ep,
                  playbackState: playbackState,
                  isCompact: availW < 520,
                );
              },
            ),
          ),
          if (_continuationToken != null &&
              _continuationToken!.trim().isNotEmpty)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                isWide ? 16 : 8,
                12,
                isWide ? 16 : 8,
                24,
              ),
              sliver: SliverToBoxAdapter(
                child: Center(
                  child: OutlinedButton.icon(
                    key: const Key(
                      'btn_podcast_load_more_episodes',
                    ),
                    onPressed: _loadingMore ? null : _loadMoreEpisodes,
                    icon: _loadingMore
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: LuminaTokens.glassTextPrimary,
                            ),
                          )
                        : const Icon(
                            Icons.expand_more_rounded,
                            size: 18,
                          ),
                    label: Text(
                      _loadingMore ? '載入更多單集中...' : '載入更多單集',
                      style: const TextStyle(fontSize: 13),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: LuminaTokens.glassTextPrimary,
                      backgroundColor: LuminaTokens.glassPillBg,
                      side: const BorderSide(
                        color: LuminaTokens.glassPillBorder,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          const SliverToBoxAdapter(
            child: SizedBox(
              height: LuminaTokens.bottomScrollClearance,
            ),
          ),
        ],
      ],
      ),
    );
  }

  Widget _buildHeroSection({
    required PodcastShow show,
    required double coverSize,
    required bool isWide,
  }) {
    final isBookmarked = _store.isBookmarked(show.id);
    final desc = show.description?.trim() ?? '';

    final metaColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: LuminaTokens.glassPillBg,
                borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
                border: Border.all(color: LuminaTokens.glassPillBorder),
              ),
              child: const Text(
                'YouTube Music Podcast',
                style: TextStyle(
                  color: LuminaTokens.glassTextSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (show.episodeCountLabel != null &&
                show.episodeCountLabel!.trim().isNotEmpty)
              Text(
                show.episodeCountLabel!,
                style: const TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 12,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          show.title,
          key: const Key('podcast_detail_title'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: LuminaTokens.textPrimary,
            fontSize: isWide ? 22 : 18,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
        ),
        if (show.author.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            show.author,
            key: const Key('podcast_detail_author'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: LuminaTokens.textSecondary,
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
        if (desc.isNotEmpty) ...[
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => _setState(
              () => _descriptionExpanded = !_descriptionExpanded,
            ),
            child: Text(
              desc,
              key: const Key('podcast_detail_description'),
              maxLines: _descriptionExpanded ? 15 : 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: LuminaTokens.textMuted,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
        ],
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const Key('btn_podcast_play_latest'),
              onPressed: _episodes.isEmpty
                  ? null
                  : () => _playEpisode(_episodes.first),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text(
                '播放最新一集',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: LuminaTokens.glassSwitchOnTrack,
                foregroundColor: LuminaTokens.onAccentDark,
                disabledBackgroundColor: LuminaTokens.glassPillBg,
                disabledForegroundColor: LuminaTokens.textDisabled,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
            ),
            OutlinedButton.icon(
              key: const Key('btn_podcast_toggle_bookmark'),
              onPressed: () => _store.toggleBookmark(show),
              icon: Icon(
                isBookmarked
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
                size: 17,
                color: isBookmarked
                    ? Colors.white
                    : LuminaTokens.glassTextSecondary,
              ),
              label: Text(
                isBookmarked ? '已收藏' : '收藏節目',
                style: TextStyle(
                  fontSize: 13,
                  color: isBookmarked
                      ? Colors.white
                      : LuminaTokens.glassTextPrimary,
                  fontWeight:
                      isBookmarked ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              style: OutlinedButton.styleFrom(
                backgroundColor: isBookmarked
                    ? LuminaTokens.glassNavActiveBg
                    : LuminaTokens.glassPillBg,
                side: BorderSide(
                  color: isBookmarked
                      ? LuminaTokens.glassCoverRim
                      : LuminaTokens.glassPillBorder,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
              ),
            ),
          ],
        ),
      ],
    );

    return Container(
      padding: EdgeInsets.all(isWide ? 20 : 14),
      decoration: BoxDecoration(
        color: LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        border: Border.all(color: LuminaTokens.glassCardBorder),
      ),
      child: isWide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildArtworkBox(
                  url: show.artworkUrl,
                  width: coverSize,
                  height: coverSize,
                  borderRadius: 12,
                  iconSize: 44,
                  targetSize: 1200,
                ),
                const SizedBox(width: 22),
                Expanded(child: metaColumn),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: _buildArtworkBox(
                    url: show.artworkUrl,
                    width: coverSize,
                    height: coverSize,
                    borderRadius: 12,
                    iconSize: 40,
                    targetSize: 1200,
                  ),
                ),
                const SizedBox(height: 14),
                metaColumn,
              ],
            ),
    );
  }
}
