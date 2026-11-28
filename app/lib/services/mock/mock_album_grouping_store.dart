part of '../mock_audio_service.dart';

class _MockAlbumGroupEntry {
  String id;
  String title;
  String artistName;
  int? releaseYear;
  String? editorialBio;
  String? coverUrl;
  String? primaryVersionId;
  bool isPrimaryLocked;
  int preference = 0;
  List<AlbumVersionInfo> versions;
  List<AlbumCreditInfo> credits;

  _MockAlbumGroupEntry({
    required this.id,
    required this.title,
    required this.artistName,
    this.releaseYear,
    this.editorialBio,
    this.coverUrl,
    this.primaryVersionId,
    this.isPrimaryLocked = false,
    required this.versions,
    this.credits = const [],
  });
}

List<_MockAlbumGroupEntry> _createDefaultMockAlbumGroups() => [
  _MockAlbumGroupEntry(
    id: 'alb-dsotm',
    title: 'The Dark Side of the Moon',
    artistName: 'Pink Floyd',
    releaseYear: 1973,
    editorialBio: '跨平台母帶高解析認證標準版本。',
    primaryVersionId: 'ver-qobuz',
    versions: [
      const AlbumVersionInfo(
        id: 'ver-qobuz',
        provider: 'qobuz',
        externalAlbumId: 'qb-001',
        editionLabel: '24-bit 高解析錄音室母帶',
        codec: 'flac',
        sampleRateHz: 96000,
        bitDepth: 24,
        isPrimary: true,
        qualityScore: 760.0,
        discCount: 1,
        trackCount: 1,
        tracks: [
          AlbumVersionTrackInfo(
            id: 'trk-001',
            title: 'Time',
            discNumber: 1,
            trackNumber: 1,
            durationMs: 245000,
            codec: 'flac',
            sampleRateHz: 96000,
            bitDepth: 24,
            externalTrackId: 'qb-trk-001',
          ),
        ],
      ),
      const AlbumVersionInfo(
        id: 'ver-local',
        provider: 'local',
        externalAlbumId: 'loc-001',
        editionLabel: 'SACD DSD64 Rip',
        codec: 'dsf',
        sampleRateHz: 2822400,
        bitDepth: 1,
        isDsd: true,
        isPrimary: false,
        qualityScore: 740.0,
        discCount: 1,
        trackCount: 1,
        tracks: [
          AlbumVersionTrackInfo(
            id: 'trk-002',
            title: 'Money',
            discNumber: 1,
            trackNumber: 2,
            durationMs: 232000,
            codec: 'dsf',
            sampleRateHz: 2822400,
            bitDepth: 1,
            externalTrackId: 'loc-trk-002',
            isDsd: true,
          ),
        ],
      ),
    ],
    credits: const [
      AlbumCreditInfo(
        artistId: 'art-pf',
        artistName: 'Pink Floyd',
        role: '主創藝術家',
        albumId: 'alb-dsotm',
        albumTitle: 'The Dark Side of the Moon',
      ),
      AlbumCreditInfo(
        artistId: 'art-ap',
        artistName: 'Alan Parsons',
        role: '錄音工程師',
        albumId: 'alb-dsotm',
        albumTitle: 'The Dark Side of the Moon',
      ),
      AlbumCreditInfo(
        artistId: 'art-dg',
        artistName: 'David Gilmour',
        role: '吉他 / 製作人',
        albumId: 'alb-dsotm',
        albumTitle: 'The Dark Side of the Moon',
      ),
    ],
  ),
  _MockAlbumGroupEntry(
    id: 'alb-wall',
    title: 'The Wall',
    artistName: 'Pink Floyd',
    releaseYear: 1979,
    editorialBio: '跨平台母帶高解析認證標準版本。',
    primaryVersionId: 'ver-wall-tidal',
    versions: [
      const AlbumVersionInfo(
        id: 'ver-wall-tidal',
        provider: 'tidal',
        externalAlbumId: 'td-002',
        editionLabel: 'Tidal Lossless',
        codec: 'flac',
        sampleRateHz: 44100,
        bitDepth: 16,
        isPrimary: true,
        qualityScore: 680.0,
        discCount: 1,
        trackCount: 1,
        tracks: [
          AlbumVersionTrackInfo(
            id: 'trk-wall-1',
            title: 'Another Brick in the Wall',
            discNumber: 1,
            trackNumber: 1,
            durationMs: 240000,
            codec: 'flac',
            sampleRateHz: 44100,
            bitDepth: 16,
            externalTrackId: 'td-trk-wall-1',
          ),
        ],
      ),
    ],
  ),
];

void _resolveMockPrimaryForGroup(_MockAlbumGroupEntry group) {
  group.versions.removeWhere((v) => v.tracks.isEmpty);
  if (group.versions.isEmpty) {
    group.primaryVersionId = null;
    return;
  }
  String? chosenId;
  if (group.isPrimaryLocked && group.primaryVersionId != null) {
    final locked = group.versions
        .where((v) => v.id == group.primaryVersionId && !v.isHidden)
        .firstOrNull;
    if (locked != null) {
      chosenId = locked.id;
    }
  }
  if (chosenId == null) {
    final candidates = group.versions.where((v) => !v.isHidden).toList();
    if (candidates.isNotEmpty) {
      candidates.sort((a, b) {
        final cmp = b.qualityScore.compareTo(a.qualityScore);
        return cmp != 0 ? cmp : a.id.compareTo(b.id);
      });
      chosenId = candidates.first.id;
    }
  }
  group.primaryVersionId = chosenId;
  group.versions = group.versions
      .map(
        (v) => v.copyWith(
          isPrimary: chosenId != null && v.id == chosenId,
          trackCount: v.tracks.length,
          discCount: v.tracks.map((t) => t.discNumber).toSet().length.clamp(1, 99),
        ),
      )
      .toList();
}

CanonicalAlbumSummary _mockSummaryFromVersion(
  _MockAlbumGroupEntry g,
  AlbumVersionInfo v,
) {
  final visibleCount = g.versions.where((x) => !x.isHidden).length;
  final hiddenCount = g.versions.where((x) => x.isHidden).length;
  return CanonicalAlbumSummary(
    id: g.id,
    groupId: g.id,
    versionId: v.id,
    primaryVersionId: g.primaryVersionId,
    title: g.title,
    artist: g.artistName,
    year: g.releaseYear,
    availableProviders: g.versions.map((x) => x.provider).toSet().toList(),
    coverUrl: g.coverUrl,
    trackCount: v.effectiveTrackCount,
    discCount: v.effectiveDiscCount,
    versionCount: visibleCount,
    hiddenVersionCount: hiddenCount,
    totalVersionCount: g.versions.length,
    isPrimary: v.isPrimary,
    isPrimaryLocked: g.isPrimaryLocked,
    isHidden: v.isHidden,
    isManualGroup: v.hasManualGrouping,
    qualityScore: v.qualityScore,
    editionLabel: v.editionLabel,
    provider: v.provider,
    codec: v.codec,
    sampleRateHz: v.sampleRateHz,
    bitDepth: v.bitDepth,
    isDsd: v.isDsd,
    preference: g.preference,
  );
}
