part of 'now_playing_layout.dart';

NowPlayingLayoutMetrics _computeSplitLayoutMetrics({
  required double w,
  required double h,
  required double vpW,
  required double vpH,
  required double hStagePad,
  required bool ultraCompact,
  required bool compact,
}) {
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
      shadowBlur = 48.0;
      shadowSpread = 0.0;
      shadowOffsetY = 20.0;
    }

    final stagePadH = math.max(
      hStagePad,
      shadowBlur + shadowSpread + 10.0,
    );
    final padTop = math.min(
      ultraCompact ? 8.0 : (compact ? 12.0 : 20.0),
      math.max(0.0, h * 0.10),
    );
    final padBottom = math.min(
      ultraCompact ? 8.0 : (compact ? 12.0 : 16.0),
      math.max(0.0, h * 0.10),
    );
    final innerH = math.max(0.0, h - padTop - padBottom);
    final targetGap = NowPlayingLayoutMetrics._safeClamp(
      vpH * 0.025,
      16.0,
      28.0,
    );
    final gap = ultraCompact
        ? math.min(8.0, innerH * 0.12)
        : (compact
              ? math.min(12.0, innerH * 0.12)
              : math.min(targetGap, innerH * 0.15));
    final titleFontSize = ultraCompact
        ? 16.5
        : (compact
              ? 18.0
              : NowPlayingLayoutMetrics._safeClamp(vpH * 0.028, 22.0, 34.0));
    final subtitleFontSize = ultraCompact
        ? 12.0
        : (compact
              ? 12.5
              : NowPlayingLayoutMetrics._safeClamp(vpH * 0.015, 14.0, 18.0));
    final metaTitleGap = compact
        ? 2.0
        : NowPlayingLayoutMetrics._safeClamp(vpH * 0.006, 4.0, 8.0);
    final metaPillGap = compact
        ? 6.0
        : NowPlayingLayoutMetrics._safeClamp(vpH * 0.011, 8.0, 14.0);
    final naturalMetaReserve = titleFontSize * 2.0 +
        metaTitleGap +
        subtitleFontSize * 1.4 +
        metaPillGap +
        30.0;
    final metaReserve = math.min(
      ultraCompact ? 80.0 : (compact ? 104.0 : naturalMetaReserve),
      innerH * 0.45,
    );
    final totalW = math.max(0.0, w - stagePadH - 16.0);
    final leftColW = totalW * (leftFlex / (leftFlex + rightFlex));
    final leftInnerW = math.max(0.0, leftColW - stagePadH * 2);
    final roomH = math.max(0.0, innerH - gap - metaReserve);
    final desiredCover = NowPlayingLayoutMetrics._safeClamp(
      math.min(vpH * 0.56, vpW * 0.46),
      300.0,
      640.0,
    );
    final physicalMax = math
        .max(0.0, math.min(640.0, math.min(leftInnerW, roomH)))
        .floorToDouble();
    final coverSide = math.min(desiredCover, physicalMax).floorToDouble();
    final preferredMin = h < 310 ? 112.0 : (h < 430 ? 156.0 : 200.0);
    final minCoverSide = math.min(preferredMin, coverSide);
    final maxCoverSide = math.max(coverSide, physicalMax);
    final remainingMeta = math.max(0.0, innerH - coverSide - gap);
    final maxMetaHeight = NowPlayingLayoutMetrics._safeClamp(
      remainingMeta,
      math.min(64.0, remainingMeta),
      220.0,
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
      subtitleFontSize: subtitleFontSize,
      metaTitleGap: metaTitleGap,
      metaPillGap: metaPillGap,
      coverBorderRadius: NowPlayingLayoutMetrics._responsiveCoverRadius(
        vpH,
        coverSide,
      ),
      compactMetadata: compact,
      ultraCompact: ultraCompact,
      shadowBlur: shadowBlur,
      shadowSpread: shadowSpread,
      shadowOffsetY: shadowOffsetY,
      maxMetaHeight: maxMetaHeight,
    );
  }

  if (w < 680 && h >= 460) {
    final stagePadH = NowPlayingLayoutMetrics._safeClamp(
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
    final coverSide = NowPlayingLayoutMetrics._safeClamp(
      rawCover,
      lo,
      hi,
    ).floorToDouble();
    final maxMetaHeight = NowPlayingLayoutMetrics._safeClamp(
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
      subtitleFontSize: 13.0,
      metaTitleGap: 3.0,
      metaPillGap: 6.0,
      coverBorderRadius: NowPlayingLayoutMetrics._responsiveCoverRadius(
        vpH,
        coverSide,
      ),
      compactMetadata: w < 360,
      ultraCompact: false,
      shadowBlur: 20.0,
      shadowSpread: 0.0,
      shadowOffsetY: 8.0,
      maxMetaHeight: maxMetaHeight,
    );
  }

  final stagePadHCompact = NowPlayingLayoutMetrics._safeClamp(
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
  final coverCompact = NowPlayingLayoutMetrics._safeClamp(
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
    subtitleFontSize: 12.5,
    metaTitleGap: 2.0,
    metaPillGap: 6.0,
    coverBorderRadius: 8.0,
    compactMetadata: true,
    ultraCompact: ultraCompact,
    shadowBlur: 12.0,
    shadowSpread: 0.0,
    shadowOffsetY: 4.0,
    maxMetaHeight: NowPlayingLayoutMetrics._safeClamp(
      coverCompact + 12.0,
      math.min(64.0, coverCompact + 12.0),
      140.0,
    ),
  );
}

NowPlayingLayoutMetrics _computeLyricsLayoutMetrics({
  required double w,
  required double h,
  required double hStagePad,
  required bool ultraCompact,
  required bool compact,
}) {
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
      subtitleFontSize: 13.5,
      metaTitleGap: 4.0,
      metaPillGap: 8.0,
      coverBorderRadius: 0.0,
      compactMetadata: compact,
      ultraCompact: false,
      shadowBlur: 0.0,
      shadowSpread: 0.0,
      shadowOffsetY: 0.0,
      maxMetaHeight: 0.0,
    );
  }

  final stagePadHLyrics = NowPlayingLayoutMetrics._safeClamp(
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
  final coverLyrics = NowPlayingLayoutMetrics._safeClamp(
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
    subtitleFontSize: 12.5,
    metaTitleGap: 2.0,
    metaPillGap: 6.0,
    coverBorderRadius: 8.0,
    compactMetadata: true,
    ultraCompact: ultraCompact,
    shadowBlur: 0.0,
    shadowSpread: 0.0,
    shadowOffsetY: 0.0,
    maxMetaHeight: NowPlayingLayoutMetrics._safeClamp(
      coverLyrics + 8.0,
      math.min(48.0, coverLyrics + 8.0),
      120.0,
    ),
  );
}
