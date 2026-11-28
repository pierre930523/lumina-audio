part of 'now_playing_overlay.dart';

extension _NowPlayingQueueDualRow on NowPlayingOverlayState {
  Widget _buildDualQueueDrawerRow({
    required double drawerWidth,
    required TrackInfo item,
    required int combinedIndex,
    required bool isCurrent,
    required bool isAuto,
    required bool isLockedPlayingAuto,
    required AutoplayController ap,
    required VoidCallback ensureSeededBeforeReorder,
  }) {
    Widget buildDragProxyContent() {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: isCurrent
              ? LuminaTokens.glassNavActiveBg
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            AlbumArtworkView(
              track: item,
              size: 36,
              fullResolution: false,
              coverTargetSize: 300,
              audioService: widget.audioService,
              libraryCache: widget.libraryCache,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: LuminaTokens.glassPillBorder,
                width: 1,
              ),
            ),
            const SizedBox(width: 10),
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
                      color: isCurrent
                          ? LuminaTokens.glassTextPrimary
                          : LuminaTokens.glassTextSecondary,
                      fontSize: 13,
                      fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    item.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: LuminaTokens.glassTextTertiary,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final payload = _DrawerQueueDragPayload(
      track: item,
      combinedIndex: combinedIndex,
      isAuto: isAuto,
    );

    Widget buildFeedback() => Material(
      color: Colors.transparent,
      child: SizedBox(
        width: math.max(150.0, drawerWidth - 20.0),
        child: FrostedGlassContainer(
          blurSigma: 0,
          enableBackdropBlur: false,
          color: LuminaTokens.glassDrawerBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: LuminaTokens.glassPillBorder),
          child: buildDragProxyContent(),
        ),
      ),
    );

    Widget buildDraggableRow() {
      final Widget grip = isLockedPlayingAuto
          ? const Icon(
              Icons.all_inclusive_rounded,
              size: 14,
              color: LuminaTokens.glassTextTertiary,
            )
          : MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Draggable<_DrawerQueueDragPayload>(
                key: Key('drawer_queue_drag_handle_${item.id}'),
                data: payload,
                feedback: buildFeedback(),
                childWhenDragging: const Opacity(
                  opacity: 0.35,
                  child: Icon(
                    Icons.drag_indicator_rounded,
                    size: 15,
                    color: LuminaTokens.glassTextTertiary,
                  ),
                ),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                  child: Icon(
                    Icons.drag_indicator_rounded,
                    size: 15,
                    color: LuminaTokens.glassTextTertiary,
                  ),
                ),
              ),
            );

      final Widget rowInner = Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        decoration: BoxDecoration(
          color: isCurrent
              ? LuminaTokens.glassNavActiveBg
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            grip,
            const SizedBox(width: 4),
            Expanded(
              child: InkWell(
                key: Key('now_playing_queue_item_${item.id}'),
                onTap: () => widget.audioService.play(track: item),
                mouseCursor: SystemMouseCursors.click,
                borderRadius: BorderRadius.circular(8),
                hoverColor: LuminaTokens.glassRowHoverBg,
                focusColor: LuminaTokens.focusRing.withValues(alpha: 0.22),
                child: Row(
                  children: [
                    AlbumArtworkView(
                      track: item,
                      size: 36,
                      fullResolution: false,
                      coverTargetSize: 300,
                      audioService: widget.audioService,
                      libraryCache: widget.libraryCache,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: LuminaTokens.glassPillBorder,
                        width: 1,
                      ),
                    ),
                    const SizedBox(width: 10),
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
                              color: isCurrent
                                  ? LuminaTokens.glassTextPrimary
                                  : LuminaTokens.glassTextSecondary,
                              fontSize: 13,
                              fontWeight: isCurrent
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            item.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: LuminaTokens.glassTextTertiary,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (isCurrent) ...[
                      const Icon(
                        Icons.equalizer_rounded,
                        size: 16,
                        color: LuminaTokens.glassTextPrimary,
                      ),
                      const SizedBox(width: 4),
                    ],
                    if (!isAuto && drawerWidth >= 260) ...[
                      Text(
                        TrackProgressBar.formatDuration(item.duration),
                        style: const TextStyle(
                          color: LuminaTokens.glassTextTertiary,
                          fontSize: 11,
                          fontFeatures: [ui.FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (isAuto) ...[
              const SizedBox(width: 2),
              Tooltip(
                message: '移至待播佇列',
                child: InkWell(
                  key: Key('btn_drawer_promote_auto_track_${item.id}'),
                  borderRadius: BorderRadius.circular(6),
                  mouseCursor: SystemMouseCursors.click,
                  hoverColor: LuminaTokens.glassPillHoverBg,
                  onTap: () => ap.promoteAutoTrackToUserQueue(item.id),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(
                      Icons.playlist_add_rounded,
                      size: 16,
                      color: LuminaTokens.glassTextSecondary,
                    ),
                  ),
                ),
              ),
              Tooltip(
                message: '移除此推薦曲目',
                child: InkWell(
                  key: Key('btn_drawer_remove_auto_track_${item.id}'),
                  borderRadius: BorderRadius.circular(6),
                  mouseCursor: SystemMouseCursors.click,
                  hoverColor: LuminaTokens.glassPillHoverBg,
                  onTap: () => ap.removeAutoTrack(item.id),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(
                      Icons.close_rounded,
                      size: 15,
                      color: LuminaTokens.glassTextTertiary,
                    ),
                  ),
                ),
              ),
            ],
            Builder(
              builder: (btnCtx) => Tooltip(
                message: '更多曲目選項',
                child: InkWell(
                  key: Key('btn_drawer_track_more_${item.id}'),
                  borderRadius: BorderRadius.circular(6),
                  mouseCursor: SystemMouseCursors.click,
                  hoverColor: LuminaTokens.glassPillHoverBg,
                  onTap: () => showTrackContextMenu(
                    context: btnCtx,
                    audioService: widget.audioService,
                    track: item,
                    anchorContext: btnCtx,
                    libraryCache: widget.libraryCache,
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(
                      Icons.more_horiz_rounded,
                      size: 16,
                      color: LuminaTokens.glassTextTertiary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );

      final Widget prefetched = TrackHoverPrefetch(
        track: item,
        child: Builder(
          builder: (rowCtx) => GestureDetector(
            onSecondaryTapUp: (details) => showTrackContextMenu(
              context: rowCtx,
              audioService: widget.audioService,
              track: item,
              globalPosition: details.globalPosition,
              libraryCache: widget.libraryCache,
            ),
            child: rowInner,
          ),
        ),
      );

      if (isLockedPlayingAuto) return prefetched;
      return LongPressDraggable<_DrawerQueueDragPayload>(
        data: payload,
        feedback: buildFeedback(),
        childWhenDragging: Opacity(
          opacity: 0.35,
          child: buildDragProxyContent(),
        ),
        child: prefetched,
      );
    }

    final Widget rowWidget = buildDraggableRow();

    return DragTarget<_DrawerQueueDragPayload>(
      onWillAcceptWithDetails: (details) =>
          details.data.combinedIndex != combinedIndex,
      onAcceptWithDetails: (details) {
        ensureSeededBeforeReorder();
        ap.reorderDualQueue(details.data.combinedIndex, combinedIndex);
      },
      builder: (context, candidateData, _) {
        final isTarget = candidateData.isNotEmpty;
        return DecoratedBox(
          decoration: BoxDecoration(
            border: isTarget
                ? const Border(
                    top: BorderSide(color: LuminaTokens.focusRing, width: 2),
                  )
                : null,
          ),
          child: rowWidget,
        );
      },
    );
  }
}
