import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/models/streaming_provider_meta.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/streaming/providers/tidal_provider.dart';
import 'package:lumina_app/services/streaming/providers/youtube_music_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';
import 'package:lumina_app/services/streaming/streaming_provider.dart';
import 'package:lumina_app/services/streaming/yt_dlp_service.dart';
import 'package:lumina_app/ui/artwork/album_artwork_view.dart';
import 'package:lumina_app/ui/streaming/streaming_service_view.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

// Valid 1x1 transparent PNG bytes for testing Image.network without external DNS.
final List<int> _valid1x1Png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

String? _locateVendoredFfmpeg() {
  final sep = Platform.pathSeparator;
  final cwd = Directory.current.path;
  final candidates = <String>[
    '$cwd${sep}windows${sep}vendor${sep}bin${sep}ffmpeg.exe',
    '$cwd${sep}app${sep}windows${sep}vendor${sep}bin${sep}ffmpeg.exe',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

/// Parses FLAC magic header (`fLaC`) and STREAMINFO block (type 0, 34 bytes).
({int sampleRate, int channels, int bitsPerSample}) _parseFlacStreamInfo(
  Uint8List bytes,
) {
  if (bytes.length < 42) {
    throw StateError('FLAC stream too short (${bytes.length} bytes)');
  }
  final magic = ascii.decode(bytes.sublist(0, 4));
  if (magic != 'fLaC') {
    throw StateError('Invalid FLAC magic header: $magic');
  }
  final blockType = bytes[4] & 0x7F;
  final blockLen = (bytes[5] << 16) | (bytes[6] << 8) | bytes[7];
  if (blockType != 0 || blockLen != 34) {
    throw StateError(
      'Expected STREAMINFO block (type=0, len=34), got type=$blockType len=$blockLen',
    );
  }
  // STREAMINFO bytes 10..13 (offset 8+10 = 18..21 in file):
  // 20 bits sampleRate, 3 bits (channels - 1), 5 bits (bitsPerSample - 1).
  final b0 = bytes[18];
  final b1 = bytes[19];
  final b2 = bytes[20];
  final b3 = bytes[21];
  final sampleRate = (b0 << 12) | (b1 << 4) | ((b2 >> 4) & 0x0F);
  final channels = ((b2 >> 1) & 0x07) + 1;
  final bitsPerSample = (((b2 & 0x01) << 4) | ((b3 >> 4) & 0x0F)) + 1;
  return (
    sampleRate: sampleRate,
    channels: channels,
    bitsPerSample: bitsPerSample,
  );
}

List<File> _findTidalTempMpdFiles({int? playRequestId}) {
  final prefix = playRequestId != null
      ? 'lumina_tidal_${playRequestId}_'
      : 'lumina_tidal_';
  return Directory.systemTemp
      .listSync(followLinks: false)
      .whereType<File>()
      .where((f) {
        final name = f.uri.pathSegments.last;
        return name.startsWith(prefix) && name.endsWith('.mpd');
      })
      .toList(growable: false);
}

Future<HttpServer> _startJsonTestServer(
  FutureOr<void> Function(HttpRequest req, String body) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    try {
      final body = await utf8.decoder.bind(req).join();
      await handler(req, body);
    } catch (e) {
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.write('Server handler error: $e');
        await req.response.close();
      } catch (_) {}
    }
  });
  return server;
}

Future<void> _sendJson(HttpResponse resp, int status, Object body) async {
  resp.statusCode = status;
  resp.headers.contentType = ContentType.json;
  resp.write(jsonEncode(body));
  await resp.close();
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not satisfied within $timeout');
    }
    await tester.pump(const Duration(milliseconds: 25));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 25));
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
}

class _FakeProcess implements Process {
  @override
  final int pid = 8001;

  final StreamController<List<int>> _stdoutCtrl =
      StreamController<List<int>>();
  final StreamController<List<int>> _stderrCtrl =
      StreamController<List<int>>();
  final Completer<int> _exitCompleter = Completer<int>();
  bool killed = false;

  _FakeProcess({String stdoutText = ''}) {
    scheduleMicrotask(() {
      if (stdoutText.isNotEmpty && !_stdoutCtrl.isClosed) {
        _stdoutCtrl.add(utf8.encode(stdoutText));
      }
      if (!_stdoutCtrl.isClosed) unawaited(_stdoutCtrl.close());
      if (!_stderrCtrl.isClosed) unawaited(_stderrCtrl.close());
      if (!_exitCompleter.isCompleted) _exitCompleter.complete(0);
    });
  }

  @override
  Future<int> get exitCode => _exitCompleter.future;

  @override
  Stream<List<int>> get stdout => _stdoutCtrl.stream;

  @override
  Stream<List<int>> get stderr => _stderrCtrl.stream;

  @override
  IOSink get stdin => throw UnimplementedError('stdin not used');

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_stdoutCtrl.isClosed) unawaited(_stdoutCtrl.close());
    if (!_stderrCtrl.isClosed) unawaited(_stderrCtrl.close());
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(-1);
    return true;
  }
}

class _SpyAudioService extends MockAudioService {
  final List<({TrackInfo track, String streamUrl, int requestId})>
      recordedPlays = [];
  final StreamController<PlaybackState> _extraStateController =
      StreamController<PlaybackState>.broadcast();
  StreamSubscription<PlaybackState>? _forwardSub;
  bool _forwardingInit = false;

  @override
  Stream<PlaybackState> get stateStream {
    if (!_forwardingInit) {
      _forwardingInit = true;
      _forwardSub = super.stateStream.listen((s) {
        if (!_extraStateController.isClosed) {
          _extraStateController.add(s);
        }
      });
    }
    return _extraStateController.stream;
  }

  void emitRawStateForTest(PlaybackState state) {
    if (!_extraStateController.isClosed) {
      _extraStateController.add(state);
    }
  }

  @override
  Future<void> playStreamUrlAsync({
    required TrackInfo track,
    required String streamUrl,
    Map<String, String> headers = const {},
    String? hintExtension,
    required int requestId,
  }) async {
    recordedPlays.add((
      track: track,
      streamUrl: streamUrl,
      requestId: requestId,
    ));
    await super.playStreamUrlAsync(
      track: track,
      streamUrl: streamUrl,
      headers: headers,
      hintExtension: hintExtension,
      requestId: requestId,
    );
  }

  @override
  void dispose() {
    unawaited(_forwardSub?.cancel());
    unawaited(_extraStateController.close());
    super.dispose();
  }
}

class _NonGuestYouTubeMusicProvider extends YouTubeMusicProvider {
  _NonGuestYouTubeMusicProvider({
    required super.credentialStore,
    required super.baseUrl,
  });

  @override
  bool get supportsGuestMode => false;
}

class _TidalInterceptingHttpClient implements HttpClient {
  final HttpClient _inner;
  final int imageServerPort;
  final List<String> requestedImageUrls;

  _TidalInterceptingHttpClient(
    this._inner, {
    required this.imageServerPort,
    required this.requestedImageUrls,
  });

  Uri _rewriteUri(Uri url) {
    if (url.host.toLowerCase().contains('resources.tidal.com')) {
      requestedImageUrls.add(url.toString());
      return Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: imageServerPort,
        path: url.path,
        query: url.hasQuery ? url.query : null,
      );
    }
    return url;
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _inner.getUrl(_rewriteUri(url));

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      _inner.openUrl(method, _rewriteUri(url));

  @override
  Future<HttpClientRequest> headUrl(Uri url) =>
      _inner.headUrl(_rewriteUri(url));

  @override
  Future<HttpClientRequest> postUrl(Uri url) =>
      _inner.postUrl(_rewriteUri(url));

  @override
  Future<HttpClientRequest> putUrl(Uri url) => _inner.putUrl(_rewriteUri(url));

  @override
  Future<HttpClientRequest> deleteUrl(Uri url) =>
      _inner.deleteUrl(_rewriteUri(url));

  @override
  Future<HttpClientRequest> patchUrl(Uri url) =>
      _inner.patchUrl(_rewriteUri(url));

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) => _inner.open(method, host, port, path);

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      _inner.get(host, port, path);

  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      _inner.head(host, port, path);

  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      _inner.post(host, port, path);

  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      _inner.put(host, port, path);

  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      _inner.delete(host, port, path);

  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      _inner.patch(host, port, path);

  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) => _inner.addCredentials(url, realm, credentials);

  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) => _inner.addProxyCredentials(host, port, realm, credentials);

  @override
  set authenticate(
    Future<bool> Function(Uri url, String scheme, String? realm)? f,
  ) => _inner.authenticate = f;

  @override
  set authenticateProxy(
    Future<bool> Function(String host, int port, String scheme, String? realm)?
        f,
  ) => _inner.authenticateProxy = f;

  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? callback,
  ) => _inner.badCertificateCallback = callback;

  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )? f,
  ) => _inner.connectionFactory = f;

  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;

  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;

  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) =>
      _inner.maxConnectionsPerHost = value;

  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

