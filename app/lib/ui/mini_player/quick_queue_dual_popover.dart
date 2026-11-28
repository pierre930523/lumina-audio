part of 'quick_queue_popover.dart';

extension _QuickQueueDualPopover on QuickQueuePopover {
  Widget _buildDualQueuePopover({
    required double resolvedMaxWidth,
    required PlaybackState state,
    required AutoplayController ap,
    required TrackPrefetchCallback? onPrefetch,
  }) {
    final combined = ap.combinedQueue;
    final autoTracks = ap.autoQueue;
    final useLegacyFallback = combined.isEmpty && audioService.queue.isNotEmpty;
    final userTracks = useLegacyFallback
        ? audioService.queue
        : combined.sublist(0, combined.length - autoTracks.length);
    final totalCount = userTracks.length + autoTracks.length;
    final upcomingCount = useLegacyFallback
        ? QuickQueuePopover.countLegacyUpcoming(userTracks, state.track)
        : ap.totalRemainingCount;
    final showAutoSection = ap.enabled || autoTracks.isNotEmpty;

    final listMaxHeight = maxHeight != null
        ? math.max(0.0, math.min(356.0, maxHeight! - 48.0))
        : 340.0;
    final rawMinHeight = (maxHeight == null || maxHeight! >= 160.0) ? 96.0 : 0.0;
    final listMinHeight = math.min(listMaxHeight, rawMinHeight);

    final estimatedHeight =
        32.0 +
        math.max(1, userTracks.length) * 54.0 +
        (showAutoSection
            ? (34.0 + math.max(1, autoTracks.length) * 54.0)
            : 0.0) +
        16.0;
    final boundedListHeight = math.min(
      listMaxHeight,
      math.max(listMinHeight, estimatedHeight),
    );

    final entries = <_QuickQueueEntry>[
      const _QuickQueueEntry(kind: _QuickQueueEntryKind.userHeader),
      if (userTracks.isEmpty)
        const _QuickQueueEntry(kind: _QuickQueueEntryKind.userEmptyPlaceholder)
      else
        for (var i = 0; i < userTracks.length; i++)
          _QuickQueueEntry(
            kind: _QuickQueueEntryKind.userTrack,
            track: userTracks[i],
            combinedIndex: i,
            isLockedPlayingAuto:
                !useLegacyFallback &&
                ap.isCurrentFromAutoQueue &&
                ap.currentTrack?.id == userTracks[i].id,
          ),
      if (showAutoSection) ...[
        const _QuickQueueEntry(kind: _QuickQueueEntryKind.autoHeader),
        if (autoTracks.isEmpty)
          const _QuickQueueEntry(kind: _QuickQueueEntryKind.autoEmptyHint)
        else
          for (var j = 0; j < autoTracks.length; j++)
            _QuickQueueEntry(
              kind: _QuickQueueEntryKind.autoTrack,
              track: autoTracks[j],
              combinedIndex: userTracks.length + j,
            ),
      ],
    ];

    void ensureSeededBeforeReorder() {
      if (useLegacyFallback) {
        ap.setUserQueue(
          userTracks,
          currentTrack: state.track,
          bumpEpoch: false,
        );
      }
    }

    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: resolvedMaxWidth,
          maxHeight: maxHeight ?? double.infinity,
        ),
        child: FrostedGlassContainer(
          key: const Key('quick_queue_popover'),
          width: resolvedMaxWidth,
          blurSigma: LuminaTokens.glassDialogBlur,
          color: LuminaTokens.glassDialogBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
          border: Border.all(color: LuminaTokens.glassCardBorder),
          boxShadow: const [
            BoxShadow(
              color: Color(0xAA000000),
              blurRadius: 28,
              offset: Offset(0, 12),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  LuminaTokens.spaceMd,
                  LuminaTokens.spaceSm,
                  8,
                  LuminaTokens.spaceXs,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '播放佇列（$totalCount 首）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.textSecondary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Tooltip(
                      message: '無限自動接播（開啟／關閉）',
                      child: Semantics(
                        button: true,
                        toggled: ap.enabled,
                        label: '無限自動接播（開啟／關閉）',
                        child: InkWell(
                          key: const Key('btn_queue_autoplay_toggle'),
                          borderRadius: BorderRadius.circular(6),
                          mouseCursor: SystemMouseCursors.click,
                          hoverColor: LuminaTokens.glassRowHoverBg,
                          focusColor: LuminaTokens.focusRing.withValues(
                            alpha: 0.25,
                          ),
                          onTap: () => _toggleAutoplay(ap, ap.enabled),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: ap.enabled
                                  ? LuminaTokens.glassNavActiveBg
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: ap.enabled
                                    ? LuminaTokens.glassPillBorder
                                    : Colors.transparent,
                              ),
                            ),
                            child: Icon(
                              Icons.all_inclusive_rounded,
                              size: 15,
                              color: ap.enabled
                                  ? LuminaTokens.glassTextPrimary
                                  : LuminaTokens.glassTextTertiary,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (onOpenLibrary != null) ...[
                      const SizedBox(width: 4),
                      _buildOpenLibraryButton(),
                    ],
                  ],
                ),
              ),
              const Divider(color: LuminaTokens.glassCardDivider, height: 1),
              Flexible(
                child: totalCount == 0 && !showAutoSection
                    ? ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: listMinHeight,
                          maxHeight: listMaxHeight,
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(LuminaTokens.spaceLg),
                          child: Text(
                            '目前待播佇列為空',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: LuminaTokens.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      )
                    : SizedBox(
                        height: boundedListHeight,
                        child: _GlideScrollHost(
                          builder: (context, scrollController) => ListView.builder(
                            key: const PageStorageKey<String>(
                              'quick_queue_list_scroll',
                            ),
                            controller: scrollController,
                            padding: const EdgeInsets.symmetric(
                              vertical: LuminaTokens.space2xs,
                            ),
                            itemCount: entries.length,
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            return switch (entry.kind) {
                              _QuickQueueEntryKind.userHeader =>
                                _buildUserSectionHeader(
                                  context: context,
                                  ap: ap,
                                  userCount: userTracks.length,
                                  upcomingCount: upcomingCount,
                                  ensureSeededBeforeReorder:
                                      ensureSeededBeforeReorder,
                                ),
                              _QuickQueueEntryKind.userEmptyPlaceholder =>
                                _buildUserEmptyDropZone(ap: ap),
                              _QuickQueueEntryKind.userTrack => _buildTrackRow(
                                resolvedMaxWidth: resolvedMaxWidth,
                                track: entry.track!,
                                combinedIndex: entry.combinedIndex,
                                isCurrent: QuickQueuePopover._isCurrentTrack(
                                  state.track,
                                  entry.track!,
                                ),
                                isAuto: false,
                                isLockedPlayingAuto: entry.isLockedPlayingAuto,
                                ap: ap,
                                onPrefetch: onPrefetch,
                                ensureSeededBeforeReorder:
                                    ensureSeededBeforeReorder,
                              ),
                              _QuickQueueEntryKind.autoHeader =>
                                _buildAutoSectionHeader(ap: ap),
                              _QuickQueueEntryKind.autoEmptyHint => Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                child: Text(
                                  ap.isRefilling
                                      ? '正在探索相似推薦曲目...'
                                      : '待播佇列即將播畢時將自動接續推薦',
                                  style: const TextStyle(
                                    color: LuminaTokens.textMuted,
                                    fontSize: 11.5,
                                  ),
                                ),
                              ),
                              _QuickQueueEntryKind.autoTrack => _buildTrackRow(
                                resolvedMaxWidth: resolvedMaxWidth,
                                track: entry.track!,
                                combinedIndex: entry.combinedIndex,
                                isCurrent: QuickQueuePopover._isCurrentTrack(
                                  state.track,
                                  entry.track!,
                                ),
                                isAuto: true,
                                isLockedPlayingAuto: false,
                                ap: ap,
                                onPrefetch: onPrefetch,
                                ensureSeededBeforeReorder:
                                    ensureSeededBeforeReorder,
                              ),
                            };
                          },
                        ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUserSectionHeader({
    required BuildContext context,
    required AutoplayController ap,
    required int userCount,
    required int upcomingCount,
    required VoidCallback ensureSeededBeforeReorder,
  }) {
    return DragTarget<_QueueDragPayload>(
      onWillAcceptWithDetails: (details) => details.data.isAuto,
      onAcceptWithDetails: (details) {
        ensureSeededBeforeReorder();
        ap.promoteAutoTrackToUserQueue(
          details.data.track.id,
          targetUserIndex: 0,
        );
      },
      builder: (context, candidateData, rejectedData) {
        final isHovered = candidateData.isNotEmpty;
        return Container(
          color: isHovered
              ? LuminaTokens.glassNavActiveBg.withValues(alpha: 0.45)
              : Colors.transparent,
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '待播佇列',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: LuminaTokens.glassTextSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              Text(
                '$userCount 首',
                style: const TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 11,
                ),
              ),
              const SizedBox(width: 6),
              _buildClearUpcomingButton(
                context,
                upcomingCount: upcomingCount,
                buttonKey: const Key('btn_clear_upcoming_queue'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildUserEmptyDropZone({required AutoplayController ap}) {
    return DragTarget<_QueueDragPayload>(
      onWillAcceptWithDetails: (details) => details.data.isAuto,
      onAcceptWithDetails: (details) {
        ap.promoteAutoTrackToUserQueue(details.data.track.id);
      },
      builder: (context, candidateData, rejectedData) {
        final isHovered = candidateData.isNotEmpty;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: isHovered
                ? LuminaTokens.glassNavActiveBg.withValues(alpha: 0.5)
                : LuminaTokens.glassCardBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isHovered
                  ? LuminaTokens.focusRing
                  : LuminaTokens.glassCardBorder,
            ),
          ),
          child: const Text(
            '目前無手動待播曲目，可拖曳推薦曲目至此',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: LuminaTokens.textMuted,
              fontSize: 11.5,
            ),
          ),
        );
      },
    );
  }

  Widget _buildAutoSectionHeader({required AutoplayController ap}) {
    final hasAutoTracks = ap.autoQueue.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 4),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              '接下來自動推薦（Autoplay）',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: LuminaTokens.glassTextSecondary,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ),
          if (ap.isRefilling) ...[
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: LuminaTokens.glassTextSecondary,
              ),
            ),
            const SizedBox(width: 6),
          ],
          if (hasAutoTracks)
            Tooltip(
              message: '清空自動推薦佇列',
              child: InkWell(
                key: const Key('btn_clear_auto_queue'),
                borderRadius: BorderRadius.circular(6),
                mouseCursor: SystemMouseCursors.click,
                hoverColor: LuminaTokens.glassRowHoverBg,
                onTap: ap.clearAutoQueue,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.clear_all_rounded,
                        size: 14,
                        color: LuminaTokens.glassTextSecondary,
                      ),
                      SizedBox(width: 3),
                      Text(
                        '清空',
                        style: TextStyle(
                          color: LuminaTokens.glassTextSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
