import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/home_layout_preset.dart';
import 'package:lumina_app/models/streaming_provider_meta.dart';
import 'package:lumina_app/services/desktop_window_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/playback_persistence_service.dart';
import 'package:lumina_app/services/streaming/providers/deezer_provider.dart';
import 'package:lumina_app/services/streaming/providers/qobuz_provider.dart';
import 'package:lumina_app/services/streaming/providers/youtube_music_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_provider.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:lumina_app/ui/streaming/streaming_service_view.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

class _NonGuestYouTubeMusicProvider extends YouTubeMusicProvider {
  _NonGuestYouTubeMusicProvider({
    required super.credentialStore,
    required super.baseUrl,
  });

  @override
  bool get supportsGuestMode => false;
}

Widget _scaledHost({
  required double scale,
  required Widget child,
}) {
  return MaterialApp(
    theme: LuminaTokens.buildDarkTheme(),
    home: Builder(
      builder: (context) {
        if ((scale - 1.0).abs() < 0.001) {
          return Scaffold(body: child);
        }
        final mq = MediaQuery.of(context);
        final scaledSize = mq.size / scale;
        return MediaQuery(
          data: mq.copyWith(
            size: scaledSize,
            devicePixelRatio: mq.devicePixelRatio * scale,
          ),
          child: Align(
            alignment: Alignment.topLeft,
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: scaledSize.width,
                height: scaledSize.height,
                child: Scaffold(body: child),
              ),
            ),
          ),
        );
      },
    ),
  );
}

