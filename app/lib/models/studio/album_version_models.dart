part of 'studio_library_models.dart';

class AlbumVersionTrackInfo {
  final String id;
  final String title;
  final int discNumber;
  final int trackNumber;
  final int durationMs;
  final String codec;
  final int sampleRateHz;
  final int bitDepth;
  final String externalTrackId;
  final bool isDsd;
  final int preference;

  const AlbumVersionTrackInfo({
    required this.id,
    required this.title,
    required this.discNumber,
    required this.trackNumber,
    required this.durationMs,
    required this.codec,
    required this.sampleRateHz,
    required this.bitDepth,
    required this.externalTrackId,
    this.isDsd = false,
    this.preference = 0,
  });

  String get formatSummary => AudioFormat.formatLabel(
    codec: codec,
    sampleRateHz: sampleRateHz,
    bitDepth: bitDepth,
    isDsd: isDsd,
  );

  AlbumVersionTrackInfo copyWith({
    String? id,
    String? title,
    int? discNumber,
    int? trackNumber,
    int? durationMs,
    String? codec,
    int? sampleRateHz,
    int? bitDepth,
    String? externalTrackId,
    bool? isDsd,
    int? preference,
  }) {
    return AlbumVersionTrackInfo(
      id: id ?? this.id,
      title: title ?? this.title,
      discNumber: discNumber ?? this.discNumber,
      trackNumber: trackNumber ?? this.trackNumber,
      durationMs: durationMs ?? this.durationMs,
      codec: codec ?? this.codec,
      sampleRateHz: sampleRateHz ?? this.sampleRateHz,
      bitDepth: bitDepth ?? this.bitDepth,
      externalTrackId: externalTrackId ?? this.externalTrackId,
      isDsd: isDsd ?? this.isDsd,
      preference: preference ?? this.preference,
    );
  }

  factory AlbumVersionTrackInfo.fromJson(Map<String, dynamic> json) {
    final fmt = json['format'] as Map<String, dynamic>?;
    return AlbumVersionTrackInfo(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '未命名曲目',
      discNumber: (json['disc_number'] as num?)?.toInt() ?? 1,
      trackNumber: (json['track_number'] as num?)?.toInt() ?? 1,
      durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
      codec: fmt?['codec']?.toString() ?? json['codec']?.toString() ?? 'flac',
      sampleRateHz: (fmt?['sample_rate_hz'] as num?)?.toInt() ?? 44100,
      bitDepth: (fmt?['bit_depth'] as num?)?.toInt() ?? 16,
      externalTrackId: json['external_track_id']?.toString() ?? '',
      isDsd: fmt?['is_dsd'] == true || json['is_dsd'] == true,
      preference: (json['preference'] as num?)?.toInt() ?? 0,
    );
  }
}

class AlbumTrackDisplayEntry {
  final AlbumVersionTrackInfo track;
  final String displayNumber;
  final bool showDiscHeader;

  const AlbumTrackDisplayEntry({
    required this.track,
    required this.displayNumber,
    required this.showDiscHeader,
  });
}

class AlbumVersionInfo {
  final String id;
  final String provider;
  final String externalAlbumId;
  final String editionLabel;
  final String codec;
  final int sampleRateHz;
  final int bitDepth;
  final bool isDsd;
  final bool isPrimary;
  final bool isHidden;
  final double qualityScore;
  final String? manualGroupId;
  final int discCount;
  final int trackCount;
  final bool hasManualTracks;
  final List<AlbumVersionTrackInfo> tracks;

  const AlbumVersionInfo({
    required this.id,
    required this.provider,
    required this.externalAlbumId,
    required this.editionLabel,
    required this.codec,
    required this.sampleRateHz,
    required this.bitDepth,
    this.isDsd = false,
    this.isPrimary = false,
    this.isHidden = false,
    this.qualityScore = 0.0,
    this.manualGroupId,
    this.discCount = 1,
    this.trackCount = 0,
    this.hasManualTracks = false,
    this.tracks = const [],
  });

  bool get hasManualGrouping =>
      (manualGroupId != null && manualGroupId!.isNotEmpty) || hasManualTracks;

  int get effectiveTrackCount => trackCount > 0 ? trackCount : tracks.length;

  int get effectiveDiscCount {
    if (discCount > 0) return discCount;
    if (tracks.isEmpty) return 1;
    final discs = tracks.map((t) => t.discNumber).toSet().length;
    return discs > 0 ? discs : 1;
  }

  String get formatSummary => AudioFormat.formatLabel(
    codec: codec,
    sampleRateHz: sampleRateHz,
    bitDepth: bitDepth,
    isDsd: isDsd,
  );

