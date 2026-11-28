import 'package:flutter/foundation.dart';

import '../studio_models.dart';
import 'json_reader.dart';

/// Canonical audio device info matching Rust `core_types::AudioDeviceInfo`.
@immutable
class ProtocolAudioDeviceInfo {
  final String id;
  final String name;
  final String backend;
  final bool isDefault;
  final bool isActive;
  final bool supportsExclusive;
  final bool supportsDsd;
  final bool supportsDop;
  final List<int> supportedSampleRates;
  final int maxChannels;
  final bool isHdmi;
  final bool bufferSizeSupported;
  final int minBufferFrames;
  final int maxBufferFrames;
  final int defaultBufferFrames;
  final int bufferGranularity;

  const ProtocolAudioDeviceInfo({
    required this.id,
    required this.name,
    required this.backend,
    this.isDefault = false,
    this.isActive = false,
    this.supportsExclusive = false,
    this.supportsDsd = false,
    this.supportsDop = false,
    this.supportedSampleRates = const <int>[44100, 48000],
    this.maxChannels = 2,
    this.isHdmi = false,
    this.bufferSizeSupported = false,
    this.minBufferFrames = 0,
    this.maxBufferFrames = 0,
    this.defaultBufferFrames = 0,
    this.bufferGranularity = 0,
  });

  factory ProtocolAudioDeviceInfo.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    return ProtocolAudioDeviceInfo(
      id: r.requiredString('id'),
      name: r.requiredString('name'),
      backend: r.requiredString('backend', fallback: 'windows_wasapi_shared'),
      isDefault: r.requiredBool('is_default', fallback: false),
      isActive: r.requiredBool('is_active', fallback: false),
      supportsExclusive: r.requiredBool(
        'supports_exclusive',
        fallback: r.requiredBool('is_exclusive', fallback: false),
      ),
      supportsDsd: r.requiredBool('supports_dsd', fallback: false),
      supportsDop: r.requiredBool('supports_dop', fallback: false),
      supportedSampleRates: r.intList(
        'supported_sample_rates',
        fallback: const <int>[44100, 48000],
      ),
      maxChannels: r.requiredInt('max_channels', fallback: 2),
      isHdmi: r.requiredBool('is_hdmi', fallback: false),
      bufferSizeSupported:
          r.requiredBool('buffer_size_supported', fallback: false),
      minBufferFrames: r.requiredInt('min_buffer_frames', fallback: 0),
      maxBufferFrames: r.requiredInt('max_buffer_frames', fallback: 0),
      defaultBufferFrames: r.requiredInt('default_buffer_frames', fallback: 0),
      bufferGranularity: r.requiredInt('buffer_granularity', fallback: 0),
    );
  }

  factory ProtocolAudioDeviceInfo.fromLegacy(
    AudioDeviceInfo legacy, {
    bool isActive = false,
  }) {
    return ProtocolAudioDeviceInfo(
      id: legacy.id,
      name: legacy.name,
      backend: legacy.backend,
      isDefault: legacy.isDefault,
      isActive: isActive,
      supportsExclusive: legacy.isExclusive,
      supportedSampleRates: List<int>.unmodifiable(legacy.supportedSampleRates),
    );
  }

  AudioDeviceInfo toLegacy() {
    return AudioDeviceInfo(
      id: id,
      name: name,
      backend: backend,
      isDefault: isDefault,
      isExclusive: supportsExclusive,
      supportedSampleRates: supportedSampleRates,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'backend': backend,
      'is_default': isDefault,
      'is_active': isActive,
      'supports_exclusive': supportsExclusive,
      'supports_dsd': supportsDsd,
      'supports_dop': supportsDop,
      'supported_sample_rates': supportedSampleRates,
      'max_channels': maxChannels,
      'is_hdmi': isHdmi,
      'buffer_size_supported': bufferSizeSupported,
      'min_buffer_frames': minBufferFrames,
      'max_buffer_frames': maxBufferFrames,
      'default_buffer_frames': defaultBufferFrames,
      'buffer_granularity': bufferGranularity,
    };
  }

  ProtocolAudioDeviceInfo copyWith({
    String? id,
    String? name,
    String? backend,
    bool? isDefault,
    bool? isActive,
    bool? supportsExclusive,
    bool? supportsDsd,
    bool? supportsDop,
    List<int>? supportedSampleRates,
    int? maxChannels,
    bool? isHdmi,
    bool? bufferSizeSupported,
    int? minBufferFrames,
    int? maxBufferFrames,
    int? defaultBufferFrames,
    int? bufferGranularity,
  }) {
    return ProtocolAudioDeviceInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      backend: backend ?? this.backend,
      isDefault: isDefault ?? this.isDefault,
      isActive: isActive ?? this.isActive,
      supportsExclusive: supportsExclusive ?? this.supportsExclusive,
      supportsDsd: supportsDsd ?? this.supportsDsd,
      supportsDop: supportsDop ?? this.supportsDop,
      supportedSampleRates: supportedSampleRates ?? this.supportedSampleRates,
      maxChannels: maxChannels ?? this.maxChannels,
      isHdmi: isHdmi ?? this.isHdmi,
      bufferSizeSupported: bufferSizeSupported ?? this.bufferSizeSupported,
      minBufferFrames: minBufferFrames ?? this.minBufferFrames,
      maxBufferFrames: maxBufferFrames ?? this.maxBufferFrames,
      defaultBufferFrames: defaultBufferFrames ?? this.defaultBufferFrames,
      bufferGranularity: bufferGranularity ?? this.bufferGranularity,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ProtocolAudioDeviceInfo &&
        other.id == id &&
        other.name == name &&
        other.backend == backend &&
        other.isDefault == isDefault &&
        other.isActive == isActive &&
        other.supportsExclusive == supportsExclusive &&
        other.supportsDsd == supportsDsd &&
        other.supportsDop == supportsDop &&
        listEquals(other.supportedSampleRates, supportedSampleRates) &&
        other.maxChannels == maxChannels &&
        other.isHdmi == isHdmi &&
        other.bufferSizeSupported == bufferSizeSupported &&
        other.minBufferFrames == minBufferFrames &&
        other.maxBufferFrames == maxBufferFrames &&
        other.defaultBufferFrames == defaultBufferFrames &&
        other.bufferGranularity == bufferGranularity;
  }

  @override
  int get hashCode => Object.hash(
        id,
        name,
        backend,
        isDefault,
        isActive,
        supportsExclusive,
        supportsDsd,
        supportsDop,
        Object.hashAll(supportedSampleRates),
        maxChannels,
        isHdmi,
        bufferSizeSupported,
        minBufferFrames,
        maxBufferFrames,
        defaultBufferFrames,
        bufferGranularity,
      );
}
