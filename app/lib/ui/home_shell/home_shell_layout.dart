part of '../home_screen.dart';

extension _HomeShellLayers on _HomeScreenState {
  void _handleShellMiniPlayerMeasured(double rawHeight) {
    _lastMeasuredRawMiniHeight = rawHeight;
    _handleMiniPlayerHeightMeasured(rawHeight);
    if (_scaleController.homeLayoutPreset.usesFloatingPlayerPill) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _syncEffectiveClearance(rawHeight);
      });
    }
  }

  Widget _buildAmbientLayer({required bool isNowPlayingFullyCovered}) {
    final preset = _scaleController.homeLayoutPreset;
    final showAjAura =
        preset == HomeLayoutPreset.auraQuickResume &&
        _activeTab == HomeTab.home;
    return Positioned.fill(
      child: Offstage(
        offstage: isNowPlayingFullyCovered,
        child: Stack(
          fit: StackFit.expand,
          children: [
            AmbientDynamicBackground(
              key: const ValueKey('home_ambient_bg_layer'),
              repaintBoundaryKey: const Key('home_bg_repaint_boundary'),
              meshPainterKey: const Key('home_ambient_bg'),
              audioService: _effectiveAudioService,
              libraryCache: _libraryCache,
              paletteService: _paletteService,
              meshFluidProgram: _shaders.meshFluidProgram,
              adaptToTheme: true,
              ambientTintStrength: 1.0,
              enabled: !_isHiddenToTray && !_isNowPlayingExpanded,
            ),
            if (showAjAura)
              Positioned.fill(
                child: TopAmbientAura(
                  key: const Key('aj_top_ambient_aura'),
                  audioService: _effectiveAudioService,
                  libraryCache: _libraryCache,
                  paletteService: _paletteService,
                  followCover: _scaleController.auraFollowCover,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildWorkspaceLayer({
    required bool isDesktop,
    required double availWidth,
    required double sidebarWidth,
    required bool isNowPlayingFullyCovered,
  }) {
    final preset = _scaleController.homeLayoutPreset;
    final effectiveSidebarCollapsed = preset.isSidebarless || _sidebarCollapsed;
    final visibleSidebarWidth =
        (isDesktop && !effectiveSidebarCollapsed) ? sidebarWidth : 0.0;
    return LayoutId(
      key: const ValueKey('home_workspace_layer'),
      id: _HomeShellSlot.workspace,
      child: RepaintBoundary(
        key: const Key('workspace_repaint_boundary'),
        child: TickerMode(
          enabled: !_isHiddenToTray && !_isNowPlayingExpanded,
          child: Visibility(
            visible: !isNowPlayingFullyCovered,
            maintainState: true,
            maintainAnimation: true,
            maintainSize: true,
            child: IgnorePointer(
              ignoring: _isNowPlayingExpanded,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: KeyedSubtree(
                      key: const ValueKey('workspace_stage'),
                      child: isDesktop
                          ? Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                ClipRect(
                                  child: AnimatedAlign(
                                    duration: const Duration(milliseconds: 220),
                                    curve: Curves.easeOutCubic,
                                    alignment: Alignment.centerRight,
                                    widthFactor:
                                        effectiveSidebarCollapsed ? 0.0 : 1.0,
                                    child: ExcludeSemantics(
                                      excluding: effectiveSidebarCollapsed,
                                      child: IgnorePointer(
                                        ignoring: effectiveSidebarCollapsed,
                                        child: _buildSidebar(
                                          width: sidebarWidth > 0
                                              ? sidebarWidth
                                              : 196.0,
                                          collapsed: effectiveSidebarCollapsed,
                                          preset: preset,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: ClipRect(
                                    child: _buildMainColumn(
                                      isDesktop: true,
                                      availWidth:
                                          availWidth - visibleSidebarWidth,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : _buildMainColumn(
                              isDesktop: false,
                              availWidth: availWidth,
                            ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: WindowDragBar.kDefaultHeight,
                    child: _buildTopBar(
                      isDesktop: isDesktop,
                      availWidth: availWidth,
                      sidebarWidth: sidebarWidth,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNowPlayingLayer({
    required double fallbackMiniPlayerClearance,
    required bool isOverlayActive,
    required bool isNowPlayingFullyCovered,
  }) {
    final usesFloatingPill =
        _scaleController.homeLayoutPreset.usesFloatingPlayerPill;
    final overlayChild = RepaintBoundary(
      key: const Key('now_playing_overlay_repaint_boundary'),
      child: ValueListenableBuilder<double?>(
        valueListenable: _measuredMiniPlayerHeight,
        builder: (context, measuredHeight, _) {
          return NowPlayingOverlay(
            key: const ValueKey('now_playing_stage'),
            audioService: _effectiveAudioService,
            libraryCache: _libraryCache,
            controller: _nowPlayingController,
            windowController: _windowController,
            paletteService: _paletteService,
            meshFluidProgram: _shaders.meshFluidProgram,
            isVisible: _isNowPlayingExpanded && !_isHiddenToTray,
            isTransitionSettled: isNowPlayingFullyCovered,
            bottomClearance: usesFloatingPill
                ? fallbackMiniPlayerClearance
                : (measuredHeight ?? fallbackMiniPlayerClearance),
            hasHostControls: true,
            recommendationSettings: _recommendationSettings,
            onOpenDsp: () {
              _setNowPlayingExpanded(false);
              _selectTab(HomeTab.dsp);
            },
            onCollapse: () => _setNowPlayingExpanded(false),
          );
        },
      ),
    );

    final Widget transitionChild = SlideTransition(
      key: const Key('now_playing_slide_transition'),
      position: _nowPlayingSlideAnim,
      child: overlayChild,
    );

    return LayoutId(
      key: const ValueKey('home_now_playing_layer'),
      id: _HomeShellSlot.nowPlaying,
      child: Offstage(
        offstage: !isOverlayActive,
        child: TickerMode(
          enabled: isOverlayActive && !_isHiddenToTray,
          child: ClipRect(child: transitionChild),
        ),
      ),
    );
  }

  Widget _buildMiniPlayerLayer({required bool suppressBackdropBlur}) {
    return LayoutId(
      key: const ValueKey('home_mini_player_layer'),
      id: _HomeShellSlot.miniPlayer,
      child: RepaintBoundary(
        key: const Key('mini_player_repaint_boundary'),
        child: ListenableBuilder(
          listenable: _nowPlayingController,
          builder: (context, _) {
            return FloatingCapsuleMiniPlayer(
              audioService: _effectiveAudioService,
              libraryCache: _libraryCache,
              uiScaleController: _scaleController,
              recommendationSettings: _recommendationSettings,
              showLyrics:
                  _isNowPlayingExpanded &&
                  _nowPlayingController.mode != NowPlayingViewMode.cover,
              isNowPlayingExpanded: _isNowPlayingExpanded,
              nowPlayingExpandProgress: _isNowPlayingExpanded ? 1.0 : 0.0,
              suppressBackdropBlur: suppressBackdropBlur,
              isQueueDrawerOpen:
                  _isNowPlayingExpanded &&
                  _nowPlayingController.queueDrawerOpen,
              floatingPillMode:
                  _scaleController.homeLayoutPreset.usesFloatingPlayerPill,
              glassShader: _glassShader,
              backdropImage: _shaders.backdropImage,
              onToggleLyrics: _toggleNowPlayingWithLyrics,
              onToggleNowPlaying: _toggleNowPlaying,
              onToggleNowPlayingLyrics: _toggleNowPlayingLyricsMode,
              onToggleNowPlayingQueue: _nowPlayingController.toggleQueueDrawer,
              onOpenZones: () => _selectTab(HomeTab.zones),
              onOpenLibrary: () => _selectTab(HomeTab.library),
            );
          },
        ),
      ),
    );
  }
}

enum _HomeShellSlot { workspace, nowPlaying, miniPlayer }

/// Single-pass shell layout delegate that lays out the docked mini-player first
/// at its exact intrinsic height, then sizes the workspace tightly to
/// `size.height - miniSize.height` so sidebar and main content abut the top edge
/// of the player bar with 0.0px gap and 0.0px overlap across all viewports.
class _HomeShellLayoutDelegate extends MultiChildLayoutDelegate {
  final bool floatingPillMode;
  final ValueChanged<double>? onMiniPlayerHeightMeasured;

  _HomeShellLayoutDelegate({
    this.floatingPillMode = false,
    this.onMiniPlayerHeightMeasured,
  });

  @override
  void performLayout(Size size) {
    Size miniSize = Size.zero;
    if (hasChild(_HomeShellSlot.miniPlayer)) {
      miniSize = layoutChild(
        _HomeShellSlot.miniPlayer,
        BoxConstraints(
          minWidth: size.width,
          maxWidth: size.width,
          minHeight: 0.0,
          maxHeight: double.infinity,
        ),
      );
      final clampedMiniHeight = miniSize.height.clamp(0.0, size.height);
      positionChild(
        _HomeShellSlot.miniPlayer,
        Offset(0.0, size.height - clampedMiniHeight),
      );
      onMiniPlayerHeightMeasured?.call(clampedMiniHeight);
      miniSize = Size(miniSize.width, clampedMiniHeight);
    }

    if (hasChild(_HomeShellSlot.workspace)) {
      final workspaceHeight = floatingPillMode
          ? size.height
          : math.max(0.0, size.height - miniSize.height);
      layoutChild(
        _HomeShellSlot.workspace,
        BoxConstraints.tightFor(
          width: size.width,
          height: workspaceHeight,
        ),
      );
      positionChild(_HomeShellSlot.workspace, Offset.zero);
    }

    if (hasChild(_HomeShellSlot.nowPlaying)) {
      layoutChild(_HomeShellSlot.nowPlaying, BoxConstraints.tight(size));
      positionChild(_HomeShellSlot.nowPlaying, Offset.zero);
    }
  }

  @override
  bool shouldRelayout(covariant _HomeShellLayoutDelegate oldDelegate) =>
      oldDelegate.floatingPillMode != floatingPillMode;
}

/// Applies a soft bottom alpha fade (`BlendMode.dstIn`) over the bottom
/// [fadeHeight] logical pixels of scrollable content so scrolled rows fade
/// smoothly into the global ambient background instead of hard-clipping.
class _BottomEdgeFadeMask extends StatelessWidget {
  final double fadeHeight;
  final Widget child;

  const _BottomEdgeFadeMask({
    super.key,
    this.fadeHeight = 28.0,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (Rect bounds) {
        if (bounds.height <= 0.0 || fadeHeight <= 0.0) {
          return const LinearGradient(
            colors: [Colors.white, Colors.white],
          ).createShader(bounds);
        }
        final stop = (1.0 - (fadeHeight / bounds.height)).clamp(0.0, 1.0);
        return LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [Colors.white, Colors.white, Colors.transparent],
          stops: [0.0, stop, 1.0],
        ).createShader(bounds);
      },
      child: child,
    );
  }
}
