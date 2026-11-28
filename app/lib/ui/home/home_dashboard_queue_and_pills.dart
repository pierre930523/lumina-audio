part of 'home_dashboard_view.dart';

extension _HomeDashboardQueue on _HomeDashboardViewState {
  Widget _buildQuickQueueCard(List<TrackInfo> tracks) {
    final recentTracks = tracks.take(5).toList(growable: false);
    return Column(
      key: const Key('home_quick_queue_card'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Expanded(
              child: Text(
                '最近播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: LuminaTokens.glassTextPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            _GlassSectionActionLink(
              label: '查看全部 >',
              onTap: widget.onOpenLibrary,
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (recentTracks.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text(
              '尚無最近播放曲目',
              style: TextStyle(
                color: LuminaTokens.glassTextSecondary,
                fontSize: 13,
              ),
            ),
          )
        else
          for (var i = 0; i < recentTracks.length; i++)
            _buildRecentTrackRow(index: i + 1, track: recentTracks[i]),
      ],
    );
  }

  Widget _buildRecentTrackRow({required int index, required TrackInfo track}) {
    return TrackHoverPrefetch(
      track: track,
      child: GestureDetector(
        onSecondaryTapUp: (details) => showTrackContextMenu(
          context: context,
          audioService: widget.audioService,
          track: track,
          globalPosition: details.globalPosition,
          libraryCache: widget.libraryCache,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: Key('home_recent_track_${track.id}'),
            borderRadius: BorderRadius.circular(8),
            hoverColor: LuminaTokens.glassRowHoverBg,
            onTap: () => widget.audioService.play(track: track),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              child: Row(
                children: [
                  SizedBox(
                    width: 22,
                    child: Text(
                      '$index',
                      style: const TextStyle(
                        color: LuminaTokens.glassTextTertiary,
                        fontSize: 12,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  AlbumArtworkView(
                    track: track,
                    size: 40,
                    fullResolution: false,
                    audioService: widget.audioService,
                    libraryCache: widget.libraryCache,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: LuminaTokens.glassPillBorder,
                      width: 0.8,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: LuminaTokens.glassTextPrimary,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          track.artist,
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
                  const SizedBox(width: 8),
                  Text(
                    _formatDuration(track.duration),
                    style: const TextStyle(
                      color: LuminaTokens.glassTextTertiary,
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 4),
                  Builder(
                    builder: (btnCtx) => IconButton(
                      key: Key('btn_home_track_more_${track.id}'),
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
                        libraryCache: widget.libraryCache,
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

  CanonicalAlbumSummary? _findAlbumForTrack(TrackInfo track) {
    return _albums
            .where(
              (a) =>
                  a.title == track.album &&
                  (a.artist == track.artist ||
                      a.artist == track.effectiveAlbumArtist),
            )
            .firstOrNull ??
        _albums.where((a) => a.title == track.album).firstOrNull;
  }

  List<_RecentItem> _buildRecentItems(List<TrackInfo> tracks) {
    final items = <_RecentItem>[];
    if (_showPlayedTab) {
      final active = widget.audioService.currentState.track;
      if (active != null) {
        items.add(
          _RecentItem(
            title: active.album,
            subtitle: active.artist,
            track: active,
            album: _findAlbumForTrack(active),
          ),
        );
      }
      for (final t in tracks) {
        if (active != null && t.id == active.id) continue;
        items.add(
          _RecentItem(
            title: t.title,
            subtitle: t.artist,
            track: t,
            album: _findAlbumForTrack(t),
          ),
        );
      }
      return items;
    }

    for (final a in _albums) {
      final matchTrack =
          tracks
              .where(
                (t) =>
                    t.album == a.title &&
                    (t.effectiveAlbumArtist == a.artist ||
                        t.artist == a.artist),
              )
              .firstOrNull ??
          tracks.where((t) => t.album == a.title).firstOrNull;
      items.add(
        _RecentItem(
          title: a.title,
          subtitle: a.artist,
          track: matchTrack,
          album: a,
        ),
      );
    }
    if (items.isEmpty) {
      for (final t in tracks) {
        items.add(
          _RecentItem(title: t.album, subtitle: t.artist, track: t),
        );
      }
    }
    return items;
  }
}

class _RecentItem {
  final String title;
  final String subtitle;
  final TrackInfo? track;
  final CanonicalAlbumSummary? album;

  const _RecentItem({
    required this.title,
    required this.subtitle,
    required this.track,
    this.album,
  });
}

class _ActivityTabButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ActivityTabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected
                  ? LuminaTokens.glassTextPrimary
                  : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected
                ? LuminaTokens.glassTextPrimary
                : LuminaTokens.glassTextSecondary,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _StatPillButton extends StatefulWidget {
  final double width;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _StatPillButton({
    super.key,
    required this.width,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  State<_StatPillButton> createState() => _StatPillButtonState();
}

class _StatPillButtonState extends State<_StatPillButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(12);
    return SizedBox(
      width: widget.width,
      height: 44,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) {
          if (!_hovered) setState(() => _hovered = true);
        },
        onExit: (_) {
          if (_hovered) setState(() => _hovered = false);
        },
        child: FrostedGlassContainer(
          height: 44,
          blurSigma: LuminaTokens.glassPillBlur,
          enableBackdropBlur: false,
          color: _hovered
              ? LuminaTokens.glassPillHoverBg
              : LuminaTokens.glassPillBg,
          borderRadius: radius,
          border: Border.all(
            color: _hovered
                ? LuminaTokens.glassCoverRim
                : LuminaTokens.glassPillBorder,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: widget.onTap,
              hoverColor: LuminaTokens.glassPillHoverBg,
              borderRadius: radius,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    Icon(
                      widget.icon,
                      size: 17,
                      color: LuminaTokens.glassTextSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.glassTextPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
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
  }
}

class _GlassSectionActionLink extends StatefulWidget {
  final String label;
  final VoidCallback onTap;

  const _GlassSectionActionLink({required this.label, required this.onTap});

  @override
  State<_GlassSectionActionLink> createState() =>
      _GlassSectionActionLinkState();
}

class _GlassSectionActionLinkState extends State<_GlassSectionActionLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        hoverColor: LuminaTokens.glassPillBg,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Text(
            widget.label,
            style: TextStyle(
              color: _hovered
                  ? LuminaTokens.glassTextPrimary
                  : LuminaTokens.glassTextSecondary,
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
