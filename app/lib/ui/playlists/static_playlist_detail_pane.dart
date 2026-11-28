part of 'static_playlists_pane.dart';

class _StaticPlaylistDetailPane extends StatefulWidget {
  final AudioService audioService;
  final StaticPlaylistDetail? detail;
  final bool loading;
  final bool busyAction;
  final Future<void> Function(StaticPlaylistDetail detail) onPlay;
  final Future<void> Function(StaticPlaylistSummary summary) onImprove;
  final Future<void> Function(StaticPlaylistSummary summary) onOpenSnapshots;
  final Future<void> Function(StaticPlaylistSummary summary) onDelete;

  const _StaticPlaylistDetailPane({
    required this.audioService,
    required this.detail,
    required this.loading,
    required this.busyAction,
    required this.onPlay,
    required this.onImprove,
    required this.onOpenSnapshots,
    required this.onDelete,
  });

  @override
  State<_StaticPlaylistDetailPane> createState() =>
      _StaticPlaylistDetailPaneState();
}

class _StaticPlaylistDetailPaneState extends State<_StaticPlaylistDetailPane> {
  final GlideScrollController _scrollController = GlideScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  TrackInfo _toTrackInfo(PlaylistTrackSummary t) {
    return TrackInfo(
      id: t.trackId,
      title: t.title,
      artist: t.artistName,
      album: t.albumTitle,
      duration: Duration(milliseconds: t.durationMs),
      format: AudioFormat(
        codec: AudioCodec.fromString(t.codec),
        sampleRateHz: t.sampleRateHz > 0 ? t.sampleRateHz : 44100,
        bitDepth: t.bitDepth > 0 ? t.bitDepth : 16,
        channels: 2,
        isDsd: t.isDsd,
      ),
      providerName: t.providerId.isNotEmpty ? t.providerId : 'Local Library',
      filePath: t.filePath,
    );
  }

  Widget _buildItemRow(BuildContext context, StaticPlaylistItemView item) {
    final audioService = widget.audioService;
    final track = item.track;
    final missing = item.isMissing || track == null;
    final trackInfo = track != null ? _toTrackInfo(track) : null;
    return GestureDetector(
      onSecondaryTapUp: trackInfo == null
          ? null
          : (details) => showTrackContextMenu(
              context: context,
              audioService: audioService,
              track: trackInfo,
              globalPosition: details.globalPosition,
            ),
      child: Material(
        type: MaterialType.transparency,
        child: ListTile(
          key: Key('static_playlist_row_${item.position}'),
          dense: true,
          leading: Text(
            '#${item.position + 1}',
            style: const TextStyle(
              color: LuminaTokens.textMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
          title: Text(
            missing ? item.rawEntry : track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: missing ? LuminaTokens.statusError : LuminaTokens.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            missing
                ? '檔案路徑失效或尚未解析'
                : '${track.artistName} · ${track.albumTitle} · ${track.codec.toUpperCase()}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: LuminaTokens.textMuted, fontSize: 12),
          ),
          trailing: missing
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: LuminaTokens.statusErrorBg,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    '失效',
                    style: TextStyle(
                      color: LuminaTokens.statusError,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '品質 ${track.qualityScore.toStringAsFixed(0)}',
                      style: const TextStyle(
                        color: LuminaTokens.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    if (trackInfo != null)
                      Builder(
                        builder: (btnCtx) => IconButton(
                          key: Key(
                            'btn_static_playlist_track_more_${item.position}',
                          ),
                          tooltip: '更多曲目選項',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => showTrackContextMenu(
                            context: btnCtx,
                            audioService: audioService,
                            track: trackInfo,
                            anchorContext: btnCtx,
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
          onTap: trackInfo == null
              ? null
              : () => audioService.play(track: trackInfo),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final audioService = widget.audioService;
    final loading = widget.loading;
    final busyAction = widget.busyAction;
    final onPlay = widget.onPlay;
    final onImprove = widget.onImprove;
    final onOpenSnapshots = widget.onOpenSnapshots;
    final onDelete = widget.onDelete;
    final current = widget.detail;
    if (loading && current == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (current == null) {
      return const Center(
        child: Text(
          '尚未建立靜態歌單',
          style: TextStyle(color: LuminaTokens.textMuted),
        ),
      );
    }
    final summary = current.playlist;

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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary.name,
                    style: const TextStyle(
                      color: LuminaTokens.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '共 ${summary.trackCount} 首 · 已解析 ${summary.resolvedCount} · 失效 ${summary.unresolvedCount} · 快照 ${summary.snapshotCount}',
                    style: const TextStyle(
                      color: LuminaTokens.textMuted,
                      fontSize: 12,
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
                    key: const Key('btn_play_static_playlist'),
                    style: FilledButton.styleFrom(
                      backgroundColor: LuminaTokens.glassSwitchOnTrack,
                      foregroundColor: LuminaTokens.onAccentDark,
                    ),
                    onPressed: summary.resolvedCount == 0
                        ? null
                        : () => unawaited(onPlay(current)),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: Text('播放 (${summary.resolvedCount})'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('btn_improve_static_playlist'),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: LuminaTokens.hiResGoldBg,
                      foregroundColor: LuminaTokens.hiResGoldText,
                      side: const BorderSide(
                        color: LuminaTokens.hiResGoldBorder,
                      ),
                    ),
                    onPressed: busyAction
                        ? null
                        : () => unawaited(onImprove(summary)),
                    icon: const Icon(Icons.auto_fix_high_rounded, size: 16),
                    label: const Text('優化歌單'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('btn_static_playlist_snapshots'),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: LuminaTokens.glassPillBg,
                      foregroundColor: LuminaTokens.glassTextPrimary,
                      side: const BorderSide(
                        color: LuminaTokens.glassPillBorder,
                      ),
                    ),
                    onPressed: busyAction
                        ? null
                        : () => unawaited(onOpenSnapshots(summary)),
                    icon: const Icon(Icons.history_rounded, size: 16),
                    label: Text('復原歷史 (${summary.snapshotCount})'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('btn_export_static_playlist'),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: LuminaTokens.glassPillBg,
                      foregroundColor: LuminaTokens.glassTextPrimary,
                      side: const BorderSide(
                        color: LuminaTokens.glassPillBorder,
                      ),
                    ),
                    onPressed: busyAction
                        ? null
                        : () => unawaited(
                            LibraryExportDialog.show(
                              context,
                              audioService: audioService,
                              initialSource: CatalogExportStaticPlaylistSource(
                                summary.id,
                              ),
                              defaultPlaylistName: summary.name,
                            ),
                          ),
                    icon: const Icon(Icons.file_download_outlined, size: 16),
                    label: const Text('匯出'),
                  ),
                  IconButton(
                    key: Key('btn_delete_static_playlist_${summary.id}'),
                    tooltip: '刪除靜態歌單',
                    onPressed: () => unawaited(onDelete(summary)),
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
          const Divider(color: LuminaTokens.glassCardDivider, height: 22),
          Expanded(
            child: current.items.isEmpty
                ? const Center(
                    child: Text(
                      '此靜態歌單目前沒有曲目',
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
                      itemCount: current.items.length,
                      itemBuilder: (itemCtx, idx) =>
                          _buildItemRow(itemCtx, current.items[idx]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
