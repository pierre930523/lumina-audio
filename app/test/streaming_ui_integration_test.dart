import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/models/streaming_provider_meta.dart';
import 'package:lumina_app/services/desktop_window_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/playback_persistence_service.dart';
import 'package:lumina_app/services/streaming/providers/apple_music_provider.dart';
import 'package:lumina_app/services/streaming/providers/deezer_provider.dart';
import 'package:lumina_app/services/streaming/providers/qobuz_provider.dart';
import 'package:lumina_app/services/streaming/providers/tidal_provider.dart';
import 'package:lumina_app/services/streaming/providers/youtube_music_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_provider.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:lumina_app/ui/mini_player/floating_capsule.dart';
import 'package:lumina_app/ui/now_playing/now_playing_overlay.dart';
import 'package:lumina_app/ui/settings/providers_and_remote_panel.dart';
import 'package:lumina_app/ui/streaming/streaming_service_view.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

class _TrackingMockAudioService extends MockAudioService {
  bool disposedCalled = false;
  int playStreamUrlCalls = 0;
  String? lastStreamUrl;
  Map<String, String>? lastStreamHeaders;
  String? lastHintExtension;
  Duration livePositionOverride = const Duration(seconds: 73);

  @override
  Future<void> playStreamUrl({
    required TrackInfo track,
    required String streamUrl,
    Map<String, String> headers = const {},
    String? hintExtension,
  }) async {
    playStreamUrlCalls++;
    lastStreamUrl = streamUrl;
    lastStreamHeaders = headers;
    lastHintExtension = hintExtension;
    await super.playStreamUrl(
      track: track,
      streamUrl: streamUrl,
      headers: headers,
      hintExtension: hintExtension,
    );
  }

  @override
  Future<Map<String, dynamic>?> getPlaybackState() async {
    final base = await super.getPlaybackState();
    return <String, dynamic>{
      ...?base,
      'position_ms': livePositionOverride.inMilliseconds,
    };
  }

  @override
  void dispose() {
    disposedCalled = true;
    super.dispose();
  }
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
  await tester.pump(const Duration(milliseconds: 100));
}

