part of 'now_playing_overlay.dart';

extension _NowPlayingTopBar on NowPlayingOverlayState {
  Widget _buildTopBar(NowPlayingViewMode mode, TrackInfo? track) {
    final isPodcast = PodcastPlaybackTracker.isPodcastTrack(track);
    return WindowDragBar(
      controller: widget.windowController,
      height: 48.0,
      padding: const EdgeInsets.symmetric(horizontal: LuminaTokens.spaceMd),
      child: Row(
        children: [
          FrostedGlassIconButton(
            key: const Key('btn_collapse_now_playing'),
            icon: Icons.keyboard_arrow_down_rounded,
            tooltip: '收合播放畫面',
            size: 36,
            iconSize: 22,
            borderRadius: 10,
            enableBackdropBlur: false,
            iconColor: LuminaTokens.glassTextPrimary,
            onTap: widget.onCollapse,
          ),
          if (isPodcast) ...[
            const SizedBox(width: LuminaTokens.spaceSm),
            FrostedGlassContainer(
              height: 36,
              enableBackdropBlur: false,
              color: LuminaTokens.glassPillBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: LuminaTokens.glassPillBorder,
                width: 1,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: const Key('btn_now_playing_skip_back_15s'),
                    tooltip: '倒退 15 秒 (-15s)',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    icon: const Icon(
                      Icons.replay_10_rounded,
                      size: 18,
                      color: LuminaTokens.glassTextPrimary,
                    ),
                    onPressed: () => PodcastPlaybackTracker.seekRelative(
                      widget.audioService,
                      PodcastPlaybackTracker.skipBackwardDelta,
                    ),
                  ),
                  IconButton(
                    key: const Key('btn_now_playing_skip_forward_30s'),
                    tooltip: '快轉 30 秒 (+30s)',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    icon: const Icon(
                      Icons.forward_30_rounded,
                      size: 18,
                      color: LuminaTokens.glassTextPrimary,
                    ),
                    onPressed: () => PodcastPlaybackTracker.seekRelative(
                      widget.audioService,
                      PodcastPlaybackTracker.skipForwardDelta,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(width: LuminaTokens.spaceXs),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FrostedGlassIconButton(
                      key: const Key('btn_now_playing_queue'),
                      icon: Icons.queue_music_rounded,
                      tooltip: '待播佇列',
                      size: 36,
                      iconSize: 18,
                      borderRadius: 10,
                      selected: _controller.queueDrawerOpen,
                      enableBackdropBlur: false,
                      onTap: _controller.toggleQueueDrawer,
                    ),
                    const SizedBox(width: LuminaTokens.space2xs),
                    FrostedGlassIconButton(
                      key: const Key('btn_now_playing_mode_split'),
                      icon: Icons.vertical_split_rounded,
                      tooltip: '封面與逐字歌詞',
                      size: 36,
                      iconSize: 18,
                      borderRadius: 10,
                      selected: mode == NowPlayingViewMode.split,
                      enableBackdropBlur: false,
                      onTap: () {
                        _controller.setQueueDrawerOpen(false);
                        _modeAnimController.forward();
                        _controller.setMode(NowPlayingViewMode.split);
                      },
                    ),
                    const SizedBox(width: LuminaTokens.space2xs),
                    FrostedGlassIconButton(
                      key: const Key('btn_now_playing_mode_lyrics'),
                      icon: Icons.lyrics_rounded,
                      tooltip: '純逐字歌詞',
                      size: 36,
                      iconSize: 18,
                      borderRadius: 10,
                      selected: mode == NowPlayingViewMode.lyrics,
                      enableBackdropBlur: false,
                      onTap: () {
                        _controller.setQueueDrawerOpen(false);
                        _controller.setMode(NowPlayingViewMode.lyrics);
                      },
                    ),
                    const SizedBox(width: LuminaTokens.space2xs),
                    FrostedGlassIconButton(
                      key: const Key('btn_now_playing_mode_cover'),
                      icon: Icons.album_outlined,
                      tooltip: '純封面檢視',
                      size: 36,
                      iconSize: 18,
                      borderRadius: 10,
                      selected: mode == NowPlayingViewMode.cover,
                      enableBackdropBlur: false,
                      onTap: () {
                        _controller.setQueueDrawerOpen(false);
                        _modeAnimController.reverse();
                        _controller.setMode(NowPlayingViewMode.cover);
                      },
                    ),
                    const SizedBox(width: LuminaTokens.space2xs),
                    FrostedGlassIconButton(
                      key: const Key('btn_now_playing_output_dsp'),
                      icon: Icons.graphic_eq_rounded,
                      tooltip: '音訊輸出與 DSP 狀態',
                      size: 36,
                      iconSize: 18,
                      borderRadius: 10,
                      enableBackdropBlur: false,
                      onTap: () =>
                          SignalPathModal.show(context, widget.audioService),
                    ),
                    const SizedBox(width: LuminaTokens.spaceSm),
                    DesktopWindowCaptionButtons(
                      controller: widget.windowController,
                      color: Colors.white70,
                      height: 48.0,
                      audioService: widget.audioService,
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

  Widget _buildStandaloneBottomControls({
    required PlaybackState state,
    required TrackInfo? track,
    required double maxWidth,
    required bool compact,
  }) {
    final isPodcast = PodcastPlaybackTracker.isPodcastTrack(track);
    final VoidCallback? onSkipBack15s = isPodcast
        ? () => PodcastPlaybackTracker.seekRelative(
            widget.audioService,
            PodcastPlaybackTracker.skipBackwardDelta,
          )
        : null;
    final VoidCallback? onSkipForward30s = isPodcast
        ? () => PodcastPlaybackTracker.seekRelative(
            widget.audioService,
            PodcastPlaybackTracker.skipForwardDelta,
          )
        : null;
    final trackDuration = track?.duration ?? const Duration(minutes: 4);
    final barWidth = math.min(
      math.max(160.0, maxWidth - 32.0),
      (maxWidth * 0.50).clamp(280.0, 680.0),
    );
    final badge = AudioQualityBadgeWithPopover(
      audioService: widget.audioService,
      track: track,
      controller: _standaloneQualityPopoverController,
      onOpenSignalPath: () =>
          SignalPathModal.show(context, widget.audioService),
    );

    return Padding(
      key: const Key('now_playing_standalone_controls'),
      padding: EdgeInsets.fromLTRB(
        16,
        compact ? 2 : 6,
        16,
        compact ? 6 : 14,
      ),
      child: Center(
        child: SizedBox(
          width: barWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: PlaybackControls(
                    status: state.status,
                    compact: compact || maxWidth < 680,
                    isShuffleEnabled: _isShuffleEnabled,
                    onToggleShuffle: _toggleShuffle,
                    repeatMode: _repeatMode,
                    onCycleRepeat: _cycleRepeat,
                    onPrevious: _handlePrevious,
                    onPlayPause: widget.audioService.togglePlayPause,
                    onNext: () => unawaited(_handleNext()),
                    onSkipBackward15s: onSkipBack15s,
                    onSkipForward30s: onSkipForward30s,
                    trailingBadge: badge,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              ValueListenableBuilder<Duration>(
                valueListenable: _positionNotifier,
                builder: (context, position, _) => TrackProgressBar(
                  position: position,
                  duration: trackDuration,
                  expand: true,
                  onSeek: widget.audioService.seek,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
