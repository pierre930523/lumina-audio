import 'dart:async';
import 'dart:ui' as ui;
import 'package:material_ui/material_ui.dart';
import '../theme/lumina_glass_theme.dart';
import '../theme/lumina_tokens.dart';

class TrackProgressBar extends StatefulWidget {
  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;
  final bool expand;
  final bool showWaveform;
  final Duration seekThrottleInterval;
  final bool enableLiveDragSeek;
  final ValueChanged<Duration>? onChangeStart;
  final ValueChanged<Duration>? onChanged;
  final ValueChanged<Duration>? onChangeEnd;

  const TrackProgressBar({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
    this.expand = false,
    this.showWaveform = true,
    this.seekThrottleInterval = const Duration(milliseconds: 100),
    this.enableLiveDragSeek = true,
    this.onChangeStart,
    this.onChanged,
    this.onChangeEnd,
  });

  static String formatDuration(Duration d) {
    final totalSecs = d.inSeconds;
    final mins = (totalSecs ~/ 60).toString().padLeft(2, '0');
    final secs = (totalSecs % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  @override
  State<TrackProgressBar> createState() => _TrackProgressBarState();
}

class _TrackProgressBarState extends State<TrackProgressBar> {
  bool _isHovered = false;
  bool _isDragging = false;
  Duration? _dragPosition;
  bool _showRemaining = false;
  Timer? _seekThrottleTimer;
  Duration? _pendingDragSeek;
  Duration? _lastDispatchedDragSeek;

  void _cancelSeekThrottleTimer() {
    _seekThrottleTimer?.cancel();
    _seekThrottleTimer = null;
  }

  void _flushThrottledDragSeek() {
    _seekThrottleTimer = null;
    if (!mounted || !_isDragging) return;
    final target = _pendingDragSeek;
    _pendingDragSeek = null;
    if (target == null || target == _lastDispatchedDragSeek) return;
    _lastDispatchedDragSeek = target;
    widget.onSeek(target);
  }

  void _handleDragStart(double value) {
    final pos = Duration(milliseconds: value.round());
    _cancelSeekThrottleTimer();
    _pendingDragSeek = null;
    _lastDispatchedDragSeek = null;
    setState(() {
      _isDragging = true;
      _dragPosition = pos;
    });
    widget.onChangeStart?.call(pos);
  }

  void _handleDragChange(double value) {
    final pos = Duration(milliseconds: value.round());
    setState(() {
      _dragPosition = pos;
    });
    widget.onChanged?.call(pos);

    if (widget.enableLiveDragSeek) {
      _pendingDragSeek = pos;
      if (_seekThrottleTimer == null) {
        if (widget.seekThrottleInterval <= Duration.zero) {
          _flushThrottledDragSeek();
        } else {
          _seekThrottleTimer = Timer(
            widget.seekThrottleInterval,
            _flushThrottledDragSeek,
          );
        }
      }
    }
  }

  void _handleDragEnd(double value) {
    final pos = Duration(milliseconds: value.round());
    _cancelSeekThrottleTimer();
    _pendingDragSeek = null;
    final lastDispatched = _lastDispatchedDragSeek;
    _lastDispatchedDragSeek = null;
    setState(() {
      _isDragging = false;
      _dragPosition = null;
    });
    widget.onChangeEnd?.call(pos);
    if (lastDispatched != pos) {
      widget.onSeek(pos);
    }
  }

  @override
  void didUpdateWidget(covariant TrackProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enableLiveDragSeek && _seekThrottleTimer != null) {
      _cancelSeekThrottleTimer();
      _pendingDragSeek = null;
    }
  }

  @override
  void dispose() {
    _cancelSeekThrottleTimer();
    super.dispose();
  }

  void _toggleRemaining() {
    setState(() {
      _showRemaining = !_showRemaining;
    });
  }

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);
    final isDark = glass.isDark;
    final activeColor =
        isDark ? LuminaTokens.glassTextPrimary : glass.textPrimary;
    final inactiveColor = isDark
        ? LuminaTokens.glassTrackUnplayed
        : glass.textPrimary.withValues(alpha: 0.22);
    final secondaryColor =
        isDark ? LuminaTokens.glassTextSecondary : glass.textSecondary;
    final tertiaryColor =
        isDark ? LuminaTokens.glassTextTertiary : glass.textTertiary;
    final glowColor = isDark ? Colors.white : glass.accent;
    final hoverBg = isDark ? LuminaTokens.glassRowHoverBg : glass.pillBg;
    final focusColor = isDark ? LuminaTokens.focusRing : glass.accent;

