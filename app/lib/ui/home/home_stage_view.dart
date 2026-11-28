import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../models/home_layout_preset.dart';
import '../../models/studio_models.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/audio_service.dart';
import '../../services/home_dashboard_data_controller.dart';
import '../../services/library_index_cache.dart';
import 'home_dashboard_view.dart';
import 'home_layout_ai.dart';
import 'home_layout_aj.dart';

/// Switches between [HomeLayoutPreset] home views (`AI`, `AJ`, `Classic`)
/// over a shared [HomeDashboardDataController] with GPU transition and zero
/// duplicate data fetches.
class HomeStageView extends StatefulWidget {
  final HomeLayoutPreset preset;
  final AudioService audioService;
  final HomeDashboardDataController dataController;
  final LibraryIndexCache? libraryCache;
  final ArtworkPaletteService? paletteService;
  final List<SmartPlaylistItem> smartPlaylists;
  final bool auraFollowCover;
  final bool minimalCoverMode;
  final VoidCallback onOpenAlbums;
  final VoidCallback onOpenLibrary;
  final VoidCallback onOpenCredits;
  final VoidCallback onOpenDsp;
  final VoidCallback onOpenZones;
  final VoidCallback? onOpenAppearance;
  final VoidCallback? onOpenLibrarySettings;
  final VoidCallback? onOpenProviderSettings;
  final void Function(String albumId)? onOpenAlbumDetail;
  final void Function(String playlistId)? onOpenSmartPlaylist;
  final VoidCallback? onOpenSmartPlaylists;
  final double initialScrollOffset;
  final double topInset;
  final ValueChanged<double>? onScrollOffsetChanged;

  const HomeStageView({
    super.key,
    required this.preset,
    required this.audioService,
    required this.dataController,
    this.libraryCache,
    this.paletteService,
    this.smartPlaylists = const [],
    this.auraFollowCover = true,
    this.minimalCoverMode = false,
    required this.onOpenAlbums,
    required this.onOpenLibrary,
    required this.onOpenCredits,
    required this.onOpenDsp,
    required this.onOpenZones,
    this.onOpenAppearance,
    this.onOpenLibrarySettings,
    this.onOpenProviderSettings,
    this.onOpenAlbumDetail,
    this.onOpenSmartPlaylist,
    this.onOpenSmartPlaylists,
    this.initialScrollOffset = 0.0,
    this.topInset = 0.0,
    this.onScrollOffsetChanged,
  });

  @override
  State<HomeStageView> createState() => _HomeStageViewState();
}

class _HomeStageViewState extends State<HomeStageView> {
  @override
  void initState() {
    super.initState();
    _ensureLoadedIfNeeded();
  }

  @override
  void didUpdateWidget(covariant HomeStageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dataController != widget.dataController) {
      _ensureLoadedIfNeeded();
    }
  }

  void _ensureLoadedIfNeeded() {
    if (!widget.dataController.hasLoaded && !widget.dataController.isLoading) {
      unawaited(widget.dataController.ensureLoaded());
    }
  }

  Widget _buildPresetView() {
    final effectiveSmartPlaylists = widget.smartPlaylists.isNotEmpty
        ? widget.smartPlaylists
        : (widget.dataController.playlistService?.playlists ??
              const <SmartPlaylistItem>[]);

    return switch (widget.preset) {
      HomeLayoutPreset.topbarMinimal => HomeLayoutAI(
        audioService: widget.audioService,
        dataController: widget.dataController,
        libraryCache: widget.libraryCache,
        minimalCoverMode: widget.minimalCoverMode,
        onOpenAlbums: widget.onOpenAlbums,
        onOpenLibrary: widget.onOpenLibrary,
        onOpenAlbumDetail: widget.onOpenAlbumDetail,
        onOpenSmartPlaylist: widget.onOpenSmartPlaylist,
        onScrollOffsetChanged: widget.onScrollOffsetChanged,
      ),
      HomeLayoutPreset.auraQuickResume => HomeLayoutAJ(
        audioService: widget.audioService,
        dataController: widget.dataController,
        libraryCache: widget.libraryCache,
        paletteService: widget.paletteService,
        auraFollowCover: widget.auraFollowCover,
        minimalCoverMode: widget.minimalCoverMode,
        topInset: widget.topInset,
        onOpenAlbums: widget.onOpenAlbums,
        onOpenLibrary: widget.onOpenLibrary,
        onOpenAlbumDetail: widget.onOpenAlbumDetail,
        onOpenSmartPlaylist: widget.onOpenSmartPlaylist,
        onScrollOffsetChanged: widget.onScrollOffsetChanged,
      ),
      HomeLayoutPreset.classic => HomeDashboardView(
        audioService: widget.audioService,
        libraryCache: widget.libraryCache,
        smartPlaylists: effectiveSmartPlaylists,
        onOpenAlbums: widget.onOpenAlbums,
        onOpenLibrary: widget.onOpenLibrary,
        onOpenCredits: widget.onOpenCredits,
        onOpenDsp: widget.onOpenDsp,
        onOpenZones: widget.onOpenZones,
        onOpenAppearance: widget.onOpenAppearance,
        onOpenLibrarySettings: widget.onOpenLibrarySettings,
        onOpenProviderSettings: widget.onOpenProviderSettings,
        onOpenAlbumDetail: widget.onOpenAlbumDetail,
        onOpenSmartPlaylist: widget.onOpenSmartPlaylist,
        onOpenSmartPlaylists: widget.onOpenSmartPlaylists,
        initialScrollOffset: widget.initialScrollOffset,
        onScrollOffsetChanged: widget.onScrollOffsetChanged,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      key: const Key('home_stage_view'),
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        final slide = Tween<Offset>(
          begin: const Offset(0.0, 0.012),
          end: Offset.zero,
        ).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: slide, child: child),
        );
      },
      child: KeyedSubtree(
        key: ValueKey<HomeLayoutPreset>(widget.preset),
        child: _buildPresetView(),
      ),
    );
  }
}
