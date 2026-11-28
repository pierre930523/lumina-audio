part of 'listen_later_view.dart';

class _ListenLaterItemCard extends StatelessWidget {
  final ListenLaterItem item;
  final bool busy;
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final VoidCallback onPlay;
  final VoidCallback onEditNote;
  final VoidCallback onToggleStatus;
  final VoidCallback? onPromote;
  final VoidCallback onRemove;

  const _ListenLaterItemCard({
    super.key,
    required this.item,
    required this.busy,
    required this.audioService,
    this.libraryCache,
    required this.onPlay,
    required this.onEditNote,
    required this.onToggleStatus,
    this.onPromote,
    required this.onRemove,
  });

  TrackInfo? _resolveTrackInfo() {
    if (item.isAlbum) return null;
    final meta = item.parseMetadata() ?? const <String, dynamic>{};
    final trackId = item.isLibrary
        ? (item.entityId?.trim().isNotEmpty == true ? item.entityId! : item.id)
        : '${item.providerId ?? "qobuz"}:${item.externalId ?? item.id}';
    return TrackInfo(
      id: trackId,
      title: item.title,
      artist: item.artistName.isNotEmpty ? item.artistName : '未知藝術家',
      album: item.albumTitle.isNotEmpty ? item.albumTitle : item.title,
      duration: Duration(
        milliseconds: (meta['duration_ms'] as num?)?.toInt() ?? 0,
      ),
      format: AudioFormat(
        codec: AudioCodec.fromString(meta['codec']?.toString()),
        sampleRateHz: (meta['sample_rate_hz'] as num?)?.toInt() ?? 44100,
        bitDepth: (meta['bit_depth'] as num?)?.toInt() ?? 16,
        channels: 2,
      ),
      providerName: item.providerId ?? 'Local Library',
      coverUrl: item.coverUrl,
    );
  }

