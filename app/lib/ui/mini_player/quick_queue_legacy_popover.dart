part of 'quick_queue_popover.dart';

extension _QuickQueueLegacyPopover on QuickQueuePopover {
  Widget _buildLegacyPopover({
    required double resolvedMaxWidth,
    required TrackPrefetchCallback? onPrefetch,
  }) {
    final listMaxHeight = maxHeight != null
        ? math.min(260.0, math.max(56.0, maxHeight! - 48.0))
        : 260.0;
    final listMinHeight = (maxHeight == null || maxHeight! >= 160.0) ? 88.0 : 0.0;

    Widget buildBody(
      BuildContext context,
      PlaybackState state,
      List<TrackInfo> tracks,
    ) {
      final upcomingCount = QuickQueuePopover.countLegacyUpcoming(
        tracks,
        state.track,
      );
      final boundedListHeight = math.min(
        listMaxHeight,
        math.max(listMinHeight, tracks.length * 56.0 + 12.0),
      );

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
                    10,
                    LuminaTokens.spaceXs,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          '播放佇列（${tracks.length} 首）',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: LuminaTokens.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (onOpenLibrary != null) _buildOpenLibraryButton(),
                    ],
                  ),
                ),
                const Divider(color: LuminaTokens.glassCardDivider, height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 8, 4),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          '即將播放',
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
                      _buildClearUpcomingButton(
                        context,
                        upcomingCount: upcomingCount,
                        buttonKey: const Key('btn_clear_upcoming_queue'),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: tracks.isEmpty
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
                              itemCount: tracks.length,
                            itemBuilder: (context, index) {
                              final track = tracks[index];
                              final isCurrent =
                                  QuickQueuePopover._isCurrentTrack(
                                    state.track,
                                    track,
                                  );
                              return TrackHoverPrefetch(
                                track: track,
                                onPrefetch: onPrefetch,
                                child: InkWell(
                                  key: Key('quick_queue_item_${track.id}'),
                                  onTap: () => audioService.play(track: track),
                                  mouseCursor: SystemMouseCursors.click,
                                  hoverColor: LuminaTokens.glassRowHoverBg,
                                  focusColor: LuminaTokens.focusRing.withValues(
                                    alpha: 0.22,
                                  ),
                                  child: Container(
                                    color: isCurrent
                                        ? LuminaTokens.glassNavActiveBg
                                        : Colors.transparent,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 9,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          isCurrent
                                              ? Icons.equalizer_rounded
                                              : Icons.music_note_outlined,
                                          size: 16,
                                          color: isCurrent
                                              ? Colors.white
                                              : LuminaTokens.textMuted,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                track.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: isCurrent
                                                      ? Colors.white
                                                      : LuminaTokens
                                                            .glassTextPrimary,
                                                  fontSize: 13,
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
                                      ],
                                    ),
                                  ),
                                ),
                              );
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

    return StreamBuilder<PlaybackState>(
      stream: audioService.stateStream,
      initialData: audioService.currentState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? audioService.currentState;
        return StreamBuilder<List<TrackInfo>>(
          stream: audioService.queueUpdatedStream,
          initialData: audioService.queue,
          builder: (context, qSnap) =>
              buildBody(context, state, qSnap.data ?? audioService.queue),
        );
      },
    );
  }
}
