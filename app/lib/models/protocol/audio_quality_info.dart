import 'package:flutter/foundation.dart';

import '../audio_format.dart';
import 'json_reader.dart';

/// Canonical audio stream quality metadata matching Rust `core_types::AudioQualityInfo`.
@immutable
class AudioQualityInfo {
  final String codec;
  final int sampleRateHz;
  final int bitDepth;
  final int channels;
  final int? bitrateKbps;
  final String outputMode;
  final bool isDsd;
  final String? dsdRate;
  final bool bitPerfect;

  const AudioQualityInfo({
    required this.codec,
    required this.sampleRateHz,
    required this.bitDepth,
    required this.channels,
    this.bitrateKbps,
    this.outputMode = 'pcm',
    this.isDsd = false,
    this.dsdRate,
    this.bitPerfect = false,
  });

  factory AudioQualityInfo.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    return AudioQualityInfo(
      codec: r.requiredString('codec', fallback: 'flac'),
      sampleRateHz: r.requiredInt('sample_rate_hz', fallback: 44100),
      bitDepth: r.requiredInt('bit_depth', fallback: 16),
      channels: r.requiredInt('channels', fallback: 2),
      bitrateKbps: r.optionalInt('bitrate_kbps'),
      outputMode: r.requiredString('output_mode', fallback: 'pcm'),
      isDsd: r.requiredBool('is_dsd', fallback: false),
      dsdRate: r.nonEmptyString('dsd_rate'),
      bitPerfect: r.requiredBool('bit_perfect', fallback: false),
    );
  }

  factory AudioQualityInfo.fromAudioFormat(
    AudioFormat format, {
    String outputMode = 'pcm',
    bool bitPerfect = false,
    String? dsdRate,
  }) {
    return AudioQualityInfo(
      codec: format.codec.name,
      sampleRateHz: format.sampleRateHz,
      bitDepth: format.bitDepth,
      channels: format.channels,
      bitrateKbps: format.bitrateKbps,
      outputMode: outputMode,
      isDsd: format.isDsd,
      dsdRate: dsdRate,
      bitPerfect: bitPerfect,
    );
  }

  AudioFormat toAudioFormat() {
    return AudioFormat(
      codec: AudioCodec.fromString(codec),
      sampleRateHz: sampleRateHz > 0 ? sampleRateHz : 44100,
      bitDepth: bitDepth > 0 ? bitDepth : 16,
      channels: channels > 0 ? channels : 2,
      isDsd: isDsd,
      bitrateKbps: bitrateKbps,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'codec': codec,
      'sample_rate_hz': sampleRateHz,
      'bit_depth': bitDepth,
      'channels': channels,
      if (bitrateKbps != null) 'bitrate_kbps': bitrateKbps,
      'output_mode': outputMode,
      'is_dsd': isDsd,
      if (dsdRate != null) 'dsd_rate': dsdRate,
      'bit_perfect': bitPerfect,
    };
  }

  AudioQualityInfo copyWith({
    String? codec,
    int? sampleRateHz,
    int? bitDepth,
    int? channels,
    int? bitrateKbps,
    String? outputMode,
    bool? isDsd,
    String? dsdRate,
    bool? bitPerfect,
  }) {
    return AudioQualityInfo(
      codec: codec ?? this.codec,
      sampleRateHz: sampleRateHz ?? this.sampleRateHz,
      bitDepth: bitDepth ?? this.bitDepth,
      channels: channels ?? this.channels,
      bitrateKbps: bitrateKbps ?? this.bitrateKbps,
      outputMode: outputMode ?? this.outputMode,
      isDsd: isDsd ?? this.isDsd,
      dsdRate: dsdRate ?? this.dsdRate,
      bitPerfect: bitPerfect ?? this.bitPerfect,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AudioQualityInfo &&
        other.codec == codec &&
        other.sampleRateHz == sampleRateHz &&
        other.bitDepth == bitDepth &&
        other.channels == channels &&
        other.bitrateKbps == bitrateKbps &&
        other.outputMode == outputMode &&
        other.isDsd == isDsd &&
        other.dsdRate == dsdRate &&
        other.bitPerfect == bitPerfect;
  }

  @override
  int get hashCode => Object.hash(
        codec,
        sampleRateHz,
        bitDepth,
        channels,
        bitrateKbps,
        outputMode,
        isDsd,
        dsdRate,
        bitPerfect,
      );
}
