import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../services/audio_service.dart';
import '../../services/home_dashboard_data_controller.dart';
import '../../services/library_index_cache.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_glass_theme.dart';
import '../theme/smooth_scroll.dart';
import 'widgets/minimal_album_card.dart';
import 'widgets/minimal_album_row.dart' show buildWithBottomPlayerClearance;

enum _AiSegment {
  recent('ai_seg_recent', '近期'),
  favorites('ai_seg_favorites', '最愛'),
  added('ai_seg_added', '新進'),
  shuffle('ai_seg_shuffle', '隨機');

  final String keyName;
  final String label;
  const _AiSegment(this.keyName, this.label);
}

/// Preset AI「無側欄極簡」: sidebar-less full-width gallery with minimal
/// 4-segment discovery strip and a clean height-aware 2-row square album wall.
class HomeLayoutAI extends StatefulWidget {
  final AudioService audioService;
  final HomeDashboardDataController dataController;
  final LibraryIndexCache? libraryCache;
  final bool minimalCoverMode;
  final VoidCallback onOpenAlbums;
  final VoidCallback onOpenLibrary;
  final void Function(String albumId)? onOpenAlbumDetail;
  final void Function(String playlistId)? onOpenSmartPlaylist;
  final ValueChanged<double>? onScrollOffsetChanged;

  const HomeLayoutAI({
    super.key,
    required this.audioService,
    required this.dataController,
    this.libraryCache,
    this.minimalCoverMode = false,
    required this.onOpenAlbums,
    required this.onOpenLibrary,
    this.onOpenAlbumDetail,
    this.onOpenSmartPlaylist,
    this.onScrollOffsetChanged,
  });

  @override
  State<HomeLayoutAI> createState() => _HomeLayoutAIState();
}

class _HomeLayoutAIState extends State<HomeLayoutAI> {
  static const double _gap = 24.0;
  static const double _rowGap = 24.0;

  final GlideScrollController _scrollController = GlideScrollController();
  final GlideScrollController _segmentScrollController =
      GlideScrollController();
  _AiSegment _activeSegment = _AiSegment.recent;

  @override
  void dispose() {
    _scrollController.dispose();
    _segmentScrollController.dispose();
    super.dispose();
  }

  List<HomeMediaCardItem> _itemsForSegment() => switch (_activeSegment) {
    _AiSegment.recent => widget.dataController.continueListeningItems,
    _AiSegment.favorites => widget.dataController.favoriteItems,
    _AiSegment.added => widget.dataController.newlyAddedItems,
    _AiSegment.shuffle => widget.dataController.shuffledItems,
  };

  void _selectSegment(_AiSegment segment) {
    if (segment == _AiSegment.shuffle) {
      widget.dataController.reshuffleDiscovery();
    }
    if (_activeSegment != segment) {
      setState(() => _activeSegment = segment);
    }
  }

