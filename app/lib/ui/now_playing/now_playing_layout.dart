import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../services/now_playing_view_controller.dart';

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

  static NowPlayingLayoutMetrics compute({
    required double width,
    required double height,
    required NowPlayingViewMode mode,
  }) {
    final w = width.isFinite && width > 0 ? width : 0.0;
    final h = height.isFinite && height > 0 ? height : 0.0;
    final hStagePad = _safeClamp(w * 0.03, math.min(16.0, w * 0.08), 48.0);
    final ultraCompact = h < 300;
    final compact = h < 440;

    switch (mode) {
      case NowPlayingViewMode.cover:
        if (w >= 480 && h < 300) {
          final padTop = _safeClamp(h * 0.05, math.min(6.0, h * 0.1), 14.0);
          final padBottom = _safeClamp(h * 0.05, math.min(6.0, h * 0.1), 14.0);
          final stagePadH = _safeClamp(
            w * 0.04,
            math.min(16.0, w * 0.1),
            40.0,
          );
          final availH = math.max(0.0, h - padTop - padBottom);
          final lo = math.min(
            96.0,
            math.max(math.min(48.0, availH), math.min(availH, h - 16.0)),
          );
          final hi = math.max(lo, math.min(260.0, availH));
          final coverSide = _safeClamp(
            math.min(availH - 8.0, w * 0.44),
            lo,
            hi,
          ).floorToDouble();
          final maxMetaHeight = _safeClamp(
            availH,
            math.min(48.0, availH),
            220.0,
          );
          return NowPlayingLayoutMetrics(
            arrangement: NowPlayingStageArrangement.coverLandscapeRow,
            coverSide: coverSide,
            minCoverSide: lo.floorToDouble(),
            maxCoverSide: hi.floorToDouble(),
            leftFlex: 5,
            rightFlex: 6,
            stagePadH: stagePadH,
            padTop: padTop,
            padBottom: padBottom,
            gap: _safeClamp(w * 0.03, 16.0, 32.0),
            titleFontSize: h < 220 ? 17.0 : 19.0,
            compactMetadata: true,
            ultraCompact: true,
            shadowBlur: 14.0,
            shadowSpread: 0.0,
            shadowOffsetY: 8.0,
            maxMetaHeight: maxMetaHeight,
          );
        }

        final double shadowBlur;
        final double shadowSpread;
        final double shadowOffsetY;
        if (h < 300) {
          shadowBlur = 14.0;
          shadowSpread = 0.0;
          shadowOffsetY = 8.0;
        } else if (h < 360 || w < 400) {
          shadowBlur = 24.0;
          shadowSpread = 0.0;
          shadowOffsetY = 10.0;
        } else {
          shadowBlur = 36.0;
          shadowSpread = 2.0;
          shadowOffsetY = 14.0;
        }

        final minPadH = math.min(16.0, w * 0.14);
        final stagePadH = math.max(
          hStagePad,
          _safeClamp(
            shadowBlur + shadowSpread + 14.0,
            minPadH,
            math.max(minPadH, w * 0.14),
          ),
        );
        final minPadTop = math.min(ultraCompact ? 8.0 : 18.0, h * 0.12);
        final padTop = _safeClamp(
          shadowBlur + shadowSpread + (compact ? 4.0 : 6.0),
          minPadTop,
          math.max(minPadTop, h * (compact ? 0.08 : 0.14)),
        );
        final padBottom = math.min(
          ultraCompact ? 8.0 : (shadowBlur < 36.0 ? 14.0 : 24.0),
          math.max(0.0, h * 0.12),
        );
        final innerW = math.max(0.0, w - stagePadH * 2);
        final innerH = math.max(0.0, h - padTop - padBottom);
        final gap = math.min(
          ultraCompact ? 8.0 : (compact ? 12.0 : (h >= 460 ? 22.0 : 14.0)),
          innerH * 0.15,
        );
        final titleFontSize = ultraCompact ? 17.0 : (compact ? 19.0 : 22.0);
        final metaReserve = math.min(
          ultraCompact ? 84.0 : (compact ? 112.0 : 148.0),
          innerH * 0.45,
        );
        final roomH = math.max(0.0, innerH - gap - metaReserve);
        final roomW = math.max(0.0, innerW * (w >= 900 ? 0.68 : 0.88));
        final physicalMax = math.min(580.0, math.min(roomW, roomH)).floorToDouble();
        final preferredMin = ultraCompact ? 96.0 : (compact ? 168.0 : 220.0);
        final minCoverSide = math.min(preferredMin, physicalMax);
        final maxCoverSide = math.max(minCoverSide, physicalMax);
        final coverSide = _safeClamp(
          physicalMax,
          minCoverSide,
          maxCoverSide,
        ).floorToDouble();
        final remainingMeta = math.max(0.0, innerH - coverSide - gap);
        final maxMetaHeight = _safeClamp(
          remainingMeta,
          math.min(64.0, remainingMeta),
          200.0,
        );

        return NowPlayingLayoutMetrics(
          arrangement: NowPlayingStageArrangement.coverVertical,
          coverSide: coverSide,
          minCoverSide: minCoverSide,
          maxCoverSide: maxCoverSide,
          leftFlex: 5,
          rightFlex: 6,
          stagePadH: stagePadH,
          padTop: padTop,
          padBottom: padBottom,
          gap: gap,
          titleFontSize: titleFontSize,
          compactMetadata: compact,
          ultraCompact: ultraCompact,
          shadowBlur: shadowBlur,
          shadowSpread: shadowSpread,
          shadowOffsetY: shadowOffsetY,
          maxMetaHeight: maxMetaHeight,
        );

      case NowPlayingViewMode.split:
        if (w >= 680 && h >= 260) {
          final leftFlex = 5;
          final rightFlex = w >= 1100 ? 6 : 5;
          final double shadowBlur;
          final double shadowSpread;
          final double shadowOffsetY;
          if (h < 300) {
            shadowBlur = 14.0;
            shadowSpread = 0.0;
            shadowOffsetY = 8.0;
          } else if (h < 360) {
            shadowBlur = 24.0;
            shadowSpread = 0.0;
            shadowOffsetY = 10.0;
          } else {
            shadowBlur = 36.0;
            shadowSpread = 2.0;
            shadowOffsetY = 14.0;
          }

          final stagePadH = math.max(
            hStagePad,
            shadowBlur + shadowSpread + 10.0,
          );
          final minPadTop = ultraCompact ? 10.0 : (compact ? 16.0 : 24.0);
          final padTop = _safeClamp(
            shadowBlur + shadowSpread + (compact ? 2.0 : 4.0),
            minPadTop,
            math.max(minPadTop, h * (compact ? 0.09 : 0.14)),
          );
          final padBottom = ultraCompact
              ? 10.0
              : (h < 360 ? 14.0 : (compact ? 16.0 : 24.0));
          final gap = ultraCompact
              ? 8.0
              : (compact ? 12.0 : (h >= 460 ? 22.0 : 14.0));
          final titleFontSize = ultraCompact ? 16.5 : (compact ? 18.0 : 22.0);
          final metaReserve = ultraCompact ? 84.0 : (compact ? 114.0 : 148.0);
          final totalW = math.max(0.0, w - stagePadH - 16.0);
          final leftColW = totalW * (leftFlex / (leftFlex + rightFlex));
          final leftInnerW = math.max(0.0, leftColW - stagePadH * 2);
          final innerH = math.max(0.0, h - padTop - padBottom);
          final roomH = math.max(0.0, innerH - gap - metaReserve);
          final physicalMax = math
              .min(540.0, math.min(leftInnerW, roomH))
              .floorToDouble();
          final preferredMin = h < 310 ? 112.0 : (h < 430 ? 156.0 : 200.0);
          final minCoverSide = math.min(preferredMin, physicalMax);
          final maxCoverSide = math.max(minCoverSide, physicalMax);
          final coverSide = _safeClamp(
            physicalMax,
            minCoverSide,
            maxCoverSide,
          ).floorToDouble();
          final remainingMeta = math.max(0.0, innerH - coverSide - gap);
          final maxMetaHeight = _safeClamp(
            remainingMeta,
            math.min(64.0, remainingMeta),
            200.0,
          );

          return NowPlayingLayoutMetrics(
            arrangement: NowPlayingStageArrangement.splitTwoColumn,
            coverSide: coverSide,
            minCoverSide: minCoverSide,
            maxCoverSide: maxCoverSide,
            leftFlex: leftFlex,
            rightFlex: rightFlex,
            stagePadH: stagePadH,
            padTop: padTop,
            padBottom: padBottom,
            gap: gap,
            titleFontSize: titleFontSize,
            compactMetadata: compact,
            ultraCompact: ultraCompact,
            shadowBlur: shadowBlur,
            shadowSpread: shadowSpread,
            shadowOffsetY: shadowOffsetY,
            maxMetaHeight: maxMetaHeight,
          );
        }

        if (w < 680 && h >= 460) {
          final stagePadH = _safeClamp(
            w * 0.04,
            math.min(14.0, w * 0.1),
            28.0,
          );
          final maxSafeW = math.max(0.0, w - stagePadH * 2 - 16.0);
          final lo = math.min(124.0, math.min(220.0, maxSafeW));
          final hi = math.max(lo, math.min(220.0, maxSafeW));
          final rawCover = math.min(
            w * (w >= 440 ? 0.36 : 0.46),
            h * 0.28,
          );
          final coverSide = _safeClamp(rawCover, lo, hi).floorToDouble();
          final maxMetaHeight = _safeClamp(
            coverSide + 16.0,
            math.min(96.0, coverSide + 16.0),
            220.0,
          );
          return NowPlayingLayoutMetrics(
            arrangement: NowPlayingStageArrangement.splitNarrowStacked,
            coverSide: coverSide,
            minCoverSide: lo.floorToDouble(),
            maxCoverSide: hi.floorToDouble(),
            leftFlex: 1,
            rightFlex: 1,
            stagePadH: stagePadH,
            padTop: 8.0,
            padBottom: 8.0,
            gap: 12.0,
            titleFontSize: w >= 440 ? 18.0 : 16.5,
            compactMetadata: w < 360,
            ultraCompact: false,
            shadowBlur: 20.0,
            shadowSpread: 0.0,
            shadowOffsetY: 8.0,
            maxMetaHeight: maxMetaHeight,
          );
        }

        final stagePadHCompact = _safeClamp(
          w * 0.03,
          math.min(12.0, w * 0.1),
          24.0,
        );
        final padTopCompact = math.min(ultraCompact ? 4.0 : 6.0, h * 0.1);
        final padBottomCompact = math.min(ultraCompact ? 4.0 : 8.0, h * 0.1);
        final availHCompact = math.max(
          0.0,
          h - padTopCompact - padBottomCompact,
        );
        final loCompact = math.min(64.0, math.min(108.0, availHCompact * 0.5));
        final hiCompact = math.max(
          loCompact,
          math.min(108.0, availHCompact * 0.5),
        );
        final coverCompact = _safeClamp(
          h * 0.22,
          loCompact,
          hiCompact,
        ).floorToDouble();
        return NowPlayingLayoutMetrics(
          arrangement: NowPlayingStageArrangement.splitCompactHeader,
          coverSide: coverCompact,
          minCoverSide: loCompact.floorToDouble(),
          maxCoverSide: hiCompact.floorToDouble(),
          leftFlex: 1,
          rightFlex: 1,
          stagePadH: stagePadHCompact,
          padTop: padTopCompact,
          padBottom: padBottomCompact,
          gap: ultraCompact ? 10.0 : 12.0,
          titleFontSize: ultraCompact ? 14.5 : 16.0,
          compactMetadata: true,
          ultraCompact: ultraCompact,
          shadowBlur: 12.0,
          shadowSpread: 0.0,
          shadowOffsetY: 4.0,
          maxMetaHeight: _safeClamp(
            coverCompact + 12.0,
            math.min(64.0, coverCompact + 12.0),
            140.0,
          ),
        );

      case NowPlayingViewMode.lyrics:
        if (w >= 760 && h >= 300) {
          return NowPlayingLayoutMetrics(
            arrangement: NowPlayingStageArrangement.lyricsFull,
            coverSide: 0.0,
            minCoverSide: 0.0,
            maxCoverSide: 0.0,
            leftFlex: 1,
            rightFlex: 1,
            stagePadH: hStagePad,
            padTop: compact ? 4.0 : 8.0,
            padBottom: compact ? 6.0 : 12.0,
            gap: 12.0,
            titleFontSize: 18.0,
            compactMetadata: compact,
            ultraCompact: false,
            shadowBlur: 0.0,
            shadowSpread: 0.0,
            shadowOffsetY: 0.0,
            maxMetaHeight: 0.0,
          );
        }

        final stagePadHLyrics = _safeClamp(
          w * 0.03,
          math.min(12.0, w * 0.1),
          32.0,
        );
        final padTopLyrics = math.min(ultraCompact ? 2.0 : 4.0, h * 0.1);
        final padBottomLyrics = math.min(ultraCompact ? 4.0 : 8.0, h * 0.1);
        final availHLyrics = math.max(0.0, h - padTopLyrics - padBottomLyrics);
        final loLyrics = math.min(56.0, math.min(88.0, availHLyrics * 0.5));
        final hiLyrics = math.max(
          loLyrics,
          math.min(88.0, availHLyrics * 0.5),
        );
        final coverLyrics = _safeClamp(
          h * 0.16,
          loLyrics,
          hiLyrics,
        ).floorToDouble();

        return NowPlayingLayoutMetrics(
          arrangement: NowPlayingStageArrangement.lyricsCompactHeader,
          coverSide: coverLyrics,
          minCoverSide: loLyrics.floorToDouble(),
          maxCoverSide: hiLyrics.floorToDouble(),
          leftFlex: 1,
          rightFlex: 1,
          stagePadH: stagePadHLyrics,
          padTop: padTopLyrics,
          padBottom: padBottomLyrics,
          gap: ultraCompact ? 10.0 : 14.0,
          titleFontSize: ultraCompact ? 14.5 : 16.0,
          compactMetadata: true,
          ultraCompact: ultraCompact,
          shadowBlur: 0.0,
          shadowSpread: 0.0,
          shadowOffsetY: 0.0,
          maxMetaHeight: _safeClamp(
            coverLyrics + 8.0,
            math.min(48.0, coverLyrics + 8.0),
            120.0,
          ),
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
        other.compactMetadata == compactMetadata &&
        other.ultraCompact == ultraCompact &&
        other.shadowBlur == shadowBlur &&
        other.shadowSpread == shadowSpread &&
        other.shadowOffsetY == shadowOffsetY &&
        other.maxMetaHeight == maxMetaHeight;
  }

  @override
  int get hashCode => Object.hash(
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
    compactMetadata,
    ultraCompact,
    shadowBlur,
    shadowSpread,
    shadowOffsetY,
    maxMetaHeight,
  );
}
