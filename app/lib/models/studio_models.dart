import 'audio_format.dart';

enum ConnectionMode {
  localOrUsbDac,
  lanRemote,
  wanRemote;

  String get label => switch (this) {
    ConnectionMode.localOrUsbDac => '本機 / USB DAC',
    ConnectionMode.lanRemote => '區域網路遠端控制',
    ConnectionMode.wanRemote => '廣域網路直連',
  };
}

enum ReplayGainModeOption {
  off,
  track,
  album;

  String get apiValue => switch (this) {
    ReplayGainModeOption.off => 'off',
    ReplayGainModeOption.track => 'track',
    ReplayGainModeOption.album => 'album',
  };

  String get label => switch (this) {
    ReplayGainModeOption.off => '關閉',
    ReplayGainModeOption.track => '單曲增益',
    ReplayGainModeOption.album => '專輯增益',
  };

  static ReplayGainModeOption fromApi(String? raw) => switch (raw?.toLowerCase()) {
    'track' => ReplayGainModeOption.track,
    'album' => ReplayGainModeOption.album,
    _ => ReplayGainModeOption.off,
  };
}

class CanonicalAlbumSummary {
  final String id;
  final String title;
  final String artist;
  final int? year;
  final List<String> availableProviders;
  final String? albumArtist;
  final String? coverUrl;

  const CanonicalAlbumSummary({
    required this.id,
    required this.title,
    required this.artist,
    this.year,
    this.availableProviders = const ['local'],
    this.albumArtist,
    this.coverUrl,
  });

