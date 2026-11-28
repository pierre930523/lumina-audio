part of 'floating_capsule.dart';

extension _FloatingCapsuleLayouts on _FloatingCapsuleMiniPlayerState {
  Widget _buildWideContent({
    required double maxWidth,
    required PlaybackState state,
    required TrackInfo? track,
    required Duration trackDuration,
    required double expandT,
    required double triggerOpacity,
    required Widget badge,
    required Widget queueBtn,
    required Widget outputBtn,
    required Widget lyricsBtn,
    required Widget? autoplayBtn,
    required VoidCallback? onSkipBack15s,
    required VoidCallback? onSkipForward30s,
  }) {
    // Equal symmetric side widths guarantee the Expanded center column
    // (and Play/Pause + linear progress bar inside it) sits
    // dead-center horizontally across the entire bottom bar.
    final sideWidth = (maxWidth * 0.24).clamp(188.0, 260.0).floorToDouble();
    final wideSliderWidth =
        (sideWidth - 140.0).clamp(48.0, 88.0).floorToDouble();
    final expandedCenterMaxWidth = (maxWidth * 0.50).clamp(280.0, 680.0);
    final centerMaxWidth =
        ui.lerpDouble(680.0, expandedCenterMaxWidth, expandT)!;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: sideWidth,
          child: _buildFadedNowPlayingTrigger(
            triggerOpacity: triggerOpacity,
            track: track,
            artSize: 48,
            iconSize: 24,
            gap: LuminaTokens.spaceSm,
          ),
        ),
        const SizedBox(width: LuminaTokens.spaceSm),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: centerMaxWidth),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: PlaybackControls(
                        status: state.status,
                        compact: maxWidth < 900,
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
                  TrackProgressBar(
                    position: state.position,
                    duration: trackDuration,
                    expand: true,
                    onSeek: widget.audioService.seek,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: LuminaTokens.spaceSm),
        SizedBox(
          width: sideWidth,
          child: Align(
            alignment: Alignment.centerRight,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  lyricsBtn,
                  const SizedBox(width: 4),
                  if (autoplayBtn != null) ...[
                    autoplayBtn,
                    const SizedBox(width: 2),
                  ],
                  queueBtn,
                  const SizedBox(width: 2),
                  outputBtn,
                  const SizedBox(width: 4),
                  VolumeControl(
                    volume: state.volume,
                    isMuted: state.isMuted,
                    lockedUnity: widget.audioService.isStrictBitPerfect,
                    sliderWidth: wideSliderWidth,
                    onVolumeChanged: widget.audioService.setVolume,
                    onToggleMute: widget.audioService.toggleMute,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMediumContent({
    required double maxWidth,
    required PlaybackState state,
    required TrackInfo? track,
    required Duration trackDuration,
    required double triggerOpacity,
    required Widget badge,
    required Widget queueBtn,
    required Widget outputBtn,
    required Widget lyricsBtn,
    required Widget? autoplayBtn,
    required VoidCallback? onSkipBack15s,
    required VoidCallback? onSkipForward30s,
  }) {
    final mediumSliderWidth =
        (maxWidth * 0.1).clamp(44.0, 68.0).floorToDouble();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: _buildFadedNowPlayingTrigger(
                triggerOpacity: triggerOpacity,
                track: track,
                artSize: 40,
                iconSize: 22,
                gap: 10,
              ),
            ),
            const SizedBox(width: LuminaTokens.spaceXs),
            PlaybackControls(
              status: state.status,
              compact: true,
              isShuffleEnabled: _isShuffleEnabled,
              onToggleShuffle: _toggleShuffle,
              repeatMode: _repeatMode,
              onCycleRepeat: _cycleRepeat,
              onPrevious: _handlePrevious,
              onPlayPause: widget.audioService.togglePlayPause,
              onNext: () => unawaited(_handleNext()),
              onSkipBackward15s: onSkipBack15s,
              onSkipForward30s: onSkipForward30s,
            ),
            const SizedBox(width: LuminaTokens.spaceXs),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: badge,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TrackProgressBar(
                position: state.position,
                duration: trackDuration,
                expand: true,
                onSeek: widget.audioService.seek,
              ),
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: math.max(120.0, maxWidth - 188.0),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    lyricsBtn,
                    const SizedBox(width: 2),
                    if (autoplayBtn != null) ...[
                      autoplayBtn,
                      const SizedBox(width: 2),
                    ],
                    queueBtn,
                    outputBtn,
                    VolumeControl(
                      volume: state.volume,
                      isMuted: state.isMuted,
                      lockedUnity: widget.audioService.isStrictBitPerfect,
                      sliderWidth: mediumSliderWidth,
                      onVolumeChanged: widget.audioService.setVolume,
                      onToggleMute: widget.audioService.toggleMute,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildNarrowContent({
    required double maxWidth,
    required PlaybackState state,
    required TrackInfo? track,
    required Duration trackDuration,
    required double expandT,
    required double triggerOpacity,
    required Widget badge,
    required Widget queueBtn,
    required Widget outputBtn,
    required Widget lyricsBtn,
    required Widget? autoplayBtn,
  }) {
    final innerW = math.max(120.0, maxWidth - 28.0);
    final narrowSliderWidth = (maxWidth - 266).clamp(40.0, 82.0).toDouble();
    final double narrowControlsMaxFactor = ui.lerpDouble(
      0.64,
      1.0,
      ((expandT - 0.4) / 0.4).clamp(0.0, 1.0),
    )!;
    final narrowControls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (autoplayBtn != null) ...[
          autoplayBtn,
          const SizedBox(width: 2),
        ],
        queueBtn,
        outputBtn,
        VolumeControl(
          volume: state.volume,
          isMuted: state.isMuted,
          lockedUnity: widget.audioService.isStrictBitPerfect,
          sliderWidth: narrowSliderWidth,
          onVolumeChanged: widget.audioService.setVolume,
          onToggleMute: widget.audioService.toggleMute,
        ),
      ],
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: _buildFadedNowPlayingTrigger(
                triggerOpacity: triggerOpacity,
                track: track,
                artSize: 36,
                iconSize: 20,
                gap: LuminaTokens.spaceXs,
              ),
            ),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: innerW * narrowControlsMaxFactor,
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PlaybackControls(
                      status: state.status,
                      compact: true,
                      isShuffleEnabled: _isShuffleEnabled,
                      onToggleShuffle: _toggleShuffle,
                      repeatMode: _repeatMode,
                      onCycleRepeat: _cycleRepeat,
                      onPrevious: _handlePrevious,
                      onPlayPause: widget.audioService.togglePlayPause,
                      onNext: () => unawaited(_handleNext()),
                    ),
                    const SizedBox(width: 2),
                    lyricsBtn,
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: LuminaTokens.space2xs),
        TrackProgressBar(
          position: state.position,
          duration: trackDuration,
          expand: true,
          onSeek: widget.audioService.seek,
        ),
        const SizedBox(height: LuminaTokens.space2xs),
        Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: badge,
                ),
              ),
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: math.max(100.0, innerW - 72.0),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: narrowControls,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCapsuleShell({
    required BuildContext context,
    required LuminaGlassTheme glass,
    required bool isExpanded,
    required bool isWide,
    required double expandT,
    required double hInset,
    required double maxWidth,
    required double outerWidth,
    required Widget content,
  }) {
    final isDark = glass.isDark;
    if (!widget.floatingPillMode) {
      final capsuleContainer = Container(
        key: const Key('liquid_glass_capsule'),
        width: double.infinity,
        constraints: isWide ? const BoxConstraints(minHeight: 84.0) : null,
        padding: EdgeInsets.symmetric(
          horizontal: isWide ? 20.0 : 14.0,
          vertical: isWide ? 8.0 : LuminaTokens.spaceXs,
        ),
        decoration: BoxDecoration(
          color: isExpanded
              ? Colors.transparent
              : (isDark ? LuminaTokens.glassPlayerBarBg : glass.playerBarBg),
          border: isExpanded
              ? null
              : Border(
                  top: BorderSide(
                    color: isDark
                        ? LuminaTokens.glassPlayerBarBorder
                        : glass.playerBarBorder,
                    width: 1.0,
                  ),
                ),
        ),
        alignment: isWide ? Alignment.center : null,
        child: content,
      );

      if (isExpanded) {
        return capsuleContainer;
      }
      return FrostedGlassContainer(
        blurSigma: isDark ? LuminaTokens.glassPlayerBarBlur : glass.glassBlur,
        color: Colors.transparent,
        enableBackdropBlur: !widget.suppressBackdropBlur,
        child: capsuleContainer,
      );
    }

    final double radiusVal = ui.lerpDouble(22.0, 0.0, expandT)!;
    final BorderRadius? pillRadius =
        radiusVal > 0.001 ? BorderRadius.circular(radiusVal) : null;
    final double pillBottomGap = outerWidth < 480 ? 8.0 : 12.0;
    final double bottomGap = ui.lerpDouble(pillBottomGap, 0.0, expandT)!;
    final double surfaceFade = (1.0 - expandT * 1.25).clamp(0.0, 1.0);
    final Color effectiveBg = expandT >= 1.0 || surfaceFade <= 0.0
        ? Colors.transparent
        : Color.lerp(Colors.transparent, glass.playerBarBg, surfaceFade)!;
    final BoxBorder? effectiveBorder = expandT >= 1.0 || surfaceFade <= 0.0
        ? null
        : Border.all(
            color: glass.glassBorder.withValues(
              alpha: glass.glassBorder.a * surfaceFade,
            ),
            width: 1.0,
          );
    final List<BoxShadow>? effectiveShadow =
        expandT >= 1.0 || surfaceFade <= 0.0
        ? null
        : glass.glassShadow
              .map(
                (s) => s.copyWith(
                  color: s.color.withValues(alpha: s.color.a * surfaceFade),
                ),
              )
              .toList(growable: false);
    final double wideMinHeight = ui.lerpDouble(78.0, 84.0, expandT)!;

    final capsuleContainer = Container(
      key: const Key('liquid_glass_capsule'),
      width: double.infinity,
      constraints: isWide ? BoxConstraints(minHeight: wideMinHeight) : null,
      padding: EdgeInsets.symmetric(
        horizontal: isWide ? 20.0 : 14.0,
        vertical: isWide ? 8.0 : LuminaTokens.spaceXs,
      ),
      decoration: BoxDecoration(
        color: effectiveBg,
        borderRadius: pillRadius,
        border: effectiveBorder,
      ),
      alignment: isWide ? Alignment.center : null,
      child: content,
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(hInset, 0.0, hInset, bottomGap),
      child: Align(
        alignment: Alignment.bottomCenter,
        heightFactor: 1.0,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: FrostedGlassContainer(
            blurSigma: glass.glassBlur,
            color: Colors.transparent,
            borderRadius: pillRadius,
            boxShadow: effectiveShadow,
            enableBackdropBlur: !widget.suppressBackdropBlur && expandT == 0.0,
            child: capsuleContainer,
          ),
        ),
      ),
    );
  }
}
