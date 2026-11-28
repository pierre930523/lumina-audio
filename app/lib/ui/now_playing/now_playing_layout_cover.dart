part of 'now_playing_layout.dart';

NowPlayingLayoutMetrics _computeCoverLayoutMetrics({
  required double w,
  required double h,
  required double vpW,
  required double vpH,
  required double hStagePad,
  required bool ultraCompact,
  required bool compact,
}) {
  if (w >= 480 && h < 300) {
    final padTop = NowPlayingLayoutMetrics._safeClamp(
      h * 0.05,
      math.min(6.0, h * 0.1),
      14.0,
    );
    final padBottom = NowPlayingLayoutMetrics._safeClamp(
      h * 0.05,
      math.min(6.0, h * 0.1),
      14.0,
    );
    final stagePadH = NowPlayingLayoutMetrics._safeClamp(
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
    final coverSide = NowPlayingLayoutMetrics._safeClamp(
      math.min(availH - 8.0, w * 0.44),
      lo,
      hi,
    ).floorToDouble();
    final maxMetaHeight = NowPlayingLayoutMetrics._safeClamp(
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
      gap: NowPlayingLayoutMetrics._safeClamp(w * 0.03, 16.0, 32.0),
      titleFontSize: h < 220 ? 17.0 : 19.0,
      subtitleFontSize: 12.5,
      metaTitleGap: 2.0,
      metaPillGap: 6.0,
      coverBorderRadius: math.min(
        coverSide * 0.08,
        NowPlayingLayoutMetrics._safeClamp(vpH * 0.018, 10.0, 16.0),
      ),
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
    shadowBlur = 48.0;
    shadowSpread = 0.0;
    shadowOffsetY = 20.0;
  }

  final minPadH = math.min(16.0, w * 0.14);
  final stagePadH = math.max(
    hStagePad,
    NowPlayingLayoutMetrics._safeClamp(
      shadowBlur + shadowSpread + 14.0,
      minPadH,
      math.max(minPadH, w * 0.14),
    ),
  );
  final padTop = math.min(
    ultraCompact ? 8.0 : (compact ? 12.0 : 20.0),
    math.max(0.0, h * 0.10),
  );
  final padBottom = math.min(
    ultraCompact ? 8.0 : (compact ? 12.0 : 16.0),
    math.max(0.0, h * 0.10),
  );
  final innerW = math.max(0.0, w - stagePadH * 2);
  final innerH = math.max(0.0, h - padTop - padBottom);
  final targetGap = NowPlayingLayoutMetrics._safeClamp(vpH * 0.025, 16.0, 28.0);
  final gap = ultraCompact
      ? math.min(8.0, innerH * 0.12)
      : (compact
            ? math.min(12.0, innerH * 0.12)
            : math.min(targetGap, innerH * 0.15));
  final titleFontSize = ultraCompact
      ? 17.0
      : (compact
            ? 20.0
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
    ultraCompact ? 80.0 : (compact ? 88.0 : naturalMetaReserve),
    innerH * 0.45,
  );
  final roomH = math.max(0.0, innerH - gap - metaReserve);
  final roomW = math.max(0.0, innerW);
  final desiredCover = NowPlayingLayoutMetrics._safeClamp(
    math.min(vpH * 0.56, vpW * 0.46),
    300.0,
    640.0,
  );
  final physicalMax = math
      .max(0.0, math.min(roomW, roomH))
      .floorToDouble();
  final coverSide = math.min(desiredCover, physicalMax).floorToDouble();
  final preferredMin = ultraCompact
      ? 96.0
      : (compact ? 168.0 : 220.0);
  final minCoverSide = math.min(preferredMin, coverSide);
  final maxCoverSide = math.max(coverSide, physicalMax);
  final remainingMeta = math.max(0.0, innerH - coverSide - gap);
  final maxMetaHeight = NowPlayingLayoutMetrics._safeClamp(
    remainingMeta,
    math.min(64.0, remainingMeta),
    220.0,
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
