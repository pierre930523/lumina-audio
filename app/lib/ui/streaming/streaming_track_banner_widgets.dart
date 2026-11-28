part of 'streaming_service_view.dart';

extension _StreamingTrackBannerWidgets on _StreamingServiceViewState {
  Widget _buildTrackRow(
    TrackInfo item, {
    required double availW,
    List<TrackInfo>? queueContext,
  }) {
    final isSelected = widget.activeTrackId == item.id;
    final isWideRow = availW >= 700;
    final showQuality = availW >= 460;
    final durationLabel = _formatDuration(item.duration);
    final albumSub = item.album.trim();

    return TrackHoverPrefetch(
      track: item,
      child: GestureDetector(
        onSecondaryTapUp: (details) => showTrackContextMenu(
          context: context,
          audioService: widget.audioService,
          track: item,
          globalPosition: details.globalPosition,
          listenLaterController: widget.listenLaterController,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: Key('streaming_track_${item.id}'),
            borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
            hoverColor: LuminaTokens.glassRowHoverBg,
            onTap: () => _playTrack(item, queueContext: queueContext),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: isSelected
                    ? LuminaTokens.glassNavActiveBg
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _buildThumbnail(
                          item.coverUrl ?? item.albumArtUrl,
                          size: 40,
                          fallbackIcon: Icons.music_note_rounded,
                        ),
                        if (isSelected)
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.52),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Center(
                              child: Icon(
                                Icons.equalizer_rounded,
                                color: Colors.white,
                                size: 19,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (isWideRow) ...[
                    Expanded(
                      flex: 5,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isSelected
                                  ? Colors.white
                                  : LuminaTokens.glassTextPrimary,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (albumSub.isNotEmpty && albumSub != item.title) ...[
                            const SizedBox(height: 1),
                            Text(
                              albumSub,
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
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 3,
                      child: Text(
                        item.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.textMuted,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  ] else
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isSelected
                                  ? Colors.white
                                  : LuminaTokens.glassTextPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            albumSub.isNotEmpty
                                ? '${item.artist} · $albumSub'
                                : item.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: LuminaTokens.textMuted,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (showQuality) ...[
                    const SizedBox(width: 10),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: isWideRow ? 170 : 128,
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 3.5,
                        ),
                        decoration: BoxDecoration(
                          color: LuminaTokens.glassPillBg,
                          borderRadius: BorderRadius.circular(
                            LuminaTokens.radiusPill,
                          ),
                          border: Border.all(
                            color: LuminaTokens.glassPillBorder,
                          ),
                        ),
                        child: Text(
                          item.format.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: LuminaTokens.glassTextSecondary,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 44,
                    child: Text(
                      durationLabel,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: LuminaTokens.textMuted,
                        fontSize: 12,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  if (widget.listenLaterController != null) ...[
                    const SizedBox(width: 4),
                    IconButton(
                      key: Key('streaming_track_listen_later_${item.id}'),
                      tooltip: '加入稍後收聽',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(
                        Icons.watch_later_outlined,
                        size: 16,
                        color: LuminaTokens.textSecondary,
                      ),
                      onPressed: () {
                        widget.listenLaterController!.addStreamingTrack(item);
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          SnackBar(
                            content: Text('已將「${item.title}」加入稍後收聽'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      },
                    ),
                  ],
                  const SizedBox(width: 2),
                  Builder(
                    builder: (btnCtx) => IconButton(
                      key: Key('btn_streaming_track_more_${item.id}'),
                      tooltip: '更多曲目選項',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(
                        Icons.more_horiz_rounded,
                        size: 17,
                        color: LuminaTokens.textMuted,
                      ),
                      onPressed: () => showTrackContextMenu(
                        context: btnCtx,
                        audioService: widget.audioService,
                        track: item,
                        anchorContext: btnCtx,
                        listenLaterController: widget.listenLaterController,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail(
    String? url, {
    double size = 40,
    required IconData fallbackIcon,
  }) {
    Widget buildFallback() => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: LuminaTokens.glassPillBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: LuminaTokens.glassSidebarBorder),
      ),
      child: Icon(
        fallbackIcon,
        color: LuminaTokens.glassTextSecondary,
        size: size * 0.52,
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: StreamingCoverImage(
        url: url,
        targetSize: size >= 100 ? 600 : 300,
        width: size,
        height: size,
        fallbackBuilder: (_) => buildFallback(),
      ),
    );
  }

  Widget _buildCompactBanner({
    required Key bannerKey,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Container(
      key: bannerKey,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        border: Border.all(color: LuminaTokens.glassCardBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: LuminaTokens.glassPillBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: LuminaTokens.glassPillBorder),
            ),
            child: Icon(icon, size: 18, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.textMuted,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          if (actionLabel != null) ...[
            const SizedBox(width: 12),
            FilledButton(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                backgroundColor: LuminaTokens.glassSwitchOnTrack,
                foregroundColor: LuminaTokens.onAccentDark,
                disabledBackgroundColor: LuminaTokens.glassPillBg,
                disabledForegroundColor: LuminaTokens.textDisabled,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                minimumSize: const Size(0, 32),
              ),
              child: Text(
                actionLabel,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
