import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../services/audio_service.dart';
import '../../services/playback_persistence_service.dart';
import '../../services/recommendation_settings_controller.dart';
import '../../services/streaming/autoplay_controller.dart';
import '../common/frosted_glass_container.dart';
import '../common/track_context_menu.dart';
import '../common/track_hover_prefetch.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';

part 'quick_queue_legacy_popover.dart';
part 'quick_queue_dual_popover.dart';
part 'quick_queue_track_row.dart';

class _QueueDragPayload {
  final TrackInfo track;
  final int combinedIndex;
  final bool isAuto;

  const _QueueDragPayload({
    required this.track,
    required this.combinedIndex,
    required this.isAuto,
  });
}

enum _QuickQueueEntryKind {
  userHeader,
  userEmptyPlaceholder,
  userTrack,
  autoHeader,
  autoEmptyHint,
  autoTrack,
}

class _QuickQueueEntry {
  final _QuickQueueEntryKind kind;
  final TrackInfo? track;
  final int combinedIndex;
  final bool isLockedPlayingAuto;

  const _QuickQueueEntry({
    required this.kind,
    this.track,
    this.combinedIndex = -1,
    this.isLockedPlayingAuto = false,
  });
}

class QuickQueuePopover extends StatelessWidget {
  final AudioService audioService;
  final VoidCallback onClose;
  final VoidCallback? onOpenLibrary;
  final double? maxWidth;
  final double? maxHeight;
  final RecommendationSettingsController? recommendationSettings;

  const QuickQueuePopover({
    super.key,
    required this.audioService,
    required this.onClose,
    this.onOpenLibrary,
    this.maxWidth,
    this.maxHeight,
    this.recommendationSettings,
  });

  AutoplayController? get _autoplayController =>
      audioService.autoplayController;

  void _toggleAutoplay(AutoplayController ap, bool currentlyEnabled) {
    final next = !currentlyEnabled;
    ap.setEnabled(next);
    final rec = recommendationSettings;
    if (rec != null && rec.autoplayEnabled != next) {
      unawaited(rec.setAutoplayEnabled(next));
    }
  }

  @override
  Widget build(BuildContext context) {
    final resolvedMaxWidth = maxWidth != null
        ? math.min(324.0, maxWidth!)
        : 324.0;

    final onPrefetch =
        TrackPrefetchScope.maybeOf(context) ?? audioService.hoverPrefetchCallback;

    final ap = _autoplayController;
    if (ap == null) {
      return _buildLegacyPopover(
        resolvedMaxWidth: resolvedMaxWidth,
        onPrefetch: onPrefetch,
      );
    }

    Widget buildStreamContent() {
      return StreamBuilder<PlaybackState>(
        stream: audioService.stateStream,
        initialData: audioService.currentState,
        builder: (context, snapshot) {
          final state = snapshot.data ?? audioService.currentState;
          return StreamBuilder<void>(
            stream: ap.changes,
            builder: (context, _) => _buildDualQueuePopover(
              resolvedMaxWidth: resolvedMaxWidth,
              state: state,
              ap: ap,
              onPrefetch: onPrefetch,
            ),
          );
        },
      );
    }

    if (recommendationSettings != null) {
      return ListenableBuilder(
        listenable: recommendationSettings!,
        builder: (context, _) => buildStreamContent(),
      );
    }

    return buildStreamContent();
  }

  static bool _isCurrentTrack(TrackInfo? active, TrackInfo item) {
    if (active == null) return false;
    if (item.id == active.id) return true;
    if (item.id.trim().isNotEmpty && active.id.trim().isNotEmpty) {
      return item.responsiveArtworkKey == active.responsiveArtworkKey;
    }
    return false;
  }

  static int countLegacyUpcoming(List<TrackInfo> tracks, TrackInfo? active) {
    if (tracks.isEmpty) return 0;
    if (active == null) return tracks.length;
    final activeIdx = PlaybackPersistenceService.findTrackIndex(tracks, active);
    final keepCount = activeIdx >= 0 ? activeIdx + 1 : 0;
    return tracks.length - keepCount;
  }

  Widget _buildClearUpcomingButton(
    BuildContext context, {
    required int upcomingCount,
    Key? buttonKey,
  }) {
    final enabled = upcomingCount > 0;
    final messenger = ScaffoldMessenger.maybeOf(context);
    return Tooltip(
      message: enabled ? '清除所有即將播放的歌曲' : '目前無即將播放的歌曲',
      child: Semantics(
        button: true,
        enabled: enabled,
        label: '清除即將播放',
        child: TextButton(
          key: buttonKey,
          onPressed: enabled
              ? () async {
                  final cleared = await audioService.clearUpcomingQueue();
                  messenger?.showSnackBar(
                    SnackBar(
                      content: Text('已清除 $cleared 首即將播放的歌曲'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              : null,
          style: TextButton.styleFrom(
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            foregroundColor: LuminaTokens.glassTextSecondary,
            disabledForegroundColor: LuminaTokens.textMuted.withValues(
              alpha: 0.45,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.playlist_remove_rounded, size: 14),
              SizedBox(width: 3),
              Text(
                '清除即將播放',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOpenLibraryButton() {
    return Semantics(
      button: true,
      label: '開啟完整曲庫',
      child: InkWell(
        key: const Key('btn_queue_open_library'),
        borderRadius: BorderRadius.circular(6),
        mouseCursor: SystemMouseCursors.click,
        hoverColor: LuminaTokens.glassRowHoverBg,
        focusColor: LuminaTokens.focusRing.withValues(alpha: 0.25),
        onTap: () {
          onClose();
          onOpenLibrary!();
        },
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Text(
            '完整曲庫 >',
            style: TextStyle(
              color: LuminaTokens.glassTextPrimary,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _GlideScrollHost extends StatefulWidget {
  final Widget Function(BuildContext context, GlideScrollController controller)
  builder;

  const _GlideScrollHost({required this.builder});

  @override
  State<_GlideScrollHost> createState() => _GlideScrollHostState();
}

class _GlideScrollHostState extends State<_GlideScrollHost> {
  final GlideScrollController _controller = GlideScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SmoothScrollWrapper(
      controller: _controller,
      child: widget.builder(context, _controller),
    );
  }
}
