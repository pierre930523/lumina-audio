part of '../mock_audio_service.dart';

mixin _MockStep4ListenLaterMixin
    on _MockAudioServiceBase, _MockAlbumGroupingMixin {
  final List<ListenLaterItem> _mockListenLater = <ListenLaterItem>[];
  int _mockListenLaterSeq = 0;

  String _nextLlId(String prefix) => '$prefix-${++_mockListenLaterSeq}';
  String _llNowIso() => DateTime.now().toUtc().toIso8601String();

  @override
  Future<ListenLaterItem?> addToListenLater({
    required String sourceKind,
    required String entityType,
    String? entityId,
    String? providerId,
    String? externalId,
    required String title,
    String artistName = '',
    String albumTitle = '',
    String? coverUrl,
    int? trackCount,
    String? metadataJson,
    String note = '',
  }) async {
    final existing = _mockListenLater.where((it) {
      if (sourceKind == 'library' && entityId != null) {
        return it.sourceKind == 'library' &&
            it.entityType == entityType &&
            it.entityId == entityId;
      }
      if (sourceKind == 'external' &&
          providerId != null &&
          externalId != null) {
        return it.sourceKind == 'external' &&
            it.providerId == providerId &&
            it.entityType == entityType &&
            it.externalId == externalId;
      }
      return false;
    }).firstOrNull;
    if (existing != null) return existing;

    final item = ListenLaterItem(
      id: _nextLlId('ll'),
      sourceKind: sourceKind,
      entityType: entityType,
      entityId: entityId,
      providerId: providerId,
      externalId: externalId,
      title: title,
      artistName: artistName,
      albumTitle: albumTitle,
      coverUrl: coverUrl,
      trackCount: trackCount,
      metadataJson: metadataJson,
      note: note,
      status: 'pending',
      addedAt: _llNowIso(),
    );
    _mockListenLater.insert(0, item);
    return item;
  }

  @override
  Future<List<ListenLaterItem>> listListenLater({String? status}) async {
    final norm = status?.trim().toLowerCase();
    final filtered = (norm == null || norm.isEmpty)
        ? _mockListenLater
        : _mockListenLater.where((it) => it.status == norm).toList();
    return List<ListenLaterItem>.unmodifiable(filtered);
  }

  @override
  Future<ListenLaterItem?> markListenLaterStatus(
    String id,
    String status,
  ) async {
    final idx = _mockListenLater.indexWhere((it) => it.id == id);
    if (idx < 0) return null;
    final norm = status.trim().toLowerCase();
    if (norm != 'pending' && norm != 'listened') return null;
    final updated = _mockListenLater[idx].copyWith(
      status: norm,
      listenedAt: norm == 'listened' ? _llNowIso() : null,
      clearListenedAt: norm == 'pending',
    );
    _mockListenLater[idx] = updated;
    return updated;
  }

  @override
  Future<ListenLaterItem?> updateListenLaterNote(String id, String note) async {
    final idx = _mockListenLater.indexWhere((it) => it.id == id);
    if (idx < 0) return null;
    final updated = _mockListenLater[idx].copyWith(note: note);
    _mockListenLater[idx] = updated;
    return updated;
  }

  @override
  Future<bool> removeListenLater(String id) async {
    final before = _mockListenLater.length;
    _mockListenLater.removeWhere((it) => it.id == id);
    return _mockListenLater.length != before;
  }

  @override
  Future<PromoteListenLaterResult?> promoteExternalToLibrary(
    String id, {
    ExternalCatalogIngestBatch? ingestBatch,
  }) async {
    final idx = _mockListenLater.indexWhere((it) => it.id == id);
    if (idx < 0) return null;
    final item = _mockListenLater[idx];
    if (!item.isExternal) return null;
    if (item.isPromoted) {
      return PromoteListenLaterResult(
        item: item,
        promotedEntityId: item.promotedEntityId!,
      );
    }

    if (ingestBatch != null) {
      await ingestExternalCatalog(ingestBatch);
    }

    final provider = item.providerId ?? 'streaming';
    final promotedAlbumId = _nextLlId('alb-promoted');
    final promotedTrackId = _nextLlId('trk-promoted');
    final albumTitle = item.albumTitle.trim().isNotEmpty
        ? item.albumTitle
        : item.title;
    final artist = item.artistName.trim().isNotEmpty
        ? item.artistName
        : 'Unknown Artist';

    final tracksToAdd = <TrackInfo>[];
    if (ingestBatch != null && ingestBatch.albums.isNotEmpty) {
      final alb = ingestBatch.albums.first;
      for (final t in alb.tracks) {
        tracksToAdd.add(
          TrackInfo(
            id: '$provider:${t.externalTrackId}',
            title: t.title,
            artist: t.artistName.isNotEmpty ? t.artistName : artist,
            album: alb.title,
            duration: Duration(milliseconds: t.durationMs),
            format: AudioFormat(
              codec: AudioCodec.fromString(t.codec),
              sampleRateHz: t.sampleRateHz ?? 44100,
              bitDepth: t.bitDepth ?? 16,
              channels: 2,
            ),
            providerName: provider,
            coverUrl: alb.coverUrl ?? item.coverUrl,
            trackNumber: t.trackNumber,
            discNumber: t.discNumber,
            albumGroupId: promotedAlbumId,
            externalAlbumId: alb.externalAlbumId,
          ),
        );
      }
    }
    if (tracksToAdd.isEmpty) {
      tracksToAdd.add(
        TrackInfo(
          id: promotedTrackId,
          title: item.title,
          artist: artist,
          album: albumTitle,
          duration: const Duration(minutes: 3, seconds: 30),
          format: const AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: 44100,
            bitDepth: 16,
            channels: 2,
          ),
          providerName: provider,
          coverUrl: item.coverUrl,
          albumGroupId: promotedAlbumId,
          externalAlbumId: item.externalId,
        ),
      );
    }

    final groups = _ensureAlbumGroups();
    groups.add(
      _MockAlbumGroupEntry(
        id: promotedAlbumId,
        title: albumTitle,
        artistName: artist,
        coverUrl: item.coverUrl,
        primaryVersionId: 'ver-$promotedAlbumId',
        versions: [
          AlbumVersionInfo(
            id: 'ver-$promotedAlbumId',
            provider: provider,
            externalAlbumId: item.externalId ?? promotedAlbumId,
            editionLabel: 'Streaming Promoted',
            codec: tracksToAdd.first.format.codec.name,
            sampleRateHz: tracksToAdd.first.format.sampleRateHz,
            bitDepth: tracksToAdd.first.format.bitDepth,
            isPrimary: true,
            trackCount: tracksToAdd.length,
            tracks: [
              for (var i = 0; i < tracksToAdd.length; i++)
                AlbumVersionTrackInfo(
                  id: tracksToAdd[i].id,
                  title: tracksToAdd[i].title,
                  discNumber: tracksToAdd[i].discNumber ?? 1,
                  trackNumber: tracksToAdd[i].trackNumber ?? (i + 1),
                  durationMs: tracksToAdd[i].duration.inMilliseconds,
                  codec: tracksToAdd[i].format.codec.name,
                  sampleRateHz: tracksToAdd[i].format.sampleRateHz,
                  bitDepth: tracksToAdd[i].format.bitDepth,
                  externalTrackId: tracksToAdd[i].id,
                ),
            ],
          ),
        ],
      ),
    );

    for (final t in tracksToAdd) {
      if (!_queue.any((e) => e.id == t.id)) {
        _queue.add(t);
      }
    }
    if (!_disposed && !_queueUpdatedController.isClosed) {
      _queueUpdatedController.add(List<TrackInfo>.unmodifiable(_queue));
    }

    final promotedEntityId = item.isTrack
        ? tracksToAdd.first.id
        : promotedAlbumId;
    final updated = item.copyWith(
      status: 'listened',
      listenedAt: _llNowIso(),
      promotedEntityId: promotedEntityId,
    );
    _mockListenLater[idx] = updated;
    return PromoteListenLaterResult(
      item: updated,
      promotedEntityId: promotedEntityId,
    );
  }
}
