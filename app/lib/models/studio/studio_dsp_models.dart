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
