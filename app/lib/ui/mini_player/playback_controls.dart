import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import '../../models/playback_state.dart';
import '../../models/protocol/protocol_models.dart' as protocol;
import '../theme/lumina_glass_theme.dart';
import '../theme/lumina_tokens.dart';

enum LuminaRepeatMode {
  off,
  all,
  one;

  protocol.RepeatMode toRepeatMode() => switch (this) {
        LuminaRepeatMode.off => protocol.RepeatMode.off,
        LuminaRepeatMode.all => protocol.RepeatMode.all,
        LuminaRepeatMode.one => protocol.RepeatMode.one,
      };

  static LuminaRepeatMode fromRepeatMode(protocol.RepeatMode mode) =>
      switch (mode) {
        protocol.RepeatMode.off => LuminaRepeatMode.off,
        protocol.RepeatMode.all => LuminaRepeatMode.all,
        protocol.RepeatMode.one => LuminaRepeatMode.one,
      };
}

class PlaybackControls extends StatelessWidget {
  final PlaybackStatus status;
  final VoidCallback onPrevious;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback? onSkipBackward15s;
  final VoidCallback? onSkipForward30s;
  final bool compact;
  final bool isShuffleEnabled;
  final VoidCallback? onToggleShuffle;
  final LuminaRepeatMode repeatMode;
  final VoidCallback? onCycleRepeat;
  final Widget? trailingBadge;

  const PlaybackControls({
    super.key,
    required this.status,
    required this.onPrevious,
    required this.onPlayPause,
    required this.onNext,
    this.onSkipBackward15s,
    this.onSkipForward30s,
    this.compact = false,
    this.isShuffleEnabled = false,
    this.onToggleShuffle,
    this.repeatMode = LuminaRepeatMode.off,
    this.onCycleRepeat,
    this.trailingBadge,
  });

