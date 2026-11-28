part of 'smart_playlists_view.dart';

class _SmartPlaylistDetailPane extends StatefulWidget {
  final SmartPlaylistItem? active;
  final List<TrackInfo> matchedTracks;
  final int totalMatched;
  final bool evaluating;
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final SmartPlaylistService playlistService;
  final void Function(SmartPlaylistItem playlist)? onEditRules;
  final VoidCallback onRefreshEval;
  final ValueChanged<String> onSelectPlaylist;

  const _SmartPlaylistDetailPane({
    required this.active,
    required this.matchedTracks,
    required this.totalMatched,
    required this.evaluating,
    required this.audioService,
    this.libraryCache,
    required this.playlistService,
    this.onEditRules,
    required this.onRefreshEval,
    required this.onSelectPlaylist,
  });

  @override
  State<_SmartPlaylistDetailPane> createState() =>
      _SmartPlaylistDetailPaneState();
}

class _SmartPlaylistDetailPaneState extends State<_SmartPlaylistDetailPane> {
  final GlideScrollController _scrollController = GlideScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _playPlaylist(BuildContext context, SmartPlaylistItem sp) async {
    final eval = await widget.playlistService.evaluatePlaylist(sp.id);
    if (!context.mounted) return;
    final tracks = eval?.tracks ?? widget.matchedTracks;
    final playable = sp.excludeBanned
        ? tracks.where((t) => t.preference != -1).toList(growable: false)
        : tracks;
    if (playable.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            tracks.isNotEmpty ? '此智慧歌單內符合條件的曲目皆已封鎖' : '目前曲庫內沒有符合此篩選條件的曲目',
          ),
        ),
      );
      return;
    }
    await widget.audioService.playQueue(playable, excludeBanned: sp.excludeBanned);
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.active;
    if (current == null) {
      return const Center(
        child: Text(
          '尚未建立智慧歌單',
          style: TextStyle(color: LuminaTokens.textMuted),
        ),
      );
    }

    final ruleTags = describeSmartPlaylistRules(current);
    final matchedTracks = widget.matchedTracks;
    final totalMatched = widget.totalMatched;
    final evaluating = widget.evaluating;
    final audioService = widget.audioService;
    final libraryCache = widget.libraryCache;
    final playlistService = widget.playlistService;
    final onEditRules = widget.onEditRules;
    final onRefreshEval = widget.onRefreshEval;
    final onSelectPlaylist = widget.onSelectPlaylist;

    return Container(
      padding: const EdgeInsets.all(LuminaTokens.spaceMd),
      decoration: BoxDecoration(
        color: LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        border: Border.all(color: LuminaTokens.glassCardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    current.name,
                    style: const TextStyle(
                      color: LuminaTokens.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (current.description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        current.description,
                        style: const TextStyle(
                          color: LuminaTokens.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    key: const Key('btn_play_smart_playlist'),
                    style: FilledButton.styleFrom(
                      backgroundColor: LuminaTokens.glassSwitchOnTrack,
                      foregroundColor: LuminaTokens.onAccentDark,
                    ),
                    onPressed: matchedTracks.isEmpty
                        ? null
                        : () => unawaited(_playPlaylist(context, current)),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: Text('播放 ($totalMatched)'),
                  ),
                  if (onEditRules != null)
                    OutlinedButton.icon(
                      key: Key('btn_edit_smart_rules_${current.id}'),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: LuminaTokens.glassPillBg,
                        foregroundColor: LuminaTokens.glassTextPrimary,
                        side: const BorderSide(
                          color: LuminaTokens.glassPillBorder,
                        ),
                      ),
                      onPressed: () => onEditRules(current),
                      icon: const Icon(Icons.tune_rounded, size: 16),
                      label: const Text('在曲庫編輯規則'),
                    ),
                  OutlinedButton.icon(
                    key: Key('btn_edit_smart_meta_${current.id}'),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: LuminaTokens.glassPillBg,
                      foregroundColor: LuminaTokens.glassTextPrimary,
                      side: const BorderSide(
                        color: LuminaTokens.glassPillBorder,
                      ),
                    ),
                    onPressed: () async {
                      final updated = await SmartPlaylistsView.showCreateDialog(
                        context: context,
                        service: playlistService,
                        editing: current,
                      );
                      if (updated != null) {
                        onRefreshEval();
                      }
                    },
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: const Text('編輯設定'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('btn_export_smart_playlist'),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: LuminaTokens.glassPillBg,
                      foregroundColor: LuminaTokens.glassTextPrimary,
                      side: const BorderSide(
                        color: LuminaTokens.glassPillBorder,
                      ),
                    ),
                    onPressed: () => unawaited(
                      LibraryExportDialog.show(
                        context,
                        audioService: audioService,
                        initialSource: CatalogExportSmartPlaylistSource(
                          current.id,
                        ),
                        defaultPlaylistName: current.name,
                      ),
                    ),
                    icon: const Icon(Icons.file_download_outlined, size: 16),
                    label: const Text('匯出'),
                  ),
                  IconButton(
                    key: Key('btn_pin_smart_playlist_${current.id}'),
                    tooltip: current.isPinned ? '取消釘選至側欄' : '釘選至側欄',
                    onPressed: () =>
                        unawaited(playlistService.togglePin(current)),
                    icon: Icon(
                      current.isPinned
                          ? Icons.push_pin_rounded
                          : Icons.push_pin_outlined,
                      size: 18,
                      color: current.isPinned
                          ? LuminaTokens.accentBlue
                          : LuminaTokens.textSecondary,
                    ),
                  ),
                  IconButton(
                    key: Key('btn_duplicate_smart_playlist_${current.id}'),
                    tooltip: '複製智慧歌單',
                    onPressed: () async {
                      final dup = await playlistService.duplicatePlaylist(
                        current.id,
                      );
                      if (dup != null) {
                        onSelectPlaylist(dup.id);
                      }
                    },
                    icon: const Icon(
                      Icons.copy_rounded,
                      size: 18,
                      color: LuminaTokens.textSecondary,
                    ),
                  ),
                  IconButton(
                    key: Key('btn_delete_smart_playlist_${current.id}'),
                    tooltip: '刪除智慧歌單',
                    onPressed: () =>
                        unawaited(playlistService.deletePlaylist(current.id)),
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      size: 18,
                      color: LuminaTokens.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: LuminaTokens.spaceSm),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: ruleTags
                .map(
                  (tag) => Chip(
                    visualDensity: VisualDensity.compact,
                    surfaceTintColor: Colors.transparent,
                    backgroundColor: LuminaTokens.glassPillBg,
                    side: const BorderSide(color: LuminaTokens.glassPillBorder),
                    label: Text(
                      tag,
                      style: const TextStyle(
                        color: LuminaTokens.glassTextPrimary,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const Divider(color: LuminaTokens.glassCardDivider, height: 22),
          Expanded(
            child: evaluating && matchedTracks.isEmpty
                ? const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: LuminaTokens.glassTextPrimary,
                    ),
                  )
                : matchedTracks.isEmpty
                ? const Center(
                    child: Text(
                      '目前曲庫內沒有符合此篩選條件的曲目',
                      style: TextStyle(color: LuminaTokens.textMuted),
                    ),
                  )
                : SmoothScrollWrapper(
                    controller: _scrollController,
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.only(
                        bottom: LuminaTokens.bottomScrollClearance,
                      ),
                      itemCount: matchedTracks.length,
                    itemBuilder: (context, index) {
                      final t = matchedTracks[index];
                      final isBanned = t.preference == -1;
                      return TrackHoverPrefetch(
                        track: t,
                        child: GestureDetector(
                          onSecondaryTapUp: (details) => showTrackContextMenu(
                            context: context,
                            audioService: audioService,
                            track: t,
                            globalPosition: details.globalPosition,
                            libraryCache: libraryCache,
                            onTrackUpdated: (_) => onRefreshEval(),
                            onTrackDeleted: onRefreshEval,
                            onPreferenceChanged: (_) => onRefreshEval(),
                          ),
                          child: Opacity(
                            opacity: isBanned ? 0.48 : 1.0,
                            child: Material(
                              type: MaterialType.transparency,
                              child: ListTile(
                                key: Key('smart_playlist_track_${t.id}'),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    LuminaTokens.radiusSm,
                                  ),
                                ),
                                hoverColor: LuminaTokens.glassRowHoverBg,
                                leading: const Icon(
                                  Icons.music_note_rounded,
                                  color: LuminaTokens.textSecondary,
                                ),
                                title: Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        t.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: LuminaTokens.textPrimary,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    if (isBanned) ...[
                                      const SizedBox(width: 8),
                                      const BannedStatusPill(),
                                    ],
                                  ],
                                ),
                                subtitle: Text(
                                  '${t.artist} • ${t.album} • ${t.format.label}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: LuminaTokens.textMuted,
                                    fontSize: 12,
                                  ),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    PreferenceToggleButton(
                                      buttonKey: Key(
                                        'smart_playlist_track_pref_${t.id}',
                                      ),
                                      audioService: audioService,
                                      libraryCache: libraryCache,
                                      entityType: 'track',
                                      entityId: t.id,
                                      preference: t.preference,
                                      onChanged: (_) => onRefreshEval(),
                                    ),
                                    IconButton(
                                      tooltip: '直接播放曲目',
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () =>
                                          audioService.play(track: t),
                                      icon: const Icon(
                                        Icons.play_arrow_rounded,
                                        color: LuminaTokens.textSecondary,
                                      ),
                                    ),
                                    Builder(
                                      builder: (btnCtx) => IconButton(
                                        key: Key(
                                          'btn_smart_playlist_track_more_${t.id}',
                                        ),
                                        tooltip: '更多曲目選項',
                                        visualDensity: VisualDensity.compact,
                                        onPressed: () => showTrackContextMenu(
                                          context: btnCtx,
                                          audioService: audioService,
                                          track: t,
                                          anchorContext: btnCtx,
                                          libraryCache: libraryCache,
                                          onTrackUpdated: (_) =>
                                              onRefreshEval(),
                                          onTrackDeleted: onRefreshEval,
                                          onPreferenceChanged: (_) =>
                                              onRefreshEval(),
                                        ),
                                        icon: const Icon(
                                          Icons.more_horiz_rounded,
                                          size: 18,
                                          color: LuminaTokens.textMuted,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                onTap: () => audioService.play(track: t),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  ),
          ),
        ],
      ),
    );
  }
}
