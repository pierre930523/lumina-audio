import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../../services/artwork_palette_service.dart';
import '../../services/audio_service.dart';
import '../../services/home_dashboard_data_controller.dart';
import '../../services/library_index_cache.dart';
import '../artwork/album_artwork_view.dart';
import '../common/frosted_glass_container.dart';
import '../common/track_context_menu.dart';
import '../common/track_hover_prefetch.dart';
import '../theme/lumina_glass_theme.dart';
import '../theme/smooth_scroll.dart';
import 'widgets/minimal_album_card.dart';
import 'widgets/minimal_album_row.dart'
    show MinimalAlbumRow, buildWithBottomPlayerClearance;

/// Preset AJ「光暈快速續播」: 2x3 frameless quick-resume shortcut grid and a
/// clean single-row discovery showcase floating directly over the full-viewport
/// [TopAmbientAura] backdrop.
class HomeLayoutAJ extends StatefulWidget {
  final AudioService audioService;
  final HomeDashboardDataController dataController;
  final LibraryIndexCache? libraryCache;
  final ArtworkPaletteService? paletteService;
  final bool auraFollowCover;
  final bool minimalCoverMode;
  final double topInset;
  final VoidCallback onOpenAlbums;
  final VoidCallback onOpenLibrary;
  final void Function(String albumId)? onOpenAlbumDetail;
  final void Function(String playlistId)? onOpenSmartPlaylist;
  final ValueChanged<double>? onScrollOffsetChanged;

  const HomeLayoutAJ({
    super.key,
    required this.audioService,
    required this.dataController,
    this.libraryCache,
    this.paletteService,
    this.auraFollowCover = true,
    this.minimalCoverMode = false,
    this.topInset = 0.0,
    required this.onOpenAlbums,
    required this.onOpenLibrary,
    this.onOpenAlbumDetail,
    this.onOpenSmartPlaylist,
    this.onScrollOffsetChanged,
  });

  @override
  State<HomeLayoutAJ> createState() => _HomeLayoutAJState();
}

