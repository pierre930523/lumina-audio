part of 'album_detail_page.dart';

@immutable
class _ActivePlaybackSnapshot {
  final String? trackId;
  final String? trackTitle;
  final String? albumTitle;
  final PlaybackStatus status;

  const _ActivePlaybackSnapshot({
    required this.trackId,
    required this.trackTitle,
    required this.albumTitle,
    required this.status,
  });

  factory _ActivePlaybackSnapshot.fromState(PlaybackState state) {
    return _ActivePlaybackSnapshot(
      trackId: state.track?.id,
      trackTitle: state.track?.title,
      albumTitle: state.track?.album,
      status: state.status,
    );
  }

  bool get isActivelyPlaying =>
      status == PlaybackStatus.playing ||
      status == PlaybackStatus.seeking ||
      status == PlaybackStatus.buffering;

  bool matchesTrack(AlbumVersionTrackInfo track, String albumName) {
    if (trackId != null && trackId!.isNotEmpty && trackId == track.id) {
      return true;
    }
    if (trackTitle != null &&
        trackTitle == track.title &&
        albumTitle != null &&
        (albumTitle == albumName ||
            albumTitle!.toLowerCase().startsWith(albumName.toLowerCase()))) {
      return true;
    }
    return false;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ActivePlaybackSnapshot &&
          other.trackId == trackId &&
          other.trackTitle == trackTitle &&
          other.albumTitle == albumTitle &&
          other.status == status;

  @override
  int get hashCode => Object.hash(trackId, trackTitle, albumTitle, status);
}

// ─── Hover-Isolated Virtualized Track Row ─────────────────────────────────────

class _AlbumTrackRow extends StatefulWidget {
  final int index;
  final AlbumVersionTrackInfo track;
  final String displayNumber;
  final String artistName;
  final String albumTitle;
  final AudioService? audioService;
  final LibraryIndexCache? libraryCache;
  final ListenLaterController? listenLaterController;
  final TrackInfo Function()? trackInfoBuilder;
  final VoidCallback? onTrackMutated;
  final bool isStreaming;
  final ValueListenable<_ActivePlaybackSnapshot> playbackListenable;
  final VoidCallback onPlay;
  final VoidCallback onAddToQueue;
  final VoidCallback onOpenArtist;
  final VoidCallback? onManageTags;
  final ValueChanged<int>? onPreferenceChanged;

  const _AlbumTrackRow({
    super.key,
    required this.index,
    required this.track,
    required this.displayNumber,
    required this.artistName,
    required this.albumTitle,
    this.audioService,
    this.libraryCache,
    this.listenLaterController,
    this.trackInfoBuilder,
    this.onTrackMutated,
    this.isStreaming = false,
    required this.playbackListenable,
    required this.onPlay,
    required this.onAddToQueue,
    required this.onOpenArtist,
    this.onManageTags,
    this.onPreferenceChanged,
  });

  @override
  State<_AlbumTrackRow> createState() => _AlbumTrackRowState();
}

class _AlbumTrackRowState extends State<_AlbumTrackRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_ActivePlaybackSnapshot>(
      valueListenable: widget.playbackListenable,
      builder: (context, snapshot, _) {
        final isMatched = snapshot.matchesTrack(
          widget.track,
          widget.albumTitle,
        );
        final isPlaying = isMatched && snapshot.isActivelyPlaying;
        final isBanned = widget.track.preference == -1;

        final rowBg = isPlaying
            ? (_isHovered
                  ? LuminaTokens.glassPillHoverBg
                  : LuminaTokens.glassNavActiveBg)
            : (_isHovered ? LuminaTokens.glassRowHoverBg : Colors.transparent);

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) {
            if (!_isHovered) setState(() => _isHovered = true);
          },
          onExit: (_) {
            if (_isHovered) setState(() => _isHovered = false);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPlay,
            onSecondaryTapUp: (details) =>
                _showTrackContextMenu(context, details.globalPosition),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 110),
              margin: const EdgeInsets.symmetric(vertical: 2),
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              decoration: BoxDecoration(
                color: rowBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isPlaying
                      ? LuminaTokens.glassCoverRim
                      : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  // Track Number or Playing Indicator Icon (smooth 30ms transition on hover to play button)
                  SizedBox(
                    width: 34,
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 30),
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: child,
                        ),
                        child: isPlaying
                            ? Icon(
                                Icons.equalizer_rounded,
                                key: Key(
                                  'track_playing_icon_${widget.track.id}',
                                ),
                                size: 18,
                                color: Colors.white,
                              )
                            : (_isHovered
                                ? Icon(
                                    Icons.play_arrow_rounded,
                                    key: Key('track_hover_play_${widget.index}'),
                                    size: 18,
                                    color: Colors.white,
                                  )
                                : Text(
                                    widget.displayNumber,
                                    key: Key('track_number_${widget.index}'),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: LuminaTokens.textMuted,
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  )),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),

