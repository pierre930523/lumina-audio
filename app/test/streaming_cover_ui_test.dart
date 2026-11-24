import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/podcast_models.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/artwork_palette_service.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/podcast_store.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:lumina_app/ui/artwork/album_artwork_view.dart';
import 'package:lumina_app/ui/artwork/streaming_cover_image.dart';
import 'package:lumina_app/ui/mini_player/floating_capsule.dart';
import 'package:lumina_app/ui/now_playing/now_playing_overlay.dart';
import 'package:lumina_app/ui/podcasts/podcast_detail_page.dart';
import 'package:material_ui/material_ui.dart';

final List<int> _valid1x1Png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

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

TrackInfo _makeYtmTrack({
  required String id,
  required String coverUrl,
  String title = 'Test YTM Track',
}) {
  return TrackInfo(
    id: id,
    title: title,
    artist: 'Test Artist',
    album: 'Test Album',
    duration: const Duration(minutes: 3, seconds: 30),
    format: const AudioFormat(
      codec: AudioCodec.aac,
      sampleRateHz: 48000,
      bitDepth: 16,
      channels: 2,
    ),
    filePath: id,
    coverUrl: coverUrl,
    albumArtUrl: coverUrl,
    providerName: 'YouTube Music',
  );
}

class _CoverDetailAudioService extends MockAudioService {
  CanonicalAlbumDetail? customDetail;

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId) async {
    if (customDetail != null) return customDetail;
    return super.getAlbumDetail(albumId);
  }
}

class _CoverInterceptingHttpClient implements HttpClient {
  final HttpClient _inner;
  final int imageServerPort;
  final List<String> requestedImageUrls;

  _CoverInterceptingHttpClient(
    this._inner, {
    required this.imageServerPort,
    required this.requestedImageUrls,
  });

