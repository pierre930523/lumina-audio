import '../audio_format.dart';
import '../ingestion_models.dart';

enum TrackDeleteMode {
  libraryOnly,
  moveToTrash;

  String toJson() => switch (this) {
    TrackDeleteMode.libraryOnly => 'library_only',
    TrackDeleteMode.moveToTrash => 'move_to_trash',
  };

  static TrackDeleteMode fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'move_to_trash' || 'trash' || 'recycle_bin' => TrackDeleteMode.moveToTrash,
        _ => TrackDeleteMode.libraryOnly,
      };
}

enum TrackCorruptionStatus {
  unchecked,
  ok,
  corrupt,
  unreadable;

  String toJson() => switch (this) {
    TrackCorruptionStatus.unchecked => 'unchecked',
    TrackCorruptionStatus.ok => 'ok',
    TrackCorruptionStatus.corrupt => 'corrupt',
    TrackCorruptionStatus.unreadable => 'unreadable',
  };

  String get displayLabel => switch (this) {
    TrackCorruptionStatus.unchecked => '尚未檢查',
    TrackCorruptionStatus.ok => '音訊檔案完整',
    TrackCorruptionStatus.corrupt => '音訊串流損毀或解碼異常',
    TrackCorruptionStatus.unreadable => '無法讀取檔案',
  };

  static TrackCorruptionStatus fromJson(String? raw) =>
      switch (raw?.trim().toLowerCase()) {
        'ok' => TrackCorruptionStatus.ok,
        'corrupt' => TrackCorruptionStatus.corrupt,
        'unreadable' => TrackCorruptionStatus.unreadable,
        _ => TrackCorruptionStatus.unchecked,
      };
}

class TrackMetadataLayerModel {
  final String? title;
  final String? artistName;
  final String? albumArtist;
  final String? albumTitle;
  final int? discNumber;
  final int? trackNumber;
  final int? releaseYear;
  final String? genre;
  final String? composer;
  final String? isrc;
  final String? lyrics;

  const TrackMetadataLayerModel({
    this.title,
    this.artistName,
    this.albumArtist,
    this.albumTitle,
    this.discNumber,
    this.trackNumber,
    this.releaseYear,
    this.genre,
    this.composer,
    this.isrc,
    this.lyrics,
  });

  factory TrackMetadataLayerModel.fromJson(Map<String, dynamic> json) {
    return TrackMetadataLayerModel(
      title: json['title'] as String?,
      artistName: json['artist_name'] as String?,
      albumArtist: json['album_artist'] as String?,
      albumTitle: json['album_title'] as String?,
      discNumber: (json['disc_number'] as num?)?.toInt(),
      trackNumber: (json['track_number'] as num?)?.toInt(),
      releaseYear: (json['release_year'] as num?)?.toInt(),
      genre: json['genre'] as String?,
      composer: json['composer'] as String?,
      isrc: json['isrc'] as String?,
      lyrics: json['lyrics'] as String?,
    );
  }
}

class TrackAnalysisResult {
  final String trackId;
  final TrackCorruptionStatus corruptionStatus;
  final String? analysisError;
  final double? integratedLufs;
  final double? truePeakDb;
  final double? replayGainTrackDb;
  final double? replayGainTrackPeak;
  final List<double> waveformPeaks;
  final int? bitrateKbps;
  final String? analyzedAt;

  const TrackAnalysisResult({
    required this.trackId,
    this.corruptionStatus = TrackCorruptionStatus.unchecked,
    this.analysisError,
    this.integratedLufs,
    this.truePeakDb,
    this.replayGainTrackDb,
    this.replayGainTrackPeak,
    this.waveformPeaks = const <double>[],
    this.bitrateKbps,
    this.analyzedAt,
  });

  factory TrackAnalysisResult.fromJson(Map<String, dynamic> json) {
    final peaksRaw = json['waveform_peaks'];
    final peaks = peaksRaw is List
        ? peaksRaw
              .whereType<num>()
              .map((n) => n.toDouble())
              .toList(growable: false)
        : const <double>[];
    return TrackAnalysisResult(
      trackId: json['track_id'] as String? ?? '',
      corruptionStatus: TrackCorruptionStatus.fromJson(
        json['corruption_status'] as String?,
      ),
      analysisError: json['analysis_error'] as String?,
      integratedLufs: (json['integrated_lufs'] as num?)?.toDouble(),
      truePeakDb: (json['true_peak_db'] as num?)?.toDouble(),
      replayGainTrackDb: (json['replay_gain_track_db'] as num?)?.toDouble(),
      replayGainTrackPeak: (json['replay_gain_track_peak'] as num?)?.toDouble(),
      waveformPeaks: peaks,
      bitrateKbps: (json['bitrate_kbps'] as num?)?.toInt(),
      analyzedAt: json['analyzed_at'] as String?,
    );
  }
}

