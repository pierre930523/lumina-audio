import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../artwork/album_artwork_view.dart';
import '../theme/lumina_tokens.dart';

Future<void> _showAlbumContextMenu({
  required BuildContext buttonContext,
  required VoidCallback onPlayAlbum,
  VoidCallback? onAddToQueue,
  required VoidCallback onOpenAlbumDetail,
  VoidCallback? onOpenArtist,
}) async {
  final overlayBox =
      Overlay.maybeOf(buttonContext)?.context.findRenderObject() as RenderBox?;
  final buttonBox = buttonContext.findRenderObject() as RenderBox?;
  if (overlayBox == null || buttonBox == null) return;
  final position = RelativeRect.fromRect(
    Rect.fromPoints(
      buttonBox.localToGlobal(Offset.zero, ancestor: overlayBox),
      buttonBox.localToGlobal(
        buttonBox.size.bottomRight(Offset.zero),
        ancestor: overlayBox,
      ),
    ),
    Offset.zero & overlayBox.size,
  );
  final action = await showMenu<String>(
    context: buttonContext,
    position: position,
    color: LuminaTokens.cardElevatedBg,
    elevation: 12,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
      side: const BorderSide(color: LuminaTokens.borderSubtle),
    ),
    items: [
      _buildAlbumMenuItem('play', Icons.play_arrow_rounded, '播放專輯'),
      _buildAlbumMenuItem('queue', Icons.playlist_add_rounded, '加入播放佇列'),
      _buildAlbumMenuItem('detail', Icons.album_rounded, '檢視專輯詳情'),
      _buildAlbumMenuItem('artist', Icons.person_rounded, '前往藝術家'),
    ],
  );
  switch (action) {
    case 'play':
      onPlayAlbum();
    case 'queue':
      onAddToQueue?.call();
    case 'detail':
      onOpenAlbumDetail();
    case 'artist':
      onOpenArtist?.call();
  }
}

PopupMenuItem<String> _buildAlbumMenuItem(
  String value,
  IconData icon,
  String label,
) {
  return PopupMenuItem<String>(
    value: value,
    height: 38,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 17, color: LuminaTokens.textSecondary),
        const SizedBox(width: 10),
        Text(
          label,
          style: const TextStyle(
            color: LuminaTokens.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    ),
  );
}

String _albumSubtitle(CanonicalAlbumSummary album) {
  return album.year != null ? '${album.artist} (${album.year})' : album.artist;
}

/// Apple Music-inspired album grid card with frameless minimalist default,
/// lazy-mounted GPU-composited cover hover FX, and isolated per-card state.
class AlbumCollectionCard extends StatefulWidget {
  final CanonicalAlbumSummary album;
  final int coverRevision;
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final bool showCardContainer;
  final VoidCallback onOpenAlbumDetail;
  final VoidCallback onPlayAlbum;
  final VoidCallback? onAddToQueue;
  final VoidCallback? onOpenArtist;

  const AlbumCollectionCard({
    super.key,
    required this.album,
    required this.audioService,
    this.libraryCache,
    this.coverRevision = 0,
    this.showCardContainer = false,
    required this.onOpenAlbumDetail,
    required this.onPlayAlbum,
    this.onAddToQueue,
    this.onOpenArtist,
  });

  @override
  State<AlbumCollectionCard> createState() => _AlbumCollectionCardState();
}

