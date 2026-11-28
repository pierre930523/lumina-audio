part of '../mock_audio_service.dart';

List<UserProfileInfo> _createDefaultMockProfiles() => [
      const UserProfileInfo(
        id: 'prof-default',
        name: 'Pierre (Default)',
        avatarColor: '#007AFF',
        isDefault: true,
      ),
      const UserProfileInfo(
        id: 'prof-studio',
        name: 'Studio Reference',
        avatarColor: '#A259FF',
        isDefault: false,
      ),
    ];

DspPipelineConfigModel _createDefaultMockDspConfig() => DspPipelineConfigModel(
      bypass: false,
      peqBands: DspPipelineConfigModel.defaultTenBandIso(),
      crossfeedEnabled: true,
      crossfeedCutoffHz: 700.0,
      crossfeedFeedLevelDb: -6.0,
      replayGainMode: ReplayGainModeOption.album,
      replayGainPreampDb: 0.0,
    );

List<AudioDeviceInfo> _createDefaultMockDevices() => [
      const AudioDeviceInfo(
        id: 'asio-fiio-k9',
        name: 'FiiO K9 Pro USB ASIO',
        backend: 'windows_asio',
        isDefault: true,
        isExclusive: true,
        supportedSampleRates: [44100, 48000, 96000, 192000, 384000],
      ),
      const AudioDeviceInfo(
        id: 'usb-dac-mobile',
        name: 'Direct USB DAC (Bit-Perfect)',
        backend: 'mobile_direct',
        isDefault: false,
        isExclusive: true,
        supportedSampleRates: [44100, 96000, 192000],
      ),
    ];

List<AudioZoneInfo> _createDefaultMockZones() => [
      const AudioZoneInfo(
        id: 'zone-local',
        name: 'Desktop DAC (FiiO K9 Pro)',
        backend: 'windows_asio',
        isActive: true,
        volume: 0.8,
        clockOffsetUs: 0,
        rttUs: 0,
        driftPpm: 0.0,
      ),
      const AudioZoneInfo(
        id: 'dlna-living-room',
        name: 'Living Room DLNA Renderer',
        backend: 'network_dlna',
        isActive: false,
        volume: 0.55,
        clockOffsetUs: 1200,
        rttUs: 840,
        driftPpm: 1.5,
      ),
    ];

List<ProviderStatusInfo> _createDefaultMockProviders() => [
      const ProviderStatusInfo(
        kind: 'local',
        isConfigured: true,
        isOnline: true,
      ),
      const ProviderStatusInfo(
        kind: 'apple_music',
        isConfigured: false,
        isOnline: false,
      ),
      const ProviderStatusInfo(
        kind: 'youtube_music',
        isConfigured: false,
        isOnline: false,
      ),
      const ProviderStatusInfo(
        kind: 'qobuz',
        isConfigured: false,
        isOnline: false,
      ),
      const ProviderStatusInfo(
        kind: 'tidal',
        isConfigured: false,
        isOnline: false,
      ),
      const ProviderStatusInfo(
        kind: 'deezer',
        isConfigured: false,
        isOnline: false,
      ),
      const ProviderStatusInfo(
        kind: 'web_dav',
        isConfigured: false,
        isOnline: false,
      ),
      const ProviderStatusInfo(
        kind: 'smb',
        isConfigured: false,
        isOnline: false,
      ),
    ];

List<TrackInfo> _createDefaultMockQueue() => [
      const TrackInfo(
        id: 'trk-001',
        title: 'Time',
        artist: 'Pink Floyd',
        album: 'The Dark Side of the Moon (50th Anniversary Remaster)',
        duration: Duration(minutes: 4, seconds: 5),
        format: AudioFormat(
          codec: AudioCodec.flac,
          sampleRateHz: 96000,
          bitDepth: 24,
          channels: 2,
          bitrateKbps: 2840,
        ),
        providerName: 'Qobuz Hi-Res',
      ),
      const TrackInfo(
        id: 'trk-002',
        title: 'Money',
        artist: 'Pink Floyd',
        album: 'The Dark Side of the Moon (50th Anniversary Remaster)',
        duration: Duration(minutes: 3, seconds: 52),
        format: AudioFormat(
          codec: AudioCodec.dsf,
          sampleRateHz: 2822400,
          bitDepth: 1,
          channels: 2,
          isDsd: true,
        ),
        providerName: 'Local NAS (DSD64)',
      ),
      const TrackInfo(
        id: 'trk-003',
        title: 'Comfortably Numb',
        artist: 'Pink Floyd',
        album: 'The Wall',
        duration: Duration(minutes: 6, seconds: 22),
        format: AudioFormat(
          codec: AudioCodec.flac,
          sampleRateHz: 192000,
          bitDepth: 24,
          channels: 2,
        ),
        providerName: 'Tidal Max',
      ),
    ];