  ButtonStyle _transportStyle({
    required Color foregroundColor,
    required Color hoverColor,
    required Color focusColor,
    Color? disabledForegroundColor,
  }) {
    return IconButton.styleFrom(
      foregroundColor: foregroundColor,
      disabledForegroundColor:
          disabledForegroundColor ?? foregroundColor.withValues(alpha: 0.72),
      backgroundColor: Colors.transparent,
      hoverColor: hoverColor,
      focusColor: focusColor.withValues(alpha: 0.25),
      shape: const CircleBorder(),
    ).copyWith(
      mouseCursor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
      ),
      side: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? BorderSide(color: focusColor, width: 1.5)
            : BorderSide.none,
      ),
    );
  }

  Widget _buildModeIndicatorIcon({
    required IconData icon,
    required double size,
    required bool active,
    required Color indicatorColor,
  }) {
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        Icon(icon, size: size),
        if (active)
          Positioned(
            bottom: -4,
            child: Container(
              width: 3.5,
              height: 3.5,
              decoration: BoxDecoration(
                color: indicatorColor,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);
    final isDark = glass.isDark;
    final primaryFg =
        isDark ? LuminaTokens.glassTextPrimary : glass.textPrimary;
    final secondaryFg =
        isDark ? LuminaTokens.glassTextSecondary : glass.textSecondary;
    final tertiaryFg =
        isDark ? LuminaTokens.glassTextTertiary : glass.textTertiary;
    final hoverColor = isDark ? LuminaTokens.glassPillBg : glass.pillBg;
    final focusColor = isDark ? LuminaTokens.focusRing : glass.accent;

    final isPlaying = status == PlaybackStatus.playing;
    final isLoading =
        status == PlaybackStatus.loading || status == PlaybackStatus.buffering;
    final density = compact ? VisualDensity.compact : VisualDensity.standard;
    final btnConstraints = compact
        ? const BoxConstraints(minWidth: 32, minHeight: 32)
        : const BoxConstraints(minWidth: 36, minHeight: 36);
    final playConstraints = compact
        ? const BoxConstraints(minWidth: 34, minHeight: 34)
        : const BoxConstraints(minWidth: 38, minHeight: 38);
    final spinnerSize = compact ? 18.0 : 22.0;

    final repeatTooltip = switch (repeatMode) {
      LuminaRepeatMode.off => '循環播放',
      LuminaRepeatMode.all => '列表循環',
      LuminaRepeatMode.one => '單曲循環',
    };

    final transportRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('btn_shuffle'),
          visualDensity: density,
          padding: EdgeInsets.zero,
          constraints: btnConstraints,
          style: _transportStyle(
            foregroundColor: isShuffleEnabled ? primaryFg : tertiaryFg,
            hoverColor: hoverColor,
            focusColor: focusColor,
          ),
          icon: _buildModeIndicatorIcon(
            icon: Icons.shuffle_rounded,
            size: compact ? 16 : 18,
            active: isShuffleEnabled,
            indicatorColor: primaryFg,
          ),
          tooltip: '隨機播放',
          onPressed: onToggleShuffle,
        ),
        if (onSkipBackward15s != null)
          IconButton(
            key: const Key('btn_podcast_skip_back_15s'),
            visualDensity: density,
            padding: EdgeInsets.zero,
            constraints: btnConstraints,
            style: _transportStyle(
              foregroundColor: secondaryFg,
              hoverColor: hoverColor,
              focusColor: focusColor,
            ),
            icon: Icon(
              Icons.replay_10_rounded,
              size: compact ? 18 : 20,
            ),
            tooltip: '倒退 15 秒 (-15s)',
            onPressed: onSkipBackward15s,
          ),
        IconButton(
          key: const Key('btn_previous'),
          visualDensity: density,
          padding: EdgeInsets.zero,
          constraints: btnConstraints,
          style: _transportStyle(
            foregroundColor: primaryFg,
            hoverColor: hoverColor,
            focusColor: focusColor,
          ),
          icon: Icon(
            Icons.skip_previous_rounded,
            size: compact ? 20 : 22,
          ),
          tooltip: '上一首',
          onPressed: onPrevious,
        ),
        IconButton(
          key: const Key('btn_play_pause'),
          visualDensity: density,
          padding: EdgeInsets.zero,
          constraints: playConstraints,
          style: _transportStyle(
            foregroundColor: primaryFg,
            hoverColor: hoverColor,
            focusColor: focusColor,
          ),
          icon: isLoading
              ? SizedBox(
                  width: spinnerSize,
                  height: spinnerSize,
                  child: CircularProgressIndicator(
                    key: const Key('btn_play_pause_loading'),
                    strokeWidth: 2.2,
                    color: primaryFg,
                  ),
                )
              : Icon(
                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: compact ? 26 : 32,
                ),
          tooltip: isLoading ? '載入串流中...' : (isPlaying ? '暫停' : '播放'),
          onPressed: onPlayPause,
        ),
        IconButton(
          key: const Key('btn_next'),
          visualDensity: density,
          padding: EdgeInsets.zero,
          constraints: btnConstraints,
          style: _transportStyle(
            foregroundColor: primaryFg,
            hoverColor: hoverColor,
            focusColor: focusColor,
          ),
          icon: Icon(
            Icons.skip_next_rounded,
            size: compact ? 20 : 22,
          ),
          tooltip: '下一首',
          onPressed: onNext,
        ),
        if (onSkipForward30s != null)
          IconButton(
            key: const Key('btn_podcast_skip_forward_30s'),
            visualDensity: density,
            padding: EdgeInsets.zero,
            constraints: btnConstraints,
            style: _transportStyle(
              foregroundColor: secondaryFg,
              hoverColor: hoverColor,
              focusColor: focusColor,
            ),
            icon: Icon(
              Icons.forward_30_rounded,
              size: compact ? 18 : 20,
            ),
            tooltip: '快轉 30 秒 (+30s)',
            onPressed: onSkipForward30s,
          ),
        IconButton(
          key: const Key('btn_repeat'),
          visualDensity: density,
          padding: EdgeInsets.zero,
          constraints: btnConstraints,
          style: _transportStyle(
            foregroundColor:
                repeatMode != LuminaRepeatMode.off ? primaryFg : tertiaryFg,
            hoverColor: hoverColor,
            focusColor: focusColor,
          ),
          icon: _buildModeIndicatorIcon(
            icon: repeatMode == LuminaRepeatMode.one
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
            size: compact ? 16 : 18,
            active: repeatMode != LuminaRepeatMode.off,
            indicatorColor: primaryFg,
          ),
          tooltip: repeatTooltip,
          onPressed: onCycleRepeat,
        ),
      ],
    );

    if (trailingBadge == null) {
      return transportRow;
    }

    return _BalancedControlsRow(
      controls: transportRow,
      trailingBadge: trailingBadge!,
    );
  }
}

