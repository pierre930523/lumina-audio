import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../models/lyric.dart';
import '../../models/playback_state.dart';
import '../../models/signal_path.dart';
import '../../services/audio_service.dart';
import '../artwork/album_artwork_view.dart';
import '../lyrics/lyrics_view.dart';
import '../signal_path/quality_badge.dart';
import '../signal_path/signal_path_modal.dart';
import '../theme/lumina_tokens.dart';

enum _NowPlayingMode { split, cover, lyrics }

class NowPlayingOverlay extends StatefulWidget {
  final AudioService audioService;
  final VoidCallback onCollapse;

  const NowPlayingOverlay({
    super.key,
    required this.audioService,
    required this.onCollapse,
  });

  @override
  State<NowPlayingOverlay> createState() => _NowPlayingOverlayState();
}

class _NowPlayingOverlayState extends State<NowPlayingOverlay> {
  _NowPlayingMode _mode = _NowPlayingMode.split;

  static List<Color> _ambientPaletteFor(TrackInfo? track) {
    final seed = (track?.title.hashCode ?? 0) ^ (track?.album.hashCode ?? 0);
    return switch (seed.abs() % 3) {
      0 => const [
        Color(0xFF0E2B3D),
        Color(0xFF173D52),
        Color(0xFF0C121B),
      ],
      1 => const [
        Color(0xFF212046),
        Color(0xFF2D2558),
        Color(0xFF0F1118),
      ],
      _ => const [
        Color(0xFF331C2D),
        Color(0xFF26182B),
        Color(0xFF0F1117),
      ],
    };
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: widget.audioService.stateStream,
      initialData: widget.audioService.currentState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? widget.audioService.currentState;
        final track = state.track;
        final lyrics = List<LyricLine>.from(widget.audioService.currentLyrics);
        final palette = _ambientPaletteFor(track);

        return AnimatedContainer(
          key: const Key('now_playing_overlay'),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-0.15, -0.35),
              radius: 1.35,
              colors: palette,
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                _buildTopBar(),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final isWide = constraints.maxWidth >= 760 &&
                          constraints.maxHeight >= 300;
                      return AnimatedSwitcher(
                        duration: const Duration(milliseconds: 240),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        child: _buildStage(
                          key: ValueKey('$_mode-$isWide'),
                          isWide: isWide,
                          maxWidth: constraints.maxWidth,
                          maxHeight: constraints.maxHeight,
                          state: state,
                          track: track,
                          lyrics: lyrics,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LuminaTokens.spaceMd,
        LuminaTokens.spaceSm,
        LuminaTokens.spaceMd + 2,
        LuminaTokens.space2xs,
      ),
      child: Row(
        children: [
          IconButton(
            key: const Key('btn_collapse_now_playing'),
            tooltip: '收合播放畫面',
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            style: IconButton.styleFrom(
              foregroundColor: LuminaTokens.textSecondary,
              hoverColor: LuminaTokens.cardHoverBg.withValues(alpha: 0.7),
              focusColor: LuminaTokens.focusRing.withValues(alpha: 0.25),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
              ),
            ).copyWith(
              mouseCursor: const WidgetStatePropertyAll(
                SystemMouseCursors.click,
              ),
              side: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.focused)
                    ? const BorderSide(
                        color: LuminaTokens.focusRing,
                        width: 1.5,
                      )
                    : const BorderSide(color: Colors.transparent, width: 1.5),
              ),
            ),
            onPressed: widget.onCollapse,
            icon: const Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 26,
            ),
          ),
          const Spacer(),
          _ModeIconButton(
            key: const Key('btn_now_playing_mode_split'),
            icon: Icons.vertical_split_rounded,
            tooltip: '封面與逐字歌詞',
            selected: _mode == _NowPlayingMode.split,
            onTap: () => setState(() => _mode = _NowPlayingMode.split),
          ),
          const SizedBox(width: LuminaTokens.space2xs),
          _ModeIconButton(
            key: const Key('btn_now_playing_mode_lyrics'),
            icon: Icons.lyrics_rounded,
            tooltip: '純逐字歌詞',
            selected: _mode == _NowPlayingMode.lyrics,
            onTap: () => setState(() => _mode = _NowPlayingMode.lyrics),
          ),
          const SizedBox(width: LuminaTokens.space2xs),
          _ModeIconButton(
            key: const Key('btn_now_playing_mode_cover'),
            icon: Icons.album_outlined,
            tooltip: '純封面檢視',
            selected: _mode == _NowPlayingMode.cover,
            onTap: () => setState(() => _mode = _NowPlayingMode.cover),
          ),
        ],
      ),
    );
  }

  Widget _buildStage({
    required Key key,
    required bool isWide,
    required double maxWidth,
    required double maxHeight,
    required PlaybackState state,
    required TrackInfo? track,
    required List<LyricLine> lyrics,
  }) {
    final hStagePad = (maxWidth * 0.03).clamp(16.0, 48.0).toDouble();
    final compactChrome = maxHeight < 420;
    final ultraCompact = maxHeight < 280;

    if (_mode == _NowPlayingMode.cover) {
      final compactShadow = maxHeight < 360 || maxWidth < 400;
      final shadowBlur = compactShadow ? (ultraCompact ? 14.0 : 22.0) : 36.0;
      final shadowSpread = compactShadow ? 0.0 : 2.0;
      final shadowOffsetY = compactShadow ? (ultraCompact ? 6.0 : 10.0) : 14.0;
      // Ensure outer padding strictly exceeds blurRadius + spreadRadius on all sides
      // so the drop shadow fades smoothly into the background without cutoff.
      final padH = math
          .max(
            hStagePad,
            (shadowBlur + shadowSpread + 14.0)
                .clamp(16.0, math.max(16.0, maxWidth * 0.14)),
          )
          .toDouble();
      final padTop = (shadowBlur + shadowSpread + (compactChrome ? 4.0 : 6.0))
          .clamp(
            ultraCompact ? 8.0 : 18.0,
            math.max(
              ultraCompact ? 8.0 : 18.0,
              maxHeight * (compactChrome ? 0.08 : 0.14),
            ),
          )
          .toDouble();
      final padBottom = ultraCompact ? 8.0 : (compactShadow ? 14.0 : 24.0);
      final gap = ultraCompact
          ? 8.0
          : (compactChrome ? 12.0 : (maxHeight >= 460 ? 22.0 : 14.0));
      final titleSize = ultraCompact ? 17.0 : (compactChrome ? 19.0 : 22.0);
      final minCover = ultraCompact ? 48.0 : 72.0;
      final metaReserve = ultraCompact ? 84.0 : (compactChrome ? 116.0 : 148.0);

      final innerW = math.max(160.0, maxWidth - padH * 2);
      final innerH = math.max(80.0, maxHeight - padTop - padBottom);
      final maxCoverW = innerW * (isWide ? 0.62 : 0.88);
      final maxCoverH = math.max(minCover, innerH - gap - metaReserve);
      final targetCoverSide = math
          .min(maxCoverW, maxCoverH)
          .clamp(minCover, 620.0)
          .floorToDouble();
      final maxMetaHeight = (innerH * 0.56).clamp(64.0, 220.0).toDouble();

      return Padding(
        key: key,
        padding: EdgeInsets.fromLTRB(padH, padTop, padH, padBottom),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: LayoutBuilder(
                  builder: (context, coverConstraints) {
                    final side = math
                        .min(
                          targetCoverSide,
                          math.min(
                            coverConstraints.maxWidth,
                            coverConstraints.maxHeight,
                          ),
                        )
                        .clamp(48.0, 620.0)
                        .floorToDouble();
                    return _buildHeroCoverCard(
                      track,
                      maxSide: side,
                      shadowBlur: shadowBlur,
                      shadowSpread: shadowSpread,
                      shadowOffsetY: shadowOffsetY,
                    );
                  },
                ),
              ),
              SizedBox(height: gap),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: innerW,
                  maxHeight: maxMetaHeight,
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.center,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: innerW),
                    child: _buildTrackMetadata(
                      track,
                      centered: true,
                      titleFontSize: titleSize,
                      compact: compactChrome,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_mode == _NowPlayingMode.lyrics || !isWide) {
      final headerCoverSide = ultraCompact ? 44.0 : 64.0;
      final headerPad = EdgeInsets.fromLTRB(
        hStagePad,
        ultraCompact ? 2 : 4,
        hStagePad,
        ultraCompact ? 4 : 8,
      );
      return Column(
        key: key,
        children: [
          if (!isWide)
            Padding(
              padding: headerPad,
              child: Row(
                children: [
                  _buildHeroCoverCard(
                    track,
                    maxSide: headerCoverSide,
                    compact: true,
                  ),
                  SizedBox(width: ultraCompact ? 10 : 14),
                  Expanded(
                    child: _buildTrackMetadata(
                      track,
                      centered: false,
                      titleFontSize: ultraCompact ? 14.5 : 16.0,
                      compact: ultraCompact,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: LyricsView(
                  lyrics: lyrics,
                  currentPosition: state.position,
                  onSeek: widget.audioService.seek,
                  centered: true,
                  isPlaying: state.status == PlaybackStatus.playing,
                  trackId: track?.id,
                  audioService: widget.audioService,
                ),
              ),
            ),
          ),
        ],
      );
    }

    final compactSplitShadow = maxHeight < 360;
    final splitShadowBlur = compactSplitShadow ? 24.0 : 36.0;
    final splitShadowSpread = compactSplitShadow ? 0.0 : 2.0;
    final splitShadowOffsetY = compactSplitShadow ? 10.0 : 14.0;
    final splitPadH = math.max(
      hStagePad,
      splitShadowBlur + splitShadowSpread + 10.0,
    );
    final splitPadTop = (splitShadowBlur +
            splitShadowSpread +
            (compactChrome ? 2.0 : 4.0))
        .clamp(
          compactChrome ? 16.0 : 24.0,
          math.max(
            compactChrome ? 16.0 : 24.0,
            maxHeight * (compactChrome ? 0.09 : 0.14),
          ),
        )
        .toDouble();
    final splitPadBottom = compactSplitShadow
        ? 14.0
        : (compactChrome ? 16.0 : 24.0);
    final splitGap = compactChrome ? 12.0 : (maxHeight >= 460 ? 22.0 : 14.0);
    final splitTitleSize = compactChrome ? 18.0 : 22.0;

    return Padding(
      key: key,
      padding: EdgeInsets.only(right: hStagePad),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 5,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                splitPadH,
                splitPadTop,
                splitPadH,
                splitPadBottom,
              ),
              child: LayoutBuilder(
                builder: (context, leftConstraints) {
                  final leftInnerW = math.max(160.0, leftConstraints.maxWidth);
                  final leftInnerH = math.max(80.0, leftConstraints.maxHeight);
                  final maxMetaHeight =
                      (leftInnerH * 0.56).clamp(72.0, 220.0).toDouble();
                  final targetSide = math
                      .min(
                        leftInnerW,
                        math.max(
                          64.0,
                          leftInnerH -
                              splitGap -
                              (compactChrome ? 114.0 : 148.0),
                        ),
                      )
                      .clamp(64.0, 560.0)
                      .floorToDouble();
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: LayoutBuilder(
                            builder: (context, coverConstraints) {
                              final side = math
                                  .min(
                                    targetSide,
                                    math.min(
                                      coverConstraints.maxWidth,
                                      coverConstraints.maxHeight,
                                    ),
                                  )
                                  .clamp(48.0, 560.0)
                                  .floorToDouble();
                              return _buildHeroCoverCard(
                                track,
                                maxSide: side,
                                shadowBlur: splitShadowBlur,
                                shadowSpread: splitShadowSpread,
                                shadowOffsetY: splitShadowOffsetY,
                              );
                            },
                          ),
                        ),
                        SizedBox(height: splitGap),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: leftInnerW,
                            maxHeight: maxMetaHeight,
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.center,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: leftInnerW),
                              child: _buildTrackMetadata(
                                track,
                                centered: true,
                                titleFontSize: splitTitleSize,
                                compact: compactChrome,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: LuminaTokens.spaceMd),
          Expanded(
            flex: 6,
            child: Padding(
              padding: EdgeInsets.symmetric(
                vertical: compactChrome
                    ? LuminaTokens.spaceXs
                    : LuminaTokens.spaceMd,
              ),
              child: LyricsView(
                lyrics: lyrics,
                currentPosition: state.position,
                onSeek: widget.audioService.seek,
                centered: true,
                isPlaying: state.status == PlaybackStatus.playing,
                trackId: track?.id,
                audioService: widget.audioService,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroCoverCard(
    TrackInfo? track, {
    required double maxSide,
    bool compact = false,
    double shadowBlur = 36,
    double shadowSpread = 2,
    double shadowOffsetY = 14,
  }) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxSide, maxHeight: maxSide),
      child: AspectRatio(
        aspectRatio: 1,
        child: AlbumArtworkView(
          track: track,
          size: maxSide,
          audioService: widget.audioService,
          borderRadius: BorderRadius.circular(compact ? 6 : 12),
          boxShadow: compact
              ? null
              : [
                  BoxShadow(
                    color: const Color(0x88000000),
                    blurRadius: shadowBlur,
                    spreadRadius: shadowSpread,
                    offset: Offset(0, shadowOffsetY),
                  ),
                ],
        ),
      ),
    );
  }

  Widget _buildTrackMetadata(
    TrackInfo? track, {
    required bool centered,
    double? titleFontSize,
    bool compact = false,
  }) {
    final crossAxis =
        centered ? CrossAxisAlignment.center : CrossAxisAlignment.start;
    final align = centered ? TextAlign.center : TextAlign.start;

    final metaSubtitle = track == null
        ? ''
        : (track.hasDistinctAlbumArtist
            ? '${track.artist} (專輯演出者: ${track.albumArtist})  •  ${track.album}'
            : '${track.artist}  •  ${track.album}');

    return Column(
      crossAxisAlignment: crossAxis,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          track?.title ?? '尚未選擇曲目',
          textAlign: align,
          maxLines: compact ? 1 : 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: LuminaTokens.textPrimary,
            fontSize: titleFontSize ?? (centered ? 22 : 16),
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: compact ? 2 : LuminaTokens.space2xs),
        Text(
          metaSubtitle,
          textAlign: align,
          maxLines: compact ? 1 : 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: LuminaTokens.textSecondary,
            fontSize: compact ? 12.5 : 13.5,
          ),
        ),
        if (centered && track != null) ...[
          SizedBox(height: compact ? 6 : LuminaTokens.spaceSm),
          StreamBuilder<SignalPath>(
            stream: widget.audioService.signalPathStream,
            initialData: widget.audioService.currentSignalPath,
            builder: (context, sigSnap) {
              final sp = sigSnap.data ?? widget.audioService.currentSignalPath;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: LuminaTokens.spaceXs,
                  runSpacing: 6,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(1),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: LuminaTokens.cardElevatedBg.withValues(
                            alpha: 0.85,
                          ),
                          borderRadius: BorderRadius.circular(
                            LuminaTokens.radiusPill,
                          ),
                          border: Border.all(
                            color: LuminaTokens.borderControl,
                            width: 1,
                          ),
                        ),
                        child: Text(
                          track.format.label,
                          style: const TextStyle(
                            color: LuminaTokens.textSecondary,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                            height: 1.25,
                          ),
                        ),
                      ),
                    ),
                    QualityBadge(
                      quality: sp.overallQuality,
                      onTap: () =>
                          SignalPathModal.show(context, widget.audioService),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}

class _ModeIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  const _ModeIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_ModeIconButton> createState() => _ModeIconButtonState();
}

class _ModeIconButtonState extends State<_ModeIconButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        selected: widget.selected,
        label: widget.tooltip,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
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
            borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
            child: AnimatedContainer(
              duration: LuminaTokens.focusDuration,
              curve: LuminaTokens.motionCurve,
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: widget.selected
                    ? LuminaTokens.cardElevatedBg.withValues(alpha: 0.92)
                    : (_hovered
                          ? LuminaTokens.cardHoverBg.withValues(alpha: 0.72)
                          : Colors.transparent),
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                border: Border.all(
                  color: _focused
                      ? LuminaTokens.focusRing
                      : (widget.selected
                            ? LuminaTokens.borderControl
                            : Colors.transparent),
                  width: 1.5,
                ),
              ),
              child: Icon(
                widget.icon,
                size: 19,
                color: widget.selected
                    ? LuminaTokens.textPrimary
                    : LuminaTokens.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
