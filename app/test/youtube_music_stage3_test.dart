import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/models/streaming_provider_meta.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/streaming/providers/apple_music_provider.dart';
import 'package:lumina_app/services/streaming/providers/deezer_provider.dart';
import 'package:lumina_app/services/streaming/providers/qobuz_provider.dart';
import 'package:lumina_app/services/streaming/providers/tidal_provider.dart';
import 'package:lumina_app/services/streaming/providers/youtube_music_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';
import 'package:lumina_app/services/streaming/streaming_provider.dart';
import 'package:lumina_app/services/streaming/yt_dlp_service.dart';
import 'package:lumina_app/services/unified_search_controller.dart';
import 'package:lumina_app/ui/streaming/streaming_service_view.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

typedef _RouteHandler =
    FutureOr<void> Function(HttpRequest req, String body);

Future<HttpServer> _startServer(_RouteHandler handler) async {
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

Map<String, dynamic> _accountMenuOk({String? visitorData}) => <String, dynamic>{
  if (visitorData != null)
    'responseContext': <String, dynamic>{'visitorData': visitorData},
  'actions': <dynamic>[
    <String, dynamic>{
      'openPopupAction': <String, dynamic>{
        'popup': <String, dynamic>{
          'multiPageMenuRenderer': <String, dynamic>{
            'header': <String, dynamic>{
              'activeAccountHeaderRenderer': <String, dynamic>{
                'accountName': <String, dynamic>{'simpleText': 'Stage3 Listener'},
                'email': <String, dynamic>{'simpleText': 'stage3@example.com'},
              },
            },
          },
        },
      },
    },
  ],
};

TrackInfo _ytmTrack(
  String id, {
  String? filePath,
  Duration duration = const Duration(minutes: 3, seconds: 30),
}) {
  return TrackInfo(
    id: id,
    title: 'Track $id',
    artist: 'YTM Artist',
    album: 'YTM Album',
    duration: duration,
    filePath: filePath,
    format: const AudioFormat(
      codec: AudioCodec.aac,
      sampleRateHz: 44100,
      bitDepth: 16,
      channels: 2,
    ),
    providerName: 'YouTube Music',
  );
}

class _RecordedResolveCall {
  final String videoId;
  final int playRequestId;
  final String? cookiesFilePath;
  final String? cookiesFileContentsSnapshot;
  final bool bypassCache;

  const _RecordedResolveCall({
    required this.videoId,
    required this.playRequestId,
    required this.cookiesFilePath,
    required this.cookiesFileContentsSnapshot,
    required this.bypassCache,
  });
}

class _RecordedProxyCall {
  final String sourceUrl;
  final Map<String, String> headers;
  final int playRequestId;

  const _RecordedProxyCall({
    required this.sourceUrl,
    required this.headers,
    required this.playRequestId,
  });
}

class _FakeYtDlpService extends YtDlpService {
  final List<_RecordedResolveCall> resolveCalls = <_RecordedResolveCall>[];
  final List<_RecordedProxyCall> proxyCalls = <_RecordedProxyCall>[];
  final List<int?> cancelExceptRequestIds = <int?>[];
  final List<String> preloadVideoIds = <String>[];
  final Map<String, YtDlpResolvedStream> fakeCache =
      <String, YtDlpResolvedStream>{};
  int stopFfmpegProxyCalls = 0;
  int stopAllCalls = 0;

  Future<YtDlpResolvedStream> Function(
    String videoId, {
    required int playRequestId,
    String? cookiesFilePath,
    bool bypassCache,
  })? onResolveVideo;

  Future<String> Function({
    required String sourceUrl,
    Map<String, String> headers,
    required int playRequestId,
  })? onOpenProxy;

  _FakeYtDlpService({super.clock});

  @override
  YtDlpResolvedStream? getCachedStream(String videoId) => fakeCache[videoId];

  @override
  Future<YtDlpResolvedStream> resolveVideo(
    String videoId, {
    required int playRequestId,
    String? cookiesFilePath,
    bool bypassCache = false,
    String? formatSelector,
    String? extractorArgs,
    String? remoteComponents,
  }) async {
    String? cookieSnapshot;
    if (cookiesFilePath != null) {
      final f = File(cookiesFilePath);
      if (f.existsSync()) {
        cookieSnapshot = await f.readAsString();
      }
    }
    resolveCalls.add(
      _RecordedResolveCall(
        videoId: videoId,
        playRequestId: playRequestId,
        cookiesFilePath: cookiesFilePath,
        cookiesFileContentsSnapshot: cookieSnapshot,
        bypassCache: bypassCache,
      ),
    );
    if (onResolveVideo != null) {
      return onResolveVideo!(
        videoId,
        playRequestId: playRequestId,
        cookiesFilePath: cookiesFilePath,
        bypassCache: bypassCache,
      );
    }
    return YtDlpResolvedStream(
      videoId: videoId,
      url: 'https://rr1.googlevideo.com/videoplayback?id=$videoId&itag=140',
      httpHeaders: const <String, String>{'User-Agent': 'yt-dlp-test'},
      acodec: 'mp4a.40.2',
      ext: 'm4a',
      sampleRateHz: 44100,
      bitrateKbps: 129.0,
      durationSeconds: 212.0,
      expiresAt: DateTime.now().add(const Duration(minutes: 45)),
    );
  }

  @override
  Future<String> openTranscodedWavUrl({
    required String sourceUrl,
    Map<String, String> headers = const {},
    required int playRequestId,
  }) async {
    proxyCalls.add(
      _RecordedProxyCall(
        sourceUrl: sourceUrl,
        headers: Map<String, String>.from(headers),
        playRequestId: playRequestId,
      ),
    );
    if (onOpenProxy != null) {
      return onOpenProxy!(
        sourceUrl: sourceUrl,
        headers: headers,
        playRequestId: playRequestId,
      );
    }
    return 'http://127.0.0.1:45678/stream/token_$playRequestId.wav';
  }

  @override
  void cancelPlaybackProcesses({int? exceptRequestId}) {
    cancelExceptRequestIds.add(exceptRequestId);
  }

  @override
  void stopFfmpegProxy({int? exceptRequestId}) {
    stopFfmpegProxyCalls++;
  }

  @override
  Future<YtDlpResolvedStream?> preloadVideo(
    String videoId, {
    String? cookiesFilePath,
  }) async {
    preloadVideoIds.add(videoId);
    final stream = YtDlpResolvedStream(
      videoId: videoId,
      url: 'https://rr1.googlevideo.com/videoplayback?id=$videoId&itag=140',
      httpHeaders: const <String, String>{},
      acodec: 'mp4a.40.2',
      ext: 'm4a',
      sampleRateHz: 44100,
      expiresAt: DateTime.now().add(const Duration(minutes: 45)),
    );
    fakeCache[videoId] = stream;
    return stream;
  }

  @override
  Future<void> stopAll({
    Duration waitTimeout = const Duration(seconds: 2),
  }) async {
    stopAllCalls++;
  }
}

class _FakeStdProcess implements Process {
  final Stream<List<int>> _stdout;
  final Future<int> _exitCode;

  _FakeStdProcess.stdout(String text)
      : _stdout = Stream<List<int>>.value(utf8.encode(text)),
        _exitCode = Future<int>.value(0);

  @override
  int get pid => 9999;

  @override
  Future<int> get exitCode => _exitCode;

  @override
  Stream<List<int>> get stdout => _stdout;

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Stage 3.1: Strict videoId sanitization', () {
    test('strips internal prefixes, extracts URL params, and accepts 11-char IDs', () {
      expect(
        YouTubeMusicProvider.extractCleanVideoId('dQw4w9WgXcQ'),
        'dQw4w9WgXcQ',
      );
      expect(
        YouTubeMusicProvider.extractCleanVideoId('ytm:dQw4w9WgXcQ'),
        'dQw4w9WgXcQ',
      );
      expect(
        YouTubeMusicProvider.extractCleanVideoId('ytm_dQw4w9WgXcQ'),
        'dQw4w9WgXcQ',
      );
      expect(
        YouTubeMusicProvider.extractCleanVideoId(
          'streaming:youtube_music:DYptgVvkVLQ',
        ),
        'DYptgVvkVLQ',
      );
      expect(
        YouTubeMusicProvider.extractCleanVideoId(
          'youtube_music:YhiQDARUJ7Y',
        ),
        'YhiQDARUJ7Y',
      );
      expect(
        YouTubeMusicProvider.extractCleanVideoId(
          'streaming:youtube_music:ytm:dQw4w9WgXcQ',
        ),
        'dQw4w9WgXcQ',
      );
      expect(
        YouTubeMusicProvider.extractCleanVideoId(
          'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=RDdQw4w9WgXcQ',
        ),
        'dQw4w9WgXcQ',
      );
      expect(
        YouTubeMusicProvider.extractCleanVideoId(
          'https://music.youtube.com/watch?v=DYptgVvkVLQ',
        ),
        'DYptgVvkVLQ',
      );
      expect(
        YouTubeMusicProvider.extractCleanVideoId(
          'https://youtu.be/YhiQDARUJ7Y?si=abc123',
        ),
        'YhiQDARUJ7Y',
      );
      expect(
        YouTubeMusicProvider.extractCleanVideoId(
          'ytm:',
          filePath: 'https://music.youtube.com/watch?v=dQw4w9WgXcQ',
        ),
        'dQw4w9WgXcQ',
      );
    });

    test('rejects browseId, playlistId, and malformed IDs with StreamingException', () {
      const invalidIds = <String>[
        '',
        'ytm:',
        'short_id',
        'way_too_long_video_id_1234',
        'bad!char@12',
        'MPREb_12345',
        'MPREb_abc123456789',
        'ytm:MPREb_abc123456789',
        'VLPL1234567890',
        'VL_FAVS',
        'FEmusic_home',
        'UC1234567890123456789012',
        'PL1234567890123456',
        'RDAMVMdQw4w9WgXcQ',
        'OLAK5uy_k1234567890',
        'https://music.youtube.com/playlist?list=PL1234567890123456',
      ];
      for (final bad in invalidIds) {
        expect(
          () => YouTubeMusicProvider.extractCleanVideoId(bad),
          throwsA(isA<StreamingException>()),
          reason: 'Expected StreamingException for invalid id: "$bad"',
        );
      }
    });
  });

  group('Stage 3.2: Header isolation & HTTP 400 root-cause guard', () {
    test('WEB_REMIX aligns headers, SAPISIDHASH (SAPISID & __Secure-3PAPISID), and visitorData', () async {
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      final capturedPlayerRequests =
          <({Map<String, String> headers, Map<String, dynamic> body})>[];

      final server = await _startServer((req, body) async {
        if (req.uri.path == '/youtubei/v1/account/account_menu') {
          return _sendJson(req.response, HttpStatus.ok, _accountMenuOk());
        }
        if (req.uri.path == '/sw.js_data') {
          req.response.statusCode = HttpStatus.ok;
          req.response.write(")]}'\n[[\"x\",[\"y\",[\"CgtWaXNpdG9yMTIzNDU2\"]]]]");
          await req.response.close();
          return;
        }
        if (req.uri.path == '/youtubei/v1/player') {
          final headers = <String, String>{};
          req.headers.forEach((name, values) {
            headers[name.toLowerCase()] = values.join(', ');
          });
          final decoded = jsonDecode(body) as Map<String, dynamic>;
          capturedPlayerRequests.add((headers: headers, body: decoded));
          return _sendJson(req.response, HttpStatus.ok, {
            'playabilityStatus': {'status': 'OK'},
            'streamingData': {
              'adaptiveFormats': [
                {
                  'itag': 140,
                  'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
                  'bitrate': 129000,
                  'audioSampleRate': '44100',
                  'audioChannels': 2,
                  'url': 'https://rr1.example.com/audio_140.m4a',
                },
              ],
            },
          });
        }
        return _sendJson(req.response, HttpStatus.notFound, {});
      });
      addTearDown(() => server.close(force: true));

      DateTime fixedClock() => DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final fakeYtDlp = _FakeYtDlpService(clock: fixedClock)
        ..onResolveVideo = (
          videoId, {
          required int playRequestId,
          String? cookiesFilePath,
          bool bypassCache = false,
        }) async =>
            throw const YtDlpException('yt-dlp unavailable in InnerTube fallback test');
      addTearDown(fakeYtDlp.dispose);

      // Case 1: SAPISID cookie + lazy visitorData from /sw.js_data
      final p1 = YouTubeMusicProvider(
        credentialStore: MemorySecureCredentialStore(),
        baseUrl: 'http://127.0.0.1:${server.port}',
        clock: fixedClock,
        ytDlpService: fakeYtDlp,
      );
      await p1.authenticate({
        'mode': 'cookie',
        'cookie': 'SAPISID=sapi_one; SID=sid_one',
      });
      final stream1 = await p1.resolveStream(_ytmTrack('ytm:dQw4w9WgXcQ'));
      expect(stream1.url, 'https://rr1.example.com/audio_140.m4a');

      final req1 = capturedPlayerRequests.last;
      final expectedHash1 = sha1
          .convert(utf8.encode('1700000000 sapi_one https://music.youtube.com'))
          .toString();
      expect(req1.headers['x-youtube-client-name'], '67');
      expect(req1.headers['x-youtube-client-version'], '1.20241120.01.00');
      expect(req1.headers['x-goog-authuser'], '0');
      expect(req1.headers['origin'], 'https://music.youtube.com');
      expect(req1.headers['x-origin'], 'https://music.youtube.com');
      expect(req1.headers['referer'], 'https://music.youtube.com/');
      expect(req1.headers['authorization'], 'SAPISIDHASH 1700000000_$expectedHash1');
      expect(req1.headers['x-goog-visitor-id'], 'CgtWaXNpdG9yMTIzNDU2');
      expect(
        (req1.body['context'] as Map)['client']['clientName'],
        'WEB_REMIX',
      );
      expect(
        (req1.body['context'] as Map)['client']['visitorData'],
        'CgtWaXNpdG9yMTIzNDU2',
      );

      // Case 2: __Secure-3PAPISID cookie
      final p2 = YouTubeMusicProvider(
        credentialStore: MemorySecureCredentialStore(),
        baseUrl: 'http://127.0.0.1:${server.port}',
        clock: fixedClock,
        ytDlpService: fakeYtDlp,
      );
      await p2.authenticate({
        'mode': 'cookie',
        'cookie': '__Secure-3PAPISID=sapi_three; SID=sid_two',
      });
      await p2.resolveStream(_ytmTrack('ytm:DYptgVvkVLQ'));
      final req2 = capturedPlayerRequests.last;
      final expectedHash2 = sha1
          .convert(utf8.encode('1700000000 sapi_three https://music.youtube.com'))
          .toString();
      expect(req2.headers['authorization'], 'SAPISIDHASH 1700000000_$expectedHash2');
    });

    test('clean fallback client (ANDROID_VR only) excludes deprecated TVHTML5 and IOS completely and NEVER leaks web cookies, auth, client 67, or origin', () async {
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      final fallbackRequests =
          <({String clientName, Map<String, String> headers})>[];

      final server = await _startServer((req, body) async {
        if (req.uri.path == '/youtubei/v1/account/account_menu') {
          return _sendJson(
            req.response,
            HttpStatus.ok,
            _accountMenuOk(visitorData: 'CgtBY2NvdW50VmlzaXRvcg=='),
          );
        }
        if (req.uri.path == '/youtubei/v1/player') {
          final headers = <String, String>{};
          req.headers.forEach((name, values) {
            headers[name.toLowerCase()] = values.join(', ');
          });
          final decoded = jsonDecode(body) as Map<String, dynamic>;
          final clientName =
              ((decoded['context'] as Map)['client'] as Map)['clientName']
                  .toString();

          if (clientName == 'WEB_REMIX') {
            return _sendJson(req.response, HttpStatus.badRequest, {
              'error': {
                'code': 400,
                'message': 'Request contains an invalid argument.',
              },
            });
          }

          fallbackRequests.add((clientName: clientName, headers: headers));

          if (clientName == 'ANDROID_VR') {
            return _sendJson(req.response, HttpStatus.ok, {
              'playabilityStatus': {'status': 'OK'},
              'streamingData': {
                'adaptiveFormats': [
                  {
                    'itag': 140,
                    'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
                    'bitrate': 128000,
                    'audioSampleRate': '44100',
                    'url': 'https://rr2.example.com/vr_140.m4a',
                  },
                ],
              },
            });
          }

          return _sendJson(req.response, HttpStatus.ok, {
            'playabilityStatus': {'status': 'LOGIN_REQUIRED'},
          });
        }
        return _sendJson(req.response, HttpStatus.notFound, {});
      });
      addTearDown(() => server.close(force: true));

      final fakeYtDlp = _FakeYtDlpService()
        ..onResolveVideo = (
          videoId, {
          required int playRequestId,
          String? cookiesFilePath,
          bool bypassCache = false,
        }) async =>
            throw const YtDlpException('yt-dlp unavailable in InnerTube fallback test');
      addTearDown(fakeYtDlp.dispose);

      final provider = YouTubeMusicProvider(
        credentialStore: MemorySecureCredentialStore(),
        baseUrl: 'http://127.0.0.1:${server.port}',
        ytDlpService: fakeYtDlp,
      );
      await provider.authenticate({
        'mode': 'cookie',
        'cookie': 'SAPISID=super_secret_cookie; SID=secret_sid',
      });

      final resolved = await provider.resolveStream(_ytmTrack('ytm:dQw4w9WgXcQ'));
      expect(resolved.url, 'https://rr2.example.com/vr_140.m4a');
      expect(
        fallbackRequests.map((r) => r.clientName).toList(),
        <String>['ANDROID_VR'],
      );
      expect(fallbackRequests.any((r) => r.clientName == 'IOS'), isFalse);
      expect(
        fallbackRequests.any((r) => r.clientName.startsWith('TVHTML5')),
        isFalse,
      );

      final expectedClientHeaders = <String, String>{
        'ANDROID_VR': '28',
      };

      for (final req in fallbackRequests) {
        expect(req.headers['cookie'], isNull, reason: '${req.clientName} leaked Cookie');
        expect(
          req.headers['authorization'],
          isNull,
          reason: '${req.clientName} leaked Authorization',
        );
        expect(
          req.headers['origin'],
          isNull,
          reason: '${req.clientName} leaked Origin',
        );
        expect(
          req.headers['x-origin'],
          isNull,
          reason: '${req.clientName} leaked X-Origin',
        );
        expect(
          req.headers['referer'],
          isNull,
          reason: '${req.clientName} leaked Referer',
        );
        expect(
          req.headers['x-goog-authuser'],
          isNull,
          reason: '${req.clientName} leaked X-Goog-AuthUser',
        );
        expect(
          req.headers['x-youtube-client-name'],
          expectedClientHeaders[req.clientName],
        );
        expect(req.headers['x-youtube-client-name'], isNot('67'));
      }
    });
  });

  group('Stage 3.3: Symphonia-native M4A/AAC priority & FFmpeg WAV wrapping', () {
    test('prefers itag 141 > itag 140 > other m4a > flac > opus, and wraps Opus-only via FFmpeg proxy', () async {
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      var currentFormats = <Map<String, dynamic>>[];

      final server = await _startServer((req, body) async {
        if (req.uri.path == '/youtubei/v1/account/account_menu') {
          return _sendJson(
            req.response,
            HttpStatus.ok,
            _accountMenuOk(visitorData: 'CgtWaXNpdG9yT0s='),
          );
        }
        if (req.uri.path == '/youtubei/v1/player') {
          return _sendJson(req.response, HttpStatus.ok, {
            'playabilityStatus': {'status': 'OK'},
            'streamingData': {'adaptiveFormats': currentFormats},
          });
        }
        return _sendJson(req.response, HttpStatus.notFound, {});
      });
      addTearDown(() => server.close(force: true));

      final fakeYtDlp = _FakeYtDlpService()
        ..onResolveVideo = (
          videoId, {
          required int playRequestId,
          String? cookiesFilePath,
          bool bypassCache = false,
        }) async =>
            throw const YtDlpException('yt-dlp unavailable in InnerTube tier test');
      addTearDown(fakeYtDlp.dispose);

      final provider = YouTubeMusicProvider(
        credentialStore: MemorySecureCredentialStore(),
        baseUrl: 'http://127.0.0.1:${server.port}',
        ytDlpService: fakeYtDlp,
      );
      await provider.authenticate({
        'mode': 'cookie',
        'cookie': 'SAPISID=abc; SID=def',
      });

      // 1. itag 141 wins over itag 140 and higher-bitrate Opus 251
      currentFormats = <Map<String, dynamic>>[
        {
          'itag': 251,
          'mimeType': 'audio/webm; codecs="opus"',
          'bitrate': 320000,
          'audioSampleRate': '48000',
          'url': 'https://rr.example.com/251.webm',
        },
        {
          'itag': 140,
          'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
          'bitrate': 128000,
          'audioSampleRate': '44100',
          'url': 'https://rr.example.com/140.m4a',
        },
        {
          'itag': 141,
          'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
          'bitrate': 256000,
          'audioSampleRate': '44100',
          'url': 'https://rr.example.com/141.m4a',
        },
      ];
      final res141 = await provider.resolveStream(_ytmTrack('ytm:dQw4w9WgXcQ'));
      expect(res141.url, 'https://rr.example.com/141.m4a');
      expect(res141.hintExtension, 'm4a');
      expect(res141.format.codec, AudioCodec.aac);
      expect(fakeYtDlp.proxyCalls, isEmpty);

      // 2. itag 140 wins over higher-bitrate Opus 251
      currentFormats = <Map<String, dynamic>>[
        {
          'itag': 251,
          'mimeType': 'audio/webm; codecs="opus"',
          'bitrate': 165000,
          'audioSampleRate': '48000',
          'url': 'https://rr.example.com/251.webm',
        },
        {
          'itag': 140,
          'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
          'bitrate': 128000,
          'audioSampleRate': '44100',
          'url': 'https://rr.example.com/140.m4a',
        },
      ];
      final res140 = await provider.resolveStream(_ytmTrack('ytm:dQw4w9WgXcQ'));
      expect(res140.url, 'https://rr.example.com/140.m4a');
      expect(res140.hintExtension, 'm4a');
      expect(res140.format.codec, AudioCodec.aac);
      expect(fakeYtDlp.proxyCalls, isEmpty);

      // 3. Opus-only -> transparently wrapped through FFmpeg WAV proxy with real Opus metadata preserved!
      currentFormats = <Map<String, dynamic>>[
        {
          'itag': 249,
          'mimeType': 'audio/webm; codecs="opus"',
          'bitrate': 50000,
          'audioSampleRate': '48000',
          'url': 'https://rr.example.com/249.webm',
        },
        {
          'itag': 251,
          'mimeType': 'audio/webm; codecs="opus"',
          'bitrate': 160000,
          'audioSampleRate': '48000',
          'url': 'https://rr.example.com/251.webm',
        },
      ];
      final resOpus = await provider.resolveStream(
        _ytmTrack('ytm:dQw4w9WgXcQ'),
        playRequestId: 77,
      );
      expect(resOpus.url, startsWith('http://127.0.0.1:'));
      expect(resOpus.hintExtension, 'wav');
      expect(resOpus.headers, isEmpty);
      expect(resOpus.format.codec, AudioCodec.opus);
      expect(resOpus.format.sampleRateHz, 48000);
      expect(fakeYtDlp.proxyCalls.length, 1);
      expect(fakeYtDlp.proxyCalls.single.sourceUrl, 'https://rr.example.com/251.webm');
      expect(fakeYtDlp.proxyCalls.single.playRequestId, 77);
    });
  });

  group('Stage 3.4: YtDlpService primary resolution, temp Netscape cookies, cache clear & route tracking', () {
    test('authenticated mode prioritizes YtDlpService FIRST (0 /player hits), deletes temp cookies in finally, falls back cleanly, and redacts secrets', () async {
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      var playerHits = 0;
      final server = await _startServer((req, body) async {
        if (req.uri.path == '/youtubei/v1/account/account_menu') {
          return _sendJson(
            req.response,
            HttpStatus.ok,
            _accountMenuOk(visitorData: 'CgtWaXNpdG9yRmFsbA=='),
          );
        }
        if (req.uri.path == '/youtubei/v1/player') {
          playerHits++;
          return _sendJson(req.response, HttpStatus.badRequest, {
            'error': {'code': 400, 'message': 'Request contains an invalid argument.'},
          });
        }
        return _sendJson(req.response, HttpStatus.notFound, {});
      });
      addTearDown(() => server.close(force: true));

      final fakeYtDlp = _FakeYtDlpService();
      addTearDown(fakeYtDlp.dispose);

      // Primary authenticated cookie call succeeds immediately without hitting InnerTube /player.
      fakeYtDlp.onResolveVideo = (
        videoId, {
        required int playRequestId,
        String? cookiesFilePath,
        bool bypassCache = false,
      }) async {
        return YtDlpResolvedStream(
          videoId: videoId,
          url: 'https://rr3.googlevideo.com/videoplayback?id=$videoId&itag=140',
          httpHeaders: const <String, String>{
            'User-Agent': 'yt-dlp-ua',
            'Accept': '*/*',
            'Accept-Language': 'en-US,en;q=0.9',
            'Referer': 'https://music.youtube.com/',
          },
          acodec: 'mp4a.40.2',
          ext: 'm4a',
          sampleRateHz: 44100,
          bitrateKbps: 128.0,
          expiresAt: DateTime.now().add(const Duration(minutes: 45)),
        );
      };

      final provider = YouTubeMusicProvider(
        credentialStore: MemorySecureCredentialStore(),
        baseUrl: 'http://127.0.0.1:${server.port}',
        ytDlpService: fakeYtDlp,
      );
      await provider.authenticate({
        'mode': 'cookie',
        'cookie': 'SAPISID=top_secret_sapi_999; SID=top_secret_sid_888',
      });

      final stream = await provider.resolveStream(
        _ytmTrack('ytm:dQw4w9WgXcQ'),
        playRequestId: 42,
      );
      expect(playerHits, 0);
      expect(stream.url, contains('itag=140'));
      expect(stream.format.codec, AudioCodec.aac);
      expect(stream.format.sampleRateHz, 44100);
      expect(stream.videoId, 'dQw4w9WgXcQ');
      expect(stream.engineRoute, 'bundled yt-dlp (direct M4A)');
      expect(stream.headers['User-Agent'], 'yt-dlp-ua');
      expect(stream.headers['Accept'], '*/*');
      expect(stream.headers['Accept-Language'], 'en-US,en;q=0.9');
      expect(stream.headers['Referer'], 'https://music.youtube.com/');

      expect(fakeYtDlp.resolveCalls.length, 1);
      final cookieCall = fakeYtDlp.resolveCalls.single;
      expect(cookieCall.cookiesFilePath, isNotNull);
      expect(
        cookieCall.cookiesFileContentsSnapshot,
        contains('.youtube.com\tTRUE\t/\tTRUE\t'),
      );
      expect(
        cookieCall.cookiesFileContentsSnapshot,
        contains('music.youtube.com\tFALSE\t/\tTRUE\t'),
      );
      expect(
        cookieCall.cookiesFileContentsSnapshot,
        contains('SAPISID\ttop_secret_sapi_999'),
      );
      // CRITICAL: Temp cookie file MUST be deleted immediately in finally!
      expect(File(cookieCall.cookiesFilePath!).existsSync(), isFalse);

      // If cookie-assisted yt-dlp fails, clean yt-dlp fallback still resolves without hitting /player.
      fakeYtDlp.resolveCalls.clear();
      fakeYtDlp.onResolveVideo = (
        videoId, {
        required int playRequestId,
        String? cookiesFilePath,
        bool bypassCache = false,
      }) async {
        if (cookiesFilePath != null) {
          throw const YtDlpException('stale cookie error', exitCode: 1);
        }
        return YtDlpResolvedStream(
          videoId: videoId,
          url: 'https://rr4.googlevideo.com/videoplayback?id=$videoId&itag=251',
          httpHeaders: const <String, String>{'User-Agent': 'yt-dlp-clean'},
          acodec: 'opus',
          ext: 'webm',
          sampleRateHz: 48000,
          expiresAt: DateTime.now().add(const Duration(minutes: 45)),
        );
      };

      final fallbackOpus = await provider.resolveStream(
        _ytmTrack('ytm:DYptgVvkVLQ'),
        playRequestId: 43,
      );
      expect(playerHits, 0);
      expect(fakeYtDlp.resolveCalls.length, 2);
      expect(fakeYtDlp.resolveCalls[0].cookiesFilePath, isNotNull);
      expect(fakeYtDlp.resolveCalls[1].cookiesFilePath, isNull);
      expect(fakeYtDlp.resolveCalls[1].bypassCache, isTrue);
      expect(
        File(fakeYtDlp.resolveCalls[0].cookiesFilePath!).existsSync(),
        isFalse,
      );
      expect(fallbackOpus.hintExtension, 'wav');
      expect(fallbackOpus.engineRoute, 'bundled yt-dlp + ffmpeg fallback');

      // Even when ALL layers fail, temp cookie file MUST still be deleted
      // and exception message MUST NOT leak secrets.
      fakeYtDlp.resolveCalls.clear();
      fakeYtDlp.onResolveVideo = (
        videoId, {
        required int playRequestId,
        String? cookiesFilePath,
        bool bypassCache = false,
      }) async {
        throw const YtDlpException(
          'yt-dlp failed with top_secret_sapi_999',
          exitCode: 1,
        );
      };

      try {
        await provider.resolveStream(_ytmTrack('ytm:dQw4w9WgXcQ'));
        fail('Expected StreamingException when all layers fail');
      } on StreamingException catch (e) {
        expect(e.message, isNot(contains('top_secret_sapi_999')));
        expect(e.message, isNot(contains('top_secret_sid_888')));
      }
      expect(fakeYtDlp.resolveCalls.length, 2);
      expect(
        File(fakeYtDlp.resolveCalls[0].cookiesFilePath!).existsSync(),
        isFalse,
      );
    });

    test('clearStreamCache and bypassCache force fresh yt-dlp re-resolve and invalidate provider/service cache', () async {
      final fakeYtDlp = _FakeYtDlpService();
      addTearDown(fakeYtDlp.dispose);

      var resolveCounter = 0;
      fakeYtDlp.onResolveVideo = (
        videoId, {
        required int playRequestId,
        String? cookiesFilePath,
        bool bypassCache = false,
      }) async {
        if (!bypassCache && fakeYtDlp.fakeCache.containsKey(videoId)) {
          return fakeYtDlp.fakeCache[videoId]!;
        }
        resolveCounter++;
        final stream = YtDlpResolvedStream(
          videoId: videoId,
          url: 'https://rr$resolveCounter.googlevideo.com/videoplayback?id=$videoId&n=$resolveCounter',
          httpHeaders: <String, String>{'User-Agent': 'yt-dlp-$resolveCounter'},
          acodec: 'mp4a.40.2',
          ext: 'm4a',
          sampleRateHz: 44100,
          expiresAt: DateTime.now().add(const Duration(minutes: 45)),
        );
        fakeYtDlp.fakeCache[videoId] = stream;
        return stream;
      };

      final store = MemorySecureCredentialStore();
      final ytm = YouTubeMusicProvider(
        credentialStore: store,
        ytDlpService: fakeYtDlp,
      );
      final manager = StreamingManager(
        credentialStore: store,
        ytDlpService: fakeYtDlp,
        providers: <String, StreamingProvider>{'youtube_music': ytm},
      );
      addTearDown(manager.dispose);

      final track = _ytmTrack('ytm:dQw4w9WgXcQ');
      final first = await manager.resolveStreamForTrack(track, playRequestId: 1);
      expect(first.url, contains('&n=1'));
      expect(first.engineRoute, 'bundled yt-dlp (direct M4A)');

      // Cached hit without bypassCache
      final cached = await manager.resolveStreamForTrack(track, playRequestId: 2);
      expect(cached.url, equals(first.url));
      expect(resolveCounter, equals(1));

      // bypassCache forces fresh re-resolve
      final fresh = await manager.resolveStreamForTrack(
        track,
        playRequestId: 3,
        bypassCache: true,
      );
      expect(fresh.url, contains('&n=2'));
      expect(fresh.headers['User-Agent'], 'yt-dlp-2');
      expect(resolveCounter, equals(2));

      // Verify real YtDlpService cache clear integration via YouTubeMusicProvider.clearStreamCache
      final tempRoot = await Directory.systemTemp.createTemp('lumina_ytm_clr_');
      addTearDown(() async {
        if (tempRoot.existsSync()) await tempRoot.delete(recursive: true);
      });
      final binDir = await Directory('${tempRoot.path}\\bin').create();
      File('${binDir.path}\\yt-dlp.exe').writeAsStringSync('bin');
      var realCalls = 0;
      final realYtDlp = YtDlpService(
        userBinDir: '${tempRoot.path}\\user',
        bundledBinDir: binDir.path,
        pathEnv: '',
        processStarter: (
          exe,
          args, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          mode = ProcessStartMode.normal,
        }) async {
          if (args.contains('--version')) {
            return _FakeStdProcess.stdout('2026.10.26\n');
          }
          realCalls++;
          return _FakeStdProcess.stdout(
            jsonEncode({
              'url': 'https://rr$realCalls.googlevideo.com/videoplayback?itag=140',
              'http_headers': {'User-Agent': 'UA-$realCalls'},
              'acodec': 'mp4a.40.2',
              'ext': 'm4a',
              'asr': 44100,
            }),
          );
        },
      );
      addTearDown(realYtDlp.dispose);
      final realYtm = YouTubeMusicProvider(
        credentialStore: store,
        ytDlpService: realYtDlp,
      );
      final realManager = StreamingManager(
        credentialStore: store,
        ytDlpService: realYtDlp,
        providers: <String, StreamingProvider>{'youtube_music': realYtm},
      );
      addTearDown(realManager.dispose);

      final r1 = await realManager.resolveStreamForTrack(track, playRequestId: 10);
      expect(r1.url, contains('rr1.googlevideo.com'));
      expect(realYtDlp.getCachedStream('dQw4w9WgXcQ'), isNotNull);

      realYtm.clearStreamCache('ytm:dQw4w9WgXcQ');
      expect(realYtDlp.getCachedStream('dQw4w9WgXcQ'), isNull);

      final r2 = await realManager.resolveStreamForTrack(
        track,
        playRequestId: 11,
      );
      expect(r2.url, contains('rr2.googlevideo.com'));
      expect(r2.headers['User-Agent'], 'UA-2');
      expect(realCalls, equals(2));

      realManager.clearStreamCache(track);
      expect(realYtDlp.getCachedStream('dQw4w9WgXcQ'), isNull);

      final r3 = await realManager.resolveStreamForTrack(
        track,
        playRequestId: 12,
        bypassCache: true,
      );
      expect(r3.url, contains('rr3.googlevideo.com'));
      expect(r3.headers['User-Agent'], 'UA-3');
      expect(realCalls, equals(3));

      // Verify CancellationToken cancels active available_at wait cleanly via cancelRequest(playRequestId)
      final cancelToken = CancellationToken();
      final futureAvailSec =
          (DateTime.now().toUtc().millisecondsSinceEpoch / 1000.0) + 10.0;
      final waitYtDlp = YtDlpService(
        userBinDir: '${tempRoot.path}\\user2',
        bundledBinDir: binDir.path,
        pathEnv: '',
        processStarter: (
          exe,
          args, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          mode = ProcessStartMode.normal,
        }) async {
          if (args.contains('--version')) {
            return _FakeStdProcess.stdout('2026.10.26\n');
          }
          return _FakeStdProcess.stdout(
            jsonEncode({
              'url': 'https://rr9.googlevideo.com/videoplayback?itag=140',
              'available_at': futureAvailSec,
              'acodec': 'mp4a.40.2',
              'ext': 'm4a',
              'asr': 44100,
            }),
          );
        },
      );
      addTearDown(waitYtDlp.dispose);
      final waitYtm = YouTubeMusicProvider(
        credentialStore: store,
        ytDlpService: waitYtDlp,
      );
      Timer(const Duration(milliseconds: 40), cancelToken.cancel);
      await expectLater(
        waitYtm.resolveStream(track, playRequestId: 99, cancel: cancelToken),
        throwsA(
          isA<StreamingException>().having((e) => e.isCancelled, 'isCancelled', true),
        ),
      );
    });
  });

  group('Stage 3.5: Guest Mode (YouTube Music unlocked, other 4 providers stay strict)', () {
    test('unauthenticated YouTubeMusicProvider browses/searches/plays via YtDlpService, syncLibrary still requires auth', () async {
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      var playerHits = 0;
      final seenAuthHeaders = <String?>[];

      final server = await _startServer((req, body) async {
        seenAuthHeaders.add(req.headers.value('authorization'));
        if (req.uri.path == '/youtubei/v1/player') {
          playerHits++;
          return _sendJson(req.response, HttpStatus.badRequest, {});
        }
        if (req.uri.path == '/youtubei/v1/search') {
          return _sendJson(req.response, HttpStatus.ok, {
            'responseContext': {'visitorData': 'CgtHdWVzdFZpc2l0b3I='},
            'contents': {
              'musicShelfRenderer': {
                'contents': [
                  {
                    'musicResponsiveListItemRenderer': {
                      'playlistItemData': {'videoId': 'dQw4w9WgXcQ'},
                      'flexColumns': [
                        {
                          'musicResponsiveListItemFlexColumnRenderer': {
                            'text': {'simpleText': 'Guest Search Song'},
                          },
                        },
                        {
                          'musicResponsiveListItemFlexColumnRenderer': {
                            'text': {'simpleText': 'Guest Artist'},
                          },
                        },
                      ],
                    },
                  },
                ],
              },
            },
          });
        }
        if (req.uri.path == '/youtubei/v1/browse') {
          final reqJson = jsonDecode(body) as Map<String, dynamic>;
          final browseId = reqJson['browseId']?.toString();
          if (browseId == 'FEmusic_home') {
            return _sendJson(req.response, HttpStatus.ok, {
              'contents': {
                'gridRenderer': {
                  'items': [
                    {
                      'musicTwoRowItemRenderer': {
                        'title': {'simpleText': 'Public Chart Album'},
                        'subtitle': {'simpleText': 'Chart Artist • 2026'},
                        'navigationEndpoint': {
                          'browseEndpoint': {
                            'browseId': 'MPREb_public01',
                            'browseEndpointContextSupportedConfigs': {
                              'browseEndpointContextMusicConfig': {
                                'pageType': 'MUSIC_PAGE_TYPE_ALBUM',
                              },
                            },
                          },
                        },
                      },
                    },
                  ],
                },
              },
            });
          }
          if (browseId == 'MPREb_public01') {
            return _sendJson(req.response, HttpStatus.ok, {
              'header': {
                'musicResponsiveHeaderRenderer': {
                  'title': {'simpleText': 'Public Chart Album'},
                  'straplineTextOne': {'simpleText': 'Chart Artist'},
                  'subtitle': {'simpleText': 'Album • 2026'},
                },
              },
              'contents': {
                'musicShelfRenderer': {
                  'contents': [
                    {
                      'musicResponsiveListItemRenderer': {
                        'playlistItemData': {'videoId': 'DYptgVvkVLQ'},
                        'flexColumns': [
                          {
                            'musicResponsiveListItemFlexColumnRenderer': {
                              'text': {'simpleText': 'Album Opener'},
                            },
                          },
                          {
                            'musicResponsiveListItemFlexColumnRenderer': {
                              'text': {'simpleText': 'Chart Artist'},
                            },
                          },
                        ],
                      },
                    },
                  ],
                },
              },
            });
          }
        }
        return _sendJson(req.response, HttpStatus.notFound, {});
      });
      addTearDown(() => server.close(force: true));

      final fakeYtDlp = _FakeYtDlpService();
      addTearDown(fakeYtDlp.dispose);

      final store = MemorySecureCredentialStore();
      final ytm = YouTubeMusicProvider(
        credentialStore: store,
        baseUrl: 'http://127.0.0.1:${server.port}',
        ytDlpService: fakeYtDlp,
      );
      final tidal = TidalProvider(credentialStore: store);
      final qobuz = QobuzProvider(credentialStore: store);
      final deezer = DeezerProvider(credentialStore: store);
      final apple = AppleMusicProvider(credentialStore: store);

      expect(ytm.supportsGuestMode, isTrue);
      expect(tidal.supportsGuestMode, isFalse);
      expect(qobuz.supportsGuestMode, isFalse);
      expect(deezer.supportsGuestMode, isFalse);
      expect(apple.supportsGuestMode, isFalse);

      final manager = StreamingManager(
        credentialStore: store,
        ytDlpService: fakeYtDlp,
        providers: <String, StreamingProvider>{
          'youtube_music': ytm,
          'tidal': tidal,
          'qobuz': qobuz,
          'deezer': deezer,
          'apple_music': apple,
        },
      );
      addTearDown(manager.dispose);

      expect(manager.connectedProviders, isEmpty);
      expect(
        manager.browsableProviders.map((p) => p.kind).toList(),
        <String>['youtube_music'],
      );

      // Guest search, recommendations, album detail work without logging in!
      final searchCatalog = await manager.searchProvider('youtube_music', 'test');
      expect(searchCatalog.tracks.single.id, 'ytm:dQw4w9WgXcQ');

      final recs = await manager.refreshRecommendationsFor('youtube_music');
      expect(recs.albums.single.id, 'MPREb_public01');

      final detail = await manager.fetchAlbumDetail(
        'youtube_music',
        'MPREb_public01',
      );
      expect(detail?.title, 'Public Chart Album');
      expect(detail?.versions.single.tracks.single.id, 'ytm:DYptgVvkVLQ');

      // All guest browse/search calls had ZERO Authorization header.
      expect(seenAuthHeaders.every((h) => h == null), isTrue);

      // Guest playback routes DIRECTLY to YtDlpService (0 /player calls)
      final guestStream = await manager.resolveStreamForTrack(
        _ytmTrack('ytm:dQw4w9WgXcQ'),
        playRequestId: 9,
      );
      expect(playerHits, 0);
      expect(fakeYtDlp.resolveCalls.length, 1);
      expect(fakeYtDlp.resolveCalls.single.videoId, 'dQw4w9WgXcQ');
      expect(fakeYtDlp.resolveCalls.single.playRequestId, 9);
      expect(guestStream.format.codec, AudioCodec.aac);
      expect(guestStream.format.sampleRateHz, 44100);
      expect(guestStream.hintExtension, 'm4a');

      // Guest playback with Opus-only from yt-dlp wraps via FFmpeg WAV proxy while preserving Opus 48 kHz metadata
      fakeYtDlp.onResolveVideo = (
        videoId, {
        required int playRequestId,
        String? cookiesFilePath,
        bool bypassCache = false,
      }) async =>
          YtDlpResolvedStream(
            videoId: videoId,
            url: 'https://rr1.googlevideo.com/opus.webm',
            httpHeaders: const <String, String>{'User-Agent': 'yt-dlp'},
            acodec: 'opus',
            ext: 'webm',
            sampleRateHz: 48000,
            expiresAt: DateTime.now().add(const Duration(minutes: 45)),
          );
      final opusStream = await manager.resolveStreamForTrack(
        _ytmTrack('ytm:DYptgVvkVLQ'),
        playRequestId: 10,
      );
      expect(opusStream.url, startsWith('http://127.0.0.1:'));
      expect(opusStream.hintExtension, 'wav');
      expect(opusStream.headers, isEmpty);
      expect(opusStream.format.codec, AudioCodec.opus);
      expect(opusStream.format.sampleRateHz, 48000);

      // Personal syncLibrary STILL requires authentication!
      await expectLater(
        ytm.syncLibrary(),
        throwsA(isA<StreamingException>()),
      );

      // Other 4 providers STILL strictly reject unauthenticated playback!
      for (final lockedTrack in <TrackInfo>[
        _ytmTrack('tidal:123').copyWith(providerName: 'Tidal'),
        _ytmTrack('qobuz:123').copyWith(providerName: 'Qobuz'),
        _ytmTrack('deezer:123').copyWith(providerName: 'Deezer'),
        _ytmTrack('apple:123').copyWith(providerName: 'Apple Music'),
      ]) {
        await expectLater(
          manager.resolveStreamForTrack(lockedTrack),
          throwsA(isA<StreamingException>()),
          reason: '${lockedTrack.providerName} must remain auth-gated',
        );
      }

      // UnifiedSearchController dispatches guest search to YouTube Music automatically!
      final audio = MockAudioService();
      final cache = LibraryIndexCache();
      addTearDown(audio.dispose);
      addTearDown(cache.dispose);
      final searchCtrl = UnifiedSearchController(
        audioService: audio,
        libraryCache: cache,
        streamingManager: manager,
      );
      addTearDown(searchCtrl.dispose);

      searchCtrl.updateQuery('Guest', immediate: true);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(searchCtrl.streamingBuckets.containsKey('youtube_music'), isTrue);
      expect(
        searchCtrl.streamingBuckets['youtube_music']!.tracks.single.title,
        'Guest Search Song',
      );
    });

    testWidgets('StreamingServiceView defaults to 探索推薦 in guest mode and shows non-blocking login prompt on 收藏曲目 / 同步', (tester) async {
      final prevOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = prevOverrides);

      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final server = (await tester.runAsync(
        () => _startServer((req, body) async {
          if (req.uri.path == '/youtubei/v1/browse') {
            return _sendJson(req.response, HttpStatus.ok, {
              'contents': {
                'gridRenderer': {
                  'items': [
                    {
                      'musicTwoRowItemRenderer': {
                        'title': {'simpleText': 'Guest Explore Album'},
                        'subtitle': {'simpleText': 'Guest Band • 2026'},
                        'navigationEndpoint': {
                          'browseEndpoint': {
                            'browseId': 'MPREb_guest_ui',
                            'browseEndpointContextSupportedConfigs': {
                              'browseEndpointContextMusicConfig': {
                                'pageType': 'MUSIC_PAGE_TYPE_ALBUM',
                              },
                            },
                          },
                        },
                      },
                    },
                  ],
                },
              },
            });
          }
          return _sendJson(req.response, HttpStatus.notFound, {});
        }),
      ))!;
      addTearDown(() => server.close(force: true));

      final store = MemorySecureCredentialStore();
      final fakeYtDlp = _FakeYtDlpService();
      addTearDown(fakeYtDlp.dispose);
      final manager = StreamingManager(
        credentialStore: store,
        ytDlpService: fakeYtDlp,
        providers: <String, StreamingProvider>{
          'youtube_music': YouTubeMusicProvider(
            credentialStore: store,
            baseUrl: 'http://127.0.0.1:${server.port}',
            ytDlpService: fakeYtDlp,
          ),
        },
      );
      addTearDown(manager.dispose);

      final audio = MockAudioService();
      addTearDown(audio.dispose);
      var openedSettings = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaTokens.buildDarkTheme(),
          home: Scaffold(
            body: StreamingServiceView(
              audioService: audio,
              provider: StreamingProviderMeta.byKind('youtube_music')!,
              streamingManager: manager,
              onOpenProviderSettings: () => openedSettings++,
            ),
          ),
        ),
      );

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (find
          .byKey(const Key('streaming_rec_album_MPREb_guest_ui'))
          .evaluate()
          .isEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Timed out waiting for guest recommendations to render');
        }
        await tester.pump(const Duration(milliseconds: 25));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 25));
      }
      await tester.pump(const Duration(milliseconds: 100));

      // Defaults to 探索推薦 tab (0) and auto-fetches public recommendations!
      expect(
        find.byKey(const Key('streaming_rec_album_MPREb_guest_ui')),
        findsOneWidget,
      );

      // Clicking 同步 in guest mode shows non-blocking SnackBar instead of red error banner
      await tester.tap(find.byKey(const Key('btn_sync_streaming_provider')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const Key('streaming_guest_sync_snackbar')), findsOneWidget);
      expect(find.byKey(const Key('streaming_error_banner')), findsNothing);

      // Switching to 收藏曲目 shows subtle non-blocking login prompt banner
      await tester.tap(find.byKey(const Key('streaming_tab_tracks')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byKey(const Key('streaming_guest_login_banner')), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('streaming_guest_login_banner')),
          matching: find.text('前往登入'),
        ),
      );
      await tester.pump();
      expect(openedSettings, 1);
    });
  });

  group('Stage 3.6: StreamingPlaybackCoordinator process lifecycle, TTL & preload', () {
    test('rapid 5-track switching kills stale playRequestId immediately, pause/stop kills ffmpeg, localhost URL never cached, preload triggers, TTL defaults to 45m', () async {
      final now = DateTime.utc(2026, 11, 22, 12, 0, 0);
      final fakeYtDlp = _FakeYtDlpService(clock: () => now);
      addTearDown(fakeYtDlp.dispose);

      // Verify 45m fallback TTL and 0 TTL for localhost FFmpeg proxy URL.
      expect(
        StreamingPlaybackCoordinator.computeCacheTtl(
          _ytmTrack('ytm:dQw4w9WgXcQ'),
          'https://rr1.googlevideo.com/videoplayback?id=noexp',
          now,
        ),
        const Duration(minutes: 45),
      );
      expect(
        StreamingPlaybackCoordinator.computeCacheTtl(
          _ytmTrack('ytm:dQw4w9WgXcQ'),
          'http://127.0.0.1:54321/stream/abc.wav',
          now,
        ),
        Duration.zero,
      );

      final store = MemorySecureCredentialStore();
      final ytm = YouTubeMusicProvider(
        credentialStore: store,
        ytDlpService: fakeYtDlp,
      );
      final manager = StreamingManager(
        credentialStore: store,
        ytDlpService: fakeYtDlp,
        providers: <String, StreamingProvider>{'youtube_music': ytm},
      );
      addTearDown(manager.dispose);

      final audio = MockAudioService();
      addTearDown(audio.dispose);

      final coordinator = StreamingPlaybackCoordinator(
        audioService: audio,
        streamingManager: manager,
        ytDlpService: fakeYtDlp,
        debounceDelay: const Duration(milliseconds: 50),
        clock: () => now,
      );

      final tracks = <TrackInfo>[
        _ytmTrack('ytm:dQw4w9WgXcQ'),
        _ytmTrack('ytm:DYptgVvkVLQ'),
        _ytmTrack('ytm:YhiQDARUJ7Y'),
        _ytmTrack('ytm:9bZkp7q19f0'),
        _ytmTrack('ytm:kJQP7kiw5Fk'),
      ];

      // Rapid 5-track switch with debounce: every switch immediately kills older requestId!
      unawaited(coordinator.playTrack(tracks[0], queueContext: tracks, debounce: true));
      unawaited(coordinator.playTrack(tracks[1], queueContext: tracks, debounce: true));
      unawaited(coordinator.playTrack(tracks[2], queueContext: tracks, debounce: true));
      unawaited(coordinator.playTrack(tracks[3], queueContext: tracks, debounce: true));
      await coordinator.playTrack(tracks[4], queueContext: tracks, debounce: true);

      // Every single switch called cancelPlaybackProcesses(exceptRequestId: reqId) immediately.
      expect(
        fakeYtDlp.cancelExceptRequestIds,
        containsAllInOrder(<int>[1, 2, 3, 4, 5]),
      );
      // Only the 5th track actually spawned yt-dlp resolveVideo!
      expect(fakeYtDlp.resolveCalls.length, 1);
      expect(fakeYtDlp.resolveCalls.single.videoId, 'kJQP7kiw5Fk');
      expect(fakeYtDlp.resolveCalls.single.playRequestId, 5);
      expect(audio.currentState.status, PlaybackStatus.playing);

      // Stable playback at position >= 8s triggers isolated preloadVideo for next track (tracks[0]) once!
      await audio.seek(const Duration(seconds: 9));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await audio.seek(const Duration(seconds: 12));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(fakeYtDlp.preloadVideoIds, <String>['dQw4w9WgXcQ']);

      // Playing an Opus stream returns localhost WAV proxy URL and does NOT store in coordinator _cache!
      fakeYtDlp.onResolveVideo = (
        videoId, {
        required int playRequestId,
        String? cookiesFilePath,
        bool bypassCache = false,
      }) async =>
          YtDlpResolvedStream(
            videoId: videoId,
            url: 'https://rr1.googlevideo.com/opus.webm',
            httpHeaders: const <String, String>{},
            acodec: 'opus',
            ext: 'webm',
            sampleRateHz: 48000,
            expiresAt: now.add(const Duration(minutes: 45)),
          );
      await coordinator.playTrack(tracks[1], queueContext: tracks);
      expect(coordinator.getCachedStream(tracks[1].id), isNull);

      // Pause and Stop immediately invoke stopFfmpegProxy() so no ffmpeg.exe lingers!
      final stopsBefore = fakeYtDlp.stopFfmpegProxyCalls;
      await audio.pause();
      await Future<void>.delayed(Duration.zero);
      expect(fakeYtDlp.stopFfmpegProxyCalls, greaterThan(stopsBefore));

      final stopsAfterPause = fakeYtDlp.stopFfmpegProxyCalls;
      await audio.stop();
      await Future<void>.delayed(Duration.zero);
      expect(fakeYtDlp.stopFfmpegProxyCalls, greaterThan(stopsAfterPause));

      // dispose() stops all child processes!
      coordinator.dispose();
      expect(fakeYtDlp.stopAllCalls, 1);
    });
  });
}
