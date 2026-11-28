import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/streaming_provider_meta.dart';
import '../../services/audio_service.dart';
import '../../services/escape_dismiss_registry.dart';
import '../../services/library_index_cache.dart';
import '../../services/podcast_store.dart';
import '../../services/recommendation_settings_controller.dart';
import '../../services/streaming/autoplay_controller.dart';
import '../../services/ui_scale_controller.dart';
import '../artwork/album_artwork_view.dart';
import '../common/audio_info_popover.dart';
import '../common/frosted_glass_container.dart';
import '../signal_path/signal_path_modal.dart';
import '../theme/lumina_glass_theme.dart';
import '../theme/lumina_tokens.dart';
import '../theme/responsive_layout.dart';
import 'playback_controls.dart';
import 'progress_bar.dart';
import 'quick_output_popover.dart';
import 'quick_queue_popover.dart';
import 'volume_control.dart';

part 'floating_capsule_layouts.dart';
part 'floating_capsule_overlays.dart';
part 'floating_capsule_widgets.dart';

class FloatingCapsuleMiniPlayer extends StatefulWidget {
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final bool showLyrics;
  final bool isNowPlayingExpanded;
  final bool suppressBackdropBlur;
  final bool isQueueDrawerOpen;
  final bool floatingPillMode;
  final double nowPlayingExpandProgress;
  final VoidCallback onToggleLyrics;
  final VoidCallback? onToggleNowPlaying;
  final VoidCallback? onToggleNowPlayingQueue;
  final VoidCallback? onToggleNowPlayingLyrics;
  final VoidCallback? onOpenZones;
  final VoidCallback? onOpenLibrary;
  final UiScaleController? uiScaleController;
  final RecommendationSettingsController? recommendationSettings;
  final ui.FragmentShader? glassShader;
  final ui.Image? backdropImage;

  const FloatingCapsuleMiniPlayer({
    super.key,
    required this.audioService,
    this.libraryCache,
    required this.showLyrics,
    required this.onToggleLyrics,
    this.isNowPlayingExpanded = false,
    this.suppressBackdropBlur = false,
    this.isQueueDrawerOpen = false,
    this.floatingPillMode = false,
    this.nowPlayingExpandProgress = 0.0,
    this.onToggleNowPlaying,
    this.onToggleNowPlayingQueue,
    this.onToggleNowPlayingLyrics,
    this.onOpenZones,
    this.onOpenLibrary,
    this.uiScaleController,
    this.recommendationSettings,
    this.glassShader,
    this.backdropImage,
  });

  @override
  State<FloatingCapsuleMiniPlayer> createState() =>
      _FloatingCapsuleMiniPlayerState();
}

