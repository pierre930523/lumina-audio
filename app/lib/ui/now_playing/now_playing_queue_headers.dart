part of 'now_playing_overlay.dart';

extension _NowPlayingQueueHeaders on NowPlayingOverlayState {
  bool _matchesQueueTrack(TrackInfo? active, TrackInfo item) {
    if (active == null) return false;
    if (item.id == active.id) return true;
    if (item.id.trim().isNotEmpty && active.id.trim().isNotEmpty) {
      return item.responsiveArtworkKey == active.responsiveArtworkKey;
    }
    return false;
  }

  int _countLegacyUpcomingTracks(
    List<TrackInfo> tracks,
    TrackInfo? activeTrack,
    bool Function(TrackInfo? active, TrackInfo item) isCurrentQueueTrack,
  ) {
    if (tracks.isEmpty) return 0;
    if (activeTrack == null) return tracks.length;
    final activeIdx = tracks.indexWhere((t) => isCurrentQueueTrack(activeTrack, t));
    final keepCount = activeIdx >= 0 ? activeIdx + 1 : 0;
    return tracks.length - keepCount;
  }

  Widget _buildDrawerClearUpcomingButton(
    BuildContext context, {
    required int upcomingCount,
  }) {
    final enabled = upcomingCount > 0;
    final messenger = ScaffoldMessenger.maybeOf(context);
    return Tooltip(
      message: enabled ? '清除所有即將播放的歌曲' : '目前無即將播放的歌曲',
      child: Semantics(
        button: true,
        enabled: enabled,
        label: '清除即將播放',
        child: TextButton(
          key: const Key('btn_drawer_clear_upcoming_queue'),
          onPressed: enabled
              ? () async {
                  final cleared = await widget.audioService.clearUpcomingQueue();
                  messenger?.showSnackBar(
                    SnackBar(
                      content: Text('已清除 $cleared 首即將播放的歌曲'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              : null,
          style: TextButton.styleFrom(
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            foregroundColor: LuminaTokens.glassTextSecondary,
            disabledForegroundColor: LuminaTokens.glassTextTertiary.withValues(
              alpha: 0.45,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.playlist_remove_rounded, size: 14),
              SizedBox(width: 3),
              Text(
                '清除即將播放',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLegacyQueueDrawer({
    required List<TrackInfo> tracks,
    required TrackInfo? activeTrack,
    required bool Function(TrackInfo? active, TrackInfo item) isCurrentQueueTrack,
  }) {
    final upcomingCount = _countLegacyUpcomingTracks(
      tracks,
      activeTrack,
      isCurrentQueueTrack,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 10, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '待播佇列（${tracks.length} 首）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.glassTextPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _buildCloseQueueDrawerButton(),
            ],
          ),
        ),
        const Divider(
          color: LuminaTokens.glassSidebarBorder,
          height: 1,
        ),
        Builder(
          builder: (sectionContext) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '即將播放',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: LuminaTokens.glassTextSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                _buildDrawerClearUpcomingButton(
                  sectionContext,
                  upcomingCount: upcomingCount,
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: tracks.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '目前待播佇列為空',
                      style: TextStyle(
                        color: LuminaTokens.glassTextTertiary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                )
              : SmoothScrollWrapper(
                  controller: _queueScrollController,
                  child: ListView.builder(
                    key: const PageStorageKey<String>(
                      'now_playing_queue_drawer_list',
                    ),
                    controller: _queueScrollController,
                    padding: const EdgeInsets.symmetric(
                      vertical: 6,
                      horizontal: 8,
                    ),
                    itemCount: tracks.length,
                    itemBuilder: (context, index) {
                      final item = tracks[index];
                      final isCurrent = isCurrentQueueTrack(activeTrack, item);
                      return _buildQueueDrawerRow(
                        item: item,
                        isCurrent: isCurrent,
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildDrawerUserHeader({
    required AutoplayController ap,
    required int userCount,
    required VoidCallback ensureSeededBeforeReorder,
  }) {
    return DragTarget<_DrawerQueueDragPayload>(
      onWillAcceptWithDetails: (details) => details.data.isAuto,
      onAcceptWithDetails: (details) {
        ensureSeededBeforeReorder();
        ap.promoteAutoTrackToUserQueue(
          details.data.track.id,
          targetUserIndex: 0,
        );
      },
      builder: (context, candidateData, _) {
        final hovered = candidateData.isNotEmpty;
        final combined = ap.combinedQueue;
        final useLegacyFallback =
            combined.isEmpty && widget.audioService.queue.isNotEmpty;
        final upcomingCount = useLegacyFallback
            ? _countLegacyUpcomingTracks(
                widget.audioService.queue,
                widget.audioService.currentState.track,
                _matchesQueueTrack,
              )
            : ap.totalRemainingCount;
        return Container(
          decoration: BoxDecoration(
            color: hovered
                ? LuminaTokens.glassNavActiveBg.withValues(alpha: 0.45)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          padding: const EdgeInsets.fromLTRB(8, 6, 4, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '待播佇列',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: LuminaTokens.glassTextSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '$userCount 首',
                style: const TextStyle(
                  color: LuminaTokens.glassTextTertiary,
                  fontSize: 11,
                ),
              ),
              const SizedBox(width: 4),
              _buildDrawerClearUpcomingButton(
                context,
                upcomingCount: upcomingCount,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDrawerEmptyUserDropZone({required AutoplayController ap}) {
    return DragTarget<_DrawerQueueDragPayload>(
      onWillAcceptWithDetails: (details) => details.data.isAuto,
      onAcceptWithDetails: (details) {
        ap.promoteAutoTrackToUserQueue(details.data.track.id);
      },
      builder: (context, candidateData, _) {
        final hovered = candidateData.isNotEmpty;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: hovered
                ? LuminaTokens.glassNavActiveBg.withValues(alpha: 0.5)
                : LuminaTokens.glassCardBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: hovered
                  ? LuminaTokens.focusRing
                  : LuminaTokens.glassCardBorder,
            ),
          ),
          child: const Text(
            '目前無手動待播曲目，可拖曳推薦曲目至此',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: LuminaTokens.glassTextTertiary,
              fontSize: 11.5,
            ),
          ),
        );
      },
    );
  }

  Widget _buildDrawerAutoHeader({required AutoplayController ap}) {
    final hasAutoTracks = ap.autoQueue.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 6, 4),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              '接下來自動推薦（Autoplay）',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: LuminaTokens.glassTextSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
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
                key: const Key('btn_drawer_clear_auto_queue'),
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

  Widget _buildQueueDrawerRow({
    required TrackInfo item,
    required bool isCurrent,
  }) {
    return TrackHoverPrefetch(
      track: item,
      child: InkWell(
        key: Key('now_playing_queue_item_${item.id}'),
        onTap: () => widget.audioService.play(track: item),
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(10),
        hoverColor: LuminaTokens.glassRowHoverBg,
        focusColor: LuminaTokens.focusRing.withValues(alpha: 0.22),
        child: Container(
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
                        fontWeight:
                            isCurrent ? FontWeight.w600 : FontWeight.w500,
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
              const SizedBox(width: 8),
              if (isCurrent) ...[
                const Icon(
                  Icons.equalizer_rounded,
                  size: 16,
                  color: LuminaTokens.glassTextPrimary,
                ),
                const SizedBox(width: 6),
              ],
              Text(
                TrackProgressBar.formatDuration(item.duration),
                style: const TextStyle(
                  color: LuminaTokens.glassTextTertiary,
                  fontSize: 11,
                  fontFeatures: [ui.FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
