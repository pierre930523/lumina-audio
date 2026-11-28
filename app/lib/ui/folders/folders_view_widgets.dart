part of 'folders_view.dart';

extension _FoldersViewWidgets on _FoldersViewState {
  Widget _buildBreadcrumbBar(List<FolderBreadcrumb> breadcrumbs) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: LuminaTokens.spaceLg),
      child: FrostedGlassContainer(
        key: const Key('folder_breadcrumb_bar'),
        blurSigma: 0,
        enableBackdropBlur: false,
        color: LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(color: LuminaTokens.glassCardBorder),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: SingleChildScrollView(
          controller: _breadcrumbScrollController,
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              InkWell(
                key: const Key('folder_breadcrumb_root'),
                borderRadius: BorderRadius.circular(6),
                onTap: _loadRoots,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.storage_rounded,
                        size: 14,
                        color: LuminaTokens.glassTextSecondary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '所有資料夾',
                        style: TextStyle(
                          color: _currentFolderId == null
                              ? LuminaTokens.glassTextPrimary
                              : LuminaTokens.glassTextSecondary,
                          fontSize: 12.5,
                          fontWeight: _currentFolderId == null
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              for (var i = 0; i < breadcrumbs.length; i++) ...[
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 16,
                  color: LuminaTokens.textMuted,
                ),
                InkWell(
                  key: Key('folder_breadcrumb_${breadcrumbs[i].id}'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => _openFolder(breadcrumbs[i].id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Text(
                      breadcrumbs[i].name,
                      style: TextStyle(
                        color: i == breadcrumbs.length - 1
                            ? LuminaTokens.glassTextPrimary
                            : LuminaTokens.glassTextSecondary,
                        fontSize: 12.5,
                        fontWeight: i == breadcrumbs.length - 1
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRootsList() {
    if (_roots.isEmpty) {
      return Center(
        child: FrostedGlassContainer(
          blurSigma: LuminaTokens.glassCardBlur,
          color: LuminaTokens.glassCardBg,
          borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
          border: Border.all(color: LuminaTokens.glassCardBorder),
          padding: const EdgeInsets.all(LuminaTokens.spaceLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '尚未索引任何本機資料夾',
                style: TextStyle(
                  color: LuminaTokens.glassTextPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (widget.onOpenLibrarySettings != null) ...[
                const SizedBox(height: LuminaTokens.spaceSm),
                OutlinedButton(
                  onPressed: widget.onOpenLibrarySettings,
                  child: const Text('前往設定掃描資料夾'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return SmoothScrollWrapper(
      controller: _rootsScrollController,
      child: ListView.separated(
        key: const Key('folder_roots_list'),
        controller: _rootsScrollController,
        padding: const EdgeInsets.fromLTRB(
          LuminaTokens.spaceLg,
          LuminaTokens.spaceSm,
          LuminaTokens.spaceLg,
          LuminaTokens.bottomScrollClearance,
        ),
        itemCount: _roots.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) => _buildFolderTile(
          _roots[index],
          tileKey: Key('folder_root_${_roots[index].id}'),
          showStatusBadge: true,
        ),
      ),
    );
  }

  Widget _buildFolderContents(FolderNode? folder) {
    final subfolders = _contents?.subfolders ?? const <FolderNode>[];
    final tracks = _contents?.tracks ?? const <TrackInfo>[];
    if (subfolders.isEmpty && tracks.isEmpty) {
      return const Center(
        child: Text(
          '此資料夾目前沒有子資料夾或曲目',
          style: TextStyle(color: LuminaTokens.textMuted, fontSize: 13),
        ),
      );
    }

    return SmoothScrollWrapper(
      controller: _contentsScrollController,
      child: ListView(
        key: const Key('folder_contents_list'),
        controller: _contentsScrollController,
        padding: const EdgeInsets.fromLTRB(
          LuminaTokens.spaceLg,
          LuminaTokens.spaceSm,
          LuminaTokens.spaceLg,
          LuminaTokens.bottomScrollClearance,
        ),
        children: [
        if (folder != null)
          Padding(
            padding: const EdgeInsets.only(bottom: LuminaTokens.spaceXs),
            child: Text(
              '${folder.displayPath}  •  直接 ${folder.directTrackCount} 首 / 總計 ${folder.recursiveTrackCount} 首',
              style: const TextStyle(
                color: LuminaTokens.textMuted,
                fontSize: 12,
              ),
            ),
          ),
        if (subfolders.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              '子資料夾',
              style: TextStyle(
                color: LuminaTokens.glassTextSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final sub in subfolders) ...[
            _buildFolderTile(
              sub,
              tileKey: Key('folder_sub_${sub.id}'),
              showStatusBadge: false,
            ),
            const SizedBox(height: 6),
          ],
          const SizedBox(height: LuminaTokens.spaceSm),
        ],
        if (tracks.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              '曲目',
              style: TextStyle(
                color: LuminaTokens.glassTextSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final track in tracks) _buildTrackTile(track),
        ],
      ],
      ),
    );
  }

  Widget _buildFolderTile(
    FolderNode node, {
    required Key tileKey,
    required bool showStatusBadge,
  }) {
    return FrostedGlassContainer(
      key: tileKey,
      blurSigma: 0,
      enableBackdropBlur: false,
      color: LuminaTokens.glassCardBg,
      borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
      border: Border.all(color: LuminaTokens.glassCardBorder),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
          hoverColor: LuminaTokens.glassRowHoverBg,
          onTap: () => _openFolder(node.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Icon(
                  Icons.folder_rounded,
                  size: 22,
                  color: node.isOnline
                      ? LuminaTokens.accentBlue
                      : LuminaTokens.textMuted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              node.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: LuminaTokens.glassTextPrimary,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (showStatusBadge) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: (node.isOnline
                                        ? LuminaTokens.statusSuccess
                                        : LuminaTokens.statusWarning)
                                    .withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                node.isOnline ? '連線中' : '離線',
                                style: TextStyle(
                                  color: node.isOnline
                                      ? LuminaTokens.statusSuccess
                                      : LuminaTokens.statusWarning,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${node.displayPath}  •  直接 ${node.directTrackCount} 首 · 總計 ${node.recursiveTrackCount} 首',
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
                IconButton(
                  key: Key('btn_play_folder_${node.id}'),
                  tooltip: '播放此資料夾',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(
                    Icons.play_arrow_rounded,
                    size: 19,
                    color: LuminaTokens.glassTextPrimary,
                  ),
                  onPressed: () => _playFolder(node.id),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTrackTile(TrackInfo track) {
    void refreshFolder() {
      if (_currentFolderId != null) {
        _openFolder(_currentFolderId!);
      } else {
        _loadRoots();
      }
    }

    return GestureDetector(
      onSecondaryTapUp: (details) => showTrackContextMenu(
        context: context,
        audioService: widget.audioService,
        track: track,
        globalPosition: details.globalPosition,
        libraryCache: widget.libraryCache,
        onTrackUpdated: (_) => refreshFolder(),
        onTrackDeleted: refreshFolder,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        child: ListTile(
          key: Key('folder_track_${track.id}'),
          dense: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
          ),
          hoverColor: LuminaTokens.glassRowHoverBg,
          leading: const Icon(
            Icons.music_note_rounded,
            size: 18,
            color: LuminaTokens.textSecondary,
          ),
          title: Text(
            track.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: LuminaTokens.glassTextPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(
            '${track.artist} • ${track.album} • ${track.format.label}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: LuminaTokens.textMuted, fontSize: 11.5),
          ),
          onTap: () => widget.audioService.play(track: track),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: Key('btn_folder_track_album_${track.id}'),
                tooltip: '前往專輯詳情',
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.album_outlined,
                  size: 17,
                  color: LuminaTokens.glassTextSecondary,
                ),
                onPressed: () => _jumpToAlbumForTrack(track),
              ),
              IconButton(
                key: Key('btn_folder_track_tags_${track.id}'),
                tooltip: '管理標籤',
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.label_outlined,
                  size: 17,
                  color: LuminaTokens.glassTextSecondary,
                ),
                onPressed: () => showTagPickerDialog(
                  context: context,
                  audioService: widget.audioService,
                  entityType: TagEntityType.track,
                  entityIds: <String>[track.id],
                  title: '管理曲目標籤：${track.title}',
                ),
              ),
              Builder(
                builder: (btnCtx) => IconButton(
                  key: Key('btn_folder_track_more_${track.id}'),
                  tooltip: '更多曲目選項',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(
                    Icons.more_horiz_rounded,
                    size: 18,
                    color: LuminaTokens.textMuted,
                  ),
                  onPressed: () => showTrackContextMenu(
                    context: btnCtx,
                    audioService: widget.audioService,
                    track: track,
                    anchorContext: btnCtx,
                    libraryCache: widget.libraryCache,
                    onTrackUpdated: (_) => refreshFolder(),
                    onTrackDeleted: refreshFolder,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