  factory CanonicalAlbumSummary.fromJson(Map<String, dynamic> json) {
    return CanonicalAlbumSummary(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '未知專輯',
      artist: json['artist_name']?.toString() ?? json['artist']?.toString() ?? '未知藝術家',
      year: (json['year'] as num?)?.toInt() ?? (json['release_year'] as num?)?.toInt(),
      availableProviders: (json['available_providers'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const ['local'],
      albumArtist: json['album_artist']?.toString(),
      coverUrl: json['cover_url']?.toString(),
    );
  }
}

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
  });

  String get formatSummary => AudioFormat.formatLabel(
    codec: codec,
    sampleRateHz: sampleRateHz,
    bitDepth: bitDepth,
    isDsd: isDsd,
  );

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
    this.tracks = const [],
  });

  String get formatSummary => AudioFormat.formatLabel(
    codec: codec,
    sampleRateHz: sampleRateHz,
    bitDepth: bitDepth,
    isDsd: isDsd,
  );

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
    return AlbumVersionInfo(
      id: verMap['id']?.toString() ?? '',
      provider: verMap['provider']?.toString() ?? 'local',
      externalAlbumId: verMap['external_album_id']?.toString() ?? '',
      editionLabel: verMap['edition_label']?.toString() ?? 'Standard Edition',
      codec: fmt?['codec']?.toString() ?? 'flac',
      sampleRateHz: (fmt?['sample_rate_hz'] as num?)?.toInt() ?? 44100,
      bitDepth: (fmt?['bit_depth'] as num?)?.toInt() ?? 16,
      isDsd: fmt?['is_dsd'] == true,
      tracks: rawTracks
          .whereType<Map<String, dynamic>>()
          .map(AlbumVersionTrackInfo.fromJson)
          .toList(),
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

  const CanonicalAlbumDetail({
    required this.id,
    required this.title,
    required this.artistName,
    this.releaseYear,
    this.editorialBio,
    this.coverUrl,
    this.versions = const [],
    this.credits = const [],
  });

  factory CanonicalAlbumDetail.fromJson(Map<String, dynamic> json) {
    final alb = json['album'] is Map<String, dynamic>
        ? json['album'] as Map<String, dynamic>
        : json;
    final rawVers = json['versions'] as List<dynamic>? ?? const [];
    final rawCreds = json['credits'] as List<dynamic>? ?? const [];
    return CanonicalAlbumDetail(
      id: alb['id']?.toString() ?? '',
      title: alb['title']?.toString() ?? 'Unknown Album',
      artistName: alb['artist_name']?.toString() ?? 'Unknown Artist',
      releaseYear: (alb['release_year'] as num?)?.toInt(),
      editorialBio: alb['editorial_bio']?.toString(),
      coverUrl: alb['cover_url']?.toString(),
      versions: rawVers
          .whereType<Map<String, dynamic>>()
          .map(AlbumVersionInfo.fromJson)
          .toList(),
      credits: rawCreds
          .whereType<Map<String, dynamic>>()
          .map(AlbumCreditInfo.fromJson)
          .toList(),
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

  const ArtistDetailInfo({
    required this.id,
    required this.name,
    required this.sortName,
    this.biography,
    this.albums = const [],
    this.credits = const [],
  });

  factory ArtistDetailInfo.fromJson(Map<String, dynamic> json) {
    final rawAlbums = json['albums'] as List<dynamic>? ?? const [];
    final rawCredits = json['credits'] as List<dynamic>? ?? const [];
    return ArtistDetailInfo(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '未知藝術家',
      sortName: json['sort_name']?.toString() ?? '',
      biography: json['biography']?.toString(),
      albums: rawAlbums
          .whereType<Map<String, dynamic>>()
          .map((e) => CanonicalAlbumSummary(
                id: e['id']?.toString() ?? '',
                title: e['title']?.toString() ?? '未知專輯',
                artist: e['artist_name']?.toString() ?? json['name']?.toString() ?? '',
                year: (e['release_year'] as num?)?.toInt(),
                coverUrl: e['cover_url']?.toString(),
              ))
          .toList(),
      credits: rawCredits
          .whereType<Map<String, dynamic>>()
          .map(AlbumCreditInfo.fromJson)
          .toList(),
    );
  }
}

class PeqBandModel {
  final String filterType;
  final double frequencyHz;
  final double gainDb;
  final double qFactor;
  final bool enabled;

  const PeqBandModel({
    this.filterType = 'peaking',
    required this.frequencyHz,
    required this.gainDb,
    this.qFactor = 0.707,
    this.enabled = true,
  });

  PeqBandModel copyWith({
    String? filterType,
    double? frequencyHz,
    double? gainDb,
    double? qFactor,
    bool? enabled,
  }) {
    return PeqBandModel(
      filterType: filterType ?? this.filterType,
      frequencyHz: frequencyHz ?? this.frequencyHz,
      gainDb: gainDb ?? this.gainDb,
      qFactor: qFactor ?? this.qFactor,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
    'filter_type': filterType,
    'frequency_hz': frequencyHz,
    'gain_db': gainDb,
    'q_factor': qFactor,
    'enabled': enabled,
  };

  factory PeqBandModel.fromJson(Map<String, dynamic> json) {
    return PeqBandModel(
      filterType: json['filter_type']?.toString() ?? 'peaking',
      frequencyHz: (json['frequency_hz'] as num?)?.toDouble() ?? 1000.0,
      gainDb: (json['gain_db'] as num?)?.toDouble() ?? 0.0,
      qFactor: (json['q_factor'] as num?)?.toDouble() ?? 0.707,
      enabled: json['enabled'] != false,
    );
  }
}

class DspPipelineConfigModel {
  final bool bypass;
  final List<PeqBandModel> peqBands;
  final bool crossfeedEnabled;
  final double crossfeedCutoffHz;
  final double crossfeedFeedLevelDb;
  final ReplayGainModeOption replayGainMode;
  final double replayGainPreampDb;
  final bool preventClipping;

  const DspPipelineConfigModel({
    this.bypass = false,
    this.peqBands = const [],
    this.crossfeedEnabled = false,
    this.crossfeedCutoffHz = 700.0,
    this.crossfeedFeedLevelDb = -6.0,
    this.replayGainMode = ReplayGainModeOption.off,
    this.replayGainPreampDb = 0.0,
    this.preventClipping = true,
  });

  static List<PeqBandModel> defaultTenBandIso() {
    const freqs = [31.0, 62.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];
    return freqs
        .map((f) => PeqBandModel(frequencyHz: f, gainDb: 0.0, qFactor: 1.414))
        .toList();
  }

  DspPipelineConfigModel copyWith({
    bool? bypass,
    List<PeqBandModel>? peqBands,
    bool? crossfeedEnabled,
    double? crossfeedCutoffHz,
    double? crossfeedFeedLevelDb,
    ReplayGainModeOption? replayGainMode,
    double? replayGainPreampDb,
    bool? preventClipping,
  }) {
    return DspPipelineConfigModel(
      bypass: bypass ?? this.bypass,
      peqBands: peqBands ?? this.peqBands,
      crossfeedEnabled: crossfeedEnabled ?? this.crossfeedEnabled,
      crossfeedCutoffHz: crossfeedCutoffHz ?? this.crossfeedCutoffHz,
      crossfeedFeedLevelDb: crossfeedFeedLevelDb ?? this.crossfeedFeedLevelDb,
      replayGainMode: replayGainMode ?? this.replayGainMode,
      replayGainPreampDb: replayGainPreampDb ?? this.replayGainPreampDb,
      preventClipping: preventClipping ?? this.preventClipping,
    );
  }

  Map<String, dynamic> toJson() => {
    'bypass': bypass,
    'peq_bands': peqBands.map((b) => b.toJson()).toList(),
    'crossfeed': {
      'enabled': crossfeedEnabled,
      'cutoff_hz': crossfeedCutoffHz,
      'feed_level_db': crossfeedFeedLevelDb,
    },
    'replay_gain': {
      'mode': replayGainMode.apiValue,
      'preamp_db': replayGainPreampDb,
      'prevent_clipping': preventClipping,
    },
  };

  factory DspPipelineConfigModel.fromJson(Map<String, dynamic> json) {
    final cf = json['crossfeed'] as Map<String, dynamic>? ?? const {};
    final rg = json['replay_gain'] as Map<String, dynamic>? ?? const {};
    final rawBands = json['peq_bands'] as List<dynamic>? ?? const [];
    return DspPipelineConfigModel(
      bypass: json['bypass'] == true,
      peqBands: rawBands
          .whereType<Map<String, dynamic>>()
          .map(PeqBandModel.fromJson)
          .toList(),
      crossfeedEnabled: cf['enabled'] == true,
      crossfeedCutoffHz: (cf['cutoff_hz'] as num?)?.toDouble() ?? 700.0,
      crossfeedFeedLevelDb: (cf['feed_level_db'] as num?)?.toDouble() ?? -6.0,
      replayGainMode: ReplayGainModeOption.fromApi(rg['mode']?.toString()),
      replayGainPreampDb: (rg['preamp_db'] as num?)?.toDouble() ?? 0.0,
      preventClipping: rg['prevent_clipping'] != false,
    );
  }
}

class AudioDeviceInfo {
  final String id;
  final String name;
  final String backend;
  final bool isDefault;
  final bool isExclusive;
  final List<int> supportedSampleRates;

  const AudioDeviceInfo({
    required this.id,
    required this.name,
    required this.backend,
    this.isDefault = false,
    this.isExclusive = false,
    this.supportedSampleRates = const [44100, 48000, 96000, 192000],
  });

  factory AudioDeviceInfo.fromJson(Map<String, dynamic> json) {
    return AudioDeviceInfo(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '預設音訊輸出',
      backend: json['backend']?.toString() ?? 'windows_wasapi_shared',
      isDefault: json['is_default'] == true,
      isExclusive: json['is_exclusive'] == true,
      supportedSampleRates: (json['supported_sample_rates'] as List<dynamic>?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          const [44100, 48000],
    );
  }
}

class AudioZoneInfo {
  final String id;
  final String name;
  final String backend;
  final String? groupId;
  final double volume;
  final bool isActive;
  final int clockOffsetUs;
  final int rttUs;
  final double driftPpm;

  const AudioZoneInfo({
    required this.id,
    required this.name,
    required this.backend,
    this.groupId,
    this.volume = 1.0,
    this.isActive = false,
    this.clockOffsetUs = 0,
    this.rttUs = 0,
    this.driftPpm = 0.0,
  });

  factory AudioZoneInfo.fromJson(Map<String, dynamic> json) {
    return AudioZoneInfo(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '播放音區',
      backend: json['backend']?.toString() ?? 'windows_wasapi_shared',
      groupId: json['group_id']?.toString(),
      volume: (json['volume'] as num?)?.toDouble() ?? 1.0,
      isActive: json['is_active'] == true,
      clockOffsetUs: (json['clock_offset_us'] as num?)?.toInt() ?? 0,
      rttUs: (json['rtt_us'] as num?)?.toInt() ?? 0,
      driftPpm: (json['drift_ppm'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

class ClockSyncMeasurementModel {
  final String zoneId;
  final int offsetUs;
  final int rttUs;
  final double driftPpm;
  final int sampleCount;

  const ClockSyncMeasurementModel({
    required this.zoneId,
    required this.offsetUs,
    required this.rttUs,
    required this.driftPpm,
    this.sampleCount = 1,
  });

  factory ClockSyncMeasurementModel.fromJson(String zoneId, Map<String, dynamic> json) {
    return ClockSyncMeasurementModel(
      zoneId: json['zone_id']?.toString() ?? zoneId,
      offsetUs: (json['offset_us'] as num?)?.toInt() ?? 0,
      rttUs: (json['rtt_us'] as num?)?.toInt() ?? 0,
      driftPpm: (json['drift_ppm'] as num?)?.toDouble() ?? 0.0,
      sampleCount: (json['sample_count'] as num?)?.toInt() ?? 1,
    );
  }
}

class ProviderStatusInfo {
  final String kind;
  final bool isConfigured;
  final bool isOnline;

  const ProviderStatusInfo({
    required this.kind,
    required this.isConfigured,
    required this.isOnline,
  });

  factory ProviderStatusInfo.fromJson(Map<String, dynamic> json) {
    return ProviderStatusInfo(
      kind: json['provider_kind']?.toString() ?? json['kind']?.toString() ?? 'local',
      isConfigured: json['is_configured'] == true,
      isOnline: json['is_online'] == true,
    );
  }
}

class TidalPkceStartInfo {
  final String authUrl;
  final String verifier;
  final String challenge;

  const TidalPkceStartInfo({
    required this.authUrl,
    required this.verifier,
    required this.challenge,
  });

  factory TidalPkceStartInfo.fromJson(Map<String, dynamic> json) {
    return TidalPkceStartInfo(
      authUrl: json['auth_url']?.toString() ?? '',
      verifier: json['verifier']?.toString() ?? '',
      challenge: json['challenge']?.toString() ?? '',
    );
  }
}

class UserProfileInfo {
  final String id;
  final String name;
  final String avatarColor;
  final bool isDefault;

  const UserProfileInfo({
    required this.id,
    required this.name,
    this.avatarColor = '#007AFF',
    this.isDefault = false,
  });

  factory UserProfileInfo.fromJson(Map<String, dynamic> json) {
    return UserProfileInfo(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '聆聽者',
      avatarColor: json['avatar_color']?.toString() ?? '#007AFF',
      isDefault: json['is_default'] == true,
    );
  }
}

class PairingInitiateInfo {
  final String pin;
  final String qrPayload;
  final int expiresInSec;

  const PairingInitiateInfo({
    required this.pin,
    required this.qrPayload,
    this.expiresInSec = 60,
  });

  factory PairingInitiateInfo.fromJson(Map<String, dynamic> json) {
    return PairingInitiateInfo(
      pin: json['pin']?.toString() ?? '',
      qrPayload: json['qr_payload']?.toString() ?? '',
      expiresInSec: (json['expires_in_sec'] as num?)?.toInt() ?? 60,
    );
  }
}

class DiscoveredServerInfo {
  final String serverName;
  final String host;
  final int port;
  final Map<String, String> txtRecords;

  const DiscoveredServerInfo({
    required this.serverName,
    required this.host,
    required this.port,
    this.txtRecords = const {},
  });

  String get httpBaseUrl => 'http://$host:$port';
}