class TrackFileInfo {
  final String trackId;
  final String versionId;
  final String albumGroupId;
  final String providerId;
  final String filePath;
  final bool isLocalFile;
  final String containerFormat;
  final AudioFormat format;
  final int durationMs;
  final int? bitrateKbps;
  final int? fileSizeBytes;
  final int? fileMtime;
  final bool isHidden;
  final int preference;
  final TrackCorruptionStatus corruptionStatus;
  final String? analysisError;
  final double? integratedLufs;
  final double? truePeakDb;
  final double? replayGainTrackDb;
  final double? replayGainTrackPeak;
  final List<double> waveformPeaks;
  final String? analyzedAt;
  final MetadataPolicy metaPolicy;
  final MetadataPolicy effectivePolicy;
  final bool hasUserEdits;
  final TrackMetadataLayerModel? fileLayer;
  final TrackMetadataLayerModel? cloudLayer;
  final TrackMetadataLayerModel? userEditsLayer;
  final TrackMetadataLayerModel effectiveLayer;
  final String? resolvedLyricsSource;

  const TrackFileInfo({
    required this.trackId,
    required this.versionId,
    required this.albumGroupId,
    required this.providerId,
    required this.filePath,
    required this.isLocalFile,
    required this.containerFormat,
    required this.format,
    required this.durationMs,
    this.bitrateKbps,
    this.fileSizeBytes,
    this.fileMtime,
    this.isHidden = false,
    this.preference = 0,
    this.corruptionStatus = TrackCorruptionStatus.unchecked,
    this.analysisError,
    this.integratedLufs,
    this.truePeakDb,
    this.replayGainTrackDb,
    this.replayGainTrackPeak,
    this.waveformPeaks = const <double>[],
    this.analyzedAt,
    this.metaPolicy = MetadataPolicy.inherit,
    this.effectivePolicy = MetadataPolicy.file,
    this.hasUserEdits = false,
    this.fileLayer,
    this.cloudLayer,
    this.userEditsLayer,
    this.effectiveLayer = const TrackMetadataLayerModel(),
    this.resolvedLyricsSource,
  });

  factory TrackFileInfo.fromJson(Map<String, dynamic> json) {
    final fmtMap = json['format'] is Map
        ? Map<String, dynamic>.from(json['format'] as Map)
        : const <String, dynamic>{};
    final bitrate = (json['bitrate_kbps'] as num?)?.toInt();
    final codec = AudioCodec.fromString(fmtMap['codec'] as String?);
    final fmt = AudioFormat(
      codec: codec,
      sampleRateHz: (fmtMap['sample_rate_hz'] as num?)?.toInt() ?? 44100,
      bitDepth: (fmtMap['bit_depth'] as num?)?.toInt() ?? 16,
      channels: (fmtMap['channels'] as num?)?.toInt() ?? 2,
      isDsd: fmtMap['is_dsd'] as bool? ?? false,
      bitrateKbps: bitrate,
    );

    final peaksRaw = json['waveform_peaks'];
    final peaks = peaksRaw is List
        ? peaksRaw
              .whereType<num>()
              .map((n) => n.toDouble())
              .toList(growable: false)
        : const <double>[];

    TrackMetadataLayerModel? parseLayer(dynamic raw) => raw is Map
        ? TrackMetadataLayerModel.fromJson(Map<String, dynamic>.from(raw))
        : null;

    return TrackFileInfo(
      trackId: json['track_id'] as String? ?? '',
      versionId: json['version_id'] as String? ?? '',
      albumGroupId: json['album_group_id'] as String? ?? '',
      providerId: json['provider_id'] as String? ?? 'local',
      filePath: json['file_path'] as String? ?? '',
      isLocalFile: json['is_local_file'] as bool? ?? false,
      containerFormat: json['container_format'] as String? ?? 'unknown',
      format: fmt,
      durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
      bitrateKbps: bitrate,
      fileSizeBytes: (json['file_size_bytes'] as num?)?.toInt(),
      fileMtime: (json['file_mtime'] as num?)?.toInt(),
      isHidden: json['is_hidden'] as bool? ?? false,
      preference: (json['preference'] as num?)?.toInt() ?? 0,
      corruptionStatus: TrackCorruptionStatus.fromJson(
        json['corruption_status'] as String?,
      ),
      analysisError: json['analysis_error'] as String?,
      integratedLufs: (json['integrated_lufs'] as num?)?.toDouble(),
      truePeakDb: (json['true_peak_db'] as num?)?.toDouble(),
      replayGainTrackDb: (json['replay_gain_track_db'] as num?)?.toDouble(),
      replayGainTrackPeak: (json['replay_gain_track_peak'] as num?)?.toDouble(),
      waveformPeaks: peaks,
      analyzedAt: json['analyzed_at'] as String?,
      metaPolicy: MetadataPolicy.fromJson(json['meta_policy'] as String?),
      effectivePolicy: MetadataPolicy.fromJson(
        json['effective_policy'] as String?,
      ),
      hasUserEdits: json['has_user_edits'] as bool? ?? false,
      fileLayer: parseLayer(json['file_layer']),
      cloudLayer: parseLayer(json['cloud_layer']),
      userEditsLayer: parseLayer(json['user_edits_layer']),
      effectiveLayer:
          parseLayer(json['effective_layer']) ??
          const TrackMetadataLayerModel(),
      resolvedLyricsSource: json['resolved_lyrics_source'] as String?,
    );
  }
}