  @override
  Widget build(BuildContext context) {
    final trackInfo = _resolveTrackInfo();
    final providerMeta = item.providerId != null
        ? StreamingProviderMeta.byKind(item.providerId!)
        : null;
    final subtitleParts = <String>[
      if (item.artistName.trim().isNotEmpty) item.artistName.trim(),
      if (item.albumTitle.trim().isNotEmpty &&
          item.albumTitle.trim() != item.title.trim())
        item.albumTitle.trim(),
      item.isAlbum ? '專輯' : '曲目',
      if (item.trackCount != null && item.trackCount! > 0)
        '${item.trackCount} 首',
    ];

    return GestureDetector(
      onSecondaryTapUp: trackInfo == null
          ? null
          : (details) => showTrackContextMenu(
              context: context,
              audioService: audioService,
              track: trackInfo,
              globalPosition: details.globalPosition,
              libraryCache: libraryCache,
            ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: LuminaTokens.glassCardBg,
          borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
          border: Border.all(color: LuminaTokens.glassCardBorder),
        ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 52,
              height: 52,
              child: item.isLibrary
                  ? AlbumArtworkView(
                      album: CanonicalAlbumSummary(
                        id: item.entityId ?? item.id,
                        title: item.title,
                        artist: item.artistName,
                        coverUrl: item.coverUrl,
                      ),
                      size: 52,
                      audioService: audioService,
                      libraryCache: libraryCache,
                      fullResolution: false,
                    )
                  : StreamingCoverImage(
                      url: item.coverUrl,
                      targetSize: 300,
                      width: 52,
                      height: 52,
                      fallbackBuilder: (_) => Container(
                        color: LuminaTokens.glassPillBg,
                        child: Icon(
                          item.isAlbum
                              ? Icons.album_rounded
                              : Icons.music_note_rounded,
                          color: LuminaTokens.textMuted,
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.glassTextPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (providerMeta != null)
                      providerMeta.buildBadge(boxSize: 16, borderRadius: 4)
                    else
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
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
                          item.isLibrary ? '曲庫' : (item.providerId ?? '外部'),
                          style: const TextStyle(
                            color: LuminaTokens.textSecondary,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    if (item.isPromoted) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: LuminaTokens.statusSuccess.withValues(
                            alpha: 0.16,
                          ),
                          borderRadius: BorderRadius.circular(
                            LuminaTokens.radiusPill,
                          ),
                        ),
                        child: const Text(
                          '已收編',
                          style: TextStyle(
                            color: LuminaTokens.statusSuccess,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitleParts.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.textMuted,
                    fontSize: 12,
                  ),
                ),
                if (item.note.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    item.note,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: LuminaTokens.glassTextSecondary,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                key: Key('btn_listen_later_play_${item.id}'),
                tooltip: '直接播放',
                onPressed: onPlay,
                icon: const Icon(
                  Icons.play_arrow_rounded,
                  size: 20,
                  color: LuminaTokens.glassTextPrimary,
                ),
              ),
              IconButton(
                key: Key('btn_listen_later_note_${item.id}'),
                tooltip: '編輯備註',
                onPressed: onEditNote,
                icon: const Icon(
                  Icons.edit_note_rounded,
                  size: 19,
                  color: LuminaTokens.glassTextSecondary,
                ),
              ),
              IconButton(
                key: Key('btn_listen_later_toggle_${item.id}'),
                tooltip: item.isPending ? '標記為已聽' : '移回待聽',
                onPressed: onToggleStatus,
                icon: Icon(
                  item.isPending
                      ? Icons.check_circle_outline_rounded
                      : Icons.replay_rounded,
                  size: 18,
                  color: item.isPending
                      ? LuminaTokens.statusSuccess
                      : LuminaTokens.glassTextSecondary,
                ),
              ),
              if (onPromote != null)
                OutlinedButton.icon(
                  key: Key('btn_listen_later_promote_${item.id}'),
                  onPressed: busy ? null : onPromote,
                  style: OutlinedButton.styleFrom(
                    backgroundColor: LuminaTokens.glassPillBg,
                    foregroundColor: LuminaTokens.glassTextPrimary,
                    side: const BorderSide(color: LuminaTokens.glassPillBorder),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                  ),
                  icon: busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.library_add_rounded, size: 15),
                  label: const Text('收編至曲庫', style: TextStyle(fontSize: 12)),
                ),
              IconButton(
                key: Key('btn_listen_later_remove_${item.id}'),
                tooltip: '從清單移除',
                onPressed: onRemove,
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  size: 18,
                  color: LuminaTokens.textMuted,
                ),
              ),
              if (trackInfo != null)
                Builder(
                  builder: (btnCtx) => IconButton(
                    key: Key('btn_listen_later_track_more_${item.id}'),
                    tooltip: '更多曲目選項',
                    onPressed: () => showTrackContextMenu(
                      context: btnCtx,
                      audioService: audioService,
                      track: trackInfo,
                      anchorContext: btnCtx,
                      libraryCache: libraryCache,
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
        ],
      ),
    ),
  );
  }
}

class _ListenLaterNoteDialog extends StatefulWidget {
  final ListenLaterItem item;

  const _ListenLaterNoteDialog({required this.item});

  @override
  State<_ListenLaterNoteDialog> createState() => _ListenLaterNoteDialogState();
}

class _ListenLaterNoteDialogState extends State<_ListenLaterNoteDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.item.note);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: FrostedGlassContainer(
          blurSigma: LuminaTokens.glassDialogBlur,
          color: LuminaTokens.glassDialogBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
          border: Border.all(color: LuminaTokens.glassCardBorder),
          padding: const EdgeInsets.all(LuminaTokens.spaceLg),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '編輯備註：${widget.item.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.glassTextPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceMd),
                TextField(
                  key: Key('input_listen_later_note_${widget.item.id}'),
                  controller: _ctrl,
                  maxLines: 3,
                  style: const TextStyle(
                    color: LuminaTokens.glassTextPrimary,
                    fontSize: 13,
                  ),
                  decoration: InputDecoration(
                    hintText: '輸入聽後感或推薦備註...',
                    hintStyle: const TextStyle(color: LuminaTokens.textMuted),
                    filled: true,
                    fillColor: LuminaTokens.glassPillBg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        LuminaTokens.radiusSm,
                      ),
                      borderSide: const BorderSide(
                        color: LuminaTokens.glassPillBorder,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceMd),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('btn_save_listen_later_note'),
                      onPressed: () =>
                          Navigator.of(context).pop(_ctrl.text.trim()),
                      style: FilledButton.styleFrom(
                        backgroundColor: LuminaTokens.glassSwitchOnTrack,
                        foregroundColor: LuminaTokens.onAccentDark,
                      ),
                      child: const Text('儲存'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
