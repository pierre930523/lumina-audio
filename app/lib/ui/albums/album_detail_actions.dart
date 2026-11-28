part of 'album_detail_page.dart';

extension _AlbumDetailActions on _AlbumDetailPageState {
  Future<void> _promptSetExternalCover() async {
    final txt = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      barrierColor: LuminaTokens.scrimBg,
      builder: (ctx) => Dialog(
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
            boxShadow: const [
              BoxShadow(
                color: Color(0x88000000),
                blurRadius: 32,
                offset: Offset(0, 14),
              ),
            ],
            padding: const EdgeInsets.all(LuminaTokens.spaceLg),
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '設定專輯外部封面',
                    style: TextStyle(
                      color: LuminaTokens.glassTextPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: LuminaTokens.spaceMd),
                  TextField(
                    controller: txt,
                    key: const Key('input_album_cover_path'),
                    style: const TextStyle(
                      color: LuminaTokens.glassTextPrimary,
                      fontSize: 13,
                    ),
                    decoration: InputDecoration(
                      hintText: 'C:\\Music\\cover.jpg',
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
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          LuminaTokens.radiusSm,
                        ),
                        borderSide: const BorderSide(
                          color: LuminaTokens.glassPillBorder,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(
                          LuminaTokens.radiusSm,
                        ),
                        borderSide: const BorderSide(
                          color: LuminaTokens.focusRing,
                          width: 1.5,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: LuminaTokens.spaceSm,
                        vertical: LuminaTokens.spaceSm,
                      ),
                    ),
                  ),
                  const SizedBox(height: LuminaTokens.spaceLg),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: LuminaTokens.glassTextSecondary,
                        ),
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: LuminaTokens.spaceXs),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: LuminaTokens.glassSwitchOnTrack,
                          foregroundColor: LuminaTokens.onAccentDark,
                        ),
                        onPressed: () => Navigator.of(ctx).pop(txt.text.trim()),
                        child: const Text('設定'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (path != null && path.isNotEmpty) {
      final cleaned = path.replaceAll(RegExp(r'''^["']|["']$'''), '').trim();
      if (cleaned.isNotEmpty) {
        await widget.audioService.setUserCover(widget.albumId, cleaned);
        widget.libraryCache?.invalidateArtwork(widget.albumId);
        if (mounted) {
          _setState(() => _coverRevision++);
        }
      }
    }
  }

  Future<void> _handleClearCover() async {
    await widget.audioService.clearUserCover(widget.albumId);
    widget.libraryCache?.invalidateArtwork(widget.albumId);
    if (mounted) {
      _setState(() => _coverRevision++);
    }
  }

  Future<void> _promptEditMetadata(CanonicalAlbumDetail detail) async {
    final isStreamingAlbum = widget.albumId.startsWith('streaming:');
    final result = await showDialog<
      ({String action, String title, String artist, MetadataPolicy policy})
    >(
      context: context,
      barrierColor: LuminaTokens.scrimBg,
      builder: (_) => _EditAlbumMetadataDialog(
        initialTitle: detail.title,
        initialArtist: detail.artistName,
        initialPolicy: detail.metaPolicy,
        isStreamingAlbum: isStreamingAlbum,
      ),
    );
    if (result == null || !mounted) return;

    if (result.action == 'clear') {
      await widget.audioService.revertEntityToFileMeta('album', detail.id);
    } else if (result.action == 'save') {
      final edits = <String, dynamic>{};
      if (result.title.isNotEmpty && result.title != detail.title) {
        edits['title'] = result.title;
      }
      if (result.artist.isNotEmpty && result.artist != detail.artistName) {
        edits['artist_name'] = result.artist;
      }
      if (edits.isNotEmpty) {
        await widget.audioService.setEntityUserEdits('album', detail.id, edits);
      }
      if (!isStreamingAlbum && result.policy != detail.metaPolicy) {
        await widget.audioService.setEntityMetaPolicy(
          'album',
          detail.id,
          result.policy,
        );
      }
    }

    final refreshed = await widget.audioService.getAlbumDetail(widget.albumId);
    final overrides = await widget.audioService.getMetadataOverrides(
      'album',
      widget.albumId,
    );
    if (!mounted) return;
    if (refreshed != null) {
      widget.libraryCache?.putAlbumDetailSync(refreshed);
    }
    if (widget.libraryCache != null) {
      unawaited(widget.libraryCache!.refresh(widget.audioService));
    }
    _setState(() {
      if (refreshed != null) {
        _detail = refreshed;
      }
      _overrides = overrides;
    });
    _notifyTitleChanged();
  }

  TrackInfo _toTrackInfo(
    CanonicalAlbumDetail d,
    AlbumVersionInfo ver,
    AlbumVersionTrackInfo vTrack,
  ) {
    final ext = vTrack.externalTrackId;
    final hasUri = ext.contains('/') ||
        ext.contains('\\') ||
        ext.startsWith('http://') ||
        ext.startsWith('https://');
    final providerMeta = StreamingProviderMeta.byKind(ver.provider);
    return TrackInfo(
      id: vTrack.id,
      title: vTrack.title,
      artist: d.artistName,
      album: d.title,
      duration: Duration(milliseconds: vTrack.durationMs),
      format: AudioFormat(
        codec: AudioCodec.fromString(vTrack.codec),
        sampleRateHz: vTrack.sampleRateHz,
        bitDepth: vTrack.bitDepth,
        channels: 2,
        isDsd: ver.isDsd || vTrack.isDsd,
      ),
      providerName: providerMeta?.name ?? ver.provider,
      trackNumber: vTrack.trackNumber,
      discNumber: vTrack.discNumber,
      albumArtUrl: d.coverUrl,
      coverUrl: d.coverUrl,
      filePath: hasUri ? ext : null,
      albumGroupId: d.id,
      preference: vTrack.preference,
    );
  }

  List<TrackInfo> _buildVersionTracks(
    CanonicalAlbumDetail d,
    AlbumVersionInfo? ver,
  ) {
    if (ver == null || ver.tracks.isEmpty) return const <TrackInfo>[];
    final q = widget.audioService.queue;
    return ver.orderedTrackEntries
        .map((e) {
          final existing = q.where((t) => t.id == e.track.id).firstOrNull;
          if (existing != null) {
            return existing.copyWith(preference: e.track.preference);
          }
          return _toTrackInfo(d, ver, e.track);
        })
        .toList(growable: false);
  }

  Future<void> _addCurrentAlbumToListenLater(CanonicalAlbumDetail d) async {
    final ll = widget.listenLaterController;
    if (ll == null) return;
    final streaming = _parseStreamingAlbumId(widget.albumId);
    if (streaming != null) {
      await ll.addStreamingAlbum(
        StreamingAlbum(
          id: streaming.rawId,
          providerKind: streaming.kind,
          title: d.title,
          artist: d.artistName,
          year: d.releaseYear,
          coverUrl: d.coverUrl,
          trackCount: d.versions.firstOrNull?.tracks.length,
        ),
        detail: d,
      );
    } else {
      await ll.add(
        sourceKind: 'library',
        entityType: 'album',
        entityId: d.id,
        title: d.title,
        artistName: d.artistName,
        albumTitle: d.title,
        coverUrl: d.coverUrl,
        trackCount: d.versions.firstOrNull?.tracks.length,
      );
    }
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('已將「${d.title}」加入稍後收聽'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  TrackInfo? _findTrack(
    CanonicalAlbumDetail d, {
    String? title,
    AlbumVersionTrackInfo? versionTrack,
  }) {
    final q = widget.audioService.queue;
    if (versionTrack != null) {
      final byId = q.where((t) => t.id == versionTrack.id).firstOrNull;
      if (byId != null) return byId;
    }
    final inAlbum = q
        .where(
          (t) =>
              t.album == d.title ||
              t.album.toLowerCase().startsWith(d.title.toLowerCase()),
        )
        .toList();
    final visibleVersions = d.versions
        .where((v) => v.tracks.isNotEmpty)
        .toList();
    final targetTitle = versionTrack?.title ?? title;
    if (targetTitle != null) {
      final hit = inAlbum.where((t) => t.title == targetTitle).firstOrNull ??
          q.where((t) => t.title == targetTitle).firstOrNull;
      if (hit != null) return hit;
    } else if (inAlbum.isNotEmpty && visibleVersions.isEmpty) {
      return inAlbum.first;
    }

    final ver = visibleVersions.isNotEmpty
        ? visibleVersions[
            _selectedVersionIndex.clamp(0, visibleVersions.length - 1)
          ]
        : null;
    if (ver == null || ver.tracks.isEmpty) {
      return inAlbum.firstOrNull;
    }
    final ordered = ver.orderedTrackEntries;
    final vTrack = versionTrack ??
        (targetTitle != null
            ? (ver.tracks.where((t) => t.title == targetTitle).firstOrNull ??
                ordered.first.track)
            : ordered.first.track);
    return _toTrackInfo(d, ver, vTrack);
  }

  Future<void> _playTrack(
    CanonicalAlbumDetail d, {
    String? title,
    AlbumVersionTrackInfo? versionTrack,
  }) async {
    final track = _findTrack(d, title: title, versionTrack: versionTrack);
    if (track == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('音樂庫中找不到此專輯的可播放曲目')),
      );
      return;
    }
    final visibleVersions = d.versions
        .where((v) => v.tracks.isNotEmpty)
        .toList();
    final ver = visibleVersions.isNotEmpty
        ? visibleVersions[
            _selectedVersionIndex.clamp(0, visibleVersions.length - 1)
          ]
        : null;
    final allAlbumTracks = _buildVersionTracks(d, ver);
    final isStreamingAlbum = widget.albumId.startsWith('streaming:');
    if (isStreamingAlbum && widget.onPlayStreamingTrack != null) {
      widget.onPlayStreamingTrack!(
        track,
        queueContext: allAlbumTracks.isNotEmpty ? allAlbumTracks : <TrackInfo>[track],
      );
      return;
    }
    final isExplicitTrackClick = versionTrack != null || title != null;
    if (allAlbumTracks.isNotEmpty) {
      if (!isExplicitTrackClick &&
          allAlbumTracks.every((t) => t.preference == -1)) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('此專輯所有曲目皆已封鎖')),
        );
        return;
      }
      await widget.audioService.playQueue(
        allAlbumTracks,
        excludeBanned: true,
        explicitTrack: isExplicitTrackClick ? track : null,
      );
      return;
    }
    await widget.audioService.play(track: track);
  }

  void _addTrackToQueue(
    CanonicalAlbumDetail d,
    AlbumVersionTrackInfo vTrack,
  ) {
    final track = _findTrack(d, title: vTrack.title, versionTrack: vTrack);
    if (track == null) return;
    unawaited(widget.audioService.enqueueTracks([track], excludeBanned: false));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('已將「${track.title}」加入播放佇列'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _addAlbumToQueue(
    CanonicalAlbumDetail d,
    AlbumVersionInfo? ver,
  ) async {
    final allTracks = _buildVersionTracks(d, ver);
    final added = await widget.audioService.enqueueTracks(
      allTracks,
      excludeBanned: true,
    );
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          added > 0 ? '已將 $added 首曲目加入播放佇列' : '無可加入的新曲目（或皆已封鎖）',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _promptManageAlbumTags(CanonicalAlbumDetail detail) async {
    final modified = await showTagPickerDialog(
      context: context,
      audioService: widget.audioService,
      entityType: TagEntityType.albumGroup,
      entityIds: <String>[detail.id],
      title: '管理專輯標籤：${detail.title}',
    );
    if (!modified || !mounted) return;
    final tags = await widget.audioService.getEntityTags(
      TagEntityType.albumGroup,
      detail.id,
    );
    if (!mounted) return;
    _setState(() => _albumTags = tags);
  }

  Future<void> _promptManageTrackTags(AlbumVersionTrackInfo track) async {
    await showTagPickerDialog(
      context: context,
      audioService: widget.audioService,
      entityType: TagEntityType.track,
      entityIds: <String>[track.id],
      title: '管理曲目標籤：${track.title}',
    );
  }

  Future<void> _loadAlbumAssets(String targetId) async {
    final epoch = ++_assetsLoadEpoch;
    if (widget.albumId.startsWith('streaming:') || targetId.trim().isEmpty) {
      if (mounted && _albumAssets != null) {
        _setState(() => _albumAssets = null);
      }
      return;
    }
    try {
      final resp = await widget.audioService.getAlbumAssets(targetId);
      if (!mounted || epoch != _assetsLoadEpoch) return;
      if (_albumAssets != resp) {
        _setState(() => _albumAssets = resp);
      }
    } catch (_) {
      if (!mounted || epoch != _assetsLoadEpoch) return;
    }
  }

  Future<void> _handleOpenDigitalBooklet() async {
    final pdfs = _albumAssets?.pdfs ?? const <AlbumAssetRecord>[];
    if (pdfs.isEmpty) return;
    final AlbumAssetRecord? chosen;
    if (pdfs.length == 1) {
      chosen = pdfs.first;
    } else {
      chosen = await showAlbumPdfPickerDialog(context, pdfs: pdfs);
    }
    if (chosen == null || !mounted) return;
    final opened = await widget.audioService.openAlbumPdfAsset(chosen);
    if (!opened && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            '無法開啟數位小冊子：${chosen.displayName.isNotEmpty ? chosen.displayName : chosen.id}',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _openAlbumImageGallery() async {
    final images = _albumAssets?.images ?? const <AlbumAssetRecord>[];
    if (images.isEmpty || !mounted) return;
    await AlbumAssetGalleryLightbox.show(
      context,
      audioService: widget.audioService,
      images: images,
    );
  }
}
