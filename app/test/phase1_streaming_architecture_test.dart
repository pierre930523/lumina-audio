import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/signal_path.dart';
import 'package:lumina_app/models/stream_source_spec.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/services/ffi_audio_service.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/streaming/playback_backend.dart';
import 'package:lumina_app/services/streaming/providers/apple_music_provider.dart';
import 'package:lumina_app/services/streaming/providers/deezer_provider.dart';
import 'package:lumina_app/services/streaming/providers/qobuz_provider.dart';
import 'package:lumina_app/services/streaming/providers/tidal_provider.dart';
import 'package:lumina_app/services/streaming/providers/youtube_music_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/stream_resolver.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';
import 'package:lumina_app/services/streaming/yt_dlp_service.dart';
import 'package:lumina_app/services/streaming/ytm_resident_resolver.dart';
import 'package:lumina_app/ui/mini_player/floating_capsule.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';

class _RealTestHttpOverrides extends HttpOverrides {}

TrackInfo _makeTrack(
  String id, {
  String providerName = 'Streaming',
  String? filePath,
  Duration duration = const Duration(minutes: 3),
}) {
  return TrackInfo(
    id: id,
    title: 'Title $id',
    artist: 'Artist',
    album: 'Album',
    duration: duration,
    filePath: filePath,
    format: const AudioFormat(
      codec: AudioCodec.flac,
      sampleRateHz: 44100,
      bitDepth: 16,
      channels: 2,
    ),
    providerName: providerName,
  );
}

Future<HttpServer> _startServer(
  FutureOr<void> Function(HttpRequest req, String body) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    try {
      final body = await utf8.decoder.bind(req).join();
      await handler(req, body);
    } catch (e) {
      req.response.statusCode = HttpStatus.internalServerError;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, dynamic>{'error': e.toString()}));
      await req.response.close();
    }
  });
  return server;
}

Future<void> _sendJson(
  HttpResponse resp,
  int statusCode,
  Object payload,
) async {
  resp.statusCode = statusCode;
  resp.headers.contentType = ContentType.json;
  resp.write(jsonEncode(payload));
  await resp.close();
}

class _CountingYtDlpService extends YtDlpService {
  int resolveCalls = 0;
  int openDashCalls = 0;
  int openTranscodedCalls = 0;

  @override
  Future<YtDlpResolvedStream> resolveVideo(
    String videoId, {
    required int playRequestId,
    String? cookiesFilePath,
    bool bypassCache = false,
    String? formatSelector,
    String? extractorArgs,
    String? remoteComponents,
  }) {
    resolveCalls++;
    throw StateError('YtDlpService.resolveVideo must NOT be called');
  }

  @override
  Future<String> openDashMpdUrl({
    required String mpdXml,
    required int playRequestId,
    bool copyFlac = true,
  }) {
    openDashCalls++;
    throw StateError('YtDlpService.openDashMpdUrl must NOT be called');
  }

  @override
  Future<String> openTranscodedWavUrl({
    required String sourceUrl,
    Map<String, String> headers = const <String, String>{},
    required int playRequestId,
  }) {
    openTranscodedCalls++;
    throw StateError('YtDlpService.openTranscodedWavUrl must NOT be called');
  }
}

class _SpyNativeAudioService extends MockAudioService {
  final List<({TrackInfo track, StreamSourceSpec spec, int epoch})> specPlays =
      [];
  int playCount = 0;
  int playUrlCount = 0;
  int playUrlAsyncCount = 0;
  int optimisticLoadCount = 0;
  int stopCount = 0;
  final List<Duration> seeks = [];

  @override
  void beginOptimisticTrackLoad(TrackInfo track, {List<TrackInfo>? queue}) {
    optimisticLoadCount++;
    super.beginOptimisticTrackLoad(track, queue: queue);
  }

  @override
  Future<void> play({TrackInfo? track}) {
    playCount++;
    return super.play(track: track);
  }

  @override
  Future<void> playStreamUrl({
    required TrackInfo track,
    required String streamUrl,
    Map<String, String> headers = const <String, String>{},
    String? hintExtension,
  }) {
    playUrlCount++;
    return super.playStreamUrl(
      track: track,
      streamUrl: streamUrl,
      headers: headers,
      hintExtension: hintExtension,
    );
  }

  @override
  Future<void> playStreamUrlAsync({
    required TrackInfo track,
    required String streamUrl,
    Map<String, String> headers = const <String, String>{},
    String? hintExtension,
    required int requestId,
  }) {
    playUrlAsyncCount++;
    return super.playStreamUrlAsync(
      track: track,
      streamUrl: streamUrl,
      headers: headers,
      hintExtension: hintExtension,
      requestId: requestId,
    );
  }

  @override
  Future<void> playStreamSpecAsync(
    TrackInfo track,
    StreamSourceSpec spec, {
    required int epoch,
  }) async {
    await super.playStreamSpecAsync(track, spec, epoch: epoch);
    specPlays.add((track: track, spec: spec, epoch: epoch));
  }

  @override
  Future<void> stop() {
    stopCount++;
    return super.stop();
  }

  @override
  Future<void> seek(Duration position) {
    seeks.add(position);
    return super.seek(position);
  }
}

class _SpyNativeBackend extends NativePlaybackBackend {
  final List<({StreamSourceSpec spec, TrackInfo track, int epoch})> playCalls =
      [];
  final List<int> stopEpochs = [];
  final List<({Duration position, int epoch})> seekCalls = [];

  _SpyNativeBackend(super.audioService);

  @override
  Future<void> play(
    StreamSourceSpec spec,
    TrackInfo track, {
    required int epoch,
  }) async {
    await super.play(spec, track, epoch: epoch);
    playCalls.add((spec: spec, track: track, epoch: epoch));
  }

  @override
  Future<void> stop({required int epoch}) {
    stopEpochs.add(epoch);
    return super.stop(epoch: epoch);
  }

  @override
  Future<void> seek(Duration position, {required int epoch}) {
    seekCalls.add((position: position, epoch: epoch));
    return super.seek(position, epoch: epoch);
  }
}

class _FakeExternalBridge implements ExternalPlaybackBridge {
  void Function(ExternalPlaybackEvent event)? _handler;
  final List<Map<String, dynamic>> configuredCalls = [];
  final List<({String trackUri, String? previewUrl, int epoch, String? webUrl})>
      playCalls = [];
  final List<int> stopEpochs = [];
  final List<({Duration position, int epoch})> seekCalls = [];
  final List<int> pauseEpochs = [];
  final List<int> resumeEpochs = [];
  final List<double> volumes = [];
  bool available = true;

  @override
  void setStateHandler(void Function(ExternalPlaybackEvent event)? handler) {
    _handler = handler;
  }

  void emitHostState(ExternalPlaybackEvent event) {
    _handler?.call(event);
  }

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<void> configure({
    required String developerToken,
    required String musicUserToken,
    String storefront = 'us',
  }) async {
    configuredCalls.add(<String, dynamic>{
      'developerToken': developerToken,
      'musicUserToken': musicUserToken,
      'storefront': storefront,
    });
  }

  @override
  Future<void> play({
    required String trackUri,
    String? previewUrl,
    required int epoch,
    String? externalWebUrl,
  }) async {
    playCalls.add((
      trackUri: trackUri,
      previewUrl: previewUrl,
      epoch: epoch,
      webUrl: externalWebUrl,
    ));
    _handler?.call(
      ExternalPlaybackEvent(
        epoch: epoch,
        status: 'playing',
        positionMs: 0,
        durationMs: 180000,
      ),
    );
  }

  @override
  Future<void> pause({required int epoch}) async {
    pauseEpochs.add(epoch);
  }

  @override
  Future<void> resume({required int epoch}) async {
    resumeEpochs.add(epoch);
  }

  @override
  Future<void> seek({required Duration position, required int epoch}) async {
    seekCalls.add((position: position, epoch: epoch));
  }

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
  }

  @override
  Future<void> stop({required int epoch}) async {
    stopEpochs.add(epoch);
  }

  @override
  void dispose() {
    _handler = null;
  }
}

class _CustomPluginResolver implements StreamResolver {
  @override
  final String providerId;

  @override
  final ProviderCapabilities capabilities;

  final Future<StreamSourceSpec> Function(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) handler;

  final List<StreamKey> seenKeys = [];
  final List<CancellationToken?> seenTokens = [];