Future<HttpServer> _startMockStreamingServer({
  required bool includeFavoriteTracks,
}) async {
  final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  srv.listen((req) async {
    final path = req.uri.path;
    Future<void> replyJson(int status, Object body) async {
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(body));
      await req.response.close();
    }

    if (path == '/user/login') {
      return replyJson(HttpStatus.ok, {
        'user_auth_token': 'qb_tok_stage5',
        'user': {
          'id': 88,
          'display_name': '88qtd6adist',
          'credential': {'label': 'Studio'},
        },
      });
    }
    if (path == '/album/getFeatured') {
      return replyJson(HttpStatus.ok, {
        'albums': {
          'items': [
            {
              'id': 'rec-1',
              'title': 'Castle in the Sky',
              'tracks_count': 12,
              'maximum_sampling_rate': 96,
              'maximum_bit_depth': 24,
              'release_date_original': '2024-05-01',
              'artist': {'name': 'Joe Hisaishi'},
            },
            {
              'id': 'rec-2',
              'title': 'Happy Day In Hell',
              'tracks_count': 9,
              'maximum_sampling_rate': 192,
              'maximum_bit_depth': 24,
              'release_date_original': '2025-01-10',
              'artist': {'name': 'Various Artists'},
            },
          ],
        },
        'tracks': {
          'items': [
            {
              'id': '2001',
              'title': 'Rec Hi-Res Track',
              'duration': 235,
              'maximum_sampling_rate': 96,
              'maximum_bit_depth': 24,
              'performer': {'name': 'Joe Hisaishi'},
              'album': {'title': 'Castle in the Sky', 'image': {}},
            },
          ],
        },
      });
    }
    if (path == '/favorite/getUserFavorites') {
      return replyJson(HttpStatus.ok, {
        'tracks': {
          'items': includeFavoriteTracks
              ? [
                  {
                    'id': '1001',
                    'title': 'Ame wo Matsu',
                    'duration': 295,
                    'maximum_sampling_rate': 96,
                    'maximum_bit_depth': 24,
                    'performer': {'name': 'Minami'},
                    'album': {'title': 'アメヲマツ、', 'image': {}},
                  },
                  {
                    'id': '1002',
                    'title': 'Moonlight Sonata',
                    'duration': 240,
                    'maximum_sampling_rate': 44.1,
                    'maximum_bit_depth': 16,
                    'performer': {'name': 'Berlin Phil'},
                    'album': {'title': 'Classical Studio', 'image': {}},
                  },
                ]
              : <Object>[],
        },
        'albums': {
          'items': [
            {
              'id': 'alb-10',
              'title': 'Master Reference',
              'tracks_count': 8,
              'maximum_sampling_rate': 96,
              'maximum_bit_depth': 24,
              'release_date_original': '2024-03-11',
              'artist': {'name': 'Minami'},
            },
          ],
        },
      });
    }
    if (path == '/playlist/getUserPlaylists') {
      return replyJson(HttpStatus.ok, {
        'playlists': {
          'items': [
            {
              'id': 'pl-10',
              'name': 'Late Night Hi-Res',
              'description': '24-bit Picks',
              'tracks_count': 1,
            },
          ],
        },
      });
    }
    if (path == '/gw') {
      final method = req.uri.queryParameters['method'] ?? '';
      if (method == 'deezer.getUserData') {
        return replyJson(HttpStatus.ok, {
          'results': {
            'USER': {
              'USER_ID': 999,
              'BLOG_NAME': 'Deezer Studio User',
              'OPTIONS': {'web_lossless': true, 'web_hq': true},
            },
          },
        });
      }
      return replyJson(HttpStatus.ok, {
        'results': {'data': <Object>[]},
      });
    }
    if (path == '/chart/0/albums') {
      return replyJson(HttpStatus.ok, {'data': <Object>[]});
    }
    if (path == '/chart/0/tracks') {
      return replyJson(HttpStatus.ok, {'data': <Object>[]});
    }
    if (path.startsWith('/user/') && path.endsWith('/recommendations/albums')) {
      return replyJson(HttpStatus.ok, {'data': <Object>[]});
    }
    if (path.startsWith('/user/') && path.endsWith('/recommendations/tracks')) {
      return replyJson(HttpStatus.ok, {'data': <Object>[]});
    }
    return replyJson(HttpStatus.notFound, {'error': 'Not found: $path'});
  });
  return srv;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Stage 5: Streaming Compact Frosted-Glass Toolbar', () {
    testWidgets(
      'Toolbar stays 52..58px tall with zero RenderFlex overflow at 100% and 150% scale across 1440x900, 1280x800, and 800x600',
      (WidgetTester tester) async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
        });

        final server = (await tester.runAsync(
          () => _startMockStreamingServer(includeFavoriteTracks: true),
        ))!;
        addTearDown(() => server.close(force: true));

        final baseUrl = 'http://127.0.0.1:${server.port}';
        final credStore = MemorySecureCredentialStore();
        final manager = StreamingManager(
          credentialStore: credStore,
          providers: <String, StreamingProvider>{
            'qobuz': QobuzProvider(
              credentialStore: credStore,
              baseUrl: baseUrl,
            ),
            'deezer': DeezerProvider(
              credentialStore: credStore,
              gwUrl: '$baseUrl/gw',
              apiBaseUrl: baseUrl,
            ),
            'youtube_music': _NonGuestYouTubeMusicProvider(
              credentialStore: credStore,
              baseUrl: baseUrl,
            ),
          },
        );
        addTearDown(manager.dispose);

        await tester.runAsync(() async {
          await manager.initialize();
          await manager.authenticateProvider('qobuz', {
            'mode': 'credentials',
            'email': 'u@test.com',
            'password': 'pw',
            'app_id': '123456',
            'app_secret': 'sec',
          });
          await manager.syncProvider('qobuz');
          await manager.refreshRecommendationsFor('qobuz', force: true);
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (manager.isAnyRecommendationLoading &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        });

        final audioService = MockAudioService();
        addTearDown(audioService.dispose);
        final qobuzMeta = StreamingProviderMeta.byKind('qobuz')!;

        const sizes = <Size>[
          Size(1440, 900),
          Size(1280, 800),
          Size(800, 600),
        ];

        for (final size in sizes) {
          for (final scale in const [1.0, 1.5]) {
            tester.view.devicePixelRatio = 1.0;
            tester.view.physicalSize = size;
            addTearDown(tester.view.reset);

            await tester.pumpWidget(
              _scaledHost(
                scale: scale,
                child: StreamingServiceView(
                  audioService: audioService,
                  provider: qobuzMeta,
                  streamingManager: manager,
                  activeTrackId: 'qobuz:1001',
                  onOpenProviderSettings: () {},
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: 'Overflow or error at size=$size scale=$scale',
            );

            final toolbarFinder = find.byKey(
              const Key('streaming_compact_toolbar'),
            );
            expect(toolbarFinder, findsOneWidget);
            final toolbarSize = tester.getSize(toolbarFinder);
            expect(
              toolbarSize.height,
              inInclusiveRange(52.0, 58.0),
              reason: 'Toolbar height out of range at size=$size scale=$scale',
            );

            expect(find.byKey(const Key('streaming_tab_explore')), findsOneWidget);
            expect(find.byKey(const Key('streaming_tab_tracks')), findsOneWidget);
            expect(find.byKey(const Key('streaming_tab_playlists')), findsOneWidget);
            expect(find.byKey(const Key('streaming_tab_albums')), findsOneWidget);
            expect(find.byKey(const Key('btn_sync_streaming_provider')), findsOneWidget);
            expect(find.byKey(const Key('btn_streaming_open_settings')), findsOneWidget);
          }
        }
      },
    );

    testWidgets(
      'HomeScreen at 1280x800 and 150% scale (with sidebar) renders StreamingServiceView single-line toolbar with zero overflow and supports multi-provider switcher',
      (WidgetTester tester) async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
        });

        final tempDir = Directory.systemTemp.createTempSync('stage5_home_');
        addTearDown(() {
          try {
            tempDir.deleteSync(recursive: true);
          } catch (_) {}
        });

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('lumina/window'), (
              _,
            ) async {
              return null;
            });
        addTearDown(() {
          DesktopWindowController.instance = null;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('lumina/window'),
                null,
              );
        });

        final server = (await tester.runAsync(
          () => _startMockStreamingServer(includeFavoriteTracks: true),
        ))!;
        addTearDown(() => server.close(force: true));

        final baseUrl = 'http://127.0.0.1:${server.port}';
        final credStore = MemorySecureCredentialStore();
        final manager = StreamingManager(
          credentialStore: credStore,
          providers: <String, StreamingProvider>{
            'qobuz': QobuzProvider(
              credentialStore: credStore,
              baseUrl: baseUrl,
            ),
            'deezer': DeezerProvider(
              credentialStore: credStore,
              gwUrl: '$baseUrl/gw',
              apiBaseUrl: baseUrl,
            ),
            'youtube_music': _NonGuestYouTubeMusicProvider(
              credentialStore: credStore,
              baseUrl: baseUrl,
            ),
          },
        );
        addTearDown(manager.dispose);

        await tester.runAsync(() async {
          await manager.initialize();
          await manager.authenticateProvider('qobuz', {
            'mode': 'credentials',
            'email': 'u@test.com',
            'password': 'pw',
            'app_id': '123456',
            'app_secret': 'sec',
          });
          await manager.authenticateProvider('deezer', {
            'mode': 'arl',
            'arl': 'arl_sample_999',
          });
          await manager.syncProvider('qobuz');
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (manager.isAnyRecommendationLoading &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        });

        final audioService = MockAudioService();
        addTearDown(audioService.dispose);
        final scaleCtrl = UiScaleController(
          initialHomeLayoutPreset: HomeLayoutPreset.classic,
          prefsFileOverride: File(
            '${tempDir.path}${Platform.pathSeparator}ui_prefs.json',
          ),
        );
        scaleCtrl.setScale(1.5);
        addTearDown(scaleCtrl.dispose);

        final persistSvc = PlaybackPersistenceService(
          prefsFileOverride: File(
            '${tempDir.path}${Platform.pathSeparator}playback.json',
          ),
        );
        addTearDown(persistSvc.dispose);

        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _scaledHost(
            scale: 1.5,
            child: HomeScreen(
              audioService: audioService,
              uiScaleController: scaleCtrl,
              streamingManager: manager,
              playbackPersistenceService: persistSvc,
            ),
          ),
        );
        await tester.pump();
        for (var step = 0; step < 60; step++) {
          if (find.byKey(const Key('nav_streaming_qobuz')).evaluate().isNotEmpty &&
              !manager.isAnyRecommendationLoading) {
            break;
          }
          await tester.pump(const Duration(milliseconds: 25));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 25));
        }
        await tester.pump(const Duration(milliseconds: 250));

        final qobuzNav = find.byKey(const Key('nav_streaming_qobuz'));
        await tester.ensureVisible(qobuzNav);
        await tester.pump();
        await tester.tap(qobuzNav);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('streaming_service_view_qobuz')), findsOneWidget);

        final toolbarSize = tester.getSize(
          find.byKey(const Key('streaming_compact_toolbar')),
        );
        expect(toolbarSize.height, inInclusiveRange(52.0, 58.0));

        expect(find.byKey(const Key('btn_streaming_filter_toggle')), findsOneWidget);
        expect(find.byKey(const Key('streaming_search_input')), findsNothing);

        await tester.tap(find.byKey(const Key('btn_streaming_filter_toggle')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('streaming_search_input')), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('streaming_search_input')),
          'Moonlight',
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byKey(const Key('streaming_track_qobuz:1002')), findsOneWidget);
        expect(find.byKey(const Key('streaming_track_qobuz:1001')), findsNothing);

        await tester.tap(find.byKey(const Key('btn_streaming_filter_toggle')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('streaming_tab_tracks')), findsOneWidget);

        expect(find.byKey(const Key('streaming_provider_switcher')), findsOneWidget);
        await tester.tap(find.byKey(const Key('streaming_provider_switcher')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byKey(const Key('streaming_switch_item_deezer')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('streaming_service_view_deezer')), findsOneWidget);
      },
    );

    testWidgets(
      'Empty library uses compact horizontal sync banner and keeps recommendations browsable, plus single-provider hides switcher',
      (WidgetTester tester) async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
        });

        final server = (await tester.runAsync(
          () => _startMockStreamingServer(includeFavoriteTracks: false),
        ))!;
        addTearDown(() => server.close(force: true));

        final baseUrl = 'http://127.0.0.1:${server.port}';
        final credStore = MemorySecureCredentialStore();
        final manager = StreamingManager(
          credentialStore: credStore,
          providers: <String, StreamingProvider>{
            'qobuz': QobuzProvider(
              credentialStore: credStore,
              baseUrl: baseUrl,
            ),
            'youtube_music': _NonGuestYouTubeMusicProvider(
              credentialStore: credStore,
              baseUrl: baseUrl,
            ),
          },
        );
        addTearDown(manager.dispose);

        await tester.runAsync(() async {
          await manager.initialize();
          await manager.authenticateProvider('qobuz', {
            'mode': 'credentials',
            'email': 'u@test.com',
            'password': 'pw',
            'app_id': '123456',
            'app_secret': 'sec',
          });
          await manager.refreshRecommendationsFor('qobuz', force: true);
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (manager.isAnyRecommendationLoading &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        });

        final audioService = MockAudioService();
        addTearDown(audioService.dispose);
        final qobuzMeta = StreamingProviderMeta.byKind('qobuz')!;

        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _scaledHost(
            scale: 1.0,
            child: StreamingServiceView(
              audioService: audioService,
              provider: qobuzMeta,
              streamingManager: manager,
              onOpenProviderSettings: () {},
              onSwitchStreamingProvider: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        expect(find.byKey(const Key('streaming_provider_switcher')), findsNothing);

        final bannerFinder = find.byKey(const Key('streaming_empty_sync_banner'));
        expect(bannerFinder, findsOneWidget);
        expect(tester.getSize(bannerFinder).height, lessThan(110.0));

        expect(find.byKey(const Key('streaming_recommended_albums_strip')), findsOneWidget);
        expect(find.byKey(const Key('streaming_rec_strip_album_rec-1')), findsOneWidget);
        expect(find.text('24-bit Hi-Res'), findsWidgets);
        expect(find.byKey(const Key('streaming_track_qobuz:2001')), findsOneWidget);
        expect(find.text('03:55'), findsOneWidget);
      },
    );
  });
}
