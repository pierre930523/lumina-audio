import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../services/audio_service.dart';
import '../../services/recommendation_settings_controller.dart';
import '../../services/streaming/autoplay_controller.dart';
import '../../services/streaming/streaming_playback_coordinator.dart';
import '../common/frosted_glass_container.dart';
import '../common/track_hover_prefetch.dart';
import '../theme/lumina_tokens.dart';

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
      audioService is CoordinatingAudioService
          ? (audioService as CoordinatingAudioService).autoplayController
          : null;

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
        ? math.min(308.0, maxWidth!)
        : 308.0;

    final onPrefetch =
        TrackPrefetchScope.maybeOf(context) ??
        (audioService is CoordinatingAudioService
            ? (audioService as CoordinatingAudioService)
                  .coordinator
                  .requestHoverPrefetch
            : null);

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

  Widget _buildLegacyPopover({
    required double resolvedMaxWidth,
    required TrackPrefetchCallback? onPrefetch,
  }) {
    final listMaxHeight = maxHeight != null
        ? math.min(260.0, math.max(56.0, maxHeight! - 48.0))
        : 260.0;
    final listMinHeight = (maxHeight == null || maxHeight! >= 160.0) ? 88.0 : 0.0;

    Widget buildBody(PlaybackState state, List<TrackInfo> tracks) {
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
            child: FrostedGlassContainer(
              key: const Key('quick_queue_popover'),
              width: resolvedMaxWidth,
              blurSigma: LuminaTokens.glassDialogBlur,
              color: LuminaTokens.glassDialogBg,
              borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
              border: Border.all(color: LuminaTokens.glassCardBorder),
              boxShadow: const [
                BoxShadow(
                  color: Color(0xAA000000),
                  blurRadius: 28,
                  offset: Offset(0, 12),
                ),
              ],
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
                        if (onOpenLibrary != null) _buildOpenLibraryButton(),
                      ],
                    ),
                  ),
                  const Divider(color: LuminaTokens.glassCardDivider, height: 1),
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
                                final isCurrent =
                                    _isCurrentTrack(state.track, track);
                                return TrackHoverPrefetch(
                                  track: track,
                                  onPrefetch: onPrefetch,
                                  child: InkWell(
                                    key: Key('quick_queue_item_${track.id}'),
                                    onTap: () => audioService.play(track: track),
                                    mouseCursor: SystemMouseCursors.click,
                                    hoverColor: LuminaTokens.glassRowHoverBg,
                                    focusColor: LuminaTokens.focusRing.withValues(
                                      alpha: 0.22,
                                    ),
                                    child: Container(
                                      color: isCurrent
                                          ? LuminaTokens.glassNavActiveBg
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
                                                ? Colors.white
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
                                                        ? Colors.white
                                                        : LuminaTokens
                                                              .glassTextPrimary,
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
    }

    return StreamBuilder<PlaybackState>(
      stream: audioService.stateStream,
      initialData: audioService.currentState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? audioService.currentState;
        if (audioService is CoordinatingAudioService) {
          final coord = audioService as CoordinatingAudioService;
          return StreamBuilder<List<TrackInfo>>(
            stream: coord.queueUpdatedStream,
            initialData: audioService.queue,
            builder: (context, qSnap) =>
                buildBody(state, qSnap.data ?? audioService.queue),
          );
        }
        return buildBody(state, audioService.queue);
      },
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

  Widget _buildDualQueuePopover({
    required double resolvedMaxWidth,
    required PlaybackState state,
    required AutoplayController ap,
    required TrackPrefetchCallback? onPrefetch,
  }) {
    final combined = ap.combinedQueue;
    final autoTracks = ap.autoQueue;
    final useLegacyFallback = combined.isEmpty && audioService.queue.isNotEmpty;
    final userTracks = useLegacyFallback
        ? audioService.queue
        : combined.sublist(0, combined.length - autoTracks.length);
    final totalCount = userTracks.length + autoTracks.length;
    final showAutoSection = ap.enabled || autoTracks.isNotEmpty;

    final listMaxHeight = maxHeight != null
        ? math.max(0.0, math.min(356.0, maxHeight! - 48.0))
        : 340.0;
    final rawMinHeight = (maxHeight == null || maxHeight! >= 160.0) ? 96.0 : 0.0;
    final listMinHeight = math.min(listMaxHeight, rawMinHeight);

    final estimatedHeight =
        32.0 +
        math.max(1, userTracks.length) * 54.0 +
        (showAutoSection
            ? (34.0 + math.max(1, autoTracks.length) * 54.0)
            : 0.0) +
        16.0;
    final boundedListHeight = math.min(
      listMaxHeight,
      math.max(listMinHeight, estimatedHeight),
    );

    final entries = <_QuickQueueEntry>[
      const _QuickQueueEntry(kind: _QuickQueueEntryKind.userHeader),
      if (userTracks.isEmpty)
        const _QuickQueueEntry(kind: _QuickQueueEntryKind.userEmptyPlaceholder)
      else
        for (var i = 0; i < userTracks.length; i++)
          _QuickQueueEntry(
            kind: _QuickQueueEntryKind.userTrack,
            track: userTracks[i],
            combinedIndex: i,
            isLockedPlayingAuto:
                !useLegacyFallback &&
                ap.isCurrentFromAutoQueue &&
                ap.currentTrack?.id == userTracks[i].id,
          ),
      if (showAutoSection) ...[
        const _QuickQueueEntry(kind: _QuickQueueEntryKind.autoHeader),
        if (autoTracks.isEmpty)
          const _QuickQueueEntry(kind: _QuickQueueEntryKind.autoEmptyHint)
        else
          for (var j = 0; j < autoTracks.length; j++)
            _QuickQueueEntry(
              kind: _QuickQueueEntryKind.autoTrack,
              track: autoTracks[j],
              combinedIndex: userTracks.length + j,
            ),
      ],
    ];

    void ensureSeededBeforeReorder() {
      if (useLegacyFallback) {
        ap.setUserQueue(
          userTracks,
          currentTrack: state.track,
          bumpEpoch: false,
        );
      }
    }

    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: resolvedMaxWidth,
          maxHeight: maxHeight ?? double.infinity,
        ),
        child: FrostedGlassContainer(
          key: const Key('quick_queue_popover'),
          width: resolvedMaxWidth,
          blurSigma: LuminaTokens.glassDialogBlur,
          color: LuminaTokens.glassDialogBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
          border: Border.all(color: LuminaTokens.glassCardBorder),
          boxShadow: const [
            BoxShadow(
              color: Color(0xAA000000),
              blurRadius: 28,
              offset: Offset(0, 12),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  LuminaTokens.spaceMd,
                  LuminaTokens.spaceSm,
                  8,
                  LuminaTokens.spaceXs,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '播放佇列（$totalCount 首）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.textSecondary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Tooltip(
                      message: '無限自動接播（開啟／關閉）',
                      child: Semantics(
                        button: true,
                        toggled: ap.enabled,
                        label: '無限自動接播（開啟／關閉）',
                        child: InkWell(
                          key: const Key('btn_queue_autoplay_toggle'),
                          borderRadius: BorderRadius.circular(6),
                          mouseCursor: SystemMouseCursors.click,
                          hoverColor: LuminaTokens.glassRowHoverBg,
                          focusColor: LuminaTokens.focusRing.withValues(
                            alpha: 0.25,
                          ),
                          onTap: () => _toggleAutoplay(ap, ap.enabled),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: ap.enabled
                                  ? LuminaTokens.glassNavActiveBg
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: ap.enabled
                                    ? LuminaTokens.glassPillBorder
                                    : Colors.transparent,
                              ),
                            ),
                            child: Icon(
                              Icons.all_inclusive_rounded,
                              size: 15,
                              color: ap.enabled
                                  ? LuminaTokens.glassTextPrimary
                                  : LuminaTokens.glassTextTertiary,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (onOpenLibrary != null) ...[
                      const SizedBox(width: 4),
                      _buildOpenLibraryButton(),
                    ],
                  ],
                ),
              ),
              const Divider(color: LuminaTokens.glassCardDivider, height: 1),
              Flexible(
                child: totalCount == 0 && !showAutoSection
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
                          itemCount: entries.length,
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            return switch (entry.kind) {
                              _QuickQueueEntryKind.userHeader =>
                                _buildUserSectionHeader(
                                  ap: ap,
                                  userCount: userTracks.length,
                                  ensureSeededBeforeReorder:
                                      ensureSeededBeforeReorder,
                                ),
                              _QuickQueueEntryKind.userEmptyPlaceholder =>
                                _buildUserEmptyDropZone(ap: ap),
                              _QuickQueueEntryKind.userTrack =>
                                _buildTrackRow(
                                  resolvedMaxWidth: resolvedMaxWidth,
                                  track: entry.track!,
                                  combinedIndex: entry.combinedIndex,
                                  isCurrent:
                                      _isCurrentTrack(state.track, entry.track!),
                                  isAuto: false,
                                  isLockedPlayingAuto:
                                      entry.isLockedPlayingAuto,
                                  ap: ap,
                                  onPrefetch: onPrefetch,
                                  ensureSeededBeforeReorder:
                                      ensureSeededBeforeReorder,
                                ),
                              _QuickQueueEntryKind.autoHeader =>
                                _buildAutoSectionHeader(ap: ap),
                              _QuickQueueEntryKind.autoEmptyHint => Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                child: Text(
                                  ap.isRefilling
                                      ? '正在探索相似推薦曲目...'
                                      : '待播佇列即將播畢時將自動接續推薦',
                                  style: const TextStyle(
                                    color: LuminaTokens.textMuted,
                                    fontSize: 11.5,
                                  ),
                                ),
                              ),
                              _QuickQueueEntryKind.autoTrack => _buildTrackRow(
                                resolvedMaxWidth: resolvedMaxWidth,
                                track: entry.track!,
                                combinedIndex: entry.combinedIndex,
                                isCurrent:
                                    _isCurrentTrack(state.track, entry.track!),
                                isAuto: true,
                                isLockedPlayingAuto: false,
                                ap: ap,
                                onPrefetch: onPrefetch,
                                ensureSeededBeforeReorder:
                                    ensureSeededBeforeReorder,
                              ),
                            };
                          },
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUserSectionHeader({
    required AutoplayController ap,
    required int userCount,
    required VoidCallback ensureSeededBeforeReorder,
  }) {
    return DragTarget<_QueueDragPayload>(
      onWillAcceptWithDetails: (details) => details.data.isAuto,
      onAcceptWithDetails: (details) {
        ensureSeededBeforeReorder();
        ap.promoteAutoTrackToUserQueue(
          details.data.track.id,
          targetUserIndex: 0,
        );
      },
      builder: (context, candidateData, rejectedData) {
        final isHovered = candidateData.isNotEmpty;
        return Container(
          color: isHovered
              ? LuminaTokens.glassNavActiveBg.withValues(alpha: 0.45)
              : Colors.transparent,
          padding: const EdgeInsets.fromLTRB(14, 8, 12, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  '待播佇列',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: LuminaTokens.glassTextSecondary,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              Text(
                '$userCount 首',
                style: const TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildUserEmptyDropZone({required AutoplayController ap}) {
    return DragTarget<_QueueDragPayload>(
      onWillAcceptWithDetails: (details) => details.data.isAuto,
      onAcceptWithDetails: (details) {
        ap.promoteAutoTrackToUserQueue(details.data.track.id);
      },
      builder: (context, candidateData, rejectedData) {
        final isHovered = candidateData.isNotEmpty;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          decoration: BoxDecoration(
            color: isHovered
                ? LuminaTokens.glassNavActiveBg.withValues(alpha: 0.5)
                : LuminaTokens.glassCardBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isHovered
                  ? LuminaTokens.focusRing
                  : LuminaTokens.glassCardBorder,
            ),
          ),
          child: const Text(
            '目前無手動待播曲目，可拖曳推薦曲目至此',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: LuminaTokens.textMuted,
              fontSize: 11.5,
            ),
          ),
        );
      },
    );
  }

  Widget _buildAutoSectionHeader({required AutoplayController ap}) {
    final hasAutoTracks = ap.autoQueue.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 4),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              '接下來自動推薦（Autoplay）',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: LuminaTokens.glassTextSecondary,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ),
          if (ap.isRefilling) ...[
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: LuminaTokens.glassTextSecondary,
              ),
            ),
            const SizedBox(width: 6),
          ],
          if (hasAutoTracks)
            Tooltip(
              message: '清空自動推薦佇列',
              child: InkWell(
                key: const Key('btn_clear_auto_queue'),
                borderRadius: BorderRadius.circular(6),
                mouseCursor: SystemMouseCursors.click,
                hoverColor: LuminaTokens.glassRowHoverBg,
                onTap: ap.clearAutoQueue,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.clear_all_rounded,
                        size: 14,
                        color: LuminaTokens.glassTextSecondary,
                      ),
                      SizedBox(width: 3),
                      Text(
                        '清空',
                        style: TextStyle(
                          color: LuminaTokens.glassTextSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTrackRow({
    required double resolvedMaxWidth,
    required TrackInfo track,
    required int combinedIndex,
    required bool isCurrent,
    required bool isAuto,
    required bool isLockedPlayingAuto,
    required AutoplayController ap,
    required TrackPrefetchCallback? onPrefetch,
    required VoidCallback ensureSeededBeforeReorder,
  }) {
    Widget buildDragProxyRow() {
      return Container(
        color: isCurrent ? LuminaTokens.glassNavActiveBg : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Icon(
              isCurrent
                  ? Icons.equalizer_rounded
                  : (isLockedPlayingAuto
                        ? Icons.all_inclusive_rounded
                        : Icons.drag_indicator_rounded),
              size: 15,
              color: isCurrent ? Colors.white : LuminaTokens.textMuted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isCurrent
                          ? Colors.white
                          : LuminaTokens.glassTextPrimary,
                      fontSize: 12.5,
                      fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
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
      );
    }

    final payload = _QueueDragPayload(
      track: track,
      combinedIndex: combinedIndex,
      isAuto: isAuto,
    );

    Widget buildFeedback() => Material(
      color: Colors.transparent,
      child: SizedBox(
        width: resolvedMaxWidth - 8,
        child: FrostedGlassContainer(
          blurSigma: 0,
          enableBackdropBlur: false,
          color: LuminaTokens.glassDialogBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: LuminaTokens.glassPillBorder),
          child: buildDragProxyRow(),
        ),
      ),
    );

    Widget buildDraggableRowBody() {
      final Widget gripIcon = Icon(
        isCurrent
            ? Icons.equalizer_rounded
            : (isLockedPlayingAuto
                  ? Icons.all_inclusive_rounded
                  : Icons.drag_indicator_rounded),
        size: 15,
        color: isCurrent ? Colors.white : LuminaTokens.textMuted,
      );

      final Widget leadingGrip = isLockedPlayingAuto
          ? Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              child: gripIcon,
            )
          : MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Draggable<_QueueDragPayload>(
                key: Key('quick_queue_drag_handle_${track.id}'),
                data: payload,
                feedback: buildFeedback(),
                childWhenDragging: Opacity(opacity: 0.35, child: gripIcon),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 2,
                    vertical: 4,
                  ),
                  child: gripIcon,
                ),
              ),
            );

      final Widget rowContent = Container(
        color: isCurrent ? LuminaTokens.glassNavActiveBg : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            leadingGrip,
            const SizedBox(width: 6),
            Expanded(
              child: InkWell(
                key: Key('quick_queue_item_${track.id}'),
                onTap: () => audioService.play(track: track),
                mouseCursor: SystemMouseCursors.click,
                hoverColor: LuminaTokens.glassRowHoverBg,
                focusColor: LuminaTokens.focusRing.withValues(alpha: 0.22),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isCurrent
                            ? Colors.white
                            : LuminaTokens.glassTextPrimary,
                        fontSize: 12.5,
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
            ),
            if (isAuto) ...[
              const SizedBox(width: 4),
              Tooltip(
                message: '移至待播佇列',
                child: InkWell(
                  key: Key('btn_promote_auto_track_${track.id}'),
                  borderRadius: BorderRadius.circular(6),
                  mouseCursor: SystemMouseCursors.click,
                  hoverColor: LuminaTokens.glassPillHoverBg,
                  onTap: () => ap.promoteAutoTrackToUserQueue(track.id),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(
                      Icons.playlist_add_rounded,
                      size: 16,
                      color: LuminaTokens.glassTextSecondary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Tooltip(
                message: '移除此推薦曲目',
                child: InkWell(
                  key: Key('btn_remove_auto_track_${track.id}'),
                  borderRadius: BorderRadius.circular(6),
                  mouseCursor: SystemMouseCursors.click,
                  hoverColor: LuminaTokens.glassPillHoverBg,
                  onTap: () => ap.removeAutoTrack(track.id),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(
                      Icons.close_rounded,
                      size: 15,
                      color: LuminaTokens.glassTextTertiary,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      );

      final Widget prefetchedRow = TrackHoverPrefetch(
        track: track,
        onPrefetch: onPrefetch,
        child: rowContent,
      );

      if (isLockedPlayingAuto) return prefetchedRow;
      return LongPressDraggable<_QueueDragPayload>(
        data: payload,
        feedback: buildFeedback(),
        childWhenDragging: Opacity(
          opacity: 0.35,
          child: buildDragProxyRow(),
        ),
        child: prefetchedRow,
      );
    }

    final Widget rowWidget = buildDraggableRowBody();

    return DragTarget<_QueueDragPayload>(
      onWillAcceptWithDetails: (details) =>
          details.data.combinedIndex != combinedIndex,
      onAcceptWithDetails: (details) {
        ensureSeededBeforeReorder();
        ap.reorderDualQueue(details.data.combinedIndex, combinedIndex);
      },
      builder: (context, candidateData, rejectedData) {
        final isTarget = candidateData.isNotEmpty;
        return DecoratedBox(
          decoration: BoxDecoration(
            border: isTarget
                ? const Border(
                    top: BorderSide(color: LuminaTokens.focusRing, width: 2),
                  )
                : null,
          ),
          child: rowWidget,
        );
      },
    );
  }
}