class _HomeLayoutAJState extends State<HomeLayoutAJ> {
  final GlideScrollController _scrollController = GlideScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  List<HomeMediaCardItem> _buildExploreItems() {
    final seen = <String>{};
    final result = <HomeMediaCardItem>[];
    for (final item in [
      ...widget.dataController.newlyAddedItems,
      ...widget.dataController.shuffledItems,
    ]) {
      final key = item.album?.id ?? item.track?.id ?? item.id;
      if (seen.add(key)) result.add(item);
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);

    return buildWithBottomPlayerClearance(
      context: context,
      extraPadding: 24.0,
      builder: (bottomClearance) {
        return ListenableBuilder(
          listenable: widget.dataController,
          builder: (context, _) {
            final quickItems = widget.dataController.quickResumeItems;
            final exploreItems = _buildExploreItems();
            return LayoutBuilder(
              builder: (context, outerConstraints) {
                final availW = outerConstraints.maxWidth;
                final hPad = (availW * 0.036).clamp(16.0, 44.0).toDouble();
                final topPad = widget.topInset + (availW >= 900 ? 24.0 : 14.0);
                return NotificationListener<ScrollUpdateNotification>(
                  onNotification: (n) {
                    if (n.metrics.axis == Axis.vertical) {
                      widget.onScrollOffsetChanged?.call(n.metrics.pixels);
                    }
                    return false;
                  },
                  child: SmoothScrollWrapper(
                    controller: _scrollController,
                    child: SingleChildScrollView(
                      key: const Key('home_layout_aj'),
                      controller: _scrollController,
                      padding: EdgeInsets.fromLTRB(
                        hPad,
                        topPad,
                        hPad,
                        bottomClearance,
                      ),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1680),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildQuickResumeSection(glass, quickItems),
                              const SizedBox(height: 36),
                              _buildExploreSection(glass, exploreItems),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildQuickResumeSection(
    LuminaGlassTheme glass,
    List<HomeQuickResumeItem> items,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '快速續播',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: glass.textPrimary,
            fontSize: 19.0,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.25,
          ),
        ),
        const SizedBox(height: 14),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Text(
              '點擊曲目或專輯即可在此快速繼續聆聽',
              style: TextStyle(color: glass.textSecondary, fontSize: 13),
            ),
          )
        else
          LayoutBuilder(
            key: const Key('aj_quick_resume_grid'),
            builder: (context, constraints) {
              final innerW = constraints.maxWidth;
              final cols = innerW >= 880 ? 3 : (innerW >= 520 ? 2 : 1);
              const gap = 14.0;
              final cardWidth = math.max(
                140.0,
                (innerW - gap * (cols - 1)) / cols,
              );
              final visible = items.take(6).toList(growable: false);
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (var i = 0; i < visible.length; i++)
                    SizedBox(
                      width: cardWidth,
                      child: _QuickResumeCard(
                        key: Key('aj_quick_card_$i'),
                        item: visible[i],
                        audioService: widget.audioService,
                        libraryCache: widget.libraryCache,
                        smartPlaylistEvals:
                            widget.dataController.smartPlaylistEvals,
                      ),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }

  Widget _buildExploreSection(
    LuminaGlassTheme glass,
    List<HomeMediaCardItem> items,
  ) {
    return Column(
      key: const Key('aj_explore_row'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                '為你挑選',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: glass.textPrimary,
                  fontSize: 19.0,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.25,
                ),
              ),
            ),
            if (items.isNotEmpty)
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onOpenAlbums,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    child: Text(
                      '全部 >',
                      style: TextStyle(
                        color: glass.textTertiary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: widget.onOpenLibrary,
                child: Text('前往曲目庫新增專輯', style: TextStyle(color: glass.accent)),
              ),
            ),
          )
        else
          MinimalAlbumRow(
            items: items,
            audioService: widget.audioService,
            libraryCache: widget.libraryCache,
            minimalCoverMode: widget.minimalCoverMode,
            onOpenAlbumDetail: widget.onOpenAlbumDetail,
            onOpenSmartPlaylist: widget.onOpenSmartPlaylist,
            onOpenAlbums: widget.onOpenAlbums,
            smartPlaylistEvals: widget.dataController.smartPlaylistEvals,
            gap: 20.0,
          ),
      ],
    );
  }
}

class _QuickResumeCard extends StatefulWidget {
  final HomeQuickResumeItem item;
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final Map<String, SmartPlaylistEvaluation> smartPlaylistEvals;

  const _QuickResumeCard({
    super.key,
    required this.item,
    required this.audioService,
    this.libraryCache,
    this.smartPlaylistEvals = const {},
  });

  @override
  State<_QuickResumeCard> createState() => _QuickResumeCardState();
}

class _QuickResumeCardState extends State<_QuickResumeCard> {
  static const Duration _hoverDuration = Duration(milliseconds: 180);
  static const Curve _hoverCurve = Curves.easeOutCubic;

  bool _hovered = false;
  bool _focused = false;

  bool get _showPlay => _hovered || _focused;

  void _resumeImmediately() {
    unawaited(
      playQuickResumeItem(
        context: context,
        audioService: widget.audioService,
        item: widget.item,
        libraryCache: widget.libraryCache,
        smartPlaylistEvals: widget.smartPlaylistEvals,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);
    final item = widget.item;
    final track = item.track;
    final radius = BorderRadius.circular(12);

    final card = RepaintBoundary(
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (h) {
          if (_hovered != h) setState(() => _hovered = h);
        },
        onShowFocusHighlight: (f) {
          if (_focused != f) setState(() => _focused = f);
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _resumeImmediately();
              return null;
            },
          ),
        },
        child: Semantics(
          button: true,
          label: '繼續播放 ${item.title} ${item.sourceLabel}',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _resumeImmediately,
            onSecondaryTapUp: track != null
                ? (d) => showTrackContextMenu(
                    context: context,
                    audioService: widget.audioService,
                    track: track,
                    globalPosition: d.globalPosition,
                    libraryCache: widget.libraryCache,
                  )
                : null,
            child: AnimatedScale(
              scale: _hovered ? 1.015 : 1.0,
              duration: _hoverDuration,
              curve: _hoverCurve,
              child: FrostedGlassContainer(
                height: 70.0,
                blurSigma: glass.glassCardBlur,
                enableBackdropBlur: false,
                borderRadius: radius,
                color: _showPlay ? glass.glassBgHover : glass.glassBg,
                boxShadow: glass.glassShadow,
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 9),
                child: Row(
                  children: [
                    AspectRatio(
                      aspectRatio: 1,
                      child: AlbumArtworkView(
                        track: track,
                        album: item.album,
                        size: 52.0,
                        audioService: widget.audioService,
                        libraryCache: widget.libraryCache,
                        fullResolution: false,
                        frameless: true,
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: const [],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: glass.textPrimary,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              height: 1.22,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            item.sourceLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: glass.textSecondary,
                              fontSize: 11.5,
                              height: 1.22,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    AnimatedOpacity(
                      opacity: _showPlay ? 1.0 : 0.0,
                      duration: _hoverDuration,
                      curve: _hoverCurve,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: glass.pillHoverBg,
                          border: Border.all(color: glass.glassBorderStrong),
                        ),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          size: 18,
                          color: glass.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return TrackHoverPrefetch(
      track: track,
      enabled: track != null,
      child: card,
    );
  }
}
