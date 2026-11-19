enum DsdOutputModeOption {
  auto(0, 'Auto', '自動協商 (Native > DoP > PCM)'),
  nativeDsd(1, 'Native DSD', 'ASIO 原生 DSD 直出'),
  dop(2, 'DoP', 'DoP v1.1 (0x05/0xFA)'),
  dsdToPcm(3, 'DSD-to-PCM', '即時轉碼 PCM (非原生)');

  final int ffiCode;
  final String shortLabel;
  final String description;
  const DsdOutputModeOption(this.ffiCode, this.shortLabel, this.description);

  static DsdOutputModeOption fromFfiCode(int code) {
    return DsdOutputModeOption.values.firstWhere(
      (e) => e.ffiCode == code,
      orElse: () => DsdOutputModeOption.auto,
    );
  }
}

class AudioDeviceCapabilitiesModel {
  final String deviceId;
  final String name;
  final String backend;
  final String transport;
  final bool isDefault;
  final bool isOsDefault;
  final bool isExclusive;
  final bool isHdmi;
  final bool hardwareSupportsExclusive;
  final List<int> supportedSampleRates;
  final List<int> supportedBitDepths;
  final List<int> supportedContainerBits;
  final List<int> supportedChannels;
  final List<String> supportedOutputModes;
  final bool supportsNativeDsd;
  final bool supportsDop;
  final bool supportsFloat32;
  final String? maxDsdRate;
  final bool asioAvailable;
  final String? asioDriverName;
  final bool exclusiveAvailable;
  final bool bufferSizeSupported;
  final int? minBufferFrames;
  final int? maxBufferFrames;
  final int? defaultBufferFrames;
  final int? bufferGranularity;
  final String? probeNote;

  const AudioDeviceCapabilitiesModel({
    required this.deviceId,
    required this.name,
    required this.backend,
    required this.transport,
    this.isDefault = false,
    this.isOsDefault = false,
    this.isExclusive = false,
    this.isHdmi = false,
    this.hardwareSupportsExclusive = false,
    this.supportedSampleRates = const [],
    this.supportedBitDepths = const [],
    this.supportedContainerBits = const [],
    this.supportedChannels = const [],
    this.supportedOutputModes = const [],
    this.supportsNativeDsd = false,
    this.supportsDop = false,
    this.supportsFloat32 = false,
    this.maxDsdRate,
    this.asioAvailable = false,
    this.asioDriverName,
    this.exclusiveAvailable = false,
    this.bufferSizeSupported = false,
    this.minBufferFrames,
    this.maxBufferFrames,
    this.defaultBufferFrames,
    this.bufferGranularity,
    this.probeNote,
  });

  String get interfaceLabel => switch (backend) {
    'windows_wasapi_exclusive' => 'WASAPI Exclusive',
    'windows_wasapi_shared' => 'WASAPI Shared',
    'windows_asio' => 'ASIO',
    'macos_core_audio_hog' => 'CoreAudio Exclusive',
    'mobile_direct' => 'Direct USB DAC',
    'network_dlna' => 'DLNA',
    'network_airplay' => 'AirPlay',
    _ => backend,
  };

  int get backendIndex => switch (backend) {
    'windows_asio' => 0,
    'windows_wasapi_exclusive' => 1,
    'windows_wasapi_shared' => 2,
    'macos_core_audio_hog' => 3,
    'mobile_direct' => 4,
    'network_dlna' => 5,
    'network_airplay' => 6,
    _ => -1,
  };

  bool get isSharedMode => backend == 'windows_wasapi_shared';

  bool get isExclusiveOrAsio =>
      backend == 'windows_wasapi_exclusive' ||
      backend == 'windows_asio' ||
      backend == 'macos_core_audio_hog' ||
      backend == 'mobile_direct';

  String get physicalEndpointId {
    if (deviceId.startsWith('wasapi-shared::')) {
      return deviceId.substring('wasapi-shared::'.length);
    }
    if (deviceId.startsWith('wasapi-excl::')) {
      return deviceId.substring('wasapi-excl::'.length);
    }
    return deviceId;
  }

