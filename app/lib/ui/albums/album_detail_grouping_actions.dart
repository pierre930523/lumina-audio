part of 'album_detail_page.dart';

extension _AlbumDetailGroupingActions on _AlbumDetailPageState {
  int _preferredVersionIndexFor(CanonicalAlbumDetail detail) {
    final visibleVersions = detail.versions
        .where((v) => v.tracks.isNotEmpty)
        .toList();
    if (visibleVersions.isEmpty) return 0;
    final primaryId = detail.primaryVersionId;
    if (primaryId != null && primaryId.isNotEmpty) {
      final idx = visibleVersions.indexWhere((v) => v.id == primaryId);
      if (idx >= 0) return idx;
    }
    final flaggedIdx = visibleVersions.indexWhere((v) => v.isPrimary);
    return flaggedIdx >= 0 ? flaggedIdx : 0;
  }

  Future<void> _handleVersionAction(
    CanonicalAlbumDetail detail,
    AlbumVersionInfo version,
    AlbumVersionMenuAction action,
  ) async {
    final String snackMessage;
    switch (action) {
      case AlbumVersionMenuAction.setPrimary:
        await widget.audioService.setPrimaryVersion(detail.id, version.id);
        snackMessage = '已將「${version.editionLabel}」設為鎖定主版本';
      case AlbumVersionMenuAction.resetPrimary:
        await widget.audioService.resetPrimaryVersion(detail.id);
        snackMessage = '已取消主版本鎖定，恢復依音質與完整度自動擇優';
      case AlbumVersionMenuAction.ungroup:
        await widget.audioService.ungroupVersion(version.id);
        snackMessage = '已將「${version.editionLabel}」移出成為獨立專輯';
      case AlbumVersionMenuAction.split:
        final splitResult = await showDialog<AlbumSplitDialogResult>(
          context: context,
          barrierColor: LuminaTokens.scrimBg,
          builder: (_) => AlbumSplitDialog(
            albumTitle: detail.title,
            version: version,
          ),
        );
        if (splitResult == null || !mounted) return;
        await widget.audioService.splitAlbumVersion(
          versionId: version.id,
          trackGroups: splitResult.trackGroups,
          targetMode: splitResult.targetMode,
        );
        snackMessage =
            '已拆分「${version.editionLabel}」為 ${splitResult.trackGroups.length} 組';
      case AlbumVersionMenuAction.toggleHidden:
        final nextHidden = !version.isHidden;
        await widget.audioService.setVersionHidden(
          version.id,
          isHidden: nextHidden,
        );
        snackMessage = nextHidden
            ? '已隱藏「${version.editionLabel}」'
            : '已取消隱藏「${version.editionLabel}」';
      case AlbumVersionMenuAction.resetGrouping:
        await widget.audioService.resetAlbumGrouping(version.id);
        snackMessage = '已重置「${version.editionLabel}」的手動分組鎖定';
    }

    if (!mounted) return;
    final refreshed = await widget.audioService.getAlbumDetail(widget.albumId);
    if (!mounted) return;

    if (refreshed != null) {
      widget.libraryCache?.putAlbumDetailSync(refreshed);
    }
    if (widget.libraryCache != null) {
      unawaited(widget.libraryCache!.refresh(widget.audioService));
    }

    if (refreshed == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(snackMessage)),
      );
      widget.onBack?.call();
      return;
    }

    final nextIdx = _selectedVersionIndex.clamp(
      0,
      refreshed.versions.isEmpty ? 0 : refreshed.versions.length - 1,
    );
    _setState(() {
      _detail = refreshed;
      _selectedVersionIndex = action == AlbumVersionMenuAction.setPrimary ||
              action == AlbumVersionMenuAction.resetPrimary
          ? _preferredVersionIndexFor(refreshed)
          : nextIdx;
    });
    _notifyTitleChanged();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(snackMessage),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
