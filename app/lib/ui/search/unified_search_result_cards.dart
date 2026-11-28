part of 'unified_search_results_view.dart';

extension _UnifiedSearchResultCards on _UnifiedSearchResultsViewState {
  Widget _buildTrackRow(SearchTrackMatch match) {
    final track = match.track;
    final isSelected = widget.activeTrackId == track.id;
    final durationLabel = _formatDuration(track.duration);

    return TrackHoverPrefetch(
      track: track,
      enabled: !match.isLocal,
      child: GestureDetector(
        onSecondaryTapUp: (details) => showTrackContextMenu(
          context: context,
          audioService: widget.audioService,
          track: track,
          globalPosition: details.globalPosition,
          libraryCache: match.isLocal ? widget.libraryCache : null,
          listenLaterController: widget.listenLaterController,
        ),
        child: Material(
          color: isSelected
              ? LuminaTokens.glassNavActiveBg
              : Colors.transparent,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
          child: InkWell(
            key: Key('search_track_${match.sourceKind}_${track.id}'),
            borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
            hoverColor: LuminaTokens.glassRowHoverBg,
            onTap: () {
              if (match.isLocal) {
                widget.audioService.play(track: track);
              } else {
                widget.onPlayStreamingTrack(
                  track,
                  queueContext: _streamingQueueFor(match.sourceKind),
                );
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Row(
                children: [
                  AlbumArtworkView(
                    track: track,
                    size: 40,
                    borderRadius: BorderRadius.circular(6),
                    audioService: match.isLocal ? widget.audioService : null,
                    libraryCache: match.isLocal ? widget.libraryCache : null,
                    fullResolution: false,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isSelected
                                ? Colors.white
                                : LuminaTokens.glassTextPrimary,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          track.album.trim().isNotEmpty
                              ? '${track.artist} · ${track.album}'
                              : track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: LuminaTokens.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _SourceBadge(sourceKind: match.sourceKind, size: 18),
                  if (MediaQuery.sizeOf(context).width >= 540) ...[
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 140),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: LuminaTokens.glassPillBg,
                          borderRadius: BorderRadius.circular(
                            LuminaTokens.radiusPill,
                          ),
                          border: Border.all(
                            color: LuminaTokens.glassPillBorder,
                          ),
                        ),
                        child: Text(
                          track.format.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: LuminaTokens.textSecondary,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (durationLabel.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      durationLabel,
                      style: const TextStyle(
                        color: LuminaTokens.textMuted,
                        fontSize: 12,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                  if (widget.listenLaterController != null) ...[
                    const SizedBox(width: 4),
                    IconButton(
                      key: Key(
                        'search_track_listen_later_${match.sourceKind}_${track.id}',
                      ),
                      tooltip: '加入稍後收聽',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(
                        Icons.watch_later_outlined,
                        size: 16,
                        color: LuminaTokens.textSecondary,
                      ),
                      onPressed: () {
                        final ll = widget.listenLaterController!;
                        if (match.isLocal) {
                          ll.addLocalTrack(track);
                        } else {
                          ll.addStreamingTrack(track);
                        }
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          SnackBar(
                            content: Text('已將「${track.title}」加入稍後收聽'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      },
                    ),
                  ],
                  const SizedBox(width: 2),
                  Builder(
                    builder: (btnCtx) => IconButton(
                      key: Key(
                        'btn_search_track_more_${match.sourceKind}_${track.id}',
                      ),
                      tooltip: '更多曲目選項',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(
                        Icons.more_horiz_rounded,
                        size: 17,
                        color: LuminaTokens.textMuted,
                      ),
                      onPressed: () => showTrackContextMenu(
                        context: btnCtx,
                        audioService: widget.audioService,
                        track: track,
                        anchorContext: btnCtx,
                        libraryCache: match.isLocal
                            ? widget.libraryCache
                            : null,
                        listenLaterController: widget.listenLaterController,
                      ),
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

  Widget _buildAlbumCard(SearchAlbumMatch match) {
    final artworkAlbum = match.localAlbum ??
        CanonicalAlbumSummary(
          id: 'streaming:${match.sourceKind}:${match.id}',
          title: match.title,
          artist: match.artist,
          year: match.year,
          availableProviders: <String>[match.sourceKind],
          coverUrl: match.coverUrl,
        );
    final metaParts = <String>[
      if (match.year != null) '${match.year}',
      if (match.qualityLabel != null && match.qualityLabel!.trim().isNotEmpty)
        match.qualityLabel!,
    ];

    return Material(
      color: LuminaTokens.glassCardBg,
      borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
      child: InkWell(
        key: Key('search_album_${match.sourceKind}_${match.id}'),
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        hoverColor: LuminaTokens.glassRowHoverBg,
        onTap: () {
          if (match.localAlbum != null) {
            widget.onOpenLocalAlbum(match.localAlbum!.id);
          } else if (match.streamingAlbum != null) {
            widget.onOpenStreamingAlbum(match.streamingAlbum!);
          }
        },
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
            border: Border.all(color: LuminaTokens.glassCardBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(
                        LuminaTokens.radiusSm,
                      ),
                      child: AlbumArtworkView(
                        album: artworkAlbum,
                        size: 160,
                        borderRadius: BorderRadius.circular(
                          LuminaTokens.radiusSm,
                        ),
                        audioService:
                            match.isLocal ? widget.audioService : null,
                        libraryCache:
                            match.isLocal ? widget.libraryCache : null,
                        fullResolution: false,
                      ),
                    ),
                    Positioned(
                      top: 6,
                      right: 6,
                      child: _SourceBadge(sourceKind: match.sourceKind, size: 20),
                    ),
                    if (widget.listenLaterController != null)
                      Positioned(
                        top: 4,
                        left: 4,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: LuminaTokens.glassDrawerBg,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: LuminaTokens.glassPillBorder,
                            ),
                          ),
                          child: IconButton(
                            key: Key(
                              'search_album_listen_later_${match.sourceKind}_${match.id}',
                            ),
                            tooltip: '加入稍後收聽',
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(
                              minWidth: 28,
                              minHeight: 28,
                            ),
                            padding: EdgeInsets.zero,
                            icon: const Icon(
                              Icons.watch_later_outlined,
                              size: 15,
                              color: Colors.white,
                            ),
                            onPressed: () {
                              final ll = widget.listenLaterController!;
                              if (match.localAlbum != null) {
                                ll.addLocalAlbum(match.localAlbum!);
                              } else if (match.streamingAlbum != null) {
                                ll.addStreamingAlbum(match.streamingAlbum!);
                              }
                              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                SnackBar(
                                  content: Text('已將「${match.title}」加入稍後收聽'),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                match.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: LuminaTokens.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                match.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: LuminaTokens.textSecondary,
                  fontSize: 11.5,
                ),
              ),
              if (metaParts.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  metaParts.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.textMuted,
                    fontSize: 10.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildArtistCard(SearchArtistMatch artist) {
    final avatarAlbum = artist.representativeAlbum ??
        (artist.coverUrl != null && artist.coverUrl!.trim().isNotEmpty
            ? CanonicalAlbumSummary(
                id: 'artist_art_${artist.name}',
                title: artist.name,
                artist: artist.name,
                coverUrl: artist.coverUrl,
              )
            : null);
    final isLocalArtist = artist.sourceKinds.contains('local');

    return Material(
      color: LuminaTokens.glassCardBg,
      borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
      child: InkWell(
        key: Key('search_artist_${artist.name}'),
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        hoverColor: LuminaTokens.glassRowHoverBg,
        onTap: () => widget.onOpenArtist(artist.name),
        child: Container(
          constraints: const BoxConstraints(minWidth: 160, maxWidth: 260),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
            border: Border.all(color: LuminaTokens.glassCardBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AlbumArtworkView(
                album: avatarAlbum,
                track: artist.representativeTrack,
                size: 36,
                circular: true,
                audioService: isLocalArtist ? widget.audioService : null,
                libraryCache: isLocalArtist ? widget.libraryCache : null,
                fullResolution: false,
                placeholder: Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(
                    color: LuminaTokens.glassPillBg,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.person_rounded,
                    size: 20,
                    color: LuminaTokens.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      artist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final kind in artist.sourceKinds)
                          _SourceBadge(
                            sourceKind: kind,
                            size: 15,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  final String sourceKind;
  final double size;

  const _SourceBadge({
    required this.sourceKind,
    this.size = 18,
  });

  @override
  Widget build(BuildContext context) {
    if (sourceKind == 'local') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: LuminaTokens.glassPillBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
          border: Border.all(color: LuminaTokens.glassPillBorder),
        ),
        child: const Text(
          '本機',
          style: TextStyle(
            color: LuminaTokens.textSecondary,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    final meta = StreamingProviderMeta.byKind(sourceKind);
    if (meta != null) {
      return meta.buildBadge(boxSize: size, borderRadius: 4);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: LuminaTokens.glassPillBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        border: Border.all(color: LuminaTokens.glassPillBorder),
      ),
      child: Text(
        sourceKind,
        style: const TextStyle(
          color: LuminaTokens.textSecondary,
          fontSize: 10,
        ),
      ),
    );
  }
}
