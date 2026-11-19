import '../models/playback_state.dart';

class SmartPlaylist {
  final String id;
  final String name;
  final String description;
  final bool isBuiltIn;
  final bool losslessOnly;
  final bool dsdOnly;
  final int minSampleRateHz;
  final int minBitDepth;
  final String keyword;

  const SmartPlaylist({
    required this.id,
    required this.name,
    this.description = '',
    this.isBuiltIn = false,
    this.losslessOnly = false,
    this.dsdOnly = false,
    this.minSampleRateHz = 0,
    this.minBitDepth = 0,
    this.keyword = '',
  });

  List<TrackInfo> evaluate(List<TrackInfo> tracks) {
    final kw = keyword.trim().toLowerCase();
    return tracks.where((t) {
      if (losslessOnly && !t.format.codec.isLossless) return false;
      if (dsdOnly && !t.format.isDsd) return false;
      if (minSampleRateHz > 0 && t.format.sampleRateHz < minSampleRateHz) {
        return false;
      }
      if (minBitDepth > 0 && !t.format.isDsd && t.format.bitDepth < minBitDepth) {
        return false;
      }
      if (kw.isNotEmpty) {
        final hay = '${t.title} ${t.artist} ${t.album} ${t.providerName}'
            .toLowerCase();
        if (!hay.contains(kw)) return false;
      }
      return true;
    }).toList();
  }

  List<String> get ruleTags {
    final tags = <String>[];
    if (dsdOnly) tags.add('DSD 原生');
    if (losslessOnly && !dsdOnly) tags.add('無損格式');
    if (minSampleRateHz > 0) {
      final khz = minSampleRateHz % 1000 == 0
          ? '${minSampleRateHz ~/ 1000} kHz+'
          : '${(minSampleRateHz / 1000).toStringAsFixed(1)} kHz+';
      tags.add(khz);
    }
    if (minBitDepth > 0) tags.add('$minBitDepth-bit+');
    if (keyword.trim().isNotEmpty) tags.add('關鍵字「${keyword.trim()}」');
    if (tags.isEmpty) tags.add('全部典藏曲目');
    return tags;
  }

  SmartPlaylist copyWith({
    String? id,
    String? name,
    String? description,
    bool? isBuiltIn,
    bool? losslessOnly,
    bool? dsdOnly,
    int? minSampleRateHz,
    int? minBitDepth,
    String? keyword,
  }) {
    return SmartPlaylist(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
      losslessOnly: losslessOnly ?? this.losslessOnly,
      dsdOnly: dsdOnly ?? this.dsdOnly,
      minSampleRateHz: minSampleRateHz ?? this.minSampleRateHz,
      minBitDepth: minBitDepth ?? this.minBitDepth,
      keyword: keyword ?? this.keyword,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'is_built_in': isBuiltIn,
    'lossless_only': losslessOnly,
    'dsd_only': dsdOnly,
    'min_sample_rate_hz': minSampleRateHz,
    'min_bit_depth': minBitDepth,
    'keyword': keyword,
  };

  factory SmartPlaylist.fromJson(Map<String, dynamic> json) {
    return SmartPlaylist(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '自訂智慧歌單',
      description: json['description']?.toString() ?? '',
      isBuiltIn: json['is_built_in'] == true,
      losslessOnly: json['lossless_only'] == true,
      dsdOnly: json['dsd_only'] == true,
      minSampleRateHz: (json['min_sample_rate_hz'] as num?)?.toInt() ?? 0,
      minBitDepth: (json['min_bit_depth'] as num?)?.toInt() ?? 0,
      keyword: json['keyword']?.toString() ?? '',
    );
  }

  static const List<SmartPlaylist> builtInPresets = [
    SmartPlaylist(
      id: 'sp-hires',
      name: 'Hi-Res 高解析精選',
      description: '自動篩選 96 kHz 以上高取樣率無損母帶或 DSD',
      isBuiltIn: true,
      losslessOnly: true,
      minSampleRateHz: 96000,
    ),
    SmartPlaylist(
      id: 'sp-lossless',
      name: '無損母帶純享',
      description: '自動篩選所有 FLAC / WAV / ALAC / DSD 無損曲目',
      isBuiltIn: true,
      losslessOnly: true,
    ),
    SmartPlaylist(
      id: 'sp-dsd',
      name: 'DSD 原生軌典藏',
      description: '自動聚合 DSF / DSDIFF 高解析位元流',
      isBuiltIn: true,
      dsdOnly: true,
    ),
    SmartPlaylist(
      id: 'sp-all',
      name: '工作室全曲庫',
      description: '完整匯聚目前已收錄的所有音軌',
      isBuiltIn: true,
    ),
  ];
}