List<LyricLine> _createDefaultMockLyrics() => const [
      LyricLine(
        start: Duration(seconds: 0),
        end: Duration(seconds: 6),
        text: 'Ticking away the moments that make up a dull day',
        words: [
          LyricWord(
            text: 'Ticking ',
            start: Duration(seconds: 0),
            end: Duration(seconds: 1),
          ),
          LyricWord(
            text: 'away ',
            start: Duration(seconds: 1),
            end: Duration(seconds: 2),
          ),
          LyricWord(
            text: 'the ',
            start: Duration(seconds: 2),
            end: Duration(seconds: 3),
          ),
          LyricWord(
            text: 'moments ',
            start: Duration(seconds: 3),
            end: Duration(seconds: 4),
          ),
          LyricWord(
            text: 'that make up a dull day',
            start: Duration(seconds: 4),
            end: Duration(seconds: 6),
          ),
        ],
      ),
      LyricLine(
        start: Duration(seconds: 6),
        end: Duration(seconds: 12),
        text: 'Fritter and waste the hours in an offhand way',
        words: [
          LyricWord(
            text: 'Fritter ',
            start: Duration(seconds: 6),
            end: Duration(seconds: 8),
          ),
          LyricWord(
            text: 'and waste ',
            start: Duration(seconds: 8),
            end: Duration(seconds: 10),
          ),
          LyricWord(
            text: 'the hours in an offhand way',
            start: Duration(seconds: 10),
            end: Duration(seconds: 12),
          ),
        ],
      ),
      LyricLine(
        start: Duration(seconds: 12),
        end: Duration(seconds: 18),
        text: 'Kicking around on a piece of ground in your home town',
        words: [
          LyricWord(
            text: 'Kicking ',
            start: Duration(seconds: 12),
            end: Duration(seconds: 14),
          ),
          LyricWord(
            text: 'around on a piece of ground ',
            start: Duration(seconds: 14),
            end: Duration(seconds: 16),
          ),
          LyricWord(
            text: 'in your home town',
            start: Duration(seconds: 16),
            end: Duration(seconds: 18),
          ),
        ],
      ),
      LyricLine(
        start: Duration(seconds: 18),
        end: Duration(seconds: 24),
        text: 'Waiting for someone or something to show you the way',
        words: [
          LyricWord(
            text: 'Waiting ',
            start: Duration(seconds: 18),
            end: Duration(seconds: 20),
          ),
          LyricWord(
            text: 'for someone or something ',
            start: Duration(seconds: 20),
            end: Duration(seconds: 22),
          ),
          LyricWord(
            text: 'to show you the way',
            start: Duration(seconds: 22),
            end: Duration(seconds: 24),
          ),
        ],
      ),
    ];

SignalPath _buildMockSignalPath({
  required TrackInfo track,
  required SignalQuality? forcedQuality,
  required bool dspBypassed,
}) {
  if (forcedQuality == SignalQuality.highQuality) {
    return SignalPath(
      overallQuality: SignalQuality.highQuality,
      description: SignalQuality.highQuality.description,
      dspBypassed: dspBypassed,
      nodes: [
        SignalPathNode(
          title: '音訊來源',
          subtitle: track.providerName,
          detail: track.format.label,
          quality: SignalQuality.lossless,
        ),
        const SignalPathNode(
          title: '系統混音器',
          subtitle: 'WASAPI 共用模式',
          detail: '經系統音訊混音器重新取樣為 48.0 kHz',
          quality: SignalQuality.highQuality,
        ),
        const SignalPathNode(
          title: '音訊輸出',
          subtitle: '系統預設輸出裝置',
          detail: '共用模式 48.0 kHz / 32-bit 浮點',
          quality: SignalQuality.highQuality,
        ),
      ],
    );
  }

  if (dspBypassed || forcedQuality == SignalQuality.lossless) {
    return SignalPath(
      overallQuality: SignalQuality.lossless,
      description: SignalQuality.lossless.description,
      dspBypassed: true,
      nodes: [
        SignalPathNode(
          title: '音訊來源',
          subtitle: track.providerName,
          detail: track.format.label,
          quality: SignalQuality.lossless,
        ),
        const SignalPathNode(
          title: 'DSP 處理管線',
          subtitle: '已啟用位元精準旁通',
          detail: '零損耗直接路由至硬體裝置',
          quality: SignalQuality.lossless,
        ),
        const SignalPathNode(
          title: '音訊輸出',
          subtitle: 'Windows ASIO 獨佔模式',
          detail: 'FiiO K9 Pro USB ASIO (96.0 kHz / 24-bit)',
          quality: SignalQuality.lossless,
        ),
      ],
    );
  }

  return SignalPath(
    overallQuality: SignalQuality.enhanced,
    description: SignalQuality.enhanced.description,
    dspBypassed: false,
    nodes: [
      SignalPathNode(
        title: '音訊來源',
        subtitle: track.providerName,
        detail: track.format.label,
        quality: SignalQuality.lossless,
      ),
      const SignalPathNode(
        title: '64 位元浮點 DSP',
        subtitle: '參數等化器 + Bauer 聲學交叉饋送',
        detail: 'AutoEQ Sennheiser HD650（10 段參數等化，64 位元浮點運算）',
        quality: SignalQuality.enhanced,
      ),
      const SignalPathNode(
        title: '音訊輸出',
        subtitle: 'Windows ASIO 獨佔模式',
        detail: 'FiiO K9 Pro USB ASIO (96.0 kHz / 24-bit)',
        quality: SignalQuality.lossless,
      ),
    ],
  );
}
