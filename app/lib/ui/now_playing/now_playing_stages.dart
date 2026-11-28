part of 'now_playing_overlay.dart';

extension _NowPlayingStages on NowPlayingOverlayState {
  Widget _buildStage({
    required Key key,
    required NowPlayingLayoutMetrics metrics,
    required double maxWidth,
    required double maxHeight,
    required double viewportWidth,
    required double viewportHeight,
    required PlaybackState state,
    required TrackInfo? track,
    required List<LyricLine> lyrics,
  }) {
    if (metrics.arrangement == NowPlayingStageArrangement.lyricsFull) {
      return _buildLyricsFullStage(
        key: key,
        metrics: metrics,
        state: state,
        track: track,
        lyrics: lyrics,
      );
    }

    if (metrics.arrangement == NowPlayingStageArrangement.lyricsCompactHeader ||
        metrics.arrangement == NowPlayingStageArrangement.splitCompactHeader) {
      return _buildCompactHeaderStage(
        key: key,
        metrics: metrics,
        state: state,
        track: track,
        lyrics: lyrics,
      );
    }

    if (metrics.arrangement == NowPlayingStageArrangement.splitNarrowStacked) {
      return _buildNarrowStackedStage(
        key: key,
        metrics: metrics,
        maxWidth: maxWidth,
        state: state,
        track: track,
        lyrics: lyrics,
      );
    }

    if (metrics.arrangement == NowPlayingStageArrangement.coverLandscapeRow) {
      return _buildLandscapeRowStage(
        key: key,
        metrics: metrics,
        maxWidth: maxWidth,
        track: track,
      );
    }

    return _buildDesktopTransitionStage(
      key: key,
      metrics: metrics,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      state: state,
      track: track,
      lyrics: lyrics,
    );
  }