    final maxMs = widget.duration.inMilliseconds > 0
        ? widget.duration.inMilliseconds.toDouble()
        : 1.0;

    // Guard against feedback seek loops while progress updates are streaming:
    // When the user is dragging, strictly use _dragPosition to prevent thumb snapping.
    final displayPosition = _isDragging && _dragPosition != null
        ? _dragPosition!
        : widget.position;

    final currentMs = displayPosition.inMilliseconds
        .toDouble()
        .clamp(0.0, maxMs);
    final isActive = _isHovered || _isDragging;

    final sliderWidget = MouseRegion(
      onEnter: (_) {
        if (!_isHovered) setState(() => _isHovered = true);
      },
      onExit: (_) {
        if (_isHovered) setState(() => _isHovered = false);
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 60),
        child: SizedBox(
          height: 16,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: isActive ? 3.0 : 2.5,
              thumbShape: _GlowingDotThumbShape(
                radius: isActive ? 5.5 : 3.5,
                isActive: isActive,
                dotColor: activeColor,
                glowColor: glowColor,
              ),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 8),
              overlayColor: activeColor.withValues(alpha: 0.14),
              activeTrackColor: activeColor,
              inactiveTrackColor: inactiveColor,
              thumbColor: activeColor,
            ),
            child: Semantics(
              label: '播放進度條',
              slider: true,
              child: Slider(
                key: const Key('track_progress_slider'),
                value: currentMs,
                min: 0.0,
                max: maxMs,
                mouseCursor: SystemMouseCursors.click,
                onChangeStart: _handleDragStart,
                onChanged: _handleDragChange,
                onChangeEnd: _handleDragEnd,
              ),
            ),
          ),
        ),
      ),
    );

    // Remaining duration calculation
    final remainingDuration = widget.duration > displayPosition
        ? widget.duration - displayPosition
        : Duration.zero;

    return Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      children: [
        Text(
          TrackProgressBar.formatDuration(displayPosition),
          key: const Key('progress_position_text'),
          style: TextStyle(
            color: _isDragging ? activeColor : tertiaryColor,
            fontSize: 11,
            fontWeight: _isDragging ? FontWeight.w600 : FontWeight.normal,
            fontFeatures: const [ui.FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 6),
        if (widget.expand)
          Expanded(child: sliderWidget)
        else
          SizedBox(width: 140, child: sliderWidget),
        const SizedBox(width: 6),
        Tooltip(
          message: _showRemaining ? '點擊顯示總時長' : '點擊顯示剩餘時間',
          child: Semantics(
            button: true,
            label: _showRemaining ? '顯示總時長' : '顯示剩餘時間',
            child: InkWell(
              borderRadius: BorderRadius.circular(LuminaTokens.space2xs),
              mouseCursor: SystemMouseCursors.click,
              hoverColor: hoverBg,
              focusColor: focusColor.withValues(alpha: 0.25),
              onTap: _toggleRemaining,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                child: Text(
                  _showRemaining
                      ? '-${TrackProgressBar.formatDuration(remainingDuration)}'
                      : TrackProgressBar.formatDuration(widget.duration),
                  key: const Key('progress_duration_text'),
                  style: TextStyle(
                    color: _showRemaining ? secondaryColor : tertiaryColor,
                    fontSize: 11,
                    fontFeatures: const [ui.FontFeature.tabularFigures()],
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

class _GlowingDotThumbShape extends SliderComponentShape {
  final double radius;
  final bool isActive;
  final Color dotColor;
  final Color glowColor;

  const _GlowingDotThumbShape({
    required this.radius,
    required this.isActive,
    required this.dotColor,
    required this.glowColor,
  });

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      Size.fromRadius(radius);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final glowPaint = Paint()
      ..color = glowColor.withValues(alpha: isActive ? 0.42 : 0.20)
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        isActive ? 5.0 : 2.5,
      );
    canvas.drawCircle(center, radius + (isActive ? 2.0 : 1.0), glowPaint);

    final dotPaint = Paint()
      ..color = dotColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, dotPaint);
  }
}
