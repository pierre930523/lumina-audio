part of '../mock_audio_service.dart';

class _MockStaticPlaylistEntry {
  final String id;
  String name;
  final String providerId = 'local';
  String sourcePath;
  List<StaticPlaylistItemView> items;
  String updatedAt;

  _MockStaticPlaylistEntry({
    required this.id,
    required this.name,
    this.sourcePath = '',
    required this.items,
    required this.updatedAt,
  });
}

class _MockPlaylistSnapshotEntry {
  final PlaylistSnapshotRecord record;
  final List<StaticPlaylistItemView> items;

  const _MockPlaylistSnapshotEntry({required this.record, required this.items});
}

/// Rich in-memory MockAudioService implementation for Step 5 Static Playlists &
/// Playlist Improver. Bulk Edit + Album Assets live in
/// [_MockStep5BulkAssetsMixin], and Backup/Restore + Export live in
/// [_MockStep5BackupExportMixin].
mixin _MockStep5Mixin
    on
        _MockAudioServiceBase,
        _MockAlbumGroupingMixin,
        _MockFocusTagsFoldersMixin,
        _MockStep4Mixin {
  List<_MockStaticPlaylistEntry>? _mockStaticPlaylists;
  final Map<String, List<_MockPlaylistSnapshotEntry>> _mockPlaylistSnapshots =
      <String, List<_MockPlaylistSnapshotEntry>>{};
  int _mockStep5Seq = 0;

  String _nextStep5Id(String prefix) => '$prefix-${++_mockStep5Seq}';

  PlaylistTrackSummary _trackSummaryFromTrackInfo(TrackInfo t) =>
      PlaylistTrackSummary(
        trackId: t.id,
        versionId: 'ver-${t.id}',
        canonicalAlbumId: 'alb-${t.album.toLowerCase().replaceAll(' ', '-')}',
        title: t.title,
        artistName: t.artist,
        albumTitle: t.album,
        providerId: 'local',
        codec: t.format.codec.name.toLowerCase(),
        sampleRateHz: t.format.sampleRateHz,
        bitDepth: t.format.bitDepth,
        isDsd: t.format.isDsd,
        durationMs: t.duration.inMilliseconds,
        qualityScore: t.format.isDsd
            ? 850.0
            : (t.format.bitDepth * 10.0 + t.format.sampleRateHz / 1000.0),
        fileStatus: 'ok',
        filePath: t.filePath,
      );

  List<_MockStaticPlaylistEntry> _ensureStaticPlaylists() {
    if (_mockStaticPlaylists != null) return _mockStaticPlaylists!;
    final first = _queue.isNotEmpty ? _trackSummaryFromTrackInfo(_queue[0]) : null;
    final second = _queue.length > 1 ? _trackSummaryFromTrackInfo(_queue[1]) : null;
    final items = <StaticPlaylistItemView>[
      if (first != null)
        StaticPlaylistItemView(
          position: 0,
          rawEntry: first.filePath ?? first.title,
          resolvedTrackSourceId: first.trackId,
          track: first,
        ),
      if (first != null)
        StaticPlaylistItemView(
          position: 1,
          rawEntry: first.filePath ?? first.title,
          resolvedTrackSourceId: first.trackId,
          track: first,
        ),
      if (second != null)
        StaticPlaylistItemView(
          position: 2,
          rawEntry: '${second.artistName} - ${second.title}.flac',
          isMissing: true,
        ),
    ];
    _mockStaticPlaylists = <_MockStaticPlaylistEntry>[
      _MockStaticPlaylistEntry(
        id: 'pl-demo-1',
        name: '發燒試音精選',
        sourcePath: 'internal://pl-demo-1',
        items: items,
        updatedAt: _nowIso(),
      ),
    ];
    return _mockStaticPlaylists!;
  }

  StaticPlaylistSummary _summaryForPlaylist(_MockStaticPlaylistEntry entry) {
    final resolved =
        entry.items.where((i) => !i.isMissing && i.track != null).length;
    final snaps = _mockPlaylistSnapshots[entry.id]?.length ?? 0;
    return StaticPlaylistSummary(
      id: entry.id,
      providerId: entry.providerId,
      sourcePath: entry.sourcePath,
      name: entry.name,
      trackCount: entry.items.length,
      resolvedCount: resolved,
      unresolvedCount: entry.items.length - resolved,
      snapshotCount: snaps,
      updatedAt: entry.updatedAt,
    );
  }

  StaticPlaylistDetail _detailForPlaylist(_MockStaticPlaylistEntry entry) =>
      StaticPlaylistDetail(
        playlist: _summaryForPlaylist(entry),
        items: List<StaticPlaylistItemView>.unmodifiable(entry.items),
      );

  @override
  Future<List<StaticPlaylistSummary>> listStaticPlaylists() async =>
      _ensureStaticPlaylists()
          .map(_summaryForPlaylist)
          .toList(growable: false);

  @override
  Future<StaticPlaylistDetail?> createStaticPlaylist(
    CreateStaticPlaylistRequest req,
  ) async {
    final name = req.name.trim();
    if (name.isEmpty) return null;
    final id = _nextStep5Id('pl');
    final items = <StaticPlaylistItemView>[];
    for (var i = 0; i < req.trackIds.length; i++) {
      final tid = req.trackIds[i];
      final track = _queue.where((t) => t.id == tid).firstOrNull;
      final summary = track != null ? _trackSummaryFromTrackInfo(track) : null;
      items.add(
        StaticPlaylistItemView(
          position: i,
          rawEntry: summary?.filePath ?? tid,
          resolvedTrackSourceId: summary?.trackId,
          track: summary,
          isMissing: summary == null,
        ),
      );
    }
    final entry = _MockStaticPlaylistEntry(
      id: id,
      name: name,
      sourcePath: 'internal://$id',
      items: items,
      updatedAt: _nowIso(),
    );
    _ensureStaticPlaylists().add(entry);
    return _detailForPlaylist(entry);
  }

  @override
  Future<StaticPlaylistDetail?> getStaticPlaylistDetail(
    String playlistId,
  ) async {
    final entry = _ensureStaticPlaylists()
        .where((p) => p.id == playlistId)
        .firstOrNull;
    return entry != null ? _detailForPlaylist(entry) : null;
  }

  @override
  Future<bool> deleteStaticPlaylist(String playlistId) async {
    final list = _ensureStaticPlaylists();
    final before = list.length;
    list.removeWhere((p) => p.id == playlistId);
    _mockPlaylistSnapshots.remove(playlistId);
    return list.length != before;
  }

  @override
  Future<StaticPlaylistDetail?> addTracksToStaticPlaylist(
    String playlistId,
    AddStaticPlaylistTracksRequest req,
  ) async {
    final entry = _ensureStaticPlaylists()
        .where((p) => p.id == playlistId)
        .firstOrNull;
    if (entry == null) return null;
    for (final tid in req.trackIds) {
      final track = _queue.where((t) => t.id == tid).firstOrNull;
      final summary = track != null ? _trackSummaryFromTrackInfo(track) : null;
      entry.items.add(
        StaticPlaylistItemView(
          position: entry.items.length,
          rawEntry: summary?.filePath ?? tid,
          resolvedTrackSourceId: summary?.trackId,
          track: summary,
          isMissing: summary == null,
        ),
      );
    }
    entry.updatedAt = _nowIso();
    return _detailForPlaylist(entry);
  }

  @override
  Future<PlaylistImprovementReport?> analyzePlaylistImprovements(
    String playlistId,
  ) async {
    final entry = _ensureStaticPlaylists()
        .where((p) => p.id == playlistId)
        .firstOrNull;
    if (entry == null) return null;
    final suggestions = <PlaylistImprovementSuggestion>[];
    final seenByKey = <String, int>{};
    var dupCount = 0;
    var repCount = 0;
    var upgCount = 0;

    for (final item in entry.items) {
      if (item.isMissing || item.track == null) {
        final rawLower = item.rawEntry.toLowerCase();
        final match = _queue.where(
          (t) =>
              rawLower.contains(t.title.toLowerCase()) ||
              (t.filePath != null && rawLower == t.filePath!.toLowerCase()),
        ).firstOrNull;
        if (match != null) {
          repCount++;
          suggestions.add(
            PlaylistImprovementSuggestion(
              suggestionId: 'repair:${item.position}:${match.id}',
              kind: PlaylistImprovementKind.repair,
              position: item.position,
              rawEntry: item.rawEntry,
              candidateTrack: _trackSummaryFromTrackInfo(match),
              reason: '找到本地相符曲目可修復失效路徑',
              confidence: 0.92,
            ),
          );
        }
        continue;
      }
      final track = item.track!;
      final firstPos = seenByKey[track.trackId];
      if (firstPos != null) {
        dupCount++;
        suggestions.add(
          PlaylistImprovementSuggestion(
            suggestionId: 'dup:${item.position}:$firstPos',
            kind: PlaylistImprovementKind.duplicate,
            position: item.position,
            duplicateOfPosition: firstPos,
            rawEntry: item.rawEntry,
            currentTrack: track,
            reason: '與位置 #$firstPos 曲目重複',
            confidence: 1.0,
          ),
        );
        continue;
      }
      seenByKey[track.trackId] = item.position;

      final better = _queue
          .where(
            (t) =>
                t.id != track.trackId &&
                t.title.toLowerCase() == track.title.toLowerCase() &&
                t.artist.toLowerCase() == track.artistName.toLowerCase() &&
                _trackSummaryFromTrackInfo(t).qualityScore > track.qualityScore,
          )
          .firstOrNull;
      if (better != null) {
        upgCount++;
        suggestions.add(
          PlaylistImprovementSuggestion(
            suggestionId: 'upg:${item.position}:${better.id}',
            kind: PlaylistImprovementKind.upgrade,
            position: item.position,
            rawEntry: item.rawEntry,
            currentTrack: track,
            candidateTrack: _trackSummaryFromTrackInfo(better),
            reason: '曲庫中存在更高解析度版本',
            confidence: 0.95,
          ),
        );
      }
    }

    return PlaylistImprovementReport(
      playlistId: entry.id,
      playlistName: entry.name,
      totalItems: entry.items.length,
      duplicateCount: dupCount,
      repairCount: repCount,
      upgradeCount: upgCount,
      suggestions: suggestions,
    );
  }

  @override
  Future<ApplyPlaylistImprovementsResult?> applyPlaylistImprovements(
    String playlistId,
    ApplyPlaylistImprovementsRequest req,
  ) async {
    final entry = _ensureStaticPlaylists()
        .where((p) => p.id == playlistId)
        .firstOrNull;
    if (entry == null) return null;
    final report = await analyzePlaylistImprovements(playlistId);
    if (report == null) return null;

    final idSet = req.suggestionIds.toSet();
    final kindSet = req.applyKinds?.toSet();
    final selected = report.suggestions.where((s) {
      if (idSet.isNotEmpty) return idSet.contains(s.suggestionId);
      if (kindSet != null && kindSet.isNotEmpty) return kindSet.contains(s.kind);
      return true;
    }).toList(growable: false);

    if (selected.isEmpty) {
      return ApplyPlaylistImprovementsResult(
        playlistId: playlistId,
        finalTrackCount: entry.items.length,
      );
    }

    final snapId = _nextStep5Id('snap');
    final snapRecord = PlaylistSnapshotRecord(
      id: snapId,
      playlistId: playlistId,
      reason: req.reason?.trim().isNotEmpty == true
          ? req.reason!.trim()
          : 'improver',
      trackCount: entry.items.length,
      createdAt: _nowIso(),
    );
    _mockPlaylistSnapshots
        .putIfAbsent(playlistId, () => <_MockPlaylistSnapshotEntry>[])
        .insert(
          0,
          _MockPlaylistSnapshotEntry(
            record: snapRecord,
            items: List<StaticPlaylistItemView>.from(entry.items),
          ),
        );

    final removePositions = <int>{};
    final replaceByPos = <int, PlaylistTrackSummary>{};
    var dupRemoved = 0;
    var repaired = 0;
    var upgraded = 0;
    for (final s in selected) {
      switch (s.kind) {
        case PlaylistImprovementKind.duplicate:
          removePositions.add(s.position);
          dupRemoved++;
        case PlaylistImprovementKind.repair:
          if (s.candidateTrack != null) {
            replaceByPos[s.position] = s.candidateTrack!;
            repaired++;
          }
        case PlaylistImprovementKind.upgrade:
          if (s.candidateTrack != null) {
            replaceByPos[s.position] = s.candidateTrack!;
            upgraded++;
          }
      }
    }

    final nextItems = <StaticPlaylistItemView>[];
    for (final item in entry.items) {
      if (removePositions.contains(item.position)) continue;
      final repl = replaceByPos[item.position];
      nextItems.add(
        repl != null
            ? StaticPlaylistItemView(
                position: nextItems.length,
                rawEntry: repl.filePath ?? repl.title,
                resolvedTrackSourceId: repl.trackId,
                track: repl,
                isMissing: false,
              )
            : StaticPlaylistItemView(
                position: nextItems.length,
                rawEntry: item.rawEntry,
                resolvedTrackSourceId: item.resolvedTrackSourceId,
                track: item.track,
                isMissing: item.isMissing,
              ),
      );
    }
    entry.items = nextItems;
    entry.updatedAt = _nowIso();

    return ApplyPlaylistImprovementsResult(
      playlistId: playlistId,
      snapshotId: snapId,
      duplicatesRemoved: dupRemoved,
      tracksRepaired: repaired,
      tracksUpgraded: upgraded,
      finalTrackCount: entry.items.length,
    );
  }

  @override
  Future<List<PlaylistSnapshotRecord>> listPlaylistSnapshots(
    String playlistId,
  ) async =>
      (_mockPlaylistSnapshots[playlistId] ?? const <_MockPlaylistSnapshotEntry>[])
          .map((e) => e.record)
          .toList(growable: false);

  @override
  Future<RevertPlaylistSnapshotResult?> revertPlaylistSnapshot(
    String snapshotId,
  ) async {
    for (final mapEntry in _mockPlaylistSnapshots.entries) {
      final snap = mapEntry.value
          .where((e) => e.record.id == snapshotId)
          .firstOrNull;
      if (snap == null) continue;
      final pl = _ensureStaticPlaylists()
          .where((p) => p.id == mapEntry.key)
          .firstOrNull;
      if (pl == null) return null;
      pl.items = List<StaticPlaylistItemView>.from(snap.items);
      pl.updatedAt = _nowIso();
      return RevertPlaylistSnapshotResult(
        playlistId: pl.id,
        snapshotId: snapshotId,
        restoredTrackCount: pl.items.length,
      );
    }
    return null;
  }
}
