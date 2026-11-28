part of 'album_collection_card.dart';

/// Horizontal row representation of an album for List view mode.
class AlbumCollectionListTile extends StatefulWidget {
  final CanonicalAlbumSummary album;
  final int coverRevision;
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final ListenLaterController? listenLaterController;
  final bool showCardContainer;
  final bool showHiddenMode;
  final bool multiSelectMode;
  final bool isSelected;
  final VoidCallback onOpenAlbumDetail;
  final VoidCallback? onTapTile;
  final VoidCallback? onToggleSelect;
  final VoidCallback onPlayAlbum;
  final VoidCallback? onAddToQueue;
  final VoidCallback? onOpenArtist;

  const AlbumCollectionListTile({
    super.key,
    required this.album,
    required this.audioService,
    this.libraryCache,
    this.listenLaterController,
    this.coverRevision = 0,
    this.showCardContainer = false,
    this.showHiddenMode = false,
    this.multiSelectMode = false,
    this.isSelected = false,
    required this.onOpenAlbumDetail,
    this.onTapTile,
    this.onToggleSelect,
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
        if (widget.multiSelectMode || widget.isSelected) ...[
          AlbumSelectionCheckbox(
            key: Key('album_select_checkbox_${album.selectionKey}'),
            selected: widget.isSelected,
            onTap: widget.onToggleSelect ?? () {},
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTapTile ?? widget.onOpenAlbumDetail,
              onSecondaryTapUp: (details) => _showAlbumContextMenu(
                buttonContext: context,
                globalPosition: details.globalPosition,
                onPlayAlbum: widget.onPlayAlbum,
                onAddToQueue: widget.onAddToQueue,
                onAddToListenLater: widget.listenLaterController != null
                    ? () {
                        widget.listenLaterController!.addLocalAlbum(album);
                      }
                    : null,
                onSetPreference: (pref) async {
                  widget.libraryCache?.updateEntityPreferenceSync(
                    'album_group',
                    album.effectiveGroupId,
                    pref,
                  );
                  await widget.audioService.setEntityPreference(
                    'album_group',
                    album.effectiveGroupId,
                    pref,
                  );
                },
                onOpenAlbumDetail: widget.onOpenAlbumDetail,
                onOpenArtist: widget.onOpenArtist,
                onManageTags: () => showTagPickerDialog(
                  context: context,
                  audioService: widget.audioService,
                  entityType: TagEntityType.albumGroup,
                  entityIds: <String>[album.effectiveGroupId],
                  title: '管理專輯標籤：${album.title}',
                ),
              ),
              child: Row(
                children: [
                  Opacity(
                    opacity: album.isHidden ? 0.58 : 1.0,
                    child: AlbumArtworkView(
                      album: album,
                      size: 56,
                      revision: widget.coverRevision,
                      audioService: widget.audioService,
                      libraryCache: widget.libraryCache,
                      fullResolution: false,
                      borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                      fit: BoxFit.cover,
                      border: Border.all(
                        color: widget.isSelected
                            ? LuminaTokens.accentBlue
                            : Colors.white.withValues(alpha: 0.08),
                        width: widget.isSelected ? 1.8 : 1.0,
                      ),
                      boxShadow: const [],
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                album.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: LuminaTokens.textPrimary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            if (!widget.showHiddenMode &&
                                album.totalVersionCount > 1) ...[
                              const SizedBox(width: 8),
                              AlbumVersionCountBadge(
                                key: Key(
                                  'album_version_count_badge_${album.selectionKey}',
                                ),
                                count: album.totalVersionCount,
                              ),
                            ],
                            if (widget.showHiddenMode) ...[
                              const SizedBox(width: 8),
                              if (album.isHidden)
                                AlbumStatusPill.hidden(
                                  key: Key(
                                    'album_hidden_badge_${album.selectionKey}',
                                  ),
                                )
                              else if (album.isPrimary)
                                AlbumStatusPill.primary(
                                  key: Key(
                                    'album_primary_badge_${album.selectionKey}',
                                  ),
                                  locked: album.isPrimaryLocked,
                                )
                              else
                                AlbumStatusPill.secondary(
                                  key: Key(
                                    'album_secondary_badge_${album.selectionKey}',
                                  ),
                                ),
                            ],
                          ],
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
        const SizedBox(width: 8),
        PreferenceToggleButton(
          buttonKey: Key('album_list_pref_${album.id}'),
          audioService: widget.audioService,
          libraryCache: widget.libraryCache,
          entityType: 'album_group',
          entityId: album.effectiveGroupId,
          preference: album.preference,
        ),
        if (widget.listenLaterController != null)
          IconButton(
            key: Key('album_list_listen_later_${album.id}'),
            tooltip: '加入稍後收聽',
            visualDensity: VisualDensity.compact,
            onPressed: () {
              widget.listenLaterController!.addLocalAlbum(album);
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                SnackBar(
                  content: Text('已將「${album.title}」加入稍後收聽'),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            icon: const Icon(
              Icons.watch_later_outlined,
              size: 18,
              color: LuminaTokens.glassTextSecondary,
            ),
          ),
        const SizedBox(width: 4),
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
                        ? LuminaTokens.glassSwitchOnTrack
                        : LuminaTokens.glassPillBg,
                    border: Border.all(
                      color: _playHovered
                          ? LuminaTokens.glassSwitchOnTrack
                          : LuminaTokens.glassPillBorder,
                    ),
                  ),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    size: 19,
                    color: _playHovered
                        ? LuminaTokens.onAccentDark
                        : LuminaTokens.glassTextPrimary,
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
                    onAddToListenLater: widget.listenLaterController != null
                        ? () {
                            widget.listenLaterController!.addLocalAlbum(album);
                          }
                        : null,
                    onSetPreference: (pref) async {
                      widget.libraryCache?.updateEntityPreferenceSync(
                        'album_group',
                        album.effectiveGroupId,
                        pref,
                      );
                      await widget.audioService.setEntityPreference(
                        'album_group',
                        album.effectiveGroupId,
                        pref,
                      );
                    },
                    onOpenAlbumDetail: widget.onOpenAlbumDetail,
                    onOpenArtist: widget.onOpenArtist,
                    onManageTags: () => showTagPickerDialog(
                      context: context,
                      audioService: widget.audioService,
                      entityType: TagEntityType.albumGroup,
                      entityIds: <String>[album.effectiveGroupId],
                      title: '管理專輯標籤：${album.title}',
                    ),
                  ),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _moreHovered
                          ? LuminaTokens.glassPillHoverBg
                          : LuminaTokens.glassPillBg,
                      border: Border.all(color: LuminaTokens.glassPillBorder),
                    ),
                    child: const Icon(
                      Icons.more_horiz_rounded,
                      size: 18,
                      color: LuminaTokens.glassTextPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );

    final surface = widget.showCardContainer
        ? Container(
            key: Key('album_surface_${album.id}'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: LuminaTokens.glassCardBg,
              borderRadius: BorderRadius.circular(
                LuminaTokens.glassCardRadius,
              ),
              border: Border.all(color: LuminaTokens.glassCardBorder),
            ),
            child: rowContent,
          )
        : Container(
            key: Key('album_surface_${album.id}'),
            color: Colors.transparent,
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: rowContent,
          );

    return RepaintBoundary(
      child: ScrollCardEntrance(
        child: surface,
      ),
    );
  }
}