/// Keeps [controls] horizontally dead-center while placing [trailingBadge]
/// 6px to its right by mirroring the trailing wing width on the left whenever
/// bounded space permits.
class _BalancedControlsRow extends MultiChildRenderObjectWidget {
  _BalancedControlsRow({
    required Widget controls,
    required Widget trailingBadge,
  }) : super(children: [controls, trailingBadge]);

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBalancedControlsRow();
}

class _BalancedControlsParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderBalancedControlsRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _BalancedControlsParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _BalancedControlsParentData> {
  static const double _badgeGap = 6.0;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _BalancedControlsParentData) {
      child.parentData = _BalancedControlsParentData();
    }
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    final controls = firstChild;
    final badge = controls == null ? null : childAfter(controls);
    if (controls == null || badge == null) return 0.0;
    return controls.getMinIntrinsicWidth(height) +
        2.0 * (_badgeGap + badge.getMinIntrinsicWidth(height));
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    final controls = firstChild;
    final badge = controls == null ? null : childAfter(controls);
    if (controls == null || badge == null) return 0.0;
    return controls.getMaxIntrinsicWidth(height) +
        2.0 * (_badgeGap + badge.getMaxIntrinsicWidth(height));
  }

  @override
  double computeMinIntrinsicHeight(double width) {
    final controls = firstChild;
    final badge = controls == null ? null : childAfter(controls);
    if (controls == null || badge == null) return 0.0;
    return math.max(
      controls.getMinIntrinsicHeight(width),
      badge.getMinIntrinsicHeight(width),
    );
  }

  @override
  double computeMaxIntrinsicHeight(double width) {
    final controls = firstChild;
    final badge = controls == null ? null : childAfter(controls);
    if (controls == null || badge == null) return 0.0;
    return math.max(
      controls.getMaxIntrinsicHeight(width),
      badge.getMaxIntrinsicHeight(width),
    );
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final controls = firstChild;
    final badge = controls == null ? null : childAfter(controls);
    if (controls == null || badge == null) {
      return constraints.smallest;
    }
    final loose = constraints.loosen();
    final controlsSize = controls.getDryLayout(loose);
    final badgeSize = badge.getDryLayout(loose);
    final wingWidth = _badgeGap + badgeSize.width;
    final desiredWidth = controlsSize.width + 2.0 * wingWidth;
    final resolvedWidth = constraints.hasBoundedWidth
        ? math.min(desiredWidth, constraints.maxWidth)
        : desiredWidth;
    final resolvedHeight = math.max(controlsSize.height, badgeSize.height);
    return constraints.constrain(Size(resolvedWidth, resolvedHeight));
  }

  @override
  void performLayout() {
    final controls = firstChild;
    final badge = controls == null ? null : childAfter(controls);
    if (controls == null || badge == null) {
      size = constraints.smallest;
      return;
    }

    final loose = constraints.loosen();
    controls.layout(loose, parentUsesSize: true);
    badge.layout(loose, parentUsesSize: true);

    final wingWidth = _badgeGap + badge.size.width;
    final desiredWidth = controls.size.width + 2.0 * wingWidth;
    final resolvedWidth = constraints.hasBoundedWidth
        ? math.min(desiredWidth, constraints.maxWidth)
        : desiredWidth;
    final resolvedHeight = math.max(controls.size.height, badge.size.height);
    size = constraints.constrain(Size(resolvedWidth, resolvedHeight));

    final idealControlsX = (size.width - controls.size.width) / 2.0;
    final maxControlsX = math.max(
      0.0,
      size.width - controls.size.width - wingWidth,
    );
    final controlsX = math
        .min(idealControlsX, maxControlsX)
        .clamp(0.0, math.max(0.0, size.width - controls.size.width))
        .toDouble();
    final controlsY = (size.height - controls.size.height) / 2.0;
    final badgeX = controlsX + controls.size.width + _badgeGap;
    final badgeY = (size.height - badge.size.height) / 2.0;

    (controls.parentData as _BalancedControlsParentData).offset = Offset(
      controlsX,
      controlsY,
    );
    (badge.parentData as _BalancedControlsParentData).offset = Offset(
      badgeX,
      badgeY,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }
}