  Widget _buildDesktopTransitionStage({
    required Key key,
    required NowPlayingLayoutMetrics metrics,
    required double maxWidth,
    required double maxHeight,
    required double viewportWidth,
    required double viewportHeight,
    required PlaybackState state,
    required TrackInfo? track,
    required List<LyricLine> lyrics,
  }) {
    final rawCoverMetrics = NowPlayingLayoutMetrics.compute(
      width: maxWidth,
      height: maxHeight,
      mode: NowPlayingViewMode.cover,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    );
    final coverMetrics =
        rawCoverMetrics.arrangement ==
            NowPlayingStageArrangement.coverLandscapeRow
        ? metrics
        : rawCoverMetrics;
    final baseCoverSide = coverMetrics.coverSide;
    final maxCoverSide = coverMetrics.maxCoverSide;
    final stageInnerH = math.max(
      0.0,
      maxHeight - coverMetrics.padTop - coverMetrics.padBottom,
    );
    final gap = coverMetrics.gap;
    final coverBorderRadius = coverMetrics.coverBorderRadius;
    final titleFontSize = coverMetrics.titleFontSize;
    final subtitleFontSize = coverMetrics.subtitleFontSize;
    final metaTitleGap = coverMetrics.metaTitleGap;
    final metaPillGap = coverMetrics.metaPillGap;
    final maxMetaHeight = coverMetrics.maxMetaHeight;
    final shadowBlur = coverMetrics.shadowBlur;
    final shadowSpread = coverMetrics.shadowSpread;
    final shadowOffsetY = coverMetrics.shadowOffsetY;
    final compactMetadata = coverMetrics.compactMetadata;

    final persistentHero = _getPersistentHeroWidget(
      track: track,
      baseCoverSide: baseCoverSide,
      maxCoverSide: maxCoverSide,
      stageInnerH: stageInnerH,
      gap: gap,
      coverBorderRadius: coverBorderRadius,
      titleFontSize: titleFontSize,
      subtitleFontSize: subtitleFontSize,
      metaTitleGap: metaTitleGap,
      metaPillGap: metaPillGap,
      maxMetaHeight: maxMetaHeight,
      shadowBlur: shadowBlur,
      shadowSpread: shadowSpread,
      shadowOffsetY: shadowOffsetY,
      compactMetadata: compactMetadata,
    );

    final leftPad = math.max(
      16.0,
      math.min(metrics.stagePadH, maxWidth * 0.06),
    );
    const interColumnGap = 24.0;
    final lyricsLeft = maxWidth * 0.48;
    final maxLeftVisualWidth = math.max(
      120.0,
      lyricsLeft - leftPad - interColumnGap,
    );
    final splitScale = baseCoverSide > 0
        ? math.min(0.88, maxLeftVisualWidth / baseCoverSide).clamp(0.35, 0.88)
        : 0.88;
    final scaledCoverHalfWidth = baseCoverSide * splitScale * 0.5;
    final minLeftCenter = scaledCoverHalfWidth + leftPad;
    final maxLeftCenter = lyricsLeft - interColumnGap - scaledCoverHalfWidth;
    final targetLeftCenterX = maxLeftCenter >= minLeftCenter
        ? (maxWidth * 0.26).clamp(minLeftCenter, maxLeftCenter).toDouble()
        : minLeftCenter;
    final dx = targetLeftCenterX - (maxWidth / 2.0);
    final centerOffset = Offset.zero;
    final leftOffset = Offset(dx, 0.0);

    return Stack(
      key: key,
      fit: StackFit.expand,
      children: [
        Positioned(
          left: lyricsLeft,
          right: math.max(16.0, metrics.stagePadH),
          top: metrics.padTop,
          bottom: metrics.padBottom,
          child: RepaintBoundary(
            key: const Key('now_playing_lyrics_repaint_boundary'),
            child: AnimatedBuilder(
              animation: _modeAnimController,
              child: ValueListenableBuilder<Duration>(
                valueListenable: _positionNotifier,
                builder: (context, position, _) => LyricsView(
                  lyrics: lyrics,
                  currentPosition: position,
                  onSeek: widget.audioService.seek,
                  centered: true,
                  isPlaying:
                      state.status == PlaybackStatus.playing &&
                      widget.isVisible,
                  trackId: track?.id,
                  audioService: widget.audioService,
                  viewController: _controller,
                  isTransitionSettled: widget.isTransitionSettled,
                ),
              ),
              builder: (context, lyricsChild) {
                final t = _modeAnimController.value;
                final lyricsT = const Interval(
                  0.28,
                  1.0,
                  curve: Curves.easeOutCubic,
                ).transform(t);
                final slideX = (1.0 - lyricsT) * 24.0;

                return IgnorePointer(
                  key: const Key('now_playing_lyrics_ignore_pointer'),
                  ignoring: t < 0.05,
                  child: Visibility(
                    key: const Key('now_playing_lyrics_visibility'),
                    visible: t > 0.01,
                    maintainState: true,
                    child: TickerMode(
                      enabled:
                          widget.isVisible &&
                          widget.isTransitionSettled &&
                          t > 0.01,
                      child: Opacity(
                        opacity: lyricsT.clamp(0.0, 1.0),
                        child: Transform.translate(
                          offset: Offset(slideX, 0.0),
                          child: lyricsChild,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        Center(
          child: AnimatedBuilder(
            animation: _modeAnimController,
            child: persistentHero,
            builder: (context, child) {
              final t = _modeAnimController.value;
              final slideT = Curves.easeInOutCubic.transform(t);
              final currentOffset =
                  Offset.lerp(centerOffset, leftOffset, slideT)!;
              final currentScale = ui.lerpDouble(1.0, splitScale, slideT)!;

              return Transform.translate(
                offset: currentOffset,
                child: Transform.scale(
                  scale: currentScale,
                  alignment: Alignment.center,
                  child: child,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildLandscapeRowStage({
    required Key key,
    required NowPlayingLayoutMetrics metrics,
    required double maxWidth,
    required TrackInfo? track,
  }) {
    final maxRowWidth = math.min(960.0, math.max(120.0, maxWidth));
    final innerRowWidth = math.max(
      0.0,
      maxRowWidth - metrics.stagePadH * 2,
    );
    final maxMetaWidth = math.max(
      100.0,
      innerRowWidth - metrics.coverSide - metrics.gap,
    );
    return Padding(
      key: key,
      padding: EdgeInsets.fromLTRB(
        metrics.stagePadH,
        metrics.padTop,
        metrics.stagePadH,
        metrics.padBottom,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxRowWidth),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildHeroCoverCard(
                track,
                maxSide: metrics.coverSide,
                borderRadius: metrics.coverBorderRadius,
                shadowBlur: metrics.shadowBlur,
                shadowSpread: metrics.shadowSpread,
                shadowOffsetY: metrics.shadowOffsetY,
              ),
              SizedBox(width: metrics.gap),
              Expanded(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: metrics.maxMetaHeight,
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxMetaWidth),
                      child: _buildTrackMetadata(
                        track,
                        centered: false,
                        showPills: true,
                        titleFontSize: metrics.titleFontSize,
                        subtitleFontSize: metrics.subtitleFontSize,
                        metaTitleGap: metrics.metaTitleGap,
                        metaPillGap: metrics.metaPillGap,
                        compact: metrics.compactMetadata,
                      ),
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

  Widget _buildLyricsFullStage({
    required Key key,
    required NowPlayingLayoutMetrics metrics,
    required PlaybackState state,
    required TrackInfo? track,
    required List<LyricLine> lyrics,
  }) {
    return Padding(
      key: key,
      padding: EdgeInsets.fromLTRB(
        metrics.stagePadH,
        metrics.padTop,
        metrics.stagePadH,
        metrics.padBottom,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: TickerMode(
            enabled: widget.isVisible && widget.isTransitionSettled,
            child: ValueListenableBuilder<Duration>(
              valueListenable: _positionNotifier,
              builder: (context, position, _) => LyricsView(
                lyrics: lyrics,
                currentPosition: position,
                onSeek: widget.audioService.seek,
                centered: true,
                isPlaying:
                    state.status == PlaybackStatus.playing && widget.isVisible,
                trackId: track?.id,
                audioService: widget.audioService,
                viewController: _controller,
                isTransitionSettled: widget.isTransitionSettled,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCompactHeaderStage({
    required Key key,
    required NowPlayingLayoutMetrics metrics,
    required PlaybackState state,
    required TrackInfo? track,
    required List<LyricLine> lyrics,
  }) {
    return Column(
      key: key,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            metrics.stagePadH,
            metrics.padTop,
            metrics.stagePadH,
            metrics.padBottom,
          ),
          child: Row(
            children: [
              _buildHeroCoverCard(
                track,
                maxSide: metrics.coverSide,
                borderRadius: metrics.coverBorderRadius,
                compact: true,
              ),
              SizedBox(width: metrics.gap),
              Expanded(
                child: _buildTrackMetadata(
                  track,
                  centered: false,
                  showPills: false,
                  titleFontSize: metrics.titleFontSize,
                  subtitleFontSize: metrics.subtitleFontSize,
                  metaTitleGap: metrics.metaTitleGap,
                  metaPillGap: metrics.metaPillGap,
                  compact: metrics.compactMetadata,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: FadeTransition(
                opacity: _modeAnim,
                child: TickerMode(
                  enabled: widget.isVisible && widget.isTransitionSettled,
                  child: ValueListenableBuilder<Duration>(
                    valueListenable: _positionNotifier,
                    builder: (context, position, _) => LyricsView(
                      lyrics: lyrics,
                      currentPosition: position,
                      onSeek: widget.audioService.seek,
                      centered: true,
                      isPlaying:
                          state.status == PlaybackStatus.playing &&
                          widget.isVisible,
                      trackId: track?.id,
                      audioService: widget.audioService,
                      viewController: _controller,
                      isTransitionSettled: widget.isTransitionSettled,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
