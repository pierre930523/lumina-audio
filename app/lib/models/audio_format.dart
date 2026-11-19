enum AudioCodec {
  flac,
  alac,
  wav,
  aiff,
  aac,
  mp3,
  opus,
  dsf,
  dsdiff;

  String get displayName => switch (this) {
    AudioCodec.flac => 'FLAC',
    AudioCodec.alac => 'ALAC',
    AudioCodec.wav => 'WAV',
    AudioCodec.aiff => 'AIFF',
    AudioCodec.aac => 'AAC',
    AudioCodec.mp3 => 'MP3',
    AudioCodec.opus => 'Opus',
    AudioCodec.dsf => 'DSF',
    AudioCodec.dsdiff => 'DSDIFF',
  };

  bool get isLossless => switch (this) {
    AudioCodec.aac || AudioCodec.mp3 || AudioCodec.opus => false,
    _ => true,
  };

  static AudioCodec fromString(String? raw) => switch (raw?.toLowerCase().trim()) {
    'flac' => AudioCodec.flac,
    'alac' => AudioCodec.alac,
    'wav' || 'wave' => AudioCodec.wav,
    'aiff' || 'aif' => AudioCodec.aiff,
    'aac' => AudioCodec.aac,
    'mp3' => AudioCodec.mp3,
    'opus' || 'ogg' => AudioCodec.opus,
    'dsf' => AudioCodec.dsf,
    'dsdiff' || 'dff' => AudioCodec.dsdiff,
    _ => AudioCodec.flac,
  };

  static String displayNameFor(String? raw) => switch (raw?.toLowerCase().trim()) {
    'flac' => 'FLAC',
    'alac' => 'ALAC',
    'wav' || 'wave' => 'WAV',
    'aiff' || 'aif' => 'AIFF',
    'aac' => 'AAC',
    'mp3' => 'MP3',
    'opus' => 'Opus',
    'dsf' => 'DSF',
    'dsdiff' || 'dff' => 'DSDIFF',
    null || '' => 'FLAC',
    final other => other.toUpperCase(),
  };
}

class AudioFormat {
  final AudioCodec codec;
  final int sampleRateHz;
  final int bitDepth;
  final int channels;
  final bool isDsd;

  const AudioFormat({
    required this.codec,
    required this.sampleRateHz,
    required this.bitDepth,
    required this.channels,
    this.isDsd = false,
  });

  static String formatSampleRateKhz(int sampleRateHz) {
    if (sampleRateHz <= 0) return '0 kHz';
    final khz = sampleRateHz % 1000 == 0
        ? '${sampleRateHz ~/ 1000}'
        : (sampleRateHz / 1000.0).toStringAsFixed(1);
    return '$khz kHz';
  }

  static String formatLabel({
    required String codec,
    required int sampleRateHz,
    int bitDepth = 16,
    bool isDsd = false,
  }) {
    final lower = codec.toLowerCase().trim();
    if (isDsd || lower == 'dsf' || lower == 'dsdiff' || lower == 'dff') {
      final multiplier = sampleRateHz > 0 ? (sampleRateHz ~/ 44100) : 64;
      return 'DSD${multiplier > 0 ? multiplier : 64}';
    }
    final name = AudioCodec.displayNameFor(codec);
    final rate = formatSampleRateKhz(sampleRateHz);
    if (bitDepth > 0) {
      return '$name $rate / $bitDepth-bit';
    }
    return '$name $rate';
  }

  String get label => formatLabel(
    codec: codec.name,
    sampleRateHz: sampleRateHz,
    bitDepth: bitDepth,
    isDsd: isDsd,
  );
}
