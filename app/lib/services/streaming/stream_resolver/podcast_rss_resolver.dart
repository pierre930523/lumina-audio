import '../../../models/audio_format.dart';
import '../../../models/stream_source_spec.dart';
import '../../../models/streaming_models.dart';
import 'stream_resolver_base.dart';

/// Built-in resolver for external RSS podcast audio URLs (`providerId: 'podcast_rss'`).
///
/// Emits a [DirectRangeSpec] with standard browser `User-Agent` and `Accept`
/// headers plus inferred MIME/extension hints so Rust `ChunkedStreamProxy`
/// handles redirects, range seeking, and Symphonia probing reliably without
/// ever requiring account login or YouTube `videoId` parsing.
class ExternalPodcastRssResolver implements StreamResolver {
  static const String defaultBrowserUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static const Map<String, String> defaultBrowserHeaders = <String, String>{
    'User-Agent': defaultBrowserUserAgent,
    'Accept': '*/*',
    'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8',
  };

  const ExternalPodcastRssResolver();

  @override
  String get providerId => 'podcast_rss';

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities.podcastRss;

  /// Extracts a clean `http://` or `https://` URL from a prefixed or raw track ID.
  static String extractUrl(String raw) {
    var candidate = raw.trim();
    for (final prefix in const <String>[
      'streaming:podcast_rss:',
      'podcast_rss:',
      'rss:',
    ]) {
      if (candidate.startsWith(prefix)) {
        candidate = candidate.substring(prefix.length).trim();
        break;
      }
    }
    return candidate;
  }

  static ({String? mimeType, String? hintExtension, AudioFormat? audioFormat})
      inferAudioMetadata(String url) {
    final uri = Uri.tryParse(url);
    final path = (uri?.path ?? url).toLowerCase();
    if (path.endsWith('.mp3') || path.contains('.mp3/')) {
      return (
        mimeType: 'audio/mpeg',
        hintExtension: 'mp3',
        audioFormat: const AudioFormat(
          codec: AudioCodec.mp3,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
        ),
      );
    }
    if (path.endsWith('.m4a') || path.endsWith('.mp4')) {
      return (
        mimeType: 'audio/mp4',
        hintExtension: 'm4a',
        audioFormat: const AudioFormat(
          codec: AudioCodec.aac,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
        ),
      );
    }
    if (path.endsWith('.aac')) {
      return (
        mimeType: 'audio/aac',
        hintExtension: 'aac',
        audioFormat: const AudioFormat(
          codec: AudioCodec.aac,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
        ),
      );
    }
    if (path.endsWith('.webm')) {
      return (
        mimeType: 'audio/webm',
        hintExtension: 'webm',
        audioFormat: const AudioFormat(
          codec: AudioCodec.opus,
          sampleRateHz: 48000,
          bitDepth: 16,
          channels: 2,
        ),
      );
    }
    if (path.endsWith('.opus') || path.endsWith('.ogg') || path.endsWith('.oga')) {
      return (
        mimeType: 'audio/ogg',
        hintExtension: 'ogg',
        audioFormat: const AudioFormat(
          codec: AudioCodec.opus,
          sampleRateHz: 48000,
          bitDepth: 16,
          channels: 2,
        ),
      );
    }
    if (path.endsWith('.flac')) {
      return (
        mimeType: 'audio/flac',
        hintExtension: 'flac',
        audioFormat: const AudioFormat(
          codec: AudioCodec.flac,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
        ),
      );
    }
    if (path.endsWith('.wav')) {
      return (
        mimeType: 'audio/wav',
        hintExtension: 'wav',
        audioFormat: const AudioFormat(
          codec: AudioCodec.wav,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
        ),
      );
    }
    // Redirecting podcast CDN URLs (e.g. Podtrac/Megaphone/Anchor) may not carry
    // a file extension in the path; leave mimeType/hintExtension null so Rust
    // probes the redirected stream cleanly.
    return (mimeType: null, hintExtension: null, audioFormat: null);
  }

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();
    final cleanUrl = extractUrl(key.trackId);
    final uri = Uri.tryParse(cleanUrl);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw StreamingException('無效的外部 Podcast 音訊網址：$cleanUrl');
    }

    final meta = inferAudioMetadata(cleanUrl);
    return DirectRangeSpec(
      key: StreamKey(providerId, cleanUrl, key.qualityKey),
      url: cleanUrl,
      headers: defaultBrowserHeaders,
      mimeType: meta.mimeType,
      hintExtension: meta.hintExtension,
      audioFormat: meta.audioFormat,
    );
  }
}
