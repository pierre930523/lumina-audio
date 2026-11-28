part of 'now_playing_overlay.dart';

extension _NowPlayingQueueDrawer on NowPlayingOverlayState {
  Widget _buildQueueDrawer({
    required PlaybackState state,
    required double maxWidth,
    required double maxHeight,
  }) {
    if (!_controller.queueDrawerOpen &&
        _queueDrawerAnimController.isDismissed) {
      return const SizedBox.shrink();
    }

    final ap = widget.audioService.autoplayController;
    final drawerWidth = math.max(180.0, math.min(340.0, maxWidth - 32.0));
    final desiredBottom = widget.hasHostControls
        ? widget.bottomClearance + 12.0
        : math.min(96.0, math.max(12.0, maxHeight * 0.25));
    final maxAllowedBottom = math.max(0.0, maxHeight - 56.0 - 120.0);
    final resolvedBottom = math.min(desiredBottom, maxAllowedBottom);

    Widget buildDrawerFrame({required Widget child}) {
      return Positioned(
        top: 56.0,
        right: 16.0,
        bottom: resolvedBottom,
        width: drawerWidth,
        child: IgnorePointer(
          ignoring: !_controller.queueDrawerOpen,
          child: SlideTransition(
            position: _queueDrawerSlideAnim,
            child: FadeTransition(
              opacity: _queueDrawerOpacityAnim,
              child: Material(
                type: MaterialType.transparency,
                child: FrostedGlassContainer(
                  key: const Key('now_playing_queue_drawer'),
                  color: LuminaTokens.glassDrawerBg,
                  enableBackdropBlur: false,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: LuminaTokens.glassPillBorder,
                    width: 1,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x88000000),
                      blurRadius: 32,
                      offset: Offset(0, 12),
                    ),
                  ],
                  child: child,
                ),
              ),
            ),
          ),
        ),
      );
    }

    bool isCurrentQueueTrack(TrackInfo? active, TrackInfo item) {
      if (active == null) return false;
      if (item.id == active.id) return true;
      if (item.id.trim().isNotEmpty && active.id.trim().isNotEmpty) {
        return item.responsiveArtworkKey == active.responsiveArtworkKey;
      }
      return false;
    }

    if (ap == null) {
      return StreamBuilder<List<TrackInfo>>(
        stream: widget.audioService.queueUpdatedStream,
        initialData: widget.audioService.queue,
        builder: (context, qSnap) => buildDrawerFrame(
          child: _buildLegacyQueueDrawer(
            tracks: qSnap.data ?? widget.audioService.queue,
            activeTrack: state.track,
            isCurrentQueueTrack: isCurrentQueueTrack,
          ),
        ),
      );
    }

    Widget buildStreamDualBody() => StreamBuilder<void>(
      stream: ap.changes,
      builder: (context, _) {
        final combined = ap.combinedQueue;
        final autoTracks = ap.autoQueue;
        final useLegacyFallback =
            combined.isEmpty && widget.audioService.queue.isNotEmpty;
        final userTracks = useLegacyFallback
            ? widget.audioService.queue
            : combined.sublist(0, combined.length - autoTracks.length);
        final totalCount = userTracks.length + autoTracks.length;
        final showAutoSection = ap.enabled || autoTracks.isNotEmpty;

        void ensureSeededBeforeReorder() {
          if (useLegacyFallback) {
            ap.setUserQueue(
              userTracks,
              currentTrack: state.track,
              bumpEpoch: false,
            );
          }
        }

        final entries = <_DrawerQueueEntry>[
          const _DrawerQueueEntry(kind: _DrawerQueueEntryKind.userHeader),
          if (userTracks.isEmpty)
            const _DrawerQueueEntry(
              kind: _DrawerQueueEntryKind.userEmptyPlaceholder,
            )
          else
            for (var i = 0; i < userTracks.length; i++)
              _DrawerQueueEntry(
                kind: _DrawerQueueEntryKind.userTrack,
                track: userTracks[i],
                combinedIndex: i,
                isLockedPlayingAuto: !useLegacyFallback &&
                    ap.isCurrentFromAutoQueue &&
                    ap.currentTrack?.id == userTracks[i].id,
              ),
          if (showAutoSection) ...[
            const _DrawerQueueEntry(kind: _DrawerQueueEntryKind.autoHeader),
            if (autoTracks.isEmpty)
              const _DrawerQueueEntry(kind: _DrawerQueueEntryKind.autoEmptyHint)
            else
              for (var j = 0; j < autoTracks.length; j++)
                _DrawerQueueEntry(
                  kind: _DrawerQueueEntryKind.autoTrack,
                  track: autoTracks[j],
                  combinedIndex: userTracks.length + j,
                ),
          ],
        ];

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 10, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '待播佇列（$totalCount 首）',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.glassTextPrimary,
                        fontSize: 14,
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
                        key: const Key('btn_drawer_autoplay_toggle'),
                        borderRadius: BorderRadius.circular(8),
                        mouseCursor: SystemMouseCursors.click,
                        hoverColor: LuminaTokens.glassPillHoverBg,
                        focusColor: LuminaTokens.focusRing.withValues(
                          alpha: 0.25,
                        ),
                        onTap: () {
                          final next = !ap.enabled;
                          ap.setEnabled(next);
                          final rec = widget.recommendationSettings;
                          if (rec != null && rec.autoplayEnabled != next) {
                            unawaited(rec.setAutoplayEnabled(next));
                          }
                        },
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: ap.enabled
                                ? LuminaTokens.glassNavActiveBg
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: ap.enabled
                                  ? LuminaTokens.glassPillBorder
                                  : Colors.transparent,
                            ),
                          ),
                          child: Icon(
                            Icons.all_inclusive_rounded,
                            size: 16,
                            color: ap.enabled
                                ? LuminaTokens.glassTextPrimary
                                : LuminaTokens.glassTextTertiary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  _buildCloseQueueDrawerButton(),
                ],
              ),
            ),
            const Divider(
              color: LuminaTokens.glassSidebarBorder,
              height: 1,
            ),
            Expanded(
              child: totalCount == 0 && !showAutoSection
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
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final entry = entries[index];
                          return switch (entry.kind) {
                            _DrawerQueueEntryKind.userHeader =>
                              _buildDrawerUserHeader(
                                ap: ap,
                                userCount: userTracks.length,
                                ensureSeededBeforeReorder:
                                    ensureSeededBeforeReorder,
                              ),
                            _DrawerQueueEntryKind.userEmptyPlaceholder =>
                              _buildDrawerEmptyUserDropZone(ap: ap),
                            _DrawerQueueEntryKind.userTrack =>
                              _buildDualQueueDrawerRow(
                                drawerWidth: drawerWidth,
                                item: entry.track!,
                                combinedIndex: entry.combinedIndex,
                                isCurrent: isCurrentQueueTrack(
                                  state.track,
                                  entry.track!,
                                ),
                                isAuto: false,
                                isLockedPlayingAuto: entry.isLockedPlayingAuto,
                                ap: ap,
                                ensureSeededBeforeReorder:
                                    ensureSeededBeforeReorder,
                              ),
                            _DrawerQueueEntryKind.autoHeader =>
                              _buildDrawerAutoHeader(ap: ap),
                            _DrawerQueueEntryKind.autoEmptyHint => Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 10,
                              ),
                              child: Text(
                                ap.isRefilling
                                    ? '正在探索相似推薦曲目...'
                                    : '待播佇列即將播畢時將自動接續推薦',
                                style: const TextStyle(
                                  color: LuminaTokens.glassTextTertiary,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            _DrawerQueueEntryKind.autoTrack =>
                              _buildDualQueueDrawerRow(
                                drawerWidth: drawerWidth,
                                item: entry.track!,
                                combinedIndex: entry.combinedIndex,
                                isCurrent: isCurrentQueueTrack(
                                  state.track,
                                  entry.track!,
                                ),
                                isAuto: true,
                                isLockedPlayingAuto: false,
                                ap: ap,
                                ensureSeededBeforeReorder:
                                    ensureSeededBeforeReorder,
                              ),
                          };
                        },
                      ),
                    ),
            ),
          ],
        );
      },
    );

    final Widget drawerChild = widget.recommendationSettings != null
        ? ListenableBuilder(
            listenable: widget.recommendationSettings!,
            builder: (context, _) => buildStreamDualBody(),
          )
        : buildStreamDualBody();

    return buildDrawerFrame(child: drawerChild);
  }

  Widget _buildCloseQueueDrawerButton() {
    return IconButton(
      key: const Key('btn_close_now_playing_queue'),
      tooltip: '關閉待播佇列',
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(
        minWidth: 32,
        minHeight: 32,
      ),
      style: IconButton.styleFrom(
        foregroundColor: LuminaTokens.glassTextSecondary,
        hoverColor: LuminaTokens.glassPillHoverBg,
        focusColor: LuminaTokens.focusRing.withValues(alpha: 0.25),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      icon: const Icon(Icons.close_rounded, size: 18),
      onPressed: () => _controller.setQueueDrawerOpen(false),
    );
  }
}

class _DrawerQueueDragPayload {
  final TrackInfo track;
  final int combinedIndex;
  final bool isAuto;

  const _DrawerQueueDragPayload({
    required this.track,
    required this.combinedIndex,
    required this.isAuto,
  });
}

enum _DrawerQueueEntryKind {
  userHeader,
  userEmptyPlaceholder,
  userTrack,
  autoHeader,
  autoEmptyHint,
  autoTrack,
}

class _DrawerQueueEntry {
  final _DrawerQueueEntryKind kind;
  final TrackInfo? track;
  final int combinedIndex;
  final bool isLockedPlayingAuto;

  const _DrawerQueueEntry({
    required this.kind,
    this.track,
    this.combinedIndex = -1,
    this.isLockedPlayingAuto = false,
  });
}
