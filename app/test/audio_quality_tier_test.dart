import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/audio_quality_tier.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/services/mock_audio_service.dart';

TrackInfo _makeTrack({
  required AudioFormat format,
  String providerName = 'Local Library',
  String? filePath,
}) {
  return TrackInfo(
    id: 'test-track',
    title: 'Test Track',
    artist: 'Test Artist',
    album: 'Test Album',
    duration: const Duration(minutes: 3, seconds: 30),
    format: format,
    providerName: providerName,
    filePath: filePath,
  );
}

void main() {
  group('AudioQualityTier metadata getters', () {
    test('exposes exact code, badgeLabel, displayName, and isLossless', () {
      expect(AudioQualityTier.hiRes.code, 'HI_RES');
      expect(AudioQualityTier.hiRes.badgeLabel, 'Hi-Res');
      expect(AudioQualityTier.hiRes.displayName, 'Hi-Res 高解析無損');
      expect(AudioQualityTier.hiRes.isLossless, isTrue);

      expect(AudioQualityTier.lossless.code, 'LOSSLESS');
      expect(AudioQualityTier.lossless.badgeLabel, 'LOSSLESS');
      expect(AudioQualityTier.lossless.displayName, 'CD 無損音質');
      expect(AudioQualityTier.lossless.isLossless, isTrue);

      expect(AudioQualityTier.hqLossy.code, 'HQ_LOSSY');
      expect(AudioQualityTier.hqLossy.badgeLabel, 'HQ');
      expect(AudioQualityTier.hqLossy.displayName, '高音質有損 (HQ)');
      expect(AudioQualityTier.hqLossy.isLossless, isFalse);

      expect(AudioQualityTier.standard.code, 'STANDARD');
      expect(AudioQualityTier.standard.badgeLabel, 'SD');
      expect(AudioQualityTier.standard.displayName, '標準／省流量 (SD)');
      expect(AudioQualityTier.standard.isLossless, isFalse);
    });
  });

  group('classifyAudioQuality priority rules', () {
    test('classifies core benchmark formats accurately', () {
      // MP3 128k -> STANDARD
      expect(
        classifyAudioQuality(format: 'MP3', bitrateKbps: 128, sampleRate: 44100),
        AudioQualityTier.standard,
      );

      // Opus 160k at 48 kHz -> STANDARD (explicit bitrate < 256 overrides 48 kHz fallback)
      expect(
        classifyAudioQuality(
          format: 'Opus',
          bitrateKbps: 160,
          sampleRate: 48000,
          providerName: 'YouTube Music',
          isHighQualityStream: true,
        ),
        AudioQualityTier.standard,
      );

      // AAC 320k -> HQ_LOSSY
      expect(
        classifyAudioQuality(format: 'AAC', bitrateKbps: 320, sampleRate: 44100),
        AudioQualityTier.hqLossy,
      );

      // CD 16-bit / 44.1 kHz FLAC -> LOSSLESS
      expect(
        classifyAudioQuality(format: 'FLAC', bitDepth: 16, sampleRate: 44100),
        AudioQualityTier.lossless,
      );

      // Hi-Res 24-bit / 96 kHz FLAC -> HI_RES
      expect(
        classifyAudioQuality(format: 'FLAC', bitDepth: 24, sampleRate: 96000),
        AudioQualityTier.hiRes,
      );

      // DSD64 -> HI_RES
      expect(
        classifyAudioQuality(
          format: 'DSF',
          sampleRate: 2822400,
          bitDepth: 1,
          isDsd: true,
        ),
        AudioQualityTier.hiRes,
      );
    });

    test('handles Hi-Res boundary conditions for DSD and lossless formats', () {
      // DSD variants by name or flag
      expect(classifyAudioQuality(format: 'DSD64'), AudioQualityTier.hiRes);
      expect(classifyAudioQuality(format: 'DFF'), AudioQualityTier.hiRes);
      expect(classifyAudioQuality(format: 'DSDIFF'), AudioQualityTier.hiRes);
      expect(classifyAudioQuality(isDsd: true), AudioQualityTier.hiRes);

      // FLAC 16-bit / 48 kHz -> HI_RES (sampleRate > 44.1 kHz)
      expect(
        classifyAudioQuality(format: 'FLAC', bitDepth: 16, sampleRate: 48000),
        AudioQualityTier.hiRes,
      );

      // ALAC 24-bit / 44.1 kHz -> HI_RES (bitDepth >= 24)
      expect(
        classifyAudioQuality(format: 'ALAC', bitDepth: 24, sampleRate: 44100),
        AudioQualityTier.hiRes,
      );

      // WAV / AIFF / PCM lossless boundaries
      expect(
        classifyAudioQuality(format: 'WAV', bitDepth: 16, sampleRate: 44100),
        AudioQualityTier.lossless,
      );
      expect(
        classifyAudioQuality(format: 'WAVE', bitDepth: 24, sampleRate: 48000),
        AudioQualityTier.hiRes,
      );
      expect(
        classifyAudioQuality(format: 'AIFF', bitDepth: 16, sampleRate: 44100),
        AudioQualityTier.lossless,
      );
      expect(
        classifyAudioQuality(format: 'AIF', bitDepth: 16, sampleRate: 88.2),
        AudioQualityTier.hiRes,
      );
      expect(
        classifyAudioQuality(format: 'PCM', bitDepth: 16, sampleRate: 44.1),
        AudioQualityTier.lossless,
      );

      // Explicit lossless codec inside M4A container
      expect(
        classifyAudioQuality(
          format: 'm4a',
          codec: 'alac',
          bitDepth: 16,
          sampleRate: 44100,
        ),
        AudioQualityTier.lossless,
      );
      expect(
        classifyAudioQuality(
          format: 'm4a',
          codec: 'alac',
          bitDepth: 24,
          sampleRate: 96000,
        ),
        AudioQualityTier.hiRes,
      );
    });

    test('handles lossy bitrate thresholds and missing-bitrate fallbacks', () {
      // Exact threshold at 256 kbps
      expect(
        classifyAudioQuality(format: 'AAC', bitrateKbps: 256, sampleRate: 44100),
        AudioQualityTier.hqLossy,
      );
      expect(
        classifyAudioQuality(format: 'AAC', bitrateKbps: 255, sampleRate: 44100),
        AudioQualityTier.standard,
      );

      // Ogg / Vorbis string handling
      expect(
        classifyAudioQuality(format: 'OGG', bitrateKbps: 320),
        AudioQualityTier.hqLossy,
      );
      expect(
        classifyAudioQuality(format: 'vorbis', bitrateKbps: 160),
        AudioQualityTier.standard,
      );

      // YouTube Music Opus 48 kHz without explicit bitrate -> HQ_LOSSY
      expect(
        classifyAudioQuality(
          format: 'opus',
          sampleRate: 48000,
          providerName: 'YouTube Music',
        ),
        AudioQualityTier.hqLossy,
      );

      // Streaming AAC 48 kHz without explicit bitrate -> HQ_LOSSY
      expect(
        classifyAudioQuality(
          format: 'aac',
          sampleRate: 48000,
          providerName: 'YouTube Music',
        ),
        AudioQualityTier.hqLossy,
      );

      // Local AAC 48 kHz without bitrate and without high-quality stream flag -> STANDARD
      expect(
        classifyAudioQuality(
          format: 'aac',
          sampleRate: 48000,
          providerName: 'Local Library',
        ),
        AudioQualityTier.standard,
      );

      // High-quality stream flag fallback when bitrate is absent or 0
      expect(
        classifyAudioQuality(
          format: 'mp3',
          bitrateKbps: 0,
          isHighQualityStream: true,
        ),
        AudioQualityTier.hqLossy,
      );
    });

    test('normalizes Hz and kHz sampleRate inputs identically', () {
      expect(
        classifyAudioQuality(format: 'FLAC', bitDepth: 16, sampleRate: 44.1),
        AudioQualityTier.lossless,
      );
      expect(
        classifyAudioQuality(format: 'FLAC', bitDepth: 16, sampleRate: 44100),
        AudioQualityTier.lossless,
      );
      expect(
        classifyAudioQuality(format: 'FLAC', bitDepth: 16, sampleRate: 48),
        AudioQualityTier.hiRes,
      );
      expect(
        classifyAudioQuality(format: 'FLAC', bitDepth: 16, sampleRate: 48000),
        AudioQualityTier.hiRes,
      );
      expect(
        classifyAudioQuality(format: 'FLAC', bitDepth: 24, sampleRate: 96),
        AudioQualityTier.hiRes,
      );
      expect(
        classifyAudioQuality(format: 'FLAC', bitDepth: 24, sampleRate: 192),
        AudioQualityTier.hiRes,
      );
      expect(
        classifyAudioQuality(format: 'opus', sampleRate: 48),
        AudioQualityTier.hqLossy,
      );
    });

    test('falls back to STANDARD on incomplete, null, or unknown metadata', () {
      expect(getAudioQualityTier(null), AudioQualityTier.standard);
      expect(getAudioQualityTier(<String, Object?>{}), AudioQualityTier.standard);
      expect(getAudioQualityTier('unsupported'), AudioQualityTier.standard);
      expect(classifyAudioQuality(), AudioQualityTier.standard);
      expect(
        classifyAudioQuality(format: 'unknown_codec', bitDepth: 24, sampleRate: 96000),
        AudioQualityTier.standard,
      );
      // Lossless with missing/0 bitDepth AND missing/0 sampleRate -> incomplete -> STANDARD
      expect(
        classifyAudioQuality(format: 'FLAC', bitDepth: 0, sampleRate: 0),
        AudioQualityTier.standard,
      );
      expect(
        classifyAudioQuality(format: 'FLAC'),
        AudioQualityTier.standard,
      );
      // Lossy without bitrate and without high-quality signal -> STANDARD
      expect(
        classifyAudioQuality(format: 'MP3', sampleRate: 44100),
        AudioQualityTier.standard,
      );
      // NaN / negative numbers are safely ignored
      expect(
        classifyAudioQuality(
          format: 'FLAC',
          bitDepth: -1,
          sampleRate: double.nan,
        ),
        AudioQualityTier.standard,
      );
    });
  });

  group('getAudioQualityTier polymorphic inputs', () {
    test('accepts TrackInfo, AudioQualityMetadata, AudioFormat, and Map', () {
      final hiResFormat = const AudioFormat(
        codec: AudioCodec.flac,
        sampleRateHz: 96000,
        bitDepth: 24,
        channels: 2,
        bitrateKbps: 2840,
      );
      final hiResTrack = _makeTrack(format: hiResFormat);

      expect(getAudioQualityTier(hiResTrack), AudioQualityTier.hiRes);
      expect(getAudioQualityTier(hiResFormat), AudioQualityTier.hiRes);
      expect(
        getAudioQualityTier(AudioQualityMetadata.fromTrackInfo(hiResTrack)),
        AudioQualityTier.hiRes,
      );

      // AudioQualityMetadata.fromTrackInfo allows overriding bitrate
      final ytmOpusTrack = _makeTrack(
        format: const AudioFormat(
          codec: AudioCodec.opus,
          sampleRateHz: 48000,
          bitDepth: 16,
          channels: 2,
        ),
        providerName: 'YouTube Music',
      );
      expect(getAudioQualityTier(ytmOpusTrack), AudioQualityTier.hqLossy);
      expect(
        getAudioQualityTier(
          AudioQualityMetadata.fromTrackInfo(ytmOpusTrack, bitrateKbps: 160),
        ),
        AudioQualityTier.standard,
      );

      // Map inputs with camelCase and snake_case keys
      expect(
        getAudioQualityTier(<String, Object?>{
          'format': 'flac',
          'bitDepth': 16,
          'sampleRate': 44.1,
        }),
        AudioQualityTier.lossless,
      );
      expect(
        getAudioQualityTier(<String, Object?>{
          'codec': 'aac',
          'bitrate': 320,
          'sampleRateHz': 44100,
        }),
        AudioQualityTier.hqLossy,
      );
      expect(
        getAudioQualityTier(<String, Object?>{
          'codec': 'opus',
          'bitrateKbps': 160,
          'sampleRateHz': 48000,
          'providerName': 'YouTube Music',
        }),
        AudioQualityTier.standard,
      );
      expect(
        getAudioQualityTier(<String, Object?>{
          'format': 'mp3',
          'isHighQualityStream': true,
        }),
        AudioQualityTier.hqLossy,
      );
      expect(
        getAudioQualityTier(<String, Object?>{'isDsd': true}),
        AudioQualityTier.hiRes,
      );
    });
  });

  group('Formatting helpers', () {
    test('formatAudioCodecName formats PCM, lossy, and DSD codecs cleanly', () {
      expect(
        formatAudioCodecName(
          const AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: 96000,
            bitDepth: 24,
            channels: 2,
          ),
        ),
        'FLAC',
      );
      expect(
        formatAudioCodecName(
          const AudioFormat(
            codec: AudioCodec.opus,
            sampleRateHz: 48000,
            bitDepth: 16,
            channels: 2,
          ),
        ),
        'Opus',
      );
      expect(
        formatAudioCodecName(
          const AudioFormat(
            codec: AudioCodec.aac,
            sampleRateHz: 44100,
            bitDepth: 16,
            channels: 2,
          ),
        ),
        'AAC',
      );
      expect(
        formatAudioCodecName(
          const AudioFormat(
            codec: AudioCodec.dsf,
            sampleRateHz: 2822400,
            bitDepth: 1,
            channels: 2,
            isDsd: true,
          ),
        ),
        'DSD64',
      );
      expect(
        formatAudioCodecName(
          const AudioFormat(
            codec: AudioCodec.dsdiff,
            sampleRateHz: 5644800,
            bitDepth: 1,
            channels: 2,
            isDsd: true,
          ),
        ),
        'DSD128',
      );
    });

    test('formatAudioSampleSpec formats PCM and DSD specifications cleanly', () {
      expect(
        formatAudioSampleSpec(
          const AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: 96000,
            bitDepth: 24,
            channels: 2,
          ),
        ),
        '24-bit / 96 kHz',
      );
      expect(
        formatAudioSampleSpec(
          const AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: 44100,
            bitDepth: 16,
            channels: 2,
          ),
        ),
        '16-bit / 44.1 kHz',
      );
      expect(
        formatAudioSampleSpec(
          const AudioFormat(
            codec: AudioCodec.dsf,
            sampleRateHz: 2822400,
            bitDepth: 1,
            channels: 2,
            isDsd: true,
          ),
        ),
        '1-bit / 2.8 MHz (DSD64)',
      );
      expect(
        formatAudioSampleSpec(
          const AudioFormat(
            codec: AudioCodec.mp3,
            sampleRateHz: 44100,
            bitDepth: 0,
            channels: 2,
          ),
        ),
        '44.1 kHz',
      );
      expect(
        formatAudioSampleSpec(
          const AudioFormat(
            codec: AudioCodec.mp3,
            sampleRateHz: 0,
            bitDepth: 0,
            channels: 2,
          ),
        ),
        '未知',
      );
    });

    test('formatAudioBitrateLabel formats explicit, exact, estimated, and unknown bitrates', () {
      final explicitTrack = _makeTrack(
        format: const AudioFormat(
          codec: AudioCodec.flac,
          sampleRateHz: 96000,
          bitDepth: 24,
          channels: 2,
          bitrateKbps: 2840,
        ),
      );
      expect(formatAudioBitrateLabel(explicitTrack), '2,840 kbps');
      expect(
        formatAudioBitrateLabel(explicitTrack, overrideBitrateKbps: 320),
        '320 kbps',
      );

      final wavTrack = _makeTrack(
        format: const AudioFormat(
          codec: AudioCodec.wav,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
        ),
        filePath: 'C:/Music/cd.wav',
      );
      expect(formatAudioBitrateLabel(wavTrack), '1,411 kbps');

      final dsdTrack = _makeTrack(
        format: const AudioFormat(
          codec: AudioCodec.dsf,
          sampleRateHz: 2822400,
          bitDepth: 1,
          channels: 2,
          isDsd: true,
        ),
      );
      expect(formatAudioBitrateLabel(dsdTrack), '5,645 kbps');

      final vbrFlacTrack = _makeTrack(
        format: const AudioFormat(
          codec: AudioCodec.flac,
          sampleRateHz: 96000,
          bitDepth: 24,
          channels: 2,
        ),
      );
      expect(formatAudioBitrateLabel(vbrFlacTrack), startsWith('約 '));
      expect(formatAudioBitrateLabel(vbrFlacTrack), endsWith(' kbps'));

      final ytmOpusTrack = _makeTrack(
        format: const AudioFormat(
          codec: AudioCodec.opus,
          sampleRateHz: 48000,
          bitDepth: 16,
          channels: 2,
        ),
        providerName: 'YouTube Music',
      );
      expect(formatAudioBitrateLabel(ytmOpusTrack), '約 256 kbps');

      final unknownLocalMp3 = _makeTrack(
        format: const AudioFormat(
          codec: AudioCodec.mp3,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
        ),
        filePath: 'C:/Music/sample.mp3',
      );
      expect(formatAudioBitrateLabel(unknownLocalMp3), '未知');
    });
  });

  group('Bitrate plumbing & defaults', () {
    test('StreamingRecommendations JSON round-trips bitrateKbps', () {
      final track = _makeTrack(
        format: const AudioFormat(
          codec: AudioCodec.aac,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
          bitrateKbps: 320,
        ),
        providerName: 'Tidal',
      );
      final encoded = StreamingRecommendations.trackToJson(track);
      final decoded = StreamingRecommendations.trackFromJson(encoded);

      expect(decoded.format.bitrateKbps, 320);
      expect(getAudioQualityTier(decoded), AudioQualityTier.hqLossy);
    });

    test('MockAudioService default track stays Hi-Res with formatted bitrate', () {
      final service = MockAudioService();
      addTearDown(service.dispose);

      final track = service.currentState.track;
      expect(track, isNotNull);
      expect(getAudioQualityTier(track), AudioQualityTier.hiRes);
      expect(formatAudioBitrateLabel(track!), '2,840 kbps');
    });
  });
}
