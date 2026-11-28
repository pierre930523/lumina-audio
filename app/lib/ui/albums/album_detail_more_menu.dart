part of 'album_detail_page.dart';

enum _AlbumMoreMenuAction {
  listenLater,
  manageTags,
  openArtist,
  digitalBooklet,
  artworkGallery,
  prefLove,
  prefNormal,
  prefBan,
  editMetadata,
  setCover,
  clearCover,
  rescanTags,
  versionSetPrimary,
  versionResetPrimary,
  versionUngroup,
  versionSplit,
}

extension _AlbumDetailMoreMenu on _AlbumDetailPageState {
  bool _isAlbumSavedInListenLater(CanonicalAlbumDetail detail) {
    final ll = widget.listenLaterController;
    if (ll == null) return false;
    final parsedStreaming = _parseStreamingAlbumId(widget.albumId);
    if (parsedStreaming != null) {
      return ll.isSaved(
        entityType: 'album',
        providerId: parsedStreaming.kind,
        externalId: parsedStreaming.rawId,
      );
    }
    return ll.isSaved(entityType: 'album', entityId: detail.id);
  }

  Future<void> _setAlbumPreference(
    CanonicalAlbumDetail detail,
    int nextPref,
  ) async {
    if (detail.id.trim().isEmpty || detail.preference == nextPref) return;
    final prevPref = detail.preference;
    _setState(() {
      _detail = detail.copyWith(preference: nextPref);
    });
    widget.libraryCache?.updateEntityPreferenceSync(
      'album_group',
      detail.id,
      nextPref,
    );
    try {
      final res = await widget.audioService.setEntityPreference(
        'album_group',
        detail.id,
        nextPref,
      );
      if (!mounted) return;
      if (res == null) {
        _setState(() {
          _detail = (_detail ?? detail).copyWith(preference: prevPref);
        });
        widget.libraryCache?.updateEntityPreferenceSync(
          'album_group',
          detail.id,
          prevPref,
        );
      } else {
        _setState(() {
          _detail = (_detail ?? detail).copyWith(preference: res.preference);
        });
        widget.libraryCache?.updateEntityPreferenceSync(
          'album_group',
          detail.id,
          res.preference,
        );
      }
    } catch (_) {
      if (!mounted) return;
      _setState(() {
        _detail = (_detail ?? detail).copyWith(preference: prevPref);
      });
      widget.libraryCache?.updateEntityPreferenceSync(
        'album_group',
        detail.id,
        prevPref,
      );
    }
  }