                  // Track Title & Clickable Small Artist Name
                  Expanded(
                    child: Opacity(
                      opacity: isBanned ? 0.5 : 1.0,
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
                                        : FontWeight.w500,
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
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: _ClickableArtistLink(
                                  key: Key('album_track_artist_${widget.index}'),
                                  artistName: widget.artistName,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w400,
                                  defaultColor: LuminaTokens.textSecondary,
                                  hoverColor: Colors.white,
                                  onTap: widget.onOpenArtist,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Track Duration
                  Text(
                    _fmtMs(widget.track.durationMs),
                    style: TextStyle(
                      color: isPlaying
                          ? Colors.white
                          : LuminaTokens.textMuted,
                      fontSize: 12.5,
                      fontWeight: isPlaying
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Right-side Quick Actions (Preference / Play / Add to Queue)
                  if (!widget.isStreaming && widget.audioService != null)
                    PreferenceToggleButton(
                      buttonKey: Key('album_track_pref_${widget.index}'),
                      audioService: widget.audioService!,
                      libraryCache: widget.libraryCache,
                      entityType: 'track',
                      entityId: widget.track.id,
                      preference: widget.track.preference,
                      onChanged: widget.onPreferenceChanged,
                    ),
                  IconButton(
                    key: Key('album_track_play_${widget.index}'),
                    onPressed: widget.onPlay,
                    tooltip: '播放曲目',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    icon: Icon(
                      Icons.play_arrow_rounded,
                      size: 18,
                      color: isPlaying || _isHovered
                          ? Colors.white
                          : LuminaTokens.textMuted,
                    ),
                  ),
                  IconButton(
                    key: Key('album_track_queue_${widget.index}'),
                    onPressed: widget.onAddToQueue,
                    tooltip: '加入播放佇列',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    icon: Icon(
                      Icons.playlist_add_rounded,
                      size: 17,
                      color: _isHovered
                          ? LuminaTokens.textPrimary
                          : LuminaTokens.textMuted,
                    ),
                  ),
                  if (widget.onManageTags != null)
                    IconButton(
                      key: Key('album_track_tags_${widget.index}'),
                      onPressed: widget.onManageTags,
                      tooltip: '管理標籤',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      icon: Icon(
                        Icons.label_outlined,
                        size: 16,
                        color: _isHovered
                            ? LuminaTokens.textPrimary
                            : LuminaTokens.textMuted,
                      ),
                    ),
                  if (widget.audioService != null)
                    Builder(
                      builder: (btnCtx) => IconButton(
                        key: Key('album_track_more_${widget.index}'),
                        onPressed: () => _showTrackContextMenu(
                          btnCtx,
                          null,
                          anchorContext: btnCtx,
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
                          color: _isHovered
                              ? LuminaTokens.textPrimary
                              : LuminaTokens.textMuted,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  TrackInfo _resolveFallbackTrackInfo() {
    if (widget.trackInfoBuilder != null) {
      return widget.trackInfoBuilder!();
    }
    return TrackInfo(
      id: widget.track.id,
      title: widget.track.title,
      artist: widget.artistName,
      album: widget.albumTitle,
      duration: Duration(milliseconds: widget.track.durationMs),
      format: AudioFormat(
        codec: AudioCodec.fromString(widget.track.codec),
        sampleRateHz: widget.track.sampleRateHz > 0
            ? widget.track.sampleRateHz
            : 44100,
        bitDepth: widget.track.bitDepth > 0 ? widget.track.bitDepth : 16,
        channels: 2,
        isDsd: widget.track.isDsd,
      ),
      trackNumber: widget.track.trackNumber,
      discNumber: widget.track.discNumber,
      preference: widget.track.preference,
    );
  }

  Future<void> _showTrackContextMenu(
    BuildContext ctx,
    Offset? globalPosition, {
    BuildContext? anchorContext,
  }) async {
    final svc = widget.audioService;
    if (svc == null) return;
    final resolvedTrack = _resolveFallbackTrackInfo();
    await showTrackContextMenu(
      context: ctx,
      audioService: svc,
      track: resolvedTrack,
      globalPosition: globalPosition,
      anchorContext: anchorContext,
      libraryCache: widget.libraryCache,
      listenLaterController: widget.listenLaterController,
      currentPreference: widget.track.preference,
      onPreferenceChanged: widget.onPreferenceChanged,
      onTrackUpdated: (_) => widget.onTrackMutated?.call(),
      onTrackDeleted: widget.onTrackMutated,
    );
  }

  String _fmtMs(int ms) {
    final d = Duration(milliseconds: ms);
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
