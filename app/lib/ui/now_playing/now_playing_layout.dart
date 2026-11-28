import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../services/now_playing_view_controller.dart';

part 'now_playing_layout_cover.dart';
part 'now_playing_layout_split_lyrics.dart';

/// Responsive stage arrangements for the Now Playing overlay.
enum NowPlayingStageArrangement {
  splitTwoColumn,
  splitNarrowStacked,
  splitCompactHeader,
  coverVertical,
  coverLandscapeRow,
  lyricsFull,
  lyricsCompactHeader,
}

/// Pure, deterministic layout metrics computed from stage bounds and view mode.
@immutable
class NowPlayingLayoutMetrics {
  final NowPlayingStageArrangement arrangement;
  final double coverSide;
  final double minCoverSide;
  final double maxCoverSide;
  final int leftFlex;
  final int rightFlex;
  final double stagePadH;
  final double padTop;
  final double padBottom;
  final double gap;
  final double titleFontSize;
  final double subtitleFontSize;
  final double metaTitleGap;
  final double metaPillGap;
  final double coverBorderRadius;
  final bool compactMetadata;
  final bool ultraCompact;
  final double shadowBlur;
  final double shadowSpread;
  final double shadowOffsetY;
  final double maxMetaHeight;

  const NowPlayingLayoutMetrics({
    required this.arrangement,
    required this.coverSide,
    required this.minCoverSide,
    required this.maxCoverSide,
    required this.leftFlex,
    required this.rightFlex,
    required this.stagePadH,
    required this.padTop,
    required this.padBottom,
    required this.gap,
    required this.titleFontSize,
    required this.subtitleFontSize,
    required this.metaTitleGap,
    required this.metaPillGap,
    required this.coverBorderRadius,
    required this.compactMetadata,
    required this.ultraCompact,
    required this.shadowBlur,
    required this.shadowSpread,
    required this.shadowOffsetY,
    required this.maxMetaHeight,
  });

  static double _safeClamp(double value, double minVal, double maxVal) {
    final lo = math.min(minVal, maxVal);
    final hi = math.max(minVal, maxVal);
    if (!value.isFinite) return lo;
    return value.clamp(lo, hi).toDouble();
  }

  static double _responsiveCoverRadius(double vpH, double coverSide) {
    if (coverSide <= 0.0) return 0.0;
    final target = _safeClamp(vpH * 0.018, 14.0, 22.0);
    return math.min(coverSide * 0.08, target);
  }

  static NowPlayingLayoutMetrics compute({
    required double width,
    required double height,
    required NowPlayingViewMode mode,
    double? viewportWidth,
    double? viewportHeight,
  }) {
    final w = width.isFinite && width > 0 ? width : 0.0;
    final h = height.isFinite && height > 0 ? height : 0.0;
    final vpW = (viewportWidth != null &&
            viewportWidth.isFinite &&
            viewportWidth > 0)
        ? viewportWidth
        : w;
    final vpH = (viewportHeight != null &&
            viewportHeight.isFinite &&
            viewportHeight > 0)
        ? viewportHeight
        : h;
    final hStagePad = _safeClamp(w * 0.03, math.min(16.0, w * 0.08), 48.0);
    final ultraCompact = h < 300;
    final compact = h < 440;

    switch (mode) {
      case NowPlayingViewMode.cover:
        return _computeCoverLayoutMetrics(
          w: w,
          h: h,
          vpW: vpW,
          vpH: vpH,
          hStagePad: hStagePad,
          ultraCompact: ultraCompact,
          compact: compact,
        );
      case NowPlayingViewMode.split:
        return _computeSplitLayoutMetrics(
          w: w,
          h: h,
          vpW: vpW,
          vpH: vpH,
          hStagePad: hStagePad,
          ultraCompact: ultraCompact,
          compact: compact,
        );
      case NowPlayingViewMode.lyrics:
        return _computeLyricsLayoutMetrics(
          w: w,
          h: h,
          hStagePad: hStagePad,
          ultraCompact: ultraCompact,
          compact: compact,
        );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is NowPlayingLayoutMetrics &&
        other.arrangement == arrangement &&
        other.coverSide == coverSide &&
        other.minCoverSide == minCoverSide &&
        other.maxCoverSide == maxCoverSide &&
        other.leftFlex == leftFlex &&
        other.rightFlex == rightFlex &&
        other.stagePadH == stagePadH &&
        other.padTop == padTop &&
        other.padBottom == padBottom &&
        other.gap == gap &&
        other.titleFontSize == titleFontSize &&
        other.subtitleFontSize == subtitleFontSize &&
        other.metaTitleGap == metaTitleGap &&
        other.metaPillGap == metaPillGap &&
        other.coverBorderRadius == coverBorderRadius &&
        other.compactMetadata == compactMetadata &&
        other.ultraCompact == ultraCompact &&
        other.shadowBlur == shadowBlur &&
        other.shadowSpread == shadowSpread &&
        other.shadowOffsetY == shadowOffsetY &&
        other.maxMetaHeight == maxMetaHeight;
  }

  @override
  int get hashCode => Object.hashAll([
        arrangement,
        coverSide,
        minCoverSide,
        maxCoverSide,
        leftFlex,
        rightFlex,
        stagePadH,
        padTop,
        padBottom,
        gap,
        titleFontSize,
        subtitleFontSize,
        metaTitleGap,
        metaPillGap,
        coverBorderRadius,
        compactMetadata,
        ultraCompact,
        shadowBlur,
        shadowSpread,
        shadowOffsetY,
        maxMetaHeight,
      ]);
}
