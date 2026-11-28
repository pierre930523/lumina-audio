part of 'now_playing_overlay.dart';

extension _NowPlayingHeroStage on NowPlayingOverlayState {
  Widget _getPersistentHeroWidget({
    required TrackInfo? track,
    required double baseCoverSide,
    required double maxCoverSide,
    required double stageInnerH,
    required double gap,
    required double coverBorderRadius,
    required double titleFontSize,
    required double subtitleFontSize,
    required double metaTitleGap,
    required double metaPillGap,
    required double maxMetaHeight,
    required double shadowBlur,
    required double shadowSpread,
    required double shadowOffsetY,
    required bool compactMetadata,
  }) {
    final trackKey = NowPlayingOverlayState._trackIdentityKey(track);
    if (_cachedHeroWidget != null &&
        _cachedHeroTrackKey == trackKey &&
        _cachedHeroCoverSide == baseCoverSide &&
        _cachedHeroMaxCoverSide == maxCoverSide &&
        _cachedHeroStageInnerH == stageInnerH &&
        _cachedHeroGap == gap &&
        _cachedHeroCoverRadius == coverBorderRadius &&
        _cachedHeroTitleFontSize == titleFontSize &&
        _cachedHeroSubtitleFontSize == subtitleFontSize &&
        _cachedHeroMetaTitleGap == metaTitleGap &&
        _cachedHeroMetaPillGap == metaPillGap &&
        _cachedHeroMaxMetaHeight == maxMetaHeight &&
        _cachedHeroShadowBlur == shadowBlur &&
        _cachedHeroCompactMetadata == compactMetadata) {
      return _cachedHeroWidget!;
    }
    _cachedHeroTrackKey = trackKey;
    _cachedHeroCoverSide = baseCoverSide;
    _cachedHeroMaxCoverSide = maxCoverSide;
    _cachedHeroStageInnerH = stageInnerH;
    _cachedHeroGap = gap;
    _cachedHeroCoverRadius = coverBorderRadius;
    _cachedHeroTitleFontSize = titleFontSize;
    _cachedHeroSubtitleFontSize = subtitleFontSize;
    _cachedHeroMetaTitleGap = metaTitleGap;
    _cachedHeroMetaPillGap = metaPillGap;
    _cachedHeroMaxMetaHeight = maxMetaHeight;
    _cachedHeroShadowBlur = shadowBlur;
    _cachedHeroCompactMetadata = compactMetadata;

    final safeSide = math.max(0.0, math.min(baseCoverSide, maxCoverSide));
    final safeRadius = coverBorderRadius.clamp(0.0, 22.0).toDouble();
    final frameMaxMetaHeight = math.min(
      maxMetaHeight,
      math.max(0.0, stageInnerH - safeSide - gap),
    );

    _cachedHeroWidget = RepaintBoundary(
      key: const Key('now_playing_cover_repaint_boundary'),
      child: SizedBox(
        width: safeSide,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeroCoverCard(
              track,
              maxSide: safeSide,
              borderRadius: safeRadius,
              shadowBlur: shadowBlur,
              shadowSpread: shadowSpread,
              shadowOffsetY: shadowOffsetY,
            ),
            SizedBox(height: gap),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: safeSide,
                maxHeight: frameMaxMetaHeight,
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.center,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: safeSide),
                  child: _buildTrackMetadata(
                    track,
                    centered: true,
                    showPills: true,
                    titleFontSize: titleFontSize,
                    subtitleFontSize: subtitleFontSize,
                    metaTitleGap: metaTitleGap,
                    metaPillGap: metaPillGap,
                    compact: compactMetadata,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return _cachedHeroWidget!;
  }

  Widget _buildNarrowStackedStage({
    required Key key,
    required NowPlayingLayoutMetrics metrics,
    required double maxWidth,
    required PlaybackState state,
    required TrackInfo? track,
    required List<LyricLine> lyrics,
  }) {
    final innerW = math.max(120.0, maxWidth - metrics.stagePadH * 2);
    final useHorizontalHero = maxWidth >= 440;
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
          child: useHorizontalHero
              ? Row(
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
                      child: LayoutBuilder(
                        builder: (context, metaConstraints) {
                          final metaW = math.max(
                            80.0,
                            metaConstraints.maxWidth,
                          );
                          return ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: metrics.maxMetaHeight,
                            ),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(maxWidth: metaW),
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
                          );
                        },
                      ),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildHeroCoverCard(
                      track,
                      maxSide: metrics.coverSide,
                      borderRadius: metrics.coverBorderRadius,
                      shadowBlur: metrics.shadowBlur,
                      shadowSpread: metrics.shadowSpread,
                      shadowOffsetY: metrics.shadowOffsetY,
                    ),
                    const SizedBox(height: LuminaTokens.spaceXs),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: innerW,
                        maxHeight: metrics.maxMetaHeight,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.center,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: innerW),
                          child: _buildTrackMetadata(
                            track,
                            centered: true,
                            showPills: true,
                            titleFontSize: metrics.titleFontSize,
                            subtitleFontSize: metrics.subtitleFontSize,
                            metaTitleGap: metrics.metaTitleGap,
                            metaPillGap: metrics.metaPillGap,
                            compact: true,
                          ),
                        ),
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

  Widget _buildHeroCoverCard(
    TrackInfo? track, {
    required double maxSide,
    double? borderRadius,
    bool compact = false,
    double shadowBlur = 48,
    double shadowSpread = 0,
    double shadowOffsetY = 20,
  }) {
    final resolvedRadius = borderRadius ?? (compact ? 8.0 : 16.0);
    Widget card = ConstrainedBox(
      key: const ValueKey('now_playing_hero_cover_card'),
      constraints: BoxConstraints(maxWidth: maxSide, maxHeight: maxSide),
      child: AspectRatio(
        aspectRatio: 1,
        child: AlbumArtworkView(
          key: ValueKey('hero_art_${track?.responsiveArtworkKey ?? 'none'}'),
          track: track,
          size: maxSide,
          fit: BoxFit.cover,
          fullResolution: !compact,
          coverTargetSize: compact ? 300 : 1200,
          audioService: widget.audioService,
          libraryCache: widget.libraryCache,
          onArtworkResolved: _artworkResolvedCallbackFor(track),
          borderRadius: BorderRadius.circular(resolvedRadius),
          border: Border.all(
            color: LuminaTokens.glassCoverRim,
            width: 1,
          ),
          boxShadow: compact
              ? null
              : [
                  BoxShadow(
                    color: const Color(0x66000000),
                    blurRadius: math.min(shadowBlur, 24.0),
                    spreadRadius: shadowSpread,
                    offset: Offset(0, math.min(shadowOffsetY, 12.0)),
                  ),
                ],
        ),
      ),
    );

    if (!compact) {
      card = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: _toggleCoverSplitMode,
          child: card,
        ),
      );
    }
    return card;
  }
}