  Uri _rewriteUri(Uri url) {
    final host = url.host.toLowerCase();
    if (host == 'i.ytimg.com' ||
        host == 'img.youtube.com' ||
        host.endsWith('.googleusercontent.com')) {
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

Future<({
  HttpServer server,
  List<String> requestedUrls,
  List<HttpClient> clients,
})> _setupMockCoverServer(
  WidgetTester tester, {
  required FutureOr<void> Function(HttpRequest req) handler,
}) async {
  final prevOverrides = HttpOverrides.current;
  HttpOverrides.global = null;
  addTearDown(() {
    HttpOverrides.global = prevOverrides;
  });

  final server = (await tester.runAsync(() async {
    final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    srv.listen((req) async {
      try {
        await handler(req);
      } catch (_) {
        try {
          req.response.statusCode = HttpStatus.internalServerError;
          await req.response.close();
        } catch (_) {}
      }
    });
    return srv;
  }))!;
  addTearDown(() => server.close(force: true));

  final requestedUrls = <String>[];
  final createdClients = <HttpClient>[];
  debugNetworkImageHttpClientProvider = () {
    final client = HttpClient()
      ..autoUncompress = false
      ..idleTimeout = Duration.zero;
    createdClients.add(client);
    return _CoverInterceptingHttpClient(
      client,
      imageServerPort: server.port,
      requestedImageUrls: requestedUrls,
    );
  };
  addTearDown(() {
    debugNetworkImageHttpClientProvider = null;
    for (final c in createdClients) {
      c.close(force: true);
    }
  });

  return (server: server, requestedUrls: requestedUrls, clients: createdClients);
}

Future<void> _drainImageRequests(
  WidgetTester tester,
  List<HttpClient> clients,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  for (final c in clients) {
    c.close(force: true);
  }
  await tester.pump(const Duration(seconds: 16));
}

Future<void> _respondPng(HttpRequest req) async {
  req.response.persistentConnection = false;
  req.response.statusCode = HttpStatus.ok;
  req.response.headers.contentType = ContentType('image', 'png');
  req.response.add(_valid1x1Png);
  await req.response.close();
}

Future<void> _respond404(HttpRequest req) async {
  req.response.persistentConnection = false;
  req.response.statusCode = HttpStatus.notFound;
  await req.response.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetCoverUpgradeLogCache();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  tearDown(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  group('AlbumArtworkView scene-tiered sizing & [CoverUpgrade] logs', () {
    testWidgets(
      'fullscreen/large scene (fullResolution: true, size: 320) upgrades w120-h120 to w1200-h1200 with no cacheWidth/Height and logs [CoverUpgrade]',
      (tester) async {
        final origDebugPrint = debugPrint;
        final loggedMessages = <String>[];
        debugPrint = (String? message, {int? wrapWidth}) {
          if (message != null) {
            loggedMessages.add(message);
          }
        };
        addTearDown(() => debugPrint = origDebugPrint);

        final env = await _setupMockCoverServer(tester, handler: _respondPng);

        const rawUrl =
            'https://lh3.googleusercontent.com/ytm_hero_cov=w120-h120-l90-rj';
        const expectedUrl =
            'https://lh3.googleusercontent.com/ytm_hero_cov=w1200-h1200-l90-rj';

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: AlbumArtworkView(
                  size: 320,
                  fullResolution: true,
                  track: _makeYtmTrack(id: 'ytm:hero1', coverUrl: rawUrl),
                ),
              ),
            ),
          ),
        );

        await _pumpUntil(
          tester,
          () =>
              env.requestedUrls.contains(expectedUrl) &&
              find
                  .byKey(const ValueKey('cover_net_$expectedUrl'))
                  .evaluate()
                  .isNotEmpty,
        );

        final img = tester.widget<Image>(
          find.byKey(const ValueKey('cover_net_$expectedUrl')),
        );
        expect(img.image, isA<NetworkImage>());
        expect(img.image, isNot(isA<ResizeImage>()));
        expect((img.image as NetworkImage).url, expectedUrl);
        expect(img.fit, BoxFit.cover);
        expect(img.filterQuality, FilterQuality.high);
        expect(img.isAntiAlias, isTrue);
        expect(img.gaplessPlayback, isTrue);

        expect(
          loggedMessages.any(
            (m) =>
                m.contains('[CoverUpgrade]') &&
                m.contains('w120-h120 -> w1200-h1200') &&
                m.contains(rawUrl) &&
                m.contains(expectedUrl),
          ),
          isTrue,
        );

        await _drainImageRequests(tester, env.clients);
      },
    );

    testWidgets(
      'card (size: 180, fullResolution: false) -> w600-h600-l90-rj and mini-player/list (size: 44, fullResolution: false) -> w300-h300-l90-rj even for pre-upgraded or w60 URLs',
      (tester) async {
        final env = await _setupMockCoverServer(tester, handler: _respondPng);

        const raw120 =
            'https://lh3.googleusercontent.com/ytm_tier_a=w120-h120-l90-rj';
        const pre1200 =
            'https://lh3.googleusercontent.com/ytm_tier_b=w1200-h1200-l90-rj';
        const old60 =
            'https://lh3.googleusercontent.com/ytm_tier_c=w60-h60-l90-rj';

        const cardA =
            'https://lh3.googleusercontent.com/ytm_tier_a=w600-h600-l90-rj';
        const cardB =
            'https://lh3.googleusercontent.com/ytm_tier_b=w600-h600-l90-rj';
        const cardC =
            'https://lh3.googleusercontent.com/ytm_tier_c=w600-h600-l90-rj';

        const miniA =
            'https://lh3.googleusercontent.com/ytm_tier_a=w300-h300-l90-rj';
        const miniB =
            'https://lh3.googleusercontent.com/ytm_tier_b=w300-h300-l90-rj';
        const miniC =
            'https://lh3.googleusercontent.com/ytm_tier_c=w300-h300-l90-rj';

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    AlbumArtworkView(
                      size: 180,
                      fullResolution: false,
                      track: _makeYtmTrack(id: 'ytm:c_a', coverUrl: raw120),
                    ),
                    AlbumArtworkView(
                      size: 180,
                      fullResolution: false,
                      track: _makeYtmTrack(id: 'ytm:c_b', coverUrl: pre1200),
                    ),
                    AlbumArtworkView(
                      size: 180,
                      fullResolution: false,
                      track: _makeYtmTrack(id: 'ytm:c_c', coverUrl: old60),
                    ),
                    AlbumArtworkView(
                      size: 44,
                      fullResolution: false,
                      track: _makeYtmTrack(id: 'ytm:m_a', coverUrl: raw120),
                    ),
                    AlbumArtworkView(
                      size: 44,
                      fullResolution: false,
                      track: _makeYtmTrack(id: 'ytm:m_b', coverUrl: pre1200),
                    ),
                    AlbumArtworkView(
                      size: 44,
                      fullResolution: false,
                      track: _makeYtmTrack(id: 'ytm:m_c', coverUrl: old60),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        await _pumpUntil(
          tester,
          () => [cardA, cardB, cardC, miniA, miniB, miniC].every(
            (u) => find.byKey(ValueKey('cover_net_$u')).evaluate().isNotEmpty,
          ),
        );

        for (final u in [cardA, cardB, cardC, miniA, miniB, miniC]) {
          expect(find.byKey(ValueKey('cover_net_$u')), findsOneWidget);
        }

        await _drainImageRequests(tester, env.clients);
      },
    );
  });

  group('Real HTTP 404 fallback on AlbumArtworkView and StreamingCoverImage', () {
    testWidgets(
      'Case A: AlbumArtworkView with raw hqdefault.jpg?sqp=abc&rs=def tries maxresdefault.jpg -> 404 -> falls back to original hqdefault.jpg query URL',
      (tester) async {
        final env = await _setupMockCoverServer(
          tester,
          handler: (req) async {
            if (req.uri.path.endsWith('/maxresdefault.jpg')) {
              await _respond404(req);
            } else {
              await _respondPng(req);
            }
          },
        );

        const rawUrl =
            'https://i.ytimg.com/vi/oldvid11111/hqdefault.jpg?sqp=abc&rs=def';
        const upgradedUrl =
            'https://i.ytimg.com/vi/oldvid11111/maxresdefault.jpg';

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AlbumArtworkView(
                size: 260,
                fullResolution: true,
                track: _makeYtmTrack(id: 'ytm:old1', coverUrl: rawUrl),
              ),
            ),
          ),
        );

        await _pumpUntil(
          tester,
          () =>
              env.requestedUrls.contains(rawUrl) &&
              find.byKey(const ValueKey('cover_net_$rawUrl')).evaluate().isNotEmpty,
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(env.requestedUrls.first, upgradedUrl);
        expect(env.requestedUrls, contains(rawUrl));
        expect(find.byKey(const ValueKey('cover_net_$rawUrl')), findsOneWidget);
        expect(find.byIcon(Icons.album_rounded), findsNothing);

        await _drainImageRequests(tester, env.clients);
      },
    );

    testWidgets(
      'Case B: AlbumArtworkView with pre-upgraded maxresdefault.jpg tries maxresdefault.jpg -> 404 -> falls back to hqdefault.jpg',
      (tester) async {
        final env = await _setupMockCoverServer(
          tester,
          handler: (req) async {
            if (req.uri.path.endsWith('/maxresdefault.jpg')) {
              await _respond404(req);
            } else {
              await _respondPng(req);
            }
          },
        );

        const preUpgradedUrl =
            'https://i.ytimg.com/vi/oldvid22222/maxresdefault.jpg';
        const fallbackUrl = 'https://i.ytimg.com/vi/oldvid22222/hqdefault.jpg';

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AlbumArtworkView(
                size: 260,
                fullResolution: true,
                track: _makeYtmTrack(id: 'ytm:old2', coverUrl: preUpgradedUrl),
              ),
            ),
          ),
        );