Future<YtDlpService> _createFakeReadyYtDlpService(
  Directory tempDir, {
  FfmpegAudioProxy? proxy,
}) async {
  final binDir = Directory('${tempDir.path}${Platform.pathSeparator}bin')
    ..createSync(recursive: true);
  final fakeFfmpeg = File('${binDir.path}${Platform.pathSeparator}ffmpeg.exe')
    ..writeAsStringSync('stub-ffmpeg');
  final service = YtDlpService(
    userBinDir: '${tempDir.path}${Platform.pathSeparator}user_bin',
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
      if (exe == fakeFfmpeg.path && args.contains('-version')) {
        return _FakeProcess(
          stdoutText: 'ffmpeg version N-129219-g359c825152 Copyright\n',
        );
      }
      return _FakeProcess();
    },
    ffmpegProxy: proxy,
  );
  await service.initialize();
  return service;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Stage 1: Real bundled ffmpeg.exe fMP4-FLAC DASH proxy e2e', () {
    test('buildDashMpdFfmpegArgs builds exact DASH remux & PCM args without HTTP-only flags or -ar', () {
      final copyArgs = FfmpegAudioProxy.buildDashMpdFfmpegArgs(
        mpdFilePath: r'C:\temp\lumina_tidal_1_abcd1234.mpd',
        copyFlac: true,
      );
      expect(copyArgs, equals(<String>[
        '-hide_banner',
        '-loglevel',
        'error',
        '-nostdin',
        '-protocol_whitelist',
        'file,http,https,tcp,tls,crypto,data',
        '-allowed_extensions',
        'ALL',
        '-f',
        'dash',
        '-i',
        r'C:\temp\lumina_tidal_1_abcd1234.mpd',
        '-vn',
        '-sn',
        '-dn',
        '-c:a',
        'copy',
        '-f',
        'flac',
        'pipe:1',
      ]));
      expect(copyArgs.contains('-reconnect'), isFalse);
      expect(copyArgs.contains('-headers'), isFalse);
      expect(copyArgs.contains('-ar'), isFalse);

      final wavArgs = FfmpegAudioProxy.buildDashMpdFfmpegArgs(
        mpdFilePath: r'C:\temp\lumina_tidal_2_efgh5678.mpd',
        copyFlac: false,
      );
      expect(wavArgs.contains('-c:a'), isTrue);
      expect(wavArgs.contains('pcm_s24le'), isTrue);
      expect(wavArgs.contains('wav'), isTrue);
      expect(wavArgs.contains('-ar'), isFalse);
    });

    test(
      'real ffmpeg.exe: HEAD spawns 0 processes, GET streams valid 24-bit/96kHz FLAC from HTTP fMP4-FLAC DASH segments, and rapid switches leave 0 zombie processes or .mpd files',
      () async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
        });

        final ffmpegPath = _locateVendoredFfmpeg();
        if (ffmpegPath == null) {
          markTestSkipped('app/windows/vendor/bin/ffmpeg.exe not present');
          return;
        }

        final tempDir = await Directory.systemTemp.createTemp(
          'lumina_dash_e2e_',
        );
        addTearDown(() async {
          if (tempDir.existsSync()) {
            await tempDir.delete(recursive: true);
          }
        });

        // 1. Synthesize a real 24-bit / 96kHz stereo fMP4-FLAC DASH stream.
        final genResult = await Process.run(
          ffmpegPath,
          <String>[
            '-y',
            '-hide_banner',
            '-loglevel',
            'error',
            '-f',
            'lavfi',
            '-i',
            'sine=frequency=440:sample_rate=96000:duration=2',
            '-ac',
            '2',
            '-sample_fmt',
            's32',
            '-bits_per_raw_sample',
            '24',
            '-c:a',
            'flac',
            '-strict',
            '-2',
            '-f',
            'dash',
            '-init_seg_name',
            'init.mp4',
            '-media_seg_name',
            r'chunk_$Number%05d$.m4s',
            'manifest.mpd',
          ],
          workingDirectory: tempDir.path,
          runInShell: false,
        );
        expect(
          genResult.exitCode,
          equals(0),
          reason: 'ffmpeg synthesis failed: ${genResult.stderr}',
        );

        final initFile = File(
          '${tempDir.path}${Platform.pathSeparator}init.mp4',
        );
        final chunkFile = File(
          '${tempDir.path}${Platform.pathSeparator}chunk_00001.m4s',
        );
        final generatedMpd = File(
          '${tempDir.path}${Platform.pathSeparator}manifest.mpd',
        );
        expect(initFile.existsSync(), isTrue);
        expect(chunkFile.existsSync(), isTrue);
        expect(generatedMpd.existsSync(), isTrue);

        final initBytes = await initFile.readAsBytes();
        final chunkBytes = await chunkFile.readAsBytes();
        expect(initBytes.length, greaterThan(100));
        expect(chunkBytes.length, greaterThan(100));

        // 2. Serve init.mp4 and chunk_00001.m4s over local HTTP.
        var initHits = 0;
        var chunkHits = 0;
        final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => upstream.close(force: true));
        upstream.listen((req) async {
          if (req.uri.path == '/init.mp4') {
            initHits++;
            req.response.headers.contentType = ContentType('audio', 'mp4');
            req.response.add(initBytes);
          } else if (req.uri.path == '/chunk_00001.m4s') {
            chunkHits++;
            req.response.headers.contentType = ContentType('audio', 'mp4');
            req.response.add(chunkBytes);
          } else {
            req.response.statusCode = HttpStatus.notFound;
          }
          await req.response.close();
        });

        // Rewrite segment paths in the synthesized MPD to point at our HTTP server.
        final rawMpd = await generatedMpd.readAsString();
        final httpMpd = rawMpd
            .replaceAll(
              'initialization="init.mp4"',
              'initialization="http://127.0.0.1:${upstream.port}/init.mp4"',
            )
            .replaceAll(
              r'media="chunk_$Number%05d$.m4s"',
              'media="http://127.0.0.1:${upstream.port}/chunk_\$Number%05d\$.m4s"',
            );

        final proxy = FfmpegAudioProxy(ffmpegPathProvider: () => ffmpegPath);
        addTearDown(() async {
          await proxy.dispose();
        });

        // 3. Open DASH MPD proxy URL & assert lazy spawn + temp file tracking.
        final flacUrl = await proxy.openDashMpdUrl(
          mpdXml: httpMpd,
          playRequestId: 101,
          copyFlac: true,
        );
        expect(flacUrl, startsWith('http://127.0.0.1:'));
        expect(flacUrl, endsWith('.flac'));
        expect(proxy.trackedTempFileCount, equals(1));
        expect(_findTidalTempMpdFiles(playRequestId: 101).length, equals(1));

        final client = HttpClient();
        addTearDown(() => client.close(force: true));

        // 4. HEAD -> 200 OK, Content-Type: audio/flac, Accept-Ranges: none, spawnCount == 0.
        final headReq = await client.headUrl(Uri.parse(flacUrl));
        final headResp = await headReq.close();
        await headResp.drain<void>();
        expect(headResp.statusCode, equals(HttpStatus.ok));
        expect(
          headResp.headers.value(HttpHeaders.contentTypeHeader),
          equals('audio/flac'),
        );
        expect(headResp.headers.value('accept-ranges'), equals('none'));
        expect(proxy.spawnCount, equals(0));

        // 5. GET (with Rust probe Range: bytes=0-0) -> 200 OK, valid fLaC 24-bit/96kHz stream!
        final getReq = await client.getUrl(Uri.parse(flacUrl));
        getReq.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
        final getResp = await getReq.close();
        final bodyBuilder = BytesBuilder(copy: false);
        await for (final chunk in getResp) {
          bodyBuilder.add(chunk);
        }
        final flacBytes = bodyBuilder.toBytes();
        expect(
          getResp.statusCode,
          equals(HttpStatus.ok),
          reason:
              'Expected 200 OK from DASH proxy, got ${getResp.statusCode}: ${utf8.decode(flacBytes, allowMalformed: true)}',
        );
        expect(
          getResp.headers.value(HttpHeaders.contentTypeHeader),
          equals('audio/flac'),
        );
        expect(getResp.headers.value('accept-ranges'), equals('none'));
        expect(proxy.spawnCount, equals(1));
        expect(initHits, greaterThanOrEqualTo(1));
        expect(chunkHits, greaterThanOrEqualTo(1));

        final streamInfo = _parseFlacStreamInfo(flacBytes);
        expect(streamInfo.sampleRate, equals(96000));
        expect(streamInfo.channels, equals(2));
        expect(streamInfo.bitsPerSample, equals(24));

        // Allow onProcessExit cleanup microtasks to settle, then verify zero leftover temp files/processes.
        await proxy.stopAll();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(proxy.activeProcessCount, equals(0));
        expect(proxy.trackedTempFileCount, equals(0));
        expect(_findTidalTempMpdFiles(playRequestId: 101), isEmpty);

        // 6. Simulate 5 rapid track switches (openDashMpdUrl / GET / cancel) and assert clean cleanup.
        for (var i = 0; i < 5; i++) {
          final reqId = 201 + i;
          final switchUrl = await proxy.openDashMpdUrl(
            mpdXml: httpMpd,
            playRequestId: reqId,
            copyFlac: true,
          );
          if (i.isEven) {
            final req = await client.getUrl(Uri.parse(switchUrl));
            unawaited(
              req.close().then((resp) => resp.drain<void>()).catchError((_) {}),
            );
            await Future<void>.delayed(const Duration(milliseconds: 25));
          }
          proxy.cancel();
        }
        await proxy.stopAll();
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(proxy.activeProcessCount, equals(0));
        expect(proxy.trackedTempFileCount, equals(0));
        for (var i = 0; i < 5; i++) {
          expect(_findTidalTempMpdFiles(playRequestId: 201 + i), isEmpty);
        }
      },
    );
  });

  group('Stage 1: Tidal resolveStream fallback matrix & Coordinator recovery', () {
    test(
      'unencrypted HI_RES_LOSSLESS application/dash+xml (96kHz/24-bit & 192kHz/24-bit) proxies via loopback .flac URL',
      () async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
        });

        final tempDir = await Directory.systemTemp.createTemp('lumina_tidal_res_');
        addTearDown(() async {
          if (tempDir.existsSync()) await tempDir.delete(recursive: true);
        });
        final ytDlp = await _createFakeReadyYtDlpService(tempDir);
        addTearDown(() async {
          await ytDlp.stopAll();
          ytDlp.dispose();
        });

        final server = await _startJsonTestServer((req, body) async {
          final path = req.uri.path;
          if (path == '/sessions') {
            return _sendJson(req.response, HttpStatus.ok, {
              'userId': 1122,
              'countryCode': 'US',
            });
          }
          if (path == '/users/1122') {
            return _sendJson(req.response, HttpStatus.ok, {'id': 1122});
          }
          if (path == '/users/1122/subscription') {
            return _sendJson(req.response, HttpStatus.ok, {
              'subscription': {'type': 'HI_RES_PLUS'},
              'highestSoundQuality': 'HI_RES_LOSSLESS',
            });
          }
          if (path == '/tracks/10096/playbackinfopostpaywall') {
            const mpd96 =
                '<MPD><Period><AdaptationSet><Representation codecs="flac" audioSamplingRate="96000"><SegmentTemplate initialization="https://audio.tidal.com/init.mp4" media="https://audio.tidal.com/\$Number\$.mp4"/></Representation></AdaptationSet></Period></MPD>';
            return _sendJson(req.response, HttpStatus.ok, {
              'audioQuality': 'HI_RES_LOSSLESS',
              'sampleRate': 96000,
              'bitDepth': 24,
              'manifestMimeType': 'application/dash+xml',
              'manifest': base64Encode(utf8.encode(mpd96)),
            });
          }
          if (path == '/tracks/10192/playbackinfopostpaywall') {
            const mpd192 =
                '<MPD><Period><AdaptationSet><Representation codecs="flac" audioSamplingRate="192000"><SegmentTemplate initialization="https://audio.tidal.com/init192.mp4" media="https://audio.tidal.com/192_\$Number\$.mp4"/></Representation></AdaptationSet></Period></MPD>';
            return _sendJson(req.response, HttpStatus.ok, {
              'audioQuality': 'HI_RES_LOSSLESS',
              'sampleRate': 192000,
              'bitDepth': 24,
              'manifestMimeType': 'application/dash+xml',
              'manifest': base64Encode(utf8.encode(mpd192)),
            });
          }
          return _sendJson(req.response, HttpStatus.notFound, {});
        });
        addTearDown(() => server.close(force: true));

        final base = 'http://127.0.0.1:${server.port}';
        final provider = TidalProvider(
          credentialStore: MemorySecureCredentialStore(),
          authBaseUrl: base,
          tokenBaseUrl: base,
          apiBaseUrl: base,
          ytDlpService: ytDlp,
        );
        await provider.authenticate({
          'mode': 'access_token',
          'access_token': 'tok_hires_dash',
        });

        const defaultFmt = AudioFormat(
          codec: AudioCodec.flac,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
        );
        const track96 = TrackInfo(
          id: 'tidal:10096',
          title: 'HiRes 96',
          artist: 'Tester',
          album: 'Test',
          duration: Duration(minutes: 3),
          format: defaultFmt,
          filePath: 'tidal:10096',
          providerName: 'Tidal',
        );
        final res96 = await provider.resolveStream(track96, playRequestId: 301);
        expect(res96.url, startsWith('http://127.0.0.1:'));
        expect(res96.url, endsWith('.flac'));
        expect(res96.hintExtension, equals('flac'));
        expect(res96.format.codec, equals(AudioCodec.flac));
        expect(res96.format.sampleRateHz, equals(96000));
        expect(res96.format.bitDepth, equals(24));
        expect(res96.isPreviewOnly, isFalse);
        expect(res96.drmNotice, isNull);
        expect(
          res96.engineRoute,
          equals('Tidal DASH FLAC (HI_RES_LOSSLESS, ffmpeg remux)'),
        );

        const track192 = TrackInfo(
          id: 'tidal:10192',
          title: 'HiRes 192',
          artist: 'Tester',
          album: 'Test',
          duration: Duration(minutes: 4),
          format: defaultFmt,
          filePath: 'tidal:10192',
          providerName: 'Tidal',
        );
        final res192 = await provider.resolveStream(
          track192,
          playRequestId: 302,
        );
        expect(res192.url, startsWith('http://127.0.0.1:'));
        expect(res192.url, endsWith('.flac'));
        expect(res192.format.codec, equals(AudioCodec.flac));
        expect(res192.format.sampleRateHz, equals(192000));
        expect(res192.format.bitDepth, equals(24));
        expect(res192.isPreviewOnly, isFalse);
        expect(
          res192.engineRoute,
          equals('Tidal DASH FLAC (HI_RES_LOSSLESS, ffmpeg remux)'),
        );
      },
    );

    test(
      'resolveStream auto-downgrades HI_RES_LOSSLESS DRM -> LOSSLESS BTS FLAC -> HIGH BTS AAC, and throws isDrmRestricted when all 3 tiers DRM',
      () async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
        });

        final tempDir = await Directory.systemTemp.createTemp('lumina_tidal_tier_');
        addTearDown(() async {
          if (tempDir.existsSync()) await tempDir.delete(recursive: true);
        });
        final ytDlp = await _createFakeReadyYtDlpService(tempDir);
        addTearDown(() async {
          await ytDlp.stopAll();
          ytDlp.dispose();
        });

        final requestedQualities = <String>[];
        var scenario = 'drm_hires_to_lossless';

        const drmMpd =
            '<MPD><Period><AdaptationSet><ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/><Representation codecs="flac"><SegmentTemplate initialization="https://x/0.mp4"/></Representation></AdaptationSet></Period></MPD>';

        final server = await _startJsonTestServer((req, body) async {
          final path = req.uri.path;
          if (path == '/sessions') {
            return _sendJson(req.response, HttpStatus.ok, {
              'userId': 1122,
              'countryCode': 'US',
            });
          }
          if (path == '/users/1122') {
            return _sendJson(req.response, HttpStatus.ok, {'id': 1122});
          }
          if (path == '/users/1122/subscription') {
            return _sendJson(req.response, HttpStatus.ok, {
              'subscription': {'type': 'HI_RES_PLUS'},
              'highestSoundQuality': 'HI_RES_LOSSLESS',
            });
          }
          if (path == '/tracks/777/playbackinfopostpaywall') {
            final q = req.uri.queryParameters['audioquality'] ?? '';
            requestedQualities.add(q);

            if (scenario == 'drm_hires_to_lossless') {
              if (q == 'HI_RES_LOSSLESS') {
                return _sendJson(req.response, HttpStatus.ok, {
                  'audioQuality': 'HI_RES_LOSSLESS',
                  'manifestMimeType': 'application/dash+xml',
                  'manifest': base64Encode(utf8.encode(drmMpd)),
                });
              }
              if (q == 'LOSSLESS') {
                final bts = jsonEncode({
                  'mimeType': 'audio/flac',
                  'codecs': 'flac',
                  'encryptionType': 'NONE',
                  'bitDepth': 16,
                  'sampleRate': 44100,
                  'urls': ['https://sp-pr-cf.audio.tidal.com/777_44_16.flac'],
                });
                return _sendJson(req.response, HttpStatus.ok, {
                  'audioQuality': 'LOSSLESS',
                  'manifestMimeType': 'application/vnd.tidal.bts',
                  'manifest': base64Encode(utf8.encode(bts)),
                });
              }
            } else if (scenario == 'hires_and_lossless_fail_to_high') {
              if (q == 'HI_RES_LOSSLESS') {
                return _sendJson(req.response, HttpStatus.ok, {
                  'audioQuality': 'HI_RES_LOSSLESS',
                  'manifestMimeType': 'application/dash+xml',
                  'manifest': base64Encode(utf8.encode(drmMpd)),
                });
              }
              if (q == 'LOSSLESS') {
                return _sendJson(req.response, HttpStatus.notFound, {
                  'userMessage': 'LOSSLESS unavailable',
                });
              }
              if (q == 'HIGH') {
                final bts = jsonEncode({
                  'mimeType': 'audio/mp4',
                  'codecs': 'mp4a.40.2',
                  'encryptionType': 'NONE',
                  'bitDepth': 16,
                  'sampleRate': 44100,
                  'urls': ['https://sp-pr-cf.audio.tidal.com/777_high.m4a'],
                });
                return _sendJson(req.response, HttpStatus.ok, {
                  'audioQuality': 'HIGH',
                  'manifestMimeType': 'application/vnd.tidal.bts',
                  'manifest': base64Encode(utf8.encode(bts)),
                });
              }
            } else if (scenario == 'all_tiers_drm') {
              return _sendJson(req.response, HttpStatus.ok, {
                'audioQuality': q,
                'manifestMimeType': 'application/dash+xml',
                'manifest': base64Encode(utf8.encode(drmMpd)),
              });
            }
          }
          return _sendJson(req.response, HttpStatus.notFound, {});
        });
        addTearDown(() => server.close(force: true));

        final base = 'http://127.0.0.1:${server.port}';
        final provider = TidalProvider(
          credentialStore: MemorySecureCredentialStore(),
          authBaseUrl: base,
          tokenBaseUrl: base,
          apiBaseUrl: base,
          ytDlpService: ytDlp,
        );
        await provider.authenticate({
          'mode': 'access_token',
          'access_token': 'tok_tiers',
        });

        const track = TrackInfo(
          id: 'tidal:777',
          title: 'Tier Track',
          artist: 'Tester',
          album: 'Test',
          duration: Duration(minutes: 3),
          format: AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: 44100,
            bitDepth: 16,
            channels: 2,
          ),
          filePath: 'tidal:777',
          providerName: 'Tidal',
        );

        // 1. DRM on HI_RES_LOSSLESS -> downgrades to LOSSLESS direct BTS FLAC.
        requestedQualities.clear();
        scenario = 'drm_hires_to_lossless';
        final lossless = await provider.resolveStream(track, playRequestId: 1);
        expect(requestedQualities, equals(['HI_RES_LOSSLESS', 'LOSSLESS']));
        expect(
          lossless.url,
          equals('https://sp-pr-cf.audio.tidal.com/777_44_16.flac'),
        );
        expect(lossless.format.codec, equals(AudioCodec.flac));
        expect(lossless.format.sampleRateHz, equals(44100));
        expect(lossless.format.bitDepth, equals(16));
        expect(lossless.engineRoute, equals('Tidal Direct FLAC (LOSSLESS)'));

        // 2. HI_RES_LOSSLESS DRM + LOSSLESS 404 -> downgrades to HIGH direct BTS AAC.
        requestedQualities.clear();
        scenario = 'hires_and_lossless_fail_to_high';
        final high = await provider.resolveStream(track, playRequestId: 2);
        expect(
          requestedQualities,
          equals(['HI_RES_LOSSLESS', 'LOSSLESS', 'HIGH']),
        );
        expect(
          high.url,
          equals('https://sp-pr-cf.audio.tidal.com/777_high.m4a'),
        );
        expect(high.format.codec, equals(AudioCodec.aac));
        expect(high.hintExtension, equals('m4a'));
        expect(high.engineRoute, equals('Tidal Direct AAC (HIGH)'));

        // 3. All 3 tiers DRM -> throws StreamingException with isDrmRestricted == true.
        requestedQualities.clear();
        scenario = 'all_tiers_drm';
        await expectLater(
          provider.resolveStream(track, playRequestId: 3),
          throwsA(predicate<StreamingException>((e) => e.isDrmRestricted)),
        );
        expect(
          requestedQualities,
          equals(['HI_RES_LOSSLESS', 'LOSSLESS', 'HIGH']),
        );
      },
    );

    test(
      'StreamingPlaybackCoordinator recovers automatically via LOSSLESS direct BTS FLAC when DASH proxy stream errors, and skips background pre-resolve for Tidal tracks',
      () async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
        });

        final tempDir = await Directory.systemTemp.createTemp('lumina_tidal_coord_');
        addTearDown(() async {
          if (tempDir.existsSync()) await tempDir.delete(recursive: true);
        });
        final ytDlp = await _createFakeReadyYtDlpService(tempDir);
        addTearDown(() async {
          await ytDlp.stopAll();
          ytDlp.dispose();
        });

        final playbackQueries = <String>[];
        final server = await _startJsonTestServer((req, body) async {
          final path = req.uri.path;
          if (path == '/sessions') {
            return _sendJson(req.response, HttpStatus.ok, {
              'userId': 1122,
              'countryCode': 'US',
            });
          }
          if (path == '/users/1122') {
            return _sendJson(req.response, HttpStatus.ok, {'id': 1122});
          }
          if (path == '/users/1122/subscription') {
            return _sendJson(req.response, HttpStatus.ok, {
              'subscription': {'type': 'HI_RES_PLUS'},
              'highestSoundQuality': 'HI_RES_LOSSLESS',
            });
          }
          if (path == '/tracks/888/playbackinfopostpaywall') {
            final q = req.uri.queryParameters['audioquality'] ?? '';
            playbackQueries.add(q);
            if (q == 'HI_RES_LOSSLESS') {
              const mpd =
                  '<MPD><Period><AdaptationSet><Representation codecs="flac" audioSamplingRate="96000"><SegmentTemplate initialization="https://audio.tidal.com/init.mp4"/></Representation></AdaptationSet></Period></MPD>';
              return _sendJson(req.response, HttpStatus.ok, {
                'audioQuality': 'HI_RES_LOSSLESS',
                'sampleRate': 96000,
                'bitDepth': 24,
                'manifestMimeType': 'application/dash+xml',
                'manifest': base64Encode(utf8.encode(mpd)),
              });
            }
            if (q == 'LOSSLESS') {
              final bts = jsonEncode({
                'mimeType': 'audio/flac',
                'codecs': 'flac',
                'encryptionType': 'NONE',
                'bitDepth': 16,
                'sampleRate': 44100,
                'urls': ['https://sp-pr-cf.audio.tidal.com/888_lossless.flac'],
              });
              return _sendJson(req.response, HttpStatus.ok, {
                'audioQuality': 'LOSSLESS',
                'manifestMimeType': 'application/vnd.tidal.bts',
                'manifest': base64Encode(utf8.encode(bts)),
              });
            }
          }
          if (path == '/tracks/999/playbackinfopostpaywall') {
            playbackQueries.add('PRE_RESOLVE_SHOULD_NOT_HAPPEN');
            return _sendJson(req.response, HttpStatus.notFound, {});
          }
          return _sendJson(req.response, HttpStatus.notFound, {});
        });
        addTearDown(() => server.close(force: true));

        final base = 'http://127.0.0.1:${server.port}';
        final credStore = MemorySecureCredentialStore();
        final tidal = TidalProvider(
          credentialStore: credStore,
          authBaseUrl: base,
          tokenBaseUrl: base,
          apiBaseUrl: base,
          ytDlpService: ytDlp,
        );
        await tidal.authenticate({
          'mode': 'access_token',
          'access_token': 'tok_coord',
        });

        final manager = StreamingManager(
          credentialStore: credStore,
          ytDlpService: ytDlp,
          providers: <String, StreamingProvider>{'tidal': tidal},
        );
        addTearDown(manager.dispose);

        final audioService = _SpyAudioService();
        addTearDown(audioService.dispose);

        final errors = <String>[];
        final logs = <String>[];
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audioService,
          streamingManager: manager,
          ytDlpService: ytDlp,
          debounceDelay: Duration.zero,
          logSink: logs.add,
          onError: (_, msg, _) => errors.add(msg),
        );
        addTearDown(coordinator.dispose);

        const defaultFmt = AudioFormat(
          codec: AudioCodec.flac,
          sampleRateHz: 44100,
          bitDepth: 16,
          channels: 2,
        );
        const track = TrackInfo(
          id: 'tidal:888',
          title: 'DASH Fallback Track',
          artist: 'Tidal Artist',
          album: 'Tidal Album',
          duration: Duration(seconds: 30),
          format: defaultFmt,
          filePath: 'tidal:888',
          providerName: 'Tidal',
        );
        const queuedNextTidal = TrackInfo(
          id: 'tidal:999',
          title: 'Queued Next Tidal',
          artist: 'Tidal Artist',
          album: 'Tidal Album',
          duration: Duration(seconds: 30),
          format: defaultFmt,
          filePath: 'tidal:999',
          providerName: 'Tidal',
        );

        await coordinator.playTrack(
          track,
          queueContext: const [track, queuedNextTidal],
        );

        expect(audioService.recordedPlays.length, equals(1));
        expect(
          audioService.recordedPlays.first.streamUrl,
          startsWith('http://127.0.0.1:'),
        );
        expect(audioService.recordedPlays.first.streamUrl, endsWith('.flac'));

        // Simulate PlaybackStatus.playing near end-of-track: pre-resolve must skip Tidal track 999.
        audioService.emitRawStateForTest(
          const PlaybackState(
            status: PlaybackStatus.playing,
            track: track,
            position: Duration(seconds: 20),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(playbackQueries, isNot(contains('PRE_RESOLVE_SHOULD_NOT_HAPPEN')));

        // Simulate runtime PlaybackStatus.error on the DASH proxy stream.
        audioService.emitRawStateForTest(
          PlaybackState(
            status: PlaybackStatus.error,
            track: track.copyWith(
              format: const AudioFormat(
                codec: AudioCodec.flac,
                sampleRateHz: 96000,
                bitDepth: 24,
                channels: 2,
              ),
            ),
            lastError: 'HTTP 502 Bad Gateway from DASH proxy',
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 50));
        await coordinator.activeTaskFuture;

        expect(errors, isEmpty);
        expect(audioService.recordedPlays.length, equals(2));
        expect(
          audioService.recordedPlays.last.streamUrl,
          equals('https://sp-pr-cf.audio.tidal.com/888_lossless.flac'),
        );
        expect(
          audioService.recordedPlays.last.track.format.sampleRateHz,
          equals(44100),
        );
        expect(
          audioService.recordedPlays.last.track.format.bitDepth,
          equals(16),
        );
        expect(playbackQueries, equals(['HI_RES_LOSSLESS', 'LOSSLESS']));
        expect(
          logs,
          contains(
            '[Tidal Play] track=tidal:888 -> runtime error (HTTP 502 Bad Gateway from DASH proxy); auto-downgrading to LOSSLESS (DASH enabled)',
          ),
        );
      },
    );

    test(
      'StreamingPlaybackCoordinator runtime DASH downgrade matrix: LOSSLESS DASH FLAC, LOSSLESS+HIGH DASH AAC (WAV proxy), no duplicate HIGH retry, and real errors on all-tier failure',
      () async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
        });

        final tempDir = await Directory.systemTemp.createTemp('lumina_tidal_mat_');
        addTearDown(() async {
          if (tempDir.existsSync()) await tempDir.delete(recursive: true);
        });
        final ytDlp = await _createFakeReadyYtDlpService(tempDir);
        addTearDown(() async {
          await ytDlp.stopAll();
          ytDlp.dispose();
        });

        var scenario = 'lossless_dash_ok';
        final playbackQueries = <String>[];
        const drmMpd =
            '<MPD><Period><AdaptationSet><ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed"/><Representation codecs="flac"><SegmentTemplate initialization="https://x/0.mp4"/></Representation></AdaptationSet></Period></MPD>';

        Map<String, dynamic> dashFlacPayload(String quality, int sr, int bd) {
          final mpd =
              '<MPD><Period><AdaptationSet><Representation codecs="flac" audioSamplingRate="$sr"><SegmentTemplate initialization="https://audio.tidal.com/${quality}_init.mp4" media="https://audio.tidal.com/${quality}_\$Number\$.m4s"/></Representation></AdaptationSet></Period></MPD>';
          return {
            'audioQuality': quality,
            'sampleRate': sr,
            'bitDepth': bd,
            'manifestMimeType': 'application/dash+xml',
            'manifest': base64Encode(utf8.encode(mpd)),
          };
        }

        Map<String, dynamic> dashAacPayload(String quality) {
          const mpd =
              '<MPD><Period><AdaptationSet><Representation codecs="mp4a.40.2" audioSamplingRate="44100"><SegmentTemplate initialization="https://audio.tidal.com/high_init.mp4" media="https://audio.tidal.com/high_\$Number\$.m4s"/></Representation></AdaptationSet></Period></MPD>';
          return {
            'audioQuality': quality,
            'sampleRate': 44100,
            'bitDepth': 16,
            'manifestMimeType': 'application/dash+xml',
            'manifest': base64Encode(utf8.encode(mpd)),
          };
        }

        final server = await _startJsonTestServer((req, body) async {
          final path = req.uri.path;
          if (path == '/sessions') {
            return _sendJson(req.response, HttpStatus.ok, {
              'userId': 2233,
              'countryCode': 'US',
            });
          }
          if (path == '/users/2233') {
            return _sendJson(req.response, HttpStatus.ok, {'id': 2233});
          }
          if (path == '/users/2233/subscription') {
            return _sendJson(req.response, HttpStatus.ok, {
              'subscription': {'type': 'HI_RES_PLUS'},
              'highestSoundQuality': 'HI_RES_LOSSLESS',
            });
          }
          if (path == '/tracks/333/playbackinfopostpaywall') {
            final q = req.uri.queryParameters['audioquality'] ?? '';
            playbackQueries.add(q);
            if (scenario == 'lossless_dash_ok') {
              if (q == 'HI_RES_LOSSLESS') {
                return _sendJson(
                  req.response,
                  HttpStatus.ok,
                  dashFlacPayload('HI_RES_LOSSLESS', 96000, 24),
                );
              }
              if (q == 'LOSSLESS') {
                return _sendJson(
                  req.response,
                  HttpStatus.ok,
                  dashFlacPayload('LOSSLESS', 44100, 16),
                );
              }
            } else if (scenario == 'cascade_to_high_dash_wav') {
              if (q == 'HI_RES_LOSSLESS') {
                return _sendJson(
                  req.response,
                  HttpStatus.ok,
                  dashFlacPayload('HI_RES_LOSSLESS', 96000, 24),
                );
              }
              if (q == 'LOSSLESS') {
                return _sendJson(
                  req.response,
                  HttpStatus.ok,
                  dashFlacPayload('LOSSLESS', 44100, 16),
                );
              }
              if (q == 'HIGH') {
                return _sendJson(
                  req.response,
                  HttpStatus.ok,
                  dashAacPayload('HIGH'),
                );
              }
            } else if (scenario == 'lossless_drm_resolves_high_dash') {
              if (q == 'HI_RES_LOSSLESS') {
                return _sendJson(
                  req.response,
                  HttpStatus.ok,
                  dashFlacPayload('HI_RES_LOSSLESS', 96000, 24),
                );
              }
              if (q == 'LOSSLESS') {
                return _sendJson(req.response, HttpStatus.ok, {
                  'audioQuality': 'LOSSLESS',
                  'manifestMimeType': 'application/dash+xml',
                  'manifest': base64Encode(utf8.encode(drmMpd)),
                });
              }
              if (q == 'HIGH') {
                return _sendJson(
                  req.response,
                  HttpStatus.ok,
                  dashAacPayload('HIGH'),
                );
              }
            } else if (scenario == 'all_tiers_fail_after_runtime_err') {
              if (q == 'HI_RES_LOSSLESS') {
                return _sendJson(
                  req.response,
                  HttpStatus.ok,
                  dashFlacPayload('HI_RES_LOSSLESS', 96000, 24),
                );
              }
              if (q == 'LOSSLESS') {
                return _sendJson(req.response, HttpStatus.ok, {
                  'audioQuality': 'LOSSLESS',
                  'manifestMimeType': 'application/dash+xml',
                  'manifest': base64Encode(utf8.encode(drmMpd)),
                });
              }
              if (q == 'HIGH') {
                return _sendJson(req.response, HttpStatus.notFound, {
                  'userMessage': 'HIGH stream missing upstream',
                });
              }
            }
          }
          return _sendJson(req.response, HttpStatus.notFound, {});
        });
        addTearDown(() => server.close(force: true));

        final base = 'http://127.0.0.1:${server.port}';
        final credStore = MemorySecureCredentialStore();
        final tidal = TidalProvider(
          credentialStore: credStore,
          authBaseUrl: base,
          tokenBaseUrl: base,
          apiBaseUrl: base,
          ytDlpService: ytDlp,
        );
        await tidal.authenticate({
          'mode': 'access_token',
          'access_token': 'tok_mat',
        });

        final manager = StreamingManager(
          credentialStore: credStore,
          ytDlpService: ytDlp,
          providers: <String, StreamingProvider>{'tidal': tidal},
        );
        addTearDown(manager.dispose);

        final audioService = _SpyAudioService();
        addTearDown(audioService.dispose);

        final errors = <String>[];
        final logs = <String>[];
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audioService,
          streamingManager: manager,
          ytDlpService: ytDlp,
          debounceDelay: Duration.zero,
          logSink: logs.add,
          onError: (_, msg, _) => errors.add(msg),
        );
        addTearDown(coordinator.dispose);

        const track = TrackInfo(
          id: 'tidal:333',
          title: 'Matrix Track',
          artist: 'Tester',
          album: 'Matrix',
          duration: Duration(minutes: 3),
          format: AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: 44100,
            bitDepth: 16,
            channels: 2,
          ),
          filePath: 'tidal:333',
          providerName: 'Tidal',
        );

        Future<void> emitRuntimeError(String errMsg) async {
          audioService.emitRawStateForTest(
            PlaybackState(
              status: PlaybackStatus.error,
              track: track,
              lastError: errMsg,
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 30));
          final pending = coordinator.activeTaskFuture;
          if (pending != null) {
            await pending;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        // Case A: HI_RES_LOSSLESS DASH runtime error -> LOSSLESS unencrypted DASH FLAC (not BTS).
        scenario = 'lossless_dash_ok';
        playbackQueries.clear();
        audioService.recordedPlays.clear();
        errors.clear();
        logs.clear();

        await coordinator.playTrack(track);
        expect(audioService.recordedPlays.length, equals(1));
        expect(audioService.recordedPlays.last.streamUrl, endsWith('.flac'));

        await emitRuntimeError('HTTP 502 from HI_RES proxy');
        expect(errors, isEmpty);
        expect(playbackQueries, equals(['HI_RES_LOSSLESS', 'LOSSLESS']));
        expect(audioService.recordedPlays.length, equals(2));
        expect(
          audioService.recordedPlays.last.streamUrl,
          startsWith('http://127.0.0.1:'),
        );
        expect(audioService.recordedPlays.last.streamUrl, endsWith('.flac'));
        expect(
          audioService.recordedPlays.last.track.format.codec,
          equals(AudioCodec.flac),
        );
        expect(
          audioService.recordedPlays.last.track.format.sampleRateHz,
          equals(44100),
        );
        expect(
          audioService.recordedPlays.last.track.format.bitDepth,
          equals(16),
        );
        expect(
          logs,
          contains(
            '[Tidal Play] track=tidal:333 -> runtime error (HTTP 502 from HI_RES proxy); auto-downgrading to LOSSLESS (DASH enabled)',
          ),
        );

        // Case B: HI_RES_LOSSLESS DASH + LOSSLESS DASH runtime errors -> HIGH unencrypted DASH AAC (WAV proxy).
        scenario = 'cascade_to_high_dash_wav';
        playbackQueries.clear();
        audioService.recordedPlays.clear();
        errors.clear();
        logs.clear();

        await coordinator.playTrack(track);
        await emitRuntimeError('HI_RES proxy died at 10s');
        await emitRuntimeError('LOSSLESS proxy died at 10s');

        expect(errors, isEmpty);
        expect(
          playbackQueries,
          equals(['HI_RES_LOSSLESS', 'LOSSLESS', 'HIGH']),
        );
        expect(audioService.recordedPlays.length, equals(3));
        expect(
          audioService.recordedPlays.last.streamUrl,
          startsWith('http://127.0.0.1:'),
        );
        expect(audioService.recordedPlays.last.streamUrl, endsWith('.wav'));
        expect(
          audioService.recordedPlays.last.track.format.codec,
          equals(AudioCodec.aac),
        );
        expect(
          logs,
          containsAllInOrder(<String>[
            '[Tidal Play] track=tidal:333 -> runtime error (HI_RES proxy died at 10s); auto-downgrading to LOSSLESS (DASH enabled)',
            '[Tidal Play] track=tidal:333 -> runtime error (LOSSLESS proxy died at 10s); auto-downgrading to HIGH (DASH enabled)',
          ]),
        );

        // If HIGH DASH also errors at runtime, it must NOT retry HIGH twice and must surface the real error.
        await emitRuntimeError('HIGH proxy failed upstream');
        expect(
          playbackQueries,
          equals(['HI_RES_LOSSLESS', 'LOSSLESS', 'HIGH']),
        );
        expect(errors, equals(['HIGH proxy failed upstream']));

        // Case C: LOSSLESS is DRM so maxQuality=LOSSLESS internally resolves HIGH DASH AAC -> runtime error must NOT retry HIGH twice.
        scenario = 'lossless_drm_resolves_high_dash';
        playbackQueries.clear();
        audioService.recordedPlays.clear();
        errors.clear();

        await coordinator.playTrack(track);
        await emitRuntimeError('HI_RES failed');
        expect(errors, isEmpty);
        expect(audioService.recordedPlays.length, equals(2));
        expect(audioService.recordedPlays.last.streamUrl, endsWith('.wav'));

        await emitRuntimeError('HIGH DASH stream aborted');
        expect(
          playbackQueries,
          equals(['HI_RES_LOSSLESS', 'LOSSLESS', 'HIGH']),
        );
        expect(errors, equals(['HIGH DASH stream aborted']));

        // Case D: All remaining tiers fail during recovery -> reports concrete error, never '目前播放模式已停用 DASH'.
        scenario = 'all_tiers_fail_after_runtime_err';
        playbackQueries.clear();
        audioService.recordedPlays.clear();
        errors.clear();

        await coordinator.playTrack(track);
        await emitRuntimeError('Initial DASH 502 error');
        expect(
          playbackQueries,
          equals(['HI_RES_LOSSLESS', 'LOSSLESS', 'HIGH']),
        );
        expect(errors, hasLength(1));
        expect(errors.single, isNot(contains('目前播放模式已停用 DASH')));
        expect(errors.single, contains('HIGH stream missing upstream'));
        expect(errors.single, contains('Initial DASH 502 error'));
        expect(audioService.currentState.status, equals(PlaybackStatus.error));
      },
    );
  });

  group('Stage 2: Tidal Explore Recommendations, Feed Parsing, Seed Rotation & UI', () {
    test(
      'captures countryCode from /sessions (and fallback /users/\$uid), sends Authorization: Bearer & countryCode across requests, and resets on logout',
      () async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
        });

        var omitSessionCountry = false;
        final observedRequests = <({String path, String? auth, String? cc})>[];

        final server = await _startJsonTestServer((req, body) async {
          final path = req.uri.path;
          observedRequests.add((
            path: path,
            auth: req.headers.value(HttpHeaders.authorizationHeader),
            cc: req.uri.queryParameters['countryCode'],
          ));
          if (path == '/v1/sessions') {
            return _sendJson(req.response, HttpStatus.ok, {
              'userId': 5511,
              if (!omitSessionCountry) 'countryCode': 'jp',
            });
          }
          if (path == '/v1/users/5511') {
            return _sendJson(req.response, HttpStatus.ok, {
              'id': 5511,
              'username': 'cc_tester',
              if (omitSessionCountry) 'countryCode': 'de',
            });
          }
          if (path == '/v1/users/5511/subscription') {
            return _sendJson(req.response, HttpStatus.ok, {
              'subscription': {'type': 'HI_RES_PLUS'},
              'highestSoundQuality': 'HI_RES_LOSSLESS',
            });
          }
          if (path == '/v1/users/5511/favorites/tracks' ||
              path == '/v1/users/5511/favorites/albums' ||
              path == '/v1/users/5511/playlists' ||
              path == '/v1/featured/recommended/albums' ||
              path == '/v1/featured/new/albums' ||
              path == '/v1/featured/top/tracks') {
            return _sendJson(req.response, HttpStatus.ok, {'items': []});
          }
          if (path == '/v2/home/feed/static' ||
              path == '/v1/pages/home' ||
              path == '/v1/pages/explore') {
            return _sendJson(req.response, HttpStatus.ok, {'rows': []});
          }
          return _sendJson(req.response, HttpStatus.notFound, {});
        });
        addTearDown(() => server.close(force: true));

        final base = 'http://127.0.0.1:${server.port}';
        final provider = TidalProvider(
          credentialStore: MemorySecureCredentialStore(),
          authBaseUrl: base,
          tokenBaseUrl: base,
          apiBaseUrl: '$base/v1',
        );

        // Case 1: countryCode from /sessions ('jp' -> 'JP').
        await provider.authenticate({
          'mode': 'access_token',
          'access_token': 'tok_jp_1',
        });
        expect(provider.accountInfo?.countryCode, equals('JP'));

        await provider.syncLibrary();
        await provider.fetchRecommendations();

        final jpExploreCalls = observedRequests.where(
          (r) => r.path == '/v2/home/feed/static' || r.path == '/v1/pages/explore',
        );
        expect(jpExploreCalls, isNotEmpty);
        for (final r in jpExploreCalls) {
          expect(r.auth, equals('Bearer tok_jp_1'));
          expect(r.cc, equals('JP'));
        }

        // logout() resets countryCode and credentials.
        await provider.logout();
        expect(provider.accountInfo, isNull);

        // Case 2: /sessions omits countryCode -> fallback /users/$uid ('de' -> 'DE').
        observedRequests.clear();
        omitSessionCountry = true;
        await provider.authenticate({
          'mode': 'access_token',
          'access_token': 'tok_de_2',
        });
        expect(provider.accountInfo?.countryCode, equals('DE'));
        await provider.fetchRecommendations();

        final deExploreCalls = observedRequests.where(
          (r) => r.path == '/v2/home/feed/static' || r.path == '/v1/pages/explore',
        );
        expect(deExploreCalls, isNotEmpty);
        for (final r in deExploreCalls) {
          expect(r.auth, equals('Bearer tok_de_2'));
          expect(r.cc, equals('DE'));
        }
      },
    );

    test(
      'parses /v2/home/feed/static data wrappers, refuses to misclassify album with duration as track, applies HIRES_LOSSLESS tag, converts UUID covers to 640x640 (1280x1280 in detail), and rotates recommendations with /albums/<id>/similar & /tracks/<id>/radio',
      () async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
        });

        final seenPaths = <String>[];
        var emptyHomeFeed = false;

        final server = await _startJsonTestServer((req, body) async {
          final path = req.uri.path;
          seenPaths.add(path);

          if (path == '/v1/sessions') {
            return _sendJson(req.response, HttpStatus.ok, {
              'userId': 9009,
              'countryCode': 'TW',
            });
          }
          if (path == '/v1/users/9009') {
            return _sendJson(req.response, HttpStatus.ok, {'id': 9009});
          }
          if (path == '/v1/users/9009/subscription') {
            return _sendJson(req.response, HttpStatus.ok, {
              'subscription': {'type': 'HI_RES_PLUS'},
              'highestSoundQuality': 'HI_RES_LOSSLESS',
            });
          }
          if (path == '/v2/home/feed/static') {
            if (emptyHomeFeed) {
              return _sendJson(req.response, HttpStatus.ok, {'items': []});
            }
            return _sendJson(req.response, HttpStatus.ok, {
              'items': [
                {
                  'type': 'ALBUM',
                  'data': {
                    'id': 1001,
                    'title': 'V2 Album With Duration',
                    'duration': 2400,
                    'numberOfTracks': 10,
                    'releaseDate': '2024-06-01',
                    'cover': 'abcd1234-5678-90ef-1234-567890abcdef',
                    'audioQuality': 'LOSSLESS',
                    'mediaMetadata': {
                      'tags': ['HIRES_LOSSLESS'],
                    },
                    'artist': {'name': 'HiRes Composer'},
                  },
                },
                {
                  'type': 'TRACK',
                  'data': {
                    'id': 2001,
                    'title': 'V2 HiRes Track',
                    'duration': 210,
                    'trackNumber': 1,
                    'audioQuality': 'LOSSLESS',
                    'mediaMetadata': {
                      'tags': ['HIRES_LOSSLESS'],
                    },
                    'album': {
                      'id': 1001,
                      'title': 'V2 Album With Duration',
                      'cover': 'abcd1234-5678-90ef-1234-567890abcdef',
                    },
                    'artist': {'name': 'HiRes Composer'},
                  },
                },
                {
                  'type': 'ARTIST',
                  'data': {'id': 3001, 'name': 'Should Be Excluded'},
                },
                {
                  'type': 'VIDEO',
                  'data': {'id': 3002, 'title': 'Video Excluded', 'duration': 180},
                },
              ],
            });
          }
          if (path == '/v1/pages/home') {
            return _sendJson(req.response, HttpStatus.ok, {'rows': []});
          }
          if (path == '/v1/pages/explore') {
            return _sendJson(req.response, HttpStatus.ok, {
              'rows': [
                {
                  'modules': [
                    {
                      'type': 'ALBUM_LIST',
                      'pagedList': {
                        'items': [
                          {
                            'id': 1002,
                            'title': 'Explore Fallback Album',
                            'numberOfTracks': 8,
                            'releaseDate': '2025-01-15',
                            'cover': '11112222-3333-4444-5555-666677778888',
                            'artist': {'name': 'Explore Artist'},
                          },
                        ],
                      },
                    },
                  ],
                },
              ],
            });
          }
          if (path == '/v1/featured/recommended/albums') {
            return _sendJson(req.response, HttpStatus.ok, {
              'items': [
                {
                  'id': 1003,
                  'title': 'Featured Rec Album',
                  'numberOfTracks': 9,
                  'cover': '22223333-4444-5555-6666-777788889999',
                  'artist': {'name': 'Featured Artist'},
                },
              ],
            });
          }
          if (path == '/v1/featured/new/albums') {
            return _sendJson(req.response, HttpStatus.ok, {
              'items': [
                {
                  'id': 1004,
                  'title': 'Featured New Album',
                  'numberOfTracks': 11,
                  'cover': '33334444-5555-6666-7777-888899990000',
                  'artist': {'name': 'New Artist'},
                },
              ],
            });
          }
          if (path == '/v1/featured/top/tracks') {
            return _sendJson(req.response, HttpStatus.ok, {
              'items': [
                {
                  'id': 2002,
                  'title': 'Featured Top Track',
                  'duration': 195,
                  'audioQuality': 'LOSSLESS',
                  'album': {
                    'id': 1003,
                    'title': 'Featured Rec Album',
                    'cover': '22223333-4444-5555-6666-777788889999',
                  },
                  'artist': {'name': 'Featured Artist'},
                },
              ],
            });
          }
          if (path == '/v1/pages/explore_new_music') {
            return _sendJson(req.response, HttpStatus.ok, {
              'rows': [
                {
                  'modules': [
                    {
                      'type': 'ALBUM_LIST',
                      'pagedList': {
                        'items': [
                          {
                            'id': 1005,
                            'title': 'Batch 1 New Music Album',
                            'numberOfTracks': 12,
                            'cover': '44445555-6666-7777-8888-999900001111',
                            'artist': {'name': 'Batch1 Artist'},
                          },
                        ],
                      },
                    },
                  ],
                },
              ],
            });
          }
          if (path == '/v1/pages/explore_top_music' ||
              path == '/v1/featured/top/albums') {
            return _sendJson(req.response, HttpStatus.ok, {
              'items': [
                {
                  'id': 1006,
                  'title': 'Batch 2 Top Album',
                  'numberOfTracks': 7,
                  'cover': '55556666-7777-8888-9999-000011112222',
                  'artist': {'name': 'Batch2 Artist'},
                },
              ],
            });
          }
          if (path.startsWith('/v1/albums/') && path.endsWith('/similar')) {
            return _sendJson(req.response, HttpStatus.ok, {
              'items': [
                {
                  'id': 1099,
                  'title': 'Similar Seed Album',
                  'numberOfTracks': 10,
                  'cover': '66667777-8888-9999-0000-111122223333',
                  'artist': {'name': 'Similar Artist'},
                },
              ],
            });
          }
          if (path.startsWith('/v1/tracks/') && path.endsWith('/radio')) {
            return _sendJson(req.response, HttpStatus.ok, {
              'items': [
                {
                  'id': 2099,
                  'title': 'Radio Seed Track',
                  'duration': 205,
                  'audioQuality': 'HI_RES_LOSSLESS',
                  'album': {
                    'id': 1099,
                    'title': 'Similar Seed Album',
                    'cover': '66667777-8888-9999-0000-111122223333',
                  },
                  'artist': {'name': 'Radio Artist'},
                },
              ],
            });
          }
          if (path == '/v1/albums/1001') {
            return _sendJson(req.response, HttpStatus.ok, {
              'id': 1001,
              'title': 'V2 Album With Duration',
              'releaseDate': '2024-06-01',
              'cover': 'abcd1234-5678-90ef-1234-567890abcdef',
              'audioQuality': 'LOSSLESS',
              'mediaMetadata': {
                'tags': ['HIRES_LOSSLESS'],
              },
              'artist': {'name': 'HiRes Composer'},
              'items': [
                {
                  'item': {
                    'id': 2001,
                    'title': 'V2 HiRes Track',
                    'duration': 210,
                    'trackNumber': 1,
                    'audioQuality': 'LOSSLESS',
                    'mediaMetadata': {
                      'tags': ['HIRES_LOSSLESS'],
                    },
                    'artist': {'name': 'HiRes Composer'},
                  },
                },
              ],
            });
          }
          return _sendJson(req.response, HttpStatus.notFound, {});
        });
        addTearDown(() => server.close(force: true));

        final base = 'http://127.0.0.1:${server.port}';
        final provider = TidalProvider(
          credentialStore: MemorySecureCredentialStore(),
          authBaseUrl: base,
          tokenBaseUrl: base,
          apiBaseUrl: '$base/v1',
        );
        await provider.authenticate({
          'mode': 'access_token',
          'access_token': 'tok_rec_tw',
        });

        // A. /v2/home/feed/static parsing + duration album protection + HIRES_LOSSLESS tag
        seenPaths.clear();
        final recV2 = await provider.fetchRecommendations();
        expect(seenPaths, contains('/v2/home/feed/static'));
        expect(recV2.albums.any((a) => a.id == '1001'), isTrue);
        expect(
          recV2.tracks.any((t) => t.id == 'tidal:1001'),
          isFalse,
          reason: 'Album with duration must NOT be misclassified as a track',
        );
        final v2Album = recV2.albums.firstWhere((a) => a.id == '1001');
        expect(v2Album.qualityLabel, equals('HI_RES_LOSSLESS'));
        expect(
          v2Album.coverUrl,
          equals(
            'https://resources.tidal.com/images/abcd1234/5678/90ef/1234/567890abcdef/640x640.jpg',
          ),
        );
        final v2Track = recV2.tracks.firstWhere((t) => t.id == 'tidal:2001');
        expect(v2Track.format.sampleRateHz, equals(96000));
        expect(v2Track.format.bitDepth, equals(24));
        expect(
          recV2.tracks.any((t) => t.id.contains('3001') || t.id.contains('3002')),
          isFalse,
        );

        // Album detail upgrades UUID cover to 1280x1280.jpg & detects HIRES_LOSSLESS.
        final detail = await provider.fetchAlbumDetail('1001');
        expect(detail, isNotNull);
        expect(
          detail!.coverUrl,
          equals(
            'https://resources.tidal.com/images/abcd1234/5678/90ef/1234/567890abcdef/1280x1280.jpg',
          ),
        );
        expect(detail.versions.single.editionLabel, equals('Tidal HiRes FLAC'));
        expect(detail.versions.single.sampleRateHz, equals(96000));
        expect(detail.versions.single.bitDepth, equals(24));

        // B. Empty home feed (new account fallback) -> /v1/pages/explore + /featured/*
        seenPaths.clear();
        emptyHomeFeed = true;
        final recNewAcc = await provider.fetchRecommendations();
        expect(seenPaths, contains('/v1/pages/explore'));
        expect(seenPaths, contains('/v1/featured/recommended/albums'));
        expect(seenPaths, contains('/v1/featured/new/albums'));
        expect(seenPaths, contains('/v1/featured/top/tracks'));
        expect(
          recNewAcc.albums.map((a) => a.id),
          containsAll(['1002', '1003', '1004']),
        );
        expect(recNewAcc.tracks.map((t) => t.id), contains('tidal:2002'));
        expect(
          recNewAcc.albums.firstWhere((a) => a.id == '1002').coverUrl,
          equals(
            'https://resources.tidal.com/images/11112222/3333/4444/5555/666677778888/640x640.jpg',
          ),
        );

        // C. 換一批 (forceRefresh: true, batchIndex: 1 & 2) -> rotates sections & calls /albums/<id>/similar & /tracks/<id>/radio
        seenPaths.clear();
        final batch1 = await provider.fetchRecommendations(
          forceRefresh: true,
          batchIndex: 1,
          excludeAlbumIds: {'1002', '1003', '1004'},
          excludeTrackIds: {'tidal:2002'},
        );
        expect(seenPaths, contains('/v1/pages/explore_new_music'));
        expect(
          seenPaths.any((p) => RegExp(r'^/v1/albums/\d+/similar$').hasMatch(p)),
          isTrue,
        );
        expect(
          seenPaths.any((p) => RegExp(r'^/v1/tracks/\d+/radio$').hasMatch(p)),
          isTrue,
        );
        expect(batch1.albums.map((a) => a.id), contains('1005'));
        expect(batch1.albums.map((a) => a.id), contains('1099'));
        expect(batch1.tracks.map((t) => t.id), contains('tidal:2099'));

        seenPaths.clear();
        final batch2 = await provider.fetchRecommendations(
          forceRefresh: true,
          batchIndex: 2,
          excludeAlbumIds: batch1.albums.map((a) => a.id).toSet(),
          excludeTrackIds: batch1.tracks.map((t) => t.id).toSet(),
        );
        expect(seenPaths, contains('/v1/pages/explore_top_music'));
        expect(seenPaths, contains('/v1/featured/top/albums'));
        expect(batch2.albums.map((a) => a.id), contains('1006'));
      },
    );

    testWidgets(
      'StreamingServiceView for Tidal defaults empty favorites to 探索推薦 (tab 0), opens albums, plays tracks, and defaults populated favorites to 收藏曲目 (tab 1)',
      (WidgetTester tester) async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
        });

        final imageServer = await tester.runAsync(() async {
          final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          srv.listen((req) async {
            req.response.statusCode = HttpStatus.ok;
            req.response.headers.contentType = ContentType('image', 'png');
            req.response.add(_valid1x1Png);
            await req.response.close();
          });
          return srv;
        });
        addTearDown(() => imageServer!.close(force: true));

        final requestedImageUrls = <String>[];
        final createdClients = <HttpClient>[];
        debugNetworkImageHttpClientProvider = () {
          final client = HttpClient()
          ..autoUncompress = false
          ..idleTimeout = Duration.zero;
          createdClients.add(client);
          return _TidalInterceptingHttpClient(
            client,
            imageServerPort: imageServer!.port,
            requestedImageUrls: requestedImageUrls,
          );
        };
        addTearDown(() {
          debugNetworkImageHttpClientProvider = null;
          for (final c in createdClients) {
            c.close(force: true);
          }
        });

        var hasFavorites = false;
        final server = await tester.runAsync(
          () => _startJsonTestServer((req, body) async {
            final path = req.uri.path;
            if (path == '/v1/sessions') {
              return _sendJson(req.response, HttpStatus.ok, {
                'userId': 4040,
                'countryCode': 'US',
              });
            }
            if (path == '/v1/users/4040') {
              return _sendJson(req.response, HttpStatus.ok, {'id': 4040});
            }
            if (path == '/v1/users/4040/subscription') {
              return _sendJson(req.response, HttpStatus.ok, {
                'subscription': {'type': 'HI_RES_PLUS'},
                'highestSoundQuality': 'HI_RES_LOSSLESS',
              });
            }
            if (path == '/v1/users/4040/favorites/tracks') {
              return _sendJson(req.response, HttpStatus.ok, {
                'items': hasFavorites
                    ? [
                        {
                          'item': {
                            'id': 9101,
                            'title': 'Synced Fav Track',
                            'duration': 220,
                            'audioQuality': 'HI_RES_LOSSLESS',
                            'album': {
                              'id': 8101,
                              'title': 'Fav Album',
                              'cover': 'aaaa1111-2222-3333-4444-555566667777',
                            },
                            'artist': {'name': 'Fav Artist'},
                          },
                        },
                      ]
                    : <Object>[],
              });
            }
            if (path == '/v1/users/4040/favorites/albums' ||
                path == '/v1/users/4040/playlists') {
              return _sendJson(req.response, HttpStatus.ok, {'items': []});
            }
            if (path == '/v2/home/feed/static') {
              return _sendJson(req.response, HttpStatus.ok, {
                'items': [
                  {
                    'type': 'ALBUM',
                    'data': {
                      'id': 7001,
                      'title': 'Tidal Explore Hero Album',
                      'numberOfTracks': 8,
                      'cover': 'bbbb1111-2222-3333-4444-555566667777',
                      'artist': {'name': 'Explore Band'},
                    },
                  },
                  {
                    'type': 'TRACK',
                    'data': {
                      'id': 7101,
                      'title': 'Tidal Explore Single',
                      'duration': 185,
                      'audioQuality': 'HI_RES_LOSSLESS',
                      'album': {
                        'id': 7001,
                        'title': 'Tidal Explore Hero Album',
                        'cover': 'bbbb1111-2222-3333-4444-555566667777',
                      },
                      'artist': {'name': 'Explore Band'},
                    },
                  },
                ],
              });
            }
            return _sendJson(req.response, HttpStatus.ok, {'items': []});
          }),
        );
        addTearDown(() => server!.close(force: true));

        final base = 'http://127.0.0.1:${server!.port}';
        final credStore = MemorySecureCredentialStore();
        final tidal = TidalProvider(
          credentialStore: credStore,
          authBaseUrl: base,
          tokenBaseUrl: base,
          apiBaseUrl: '$base/v1',
        );
        final manager = StreamingManager(
          credentialStore: credStore,
          providers: <String, StreamingProvider>{
            'tidal': tidal,
            'youtube_music': _NonGuestYouTubeMusicProvider(
              credentialStore: credStore,
              baseUrl: base,
            ),
          },
        );
        addTearDown(manager.dispose);

        await tester.runAsync(() async {
          await manager.initialize();
          await manager.authenticateProvider('tidal', {
            'mode': 'access_token',
            'access_token': 'tok_ui_test',
          });
          await manager.syncProvider('tidal');
        });

        final audioService = MockAudioService();
        addTearDown(audioService.dispose);

        final openedAlbums = <StreamingAlbum>[];
        final playedTracks = <TrackInfo>[];
        final tidalMeta = StreamingProviderMeta.byKind('tidal')!;

        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        // 1. Empty Tidal favorites -> automatically opens on 探索推薦 (tab 0) showing albums & tracks.
        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              body: StreamingServiceView(
                audioService: audioService,
                provider: tidalMeta,
                streamingManager: manager,
                onOpenStreamingAlbum: openedAlbums.add,
                onPlayStreamingTrackWithContext: (track, _) async {
                  playedTracks.add(track);
                },
                onOpenProviderSettings: () {},
              ),
            ),
          ),
        );

        await _pumpUntil(
          tester,
          () => find
              .byKey(const Key('streaming_rec_album_7001'))
              .evaluate()
              .isNotEmpty,
        );

        expect(find.byKey(const Key('streaming_empty_sync_banner')), findsNothing);
        expect(find.text('為你推薦的專輯'), findsOneWidget);
        expect(find.byKey(const Key('streaming_rec_album_7001')), findsOneWidget);
        expect(find.text('Tidal Explore Hero Album'), findsWidgets);
        expect(find.text('Tidal Explore Single'), findsOneWidget);

        // Tapping album invokes onOpenStreamingAlbum.
        await tester.tap(find.byKey(const Key('streaming_rec_album_7001')));
        await tester.pump();
        expect(openedAlbums.length, equals(1));
        expect(openedAlbums.single.id, equals('7001'));

        // Tapping track triggers playback callback.
        final trackFinder = find.byKey(const Key('streaming_track_tidal:7101'));
        await tester.ensureVisible(trackFinder);
        await tester.tap(trackFinder);
        await tester.pump();
        expect(playedTracks.length, equals(1));
        expect(playedTracks.single.id, equals('tidal:7101'));

        // 2. Populated Tidal favorites -> defaults to 收藏曲目 (tab 1).
        hasFavorites = true;
        await tester.runAsync(() => manager.syncProvider('tidal'));

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              body: StreamingServiceView(
                audioService: audioService,
                provider: tidalMeta,
                streamingManager: manager,
                onOpenStreamingAlbum: openedAlbums.add,
                onOpenProviderSettings: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Synced Fav Track'), findsOneWidget);
        expect(find.byKey(const Key('streaming_track_tidal:9101')), findsOneWidget);
      },
    );

    testWidgets(
      'AlbumArtworkView upgrades Tidal 640x640 cover URL to 1280x1280 on large fullResolution hero (size >= 160) and falls back cleanly on 404',
      (WidgetTester tester) async {
        const baseUrl =
            'https://resources.tidal.com/images/abcd/1234/efgh/5678/640x640.jpg';
        expect(
          AlbumArtworkView.maybeUpgradeTidalLargeCoverUrl(
            baseUrl,
            size: 240,
            fullResolution: true,
          ),
          equals(
            'https://resources.tidal.com/images/abcd/1234/efgh/5678/1280x1280.jpg',
          ),
        );
        expect(
          AlbumArtworkView.maybeUpgradeTidalLargeCoverUrl(
            baseUrl,
            size: 48,
            fullResolution: true,
          ),
          equals(baseUrl),
        );
        expect(
          AlbumArtworkView.maybeUpgradeTidalLargeCoverUrl(
            baseUrl,
            size: 240,
            fullResolution: false,
          ),
          equals(baseUrl),
        );

        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
        });

        final imageServer = await tester.runAsync(() async {
          final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          srv.listen((req) async {
            if (req.uri.path.contains('1280x1280')) {
              req.response.statusCode = HttpStatus.notFound;
            } else {
              req.response.statusCode = HttpStatus.ok;
              req.response.headers.contentType = ContentType('image', 'png');
              req.response.add(_valid1x1Png);
            }
            await req.response.close();
          });
          return srv;
        });
        addTearDown(() => imageServer!.close(force: true));

        final requestedImageUrls = <String>[];
        final createdClients = <HttpClient>[];
        debugNetworkImageHttpClientProvider = () {
          final client = HttpClient()
          ..autoUncompress = false
          ..idleTimeout = Duration.zero;
          createdClients.add(client);
          return _TidalInterceptingHttpClient(
            client,
            imageServerPort: imageServer!.port,
            requestedImageUrls: requestedImageUrls,
          );
        };
        addTearDown(() {
          debugNetworkImageHttpClientProvider = null;
          for (final c in createdClients) {
            c.close(force: true);
          }
        });

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: AlbumArtworkView(
                size: 220,
                fullResolution: true,
                track: TrackInfo(
                  id: 'tidal:9900',
                  title: 'Hero Art',
                  artist: 'Artist',
                  album: 'Album',
                  duration: Duration(minutes: 3),
                  format: AudioFormat(
                    codec: AudioCodec.flac,
                    sampleRateHz: 44100,
                    bitDepth: 16,
                    channels: 2,
                  ),
                  filePath: 'tidal:9900',
                  coverUrl: baseUrl,
                ),
              ),
            ),
          ),
        );

        // First tries 1280x1280.jpg; upon 404, falls back to 640x640.jpg.
        await _pumpUntil(
          tester,
          () =>
              requestedImageUrls.any((u) => u.contains('640x640.jpg')) &&
              find
                  .byKey(
                    const ValueKey(
                      'cover_net_https://resources.tidal.com/images/abcd/1234/efgh/5678/640x640.jpg',
                    ),
                  )
                  .evaluate()
                  .isNotEmpty,
        );

        expect(
          requestedImageUrls.first,
          contains('1280x1280.jpg'),
        );
        expect(
          requestedImageUrls.last,
          contains('640x640.jpg'),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        for (final c in createdClients) {
          c.close(force: true);
        }
        await tester.pump(const Duration(seconds: 16));
      },
    );
  });
}