  Future<void> _handleRescanAlbumTags(CanonicalAlbumDetail detail) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await widget.audioService.startTagRescan(force: true);
    if (!mounted) return;
    final refreshed = await widget.audioService.getAlbumDetail(widget.albumId);
    if (!mounted) return;
    if (refreshed != null) {
      widget.libraryCache?.putAlbumDetailSync(refreshed);
      _setState(() {
        _detail = refreshed;
      });
    }
    if (widget.libraryCache != null) {
      unawaited(widget.libraryCache!.refresh(widget.audioService));
    }
    messenger?.showSnackBar(
      SnackBar(
        content: Text('已啟動重新掃描標籤（${detail.title}）'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _showAlbumMoreOptionsMenu(
    BuildContext anchorContext,
    CanonicalAlbumDetail detail,
    AlbumVersionInfo? ver,
  ) async {
    final isStreamingAlbum = widget.albumId.startsWith('streaming:');
    final isListenLaterSaved = _isAlbumSavedInListenLater(detail);
    final hasArtist = detail.artistName.trim().isNotEmpty;
    final hasBooklets = _albumAssets?.pdfs.isNotEmpty == true;
    final hasGallery = _albumAssets?.images.isNotEmpty == true;
    final hasMultiVersion =
        !isStreamingAlbum && ver != null && detail.versions.length > 1;

    final entries = <LuminaContextMenuEntry<_AlbumMoreMenuAction>>[];

    final group1 = <LuminaContextMenuEntry<_AlbumMoreMenuAction>>[
      if (widget.listenLaterController != null)
        LuminaContextMenuAction<_AlbumMoreMenuAction>(
          key: const Key('btn_album_detail_listen_later'),
          value: _AlbumMoreMenuAction.listenLater,
          label: isListenLaterSaved ? '已在稍後收聽' : '稍後收聽',
          icon: isListenLaterSaved
              ? Icons.watch_later_rounded
              : Icons.watch_later_outlined,
          iconColor: isListenLaterSaved ? LuminaTokens.accentBlue : null,
        ),
      if (!isStreamingAlbum)
        const LuminaContextMenuAction<_AlbumMoreMenuAction>(
          key: Key('btn_album_menu_manage_tags'),
          value: _AlbumMoreMenuAction.manageTags,
          label: '管理專輯標籤...',
          icon: Icons.label_outline_rounded,
        ),
      if (hasArtist)
        const LuminaContextMenuAction<_AlbumMoreMenuAction>(
          key: Key('btn_album_menu_open_artist'),
          value: _AlbumMoreMenuAction.openArtist,
          label: '檢視藝術家頁面',
          icon: Icons.person_outline_rounded,
        ),
      if (hasBooklets)
        const LuminaContextMenuAction<_AlbumMoreMenuAction>(
          key: Key('btn_album_digital_booklet'),
          value: _AlbumMoreMenuAction.digitalBooklet,
          label: '數位小冊子',
          icon: Icons.menu_book_rounded,
        ),
      if (hasGallery)
        const LuminaContextMenuAction<_AlbumMoreMenuAction>(
          key: Key('btn_album_artwork_gallery'),
          value: _AlbumMoreMenuAction.artworkGallery,
          label: '檢視專輯圖集',
          icon: Icons.photo_library_outlined,
        ),
    ];

    if (group1.isNotEmpty) {
      entries.add(const LuminaContextMenuSectionLabel('收藏與瀏覽'));
      entries.addAll(group1);
    }

    if (!isStreamingAlbum) {
      if (entries.isNotEmpty) {
        entries.add(const LuminaContextMenuDivider());
      }
      entries.addAll(<LuminaContextMenuEntry<_AlbumMoreMenuAction>>[
        const LuminaContextMenuSectionLabel('喜好設定'),
        LuminaContextMenuAction<_AlbumMoreMenuAction>(
          key: const Key('btn_album_pref_love'),
          value: _AlbumMoreMenuAction.prefLove,
          label: '設為喜愛',
          icon: PreferenceToggleButton.iconFor(1),
          iconColor: PreferenceToggleButton.colorFor(1),
          selected: detail.preference == 1,
        ),
        LuminaContextMenuAction<_AlbumMoreMenuAction>(
          key: const Key('btn_album_pref_normal'),
          value: _AlbumMoreMenuAction.prefNormal,
          label: '普通（預設）',
          icon: Icons.favorite_border_rounded,
          iconColor: LuminaTokens.textSecondary,
          selected: detail.preference == 0,
        ),
        LuminaContextMenuAction<_AlbumMoreMenuAction>(
          key: const Key('btn_album_pref_ban'),
          value: _AlbumMoreMenuAction.prefBan,
          label: '封鎖此專輯',
          icon: Icons.block_rounded,
          destructive: true,
          selected: detail.preference == -1,
        ),
      ]);
    }

    if (entries.isNotEmpty) {
      entries.add(const LuminaContextMenuDivider());
    }
    entries.addAll(const <LuminaContextMenuEntry<_AlbumMoreMenuAction>>[
      LuminaContextMenuSectionLabel('詮釋資料與封面'),
      LuminaContextMenuAction<_AlbumMoreMenuAction>(
        key: Key('btn_edit_album_metadata'),
        value: _AlbumMoreMenuAction.editMetadata,
        label: '編輯詮釋資料',
        icon: Icons.edit_outlined,
      ),
      LuminaContextMenuAction<_AlbumMoreMenuAction>(
        key: Key('btn_set_album_cover'),
        value: _AlbumMoreMenuAction.setCover,
        label: '設定外部封面...',
        icon: Icons.image_outlined,
      ),
      LuminaContextMenuAction<_AlbumMoreMenuAction>(
        key: Key('btn_clear_album_cover'),
        value: _AlbumMoreMenuAction.clearCover,
        label: '清除自訂封面',
        icon: Icons.clear_rounded,
      ),
    ]);

    if (!isStreamingAlbum) {
      entries.addAll(<LuminaContextMenuEntry<_AlbumMoreMenuAction>>[
        const LuminaContextMenuDivider(),
        const LuminaContextMenuSectionLabel('曲庫與版本'),
        const LuminaContextMenuAction<_AlbumMoreMenuAction>(
          key: Key('btn_album_rescan_tags'),
          value: _AlbumMoreMenuAction.rescanTags,
          label: '重新掃描曲庫標籤',
          icon: Icons.refresh_rounded,
        ),
        if (hasMultiVersion && !ver.isPrimary)
          const LuminaContextMenuAction<_AlbumMoreMenuAction>(
            key: Key('btn_album_version_set_primary'),
            value: _AlbumMoreMenuAction.versionSetPrimary,
            label: '將目前版本設為主版本',
            icon: Icons.star_rounded,
          ),
        if (hasMultiVersion && ver.isPrimary && detail.isPrimaryLocked)
          const LuminaContextMenuAction<_AlbumMoreMenuAction>(
            key: Key('btn_album_version_reset_primary'),
            value: _AlbumMoreMenuAction.versionResetPrimary,
            label: '取消主版本鎖定',
            icon: Icons.lock_open_rounded,
          ),
        if (hasMultiVersion)
          const LuminaContextMenuAction<_AlbumMoreMenuAction>(
            key: Key('btn_album_version_ungroup'),
            value: _AlbumMoreMenuAction.versionUngroup,
            label: '將目前版本移出為獨立專輯',
            icon: Icons.call_split_rounded,
          ),
        if (hasMultiVersion && ver.tracks.length > 1)
          const LuminaContextMenuAction<_AlbumMoreMenuAction>(
            key: Key('btn_album_version_split'),
            value: _AlbumMoreMenuAction.versionSplit,
            label: '拆分目前版本曲目...',
            icon: Icons.content_cut_rounded,
          ),
      ]);
    }

    final action = await showLuminaContextMenu<_AlbumMoreMenuAction>(
      context: anchorContext,
      anchorContext: anchorContext,
      menuKey: const Key('album_more_options_menu'),
      minWidth: 230,
      maxWidth: 280,
      preferAnchorRightAlign: false,
      entries: entries,
    );
    if (action == null || !mounted) return;

    switch (action) {
      case _AlbumMoreMenuAction.listenLater:
        await _addCurrentAlbumToListenLater(detail);
      case _AlbumMoreMenuAction.manageTags:
        await _promptManageAlbumTags(detail);
      case _AlbumMoreMenuAction.openArtist:
        _handleOpenArtist(detail.artistName, detail);
      case _AlbumMoreMenuAction.digitalBooklet:
        await _handleOpenDigitalBooklet();
      case _AlbumMoreMenuAction.artworkGallery:
        await _openAlbumImageGallery();
      case _AlbumMoreMenuAction.prefLove:
        await _setAlbumPreference(detail, 1);
      case _AlbumMoreMenuAction.prefNormal:
        await _setAlbumPreference(detail, 0);
      case _AlbumMoreMenuAction.prefBan:
        await _setAlbumPreference(detail, -1);
      case _AlbumMoreMenuAction.editMetadata:
        await _promptEditMetadata(detail);
      case _AlbumMoreMenuAction.setCover:
        await _promptSetExternalCover();
      case _AlbumMoreMenuAction.clearCover:
        await _handleClearCover();
      case _AlbumMoreMenuAction.rescanTags:
        await _handleRescanAlbumTags(detail);
      case _AlbumMoreMenuAction.versionSetPrimary:
        if (ver != null) {
          await _handleVersionAction(
            detail,
            ver,
            AlbumVersionMenuAction.setPrimary,
          );
        }
      case _AlbumMoreMenuAction.versionResetPrimary:
        if (ver != null) {
          await _handleVersionAction(
            detail,
            ver,
            AlbumVersionMenuAction.resetPrimary,
          );
        }
      case _AlbumMoreMenuAction.versionUngroup:
        if (ver != null) {
          await _handleVersionAction(
            detail,
            ver,
            AlbumVersionMenuAction.ungroup,
          );
        }
      case _AlbumMoreMenuAction.versionSplit:
        if (ver != null) {
          await _handleVersionAction(
            detail,
            ver,
            AlbumVersionMenuAction.split,
          );
        }
    }
  }
}
