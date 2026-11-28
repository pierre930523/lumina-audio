part of 'quick_queue_popover.dart';

extension _QuickQueueTrackRow on QuickQueuePopover {
  Widget _buildTrackRow({
    required double resolvedMaxWidth,
    required TrackInfo track,
    required int combinedIndex,
    required bool isCurrent,
    required bool isAuto,
    required bool isLockedPlayingAuto,
    required AutoplayController ap,
    required TrackPrefetchCallback? onPrefetch,
    required VoidCallback ensureSeededBeforeReorder,
  }) {
    Widget buildDragProxyRow() {
      return Container(
        color: isCurrent ? LuminaTokens.glassNavActiveBg : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Icon(
              isCurrent
                  ? Icons.equalizer_rounded
                  : (isLockedPlayingAuto
                        ? Icons.all_inclusive_rounded
                        : Icons.drag_indicator_rounded),
              size: 15,
              color: isCurrent ? Colors.white : LuminaTokens.textMuted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isCurrent
                          ? Colors.white
                          : LuminaTokens.glassTextPrimary,
                      fontSize: 12.5,
                      fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  Text(
                    '${track.artist} • ${track.format.label}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: LuminaTokens.textMuted,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final payload = _QueueDragPayload(
      track: track,
      combinedIndex: combinedIndex,
      isAuto: isAuto,
    );

    Widget buildFeedback() => Material(
      color: Colors.transparent,
      child: SizedBox(
        width: resolvedMaxWidth - 8,
        child: FrostedGlassContainer(
          blurSigma: 0,
          enableBackdropBlur: false,
          color: LuminaTokens.glassDialogBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: LuminaTokens.glassPillBorder),
          child: buildDragProxyRow(),
        ),
      ),
    );

    Widget buildDraggableRowBody() {
      final Widget gripIcon = Icon(
        isCurrent
            ? Icons.equalizer_rounded
            : (isLockedPlayingAuto
                  ? Icons.all_inclusive_rounded
                  : Icons.drag_indicator_rounded),
        size: 15,
        color: isCurrent ? Colors.white : LuminaTokens.textMuted,
      );

      final Widget leadingGrip = isLockedPlayingAuto
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              child: gripIcon,
            )
          : MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Draggable<_QueueDragPayload>(
                key: Key('quick_queue_drag_handle_${track.id}'),
                data: payload,
                feedback: buildFeedback(),
                childWhenDragging: Opacity(opacity: 0.35, child: gripIcon),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 4,
                  ),
                  child: gripIcon,
                ),
              ),
            );

      final Widget rowContent = Container(
        color: isCurrent ? LuminaTokens.glassNavActiveBg : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            leadingGrip,
            const SizedBox(width: 6),
            Expanded(
              child: InkWell(
                key: Key('quick_queue_item_${track.id}'),
                onTap: () => audioService.play(track: track),
                mouseCursor: SystemMouseCursors.click,
                hoverColor: LuminaTokens.glassRowHoverBg,
                focusColor: LuminaTokens.focusRing.withValues(alpha: 0.22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isCurrent
                            ? Colors.white
                            : LuminaTokens.glassTextPrimary,
                        fontSize: 12.5,
                        fontWeight: isCurrent
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    Text(
                      '${track.artist} • ${track.format.label}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (isAuto) ...[
              const SizedBox(width: 4),
              Tooltip(
                message: '移至待播佇列',
                child: InkWell(
                  key: Key('btn_promote_auto_track_${track.id}'),
                  borderRadius: BorderRadius.circular(6),
                  mouseCursor: SystemMouseCursors.click,
                  hoverColor: LuminaTokens.glassPillHoverBg,
                  onTap: () => ap.promoteAutoTrackToUserQueue(track.id),
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
              const SizedBox(width: 2),
              Tooltip(
                message: '移除此推薦曲目',
                child: InkWell(
                  key: Key('btn_remove_auto_track_${track.id}'),
                  borderRadius: BorderRadius.circular(6),
                  mouseCursor: SystemMouseCursors.click,
                  hoverColor: LuminaTokens.glassPillHoverBg,
                  onTap: () => ap.removeAutoTrack(track.id),
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
                  key: Key('btn_quick_queue_more_${track.id}'),
                  borderRadius: BorderRadius.circular(6),
                  mouseCursor: SystemMouseCursors.click,
                  hoverColor: LuminaTokens.glassPillHoverBg,
                  onTap: () => showTrackContextMenu(
                    context: btnCtx,
                    audioService: audioService,
                    track: track,
                    anchorContext: btnCtx,
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(
                      Icons.more_horiz_rounded,
                      size: 16,
                      color: LuminaTokens.textMuted,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );

      final Widget prefetchedRow = TrackHoverPrefetch(
        track: track,
        onPrefetch: onPrefetch,
        child: Builder(
          builder: (rowCtx) => GestureDetector(
            onSecondaryTapUp: (details) => showTrackContextMenu(
              context: rowCtx,
              audioService: audioService,
              track: track,
              globalPosition: details.globalPosition,
            ),
            child: rowContent,
          ),
        ),
      );

      if (isLockedPlayingAuto) return prefetchedRow;
      return LongPressDraggable<_QueueDragPayload>(
        data: payload,
        feedback: buildFeedback(),
        childWhenDragging: Opacity(
          opacity: 0.35,
          child: buildDragProxyRow(),
        ),
        child: prefetchedRow,
      );
    }

    final Widget rowWidget = buildDraggableRowBody();

    return DragTarget<_QueueDragPayload>(
      onWillAcceptWithDetails: (details) =>
          details.data.combinedIndex != combinedIndex,
      onAcceptWithDetails: (details) {
        ensureSeededBeforeReorder();
        ap.reorderDualQueue(details.data.combinedIndex, combinedIndex);
      },
      builder: (context, candidateData, rejectedData) {
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