  factory AudioDeviceCapabilitiesModel.fromJson(Map<String, dynamic> json) {
    final exclAvail = json['exclusive_available'] == true;
    final isDef = json['is_default'] == true;
    return AudioDeviceCapabilitiesModel(
      deviceId: json['device_id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      backend: json['backend']?.toString() ?? '',
      transport: json['transport']?.toString() ?? 'internal',
      isDefault: isDef,
      isOsDefault: json['is_os_default'] == true || isDef,
      isExclusive: json['is_exclusive'] == true,
      isHdmi: json['is_hdmi'] == true,
      hardwareSupportsExclusive:
          json['hardware_supports_exclusive'] == true || exclAvail,
      supportedSampleRates: (json['supported_sample_rates'] as List<dynamic>?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          const [],
      supportedBitDepths: (json['supported_bit_depths'] as List<dynamic>?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          const [],
      supportedContainerBits: (json['supported_container_bits'] as List<dynamic>?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          const [],
      supportedChannels: (json['supported_channels'] as List<dynamic>?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          const [],
      supportedOutputModes: (json['supported_output_modes'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      supportsNativeDsd: json['supports_native_dsd'] == true,
      supportsDop: json['supports_dop'] == true,
      supportsFloat32: json['supports_float32'] == true,
      maxDsdRate: json['max_dsd_rate']?.toString(),
      asioAvailable: json['asio_available'] == true,
      asioDriverName: json['asio_driver_name']?.toString(),
      exclusiveAvailable: exclAvail,
      bufferSizeSupported: json['buffer_size_supported'] == true,
      minBufferFrames: (json['min_buffer_frames'] as num?)?.toInt(),
      maxBufferFrames: (json['max_buffer_frames'] as num?)?.toInt(),
      defaultBufferFrames: (json['default_buffer_frames'] as num?)?.toInt(),
      bufferGranularity: (json['buffer_granularity'] as num?)?.toInt(),
      probeNote: json['probe_note']?.toString(),
    );
  }
}

class AudioSourceInfoModel {
  final String codec;
  final int sampleRateHz;
  final int bitDepth;
  final int channels;
  final String channelLayout;
  final String sourceFormat;
  final String? title;
  final String? artist;
  final String? album;

  const AudioSourceInfoModel({
    this.codec = '',
    this.sampleRateHz = 0,
    this.bitDepth = 0,
    this.channels = 0,
    this.channelLayout = '',
    this.sourceFormat = '',
    this.title,
    this.artist,
    this.album,
  });

  factory AudioSourceInfoModel.fromJson(Map<String, dynamic> json) {
    return AudioSourceInfoModel(
      codec: json['codec']?.toString() ?? '',
      sampleRateHz: (json['sample_rate_hz'] as num?)?.toInt() ?? 0,
      bitDepth: (json['bit_depth'] as num?)?.toInt() ?? 0,
      channels: (json['channels'] as num?)?.toInt() ?? 0,
      channelLayout: json['channel_layout']?.toString() ?? '',
      sourceFormat: json['source_format']?.toString() ?? '',
      title: json['title']?.toString(),
      artist: json['artist']?.toString(),
      album: json['album']?.toString(),
    );
  }
}

class AudioDecoderInfoModel {
  final String decoderType;
  final String decodedPcmFormat;
  final int sampleRateHz;
  final int containerBits;
  final int validBits;
  final bool integerPreserved;

  const AudioDecoderInfoModel({
    this.decoderType = '',
    this.decodedPcmFormat = '',
    this.sampleRateHz = 0,
    this.containerBits = 0,
    this.validBits = 0,
    this.integerPreserved = false,
  });

  factory AudioDecoderInfoModel.fromJson(Map<String, dynamic> json) {
    return AudioDecoderInfoModel(
      decoderType: json['decoder_type']?.toString() ?? '',
      decodedPcmFormat: json['decoded_pcm_format']?.toString() ?? '',
      sampleRateHz: (json['sample_rate_hz'] as num?)?.toInt() ?? 0,
      containerBits: (json['container_bits'] as num?)?.toInt() ?? 0,
      validBits: (json['valid_bits'] as num?)?.toInt() ?? 0,
      integerPreserved: json['integer_preserved'] == true,
    );
  }
}

class AudioOutputInfoModel {
  final String selectedDevice;
  final String transportKind;
  final String audioApi;
  final String outputMode;
  final int sampleRateHz;
  final int containerBits;
  final int validBits;
  final int channels;
  final int bufferSizeFrames;
  final String dspStatus;
  final String softwareVolumeStatus;
  final bool strictMode;
  final bool hardwareVolumeRecommended;
  final String? degradationReason;

  const AudioOutputInfoModel({
    this.selectedDevice = '',
    this.transportKind = '',
    this.audioApi = '',
    this.outputMode = '',
    this.sampleRateHz = 0,
    this.containerBits = 0,
    this.validBits = 0,
    this.channels = 0,
    this.bufferSizeFrames = 0,
    this.dspStatus = '',
    this.softwareVolumeStatus = '',
    this.strictMode = false,
    this.hardwareVolumeRecommended = false,
    this.degradationReason,
  });

  factory AudioOutputInfoModel.fromJson(Map<String, dynamic> json) {
    return AudioOutputInfoModel(
      selectedDevice: json['selected_device']?.toString() ?? '',
      transportKind: json['transport_kind']?.toString() ?? '',
      audioApi: json['audio_api']?.toString() ?? '',
      outputMode: json['output_mode']?.toString() ?? '',
      sampleRateHz: (json['sample_rate_hz'] as num?)?.toInt() ?? 0,
      containerBits: (json['container_bits'] as num?)?.toInt() ?? 0,
      validBits: (json['valid_bits'] as num?)?.toInt() ?? 0,
      channels: (json['channels'] as num?)?.toInt() ?? 0,
      bufferSizeFrames: (json['buffer_size_frames'] as num?)?.toInt() ?? 0,
      dspStatus: json['dsp_status']?.toString() ?? '',
      softwareVolumeStatus: json['software_volume_status']?.toString() ?? '',
      strictMode: json['strict_mode'] == true,
      hardwareVolumeRecommended: json['hardware_volume_recommended'] == true,
      degradationReason: json['degradation_reason']?.toString(),
    );
  }
}

class AudioVerificationInfoModel {
  final String pcmSampleCheck;
  final bool sampleHashMatch;
  final String decoderSha256;
  final String processingSha256;
  final String backendInputSha256;
  final bool formatMatch;
  final String outputPath;
  final String verificationLevel;
  final String status;
  final int framesVerified;
  final int mismatchedFrames;

  const AudioVerificationInfoModel({
    this.pcmSampleCheck = 'Not Verified',
    this.sampleHashMatch = false,
    this.decoderSha256 = '',
    this.processingSha256 = '',
    this.backendInputSha256 = '',
    this.formatMatch = false,
    this.outputPath = 'Idle',
    this.verificationLevel =
        'Software Verification Only (Decoder -> Output Backend Input)',
    this.status = 'NOT VERIFIED',
    this.framesVerified = 0,
    this.mismatchedFrames = 0,
  });

  factory AudioVerificationInfoModel.fromJson(Map<String, dynamic> json) {
    return AudioVerificationInfoModel(
      pcmSampleCheck: json['pcm_sample_check']?.toString() ?? 'Not Verified',
      sampleHashMatch: json['sample_hash_match'] == true,
      decoderSha256: json['decoder_sha256']?.toString() ?? '',
      processingSha256: json['processing_sha256']?.toString() ?? '',
      backendInputSha256: json['backend_input_sha256']?.toString() ?? '',
      formatMatch: json['format_match'] == true,
      outputPath: json['output_path']?.toString() ?? '',
      verificationLevel: json['verification_level']?.toString() ??
          'Software Verification Only (Decoder -> Output Backend Input)',
      status: json['status']?.toString() ?? 'NOT VERIFIED',
      framesVerified: (json['frames_verified'] as num?)?.toInt() ?? 0,
      mismatchedFrames: (json['mismatched_frames'] as num?)?.toInt() ?? 0,
    );
  }
}

class AudioEngineOutputInfoModel {
  final AudioSourceInfoModel source;
  final AudioDecoderInfoModel decoder;
  final AudioOutputInfoModel output;
  final AudioVerificationInfoModel verification;

  const AudioEngineOutputInfoModel({
    this.source = const AudioSourceInfoModel(),
    this.decoder = const AudioDecoderInfoModel(),
    this.output = const AudioOutputInfoModel(),
    this.verification = const AudioVerificationInfoModel(),
  });

  factory AudioEngineOutputInfoModel.fromJson(Map<String, dynamic> json) {
    return AudioEngineOutputInfoModel(
      source: json['source'] is Map<String, dynamic>
          ? AudioSourceInfoModel.fromJson(
              json['source'] as Map<String, dynamic>,
            )
          : const AudioSourceInfoModel(),
      decoder: json['decoder'] is Map<String, dynamic>
          ? AudioDecoderInfoModel.fromJson(
              json['decoder'] as Map<String, dynamic>,
            )
          : const AudioDecoderInfoModel(),
      output: json['output'] is Map<String, dynamic>
          ? AudioOutputInfoModel.fromJson(
              json['output'] as Map<String, dynamic>,
            )
          : const AudioOutputInfoModel(),
      verification: json['verification'] is Map<String, dynamic>
          ? AudioVerificationInfoModel.fromJson(
              json['verification'] as Map<String, dynamic>,
            )
          : const AudioVerificationInfoModel(),
    );
  }
}
