part of 'podcasts_view.dart';

extension _PodcastsShowCard on _PodcastsViewState {
  Widget _buildShowsGridSliver({
    required List<PodcastShow> shows,
    required double availW,
  }) {
    return SliverList.builder(
      itemCount: shows.length,
      itemBuilder: (context, index) {
        final show = shows[index];
        return _buildShowCard(show: show, isCompact: availW < 520);
      },
    );
  }

  Widget _buildShowCard({
    required PodcastShow show,
    required bool isCompact,
  }) {
    final isBookmarked = _store.isBookmarked(show.id);
    final subParts = <String>[
      if (show.author.trim().isNotEmpty) show.author.trim(),
      if (show.episodeCountLabel != null &&
          show.episodeCountLabel!.trim().isNotEmpty)
        show.episodeCountLabel!.trim(),
    ];

    return Container(
      key: Key('podcast_show_card_${show.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        border: Border.all(color: LuminaTokens.glassCardBorder),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        hoverColor: LuminaTokens.glassRowHoverBg,
        onTap: () => _openShow(show),
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Row(
            children: [
              _buildNetworkArtwork(
                url: show.artworkUrl,
                size: isCompact ? 56 : 64,
                borderRadius: 8,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      show.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subParts.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subParts.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                    if (show.latestEpisodeTitle != null &&
                        show.latestEpisodeTitle!.trim().isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        '最新：${show.latestEpisodeTitle!.trim()}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.textMuted,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: Key('btn_bookmark_show_${show.id}'),
                tooltip: isBookmarked ? '取消收藏節目' : '收藏節目',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                padding: EdgeInsets.zero,
                icon: Icon(
                  isBookmarked
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  size: 20,
                  color: isBookmarked
                      ? LuminaTokens.glassTextPrimary
                      : LuminaTokens.textSecondary,
                ),
                onPressed: () => _store.toggleBookmark(show),
              ),
              IconButton(
                key: Key('btn_open_show_${show.id}'),
                tooltip: '檢視節目單集',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                padding: EdgeInsets.zero,
                icon: const Icon(
                  Icons.chevron_right_rounded,
                  size: 22,
                  color: LuminaTokens.textSecondary,
                ),
                onPressed: () => _openShow(show),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNetworkArtwork({
    required String? url,
    required double size,
    required double borderRadius,
  }) {
    Widget placeholder() => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: LuminaTokens.glassPillBg,
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(color: LuminaTokens.glassSidebarBorder),
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.podcasts_rounded,
            size: 24,
            color: LuminaTokens.textMuted,
          ),
        );

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: StreamingCoverImage(
        url: url,
        targetSize: size >= 100 ? 600 : 300,
        width: size,
        height: size,
        fallbackBuilder: (_) => placeholder(),
      ),
    );
  }
}
