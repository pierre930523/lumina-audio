import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../models/studio_models.dart';
import '../../../services/audio_service.dart';
import '../../../services/home_dashboard_data_controller.dart';
import '../../../services/library_index_cache.dart';
import '../../common/bottom_player_bar_scope.dart';
import '../../theme/lumina_glass_theme.dart';
import '../../theme/lumina_tokens.dart';
import 'minimal_album_card.dart';

/// Resolves reactive bottom scroll clearance above the docked or floating player.
Widget buildWithBottomPlayerClearance({
  required BuildContext context,
  required double extraPadding,
  required Widget Function(double bottomClearance) builder,
}) {
  final listenable = BottomPlayerBarScope.listenableOf(context);
  if (listenable == null) {
    return builder(math.max(LuminaTokens.bottomScrollClearance, extraPadding));
  }
  return ValueListenableBuilder<double>(
    valueListenable: listenable,
    builder: (context, barHeight, _) => builder(
      math.max(LuminaTokens.bottomScrollClearance, barHeight + extraPadding),
    ),
  );
}

/// Shared adaptive single-row square album strip rendering CSS-Grid-aligned
/// complete columns inside a strict [ClipRect] with subtle `<` / `>` paging.
class MinimalAlbumRow extends StatefulWidget {
  final List<HomeMediaCardItem> items;
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final bool minimalCoverMode;
  final void Function(String albumId)? onOpenAlbumDetail;
  final void Function(String playlistId)? onOpenSmartPlaylist;
  final VoidCallback? onOpenAlbums;
  final Map<String, SmartPlaylistEvaluation> smartPlaylistEvals;
  final double gap;

  const MinimalAlbumRow({
    super.key,
    required this.items,
    required this.audioService,
    this.libraryCache,
    this.minimalCoverMode = false,
    this.onOpenAlbumDetail,
    this.onOpenSmartPlaylist,
    this.onOpenAlbums,
    this.smartPlaylistEvals = const {},
    this.gap = 20.0,
  });

  static int resolveColumns(double width) {
    if (width >= 1360) return 6;
    if (width >= 1040) return 5;
    if (width >= 760) return 4;
    if (width >= 500) return 3;
    return 2;
  }

  @override
  State<MinimalAlbumRow> createState() => _MinimalAlbumRowState();
}

class _MinimalAlbumRowState extends State<MinimalAlbumRow> {
  static const double _clipPadH = 4.0;
  int _page = 0;

  @override
  void didUpdateWidget(covariant MinimalAlbumRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length && _page > 0) {
      if (widget.items.isEmpty || _page >= widget.items.length) {
        _page = 0;
      }
    }
  }

  Widget _buildPageButton({
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required LuminaGlassTheme glass,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: glass.pillBg,
        shape: CircleBorder(
          side: BorderSide(
            color: enabled
                ? glass.glassBorder
                : glass.glassBorder.withValues(alpha: 0.4),
          ),
        ),
        child: InkWell(
          customBorder: const CircleBorder(),
          hoverColor: glass.pillHoverBg,
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: 28,
            height: 28,
            child: Icon(
              icon,
              size: 17,
              color: enabled ? glass.textSecondary : glass.textDisabled,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final availW = constraints.maxWidth;
        final innerW = math.max(96.0, availW - _clipPadH * 2);
        final cols = MinimalAlbumRow.resolveColumns(innerW);
        final cardWidth =
            math.max(88.0, (innerW - widget.gap * (cols - 1)) / cols);
        final maxPage =
            widget.items.isEmpty ? 0 : ((widget.items.length - 1) ~/ cols);
        final safePage = _page.clamp(0, maxPage);
        if (safePage != _page) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _page != safePage) setState(() => _page = safePage);
          });
        }
        final visible =
            widget.items.skip(safePage * cols).take(cols).toList(growable: false);

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ClipRect(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(_clipPadH, 10, _clipPadH, 16),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: Row(
                    key: ValueKey<String>('row_p${safePage}_c$cols'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < visible.length; i++)
                        Padding(
                          padding: EdgeInsets.only(
                            right: i == visible.length - 1 ? 0 : widget.gap,
                          ),
                          child: SizedBox(
                            width: cardWidth,
                            child: MinimalAlbumCard(
                              key: Key('minimal_album_card_${visible[i].id}'),
                              item: visible[i],
                              audioService: widget.audioService,
                              libraryCache: widget.libraryCache,
                              minimalCoverMode: widget.minimalCoverMode,
                              onOpenAlbumDetail: widget.onOpenAlbumDetail,
                              onOpenSmartPlaylist: widget.onOpenSmartPlaylist,
                              onOpenAlbums: widget.onOpenAlbums,
                              smartPlaylistEvals: widget.smartPlaylistEvals,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (widget.items.length > cols)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _buildPageButton(
                      icon: Icons.chevron_left_rounded,
                      tooltip: '上一頁',
                      enabled: safePage > 0,
                      glass: glass,
                      onTap: () =>
                          setState(() => _page = math.max(0, safePage - 1)),
                    ),
                    const SizedBox(width: 8),
                    _buildPageButton(
                      icon: Icons.chevron_right_rounded,
                      tooltip: '下一頁',
                      enabled: safePage < maxPage,
                      glass: glass,
                      onTap: () => setState(
                        () => _page = math.min(maxPage, safePage + 1),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