        await _pumpUntil(
          tester,
          () =>
              env.requestedUrls.contains(fallbackUrl) &&
              find
                  .byKey(const ValueKey('cover_net_$fallbackUrl'))
                  .evaluate()
                  .isNotEmpty,
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(env.requestedUrls.first, preUpgradedUrl);
        expect(env.requestedUrls, contains(fallbackUrl));
        expect(
          find.byKey(const ValueKey('cover_net_$fallbackUrl')),
          findsOneWidget,
        );
        expect(find.byIcon(Icons.album_rounded), findsNothing);

        await _drainImageRequests(tester, env.clients);
      },
    );

    testWidgets(
      'Case C: StreamingCoverImage with raw mqdefault.jpg tries maxresdefault.jpg -> 404 -> falls back to mqdefault.jpg without showing fallback widget',
      (tester) async {
        final env = await _setupMockCoverServer(
          tester,
          handler: (req) async {
            if (req.uri.path.endsWith('/maxresdefault.jpg')) {
              await _respond404(req);
            } else {
              await _respondPng(req);
            }
          },
        );

        const rawUrl = 'https://i.ytimg.com/vi/oldvid33333/mqdefault.jpg';
        const upgradedUrl =
            'https://i.ytimg.com/vi/oldvid33333/maxresdefault.jpg';

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StreamingCoverImage(
                url: rawUrl,
                targetSize: 600,
                width: 180,
                height: 180,
                fallbackBuilder: (_) =>
                    const Icon(Icons.broken_image_rounded, key: Key('sc_fb')),
              ),
            ),
          ),
        );

        await _pumpUntil(
          tester,
          () =>
              env.requestedUrls.contains(rawUrl) &&
              find
                  .byKey(const ValueKey('streaming_cover_$rawUrl'))
                  .evaluate()
                  .isNotEmpty,
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(env.requestedUrls.first, upgradedUrl);
        expect(env.requestedUrls, contains(rawUrl));
        expect(
          find.byKey(const ValueKey('streaming_cover_$rawUrl')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('sc_fb')), findsNothing);

        await _drainImageRequests(tester, env.clients);
      },
    );
  });

  group('Scene-tiered page & widget wiring verification', () {
    testWidgets(
      'NowPlayingOverlay hero uses 1200 (no cacheWidth), FloatingCapsule uses 300, AlbumDetailPage uses 1200, and PodcastDetailPage uses 1200 for show cover',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final env = await _setupMockCoverServer(tester, handler: _respondPng);

        const hero1200 =
            'https://lh3.googleusercontent.com/ytm_scene_hero=w1200-h1200-l90-rj';
        const hero300 =
            'https://lh3.googleusercontent.com/ytm_scene_hero=w300-h300-l90-rj';
        const albRaw =
            'https://lh3.googleusercontent.com/ytm_scene_alb=w120-h120-l90-rj';
        const alb1200 =
            'https://lh3.googleusercontent.com/ytm_scene_alb=w1200-h1200-l90-rj';
        const podRaw =
            'https://lh3.googleusercontent.com/ytm_scene_pod=w120-h120-l90-rj';
        const pod1200 =
            'https://lh3.googleusercontent.com/ytm_scene_pod=w1200-h1200-l90-rj';

        final audioSvc = _CoverDetailAudioService()
          ..customDetail = const CanonicalAlbumDetail(
            id: 'ytm-alb-1',
            title: 'Scene Album',
            artistName: 'Scene Artist',
            coverUrl: albRaw,
            versions: [],
          );
        addTearDown(audioSvc.dispose);
        await audioSvc.play(
          track: _makeYtmTrack(id: 'ytm:scene1', coverUrl: hero1200),
        );
        await audioSvc.pause();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  Expanded(
                    child: NowPlayingOverlay(
                      audioService: audioSvc,
                      enableAmbientMotion: false,
                      paletteService: ArtworkPaletteService(
                        urlExtractorOverride: (_) async => null,
                      ),
                      onCollapse: () {},
                    ),
                  ),
                  FloatingCapsuleMiniPlayer(
                    audioService: audioSvc,
                    showLyrics: false,
                    onToggleLyrics: () {},
                  ),
                ],
              ),
            ),
          ),
        );

        await _pumpUntil(
          tester,
          () =>
              find
                  .descendant(
                    of: find.byType(NowPlayingOverlay),
                    matching: find.byKey(const ValueKey('cover_net_$hero1200')),
                  )
                  .evaluate()
                  .isNotEmpty &&
              find
                  .descendant(
                    of: find.byType(FloatingCapsuleMiniPlayer),
                    matching: find.byKey(const ValueKey('cover_net_$hero300')),
                  )
                  .evaluate()
                  .isNotEmpty,
        );

        final heroImg = tester.widget<Image>(
          find.descendant(
            of: find.byType(NowPlayingOverlay),
            matching: find.byKey(const ValueKey('cover_net_$hero1200')),
          ),
        );
        expect(heroImg.image, isA<NetworkImage>());
        expect(heroImg.image, isNot(isA<ResizeImage>()));

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  Expanded(
                    child: AlbumDetailPage(
                      albumId: 'ytm-alb-1',
                      audioService: audioSvc,
                    ),
                  ),
                  Expanded(
                    child: PodcastDetailPage(
                      showId: 'MPSP_scene_pod',
                      audioService: audioSvc,
                      podcastStore: PodcastStore(),
                      initialShow: const PodcastShow(
                        id: 'MPSP_scene_pod',
                        title: 'Scene Podcast',
                        author: 'Host',
                        artworkUrl: podRaw,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

        await _pumpUntil(
          tester,
          () =>
              find
                  .byKey(const ValueKey('cover_net_$alb1200'))
                  .evaluate()
                  .isNotEmpty &&
              find
                  .byKey(const ValueKey('streaming_cover_$pod1200'))
                  .evaluate()
                  .isNotEmpty,
        );

        final albImg = tester.widget<Image>(
          find.byKey(const ValueKey('cover_net_$alb1200')),
        );
        expect(albImg.image, isA<NetworkImage>());
        expect(albImg.image, isNot(isA<ResizeImage>()));

        final podImg = tester.widget<Image>(
          find.byKey(const ValueKey('streaming_cover_$pod1200')),
        );
        expect(podImg.image, isA<NetworkImage>());
        expect(podImg.image, isNot(isA<ResizeImage>()));

        await _drainImageRequests(tester, env.clients);
      },
    );

    testWidgets(
      'NowPlayingOverlay hero uses 1200 even when original track URL was w120',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final env = await _setupMockCoverServer(tester, handler: _respondPng);

        const raw120 =
            'https://lh3.googleusercontent.com/ytm_hero_120=w120-h120-l90-rj';
        const expected1200 =
            'https://lh3.googleusercontent.com/ytm_hero_120=w1200-h1200-l90-rj';

        final audioSvc = MockAudioService();
        addTearDown(audioSvc.dispose);
        await audioSvc.play(
          track: _makeYtmTrack(id: 'ytm:h120', coverUrl: raw120),
        );
        await audioSvc.pause();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NowPlayingOverlay(
                audioService: audioSvc,
                enableAmbientMotion: false,
                paletteService: ArtworkPaletteService(
                  urlExtractorOverride: (_) async => null,
                ),
                onCollapse: () {},
              ),
            ),
          ),
        );

        await _pumpUntil(
          tester,
          () => find
              .byKey(const ValueKey('cover_net_$expected1200'))
              .evaluate()
              .isNotEmpty,
        );

        final img = tester.widget<Image>(
          find.byKey(const ValueKey('cover_net_$expected1200')),
        );
        expect(img.image, isA<NetworkImage>());
        expect(img.image, isNot(isA<ResizeImage>()));

        await _drainImageRequests(tester, env.clients);
      },
    );

    testWidgets(
      'StreamingCoverImage upgrades card/list targetSize, handles null URL fallback, and resets fallback on url change',
      (tester) async {
        final env = await _setupMockCoverServer(
          tester,
          handler: (req) async {
            if (req.uri.path.endsWith('/maxresdefault.jpg')) {
              await _respond404(req);
            } else {
              await _respondPng(req);
            }
          },
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StreamingCoverImage(
                url: null,
                targetSize: 600,
                fallbackBuilder: (_) =>
                    const Icon(Icons.music_off_rounded, key: Key('null_fb')),
              ),
            ),
          ),
        );
        expect(find.byKey(const Key('null_fb')), findsOneWidget);
        expect(env.requestedUrls, isEmpty);

        const gUrl =
            'https://lh3.googleusercontent.com/ytm_card_cov=w120-h120-l90-rj';
        const gCardUrl =
            'https://lh3.googleusercontent.com/ytm_card_cov=w600-h600-l90-rj';

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StreamingCoverImage(
                url: gUrl,
                targetSize: 600,
                width: 160,
                height: 160,
                fallbackBuilder: (_) =>
                    const Icon(Icons.music_off_rounded, key: Key('card_fb')),
              ),
            ),
          ),
        );

        await _pumpUntil(
          tester,
          () => find
              .byKey(const ValueKey('streaming_cover_$gCardUrl'))
              .evaluate()
              .isNotEmpty,
        );
        final cardImg = tester.widget<Image>(
          find.byKey(const ValueKey('streaming_cover_$gCardUrl')),
        );
        expect(cardImg.image, isA<NetworkImage>());
        expect(cardImg.image, isNot(isA<ResizeImage>()));

        // Trigger 404 fallback for oldvid44444, then switch to oldvid55555 and
        // verify _fallbackActive resets cleanly so maxresdefault.jpg is tried first.
        const ytA = 'https://i.ytimg.com/vi/oldvid44444/mqdefault.jpg';
        const ytB = 'https://i.ytimg.com/vi/oldvid55555/hqdefault.jpg';
        const ytBMax = 'https://i.ytimg.com/vi/oldvid55555/maxresdefault.jpg';

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StreamingCoverImage(
                url: ytA,
                targetSize: 300,
                width: 48,
                height: 48,
                fallbackBuilder: (_) =>
                    const Icon(Icons.music_off_rounded, key: Key('yt_fb')),
              ),
            ),
          ),
        );
        await _pumpUntil(
          tester,
          () => find
              .byKey(const ValueKey('streaming_cover_$ytA'))
              .evaluate()
              .isNotEmpty,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StreamingCoverImage(
                url: ytB,
                targetSize: 300,
                width: 48,
                height: 48,
                fallbackBuilder: (_) =>
                    const Icon(Icons.music_off_rounded, key: Key('yt_fb')),
              ),
            ),
          ),
        );
        await _pumpUntil(
          tester,
          () =>
              env.requestedUrls.contains(ytBMax) &&
              find
                  .byKey(const ValueKey('streaming_cover_$ytB'))
                  .evaluate()
                  .isNotEmpty,
        );

        expect(env.requestedUrls.indexOf(ytBMax), lessThan(env.requestedUrls.indexOf(ytB)));

        await _drainImageRequests(tester, env.clients);
      },
    );
  });
}
