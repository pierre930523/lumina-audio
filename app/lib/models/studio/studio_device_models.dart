import '../protocol/protocol_models.dart';

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

  factory AudioDeviceInfo.fromProtocol(ProtocolAudioDeviceInfo protocol) =>
      protocol.toLegacy();

  ProtocolAudioDeviceInfo toProtocol({bool isActive = false}) =>
      ProtocolAudioDeviceInfo.fromLegacy(this, isActive: isActive);
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

  factory AudioZoneInfo.fromProtocol(ProtocolZoneInfo protocol) =>
      protocol.toLegacy();

  ProtocolZoneInfo toProtocol() => ProtocolZoneInfo.fromLegacy(this);
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