class _AlbumCollectionCardState extends State<AlbumCollectionCard>
    with TickerProviderStateMixin {
  static const Duration _hoverDuration = Duration(milliseconds: 220);
  static const Duration _playHoverDuration = Duration(milliseconds: 180);
  static const Curve _appleCurve = Cubic(0.2, 0.8, 0.2, 1.0);
  static const BorderRadius _coverRadius = BorderRadius.all(
    Radius.circular(LuminaTokens.radiusSm),
  );

  late final AnimationController _hoverController;
  late final CurvedAnimation _hoverCurve;
  late final Animation<double> _coverScaleAnimation;
  late final Animation<double> _glowOpacityAnimation;
  late final Animation<double> _buttonSlideAnimation;

  late final AnimationController _playHoverController;
  late final CurvedAnimation _playHoverCurve;
  late final Animation<double> _playScaleAnimation;

  bool _coverHovered = false;
  bool _playHovered = false;
  bool _moreHovered = false;
  bool _menuOpen = false;
  bool _overlayMounted = false;

  String? _resolvedCachePath;
  String? _resolvedCoverUrl;

  @override
  void initState() {
    super.initState();
    _hoverController = AnimationController(
      vsync: this,
      duration: _hoverDuration,
    )..addStatusListener(_handleHoverStatusChanged);
    _hoverCurve = CurvedAnimation(
      parent: _hoverController,
      curve: _appleCurve,
    );
    _coverScaleAnimation = Tween<double>(
      begin: 1.0,
      end: 1.02,
    ).animate(_hoverCurve);
    _glowOpacityAnimation = Tween<double>(
      begin: 0.0,
      end: 0.58,
    ).animate(_hoverCurve);
    _buttonSlideAnimation = Tween<double>(
      begin: 5.0,
      end: 0.0,
    ).animate(_hoverCurve);

    _playHoverController = AnimationController(
      vsync: this,
      duration: _playHoverDuration,
    );
    _playHoverCurve = CurvedAnimation(
      parent: _playHoverController,
      curve: _appleCurve,
    );
    _playScaleAnimation = Tween<double>(
      begin: 1.0,
      end: 1.08,
    ).animate(_playHoverCurve);
  }

  @override
  void didUpdateWidget(covariant AlbumCollectionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.album.id != widget.album.id ||
        oldWidget.album.coverUrl != widget.album.coverUrl ||
        oldWidget.coverRevision != widget.coverRevision) {
      _resolvedCachePath = null;
      _resolvedCoverUrl = null;
    }
  }

  @override
  void dispose() {
    _hoverController.removeStatusListener(_handleHoverStatusChanged);
    _hoverCurve.dispose();
    _hoverController.dispose();
    _playHoverCurve.dispose();
    _playHoverController.dispose();
    super.dispose();
  }

  void _handleHoverStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.dismissed &&
        !_coverHovered &&
        !_menuOpen &&
        _overlayMounted) {
      if (!mounted) return;
      setState(() {
        _overlayMounted = false;
        _playHovered = false;
        _moreHovered = false;
      });
      _playHoverController.reset();
    }
  }

  void _handleArtworkResolved(String? cachePath, String? coverUrl) {
    if (_resolvedCachePath == cachePath && _resolvedCoverUrl == coverUrl) {
      return;
    }
    _resolvedCachePath = cachePath;
    _resolvedCoverUrl = coverUrl;
    if (_overlayMounted && mounted) {
      setState(() {});
    }
  }

  void _onCoverHoverEnter() {
    if (_coverHovered && _overlayMounted) return;
    setState(() {
      _coverHovered = true;
      _overlayMounted = true;
    });
    _hoverController.forward();
  }

  void _onCoverHoverExit() {
    if (!_coverHovered) return;
    _coverHovered = false;
    if (_playHovered) {
      _playHovered = false;
      _playHoverController.reverse();
    }
    if (_moreHovered) {
      setState(() => _moreHovered = false);
    }
    if (!_menuOpen) {
      _hoverController.reverse();
    }
  }

  void _setPlayHovered(bool hovered) {
    if (_playHovered == hovered) return;
    _playHovered = hovered;
    if (hovered) {
      _playHoverController.forward();
    } else {
      _playHoverController.reverse();
    }
  }

  Future<void> _openMoreMenu(BuildContext btnCtx) async {
    _menuOpen = true;
    await _showAlbumContextMenu(
      buttonContext: btnCtx,
      onPlayAlbum: widget.onPlayAlbum,
      onAddToQueue: widget.onAddToQueue,
      onOpenAlbumDetail: widget.onOpenAlbumDetail,
      onOpenArtist: widget.onOpenArtist,
    );
    _menuOpen = false;
    if (!mounted) return;
    if (!_coverHovered) {
      _hoverController.reverse();
    }
  }

  Widget _buildFallbackGlowBox(double side) {
    return Container(
      width: side,
      height: side,
      decoration: const BoxDecoration(
        borderRadius: _coverRadius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF285E8E),
            Color(0xFF5B52F2),
            Color(0xFF1A2542),
          ],
        ),
      ),
    );
  }

  Widget _buildGlowSource(double side) {
    final cachePath = _resolvedCachePath;
    if (cachePath != null && cachePath.isNotEmpty) {
      return Image.file(
        File(cachePath),
        width: side,
        height: side,
        fit: BoxFit.cover,
        cacheWidth: 32,
        cacheHeight: 32,
        filterQuality: FilterQuality.low,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _buildFallbackGlowBox(side),
      );
    }
    final coverUrl = _resolvedCoverUrl;
    if (coverUrl != null && coverUrl.isNotEmpty) {
      return Image.network(
        coverUrl,
        width: side,
        height: side,
        fit: BoxFit.cover,
        cacheWidth: 32,
        cacheHeight: 32,
        filterQuality: FilterQuality.low,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _buildFallbackGlowBox(side),
      );
    }
    return _buildFallbackGlowBox(side);
  }

  Widget _buildActionEntrance({required Widget child}) {
    return FadeTransition(
      opacity: _hoverCurve,
      child: AnimatedBuilder(
        animation: _buttonSlideAnimation,
        builder: (context, child) {
          return Transform.translate(
            offset: Offset(0, _buttonSlideAnimation.value),
            child: child,
          );
        },
        child: child,
      ),
    );
  }

  Widget _buildPlayButton() {
    return Tooltip(
      message: '播放專輯',
      child: Semantics(
        button: true,
        label: '播放專輯 ${widget.album.title}',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => _setPlayHovered(true),
          onExit: (_) => _setPlayHovered(false),
          child: GestureDetector(
            key: Key('album_card_play_${widget.album.id}'),
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPlayAlbum,
            child: ScaleTransition(
              scale: _playScaleAnimation,
              child: ClipOval(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: AnimatedBuilder(
                    animation: _playHoverCurve,
                    builder: (context, _) {
                      final t = _playHoverCurve.value;
                      final bgColor = Color.lerp(
                        const Color(0x991C1E26),
                        LuminaTokens.accentBlue,
                        t,
                      )!;
                      final borderColor = Color.lerp(
                        Colors.white.withValues(alpha: 0.22),
                        LuminaTokens.accentBlue,
                        t,
                      )!;
                      final iconColor = t >= 0.5
                          ? LuminaTokens.onAccentDark
                          : Colors.white;
                      return Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: bgColor,
                          border: Border.all(color: borderColor, width: 1.0),
                        ),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          size: 20,
                          color: iconColor,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMoreButton() {
    return Tooltip(
      message: '更多選項',
      child: Semantics(
        button: true,
        label: '更多選項 ${widget.album.title}',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _moreHovered = true),
          onExit: (_) => setState(() => _moreHovered = false),
          child: Builder(
            builder: (btnCtx) => GestureDetector(
              key: Key('album_card_more_${widget.album.id}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => _openMoreMenu(btnCtx),
              child: ClipOval(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _moreHovered
                          ? const Color(0xCC282C38)
                          : const Color(0x991C1E26),
                      border: Border.all(
                        color: Colors.white.withValues(
                          alpha: _moreHovered ? 0.36 : 0.22,
                        ),
                        width: 1.0,
                      ),
                    ),
                    child: const Icon(
                      Icons.more_horiz_rounded,
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCoverArea(double side) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _onCoverHoverEnter(),
      onExit: (_) => _onCoverHoverExit(),
      child: SizedBox(
        width: side,
        height: side,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (_overlayMounted)
              Positioned.fill(
                key: const ValueKey('album_ambient_glow'),
                child: IgnorePointer(
                  child: FadeTransition(
                    opacity: _glowOpacityAnimation,
                    child: Transform.translate(
                      offset: const Offset(0, 6),
                      child: Transform.scale(
                        scale: 1.08,
                        child: ImageFiltered(
                          imageFilter: ui.ImageFilter.blur(
                            sigmaX: 16,
                            sigmaY: 16,
                            tileMode: TileMode.decal,
                          ),
                          child: _buildGlowSource(side),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (_overlayMounted)
              Positioned.fill(
                key: const ValueKey('album_depth_shadow'),
                child: IgnorePointer(
                  child: ScaleTransition(
                    scale: _coverScaleAnimation,
                    child: FadeTransition(
                      opacity: _hoverCurve,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: _coverRadius,
                          boxShadow: [
                            BoxShadow(
                              color: Color(0x88000000),
                              blurRadius: 24,
                              offset: Offset(0, 10),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ScaleTransition(
              key: const ValueKey('album_cover_foreground'),
              scale: _coverScaleAnimation,
              child: SizedBox(
                width: side,
                height: side,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    AlbumArtworkView(
                      album: widget.album,
                      size: side,
                      revision: widget.coverRevision,
                      audioService: widget.audioService,
                      libraryCache: widget.libraryCache,
                      fullResolution: false,
                      borderRadius: _coverRadius,
                      fit: BoxFit.cover,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                        width: 1.0,
                      ),
                      boxShadow: const [],
                      onArtworkResolved: _handleArtworkResolved,
                    ),
                    if (_overlayMounted)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: ClipRRect(
                            borderRadius: _coverRadius,
                            child: FadeTransition(
                              opacity: _hoverCurve,
                              child: const DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    stops: [0.35, 1.0],
                                    colors: [
                                      Colors.transparent,
                                      Color(0xB3080A0F),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (_overlayMounted) ...[
                      Positioned(
                        left: 10,
                        bottom: 10,
                        child: _buildActionEntrance(child: _buildPlayButton()),
                      ),
                      Positioned(
                        right: 10,
                        bottom: 10,
                        child: _buildActionEntrance(child: _buildMoreButton()),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    final content = LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 180.0;
        final maxH = constraints.maxHeight;
        final textReserve = 54.0;
        final coverSide = maxH.isFinite
            ? math.max(48.0, math.min(maxW, maxH - textReserve))
            : maxW;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildCoverArea(coverSide),
            const SizedBox(height: 10),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Text(
                album.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: LuminaTokens.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                ),
              ),
            ),
            const SizedBox(height: 2),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Text(
                _albumSubtitle(album),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: LuminaTokens.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        );
      },
    );

    final wrappedContainer = widget.showCardContainer
        ? Container(
            key: Key('album_surface_${album.id}'),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: LuminaTokens.cardBg,
              borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
              border: Border.all(color: LuminaTokens.borderSubtle),
            ),
            child: content,
          )
        : Container(
            key: Key('album_surface_${album.id}'),
            color: Colors.transparent,
            padding: EdgeInsets.zero,
            child: content,
          );

    return RepaintBoundary(
      child: Semantics(
        button: true,
        label: '${album.title} ${album.artist}',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onOpenAlbumDetail,
          child: wrappedContainer,
        ),
      ),
    );
  }
}

/// Horizontal row representation of an album for List view mode.
class AlbumCollectionListTile extends StatefulWidget {
  final CanonicalAlbumSummary album;
  final int coverRevision;
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final bool showCardContainer;
  final VoidCallback onOpenAlbumDetail;
  final VoidCallback onPlayAlbum;
  final VoidCallback? onAddToQueue;
  final VoidCallback? onOpenArtist;

  const AlbumCollectionListTile({
    super.key,
    required this.album,
    required this.audioService,
    this.libraryCache,
    this.coverRevision = 0,
    this.showCardContainer = false,
    required this.onOpenAlbumDetail,
    required this.onPlayAlbum,
    this.onAddToQueue,
    this.onOpenArtist,
  });

  @override
  State<AlbumCollectionListTile> createState() =>
      _AlbumCollectionListTileState();
}

class _AlbumCollectionListTileState extends State<AlbumCollectionListTile> {
  bool _playHovered = false;
  bool _moreHovered = false;

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    final rowContent = Row(
      children: [
        Expanded(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onOpenAlbumDetail,
              child: Row(
                children: [
                  AlbumArtworkView(
                    album: album,
                    size: 56,
                    revision: widget.coverRevision,
                    audioService: widget.audioService,
                    libraryCache: widget.libraryCache,
                    fullResolution: false,
                    borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                    fit: BoxFit.cover,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                      width: 1.0,
                    ),
                    boxShadow: const [],
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          album.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: LuminaTokens.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _albumSubtitle(album),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: LuminaTokens.textSecondary,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Tooltip(
          message: '播放專輯',
          child: Semantics(
            button: true,
            label: '播放專輯 ${album.title}',
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _playHovered = true),
              onExit: (_) => setState(() => _playHovered = false),
              child: GestureDetector(
                key: Key('album_card_play_${album.id}'),
                behavior: HitTestBehavior.opaque,
                onTap: widget.onPlayAlbum,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _playHovered
                        ? LuminaTokens.accentBlue
                        : LuminaTokens.cardElevatedBg,
                    border: Border.all(
                      color: _playHovered
                          ? LuminaTokens.accentBlue
                          : LuminaTokens.borderControl,
                    ),
                  ),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    size: 19,
                    color: _playHovered
                        ? LuminaTokens.onAccentDark
                        : LuminaTokens.textPrimary,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: '更多選項',
          child: Semantics(
            button: true,
            label: '更多選項 ${album.title}',
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _moreHovered = true),
              onExit: (_) => setState(() => _moreHovered = false),
              child: Builder(
                builder: (btnCtx) => GestureDetector(
                  key: Key('album_card_more_${album.id}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _showAlbumContextMenu(
                    buttonContext: btnCtx,
                    onPlayAlbum: widget.onPlayAlbum,
                    onAddToQueue: widget.onAddToQueue,
                    onOpenAlbumDetail: widget.onOpenAlbumDetail,
                    onOpenArtist: widget.onOpenArtist,
                  ),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _moreHovered
                          ? LuminaTokens.cardHoverBg
                          : LuminaTokens.cardElevatedBg,
                      border: Border.all(color: LuminaTokens.borderControl),
                    ),
                    child: const Icon(
                      Icons.more_horiz_rounded,
                      size: 18,
                      color: LuminaTokens.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );

    return RepaintBoundary(
      child: widget.showCardContainer
          ? Container(
              key: Key('album_surface_${album.id}'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: LuminaTokens.cardBg,
                borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
                border: Border.all(color: LuminaTokens.borderSubtle),
              ),
              child: rowContent,
            )
          : Container(
              key: Key('album_surface_${album.id}'),
              color: Colors.transparent,
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: rowContent,
            ),
    );
  }
}
