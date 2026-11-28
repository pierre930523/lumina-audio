import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../models/audio_quality_tier.dart';
import '../../models/lyric.dart';
import '../../models/playback_state.dart';
import '../../models/streaming_provider_meta.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/audio_service.dart';
import '../../services/desktop_window_controller.dart';
import '../../services/escape_dismiss_registry.dart';
import '../../services/library_index_cache.dart';
import '../../services/now_playing_view_controller.dart';
import '../../services/podcast_store.dart';
import '../../services/recommendation_settings_controller.dart';
import '../../services/streaming/autoplay_controller.dart';
import '../artwork/album_artwork_view.dart';
import '../common/ambient_dynamic_background.dart';
import '../common/audio_info_popover.dart';
import '../common/audio_quality_badge.dart';
import '../common/desktop_window_caption.dart';
import '../common/frosted_glass_container.dart';
import '../common/preference_toggle_button.dart';
import '../common/track_context_menu.dart';
import '../common/track_hover_prefetch.dart';
import '../common/window_drag_bar.dart';
import '../lyrics/lyrics_view.dart';
import '../mini_player/playback_controls.dart';
import '../mini_player/progress_bar.dart';
import '../signal_path/signal_path_modal.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';
import 'now_playing_layout.dart';

part 'now_playing_hero_stage.dart';
part 'now_playing_metadata.dart';
part 'now_playing_overlay_actions.dart';
part 'now_playing_queue_drawer.dart';
part 'now_playing_queue_dual_row.dart';
part 'now_playing_queue_headers.dart';
part 'now_playing_stages.dart';
part 'now_playing_top_bar.dart';

class NowPlayingOverlay extends StatefulWidget {
  final AudioService audioService;
  final VoidCallback onCollapse;
  final LibraryIndexCache? libraryCache;
  final NowPlayingViewController? controller;
  final DesktopWindowController? windowController;
  final ArtworkPaletteService? paletteService;
  final ui.FragmentProgram? meshFluidProgram;
  final bool isVisible;
  final bool isTransitionSettled;
  final bool? enableAmbientMotion;
  final double bottomClearance;
  final bool hasHostControls;
  final VoidCallback? onOpenDsp;
  final RecommendationSettingsController? recommendationSettings;

  const NowPlayingOverlay({
    super.key,
    required this.audioService,
    required this.onCollapse,
    this.libraryCache,
    this.controller,
    this.windowController,
    this.paletteService,
    this.meshFluidProgram,
    this.isVisible = true,
    this.isTransitionSettled = true,
    this.enableAmbientMotion,
    this.bottomClearance = 0.0,
    this.hasHostControls = false,
    this.onOpenDsp,
    this.recommendationSettings,
  });

  @override
  State<NowPlayingOverlay> createState() => NowPlayingOverlayState();
}

