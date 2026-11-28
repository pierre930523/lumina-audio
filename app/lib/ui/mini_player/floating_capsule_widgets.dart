part of 'floating_capsule.dart';

extension _FloatingCapsuleWidgets on _FloatingCapsuleMiniPlayerState {
  Widget _buildAlbumArt(TrackInfo? track, double size, double iconSize) {
    final glass = LuminaGlassTheme.of(context);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AlbumArtworkView(
            key: ValueKey('mini_art_${track?.responsiveArtworkKey ?? 'none'}'),
            track: track,
            size: size,
            fullResolution: false,
            coverTargetSize: 300,
            audioService: widget.audioService,
            libraryCache: widget.libraryCache,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: glass.isDark
                  ? LuminaTokens.glassCoverRim
                  : glass.glassBorderStrong,
              width: 1,
            ),
          ),
          Positioned(
            right: 2,
            top: 2,
            child: ExcludeSemantics(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: LuminaTokens.canvasBg.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(
                  Icons.keyboard_arrow_up_rounded,
                  color: LuminaTokens.glassTextPrimary,
                  size: 13,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _wrapExpandedDarkTheme({
    required BuildContext context,
    required double expandT,
    required Widget child,
  }) {
    final outerTheme = Theme.of(context);
    final outerGlass = LuminaGlassTheme.of(context);
    if (outerGlass.isDark) {
      return child;
    }
    final double darkBlendT = widget.floatingPillMode
        ? ((expandT - 0.15) / 0.55).clamp(0.0, 1.0)
        : (widget.isNowPlayingExpanded ? 1.0 : 0.0);
    final ThemeData resolvedTheme;
    if (darkBlendT <= 0.0) {
      resolvedTheme = outerTheme;
    } else if (darkBlendT >= 1.0) {
      resolvedTheme = outerTheme.copyWith(
        brightness: Brightness.dark,
        extensions: const [LuminaGlassTheme.dark],
      );
    } else {
      resolvedTheme = outerTheme.copyWith(
        brightness: darkBlendT < 0.5 ? Brightness.light : Brightness.dark,
        extensions: [outerGlass.lerp(LuminaGlassTheme.dark, darkBlendT)],
      );
    }
    return Theme(data: resolvedTheme, child: child);
  }

  Widget _buildFadedNowPlayingTrigger({
    required double triggerOpacity,
    required TrackInfo? track,
    required double artSize,
    required double iconSize,
    required double gap,
  }) {
    if (triggerOpacity <= 0.0) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      ignoring: triggerOpacity < 0.5,
      child: ExcludeSemantics(
        excluding: triggerOpacity < 0.5,
        child: Opacity(
          opacity: triggerOpacity,
          child: _buildNowPlayingTrigger(
            track: track,
            artSize: artSize,
            iconSize: iconSize,
            gap: gap,
          ),
        ),
      ),
    );
  }

  Widget _buildNowPlayingTrigger({
    required TrackInfo? track,
    required double artSize,
    required double iconSize,
    required double gap,
  }) {
    final glass = LuminaGlassTheme.of(context);
    final isDark = glass.isDark;
    final triggerCallback = widget.onToggleNowPlaying ?? widget.onToggleLyrics;
    final tooltipText =
        widget.isNowPlayingExpanded ? '收合播放與歌詞畫面' : '展開播放與逐字歌詞';
    return Tooltip(
      message: tooltipText,
      child: Semantics(
        button: true,
        label: tooltipText,
        child: InkWell(
          key: const Key('btn_expand_now_playing'),
          onTap: triggerCallback,
          mouseCursor: SystemMouseCursors.click,
          hoverColor: isDark ? LuminaTokens.glassRowHoverBg : glass.pillBg,
          focusColor: (isDark ? LuminaTokens.focusRing : glass.accent)
              .withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                _buildAlbumArt(track, artSize, iconSize),
                SizedBox(width: gap),
                Expanded(child: _buildTrackTitles(track)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  StreamingProviderMeta? _resolveStreamingMeta(TrackInfo? track) {
    if (track == null || track.providerName.trim().isEmpty) return null;
    for (final meta in StreamingProviderMeta.streamingServices) {
      if (meta.matchesTrackProvider(track.providerName)) {
        return meta;
      }
    }
    return null;
  }

  Widget _buildTrackTitles(TrackInfo? track) {
    final glass = LuminaGlassTheme.of(context);
    final primaryColor =
        glass.isDark ? LuminaTokens.glassTextPrimary : glass.textPrimary;
    final secondaryColor =
        glass.isDark ? LuminaTokens.glassTextSecondary : glass.textSecondary;
    final isPodcast = PodcastPlaybackTracker.isPodcastTrack(track);
    final artistSubtitle = track == null
        ? ''
        : (isPodcast && track.album.trim().isNotEmpty
            ? (track.artist.trim().isNotEmpty &&
                    track.artist.trim() != track.album.trim()
                ? '${track.album} · ${track.artist}'
                : track.album)
            : (track.hasDistinctAlbumArtist
                ? '${track.artist} (${track.albumArtist})'
                : track.artist));
    final streamingMeta = _resolveStreamingMeta(track);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          track?.title ?? '尚未選擇曲目',
          key: const Key('capsule_track_title'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: primaryColor,
            fontWeight: FontWeight.w600,
            fontSize: 13.5,
          ),
        ),
        if (streamingMeta != null)
          Row(
            children: [
              Tooltip(
                message: streamingMeta.name,
                child: KeyedSubtree(
                  key: Key('capsule_provider_badge_${streamingMeta.kind}'),
                  child: streamingMeta.buildBadge(
                    boxSize: 16,
                    borderRadius: 4,
                  ),
                ),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  artistSubtitle,
                  key: const Key('capsule_track_artist'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: secondaryColor,
                    fontSize: 11.5,
                  ),
                ),
              ),
            ],
          )
        else
          Text(
            artistSubtitle,
            key: const Key('capsule_track_artist'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: secondaryColor,
              fontSize: 11.5,
            ),
          ),
      ],
    );
  }

  Widget _buildLyricsToggleButton() {
    final onPressed = widget.isNowPlayingExpanded
        ? (widget.onToggleNowPlayingLyrics ?? widget.onToggleLyrics)
        : widget.onToggleLyrics;
    return _LyricsPillButton(
      isActive: widget.showLyrics,
      onTap: onPressed,
    );
  }

  Widget _buildFooterIconTrigger({
    required Key buttonKey,
    required GlobalKey anchorKey,
    required LayerLink link,
    required bool isOpen,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return CompositedTransformTarget(
      key: anchorKey,
      link: link,
      child: _FooterIconTrigger(
        buttonKey: buttonKey,
        isOpen: isOpen,
        icon: icon,
        tooltip: tooltip,
        onTap: onTap,
      ),
    );
  }
}

class _LyricsPillButton extends StatefulWidget {
  final bool isActive;
  final VoidCallback onTap;

  const _LyricsPillButton({
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_LyricsPillButton> createState() => _LyricsPillButtonState();
}

class _LyricsPillButtonState extends State<_LyricsPillButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);
    final isDark = glass.isDark;
    final activeBg =
        isDark ? LuminaTokens.glassNavActiveBg : glass.glassBgActive;
    final focusColor = isDark ? LuminaTokens.focusRing : glass.accent;
    final primaryText =
        isDark ? LuminaTokens.glassTextPrimary : glass.textPrimary;
    final secondaryText =
        isDark ? LuminaTokens.glassTextSecondary : glass.textSecondary;

    return Tooltip(
      message: '切換歌詞顯示',
      child: Semantics(
        button: true,
        toggled: widget.isActive,
        label: '切換歌詞顯示',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const Key('btn_toggle_lyrics'),
            onTap: widget.onTap,
            onHover: (v) {
              if (_hovered != v) setState(() => _hovered = v);
            },
            onFocusChange: (v) {
              if (_focused != v) setState(() => _focused = v);
            },
            mouseCursor: SystemMouseCursors.click,
            hoverColor: Colors.transparent,
            focusColor: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: LuminaTokens.focusDuration,
              curve: LuminaTokens.motionCurve,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: widget.isActive
                    ? activeBg
                    : (_hovered ? glass.pillHoverBg : Colors.transparent),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _focused
                      ? focusColor
                      : (widget.isActive
                            ? glass.pillBorder
                            : Colors.transparent),
                  width: 1.2,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                '詞',
                style: TextStyle(
                  color: widget.isActive || _hovered
                      ? primaryText
                      : secondaryText,
                  fontSize: 13,
                  fontWeight:
                      widget.isActive ? FontWeight.w700 : FontWeight.w600,
                  height: 1.1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FooterIconTrigger extends StatefulWidget {
  final Key buttonKey;
  final bool isOpen;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _FooterIconTrigger({
    required this.buttonKey,
    required this.isOpen,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_FooterIconTrigger> createState() => _FooterIconTriggerState();
}

class _FooterIconTriggerState extends State<_FooterIconTrigger> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);
    final isDark = glass.isDark;
    final activeBg =
        isDark ? LuminaTokens.glassNavActiveBg : glass.glassBgActive;
    final focusColor = isDark ? LuminaTokens.focusRing : glass.accent;
    final primaryText =
        isDark ? LuminaTokens.glassTextPrimary : glass.textPrimary;
    final secondaryText =
        isDark ? LuminaTokens.glassTextSecondary : glass.textSecondary;

    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        toggled: widget.isOpen,
        label: widget.tooltip,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: widget.buttonKey,
            onTap: widget.onTap,
            onHover: (v) {
              if (_hovered != v) setState(() => _hovered = v);
            },
            onFocusChange: (v) {
              if (_focused != v) setState(() => _focused = v);
            },
            mouseCursor: SystemMouseCursors.click,
            hoverColor: Colors.transparent,
            focusColor: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: LuminaTokens.focusDuration,
              curve: LuminaTokens.motionCurve,
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: widget.isOpen
                    ? activeBg
                    : (_hovered ? glass.pillHoverBg : Colors.transparent),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _focused
                      ? focusColor
                      : (widget.isOpen ? glass.pillBorder : Colors.transparent),
                  width: 1.2,
                ),
              ),
              child: Icon(
                widget.icon,
                size: 18,
                color: widget.isOpen || _hovered ? primaryText : secondaryText,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
