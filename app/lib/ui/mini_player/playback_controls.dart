import 'package:material_ui/material_ui.dart';
import '../../models/playback_state.dart';
import '../theme/lumina_tokens.dart';

class PlaybackControls extends StatelessWidget {
  final PlaybackStatus status;
  final VoidCallback onPrevious;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final bool compact;

  const PlaybackControls({
    super.key,
    required this.status,
    required this.onPrevious,
    required this.onPlayPause,
    required this.onNext,
    this.compact = false,
  });

  ButtonStyle _transportStyle({required bool isPrimary}) {
    return IconButton.styleFrom(
      foregroundColor: isPrimary
          ? LuminaTokens.textPrimary
          : LuminaTokens.textSecondary,
      hoverColor: LuminaTokens.cardHoverBg.withValues(alpha: 0.72),
      focusColor: LuminaTokens.focusRing.withValues(alpha: 0.25),
      shape: const CircleBorder(),
    ).copyWith(
      mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.click),
      side: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? const BorderSide(color: LuminaTokens.focusRing, width: 1.5)
            : BorderSide.none,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isPlaying = status == PlaybackStatus.playing;
    final isLoading =
        status == PlaybackStatus.loading || status == PlaybackStatus.buffering;
    final density = compact ? VisualDensity.compact : VisualDensity.standard;
    final padding = compact ? const EdgeInsets.all(4) : const EdgeInsets.all(8);
    final btnConstraints = compact
        ? const BoxConstraints(minWidth: 36, minHeight: 36)
        : const BoxConstraints(minWidth: 40, minHeight: 40);
    final spinnerSize = compact ? 20.0 : 24.0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          key: const Key('btn_previous'),
          visualDensity: density,
          padding: padding,
          constraints: btnConstraints,
          style: _transportStyle(isPrimary: false),
          icon: Icon(
            Icons.skip_previous_rounded,
            size: compact ? 22 : 24,
          ),
          tooltip: '上一首',
          onPressed: onPrevious,
        ),
        IconButton(
          key: const Key('btn_play_pause'),
          visualDensity: density,
          padding: padding,
          constraints: compact
              ? const BoxConstraints(minWidth: 40, minHeight: 40)
              : const BoxConstraints(minWidth: 44, minHeight: 44),
          style: _transportStyle(isPrimary: true),
          icon: isLoading
              ? SizedBox(
                  width: spinnerSize,
                  height: spinnerSize,
                  child: const CircularProgressIndicator(
                    key: Key('btn_play_pause_loading'),
                    strokeWidth: 2.2,
                    color: LuminaTokens.accentBlue,
                  ),
                )
              : Icon(
                  isPlaying
                      ? Icons.pause_circle_filled_rounded
                      : Icons.play_circle_fill_rounded,
                  size: compact ? 30 : 34,
                ),
          tooltip: isLoading ? '載入串流中...' : (isPlaying ? '暫停' : '播放'),
          onPressed: onPlayPause,
        ),
        IconButton(
          key: const Key('btn_next'),
          visualDensity: density,
          padding: padding,
          constraints: btnConstraints,
          style: _transportStyle(isPrimary: false),
          icon: Icon(
            Icons.skip_next_rounded,
            size: compact ? 22 : 24,
          ),
          tooltip: '下一首',
          onPressed: onNext,
        ),
      ],
    );
  }
}
