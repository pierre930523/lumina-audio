part of 'artist_detail_page.dart';

// ─── Hover-Isolated Artist Track Row ──────────────────────────────────────────

class _ArtistTrackRow extends StatefulWidget {
  final int index;
  final TrackInfo track;
  final CanonicalAlbumSummary? resolvedAlbum;
  final bool isPlaying;
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final VoidCallback onPlay;
  final VoidCallback? onOpenAlbumDetail;

  const _ArtistTrackRow({
    super.key,
    required this.index,
    required this.track,
    required this.resolvedAlbum,
    required this.isPlaying,
    required this.audioService,
    required this.libraryCache,
    required this.onPlay,
    this.onOpenAlbumDetail,
  });

  @override
  State<_ArtistTrackRow> createState() => _ArtistTrackRowState();
}

class _ArtistTrackRowState extends State<_ArtistTrackRow> {
  bool _rowHovered = false;
  bool _albumHovered = false;

  @override
  Widget build(BuildContext context) {
    final isPlaying = widget.isPlaying;
    final isBanned = widget.track.preference == -1;
    final canOpenAlbum = widget.onOpenAlbumDetail != null;
    final albumTitle = widget.track.album.trim().isNotEmpty
        ? widget.track.album.trim()
        : (widget.resolvedAlbum?.title ?? '');

    final bgColor = isPlaying
        ? LuminaTokens.glassNavActiveBg
        : (_rowHovered ? LuminaTokens.glassRowHoverBg : Colors.transparent);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_rowHovered) setState(() => _rowHovered = true);
      },
      onExit: (_) {
        if (_rowHovered || _albumHovered) {
          setState(() {
            _rowHovered = false;
            _albumHovered = false;
          });
        }
      },
      child: Semantics(
        button: true,
        label: widget.track.title,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPlay,
          onSecondaryTapUp: (details) => showTrackContextMenu(
            context: context,
            audioService: widget.audioService,
            track: widget.track,
            globalPosition: details.globalPosition,
            libraryCache: widget.libraryCache,
          ),
          child: AnimatedContainer(
            duration: LuminaTokens.focusDuration,
            curve: LuminaTokens.motionCurve,
            margin: const EdgeInsets.symmetric(vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isPlaying
                    ? LuminaTokens.glassCoverRim
                    : Colors.transparent,
              ),
            ),
            child: LayoutBuilder(
              builder: (context, rowConstraints) {
                final showAlbumColumn =
                    rowConstraints.maxWidth >= 340 && albumTitle.isNotEmpty;

                return Row(
                  children: [
                    // Leading index / playing indicator (turns into play button on hover with smooth 30ms transition)
                    SizedBox(
                      width: 24,
                      child: Center(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 30),
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                            opacity: animation,
                            child: child,
                          ),
                          child: isPlaying
                              ? const Icon(
                                  Icons.equalizer_rounded,
                                  key: Key('artist_track_playing_indicator'),
                                  size: 16,
                                  color: Colors.white,
                                )
                              : (_rowHovered
                                  ? const Icon(
                                      Icons.play_arrow_rounded,
                                      key: Key('artist_track_hover_play'),
                                      size: 16,
                                      color: Colors.white,
                                    )
                                  : Text(
                                      '${widget.index + 1}',
                                      key: Key('artist_track_num_${widget.index}'),
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: _rowHovered
                                            ? LuminaTokens.textSecondary
                                            : LuminaTokens.textMuted,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    )),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Small square album thumbnail
                    AlbumArtworkView(
                      track: widget.track,
                      album: widget.resolvedAlbum,
                      size: 40,
                      fullResolution: false,
                      audioService: widget.audioService,
                      libraryCache: widget.libraryCache,
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: const [],
                    ),
                    const SizedBox(width: 12),

                    // Track title + small artist subtitle
                    Expanded(
                      flex: 5,
                      child: Opacity(
                        opacity: isBanned ? 0.48 : 1.0,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    widget.track.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: isPlaying
                                          ? Colors.white
                                          : LuminaTokens.glassTextPrimary,
                                      fontSize: 13.5,
                                      fontWeight: isPlaying
                                          ? FontWeight.w700
                                          : FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (isBanned) ...[
                                  const SizedBox(width: 8),
                                  const BannedStatusPill(),
                                ],
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.track.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: LuminaTokens.textMuted,
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Middle column: Clickable Album Name
                    if (showAlbumColumn) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 4,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: MouseRegion(
                            cursor: canOpenAlbum
                                ? SystemMouseCursors.click
                                : SystemMouseCursors.basic,
                            onEnter: (_) {
                              if (canOpenAlbum && !_albumHovered) {
                                setState(() => _albumHovered = true);
                              }
                            },
                            onExit: (_) {
                              if (_albumHovered) {
                                setState(() => _albumHovered = false);
                              }
                            },
                            child: GestureDetector(
                              key: Key('artist_track_album_${widget.index}'),
                              behavior: HitTestBehavior.opaque,
                              onTap: canOpenAlbum
                                  ? widget.onOpenAlbumDetail
                                  : null,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                                child: Text(
                                  albumTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _albumHovered
                                        ? Colors.white
                                        : LuminaTokens.textSecondary,
                                    fontSize: 12.5,
                                    fontWeight: _albumHovered
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    decoration: _albumHovered
                                        ? TextDecoration.underline
                                        : TextDecoration.none,
                                    decorationColor: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(width: 12),

                    // Right side: Track duration + action icon
                    Text(
                      _formatDuration(widget.track.duration),
                      style: const TextStyle(
                        color: LuminaTokens.textMuted,
                        fontSize: 12,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 6),
                    PreferenceToggleButton(
                      buttonKey: Key('artist_track_pref_${widget.index}'),
                      audioService: widget.audioService,
                      libraryCache: widget.libraryCache,
                      entityType: 'track',
                      entityId: widget.track.id,
                      preference: widget.track.preference,
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      key: Key('artist_track_play_${widget.index}'),
                      onPressed: widget.onPlay,
                      tooltip: '播放曲目',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      icon: Icon(
                        isPlaying
                            ? Icons.volume_up_rounded
                            : Icons.play_arrow_rounded,
                        size: 17,
                        color: isPlaying || _rowHovered
                            ? Colors.white
                            : LuminaTokens.textMuted,
                      ),
                    ),
                    Builder(
                      builder: (btnCtx) => IconButton(
                        key: Key('btn_artist_track_more_${widget.index}'),
                        onPressed: () => showTrackContextMenu(
                          context: btnCtx,
                          audioService: widget.audioService,
                          track: widget.track,
                          anchorContext: btnCtx,
                          libraryCache: widget.libraryCache,
                        ),
                        tooltip: '更多曲目選項',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        icon: Icon(
                          Icons.more_horiz_rounded,
                          size: 17,
                          color: _rowHovered
                              ? Colors.white
                              : LuminaTokens.textMuted,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

// ─── Hover-Isolated Artist Album Card ─────────────────────────────────────────

class _ArtistAlbumCard extends StatefulWidget {
  final CanonicalAlbumSummary album;
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final VoidCallback? onTap;

  const _ArtistAlbumCard({
    super.key,
    required this.album,
    required this.audioService,
    required this.libraryCache,
    this.onTap,
  });

  @override
  State<_ArtistAlbumCard> createState() => _ArtistAlbumCardState();
}

class _ArtistAlbumCardState extends State<_ArtistAlbumCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final album = widget.album;

    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: Semantics(
        button: widget.onTap != null,
        label: album.title,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: LuminaTokens.focusDuration,
            curve: LuminaTokens.motionCurve,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _hovered
                  ? LuminaTokens.glassPillHoverBg
                  : LuminaTokens.glassCardBg,
              borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
              border: Border.all(
                color: _hovered
                    ? LuminaTokens.glassCoverRim
                    : LuminaTokens.glassCardBorder,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 1.0,
                      child: LayoutBuilder(
                        builder: (context, box) {
                          final side = math.min(box.maxWidth, box.maxHeight);
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              AlbumArtworkView(
                                album: album,
                                size: side.isFinite && side > 0 ? side : 160,
                                fullResolution: false,
                                audioService: widget.audioService,
                                libraryCache: widget.libraryCache,
                                borderRadius: BorderRadius.circular(8),
                                boxShadow: const [],
                              ),
                              if (_hovered)
                                Positioned(
                                  right: 8,
                                  bottom: 8,
                                  child: Container(
                                    width: 34,
                                    height: 34,
                                    decoration: const BoxDecoration(
                                      color: LuminaTokens.glassSwitchOnTrack,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Color(0x66000000),
                                          blurRadius: 10,
                                          offset: Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.play_arrow_rounded,
                                      size: 20,
                                      color: LuminaTokens.onAccentDark,
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (album.year != null) ...[
                  Text(
                    '${album.year}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: LuminaTokens.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 2),
                ],
                Text(
                  album.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _hovered
                        ? Colors.white
                        : LuminaTokens.glassTextPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  album.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.textMuted,
                    fontSize: 11.5,
                    height: 1.15,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