  static int _wallColumnsForWidth(double width) {
    if (width >= 1660) return 6;
    if (width >= 1160) return 5;
    if (width >= 780) return 4;
    if (width >= 540) return 3;
    return 2;
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
            final items = _itemsForSegment();

            return LayoutBuilder(
              builder: (context, outerConstraints) {
                final availW = outerConstraints.maxWidth;
                final availH = outerConstraints.maxHeight;
                final hPad = (availW * 0.055).clamp(24.0, 72.0).toDouble();
                final topPad = availW >= 900 ? 20.0 : 12.0;
                final segGap = availH.isFinite && availH < 460 ? 18.0 : 26.0;

                return NotificationListener<ScrollUpdateNotification>(
                  onNotification: (notification) {
                    if (notification.metrics.axis == Axis.vertical) {
                      widget.onScrollOffsetChanged?.call(
                        notification.metrics.pixels,
                      );
                    }
                    return false;
                  },
                  child: SmoothScrollWrapper(
                    controller: _scrollController,
                    child: SingleChildScrollView(
                      key: const Key('home_layout_ai'),
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
                          constraints: const BoxConstraints(maxWidth: 1480),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Center(child: _buildSegmentBar(glass)),
                              SizedBox(height: segGap),
                              if (items.isEmpty)
                                _buildEmptyWall(glass)
                              else
                                _buildAlbumWall(
                                  items: items,
                                  availW: availW,
                                  availH: availH,
                                  topPad: topPad,
                                  segGap: segGap,
                                  bottomClearance: bottomClearance,
                                ),
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

  Widget _buildSegmentBar(LuminaGlassTheme glass) {
    final barBg = glass.isDark ? const Color(0x47181B22) : glass.glassBgElevated;
    return FrostedGlassContainer(
      key: const Key('ai_segment_bar'),
      blurSigma: glass.glassCardBlur,
      enableBackdropBlur: false,
      borderRadius: BorderRadius.circular(999),
      color: barBg,
      border: Border.all(color: glass.glassBorderStrong),
      padding: const EdgeInsets.all(4),
      child: SingleChildScrollView(
        controller: _segmentScrollController,
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final seg in _AiSegment.values)
              _SegmentChip(
                key: Key(seg.keyName),
                label: seg.label,
                selected: _activeSegment == seg,
                glass: glass,
                onTap: () => _selectSegment(seg),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlbumWall({
    required List<HomeMediaCardItem> items,
    required double availW,
    required double availH,
    required double topPad,
    required double segGap,
    required double bottomClearance,
  }) {
    return LayoutBuilder(
      key: const Key('ai_album_wall'),
      builder: (context, constraints) {
        final innerW = constraints.maxWidth;
        final cols = _wallColumnsForWidth(availW);
        final widthCard = math.max(92.0, (innerW - _gap * (cols - 1)) / cols);
        final visible = items.take(cols * 2).toList(growable: false);
        final row1 = visible.take(cols).toList(growable: false);
        final row2 = visible.skip(cols).take(cols).toList(growable: false);

        var cardWidth = widthCard;
        if (availH.isFinite) {
          final rowCount = row2.isNotEmpty ? 2 : 1;
          final captionOverhead = widget.minimalCoverMode ? 0.0 : rowCount * 46.0;
          final verticalChrome =
              topPad + 40.0 + segGap + (row2.isNotEmpty ? _rowGap : 0.0);
          final effectiveBottom = math.max(bottomClearance, 96.0);
          final availCoversH = math.max(
            0.0,
            availH - verticalChrome - captionOverhead - effectiveBottom,
          );
          final heightCap = (availCoversH / rowCount).clamp(96.0, 280.0);
          cardWidth = math.max(88.0, math.min(widthCard, heightCap));
        }

        final gridWidth = math.min(
          innerW,
          cols * cardWidth + _gap * (cols - 1),
        );

        Widget buildRow(List<HomeMediaCardItem> rowItems) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < rowItems.length; i++)
                Padding(
                  padding: EdgeInsets.only(right: i == cols - 1 ? 0 : _gap),
                  child: SizedBox(
                    width: cardWidth,
                    child: MinimalAlbumCard(
                      key: Key('ai_album_card_${rowItems[i].id}'),
                      item: rowItems[i],
                      audioService: widget.audioService,
                      libraryCache: widget.libraryCache,
                      minimalCoverMode: widget.minimalCoverMode,
                      onOpenAlbumDetail: widget.onOpenAlbumDetail,
                      onOpenSmartPlaylist: widget.onOpenSmartPlaylist,
                      onOpenAlbums: widget.onOpenAlbums,
                      smartPlaylistEvals:
                          widget.dataController.smartPlaylistEvals,
                    ),
                  ),
                ),
            ],
          );
        }

        return Center(
          child: SizedBox(
            width: gridWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                buildRow(row1),
                if (row2.isNotEmpty) ...[
                  const SizedBox(height: _rowGap),
                  buildRow(row2),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyWall(LuminaGlassTheme glass) {
    return Padding(
      key: const Key('ai_album_wall'),
      padding: const EdgeInsets.symmetric(vertical: 72),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.album_outlined,
            size: 42,
            color: glass.emptyCoverIconColor,
          ),
          const SizedBox(height: 12),
          Text(
            '此分類目前沒有專輯項目',
            style: TextStyle(color: glass.textSecondary, fontSize: 13.5),
          ),
        ],
      ),
    );
  }
}

class _SegmentChip extends StatefulWidget {
  final String label;
  final bool selected;
  final LuminaGlassTheme glass;
  final VoidCallback onTap;

  const _SegmentChip({
    super.key,
    required this.label,
    required this.selected,
    required this.glass,
    required this.onTap,
  });

  @override
  State<_SegmentChip> createState() => _SegmentChipState();
}

class _SegmentChipState extends State<_SegmentChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final glass = widget.glass;
    final bg = widget.selected
        ? glass.glassBgActive
        : (_hovered ? glass.pillHoverBg : Colors.transparent);
    final textColor = widget.selected
        ? glass.textPrimary
        : (_hovered ? glass.textPrimary : glass.textSecondary);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: Semantics(
        button: true,
        selected: widget.selected,
        label: widget.label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: widget.selected
                    ? glass.glassBorderStrong
                    : Colors.transparent,
              ),
            ),
            child: Text(
              widget.label,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                color: textColor,
                fontSize: 13.0,
                fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
