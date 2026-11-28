import '../audio_format.dart';
import '../ingestion/ingestion_cleanup_models.dart';

export 'focus_models.dart';
export 'folder_models.dart';
export 'tag_models.dart';

part 'album_version_models.dart';

class CanonicalAlbumSummary {
  final String id;
  final String? groupId;
  final String? versionId;
  final String? primaryVersionId;
  final String title;
  final String artist;
  final int? year;
  final List<String> availableProviders;
  final String? albumArtist;
  final String? coverUrl;
  final int? trackCount;
  final int discCount;
  final int versionCount;
  final int hiddenVersionCount;
  final int totalVersionCount;
  final bool isPrimary;
  final bool isPrimaryLocked;
  final bool isHidden;
  final bool isManualGroup;
  final double qualityScore;
  final String? editionLabel;
  final String? provider;
  final String? codec;
  final int? sampleRateHz;
  final int? bitDepth;
  final bool isDsd;
  final String? recordLabel;
  final int preference;

  const CanonicalAlbumSummary({
    required this.id,
    this.groupId,
    this.versionId,
    this.primaryVersionId,
    required this.title,
    required this.artist,
    this.year,
    this.availableProviders = const ['local'],
    this.albumArtist,
    this.coverUrl,
    this.trackCount,
    this.discCount = 1,
    this.versionCount = 1,
    this.hiddenVersionCount = 0,
    int? totalVersionCount,
    this.isPrimary = true,
    this.isPrimaryLocked = false,
    this.isHidden = false,
    this.isManualGroup = false,
    this.qualityScore = 0.0,
    this.editionLabel,
    this.provider,
    this.codec,
    this.sampleRateHz,
    this.bitDepth,
    this.isDsd = false,
    this.recordLabel,
    this.preference = 0,
  }) : totalVersionCount = (totalVersionCount != null && totalVersionCount > 0)
           ? totalVersionCount
           : ((versionCount + hiddenVersionCount) > 0
                 ? versionCount + hiddenVersionCount
                 : 1);

  String get effectiveGroupId =>
      (groupId != null && groupId!.isNotEmpty) ? groupId! : id;

  String get selectionKey =>
      (versionId != null && versionId!.isNotEmpty) ? versionId! : id;

  String? get formatSummary {
    if (codec == null || codec!.isEmpty) return null;
    return AudioFormat.formatLabel(
      codec: codec!,
      sampleRateHz: sampleRateHz ?? 44100,
      bitDepth: bitDepth ?? 16,
      isDsd: isDsd,
    );
  }