class TrackVisibilityResult {
  final String trackId;
  final bool isHidden;
  final List<String> affectedAlbumIds;

  const TrackVisibilityResult({
    required this.trackId,
    required this.isHidden,
    this.affectedAlbumIds = const <String>[],
  });

  factory TrackVisibilityResult.fromJson(Map<String, dynamic> json) {
    final idsRaw = json['affected_album_ids'];
    final ids = idsRaw is List
        ? idsRaw.map((e) => e.toString()).toList(growable: false)
        : const <String>[];
    return TrackVisibilityResult(
      trackId: json['track_id'] as String? ?? '',
      isHidden: json['is_hidden'] as bool? ?? false,
      affectedAlbumIds: ids,
    );
  }
}

class ReidentifyTrackResult {
  final String trackId;
  final bool matched;
  final String? source;
  final String? musicbrainzRecordingId;
  final String? message;
  final TrackFileInfo? fileInfo;

  const ReidentifyTrackResult({
    required this.trackId,
    required this.matched,
    this.source,
    this.musicbrainzRecordingId,
    this.message,
    this.fileInfo,
  });

  factory ReidentifyTrackResult.fromJson(Map<String, dynamic> json) {
    final infoRaw = json['file_info'];
    return ReidentifyTrackResult(
      trackId: json['track_id'] as String? ?? '',
      matched: json['matched'] as bool? ?? false,
      source: json['source'] as String?,
      musicbrainzRecordingId: json['musicbrainz_recording_id'] as String?,
      message: json['message'] as String?,
      fileInfo: infoRaw is Map
          ? TrackFileInfo.fromJson(Map<String, dynamic>.from(infoRaw))
          : null,
    );
  }
}

class DeleteTrackResult {
  final String trackId;
  final TrackDeleteMode mode;
  final bool deletedFromLibrary;
  final bool movedToTrash;
  final List<String> vacatedAlbumIds;
  final int orphansPruned;
  final String? warning;

  const DeleteTrackResult({
    required this.trackId,
    required this.mode,
    required this.deletedFromLibrary,
    required this.movedToTrash,
    this.vacatedAlbumIds = const <String>[],
    this.orphansPruned = 0,
    this.warning,
  });

  factory DeleteTrackResult.fromJson(Map<String, dynamic> json) {
    final vacatedRaw = json['vacated_album_ids'];
    final vacated = vacatedRaw is List
        ? vacatedRaw.map((e) => e.toString()).toList(growable: false)
        : const <String>[];
    return DeleteTrackResult(
      trackId: json['track_id'] as String? ?? '',
      mode: TrackDeleteMode.fromJson(json['mode'] as String?),
      deletedFromLibrary: json['deleted_from_library'] as bool? ?? false,
      movedToTrash: json['moved_to_trash'] as bool? ?? false,
      vacatedAlbumIds: vacated,
      orphansPruned: (json['orphans_pruned'] as num?)?.toInt() ?? 0,
      warning: json['warning'] as String?,
    );
  }
}
