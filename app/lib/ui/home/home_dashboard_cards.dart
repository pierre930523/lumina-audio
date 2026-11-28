part of 'home_dashboard_view.dart';

class _RecommendedPlaylistCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final List<Color> colors;
  final IconData icon;
  final TrackInfo? coverTrack;
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final VoidCallback onOpen;
  final VoidCallback onPlay;

  const _RecommendedPlaylistCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.colors,
    required this.icon,
    required this.coverTrack,
    required this.audioService,
    required this.libraryCache,
    required this.onOpen,
    required this.onPlay,
  });

  @override
  State<_RecommendedPlaylistCard> createState() =>
      _RecommendedPlaylistCardState();
}

class _RecommendedPlaylistCardState extends State<_RecommendedPlaylistCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(12);
    return RepaintBoundary(
      child: ScrollCardEntrance(
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) {
            if (!_hovered) setState(() => _hovered = true);
          },
          onExit: (_) {
            if (_hovered) setState(() => _hovered = false);
          },
          child: Semantics(
            button: true,
            label: '${widget.title} ${widget.subtitle}',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onOpen,
              child: AnimatedContainer(
                duration: LuminaTokens.hoverDuration,
                curve: LuminaTokens.motionCurve,
                transform: Matrix4.translationValues(
                  0.0,
                  _hovered ? -3.0 : 0.0,
                  0.0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AspectRatio(
                      aspectRatio: 16 / 10,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: radius,
                          boxShadow: [
                            BoxShadow(
                              color: _hovered
                                  ? const Color(0x73000000)
                                  : const Color(0x59000000),
                              blurRadius: _hovered ? 24 : 18,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: radius,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              AlbumArtworkView(
                                track: widget.coverTrack,
                                size: 240,
                                fullResolution: false,
                                audioService: widget.audioService,
                                libraryCache: widget.libraryCache,
                                borderRadius: radius,
                                border: Border.all(
                                  color: _hovered
                                      ? LuminaTokens.glassCoverRim
                                      : LuminaTokens.glassPillBorder,
                                ),
                                boxShadow: const [],
                                placeholder: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: radius,
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: widget.colors,
                                    ),
                                  ),
                                  child: Center(
                                    child: Icon(
                                      widget.icon,
                                      size: 36,
                                      color: Colors.white.withValues(alpha: 0.36),
                                    ),
                                  ),
                                ),
                              ),
                              IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.transparent,
                                        Colors.black.withValues(alpha: 0.45),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                right: 8,
                                bottom: 8,
                                child: Tooltip(
                                  message: '播放 ${widget.title}',
                                  child: Semantics(
                                    button: true,
                                    label: '播放 ${widget.title}',
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: widget.onPlay,
                                      child: AnimatedContainer(
                                        duration: LuminaTokens.focusDuration,
                                        width: 32,
                                        height: 32,
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(
                                            alpha: _hovered ? 0.68 : 0.48,
                                          ),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: _hovered
                                                ? LuminaTokens.glassCoverRim
                                                : LuminaTokens.glassPillBorder,
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.play_arrow_rounded,
                                          size: 19,
                                          color: LuminaTokens.glassTextPrimary,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.glassTextPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.glassTextSecondary,
                        fontSize: 12,
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
  }
}

class _RecentAlbumCard extends StatefulWidget {
  final _RecentItem item;
  final CanonicalAlbumSummary? album;
  final List<Color> palette;
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final bool showTrackArtwork;
  final VoidCallback onOpenAlbum;
  final VoidCallback? onPlayTrack;

  const _RecentAlbumCard({
    super.key,
    required this.item,
    required this.album,
    required this.palette,
    required this.audioService,
    required this.libraryCache,
    required this.showTrackArtwork,
    required this.onOpenAlbum,
    this.onPlayTrack,
  });

  @override
  State<_RecentAlbumCard> createState() => _RecentAlbumCardState();
}

class _RecentAlbumCardState extends State<_RecentAlbumCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final album = widget.album;
    final coverRadius = BorderRadius.circular(12);

    return RepaintBoundary(
      child: ScrollCardEntrance(
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) {
            if (!_hovered) setState(() => _hovered = true);
          },
          onExit: (_) {
            if (_hovered) setState(() => _hovered = false);
          },
          child: Semantics(
            button: true,
            label: '${item.title} ${item.subtitle}',
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onOpenAlbum,
              child: AnimatedContainer(
                duration: LuminaTokens.hoverDuration,
                curve: LuminaTokens.motionCurve,
                transform: Matrix4.translationValues(
                  0.0,
                  _hovered ? -4.0 : 0.0,
                  0.0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AspectRatio(
                      aspectRatio: 1,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 280),
                        child: LayoutBuilder(
                          builder: (context, artConstraints) {
                            final side = math.min(
                              artConstraints.maxWidth,
                              artConstraints.maxHeight,
                            );
                            final artSize = (side.isFinite && side > 0)
                                ? side
                                : 180.0;
                            return Container(
                              decoration: BoxDecoration(
                                borderRadius: coverRadius,
                                boxShadow: [
                                  BoxShadow(
                                    color: _hovered
                                        ? const Color(0x73000000)
                                        : const Color(0x59000000),
                                    blurRadius: _hovered ? 28 : 24,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  AlbumArtworkView(
                                    track: widget.showTrackArtwork
                                        ? item.track
                                        : null,
                                    album: album,
                                    size: artSize,
                                    audioService: widget.audioService,
                                    libraryCache: widget.libraryCache,
                                    fullResolution: false,
                                    borderRadius: coverRadius,
                                    border: Border.all(
                                      color: _hovered
                                          ? LuminaTokens.glassCoverRim
                                          : LuminaTokens.glassPillBorder,
                                    ),
                                    boxShadow: const [],
                                    placeholder: Container(
                                      decoration: BoxDecoration(
                                        borderRadius: coverRadius,
                                        gradient: LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: widget.palette,
                                        ),
                                      ),
                                      child: Center(
                                        child: Icon(
                                          Icons.album_rounded,
                                          size: 56,
                                          color: Colors.white.withValues(
                                            alpha: 0.34,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    right: 8,
                                    bottom: 8,
                                    child: Tooltip(
                                      message: '播放 ${item.title}',
                                      child: Semantics(
                                        button: true,
                                        label: '播放 ${item.title}',
                                        child: MouseRegion(
                                          cursor: SystemMouseCursors.click,
                                          child: GestureDetector(
                                            behavior: HitTestBehavior.opaque,
                                            onTap:
                                                widget.onPlayTrack ??
                                                widget.onOpenAlbum,
                                            child: AnimatedOpacity(
                                              duration:
                                                  LuminaTokens.focusDuration,
                                              opacity: _hovered ? 1.0 : 0.78,
                                              child: Container(
                                                width: 32,
                                                height: 32,
                                                decoration: BoxDecoration(
                                                  color: Colors.black.withValues(
                                                    alpha: _hovered ? 0.68 : 0.48,
                                                  ),
                                                  shape: BoxShape.circle,
                                                  border: Border.all(
                                                    color: _hovered
                                                        ? LuminaTokens
                                                              .glassCoverRim
                                                        : LuminaTokens
                                                              .glassPillBorder,
                                                  ),
                                                ),
                                                child: const Icon(
                                                  Icons.play_arrow_rounded,
                                                  size: 19,
                                                  color: LuminaTokens
                                                      .glassTextPrimary,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.glassTextPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.glassTextSecondary,
                        fontSize: 12,
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
  }
}