class NowPlayingOverlayState extends State<NowPlayingOverlay>
    with TickerProviderStateMixin {
  late NowPlayingViewController _controller;
  late bool _ownsController;
  late NowPlayingViewMode _lastMode;
  late bool _lastQueueDrawerOpen;
  late ArtworkPaletteService _paletteService;

  late final AnimationController _modeAnimController;
  late final Animation<double> _modeAnim;
  late final AnimationController _queueDrawerAnimController;
  late final Animation<Offset> _queueDrawerSlideAnim;
  late final Animation<double> _queueDrawerOpacityAnim;
  late final GlideScrollController _queueScrollController;

  late final bool Function() _queueEscapeHandler = _handleQueueEscape;

  AnimationController get modeAnimController => _modeAnimController;
  AnimationController get transitionController => _modeAnimController;

  Widget? _cachedHeroWidget;
  String? _cachedHeroTrackKey;
  double? _cachedHeroCoverSide;
  double? _cachedHeroMaxCoverSide;
  double? _cachedHeroStageInnerH;
  double? _cachedHeroGap;
  double? _cachedHeroCoverRadius;
  double? _cachedHeroTitleFontSize;
  double? _cachedHeroSubtitleFontSize;
  double? _cachedHeroMetaTitleGap;
  double? _cachedHeroMetaPillGap;
  double? _cachedHeroMaxMetaHeight;
  double? _cachedHeroShadowBlur;
  bool? _cachedHeroCompactMetadata;

  String? _artworkCallbackTrackKey;
  void Function(String?, String?)? _artworkResolvedCallback;

  String? _resolvedCoverPath;
  String? _resolvedCoverUrl;
  String? _resolvedArtworkTrackKey;

  final math.Random _random = math.Random();
  bool get _isShuffleEnabled => widget.audioService.shuffle;
  LuminaRepeatMode get _repeatMode =>
      LuminaRepeatMode.fromRepeatMode(widget.audioService.repeatMode);
  final AudioInfoPopoverController _standaloneQualityPopoverController =
      AudioInfoPopoverController();

  StreamSubscription<PlaybackState>? _stateSub;
  StreamSubscription<TrackInfo>? _trackChangedSub;

  late PlaybackState _structuralState;
  late List<LyricLine> _structuralLyrics;
  late String _structuralSignature;
  late final ValueNotifier<Duration> _positionNotifier;

  void _mutateState(VoidCallback fn) => setState(fn);

  void Function(String?, String?) _artworkResolvedCallbackFor(TrackInfo? track) {
    final key = _trackIdentityKey(track);
    if (_artworkResolvedCallback == null || _artworkCallbackTrackKey != key) {
      _artworkCallbackTrackKey = key;
      _artworkResolvedCallback = (cachePath, coverUrl) =>
          _handleArtworkResolved(track, cachePath, coverUrl);
    }
    return _artworkResolvedCallback!;
  }

  static String _trackIdentityKey(TrackInfo? track) {
    if (track == null) return 'none';
    return '${track.responsiveArtworkKey}|'
        '${track.id}|'
        '${track.artworkCacheKey ?? ''}|'
        '${track.coverUrl ?? ''}|'
        '${track.albumArtUrl ?? ''}|'
        '${track.filePath ?? ''}|'
        '${track.album}|'
        '${track.title}|'
        '${track.artist}|'
        '${track.providerName}|'
        '${track.format.label}|'
        '${track.format.bitrateKbps ?? ''}|'
        '${getAudioQualityTier(track).code}';
  }

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? NowPlayingViewController();
    _lastMode = _controller.mode;
    _lastQueueDrawerOpen = _controller.queueDrawerOpen;
    _controller.addListener(_onControllerChanged);

    _paletteService = widget.paletteService ?? ArtworkPaletteService();
    _structuralState = widget.audioService.currentState;
    _structuralLyrics = List<LyricLine>.from(widget.audioService.currentLyrics);
    _structuralSignature = _computeStructuralSignature(
      _structuralState,
      _structuralLyrics,
    );
    _positionNotifier = ValueNotifier<Duration>(_structuralState.position);
    _resolvedArtworkTrackKey = _trackIdentityKey(_structuralState.track);

    widget.audioService.setNowPlayingVisible(
      widget.isVisible && widget.isTransitionSettled,
    );

    _modeAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
      value: _controller.mode == NowPlayingViewMode.cover ? 0.0 : 1.0,
    );
    _modeAnim = CurvedAnimation(
      parent: _modeAnimController,
      curve: Curves.easeInOutCubic,
    );

    _queueDrawerAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: _controller.queueDrawerOpen ? 1.0 : 0.0,
    )..addStatusListener(_onQueueDrawerAnimStatus);
    _queueDrawerSlideAnim = Tween<Offset>(
      begin: const Offset(1.0, 0.0),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _queueDrawerAnimController,
        curve: Curves.easeOutCubic,
      ),
    );
    _queueDrawerOpacityAnim = CurvedAnimation(
      parent: _queueDrawerAnimController,
      curve: Curves.easeOutCubic,
    );

    _queueScrollController = GlideScrollController(
      initialScrollOffset: _controller.queueScrollOffset,
    )..addListener(_onQueueScroll);

    _stateSub = widget.audioService.stateStream.listen(_onPlaybackState);
    _trackChangedSub = widget.audioService.trackChangedStream.listen(
      _onTrackChanged,
    );
    _syncQueueEscapeRegistration();
  }

  @override
  void didUpdateWidget(covariant NowPlayingOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onControllerChanged);
      _controller.removeListener(_onControllerChanged);
      if (_ownsController) {
        _controller.dispose();
      }
      _ownsController = widget.controller == null;
      _controller = widget.controller ?? NowPlayingViewController();
      _lastMode = _controller.mode;
      _lastQueueDrawerOpen = _controller.queueDrawerOpen;
      _controller.addListener(_onControllerChanged);
      if (_controller.mode == NowPlayingViewMode.cover) {
        _modeAnimController.value = 0.0;
      } else if (_controller.mode == NowPlayingViewMode.split) {
        _modeAnimController.value = 1.0;
      }
      if (_lastQueueDrawerOpen) {
        _queueDrawerAnimController.forward();
      } else {
        _queueDrawerAnimController.reverse();
      }
    }

    if (oldWidget.paletteService != widget.paletteService) {
      _paletteService = widget.paletteService ?? ArtworkPaletteService();
    }

    if (oldWidget.audioService != widget.audioService) {
      _stateSub?.cancel();
      _trackChangedSub?.cancel();
      _trackChangedSub = null;
      _stateSub = widget.audioService.stateStream.listen(_onPlaybackState);
      _trackChangedSub = widget.audioService.trackChangedStream.listen(
        _onTrackChanged,
      );
      _syncFromAudioService();
    } else if (!oldWidget.isVisible && widget.isVisible ||
        (!oldWidget.isTransitionSettled && widget.isTransitionSettled)) {
      _syncFromAudioService();
    }

    final wasVisiblySettled =
        oldWidget.isVisible && oldWidget.isTransitionSettled;
    final isVisiblySettled = widget.isVisible && widget.isTransitionSettled;
    if (wasVisiblySettled != isVisiblySettled ||
        oldWidget.audioService != widget.audioService) {
      if (oldWidget.audioService != widget.audioService) {
        oldWidget.audioService.setNowPlayingVisible(false);
      }
      widget.audioService.setNowPlayingVisible(isVisiblySettled);
    }

    if (oldWidget.isVisible != widget.isVisible ||
        oldWidget.controller != widget.controller) {
      _syncQueueEscapeRegistration();
    }
    if ((oldWidget.isVisible && !widget.isVisible) ||
        (!oldWidget.hasHostControls && widget.hasHostControls)) {
      _standaloneQualityPopoverController.close();
    }
  }

  @override
  void dispose() {
    _standaloneQualityPopoverController.dispose();
    EscapeDismissRegistry.instance.unregister(_queueEscapeHandler);
    widget.audioService.setNowPlayingVisible(false);
    _stateSub?.cancel();
    _trackChangedSub?.cancel();
    _trackChangedSub = null;
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) {
      _controller.dispose();
    }
    _queueDrawerAnimController.removeStatusListener(_onQueueDrawerAnimStatus);
    _queueDrawerAnimController.dispose();
    _queueScrollController.removeListener(_onQueueScroll);
    _queueScrollController.dispose();
    _modeAnimController.dispose();
    _positionNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _structuralState;
    final track = state.track;
    final lyrics = _structuralLyrics;
    final mode = _controller.mode;

    return TickerMode(
      enabled: widget.isVisible,
      child: SizedBox.expand(
        child: Stack(
          fit: StackFit.expand,
          children: [
            AmbientDynamicBackground(
              repaintBoundaryKey: const Key('now_playing_bg_repaint_boundary'),
              meshPainterKey: const Key('now_playing_ambient_bg'),
              audioService: widget.audioService,
              libraryCache: widget.libraryCache,
              paletteService: _paletteService,
              meshFluidProgram: widget.meshFluidProgram,
              enabled: widget.isVisible && widget.isTransitionSettled,
              externalArtworkCachePath: _resolvedCoverPath,
              externalArtworkUrl: _resolvedCoverUrl,
            ),
            LayoutBuilder(
              builder: (context, outerConstraints) {
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      bottom: widget.bottomClearance,
                      child: Material(
                        key: const Key('now_playing_overlay'),
                        type: MaterialType.transparency,
                        child: Column(
                          children: [
                            _buildTopBar(mode, track),
                            Expanded(
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final metrics =
                                      NowPlayingLayoutMetrics.compute(
                                    width: constraints.maxWidth,
                                    height: constraints.maxHeight,
                                    mode: mode,
                                    viewportWidth: outerConstraints.maxWidth,
                                    viewportHeight:
                                        outerConstraints.maxHeight,
                                  );
                                  final stageWidget = _buildStage(
                                    key: const Key(
                                      'now_playing_stage_content',
                                    ),
                                    metrics: metrics,
                                    maxWidth: constraints.maxWidth,
                                    maxHeight: constraints.maxHeight,
                                    viewportWidth: outerConstraints.maxWidth,
                                    viewportHeight:
                                        outerConstraints.maxHeight,
                                    state: state,
                                    track: track,
                                    lyrics: lyrics,
                                  );
                                  final stageKey =
                                      mode == NowPlayingViewMode.lyrics
                                          ? 'lyrics'
                                          : 'main';
                                  return AnimatedSwitcher(
                                    duration:
                                        const Duration(milliseconds: 350),
                                    switchInCurve: Curves.easeInOutCubic,
                                    switchOutCurve: Curves.easeInOutCubic,
                                    transitionBuilder: (child, animation) {
                                      return FadeTransition(
                                        opacity: animation,
                                        child: child,
                                      );
                                    },
                                    child: KeyedSubtree(
                                      key: ValueKey('stage_$stageKey'),
                                      child: stageWidget,
                                    ),
                                  );
                                },
                              ),
                            ),
                            if (!widget.hasHostControls)
                              _buildStandaloneBottomControls(
                                state: state,
                                track: track,
                                maxWidth: outerConstraints.maxWidth,
                                compact: outerConstraints.maxHeight < 280,
                              ),
                          ],
                        ),
                      ),
                    ),
                    _buildQueueDrawer(
                      state: state,
                      maxWidth: outerConstraints.maxWidth,
                      maxHeight: outerConstraints.maxHeight,
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
