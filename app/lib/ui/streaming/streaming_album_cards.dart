part of 'streaming_service_view.dart';

extension _StreamingAlbumCards on _StreamingServiceViewState {
  Widget _buildSectionHeader({
    required String title,
    int? count,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: LuminaTokens.glassPillBg,
                borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
                border: Border.all(color: LuminaTokens.glassPillBorder),
              ),
              child: Text(
                '$count',
                style: const TextStyle(
                  color: LuminaTokens.glassTextSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }

  int _stripColumnCount(double availW) => availW >= 1320
      ? 7
      : (availW >= 1100
            ? 6
            : (availW >= 880
                  ? 5
                  : (availW >= 660 ? 4 : (availW >= 460 ? 3 : 2))));

  Widget _buildSingleRowAlbumStrip(
    List<StreamingAlbum> albums, {
    required double availW,
  }) {
    final maxCols = _stripColumnCount(availW);
    const spacing = 14.0;
    final visible = albums.take(maxCols).toList(growable: false);
    final cardWidth = (availW - spacing * (maxCols - 1)) / maxCols;
    final cardHeight = cardWidth + 46.0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < visible.length; i++) ...[
          if (i > 0) const SizedBox(width: spacing),
          SizedBox(
            width: cardWidth,
            height: cardHeight,
            child: _buildAlbumCard(
              visible[i],
              cardKey: Key('streaming_rec_strip_album_${visible[i].id}'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAlbumsSliverGrid(
    List<StreamingAlbum> albums, {
    String keyPrefix = 'streaming_rec_album_',
  }) {
    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 190,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: 0.74,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final alb = albums[index];
          return _buildAlbumCard(
            alb,
            cardKey: Key('$keyPrefix${alb.id}'),
          );
        },
        childCount: albums.length,
      ),
    );
  }

  Widget _buildAlbumCard(
    StreamingAlbum album, {
    required Key cardKey,
  }) {
    final qualityBadge = _formatAlbumQualityBadge(album.qualityLabel);
    final subtitle = album.year != null
        ? '${album.artist} · ${album.year}'
        : album.artist;

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: cardKey,
        borderRadius: BorderRadius.circular(10),
        hoverColor: LuminaTokens.glassRowHoverBg,
        onTap: widget.onOpenStreamingAlbum != null
            ? () => widget.onOpenStreamingAlbum!(album)
            : null,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: StreamingCoverImage(
                            url: album.coverUrl,
                            targetSize: 600,
                            fallbackBuilder: (_) => _buildAlbumCoverFallback(),
                          ),
                        ),
                        if (widget.listenLaterController != null)
                          Positioned(
                            top: 6,
                            right: 6,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: LuminaTokens.glassDrawerBg,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: LuminaTokens.glassPillBorder,
                                ),
                              ),
                              child: IconButton(
                                key: Key(
                                  'streaming_album_listen_later_${album.id}',
                                ),
                                tooltip: '加入稍後收聽',
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints(
                                  minWidth: 28,
                                  minHeight: 28,
                                ),
                                padding: EdgeInsets.zero,
                                icon: const Icon(
                                  Icons.watch_later_outlined,
                                  size: 15,
                                  color: Colors.white,
                                ),
                                onPressed: () {
                                  widget.listenLaterController!
                                      .addStreamingAlbum(album);
                                  ScaffoldMessenger.maybeOf(context)
                                      ?.showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        '已將「${album.title}」加入稍後收聽',
                                      ),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        if (qualityBadge != null)
                          Positioned(
                            right: 6,
                            bottom: 6,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 132),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: LuminaTokens.glassDialogBg,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: LuminaTokens.glassPillBorder,
                                  ),
                                ),
                                child: Text(
                                  qualityBadge,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: LuminaTokens.textPrimary,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    height: 1.1,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 7),
              Text(
                album.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: LuminaTokens.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 11.5,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAlbumCoverFallback() {
    return Container(
      decoration: BoxDecoration(
        color: LuminaTokens.glassPillBg,
        border: Border.all(color: LuminaTokens.glassSidebarBorder),
      ),
      child: const Center(
        child: Icon(
          Icons.album_rounded,
          size: 34,
          color: LuminaTokens.textMuted,
        ),
      ),
    );
  }
}