  _CustomPluginResolver({
    required this.providerId,
    required this.capabilities,
    required this.handler,
  });

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) {
    seenKeys.add(key);
    seenTokens.add(cancelToken);
    return handler(key, cancelToken: cancelToken);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 1 Models & JSON Schema Parity', () {
    test('StreamKey equality, hashing, and toJson/fromJson round-trip', () {
      const k1 = StreamKey('qobuz', '12345', '27');
      const k2 = StreamKey('qobuz', '12345', '27');
      const k3 = StreamKey('qobuz', '12345', '6');

      expect(k1, equals(k2));
      expect(k1.hashCode, equals(k2.hashCode));
      expect(k1, isNot(equals(k3)));
      expect(k1.toJson(), <String, dynamic>{
        'provider_id': 'qobuz',
        'track_id': '12345',
        'quality_key': '27',
      });
      expect(StreamKey.fromJson(k1.toJson()), equals(k1));
    });

    test('ProviderCapabilities presets match exact Phase 1 matrix', () {
      expect(ProviderCapabilities.youtubeMusic.supportsL1UrlCache, isTrue);
      expect(ProviderCapabilities.youtubeMusic.supportsL2HeadCache, isTrue);
      expect(ProviderCapabilities.youtubeMusic.requiresRangeChunking, isTrue);
      expect(ProviderCapabilities.youtubeMusic.needsNetworkEpochReset, isTrue);
      expect(
        ProviderCapabilities.youtubeMusic.defaultL1SafetyMarginSec,
        equals(1800),
      );

      expect(ProviderCapabilities.qobuz.defaultL1SafetyMarginSec, equals(60));
      expect(ProviderCapabilities.qobuz.needsNetworkEpochReset, isFalse);

      expect(ProviderCapabilities.tidal.defaultL1SafetyMarginSec, equals(60));
      expect(ProviderCapabilities.tidal.requiresRangeChunking, isTrue);

      expect(ProviderCapabilities.deezer.defaultL1SafetyMarginSec, equals(120));
      expect(ProviderCapabilities.deezer.requiresRangeChunking, isTrue);

      for (final cap in const [
        ProviderCapabilities.appleMusic,
        ProviderCapabilities.local,
      ]) {
        expect(cap.supportsL1UrlCache, isFalse);
        expect(cap.supportsL2HeadCache, isFalse);
        expect(cap.requiresRangeChunking, isFalse);
        expect(cap.needsNetworkEpochReset, isFalse);
        expect(cap.defaultL1SafetyMarginSec, equals(0));
      }
    });

    test('All 5 StreamSourceSpec variants serialize to Rust core-types JSON 1:1', () {
      const key = StreamKey('tidal', '999', 'HI_RES_LOSSLESS');

      const direct = DirectRangeSpec(
        key: StreamKey('youtube_music', 'dQw4w9WgXcQ', 'default'),
        url: 'https://rr1.googlevideo.com/videoplayback?itag=251',
        headers: <String, String>{'User-Agent': 'LuminaTest/1.0'},
        contentLength: 4194304,
        bitrateBps: 160000,
        mimeType: 'audio/webm; codecs="opus"',
        hintExtension: 'webm',
        expireAt: 1790000000,
      );
      expect(direct.toJson(), <String, dynamic>{
        'kind': 'direct_range',
        'key': <String, dynamic>{
          'provider_id': 'youtube_music',
          'track_id': 'dQw4w9WgXcQ',
          'quality_key': 'default',
        },
        'url': 'https://rr1.googlevideo.com/videoplayback?itag=251',
        'headers': <String, String>{'User-Agent': 'LuminaTest/1.0'},
        'content_length': 4194304,
        'bitrate_bps': 160000,
        'mime_type': 'audio/webm; codecs="opus"',
        'hint_extension': 'webm',
        'expire_at': 1790000000,
      });
      expect(StreamSourceSpec.fromJson(direct.toJson()), equals(direct));

      const dash = SegmentedManifestSpec(
        key: key,
        manifestUrlOrXml: '<MPD><Period/></MPD>',
        format: ManifestFormat.dash,
        headers: <String, String>{'Accept': 'application/dash+xml'},
        bitrateBps: 2304000,
        mimeType: 'audio/flac',
        expireAt: 1790000100,
      );
      expect(dash.toJson()['kind'], equals('segmented_manifest'));
      expect(dash.toJson()['format'], equals('dash'));
      expect(dash.toJson()['manifest_url_or_xml'], equals('<MPD><Period/></MPD>'));
      expect(StreamSourceSpec.fromJson(dash.toJson()), equals(dash));

      const encrypted = EncryptedRangeSpec(
        key: StreamKey('deezer', '3135556', 'FLAC'),
        url: 'https://e-cdns-proxy.dzcdn.net/mobile/1/abc',
        contentLength: 32000000,
        bitrateBps: 1411000,
        mimeType: 'audio/flac',
        hintExtension: 'flac',
        cipher: DeezerBlowfishCipher(trackId: '3135556'),
        expireAt: 1790000200,
      );
      expect(encrypted.toJson()['kind'], equals('encrypted_range'));
      expect(encrypted.toJson()['cipher'], <String, dynamic>{
        'kind': 'deezer_blowfish',
        'track_id': '3135556',
        'block_size': 2048,
        'stride': 3,
      });
      expect(StreamSourceSpec.fromJson(encrypted.toJson()), equals(encrypted));

      const local = LocalFileSpec(
        key: StreamKey('local', 'C:/Music/test.flac', 'default'),
        path: 'C:/Music/test.flac',
      );
      expect(local.toJson(), <String, dynamic>{
        'kind': 'local_file',
        'key': <String, dynamic>{
          'provider_id': 'local',
          'track_id': 'C:/Music/test.flac',
          'quality_key': 'default',
        },
        'path': 'C:/Music/test.flac',
      });
      expect(StreamSourceSpec.fromJson(local.toJson()), equals(local));

      const external = ExternalBackendSpec(
        key: StreamKey('apple_music', '1440857781', 'default'),
        providerId: 'apple_music',
        trackUri: 'apple:1440857781',
        externalWebUrl: 'https://music.apple.com/us/song/1440857781',
        previewUrl: 'https://audio-ssl.itunes.apple.com/preview.m4a',
        notice: 'FairPlay DRM',
      );
      expect(external.toJson(), <String, dynamic>{
        'kind': 'external_backend',
        'key': <String, dynamic>{
          'provider_id': 'apple_music',
          'track_id': '1440857781',
          'quality_key': 'default',
        },
        'provider_id': 'apple_music',
        'track_uri': 'apple:1440857781',
        'external_web_url': 'https://music.apple.com/us/song/1440857781',
        'preview_url': 'https://audio-ssl.itunes.apple.com/preview.m4a',
        'notice': 'FairPlay DRM',
      });
      expect(StreamSourceSpec.fromJson(external.toJson()), equals(external));
      expect(external.loudness, isNull);
      expect(external.albumLoudness, isNull);
    });

    test('NormalizedLoudness helpers and StreamSourceSpec loudness JSON round-trip', () {
      expect(NormalizedLoudness.targetLufs, equals(-14.0));
      expect(
        NormalizedLoudness.fromYtmLoudnessDb(3.5),
        equals(const NormalizedLoudness(gainDb: -3.5, peak: 1.0)),
      );
      expect(
        NormalizedLoudness.fromReplayGain(-7.5, peak: 0.988),
        equals(const NormalizedLoudness(gainDb: -3.5, peak: 0.988)),
      );
      expect(
        NormalizedLoudness.fromDeezerGain(-4.2),
        equals(const NormalizedLoudness(gainDb: -3.2, peak: 1.0)),
      );
      expect(
        NormalizedLoudness.fromJson(const <String, dynamic>{
          'gain_db': double.nan,
          'peak': -1.0,
        }),
        equals(const NormalizedLoudness(gainDb: 0.0, peak: 1.0)),
      );

      final trackLoudness = NormalizedLoudness.fromReplayGain(-8.0, peak: 0.95);
      final albumLoudness = NormalizedLoudness.fromReplayGain(-6.5, peak: 0.99);
      final spec = DirectRangeSpec(
        key: const StreamKey('qobuz', '99', '27'),
        url: 'https://cdn.example.com/99.flac',
        loudness: trackLoudness,
        albumLoudness: albumLoudness,
      );
      final json = spec.toJson();
      expect(json['loudness'], <String, dynamic>{'gain_db': -4.0, 'peak': 0.95});
      expect(json['album_loudness'], <String, dynamic>{'gain_db': -2.5, 'peak': 0.99});
      final roundTrip = StreamSourceSpec.fromJson(json);
      expect(roundTrip, equals(spec));
      expect(roundTrip.loudness, equals(trackLoudness));
      expect(roundTrip.albumLoudness, equals(albumLoudness));
    });
  });

  group('StreamResolverRegistry Composite Key Dispatch', () {
    test('dispatches registered custom/local/streaming providers without hardcoded platform branches', () async {
      final registry = StreamResolverRegistry();
      final custom = _CustomPluginResolver(
        providerId: 'custom_hifi',
        capabilities: const ProviderCapabilities(
          supportsL1UrlCache: true,
          supportsL2HeadCache: true,
          requiresRangeChunking: true,
          needsNetworkEpochReset: false,
          defaultL1SafetyMarginSec: 45,
        ),
        handler: (key, {cancelToken}) async => DirectRangeSpec(
          key: key,
          url: 'https://custom.example.com/${key.trackId}.flac',
          hintExtension: 'flac',
          mimeType: 'audio/flac',
        ),
      );
      registry.register(
        custom,
        idPrefixes: const ['chf:'],
        providerNames: const ['Custom HiFi'],
      );

      final customTrack = _makeTrack('chf:track_42', providerName: 'Custom HiFi');
      final customSpec = await registry.resolveTrack(customTrack);
      expect(customSpec, isA<DirectRangeSpec>());
      expect(
        customSpec.key,
        equals(const StreamKey('custom_hifi', 'track_42', 'default')),
      );
      expect(custom.seenKeys, equals([const StreamKey('custom_hifi', 'track_42', 'default')]));

      final localTrack = _makeTrack(
        'local-1',
        providerName: 'Local Library',
        filePath: 'D:/FLAC/01.flac',
      );
      final localSpec = await registry.resolveTrack(localTrack);
      expect(localSpec, isA<LocalFileSpec>());
      expect((localSpec as LocalFileSpec).path, equals('D:/FLAC/01.flac'));
    });
  });

  group('YtmResidentResolver & Zero-Subprocess InnerTube Resolution', () {
    test('owns persistent keep-alive HttpClient (60s idle, 4 maxConn/host), strictly picks itag 251 -> 140, and spawns 0 CLI processes', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final seenClientHeaders = <({String? clientName, String? cookie, String? auth, String? origin})>[];
        var scenario = 'prefer_251';

        final server = await _startServer((req, body) async {
          if (req.uri.path != '/youtubei/v1/player') {
            return _sendJson(req.response, HttpStatus.notFound, {});
          }
          seenClientHeaders.add((
            clientName: req.headers.value('x-youtube-client-name'),
            cookie: req.headers.value('cookie'),
            auth: req.headers.value('authorization'),
            origin: req.headers.value('origin'),
          ));
          final clientHeader = req.headers.value('x-youtube-client-name');

          if (scenario == 'prefer_251') {
            return _sendJson(req.response, HttpStatus.ok, {
              'playabilityStatus': {'status': 'OK'},
              'streamingData': {
                'expiresInSeconds': '21600',
                'adaptiveFormats': [
                  {
                    'itag': 141,
                    'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
                    'bitrate': 256000,
                    'contentLength': '8000000',
                    'audioSampleRate': '44100',
                    'url': 'https://rr1.googlevideo.com/videoplayback?itag=141&expire=1790000141',
                  },
                  {
                    'itag': 140,
                    'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
                    'bitrate': 128000,
                    'contentLength': '4000000',
                    'audioSampleRate': '44100',
                    'url': 'https://rr1.googlevideo.com/videoplayback?itag=140&expire=1790000140',
                  },
                  {
                    'itag': 251,
                    'mimeType': 'audio/webm; codecs="opus"',
                    'bitrate': 160000,
                    'contentLength': '5200000',
                    'audioSampleRate': '48000',
                    'audioChannels': 2,
                    'url': 'https://rr1.googlevideo.com/videoplayback?itag=251&expire=1790000251',
                  },
                ],
              },
            });
          }

          if (scenario == 'fallback_140') {
            if (clientHeader == '28') {
              return _sendJson(req.response, HttpStatus.ok, {
                'playabilityStatus': {'status': 'LOGIN_REQUIRED', 'reason': 'Sign in'},
              });
            }
            if (clientHeader == '67') {
              return _sendJson(req.response, HttpStatus.ok, {
                'playabilityStatus': {'status': 'OK'},
                'streamingData': {
                  'expiresInSeconds': '1800',
                  'adaptiveFormats': [
                    {
                      'itag': 139,
                      'mimeType': 'audio/mp4; codecs="mp4a.40.5"',
                      'bitrate': 48000,
                      'contentLength': '1200000',
                      'url': 'https://rr1.googlevideo.com/videoplayback?itag=139',
                    },
                    {
                      'itag': 140,
                      'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
                      'bitrate': 130000,
                      'contentLength': '3900000',
                      'audioSampleRate': '44100',
                      'url': 'https://rr1.googlevideo.com/videoplayback?itag=140&expire=1790001140',
                    },
                  ],
                },
              });
            }
          }

          if (scenario == 'web_remix_auth') {
            if (clientHeader == '28') {
              return _sendJson(req.response, HttpStatus.forbidden, {'error': 'blocked'});
            }
            if (clientHeader == '67') {
              return _sendJson(req.response, HttpStatus.ok, {
                'playabilityStatus': {'status': 'OK'},
                'streamingData': {
                  'adaptiveFormats': [
                    {
                      'itag': 251,
                      'mimeType': 'audio/webm; codecs="opus"',
                      'bitrate': 162000,
                      'contentLength': '5100000',
                      'audioSampleRate': '48000',
                      'url': 'https://rr2.googlevideo.com/videoplayback?itag=251&expire=1790002251',
                    },
                  ],
                },
              });
            }
          }

          return _sendJson(req.response, HttpStatus.notFound, {});
        });
        addTearDown(() => server.close(force: true));

        final baseUrl = 'http://127.0.0.1:${server.port}';
        final resident = YtmResidentResolver(
          webBaseUrl: baseUrl,
          musicBaseUrl: baseUrl,
          authProvider: () => const YtmAuthCredentials(
            authMode: 'cookie',
            cookie: 'SAPISID=test_sapisid_val; SID=abc',
          ),
        );
        addTearDown(resident.dispose);

        expect(resident.httpClient.idleTimeout, equals(const Duration(seconds: 60)));
        expect(resident.httpClient.maxConnectionsPerHost, equals(4));

        // 1. Strictly prefers itag 251 over 141 and 140.
        final spec251 = await resident.resolve(
          const StreamKey('youtube_music', 'dQw4w9WgXcQ', 'default'),
        );
        expect(spec251, isA<DirectRangeSpec>());
        final direct251 = spec251 as DirectRangeSpec;
        expect(direct251.url, contains('itag=251'));
        expect(direct251.hintExtension, equals('webm'));
        expect(direct251.mimeType, contains('audio/webm'));
        expect(direct251.contentLength, equals(5200000));
        expect(direct251.bitrateBps, equals(160000));
        expect(direct251.expireAt, equals(1790000251));
        expect(direct251.headers['User-Agent'], isNotEmpty);
        expect(seenClientHeaders.last.clientName, equals('28'));
        expect(seenClientHeaders.last.cookie, isNull);
        expect(seenClientHeaders.last.auth, isNull);

        // 2. Falls back ANDROID_VR -> VISIONOS -> WEB_REMIX (never deprecated client 85) and picks itag 140 when 251 absent.
        scenario = 'fallback_140';
        seenClientHeaders.clear();
        final spec140 = await resident.resolve(
          const StreamKey('youtube_music', 'DYptgVvkVLQ', 'default'),
        );
        final direct140 = spec140 as DirectRangeSpec;
        expect(direct140.url, contains('itag=140'));
        expect(direct140.hintExtension, equals('m4a'));
        expect(direct140.mimeType, contains('audio/mp4'));
        expect(direct140.contentLength, equals(3900000));
        expect(direct140.bitrateBps, equals(130000));
        expect(direct140.expireAt, equals(1790001140));
        expect(
          seenClientHeaders.map((c) => c.clientName).toList(),
          equals(['28', '101', '67']),
        );
        expect(seenClientHeaders.first.cookie, isNull);
        expect(seenClientHeaders.first.auth, isNull);
        expect(seenClientHeaders.first.origin, isNull);
        expect(seenClientHeaders[1].cookie, isNull);
        expect(seenClientHeaders[1].auth, isNull);
        expect(seenClientHeaders[1].origin, isNull);
        expect(seenClientHeaders.any((c) => c.clientName == '85'), isFalse);

        // 3. Falls back ANDROID_VR -> VISIONOS -> authenticated WEB_REMIX (never deprecated client 85).
        scenario = 'web_remix_auth';
        seenClientHeaders.clear();
        final specWeb = await resident.resolve(
          const StreamKey('youtube_music', 'YhiQDARUJ7Y', 'default'),
        );
        expect((specWeb as DirectRangeSpec).url, contains('itag=251'));
        expect(
          seenClientHeaders.map((c) => c.clientName).toList(),
          equals(['28', '101', '67']),
        );
        expect(seenClientHeaders.first.cookie, isNull);
        expect(seenClientHeaders.first.auth, isNull);
        expect(seenClientHeaders[1].cookie, isNull);
        expect(seenClientHeaders[1].auth, isNull);
        expect(seenClientHeaders.last.auth, startsWith('SAPISIDHASH '));
        expect(seenClientHeaders.last.cookie, contains('SAPISID=test_sapisid_val'));

        // 4. YouTubeMusicProvider delegates StreamResolver.resolve to YtmResidentResolver with 0 yt-dlp spawns.
        scenario = 'prefer_251';
        final countingYtDlp = _CountingYtDlpService();
        addTearDown(countingYtDlp.dispose);
        final ytm = YouTubeMusicProvider(
          credentialStore: MemorySecureCredentialStore(),
          baseUrl: baseUrl,
          ytDlpService: countingYtDlp,
        );
        addTearDown(ytm.dispose);

        expect(ytm.capabilities, equals(ProviderCapabilities.youtubeMusic));
        final ytmSpec = await ytm.resolve(
          const StreamKey('youtube_music', 'dQw4w9WgXcQ', 'default'),
        );
        expect(ytmSpec, isA<DirectRangeSpec>());
        expect((ytmSpec as DirectRangeSpec).hintExtension, equals('webm'));
        expect(countingYtDlp.resolveCalls, equals(0));
        expect(countingYtDlp.openDashCalls, equals(0));
        expect(countingYtDlp.openTranscodedCalls, equals(0));

        // 5. CancellationToken cancels in-flight resolve without closing persistent HttpClient.
        final hungServer = await _startServer((req, body) async {
          // Hold response open until cancelled.
        });
        addTearDown(() => hungServer.close(force: true));

        final cancelResident = YtmResidentResolver(
          webBaseUrl: 'http://127.0.0.1:${hungServer.port}',
          musicBaseUrl: 'http://127.0.0.1:${hungServer.port}',
        );
        addTearDown(cancelResident.dispose);

        final cancelToken = CancellationToken();
        Timer(const Duration(milliseconds: 30), cancelToken.cancel);
        await expectLater(
          cancelResident.resolve(
            const StreamKey('youtube_music', 'dQw4w9WgXcQ', 'default'),
            cancelToken: cancelToken,
          ),
          throwsA(
            isA<StreamingException>().having(
              (e) => e.isCancelled,
              'isCancelled',
              isTrue,
            ),
          ),
        );

        // Resident keep-alive HttpClient remains healthy for subsequent resolves.
        final postCancelServer = await _startServer((req, body) async {
          return _sendJson(req.response, HttpStatus.ok, {
            'playabilityStatus': {'status': 'OK'},
            'streamingData': {
              'adaptiveFormats': [
                {
                  'itag': 251,
                  'mimeType': 'audio/webm; codecs="opus"',
                  'url': 'https://rr1.googlevideo.com/videoplayback?itag=251',
                },
              ],
            },
          });
        });
        addTearDown(() => postCancelServer.close(force: true));
        final healthyResident = YtmResidentResolver(
          httpClient: cancelResident.httpClient,
          webBaseUrl: 'http://127.0.0.1:${postCancelServer.port}',
          musicBaseUrl: 'http://127.0.0.1:${postCancelServer.port}',
        );
        final afterCancelSpec = await healthyResident.resolve(
          const StreamKey('youtube_music', 'dQw4w9WgXcQ', 'default'),
        );
        expect((afterCancelSpec as DirectRangeSpec).hintExtension, equals('webm'));
      }, _RealTestHttpOverrides());
    });
  });

  group('All 5 Providers StreamResolver Outputs', () {
    test('Qobuz, Tidal (BTS + DASH + DRM), Deezer (ARL EncryptedRange + preview), and Apple Music (ExternalBackendSpec)', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final countingYtDlp = _CountingYtDlpService();
        addTearDown(countingYtDlp.dispose);
        var tidalMode = 'dash_clear';

        final server = await _startServer((req, body) async {
          final path = req.uri.path;
          // Qobuz
          if (path == '/qobuz/user/get') {
            return _sendJson(req.response, HttpStatus.ok, {
              'id': 1,
              'login': 'qb@example.com',
              'credential': {'parameters': {'label': 'Studio'}},
            });
          }
          if (path == '/qobuz/track/getFileUrl') {
            return _sendJson(req.response, HttpStatus.ok, {
              'url': 'https://streaming-qobuz-std.akamaized.net/file.flac?exp=1790000900',
              'format_id': 27,
              'sampling_rate': 192.0,
              'bit_depth': 24,
              'mime_type': 'audio/flac',
            });
          }

          // Tidal
          if (path == '/tidal/sessions') {
            return _sendJson(req.response, HttpStatus.ok, {'userId': 99, 'countryCode': 'US'});
          }
          if (path == '/tidal/users/99') {
            return _sendJson(req.response, HttpStatus.ok, {'id': 99});
          }
          if (path == '/tidal/users/99/subscription') {
            return _sendJson(req.response, HttpStatus.ok, {'highestSoundQuality': 'HI_RES_LOSSLESS'});
          }
          if (path == '/tidal/tracks/888/playbackinfopostpaywall') {
            if (tidalMode == 'bts') {
              final bts = jsonEncode({
                'mimeType': 'audio/flac',
                'codecs': 'flac',
                'encryptionType': 'NONE',
                'bitDepth': 16,
                'sampleRate': 44100,
                'urls': ['https://sp-pr-cf.audio.tidal.com/888.flac'],
              });
              return _sendJson(req.response, HttpStatus.ok, {
                'audioQuality': 'LOSSLESS',
                'manifestMimeType': 'application/vnd.tidal.bts',
                'manifest': base64Encode(utf8.encode(bts)),
              });
            }
            if (tidalMode == 'dash_drm') {
              const drmMpd =
                  '<MPD><Period><AdaptationSet><ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/><Representation codecs="flac"><SegmentTemplate initialization="https://audio.tidal.com/0.mp4"/></Representation></AdaptationSet></Period></MPD>';
              return _sendJson(req.response, HttpStatus.ok, {
                'audioQuality': 'HI_RES_LOSSLESS',
                'manifestMimeType': 'application/dash+xml',
                'manifest': base64Encode(utf8.encode(drmMpd)),
              });
            }
            const clearMpd =
                '<MPD><Period><AdaptationSet><Representation codecs="flac" audioSamplingRate="96000"><SegmentTemplate initialization="https://audio.tidal.com/init.mp4" media="https://audio.tidal.com/seg_\$Number\$.m4s"/></Representation></AdaptationSet></Period></MPD>';
            return _sendJson(req.response, HttpStatus.ok, {
              'audioQuality': 'HI_RES_LOSSLESS',
              'sampleRate': 96000,
              'bitDepth': 24,
              'manifestMimeType': 'application/dash+xml',
              'manifest': base64Encode(utf8.encode(clearMpd)),
            });
          }

          // Deezer
          if (path == '/deezer/gw') {
            final method = req.uri.queryParameters['method'];
            if (method == 'deezer.getUserData') {
              return _sendJson(req.response, HttpStatus.ok, {
                'results': {
                  'USER': {
                    'USER_ID': 77,
                    'BLOG_NAME': 'DeezerPro',
                    'OPTIONS': {
                      'license_token': 'lic_tok',
                      'web_lossless': true,
                      'web_hq': true,
                    },
                  },
                  'checkForm': 'api_tok_1',
                },
              });
            }
            if (method == 'song.getData') {
              return _sendJson(req.response, HttpStatus.ok, {
                'results': {'TRACK_TOKEN': 'trk_tok_1'},
              });
            }
          }
          if (path == '/deezer/media') {
            return _sendJson(req.response, HttpStatus.ok, {
              'data': [
                {
                  'media': [
                    {
                      'format': 'FLAC',
                      'exp': 1790005555,
                      'sources': [
                        {'url': 'https://e-cdns-proxy.dzcdn.net/mobile/1/encrypted.flac'},
                      ],
                    },
                  ],
                },
              ],
            });
          }
          if (path == '/deezer/oauth/access_token.php') {
            return _sendJson(req.response, HttpStatus.ok, {
              'access_token': 'dz_oa',
              'expires': 3600,
            });
          }
          if (path == '/deezer/api/user/me') {
            return _sendJson(req.response, HttpStatus.ok, {'id': 88, 'name': 'OAuthUser'});
          }
          if (path == '/deezer/api/track/3135556') {
            return _sendJson(req.response, HttpStatus.ok, {
              'id': 3135556,
              'preview': 'https://cdns-preview.dzcdn.net/stream/preview.mp3',
            });
          }

          // Apple Music
          if (path == '/apple/v1/me/storefront') {
            return _sendJson(req.response, HttpStatus.ok, {
              'data': [
                {
                  'id': 'tw',
                  'attributes': {'name': 'Taiwan'},
                },
              ],
            });
          }
          if (path == '/apple/v1/catalog/tw/songs/1440857781') {
            return _sendJson(req.response, HttpStatus.ok, {
              'data': [
                {
                  'id': '1440857781',
                  'attributes': {
                    'url': 'https://music.apple.com/tw/song/test/1440857781',
                    'previews': [
                      {'url': 'https://audio-ssl.itunes.apple.com/preview_apple.m4a'},
                    ],
                  },
                },
              ],
            });
          }

          return _sendJson(req.response, HttpStatus.notFound, {});
        });
        addTearDown(() => server.close(force: true));

        final base = 'http://127.0.0.1:${server.port}';
        final store = MemorySecureCredentialStore();

        // Qobuz
        final qobuz = QobuzProvider(credentialStore: store, baseUrl: '$base/qobuz');
        await qobuz.authenticate({
          'mode': 'token',
          'app_id': 'app1',
          'app_secret': 'sec1',
          'user_auth_token': 'tok1',
        });
        expect(qobuz.capabilities, equals(ProviderCapabilities.qobuz));
        final qobuzSpec = await qobuz.resolve(const StreamKey('qobuz', '555', '27'));
        expect(qobuzSpec, isA<DirectRangeSpec>());
        expect((qobuzSpec as DirectRangeSpec).hintExtension, equals('flac'));
        expect(qobuzSpec.expireAt, equals(1790000900));

        // Tidal clear DASH -> SegmentedManifestSpec with 0 FfmpegAudioProxy calls!
        final tidal = TidalProvider(
          credentialStore: store,
          authBaseUrl: '$base/tidal',
          tokenBaseUrl: '$base/tidal',
          apiBaseUrl: '$base/tidal',
          ytDlpService: countingYtDlp,
        );
        await tidal.authenticate({'mode': 'access_token', 'access_token': 'tok_t'});
        expect(tidal.capabilities, equals(ProviderCapabilities.tidal));
        final dashSpec = await tidal.resolve(const StreamKey('tidal', '888', 'HI_RES_LOSSLESS'));
        expect(dashSpec, isA<SegmentedManifestSpec>());
        expect((dashSpec as SegmentedManifestSpec).format, equals(ManifestFormat.dash));
        expect(dashSpec.manifestUrlOrXml, contains('<MPD>'));
        expect(countingYtDlp.openDashCalls, equals(0));

        // Tidal BTS -> DirectRangeSpec
        tidalMode = 'bts';
        final btsSpec = await tidal.resolve(const StreamKey('tidal', '888', 'LOSSLESS'));
        expect(btsSpec, isA<DirectRangeSpec>());
        expect((btsSpec as DirectRangeSpec).url, contains('888.flac'));

        // Tidal <ContentProtection -> StreamingException(isDrmRestricted: true)
        tidalMode = 'dash_drm';
        await expectLater(
          tidal.resolve(const StreamKey('tidal', '888', 'HI_RES_LOSSLESS')),
          throwsA(
            isA<StreamingException>().having(
              (e) => e.isDrmRestricted,
              'isDrmRestricted',
              isTrue,
            ),
          ),
        );

        // Deezer full ARL -> EncryptedRangeSpec(DeezerBlowfishCipher)
        final deezerArl = DeezerProvider(
          credentialStore: store,
          gwUrl: '$base/deezer/gw',
          apiBaseUrl: '$base/deezer/api',
          mediaBaseUrl: '$base/deezer/media',
        );
        await deezerArl.authenticate({'mode': 'arl', 'arl': 'arl_secret'});
        expect(deezerArl.capabilities, equals(ProviderCapabilities.deezer));
        final dzFullSpec = await deezerArl.resolve(const StreamKey('deezer', '3135556', 'FLAC'));
        expect(dzFullSpec, isA<EncryptedRangeSpec>());
        final enc = dzFullSpec as EncryptedRangeSpec;
        expect(enc.cipher, equals(const DeezerBlowfishCipher(trackId: '3135556', blockSize: 2048, stride: 3)));
        expect(enc.expireAt, equals(1790005555));

        // Deezer OAuth preview -> DirectRangeSpec
        final dzOauth = DeezerProvider(
          credentialStore: store,
          gwUrl: '$base/deezer/gw',
          oauthBaseUrl: '$base/deezer',
          apiBaseUrl: '$base/deezer/api',
          mediaBaseUrl: '$base/deezer/media',
        );
        await dzOauth.authenticate({
          'mode': 'oauth',
          'app_id': 'dz_app',
          'app_secret': 'dz_sec',
          'code': 'dz_code',
        });
        final dzPrevSpec = await dzOauth.resolve(const StreamKey('deezer', '3135556', 'default'));
        expect(dzPrevSpec, isA<DirectRangeSpec>());
        expect((dzPrevSpec as DirectRangeSpec).url, contains('preview.mp3'));

        // Apple Music -> ExternalBackendSpec, capabilities all false
        final apple = AppleMusicProvider(
          credentialStore: store,
          apiBaseUrl: '$base/apple',
        );
        await apple.authenticate({
          'mode': 'musickit_tokens',
          'developer_token': 'dev_jwt',
          'music_user_token': 'user_mut',
        });
        expect(apple.capabilities, equals(ProviderCapabilities.appleMusic));
        final appleSpec = await apple.resolve(const StreamKey('apple_music', '1440857781', 'default'));
        expect(appleSpec, isA<ExternalBackendSpec>());
        final ext = appleSpec as ExternalBackendSpec;
        expect(ext.providerId, equals('apple_music'));
        expect(ext.trackUri, equals('apple:1440857781'));
        expect(ext.previewUrl, contains('preview_apple.m4a'));
      }, _RealTestHttpOverrides());
    });
  });

  group('AppleMusicPlaybackBackend Isolation & FfiAudioService Spec/Epoch', () {
    test('AppleMusicPlaybackBackend is 100% isolated from NativePlaybackBackend/AudioService/proxy and rejects non-external specs', () async {
      final audio = _SpyNativeAudioService();
      addTearDown(audio.dispose);
      final nativeBackend = _SpyNativeBackend(audio);
      final bridge = _FakeExternalBridge();
      final externalBackend = AppleMusicPlaybackBackend(
        bridge: bridge,
        credentialsProvider: () => const AppleMusicCredentials(
          developerToken: 'dev_1',
          musicUserToken: 'mut_1',
          storefront: 'us',
        ),
      );
      addTearDown(externalBackend.dispose);

      const extSpec = ExternalBackendSpec(
        key: StreamKey('apple_music', '1440857781', 'default'),
        providerId: 'apple_music',
        trackUri: 'apple:1440857781',
        externalWebUrl: 'https://music.apple.com/us/song/1440857781',
        previewUrl: 'https://audio-ssl.itunes.apple.com/preview.m4a',
        notice: 'FairPlay DRM',
      );
      const nativeSpec = DirectRangeSpec(
        key: StreamKey('qobuz', '123', '27'),
        url: 'https://cdn.example.com/123.flac',
      );
      final track = _makeTrack('apple:1440857781', providerName: 'Apple Music');

      // NativePlaybackBackend and AudioService reject ExternalBackendSpec.
      await expectLater(
        () => nativeBackend.play(extSpec, track, epoch: 1),
        throwsStateError,
      );
      await expectLater(
        () => audio.playStreamSpecAsync(track, extSpec, epoch: 1),
        throwsStateError,
      );
      // AppleMusicPlaybackBackend rejects DirectRangeSpec.
      await expectLater(
        externalBackend.play(nativeSpec, track, epoch: 1),
        throwsStateError,
      );
      nativeBackend.playCalls.clear();
      audio.specPlays.clear();

      // Coordinator routing Apple Music -> ExternalBackend produces ZERO native calls.
      final countingYtDlp = _CountingYtDlpService();
      addTearDown(countingYtDlp.dispose);
      final registry = StreamResolverRegistry()
        ..register(
          _CustomPluginResolver(
            providerId: 'apple_music',
            capabilities: ProviderCapabilities.appleMusic,
            handler: (key, {cancelToken}) async => extSpec,
          ),
          idPrefixes: const ['apple:'],
          providerNames: const ['Apple Music'],
        );
      final manager = StreamingManager(
        credentialStore: MemorySecureCredentialStore(),
        ytDlpService: countingYtDlp,
      );
      addTearDown(manager.dispose);

      final coordinator = StreamingPlaybackCoordinator(
        audioService: audio,
        streamingManager: manager,
        resolverRegistry: registry,
        nativeBackend: nativeBackend,
        externalBackend: externalBackend,
        debounceDelay: Duration.zero,
      );
      addTearDown(coordinator.dispose);

      await coordinator.playTrack(track);

      expect(nativeBackend.playCalls, isEmpty);
      expect(audio.optimisticLoadCount, equals(0));
      expect(audio.playCount, equals(0));
      expect(audio.playUrlCount, equals(0));
      expect(audio.playUrlAsyncCount, equals(0));
      expect(audio.specPlays, isEmpty);
      expect(countingYtDlp.resolveCalls, equals(0));
      expect(countingYtDlp.openDashCalls, equals(0));
      expect(countingYtDlp.openTranscodedCalls, equals(0));

      expect(bridge.configuredCalls, hasLength(1));
      expect(bridge.playCalls.single.trackUri, equals('apple:1440857781'));
      expect(bridge.playCalls.single.epoch, equals(1));
      expect(externalBackend.currentState.status, equals(PlaybackStatus.playing));

      // Stale bridge event from older epoch is ignored; matching epoch updates state.
      bridge.emitHostState(
        const ExternalPlaybackEvent(epoch: 99, status: 'error', error: 'stale'),
      );
      expect(externalBackend.currentState.status, equals(PlaybackStatus.playing));

      bridge.emitHostState(
        const ExternalPlaybackEvent(
          epoch: 1,
          status: 'paused',
          positionMs: 12000,
          durationMs: 180000,
        ),
      );
      expect(externalBackend.currentState.status, equals(PlaybackStatus.paused));
      expect(
        externalBackend.currentState.position,
        equals(const Duration(seconds: 12)),
      );
    });

    test('MethodChannelExternalPlaybackBridge handles calls & MissingPluginException gracefully', () async {
      final recordedMethods = <(String method, dynamic args)>[];
      const channel = MethodChannel(MethodChannelExternalPlaybackBridge.channelName);
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        recordedMethods.add((call.method, call.arguments));
        if (call.method == 'isAvailable') return true;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final bridge = MethodChannelExternalPlaybackBridge();
      addTearDown(bridge.dispose);
      final receivedEvents = <ExternalPlaybackEvent>[];
      bridge.setStateHandler(receivedEvents.add);

      expect(await bridge.isAvailable(), isTrue);
      await bridge.configure(
        developerToken: 'dev_tok',
        musicUserToken: 'mut_tok',
        storefront: 'jp',
      );
      await bridge.play(
        trackUri: 'apple:1440857781',
        previewUrl: 'https://preview.example.com/a.m4a',
        epoch: 11,
        externalWebUrl: 'https://music.apple.com/jp/song/1440857781',
      );
      await bridge.pause(epoch: 11);
      await bridge.resume(epoch: 11);
      await bridge.seek(position: const Duration(seconds: 42), epoch: 12);
      await bridge.setVolume(0.75);
      await bridge.stop(epoch: 13);

      expect(
        recordedMethods.map((m) => m.$1).toList(),
        equals([
          'isAvailable',
          'configure',
          'play',
          'pause',
          'resume',
          'seek',
          'setVolume',
          'stop',
        ]),
      );

      // Simulate Win32 ExternalMusicHost calling `onState` back into Dart.
      await messenger.handlePlatformMessage(
        MethodChannelExternalPlaybackBridge.channelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('onState', <String, dynamic>{
            'epoch': 12,
            'status': 'playing',
            'positionMs': 42000,
            'durationMs': 210000,
          }),
        ),
        (_) {},
      );
      expect(receivedEvents, hasLength(1));
      expect(receivedEvents.single.epoch, equals(12));
      expect(receivedEvents.single.status, equals('playing'));
      expect(receivedEvents.single.positionMs, equals(42000));

      final headlessBridge = MethodChannelExternalPlaybackBridge(
        channel: const MethodChannel('lumina/test_missing_channel'),
      );
      addTearDown(headlessBridge.dispose);

      final errors = <ExternalPlaybackEvent>[];
      headlessBridge.setStateHandler(errors.add);
      expect(await headlessBridge.isAvailable(), isFalse);
      await headlessBridge.configure(
        developerToken: 'd',
        musicUserToken: 'u',
      );
      await headlessBridge.play(trackUri: 'apple:1', epoch: 3);
      await headlessBridge.pause(epoch: 3);
      await headlessBridge.resume(epoch: 3);
      await headlessBridge.seek(position: const Duration(seconds: 5), epoch: 3);
      await headlessBridge.setVolume(0.5);
      await headlessBridge.stop(epoch: 3);

      expect(errors, hasLength(1));
      expect(errors.single.epoch, equals(3));
      expect(errors.single.status, equals('error'));
    });

    test('FfiAudioService serializes source_spec + epoch and drops stale epoch state JSON', () async {
      final ffiService = FfiAudioService(headless: true);
      addTearDown(ffiService.dispose);

      const spec = EncryptedRangeSpec(
        key: StreamKey('deezer', '3135556', 'FLAC'),
        url: 'https://e-cdns-proxy.dzcdn.net/mobile/1/encrypted.flac',
        contentLength: 1024,
        bitrateBps: 1411000,
        mimeType: 'audio/flac',
        hintExtension: 'flac',
        cipher: DeezerBlowfishCipher(trackId: '3135556'),
      );
      final track = _makeTrack('deezer:3135556', providerName: 'Deezer');

      final encoded = jsonDecode(
        ffiService.encodeStreamSpecPayloadForTest(track, spec, epoch: 7),
      ) as Map<String, dynamic>;
      expect(encoded['epoch'], equals(7));
      expect(encoded['source_spec'], equals(spec.toJson()));
      expect(
        encoded['stream_url'],
        equals('https://e-cdns-proxy.dzcdn.net/mobile/1/encrypted.flac'),
      );

      final emitted = <PlaybackState>[];
      final sub = ffiService.stateStream.listen(emitted.add);
      addTearDown(sub.cancel);

      ffiService.setActiveEpochForTest(7);
      expect(
        ffiService.processStateJsonForTest(<String, dynamic>{
          'epoch': 6,
          'play_request_id': 6,
          'loaded_request_id': 6,
          'state_code': 2,
          'position_ms': 9000,
        }),
        isFalse,
      );
      expect(
        ffiService.processStateJsonForTest(<String, dynamic>{
          'epoch': 7,
          'play_request_id': 7,
          'loaded_request_id': 7,
          'state_code': 2,
          'position_ms': 1500,
        }),
        isTrue,
      );
      await Future<void>.delayed(Duration.zero);
      expect(emitted, hasLength(1));
      expect(emitted.single.position, equals(const Duration(milliseconds: 1500)));
    });
  });

  group('20x Rapid Cross-Platform Skip, Seek & Epoch Cancellation', () {
    test('20x rapid cross-platform skipping + repeated seeks cancel all stale tokens, stop inactive backend, and leave 0 stale playback', () async {
      final audio = _SpyNativeAudioService();
      addTearDown(audio.dispose);
      final nativeBackend = _SpyNativeBackend(audio);
      final bridge = _FakeExternalBridge();
      final externalBackend = AppleMusicPlaybackBackend(bridge: bridge);
      addTearDown(externalBackend.dispose);

      final allTokens = <CancellationToken>[];
      final pendingResolves = <Completer<StreamSourceSpec>>[];

      StreamResolverRegistry buildRegistry() {
        final reg = StreamResolverRegistry();
        final specs = <String, (ProviderCapabilities, StreamSourceSpec Function(StreamKey))>{
          'youtube_music': (
            ProviderCapabilities.youtubeMusic,
            (k) => DirectRangeSpec(
              key: k,
              url: 'https://rr1.googlevideo.com/${k.trackId}?itag=251',
              hintExtension: 'webm',
              mimeType: 'audio/webm; codecs="opus"',
            ),
          ),
          'qobuz': (
            ProviderCapabilities.qobuz,
            (k) => DirectRangeSpec(
              key: k,
              url: 'https://qobuz.example.com/${k.trackId}.flac',
              hintExtension: 'flac',
              mimeType: 'audio/flac',
            ),
          ),
          'tidal': (
            ProviderCapabilities.tidal,
            (k) => SegmentedManifestSpec(
              key: k,
              manifestUrlOrXml: '<MPD id="${k.trackId}"><Period/></MPD>',
              format: ManifestFormat.dash,
            ),
          ),
          'deezer': (
            ProviderCapabilities.deezer,
            (k) => EncryptedRangeSpec(
              key: k,
              url: 'https://dz.example.com/${k.trackId}',
              hintExtension: 'flac',
              cipher: DeezerBlowfishCipher(trackId: k.trackId),
            ),
          ),
          'apple_music': (
            ProviderCapabilities.appleMusic,
            (k) => ExternalBackendSpec(
              key: k,
              providerId: 'apple_music',
              trackUri: 'apple:${k.trackId}',
            ),
          ),
        };

        final prefixes = <String, List<String>>{
          'youtube_music': ['ytm:'],
          'qobuz': ['qobuz:'],
          'tidal': ['tidal:'],
          'deezer': ['deezer:'],
          'apple_music': ['apple:'],
        };

        for (final entry in specs.entries) {
          final pid = entry.key;
          final caps = entry.value.$1;
          final factory = entry.value.$2;
          reg.register(
            _CustomPluginResolver(
              providerId: pid,
              capabilities: caps,
              handler: (key, {cancelToken}) async {
                if (cancelToken != null) allTokens.add(cancelToken);
                // First 19 requests stall until cancelled; the 20th resolves cleanly.
                if (key.trackId == 'track_19') {
                  return factory(key);
                }
                final comp = Completer<StreamSourceSpec>();
                pendingResolves.add(comp);
                return comp.future;
              },
            ),
            idPrefixes: prefixes[pid]!,
          );
        }
        return reg;
      }

      final manager = StreamingManager(
        credentialStore: MemorySecureCredentialStore(),
      );
      addTearDown(manager.dispose);

      final coordinator = StreamingPlaybackCoordinator(
        audioService: audio,
        streamingManager: manager,
        resolverRegistry: buildRegistry(),
        nativeBackend: nativeBackend,
        externalBackend: externalBackend,
        debounceDelay: Duration.zero,
      );
      addTearDown(coordinator.dispose);

      final trackSequence = <TrackInfo>[
        for (var i = 0; i < 20; i++)
          _makeTrack(
            switch (i % 5) {
              0 => 'ytm:track_$i',
              1 => 'qobuz:track_$i',
              2 => 'tidal:track_$i',
              3 => 'deezer:track_$i',
              _ => 'apple:track_$i',
            },
          ),
      ];

      // 20x rapid skips across all 5 platforms (19th is apple:track_19 -> external!).
      final futures = <Future<void>>[];
      for (var i = 0; i < 20; i++) {
        futures.add(coordinator.playTrack(trackSequence[i], queueContext: trackSequence));
      }
      await Future.wait(futures);

      // All 19 earlier tokens must be cancelled; only the 20th (#19) ran to playback.
      expect(allTokens, hasLength(20));
      for (var i = 0; i < 19; i++) {
        expect(allTokens[i].isCancelled, isTrue, reason: 'Token $i must be cancelled');
      }
      expect(allTokens.last.isCancelled, isFalse);
      expect(coordinator.currentEpoch, equals(20));
      expect(nativeBackend.playCalls, isEmpty);
      expect(bridge.playCalls, hasLength(1));
      expect(bridge.playCalls.single.trackUri, equals('apple:track_19'));
      expect(bridge.playCalls.single.epoch, equals(20));

      // Late completion of all 19 stalled completers must NEVER leak into playback.
      for (var i = 0; i < pendingResolves.length; i++) {
        if (!pendingResolves[i].isCompleted) {
          pendingResolves[i].complete(
            DirectRangeSpec(
              key: StreamKey('qobuz', 'stale_$i', 'default'),
              url: 'https://stale.example.com/$i.flac',
            ),
          );
        }
      }
      await Future<void>.delayed(Duration.zero);
      expect(nativeBackend.playCalls, isEmpty);
      expect(bridge.playCalls, hasLength(1));

      // Repeated seeks increment _epoch and forward to the active External backend.
      await coordinator.seek(const Duration(seconds: 15));
      await coordinator.seek(const Duration(seconds: 45));
      expect(coordinator.currentEpoch, equals(22));
      expect(
        bridge.seekCalls.map((s) => (s.position.inSeconds, s.epoch)).toList(),
        equals([(15, 21), (45, 22)]),
      );

      // Switching External -> Native stops AppleMusicPlaybackBackend cleanly before Native plays!
      await coordinator.playTrack(_makeTrack('ytm:track_19'));
      expect(bridge.stopEpochs, contains(23));
      expect(nativeBackend.playCalls, hasLength(1));
      expect(nativeBackend.playCalls.single.epoch, equals(23));
      expect(nativeBackend.playCalls.single.spec, isA<DirectRangeSpec>());

      // Switching Native -> External stops NativePlaybackBackend cleanly before External plays!
      await coordinator.playTrack(_makeTrack('apple:track_19'));
      expect(nativeBackend.stopEpochs, contains(24));
      expect(bridge.playCalls, hasLength(2));
      expect(bridge.playCalls.last.epoch, equals(24));

      // Repeated seeks on Native increment _epoch without touching External bridge.
      await coordinator.playTrack(_makeTrack('tidal:track_19'));
      await coordinator.seek(const Duration(seconds: 30));
      expect(coordinator.currentEpoch, equals(26));
      expect(nativeBackend.seekCalls.single.epoch, equals(26));
      expect(audio.seeks.single, equals(const Duration(seconds: 30)));

      // Stop increments epoch and leaves zero active Single-Flight tasks
      // (all 19 skipped in-flight tokens are cancelled; completed flights
      // finish cleanly without cancelling their internal task tokens).
      await coordinator.stop();
      expect(coordinator.currentEpoch, equals(27));
      expect(nativeBackend.stopEpochs, contains(27));
      expect(allTokens.take(19).every((t) => t.isCancelled), isTrue);
      expect(coordinator.inFlightResolutionCount, equals(0));
    });
  });

  group('Apple Music Interruption, Shared Mixed Queue & UI Control Routing', () {
    TrackInfo buildTrack(
      String id, {
      required String title,
      String providerName = '',
      String? filePath,
      Duration duration = const Duration(minutes: 3),
    }) {
      return TrackInfo(
        id: id,
        title: title,
        artist: 'Test Artist',
        album: 'Test Album',
        duration: duration,
        format: const AudioFormat(
          codec: AudioCodec.aac,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
        ),
        providerName: providerName,
        filePath: filePath,
      );
    }

    StreamResolverRegistry buildAppleAndQobuzRegistry({
      Future<StreamSourceSpec> Function(StreamKey key, CancellationToken? cancel)?
          appleResolveOverride,
    }) {
      final registry = StreamResolverRegistry();
      registry.register(
        _CustomPluginResolver(
          providerId: 'apple_music',
          capabilities: ProviderCapabilities.appleMusic,
          handler: (key, {cancelToken}) {
            if (appleResolveOverride != null) {
              return appleResolveOverride(key, cancelToken);
            }
            return Future.value(
              ExternalBackendSpec(
                key: key,
                providerId: 'apple_music',
                trackUri: 'apple:${key.trackId}',
                externalWebUrl: 'https://music.apple.com/song/${key.trackId}',
              ),
            );
          },
        ),
        idPrefixes: const <String>['apple:', 'apple_music:'],
        providerNames: const <String>['apple music'],
      );
      registry.register(
        _CustomPluginResolver(
          providerId: 'qobuz',
          capabilities: ProviderCapabilities.qobuz,
          handler: (key, {cancelToken}) async => DirectRangeSpec(
            key: key,
            url: 'https://qobuz.example.com/${key.trackId}.flac',
            hintExtension: 'flac',
            mimeType: 'audio/flac',
          ),
        ),
        idPrefixes: const <String>['qobuz:', 'streaming:qobuz:'],
        providerNames: const <String>['qobuz'],
      );
      return registry;
    }

    test('local track interruption on AudioService stops active and resolving AppleMusicPlaybackBackend without overlap', () async {
      final audio = _SpyNativeAudioService();
      addTearDown(audio.dispose);
      final nativeBackend = _SpyNativeBackend(audio);
      final bridge = _FakeExternalBridge();
      final externalBackend = AppleMusicPlaybackBackend(bridge: bridge);
      addTearDown(externalBackend.dispose);

      final store = MemorySecureCredentialStore();
      final manager = StreamingManager(credentialStore: store);
      addTearDown(manager.dispose);

      final pendingAppleCompleter = Completer<StreamSourceSpec>();
      var resolveCount = 0;
      CancellationToken? inflightToken;
      final registry = buildAppleAndQobuzRegistry(
        appleResolveOverride: (key, cancel) {
          resolveCount++;
          if (resolveCount == 1) {
            return Future.value(
              ExternalBackendSpec(
                key: key,
                providerId: 'apple_music',
                trackUri: 'apple:${key.trackId}',
              ),
            );
          }
          inflightToken = cancel;
          return pendingAppleCompleter.future;
        },
      );

      final coordinator = StreamingPlaybackCoordinator(
        audioService: audio,
        streamingManager: manager,
        resolverRegistry: registry,
        nativeBackend: nativeBackend,
        externalBackend: externalBackend,
        debounceDelay: Duration.zero,
      );
      addTearDown(coordinator.dispose);

      final appleTrack1 = buildTrack(
        'apple:101',
        title: 'Apple Song 1',
        providerName: 'Apple Music',
      );
      final localTrack = buildTrack(
        'local_interrupt_1',
        title: 'Local FLAC Track',
        filePath: '/music/local_interrupt_1.flac',
      );

      await coordinator.playTrack(appleTrack1);
      expect(coordinator.isExternalBackendActive, isTrue);
      expect(coordinator.activeBackend, same(externalBackend));
      expect(bridge.playCalls, hasLength(1));
      expect(audio.specPlays, isEmpty);
      expect(audio.playUrlAsyncCount, equals(0));
      expect(audio.playCount, equals(0));

      final playEpoch = coordinator.currentEpoch;

      // Starting a local track directly on AudioService triggers interrupt handler.
      await audio.play(track: localTrack);
      await Future<void>.delayed(Duration.zero);

      expect(coordinator.currentEpoch, equals(playEpoch + 1));
      expect(bridge.stopEpochs, contains(playEpoch + 1));
      expect(coordinator.isExternalBackendActive, isFalse);
      expect(coordinator.activeBackend, same(nativeBackend));
      expect(coordinator.currentState.track?.id, equals(localTrack.id));
      expect(coordinator.currentState.status, equals(PlaybackStatus.playing));

      // Late callbacks emitted by the external bridge must be ignored cleanly.
      bridge.emitHostState(
        ExternalPlaybackEvent(
          epoch: playEpoch,
          status: 'playing',
          positionMs: 9000,
          durationMs: 180000,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.currentState.track?.id, equals(localTrack.id));

      // Interrupting while a second Apple Music track is still resolving cancels it.
      final appleTrack2 = buildTrack(
        'apple:102',
        title: 'Apple Song 2',
        providerName: 'Apple Music',
      );
      final resolveFuture = coordinator.playTrack(appleTrack2);
      expect(coordinator.isExternalBackendActive, isTrue);

      await audio.play(track: localTrack);
      expect(inflightToken?.isCancelled, isTrue);
      expect(coordinator.isExternalBackendActive, isFalse);
      expect(coordinator.activeBackend, same(nativeBackend));

      // Resolving the stale future afterwards must NOT trigger external play.
      pendingAppleCompleter.complete(
        ExternalBackendSpec(
          key: const StreamKey('apple_music', '102', 'default'),
          providerId: 'apple_music',
          trackUri: 'apple:102',
        ),
      );
      await resolveFuture;
      expect(bridge.playCalls, hasLength(1));
      expect(coordinator.activeBackend, same(nativeBackend));
      expect(coordinator.currentState.track?.id, equals(localTrack.id));
    });

    test('CoordinatingAudioService shares mixed queue and routes controls, state, position, and SignalPath to AppleMusicPlaybackBackend', () async {
      final audio = _SpyNativeAudioService();
      addTearDown(audio.dispose);
      final bridge = _FakeExternalBridge();
      final externalBackend = AppleMusicPlaybackBackend(bridge: bridge);
      addTearDown(externalBackend.dispose);

      final store = MemorySecureCredentialStore();
      final manager = StreamingManager(credentialStore: store);
      addTearDown(manager.dispose);

      final registry = buildAppleAndQobuzRegistry();
      final coordinator = StreamingPlaybackCoordinator(
        audioService: audio,
        streamingManager: manager,
        resolverRegistry: registry,
        externalBackend: externalBackend,
        debounceDelay: Duration.zero,
      );
      addTearDown(coordinator.dispose);

      final coordinatingAudio = CoordinatingAudioService(
        inner: audio,
        coordinator: coordinator,
        disposeInner: false,
      );
      addTearDown(coordinatingAudio.dispose);

      final observedStates = <PlaybackState>[];
      final observedPositions = <Duration>[];
      final observedPaths = <SignalPath>[];
      final stateSub = coordinatingAudio.stateStream.listen(observedStates.add);
      final posSub = coordinatingAudio.positionStream.listen(observedPositions.add);
      final pathSub = coordinatingAudio.signalPathStream.listen(observedPaths.add);
      addTearDown(stateSub.cancel);
      addTearDown(posSub.cancel);
      addTearDown(pathSub.cancel);

      final appleTrack = buildTrack(
        'apple:201',
        title: 'YOASOBI - Idol',
        providerName: 'Apple Music',
      );
      final qobuzTrack = buildTrack(
        'qobuz:301',
        title: 'Qobuz Lossless',
        providerName: 'Qobuz',
      );
      final localTrack = buildTrack(
        'local_mix_401',
        title: 'Local DSD Track',
        filePath: '/music/local_mix_401.flac',
      );
      final mixedQueue = <TrackInfo>[appleTrack, qobuzTrack, localTrack];

      // Start Apple Music track with mixed queue context.
      await coordinator.playTrack(appleTrack, queueContext: mixedQueue);
      await Future<void>.delayed(Duration.zero);

      expect(bridge.playCalls, hasLength(1));
      expect(bridge.playCalls.single.trackUri, equals('apple:201'));
      expect(audio.specPlays, isEmpty);
      expect(audio.playCount, equals(0));
      expect(audio.playUrlCount, equals(0));
      expect(audio.playUrlAsyncCount, equals(0));
      expect(audio.optimisticLoadCount, equals(0));

      expect(coordinatingAudio.queue.map((t) => t.id), equals(['apple:201', 'qobuz:301', 'local_mix_401']));
      expect(coordinatingAudio.currentSignalPath.description, contains('Apple Music'));
      expect(coordinatingAudio.currentSignalPath.nodes.last.detail, contains('ByteStreamSource'));

      // Host emits position tick -> arrives cleanly on positionStream.
      final firstPlayEpoch = coordinator.currentEpoch;
      bridge.emitHostState(
        ExternalPlaybackEvent(
          epoch: firstPlayEpoch,
          status: 'playing',
          positionMs: 12500,
          durationMs: 180000,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(observedPositions, contains(const Duration(milliseconds: 12500)));

      // Controls routed via CoordinatingAudioService reach AppleMusicPlaybackBackend cleanly.
      await coordinatingAudio.togglePlayPause();
      expect(bridge.pauseEpochs, contains(firstPlayEpoch));
      expect(coordinatingAudio.currentState.status, equals(PlaybackStatus.paused));

      await coordinatingAudio.togglePlayPause();
      expect(bridge.resumeEpochs, contains(firstPlayEpoch));
      expect(coordinatingAudio.currentState.status, equals(PlaybackStatus.playing));

      await coordinatingAudio.seek(const Duration(seconds: 42));
      expect(bridge.seekCalls.single.position, equals(const Duration(seconds: 42)));
      expect(coordinatingAudio.currentState.position, equals(const Duration(seconds: 42)));

      await coordinatingAudio.setVolume(0.4);
      expect(bridge.volumes, contains(0.4));
      expect(coordinatingAudio.currentState.volume, closeTo(0.4, 1e-6));

      await coordinatingAudio.toggleMute();
      expect(bridge.volumes.last, equals(0.0));
      expect(coordinatingAudio.currentState.isMuted, isTrue);

      await coordinatingAudio.toggleMute();
      expect(bridge.volumes.last, closeTo(0.4, 1e-6));
      expect(coordinatingAudio.currentState.isMuted, isFalse);

      final playbackSnapshot = await coordinatingAudio.getPlaybackState();
      expect(playbackSnapshot?['clock_source'], equals('external_musickit'));
      expect(playbackSnapshot?['position_ms'], equals(42000));

      // Advance Apple Music -> Qobuz via CoordinatingAudioService.next().
      await coordinatingAudio.next();
      expect(bridge.stopEpochs, isNotEmpty);
      expect(audio.specPlays, hasLength(1));
      expect(audio.specPlays.single.track.id, equals('qobuz:301'));
      expect(coordinator.isExternalBackendActive, isFalse);
      expect(observedPaths.any((p) => p.description.contains('Apple Music')), isTrue);

      // Advance Qobuz -> Local via CoordinatingAudioService.next().
      await coordinatingAudio.next();
      expect(audio.playCount, equals(1));
      expect(audio.currentState.track?.id, equals('local_mix_401'));
      expect(coordinatingAudio.queue.map((t) => t.id), equals(['apple:201', 'qobuz:301', 'local_mix_401']));

      // Advance Local -> wraps cleanly back to Apple Music without touching native play/spec.
      final playCallsBeforeWrap = audio.playCount;
      final specPlaysBeforeWrap = audio.specPlays.length;
      await coordinatingAudio.next();
      expect(bridge.playCalls, hasLength(2));
      expect(bridge.playCalls.last.trackUri, equals('apple:201'));
      expect(audio.playCount, equals(playCallsBeforeWrap));
      expect(audio.specPlays.length, equals(specPlaysBeforeWrap));

      // Previous from Apple Music wraps back to Local cleanly and stops Apple Music.
      final stopsBeforePrev = bridge.stopEpochs.length;
      await coordinatingAudio.previous();
      expect(bridge.stopEpochs.length, greaterThan(stopsBeforePrev));
      expect(audio.playCount, equals(playCallsBeforeWrap + 1));
      expect(audio.currentState.track?.id, equals('local_mix_401'));

      // Stop through CoordinatingAudioService stops Apple Music cleanly when active.
      await coordinatingAudio.play(track: appleTrack);
      final epochAtApple = coordinator.currentEpoch;
      await coordinatingAudio.stop();
      expect(bridge.stopEpochs, contains(epochAtApple + 1));
      expect(coordinatingAudio.currentState.status, equals(PlaybackStatus.stopped));
    });

    testWidgets('FloatingCapsuleMiniPlayer forwards Apple Music pause/resume/next via CoordinatingAudioService', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 240));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final audio = _SpyNativeAudioService();
      addTearDown(audio.dispose);
      final bridge = _FakeExternalBridge();
      final externalBackend = AppleMusicPlaybackBackend(bridge: bridge);
      addTearDown(externalBackend.dispose);

      final store = MemorySecureCredentialStore();
      final manager = StreamingManager(credentialStore: store);
      addTearDown(manager.dispose);

      final coordinator = StreamingPlaybackCoordinator(
        audioService: audio,
        streamingManager: manager,
        resolverRegistry: buildAppleAndQobuzRegistry(),
        externalBackend: externalBackend,
        debounceDelay: Duration.zero,
      );
      addTearDown(coordinator.dispose);

      final coordinatingAudio = CoordinatingAudioService(
        inner: audio,
        coordinator: coordinator,
        disposeInner: false,
      );
      addTearDown(coordinatingAudio.dispose);

      final appleTrack = buildTrack(
        'apple:501',
        title: 'Apple MiniPlayer Track',
        providerName: 'Apple Music',
      );
      final qobuzTrack = buildTrack(
        'qobuz:502',
        title: 'Qobuz MiniPlayer Next',
        providerName: 'Qobuz',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaTokens.buildDarkTheme(),
          home: Scaffold(
            body: Center(
              child: FloatingCapsuleMiniPlayer(
                audioService: coordinatingAudio,
                showLyrics: false,
                onToggleLyrics: () {},
              ),
            ),
          ),
        ),
      );

      await coordinator.playTrack(
        appleTrack,
        queueContext: <TrackInfo>[appleTrack, qobuzTrack],
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Apple MiniPlayer Track'), findsOneWidget);
      expect(audio.specPlays, isEmpty);

      // Tap Play/Pause button -> pauses AppleMusicPlaybackBackend bridge.
      await tester.tap(find.byKey(const Key('btn_play_pause')));
      await tester.pump();
      expect(bridge.pauseEpochs, isNotEmpty);
      expect(coordinatingAudio.currentState.status, equals(PlaybackStatus.paused));

      // Tap Play/Pause again -> resumes AppleMusicPlaybackBackend bridge.
      await tester.tap(find.byKey(const Key('btn_play_pause')));
      await tester.pump();
      expect(bridge.resumeEpochs, isNotEmpty);
      expect(coordinatingAudio.currentState.status, equals(PlaybackStatus.playing));

      // Tap Next button -> stops AppleMusicPlaybackBackend and dispatches Qobuz natively.
      await tester.tap(find.byKey(const Key('btn_next')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(bridge.stopEpochs, isNotEmpty);
      expect(audio.specPlays, hasLength(1));
      expect(audio.specPlays.single.track.id, equals('qobuz:502'));
    });
  });
}
