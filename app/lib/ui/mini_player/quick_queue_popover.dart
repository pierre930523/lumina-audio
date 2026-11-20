import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../services/audio_service.dart';
import '../theme/lumina_tokens.dart';

class QuickQueuePopover extends StatelessWidget {
  final AudioService audioService;
  final VoidCallback onClose;
  final VoidCallback? onOpenLibrary;
  final double? maxWidth;
  final double? maxHeight;

  const QuickQueuePopover({
    super.key,
    required this.audioService,
    required this.onClose,
    this.onOpenLibrary,
    this.maxWidth,
    this.maxHeight,
  });

  @override
  Widget build(BuildContext context) {
    final resolvedMaxWidth = maxWidth != null
        ? math.min(308.0, maxWidth!)
        : 308.0;
    final listMaxHeight = maxHeight != null
        ? math.min(260.0, math.max(56.0, maxHeight! - 48.0))
        : 260.0;
    final listMinHeight = (maxHeight == null || maxHeight! >= 160.0) ? 88.0 : 0.0;

    return StreamBuilder<PlaybackState>(
      stream: audioService.stateStream,
      initialData: audioService.currentState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? audioService.currentState;
        final activeId = state.track?.id;
        final tracks = audioService.queue;
        final boundedListHeight = math.min(
          listMaxHeight,
          math.max(listMinHeight, tracks.length * 56.0 + 12.0),
        );

        return Material(
          color: Colors.transparent,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: resolvedMaxWidth,
              maxHeight: maxHeight ?? double.infinity,
            ),
            child: Container(
              key: const Key('quick_queue_popover'),
              width: resolvedMaxWidth,
              decoration: BoxDecoration(
                color: LuminaTokens.cardElevatedBg,
                borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
                border: Border.all(
                  color: LuminaTokens.borderControl.withValues(alpha: 0.7),
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0xAA000000),
                    blurRadius: 28,
                    offset: Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      LuminaTokens.spaceMd,
                      LuminaTokens.spaceSm,
                      10,
                      LuminaTokens.spaceXs,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            '播放佇列（${tracks.length} 首）',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: LuminaTokens.textSecondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (onOpenLibrary != null)
                          Semantics(
                            button: true,
                            label: '開啟完整曲庫',
                            child: InkWell(
                              key: const Key('btn_queue_open_library'),
                              borderRadius: BorderRadius.circular(6),
                              mouseCursor: SystemMouseCursors.click,
                              hoverColor: LuminaTokens.cardHoverBg,
                              focusColor: LuminaTokens.focusRing.withValues(
                                alpha: 0.25,
                              ),
                              onTap: () {
                                onClose();
                                onOpenLibrary!();
                              },
                              child: const Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 4,
                                ),
                                child: Text(
                                  '完整曲庫 >',
                                  style: TextStyle(
                                    color: LuminaTokens.accentBlue,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Divider(color: LuminaTokens.borderSubtle, height: 1),
                  Flexible(
                    child: tracks.isEmpty
                        ? ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight: listMinHeight,
                              maxHeight: listMaxHeight,
                            ),
                            child: const Padding(
                              padding: EdgeInsets.all(LuminaTokens.spaceLg),
                              child: Text(
                                '目前待播佇列為空',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: LuminaTokens.textMuted,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          )
                        : SizedBox(
                            height: boundedListHeight,
                            child: ListView.builder(
                              key: const PageStorageKey<String>(
                                'quick_queue_list_scroll',
                              ),
                              padding: const EdgeInsets.symmetric(
                                vertical: LuminaTokens.space2xs,
                              ),
                              itemCount: tracks.length,
                              itemBuilder: (context, index) {
                                final track = tracks[index];
                                final isCurrent = track.id == activeId;
                                return InkWell(
                                  key: Key('quick_queue_item_${track.id}'),
                                  onTap: () => audioService.play(track: track),
                                  mouseCursor: SystemMouseCursors.click,
                                  hoverColor: LuminaTokens.cardHoverBg.withValues(
                                    alpha: 0.72,
                                  ),
                                  focusColor: LuminaTokens.focusRing.withValues(
                                    alpha: 0.22,
                                  ),
                                  child: Container(
                                    color: isCurrent
                                        ? LuminaTokens.accentBlueStrong
                                            .withValues(alpha: 0.14)
                                        : Colors.transparent,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 9,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          isCurrent
                                              ? Icons.equalizer_rounded
                                              : Icons.music_note_outlined,
                                          size: 16,
                                          color: isCurrent
                                              ? LuminaTokens.accentBlue
                                              : LuminaTokens.textMuted,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                track.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: isCurrent
                                                      ? LuminaTokens.accentBlue
                                                      : LuminaTokens.textPrimary,
                                                  fontSize: 13,
                                                  fontWeight: isCurrent
                                                      ? FontWeight.w600
                                                      : FontWeight.w400,
                                                ),
                                              ),
                                              Text(
                                                '${track.artist} • ${track.format.label}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: LuminaTokens.textMuted,
                                                  fontSize: 11,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