Widget _scaledMediaWrapper({
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProvidersAndRemotePanel & StreamingLoginDialog Integration', () {
    testWidgets(
      '4 UI states (disconnected, authenticating+cancel, connected, error) & StreamingLoginDialog 401 vs 200 + Apple Music DRM notice',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 900);
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        var qobuzReturn401 = true;

        final server = (await tester.runAsync(() async {
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
              if (qobuzReturn401) {
                return replyJson(HttpStatus.unauthorized, {
                  'status': 'error',
                  'message': 'Invalid Qobuz credentials (401)',
                });
              }
              return replyJson(HttpStatus.ok, {
                'user_auth_token': 'qb_ok_token',
                'user': {
                  'id': 101,
                  'display_name': 'Studio Audiophile',
                  'credential': {'label': 'Sublime Hi-Res'},
                },
              });
            }

            if (path == '/v1/oauth2/device_authorization') {
              return replyJson(HttpStatus.ok, {
                'deviceCode': 'dev_code_123',
                'userCode': 'TIDAL-9988',
                'verificationUri': 'http://127.0.0.1:${srv.port}/device',
                'expiresIn': 300,
                'interval': 1,
              });
            }

            if (path == '/v1/oauth2/token') {
              return replyJson(HttpStatus.unauthorized, {
                'error': 'authorization_pending',
              });
            }

            if (path == '/v1/me/storefront') {
              return replyJson(HttpStatus.unauthorized, {
                'errors': [
                  {'detail': 'Music-User-Token expired'},
                ],
              });
            }

            return replyJson(HttpStatus.notFound, {'error': 'Not found'});
          });
          return srv;
        }))!;
        addTearDown(() => server.close(force: true));

        final baseUrl = 'http://127.0.0.1:${server.port}';
        final credStore = MemorySecureCredentialStore();
        // Pre-seed Apple Music expired credentials so initialize() moves it to error state!
        await credStore.write(
          'streaming:apple_music',
          jsonEncode({
            'developer_token': 'dev_jwt_old',
            'music_user_token': 'expired_tok',
            'storefront': 'tw',
          }),
        );

        final manager = StreamingManager(
          credentialStore: credStore,
          providers: <String, StreamingProvider>{
            'apple_music': AppleMusicProvider(
              credentialStore: credStore,
              apiBaseUrl: baseUrl,
            ),
            'youtube_music': YouTubeMusicProvider(
              credentialStore: credStore,
              baseUrl: baseUrl,
            ),
            'qobuz': QobuzProvider(
              credentialStore: credStore,
              baseUrl: baseUrl,
            ),
            'tidal': TidalProvider(
              credentialStore: credStore,
              authBaseUrl: baseUrl,
              tokenBaseUrl: baseUrl,
              apiBaseUrl: baseUrl,
              urlOpener: (_) async => true,
            ),
            'deezer': DeezerProvider(
              credentialStore: credStore,
              gwUrl: '$baseUrl/gw',
              apiBaseUrl: baseUrl,
            ),
          },
        );
        await tester.runAsync(() => manager.initialize());
        addTearDown(manager.dispose);

        final audioService = MockAudioService();
        addTearDown(audioService.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              body: ProvidersAndRemotePanel(
                audioService: audioService,
                streamingManager: manager,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. Disconnected state shows 登入
        expect(find.byKey(const Key('btn_signin_qobuz')), findsOneWidget);
        expect(find.byKey(const Key('btn_signin_youtube_music')), findsOneWidget);

        // 2. Error state shows red dot + real error + 重新登入
        expect(find.byKey(const Key('btn_relogin_apple_music')), findsOneWidget);
        expect(find.textContaining('Music-User-Token expired'), findsOneWidget);

        // Open Apple Music login dialog via 重新登入 & verify FairPlay DRM notice
        await tester.tap(find.byKey(const Key('btn_relogin_apple_music')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('apple_music_drm_notice')), findsOneWidget);
        expect(find.textContaining('FairPlay DRM'), findsWidgets);
        await tester.tap(find.byKey(const Key('btn_dialog_cancel_login')));
        await tester.pumpAndSettle();

        // 3. StreamingLoginDialog 401 failure keeps dialog open and displays red error, then 200 succeeds
        await tester.tap(find.byKey(const Key('btn_signin_qobuz')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('btn_toggle_manual_token_section')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('qobuz_byok_toggle')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('input_qobuz_app_id')),
          'app_id_1',
        );
        await tester.enterText(
          find.byKey(const Key('input_qobuz_email')),
          'user@example.com',
        );
        await tester.enterText(
          find.byKey(const Key('input_qobuz_password')),
          'wrong_pass',
        );
        await tester.tap(find.byKey(const Key('btn_dialog_submit_login')));
        await _pumpUntil(
          tester,
          () => find.byKey(const Key('login_dialog_error')).evaluate().isNotEmpty,
        );

        // Honest 401 error box visible and dialog remains open
        expect(find.byKey(const Key('streaming_login_dialog_qobuz')), findsOneWidget);
        expect(find.byKey(const Key('login_dialog_error')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('login_dialog_error')),
            matching: find.textContaining('Invalid Qobuz credentials (401)'),
          ),
          findsOneWidget,
        );

        // Switch server to 200 and submit again
        qobuzReturn401 = false;
        await tester.enterText(
          find.byKey(const Key('input_qobuz_password')),
          'right_pass',
        );
        await tester.tap(find.byKey(const Key('btn_dialog_submit_login')));
        await _pumpUntil(
          tester,
          () => find.byKey(const Key('streaming_login_dialog_qobuz')).evaluate().isEmpty,
        );
        await tester.pumpAndSettle();

        // Dialog closed & connected state displays account name, plan tier, and buttons
        expect(find.byKey(const Key('streaming_login_dialog_qobuz')), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const Key('provider_row_qobuz')),
            matching: find.textContaining('Studio Audiophile'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('provider_row_qobuz')),
            matching: find.textContaining('Sublime Hi-Res'),
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('btn_sync_qobuz')), findsOneWidget);
        expect(find.byKey(const Key('btn_settings_qobuz')), findsOneWidget);
        expect(find.byKey(const Key('btn_logout_qobuz')), findsOneWidget);
        expect(find.byKey(const Key('btn_activate_provider_qobuz')), findsOneWidget);

        // 4. Authenticating state: spinner + 連線中... + 取消 button calling cancelLogin
        Object? capturedCancelError;
        var authFinished = false;
        final authFuture = manager.authenticateProvider('tidal', {
          'mode': 'device_code',
          'client_id': 'tidal_client_1',
        }).catchError((Object e) {
          capturedCancelError = e;
        }).whenComplete(() {
          authFinished = true;
        });
        await _pumpUntil(
          tester,
          () =>
              find.text('連線中...').evaluate().isNotEmpty &&
              find.byKey(const Key('btn_cancel_signin_tidal')).evaluate().isNotEmpty,
        );

        expect(find.text('連線中...'), findsOneWidget);
        expect(find.byKey(const Key('btn_cancel_signin_tidal')), findsOneWidget);

        await tester.ensureVisible(
          find.byKey(const Key('btn_cancel_signin_tidal')),
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('btn_cancel_signin_tidal')));
        await tester.pump();
        await _pumpUntil(tester, () => authFinished);
        await authFuture;
        expect(capturedCancelError, isA<StreamingException>());
        expect((capturedCancelError! as StreamingException).isCancelled, isTrue);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('btn_signin_tidal')), findsOneWidget);
      },
    );
  });

  group('StreamingServiceView, Badges & 100%/150% Scale Integration', () {
    testWidgets(
      'StreamingServiceView tabs (tracks, playlists, albums, search) and platform badges render with zero overflow at 100% and 150% scale',
      (WidgetTester tester) async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
        });

        final server = (await tester.runAsync(() async {
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
                'user_auth_token': 'qb_tok_1',
                'user': {
                  'id': 77,
                  'display_name': 'Qobuz Master',
                  'credential': {'label': 'Studio'},
                },
              });
            }
            if (path == '/favorite/getUserFavorites') {
              return replyJson(HttpStatus.ok, {
                'tracks': {
                  'items': [
                    {
                      'id': '1001',
                      'title': 'Hi-Res Symphony',
                      'duration': 240,
                      'maximum_sampling_rate': 192,
                      'maximum_bit_depth': 24,
                      'performer': {'name': 'Berlin Phil'},
                      'album': {'title': 'Masterworks', 'image': {}},
                    },
                  ],
                },
                'albums': {
                  'items': [
                    {
                      'id': 'alb-1',
                      'title': 'Masterworks',
                      'tracks_count': 10,
                      'maximum_sampling_rate': 192,
                      'maximum_bit_depth': 24,
                      'release_date_original': '2024-01-01',
                      'artist': {'name': 'Berlin Phil'},
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
                      'id': 'pl-1',
                      'name': 'Audiophile Reference',
                      'description': '24-bit FLAC Showcase',
                      'tracks_count': 1,
                    },
                  ],
                },
              });
            }
            if (path == '/playlist/get') {
              return replyJson(HttpStatus.ok, {
                'id': 'pl-1',
                'tracks': {
                  'items': [
                    {
                      'id': '1002',
                      'title': 'Playlist Reference Track',
                      'duration': 210,
                      'maximum_sampling_rate': 96,
                      'maximum_bit_depth': 24,
                      'performer': {'name': 'Jazz Trio'},
                      'album': {'title': 'Reference Vol.1', 'image': {}},
                    },
                  ],
                },
              });
            }
            if (path == '/catalog/search') {
              return replyJson(HttpStatus.ok, {
                'tracks': {
                  'items': [
                    {
                      'id': '1003',
                      'title': 'Searched Nocturne',
                      'duration': 195,
                      'maximum_sampling_rate': 96,
                      'maximum_bit_depth': 24,
                      'performer': {'name': 'Chopin Ensemble'},
                      'album': {'title': 'Nocturnes', 'image': {}},
                    },
                  ],
                },
                'albums': {'items': []},
                'playlists': {'items': []},
              });
            }
            return replyJson(HttpStatus.notFound, {'error': 'Not found'});
          });
          return srv;
        }))!;
        addTearDown(() => server.close(force: true));

        final baseUrl = 'http://127.0.0.1:${server.port}';
        final credStore = MemorySecureCredentialStore();
        final qobuz = QobuzProvider(
          credentialStore: credStore,
          baseUrl: baseUrl,
        );
        final manager = StreamingManager(
          credentialStore: credStore,
          providers: <String, StreamingProvider>{'qobuz': qobuz},
        );
        addTearDown(manager.dispose);

        await tester.runAsync(() async {
          await manager.authenticateProvider('qobuz', {
            'mode': 'credentials',
            'email': 'u@test.com',
            'password': 'pw',
            'app_id': '123456',
            'app_secret': 'sec',
          });
          await manager.syncProvider('qobuz');
        });

        final audioService = _TrackingMockAudioService();
        addTearDown(audioService.dispose);
        await audioService.play(
          track: const TrackInfo(
            id: 'qobuz:1001',
            title: 'Hi-Res Symphony',
            artist: 'Berlin Phil',
            album: 'Masterworks',
            duration: Duration(minutes: 4),
            format: AudioFormat(
              codec: AudioCodec.flac,
              sampleRateHz: 192000,
              bitDepth: 24,
              channels: 2,
            ),
            providerName: 'Qobuz',
          ),
        );

        final qobuzMeta = StreamingProviderMeta.byKind('qobuz')!;
        TrackInfo? tappedTrack;

        for (final scale in const [1.0, 1.5]) {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = const Size(1280, 900);
          addTearDown(tester.view.reset);

          await tester.pumpWidget(
            _scaledMediaWrapper(
              scale: scale,
              child: Column(
                children: [
                  Expanded(
                    child: StreamingServiceView(
                      audioService: audioService,
                      provider: qobuzMeta,
                      streamingManager: manager,
                      activeTrackId: 'qobuz:1001',
                      onOpenProviderSettings: () {},
                      onPlayStreamingTrack: (t) async {
                        tappedTrack = t;
                      },
                    ),
                  ),
                  FloatingCapsuleMiniPlayer(
                    audioService: audioService,
                    showLyrics: false,
                    onToggleLyrics: () {},
                  ),
                ],
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          // Real account info + track + capsule platform badge
          expect(find.textContaining('Qobuz Master'), findsOneWidget);
          expect(find.byKey(const Key('streaming_track_qobuz:1001')), findsOneWidget);
          expect(find.byKey(const Key('capsule_provider_badge_qobuz')), findsOneWidget);

          if (scale == 1.0) {
            await tester.tap(find.byKey(const Key('streaming_track_qobuz:1001')));
            await tester.pumpAndSettle();
            expect(tappedTrack?.id, 'qobuz:1001');

            // Playlists tab -> load playlist tracks
            await tester.tap(find.byKey(const Key('streaming_tab_playlists')));
            await tester.pumpAndSettle();
            expect(find.byKey(const Key('streaming_playlist_pl-1')), findsOneWidget);
            await tester.tap(find.byKey(const Key('streaming_playlist_pl-1')));
            await _pumpUntil(
              tester,
              () => find.byKey(const Key('streaming_track_qobuz:1002')).evaluate().isNotEmpty,
            );
            expect(find.byKey(const Key('streaming_track_qobuz:1002')), findsOneWidget);
            await tester.tap(find.byKey(const Key('btn_back_to_playlists')));
            await tester.pumpAndSettle();

            // Albums tab
            await tester.tap(find.byKey(const Key('streaming_tab_albums')));
            await tester.pumpAndSettle();
            expect(find.byKey(const Key('streaming_album_alb-1')), findsOneWidget);
            expect(find.textContaining('Masterworks'), findsOneWidget);

            // Remote search tab
            await tester.tap(find.byKey(const Key('streaming_tab_search')));
            await tester.pumpAndSettle();
            await tester.enterText(
              find.byKey(const Key('streaming_remote_search_input')),
              'Nocturne',
            );
            await tester.tap(find.byKey(const Key('btn_streaming_remote_search')));
            await _pumpUntil(
              tester,
              () => find.byKey(const Key('streaming_track_qobuz:1003')).evaluate().isNotEmpty,
            );
            expect(find.byKey(const Key('streaming_track_qobuz:1003')), findsOneWidget);
          }
        }

        // NowPlayingOverlay platform badge renders cleanly at narrow & normal widths
        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              body: SizedBox(
                width: 480,
                height: 760,
                child: NowPlayingOverlay(
                  audioService: audioService,
                  onCollapse: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('now_playing_provider_badge_qobuz')), findsOneWidget);
      },
    );
  });

  group('HomeScreen Tray Close Interception & Clean Exit Persistence', () {
    late Directory tempDir;
    late File prefsFile;
    late File playbackFile;
    late List<MethodCall> windowCalls;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('home_tray_close_test_');
      prefsFile = File('${tempDir.path}${Platform.pathSeparator}ui_prefs.json');
      playbackFile = File(
        '${tempDir.path}${Platform.pathSeparator}playback_state.json',
      );
      windowCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('lumina/window'), (
            MethodCall call,
          ) async {
            windowCalls.add(call);
            return null;
          });
    });

    tearDown(() {
      DesktopWindowController.instance = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('lumina/window'), null);
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    testWidgets(
      'minimizeToTrayOnClose: true hides to tray without stopping audio, pauses NowPlayingOverlay tickers, and restores on tray click',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.reset);

        final audioService = _TrackingMockAudioService();
        addTearDown(audioService.dispose);
        await audioService.play(track: audioService.queue[1]);

        final scaleCtrl = UiScaleController(prefsFileOverride: prefsFile);
        scaleCtrl.setMinimizeToTrayOnClose(true);
        addTearDown(scaleCtrl.dispose);

        final persistSvc = PlaybackPersistenceService(
          prefsFileOverride: playbackFile,
        );
        addTearDown(persistSvc.dispose);

        final winCtrl = DesktopWindowController(isSupportedOverride: true);
        final credStore = MemorySecureCredentialStore();
        final streamingMgr = StreamingManager(credentialStore: credStore);
        addTearDown(streamingMgr.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: audioService,
              uiScaleController: scaleCtrl,
              windowController: winCtrl,
              streamingManager: streamingMgr,
              playbackPersistenceService: persistSvc,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(windowCalls.any((c) => c.method == 'setPreventClose'), isTrue);
        expect(windowCalls.any((c) => c.method == 'trayInit'), isTrue);

        // Expand NowPlayingOverlay first so we verify isVisible flips false when hidden to tray
        await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
        await tester.pumpAndSettle();
        var overlayWidget = tester.widget<NowPlayingOverlay>(
          find.byKey(const Key('now_playing_stage')),
        );
        expect(overlayWidget.isVisible, isTrue);

        // Trigger close interception
        windowCalls.clear();
        await winCtrl.handleIncomingCall(const MethodCall('onWindowClose'));
        await tester.pump();

        expect(windowCalls.any((c) => c.method == 'hide'), isTrue);
        expect(windowCalls.any((c) => c.method == 'destroy'), isFalse);
        expect(audioService.windowMinimized, isTrue);
        expect(audioService.disposedCalled, isFalse);
        expect(audioService.currentState.status, PlaybackStatus.playing);

        overlayWidget = tester.widget<NowPlayingOverlay>(
          find.byKey(const Key('now_playing_stage')),
        );
        expect(overlayWidget.isVisible, isFalse);

        // Tray menu playback action works while hidden
        await winCtrl.handleIncomingCall(
          const MethodCall('onTrayMenuAction', 'toggle_play_pause'),
        );
        await tester.pump();
        expect(audioService.currentState.status, PlaybackStatus.paused);

        // Restore via tray click
        windowCalls.clear();
        await winCtrl.handleIncomingCall(const MethodCall('onTrayClick'));
        await tester.pumpAndSettle();

        expect(windowCalls.any((c) => c.method == 'show'), isTrue);
        expect(windowCalls.any((c) => c.method == 'focus'), isTrue);
        expect(audioService.windowMinimized, isFalse);
        overlayWidget = tester.widget<NowPlayingOverlay>(
          find.byKey(const Key('now_playing_stage')),
        );
        expect(overlayWidget.isVisible, isTrue);
      },
    );

    testWidgets(
      'minimizeToTrayOnClose: false queries live position, flushes persistence atomically, disposes audio, and destroys tray & window',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 800);
        addTearDown(tester.view.reset);

        final audioService = _TrackingMockAudioService();
        addTearDown(audioService.dispose);
        await audioService.play(track: audioService.queue[1]);
        audioService.livePositionOverride = const Duration(seconds: 94);

        final scaleCtrl = UiScaleController(prefsFileOverride: prefsFile);
        scaleCtrl.setMinimizeToTrayOnClose(false);
        addTearDown(scaleCtrl.dispose);

        final persistSvc = PlaybackPersistenceService(
          prefsFileOverride: playbackFile,
        );
        addTearDown(persistSvc.dispose);

        final winCtrl = DesktopWindowController(isSupportedOverride: true);
        final credStore = MemorySecureCredentialStore();
        final streamingMgr = StreamingManager(credentialStore: credStore);
        addTearDown(streamingMgr.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: audioService,
              uiScaleController: scaleCtrl,
              windowController: winCtrl,
              streamingManager: streamingMgr,
              playbackPersistenceService: persistSvc,
            ),
          ),
        );
        await tester.pumpAndSettle();

        windowCalls.clear();
        await winCtrl.handleIncomingCall(const MethodCall('onWindowClose'));
        await _pumpUntil(
          tester,
          () =>
              audioService.disposedCalled &&
              windowCalls.any((c) => c.method == 'destroy'),
        );

        expect(audioService.disposedCalled, isTrue);
        expect(windowCalls.any((c) => c.method == 'trayDestroy'), isTrue);
        expect(windowCalls.any((c) => c.method == 'destroy'), isTrue);
        expect(windowCalls.any((c) => c.method == 'hide'), isFalse);

        // Verify live position was flushed to disk BEFORE exit
        expect(playbackFile.existsSync(), isTrue);
        final saved =
            jsonDecode(playbackFile.readAsStringSync()) as Map<String, dynamic>;
        expect(saved['position_ms'], 94000);
        expect(saved['track']['id'], audioService.queue[1].id);
      },
    );
  });
}