class _FloatingCapsuleMiniPlayerState extends State<FloatingCapsuleMiniPlayer>
    with WidgetsBindingObserver {
  final LayerLink _outputLayerLink = LayerLink();
  final LayerLink _queueLayerLink = LayerLink();
  final GlobalKey _outputAnchorKey = GlobalKey();
  final GlobalKey _queueAnchorKey = GlobalKey();
  final AudioInfoPopoverController _qualityPopoverController =
      AudioInfoPopoverController();
  OverlayEntry? _outputOverlay;
  OverlayEntry? _queueOverlay;
  bool _metricsUpdateScheduled = false;
  final math.Random _random = math.Random();
  late final bool Function() _escapeDismissHandler = _handleEscapeDismiss;
  StreamSubscription<void>? _autoplayChangesSub;
  StreamSubscription<Duration>? _positionSub;
  PlaybackState? _lastStreamState;
  Duration? _livePosition;
  bool _useStaticExpandedFallback = false;

  double get _effectiveExpandT {
    if (!widget.floatingPillMode) {
      return widget.isNowPlayingExpanded ? 1.0 : 0.0;
    }
    if (_useStaticExpandedFallback) return 1.0;
    return widget.nowPlayingExpandProgress.clamp(0.0, 1.0);
  }

  bool get _isShuffleEnabled => widget.audioService.shuffle;
  LuminaRepeatMode get _repeatMode =>
      LuminaRepeatMode.fromRepeatMode(widget.audioService.repeatMode);

  AutoplayController? get _autoplayController =>
      widget.audioService.autoplayController;

  void _onAutoplayChanged(void _) {
    if (mounted) {
      setState(() {});
    }
  }

  void _onRecommendationSettingsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _subscribeAutoplay() {
    _autoplayChangesSub?.cancel();
    _autoplayChangesSub = _autoplayController?.changes.listen(_onAutoplayChanged);
  }

  void _subscribePosition() {
    _positionSub?.cancel();
    _positionSub = widget.audioService.positionStream.listen(_onPositionTick);
  }

  void _onPositionTick(Duration pos) {
    if (!mounted) return;
    if ((_livePosition ?? _lastStreamState?.position) == pos) return;
    _livePosition = pos;
    setState(() {});
  }

  void _toggleAutoplay(bool currentlyEnabled) {
    final next = !currentlyEnabled;
    _autoplayController?.setEnabled(next);
    final rec = widget.recommendationSettings;
    if (rec != null && rec.autoplayEnabled != next) {
      unawaited(rec.setAutoplayEnabled(next));
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    _useStaticExpandedFallback =
        widget.floatingPillMode &&
        widget.isNowPlayingExpanded &&
        widget.nowPlayingExpandProgress == 0.0;
    WidgetsBinding.instance.addObserver(this);
    _subscribeAutoplay();
    _subscribePosition();
    widget.recommendationSettings?.addListener(_onRecommendationSettingsChanged);
  }

  @override
  void didUpdateWidget(covariant FloatingCapsuleMiniPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.nowPlayingExpandProgress > 0.0 || !widget.isNowPlayingExpanded) {
      _useStaticExpandedFallback = false;
    } else if (!oldWidget.floatingPillMode &&
        widget.floatingPillMode &&
        widget.isNowPlayingExpanded &&
        widget.nowPlayingExpandProgress == 0.0) {
      _useStaticExpandedFallback = true;
    }
    if (!identical(oldWidget.audioService, widget.audioService)) {
      _lastStreamState = null;
      _livePosition = null;
      _subscribeAutoplay();
      _subscribePosition();
    }
    if (!identical(
      oldWidget.recommendationSettings,
      widget.recommendationSettings,
    )) {
      oldWidget.recommendationSettings?.removeListener(
        _onRecommendationSettingsChanged,
      );
      widget.recommendationSettings?.addListener(
        _onRecommendationSettingsChanged,
      );
    }
    if (!oldWidget.isNowPlayingExpanded &&
        widget.isNowPlayingExpanded &&
        _queueOverlay != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _closeAllOverlays();
      });
    }
  }

  void _toggleShuffle() {
    unawaited(widget.audioService.setShuffle(!_isShuffleEnabled));
    if (mounted) {
      setState(() {});
    }
  }

  void _cycleRepeat() {
    final nextMode = widget.audioService.repeatMode.nextCycle;
    unawaited(widget.audioService.setRepeatMode(nextMode));
    if (mounted) {
      setState(() {});
    }
  }

  void _handlePrevious() {
    unawaited(widget.audioService.previous());
  }

  Future<void> _handleNext() async {
    if (_repeatMode == LuminaRepeatMode.one) {
      await widget.audioService.seek(Duration.zero);
      if (widget.audioService.currentState.status != PlaybackStatus.playing) {
        await widget.audioService.play();
      }
      return;
    }
    final queue = widget.audioService.queue;
    if (_isShuffleEnabled && queue.length > 1) {
      final currentId = widget.audioService.currentState.track?.id;
      final candidates = queue
          .where((t) => t.id != currentId && t.preference != -1)
          .toList();
      if (candidates.isNotEmpty) {
        final chosen = candidates[_random.nextInt(candidates.length)];
        unawaited(widget.audioService.skipToTrack(chosen, queueContext: queue));
        return;
      }
    }
    unawaited(widget.audioService.next());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleOpenPopoverRebuild();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    _scheduleOpenPopoverRebuild();
  }

  void _scheduleOpenPopoverRebuild() {
    if (_outputOverlay == null && _queueOverlay == null) return;
    if (_metricsUpdateScheduled) return;
    _metricsUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _metricsUpdateScheduled = false;
      if (!mounted) return;
      _outputOverlay?.markNeedsBuild();
      _queueOverlay?.markNeedsBuild();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _autoplayChangesSub?.cancel();
    _autoplayChangesSub = null;
    _positionSub?.cancel();
    _positionSub = null;
    widget.recommendationSettings?.removeListener(
      _onRecommendationSettingsChanged,
    );
    _closeAllOverlays(markState: false);
    _qualityPopoverController.dispose();
    super.dispose();
  }

  bool _handleEscapeDismiss() {
    if (_outputOverlay == null && _queueOverlay == null) {
      EscapeDismissRegistry.instance.unregister(_escapeDismissHandler);
      return false;
    }
    _closeAllOverlays();
    return true;
  }

  void _refreshState() {
    if (mounted) {
      setState(() {});
    }
  }

  void _setOutputOverlay(OverlayEntry entry) {
    setState(() => _outputOverlay = entry);
  }

  void _setQueueOverlay(OverlayEntry entry) {
    setState(() => _queueOverlay = entry);
  }

  void _closeAllOverlays({bool markState = true}) {
    EscapeDismissRegistry.instance.unregister(_escapeDismissHandler);
    _qualityPopoverController.close();
    var changed = false;
    if (_outputOverlay != null) {
      _outputOverlay!.remove();
      _outputOverlay!.dispose();
      _outputOverlay = null;
      changed = true;
    }
    if (_queueOverlay != null) {
      _queueOverlay!.remove();
      _queueOverlay!.dispose();
      _queueOverlay = null;
      changed = true;
    }
    if (changed && markState && mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final double expandT = _effectiveExpandT;
    final Widget body = StreamBuilder<PlaybackState>(
      stream: widget.audioService.stateStream,
      initialData: widget.audioService.currentState,
      builder: (context, stateSnap) {
        final rawState = stateSnap.data ?? widget.audioService.currentState;
        if (!identical(rawState, _lastStreamState)) {
          _lastStreamState = rawState;
          _livePosition = null;
        }
        final state = _livePosition != null && _livePosition != rawState.position
            ? rawState.copyWith(position: _livePosition)
            : rawState;
        final track = state.track;
        final trackDuration = track?.duration ?? const Duration(minutes: 4);

        return LayoutBuilder(
          builder: (context, constraints) {
            final outerWidth = constraints.maxWidth;
            final glass = LuminaGlassTheme.of(context);
            final bool isExpanded = widget.floatingPillMode
                ? expandT >= 1.0
                : widget.isNowPlayingExpanded;
            final double pillHInset = widget.floatingPillMode
                ? (outerWidth * 0.018).clamp(12.0, 24.0).floorToDouble()
                : 0.0;
            final double hInset = widget.floatingPillMode
                ? ui.lerpDouble(pillHInset, 0.0, expandT)!
                : 0.0;
            final double pillMaxWidth = widget.floatingPillMode
                ? math.min(1140.0, math.max(0.0, outerWidth - pillHInset * 2.0))
                : outerWidth;
            final double maxWidth = widget.floatingPillMode
                ? ui.lerpDouble(pillMaxWidth, outerWidth, expandT)!
                : outerWidth;
            final double triggerOpacity = !widget.floatingPillMode
                ? (isExpanded ? 0.0 : 1.0)
                : (1.0 - expandT * 2.5).clamp(0.0, 1.0);
            final isWide = maxWidth >= 740;
            final isMedium = !isWide && maxWidth >= 480;

            final controls = _buildFooterControls(context, track);
            final isPodcast = PodcastPlaybackTracker.isPodcastTrack(track);
            final VoidCallback? onSkipBack15s = isPodcast
                ? () => PodcastPlaybackTracker.seekRelative(
                    widget.audioService,
                    PodcastPlaybackTracker.skipBackwardDelta,
                  )
                : null;
            final VoidCallback? onSkipForward30s = isPodcast
                ? () => PodcastPlaybackTracker.seekRelative(
                    widget.audioService,
                    PodcastPlaybackTracker.skipForwardDelta,
                  )
                : null;

            final Widget content;
            if (isWide) {
              content = _buildWideContent(
                maxWidth: maxWidth,
                state: state,
                track: track,
                trackDuration: trackDuration,
                expandT: expandT,
                triggerOpacity: triggerOpacity,
                badge: controls.badge,
                queueBtn: controls.queueBtn,
                outputBtn: controls.outputBtn,
                lyricsBtn: controls.lyricsBtn,
                autoplayBtn: controls.autoplayBtn,
                onSkipBack15s: onSkipBack15s,
                onSkipForward30s: onSkipForward30s,
              );
            } else if (isMedium) {
              content = _buildMediumContent(
                maxWidth: maxWidth,
                state: state,
                track: track,
                trackDuration: trackDuration,
                triggerOpacity: triggerOpacity,
                badge: controls.badge,
                queueBtn: controls.queueBtn,
                outputBtn: controls.outputBtn,
                lyricsBtn: controls.lyricsBtn,
                autoplayBtn: controls.autoplayBtn,
                onSkipBack15s: onSkipBack15s,
                onSkipForward30s: onSkipForward30s,
              );
            } else {
              content = _buildNarrowContent(
                maxWidth: maxWidth,
                state: state,
                track: track,
                trackDuration: trackDuration,
                expandT: expandT,
                triggerOpacity: triggerOpacity,
                badge: controls.badge,
                queueBtn: controls.queueBtn,
                outputBtn: controls.outputBtn,
                lyricsBtn: controls.lyricsBtn,
                autoplayBtn: controls.autoplayBtn,
              );
            }

            return _buildCapsuleShell(
              context: context,
              glass: glass,
              isExpanded: isExpanded,
              isWide: isWide,
              expandT: expandT,
              hInset: hInset,
              maxWidth: maxWidth,
              outerWidth: outerWidth,
              content: content,
            );
          },
        );
      },
    );

    return _wrapExpandedDarkTheme(
      context: context,
      expandT: expandT,
      child: body,
    );
  }
}
