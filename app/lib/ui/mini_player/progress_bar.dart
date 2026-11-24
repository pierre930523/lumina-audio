import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:material_ui/material_ui.dart';
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
    final progressRatio = (currentMs / maxMs).clamp(0.0, 1.0);

    final sliderWidget = ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 60),
      child: SizedBox(
        height: widget.showWaveform ? 22 : 18,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (widget.showWaveform)
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: CustomPaint(
                    painter: _WaveformProgressPainter(progress: progressRatio),
                  ),
                ),
              ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: widget.showWaveform ? 0.5 : 3,
                thumbShape: RoundSliderThumbShape(
                  enabledThumbRadius: _isDragging ? 6.0 : 4.0,
                ),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                overlayColor: LuminaTokens.focusRing.withValues(alpha: 0.22),
                activeTrackColor: widget.showWaveform
                    ? Colors.transparent
                    : LuminaTokens.accentPurple,
                inactiveTrackColor: widget.showWaveform
                    ? Colors.transparent
                    : LuminaTokens.borderControl.withValues(alpha: 0.45),
                thumbColor: _isDragging
                    ? LuminaTokens.accentBlue
                    : LuminaTokens.textPrimary,
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
          ],
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
            color: _isDragging
                ? LuminaTokens.focusRing
                : LuminaTokens.textSecondary,
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
              hoverColor: LuminaTokens.cardHoverBg.withValues(alpha: 0.65),
              focusColor: LuminaTokens.focusRing.withValues(alpha: 0.25),
              onTap: _toggleRemaining,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                child: Text(
                  _showRemaining
                      ? '-${TrackProgressBar.formatDuration(remainingDuration)}'
                      : TrackProgressBar.formatDuration(widget.duration),
                  key: const Key('progress_duration_text'),
                  style: TextStyle(
                    color: _showRemaining
                        ? LuminaTokens.accentBlue
                        : LuminaTokens.textMuted,
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

class _WaveformProgressPainter extends CustomPainter {
  final double progress;

  const _WaveformProgressPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    const barWidth = 1.5;
    const barGap = 1.6;
    const step = barWidth + barGap;
    final count = (size.width / step).floor().clamp(8, 280);
    final midY = size.height / 2;

    final unplayedPaint = Paint()
      ..color = LuminaTokens.borderControl.withValues(alpha: 0.58)
      ..strokeWidth = barWidth
      ..strokeCap = StrokeCap.round;

    final playedPaint = Paint()
      ..strokeWidth = barWidth
      ..strokeCap = StrokeCap.round;

    for (var i = 0; i < count; i++) {
      final norm = i / count;
      final amp = 0.16 +
          0.82 *
              (0.45 +
                  0.32 * math.sin(i * 0.37) +
                  0.23 * math.cos(i * 1.19))
                  .clamp(0.0, 1.0);
      final halfH = (size.height * 0.48) * amp;
      final x = i * step + barWidth / 2;
      if (norm <= progress) {
        final nearPlayhead = ((progress - norm) < 0.04)
            ? (1.0 - (progress - norm) / 0.04)
            : 0.0;
        playedPaint.color = Color.lerp(
          LuminaTokens.accentBlueStrong,
          const Color(0xFFEC5B7E),
          nearPlayhead,
        )!;
        canvas.drawLine(Offset(x, midY - halfH), Offset(x, midY + halfH), playedPaint);
      } else {
        canvas.drawLine(Offset(x, midY - halfH), Offset(x, midY + halfH), unplayedPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformProgressPainter oldDelegate) =>
      (oldDelegate.progress - progress).abs() > 0.002;
}