  AlbumVersionInfo copyWith({
    String? id,
    String? provider,
    String? externalAlbumId,
    String? editionLabel,
    String? codec,
    int? sampleRateHz,
    int? bitDepth,
    bool? isDsd,
    bool? isPrimary,
    bool? isHidden,
    double? qualityScore,
    String? manualGroupId,
    bool clearManualGroupId = false,
    int? discCount,
    int? trackCount,
    bool? hasManualTracks,
    List<AlbumVersionTrackInfo>? tracks,
  }) {
    return AlbumVersionInfo(
      id: id ?? this.id,
      provider: provider ?? this.provider,
      externalAlbumId: externalAlbumId ?? this.externalAlbumId,
      editionLabel: editionLabel ?? this.editionLabel,
      codec: codec ?? this.codec,
      sampleRateHz: sampleRateHz ?? this.sampleRateHz,
      bitDepth: bitDepth ?? this.bitDepth,
      isDsd: isDsd ?? this.isDsd,
      isPrimary: isPrimary ?? this.isPrimary,
      isHidden: isHidden ?? this.isHidden,
      qualityScore: qualityScore ?? this.qualityScore,
      manualGroupId: clearManualGroupId
          ? null
          : (manualGroupId ?? this.manualGroupId),
      discCount: discCount ?? this.discCount,
      trackCount: trackCount ?? this.trackCount,
      hasManualTracks: hasManualTracks ?? this.hasManualTracks,
      tracks: tracks ?? this.tracks,
    );
  }

  List<AlbumTrackDisplayEntry> get orderedTrackEntries {
    if (tracks.isEmpty) return const [];
    final sorted = List<AlbumVersionTrackInfo>.from(tracks)
      ..sort((a, b) {
        final d = a.discNumber.compareTo(b.discNumber);
        if (d != 0) return d;
        final t = a.trackNumber.compareTo(b.trackNumber);
        if (t != 0) return t;
        final p = a.externalTrackId.compareTo(b.externalTrackId);
        if (p != 0) return p;
        return a.title.compareTo(b.title);
      });

    final distinctDiscs = sorted.map((t) => t.discNumber).toSet();
    final isMultiDisc = distinctDiscs.length > 1;

    final tracksByDisc = <int, List<AlbumVersionTrackInfo>>{};
    for (final t in sorted) {
      tracksByDisc.putIfAbsent(t.discNumber, () => []).add(t);
    }

    final entries = <AlbumTrackDisplayEntry>[];
    for (final disc in tracksByDisc.keys) {
      final discTracks = tracksByDisc[disc]!;
      final seenInDisc = <int>{};
      var hasDuplicateOrInvalid = false;
      for (final t in discTracks) {
        if (t.trackNumber <= 0 || !seenInDisc.add(t.trackNumber)) {
          hasDuplicateOrInvalid = true;
          break;
        }
      }

      for (var i = 0; i < discTracks.length; i++) {
        final t = discTracks[i];
        final numInDisc = hasDuplicateOrInvalid ? (i + 1) : t.trackNumber;
        entries.add(
          AlbumTrackDisplayEntry(
            track: t,
            displayNumber: isMultiDisc ? '${t.discNumber}-$numInDisc' : '$numInDisc',
            showDiscHeader: isMultiDisc && i == 0,
          ),
        );
      }
    }
    return entries;
  }

  factory AlbumVersionInfo.fromJson(Map<String, dynamic> json) {
    final verMap = json['version'] is Map<String, dynamic>
        ? json['version'] as Map<String, dynamic>
        : json;
    final fmt = verMap['format'] as Map<String, dynamic>?;
    final rawTracks = json['tracks'] as List<dynamic>? ?? const [];
    final parsedTracks = rawTracks
        .whereType<Map<String, dynamic>>()
        .map(AlbumVersionTrackInfo.fromJson)
        .toList();
    final rawTrackCount = (verMap['track_count'] as num?)?.toInt();
    final rawDiscCount = (verMap['disc_count'] as num?)?.toInt();
    return AlbumVersionInfo(
      id: verMap['id']?.toString() ?? '',
      provider: verMap['provider']?.toString() ?? 'local',
      externalAlbumId: verMap['external_album_id']?.toString() ?? '',
      editionLabel: verMap['edition_label']?.toString() ?? 'Standard Edition',
      codec: fmt?['codec']?.toString() ?? 'flac',
      sampleRateHz: (fmt?['sample_rate_hz'] as num?)?.toInt() ?? 44100,
      bitDepth: (fmt?['bit_depth'] as num?)?.toInt() ?? 16,
      isDsd: fmt?['is_dsd'] == true,
      isPrimary: verMap['is_primary'] == true || verMap['is_primary'] == 1,
      isHidden: verMap['is_hidden'] == true || verMap['is_hidden'] == 1,
      qualityScore: (verMap['quality_score'] as num?)?.toDouble() ?? 0.0,
      manualGroupId: verMap['manual_group_id']?.toString(),
      discCount: rawDiscCount != null && rawDiscCount > 0 ? rawDiscCount : 1,
      trackCount: rawTrackCount != null && rawTrackCount > 0
          ? rawTrackCount
          : parsedTracks.length,
      hasManualTracks: verMap['has_manual_tracks'] == true ||
          verMap['has_manual_tracks'] == 1,
      tracks: parsedTracks,
    );
  }
}