  factory CanonicalAlbumSummary.fromJson(Map<String, dynamic> json) {
    final providerStr = json['provider']?.toString();
    final providers = (json['available_providers'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        (providerStr != null && providerStr.isNotEmpty
            ? <String>[providerStr]
            : const ['local']);
    final versionCount = (json['version_count'] as num?)?.toInt() ?? 1;
    final hiddenVersionCount =
        (json['hidden_version_count'] as num?)?.toInt() ?? 0;
    final rawTotal = (json['total_version_count'] as num?)?.toInt();
    final rawIsPrimary = json['is_primary'];
    return CanonicalAlbumSummary(
      id: json['id']?.toString() ?? '',
      groupId: json['group_id']?.toString(),
      versionId: json['version_id']?.toString(),
      primaryVersionId: json['primary_version_id']?.toString(),
      title: json['title']?.toString() ?? '未知專輯',
      artist: json['artist_name']?.toString() ??
          json['artist']?.toString() ??
          '未知藝術家',
      year: (json['year'] as num?)?.toInt() ??
          (json['release_year'] as num?)?.toInt(),
      availableProviders: providers,
      albumArtist: json['album_artist']?.toString(),
      coverUrl: json['cover_url']?.toString(),
      trackCount: (json['track_count'] as num?)?.toInt(),
      discCount: (json['disc_count'] as num?)?.toInt() ?? 1,
      versionCount: versionCount,
      hiddenVersionCount: hiddenVersionCount,
      totalVersionCount: rawTotal,
      isPrimary: rawIsPrimary == null
          ? true
          : (rawIsPrimary == true || rawIsPrimary == 1),
      isPrimaryLocked:
          json['is_primary_locked'] == true || json['is_primary_locked'] == 1,
      isHidden: json['is_hidden'] == true || json['is_hidden'] == 1,
      isManualGroup:
          json['is_manual_group'] == true || json['is_manual_group'] == 1,
      qualityScore: (json['quality_score'] as num?)?.toDouble() ?? 0.0,
      editionLabel: json['edition_label']?.toString(),
      provider: providerStr,
      codec: json['codec']?.toString(),
      sampleRateHz: (json['sample_rate_hz'] as num?)?.toInt(),
      bitDepth: (json['bit_depth'] as num?)?.toInt(),
      isDsd: json['is_dsd'] == true || json['is_dsd'] == 1,
      recordLabel: json['record_label']?.toString(),
      preference: (json['preference'] as num?)?.toInt() ?? 0,
    );
  }
}

class AlbumCreditInfo {
  final String artistId;
  final String artistName;
  final String role;
  final String? albumId;
  final String? albumTitle;

  const AlbumCreditInfo({
    required this.artistId,
    required this.artistName,
    required this.role,
    this.albumId,
    this.albumTitle,
  });

  factory AlbumCreditInfo.fromJson(Map<String, dynamic> json) {
    return AlbumCreditInfo(
      artistId: json['artist_id']?.toString() ?? '',
      artistName: json['artist_name']?.toString() ?? 'Unknown Contributor',
      role: json['role']?.toString() ?? 'Contributor',
      albumId: json['album_id']?.toString(),
      albumTitle: json['album_title']?.toString(),
    );
  }
}

class CanonicalAlbumDetail {
  final String id;
  final String title;
  final String artistName;
  final int? releaseYear;
  final String? editorialBio;
  final String? coverUrl;
  final List<AlbumVersionInfo> versions;
  final List<AlbumCreditInfo> credits;
  final MetadataPolicy metaPolicy;
  final bool hasUserEdits;
  final String? primaryVersionId;
  final bool isPrimaryLocked;
  final int hiddenVersionCount;
  final int preference;

  const CanonicalAlbumDetail({
    required this.id,
    required this.title,
    required this.artistName,
    this.releaseYear,
    this.editorialBio,
    this.coverUrl,
    this.versions = const [],
    this.credits = const [],
    this.metaPolicy = MetadataPolicy.inherit,
    this.hasUserEdits = false,
    this.primaryVersionId,
    this.isPrimaryLocked = false,
    this.hiddenVersionCount = 0,
    this.preference = 0,
  });

  CanonicalAlbumDetail copyWith({
    String? id,
    String? title,
    String? artistName,
    int? releaseYear,
    String? editorialBio,
    String? coverUrl,
    List<AlbumVersionInfo>? versions,
    List<AlbumCreditInfo>? credits,
    MetadataPolicy? metaPolicy,
    bool? hasUserEdits,
    String? primaryVersionId,
    bool? isPrimaryLocked,
    int? hiddenVersionCount,
    int? preference,
  }) {
    return CanonicalAlbumDetail(
      id: id ?? this.id,
      title: title ?? this.title,
      artistName: artistName ?? this.artistName,
      releaseYear: releaseYear ?? this.releaseYear,
      editorialBio: editorialBio ?? this.editorialBio,
      coverUrl: coverUrl ?? this.coverUrl,
      versions: versions ?? this.versions,
      credits: credits ?? this.credits,
      metaPolicy: metaPolicy ?? this.metaPolicy,
      hasUserEdits: hasUserEdits ?? this.hasUserEdits,
      primaryVersionId: primaryVersionId ?? this.primaryVersionId,
      isPrimaryLocked: isPrimaryLocked ?? this.isPrimaryLocked,
      hiddenVersionCount: hiddenVersionCount ?? this.hiddenVersionCount,
      preference: preference ?? this.preference,
    );
  }

  factory CanonicalAlbumDetail.fromJson(Map<String, dynamic> json) {
    final alb = json['album'] is Map<String, dynamic>
        ? json['album'] as Map<String, dynamic>
        : json;
    final rawVers = json['versions'] as List<dynamic>? ?? const [];
    final rawCreds = json['credits'] as List<dynamic>? ?? const [];
    final rawPolicy = alb['meta_policy'] ?? json['meta_policy'];
    final rawHasEdits = alb['has_user_edits'] ?? json['has_user_edits'];
    final rawPrimaryId =
        json['primary_version_id'] ?? alb['primary_version_id'];
    final rawPrimaryLocked =
        json['is_primary_locked'] ?? alb['is_primary_locked'];
    final rawHiddenCount = json['hidden_version_count'];
    final parsedVersions = rawVers
        .whereType<Map<String, dynamic>>()
        .map(AlbumVersionInfo.fromJson)
        .where((v) => v.tracks.isNotEmpty)
        .toList();
    final derivedHiddenCount = rawHiddenCount != null
        ? (rawHiddenCount as num).toInt()
        : parsedVersions.where((v) => v.isHidden).length;
    return CanonicalAlbumDetail(
      id: alb['id']?.toString() ?? '',
      title: alb['title']?.toString() ?? 'Unknown Album',
      artistName: alb['artist_name']?.toString() ?? 'Unknown Artist',
      releaseYear: (alb['release_year'] as num?)?.toInt(),
      editorialBio: alb['editorial_bio']?.toString(),
      coverUrl: alb['cover_url']?.toString(),
      versions: parsedVersions,
      credits: rawCreds
          .whereType<Map<String, dynamic>>()
          .map(AlbumCreditInfo.fromJson)
          .toList(),
      metaPolicy: MetadataPolicy.fromJson(rawPolicy?.toString()),
      hasUserEdits: rawHasEdits == true || rawHasEdits == 1,
      primaryVersionId: rawPrimaryId?.toString(),
      isPrimaryLocked: rawPrimaryLocked == true || rawPrimaryLocked == 1,
      hiddenVersionCount: derivedHiddenCount,
      preference:
          (alb['preference'] as num?)?.toInt() ??
          (json['preference'] as num?)?.toInt() ??
          0,
    );
  }
}

class ArtistDetailInfo {
  final String id;
  final String name;
  final String sortName;
  final String? biography;
  final List<CanonicalAlbumSummary> albums;
  final List<AlbumCreditInfo> credits;
  final int preference;

  const ArtistDetailInfo({
    required this.id,
    required this.name,
    required this.sortName,
    this.biography,
    this.albums = const [],
    this.credits = const [],
    this.preference = 0,
  });

  factory ArtistDetailInfo.fromJson(Map<String, dynamic> json) {
    final rawAlbums = json['albums'] as List<dynamic>? ?? const [];
    final rawCredits = json['credits'] as List<dynamic>? ?? const [];
    return ArtistDetailInfo(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '未知藝術家',
      sortName: json['sort_name']?.toString() ?? '',
      biography: json['biography']?.toString(),
      preference: (json['preference'] as num?)?.toInt() ?? 0,
      albums: rawAlbums
          .whereType<Map<String, dynamic>>()
          .map((e) => CanonicalAlbumSummary(
                id: e['id']?.toString() ?? '',
                title: e['title']?.toString() ?? '未知專輯',
                artist: e['artist_name']?.toString() ?? json['name']?.toString() ?? '',
                year: (e['release_year'] as num?)?.toInt(),
                coverUrl: e['cover_url']?.toString(),
                preference: (e['preference'] as num?)?.toInt() ?? 0,
              ))
          .toList(),
      credits: rawCredits
          .whereType<Map<String, dynamic>>()
          .map(AlbumCreditInfo.fromJson)
          .toList(),
    );
  }
}
