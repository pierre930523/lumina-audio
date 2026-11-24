import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/streaming/providers/apple_music_provider.dart';
import 'package:lumina_app/services/streaming/providers/deezer_provider.dart';
import 'package:lumina_app/services/streaming/providers/qobuz_provider.dart';
import 'package:lumina_app/services/streaming/providers/tidal_provider.dart';
import 'package:lumina_app/services/streaming/providers/youtube_music_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/webview_auth_service.dart';
import 'package:lumina_app/ui/settings/providers_and_remote_panel.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

class _FakeWebViewAuthService implements WebViewAuthService {
  bool available;
  int closeCalls = 0;
  final List<WebViewAuthRequest> openedRequests = [];
  Future<WebViewAuthResult> Function(WebViewAuthRequest request)? onOpen;

  _FakeWebViewAuthService({this.available = true});

  @override
  Future<bool> isWebView2Available() async => available;

  @override
  Future<WebViewAuthResult> openAuthWindow(WebViewAuthRequest request) async {
    openedRequests.add(request);
    if (onOpen != null) {
      return onOpen!(request);
    }
    return const WebViewAuthResult(captured: false, cancelled: true);
  }

  @override
  Future<void> closeAuthWindow() async {
    closeCalls++;
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  const maxSteps = 100;
  for (var step = 0; step < maxSteps && !condition(); step++) {
    await tester.pump(const Duration(milliseconds: 25));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 25));
  }
  if (!condition()) {
    throw TimeoutException('Timed out waiting for UI condition after $timeout');
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WebViewAuthService presets & payload extraction', () {
    test('builds valid WebViewAuthRequest presets and extracts credentials for all 5 services', () {
      final ytmReq = WebViewAuthRequest.presetFor('youtube_music');
      expect(ytmReq.initialUrl, 'https://music.youtube.com');
      expect(ytmReq.requiredHostSubstring, 'music.youtube.com');
      expect(ytmReq.excludedUrlSubstrings, contains('accounts.google.com'));
      expect(
        buildAuthParamsFromWebViewResult(
          'youtube_music',
          const WebViewAuthResult(
            captured: true,
            cancelled: false,
            cookieHeader: 'SAPISID=sap123; SID=sid123',
            cookies: {'SAPISID': 'sap123'},
          ),
        ),
        {'mode': 'cookie', 'cookie': 'SAPISID=sap123; SID=sid123'},
      );

      final deezerReq = WebViewAuthRequest.presetFor('deezer');
      expect(deezerReq.initialUrl, 'https://www.deezer.com/login');
      expect(deezerReq.excludedUrlSubstrings, containsAll(['/login', '/signup']));
      expect(
        buildAuthParamsFromWebViewResult(
          'deezer',
          const WebViewAuthResult(
            captured: true,
            cancelled: false,
            cookies: {'arl': 'arl_abc'},
          ),
        ),
        {'mode': 'arl', 'arl': 'arl_abc'},
      );

      final tidalReq = WebViewAuthRequest.presetFor('tidal');
      expect(tidalReq.initialUrl, 'https://listen.tidal.com');
      expect(
        tidalReq.headerUrlSubstrings,
        containsAll(['api.tidal.com', 'openapi.tidal.com']),
      );
      expect(
        buildAuthParamsFromWebViewResult(
          'tidal',
          const WebViewAuthResult(
            captured: true,
            cancelled: false,
            headers: {'authorization': 'Bearer tidal_tok_99'},
          ),
        ),
        {'mode': 'access_token', 'access_token': 'tidal_tok_99'},
      );

      final qobuzReq = WebViewAuthRequest.presetFor('qobuz');
      expect(qobuzReq.initialUrl, 'https://play.qobuz.com/login');
      expect(qobuzReq.headerUrlSubstrings, contains('qobuz.com/api.json'));
      expect(qobuzReq.responseBodyUrlSubstrings, contains('/user/login'));
      expect(qobuzReq.inspectWebStorage, isTrue);
      expect(qobuzReq.cookieDomainSubstrings, contains('.qobuz.com'));
      expect(
        buildAuthParamsFromWebViewResult(
          'qobuz',
          const WebViewAuthResult(
            captured: true,
            cancelled: false,
            headers: {'x-user-auth-token': 'qb_tok'},
            queryParams: {'app_id': '285473059'},
          ),
        ),
        {
          'mode': 'token',
          'user_auth_token': 'qb_tok',
          'app_id': '285473059',
        },
      );
      expect(
        buildAuthParamsFromWebViewResult(
          'qobuz',
          const WebViewAuthResult(
            captured: true,
            cancelled: false,
            responseValues: {
              'user_auth_token': 'qb_resp_tok',
              'app_id': '285473059',
            },
          ),
        ),
        {
          'mode': 'token',
          'user_auth_token': 'qb_resp_tok',
          'app_id': '285473059',
        },
      );
      expect(
        buildAuthParamsFromWebViewResult(
          'tidal',
          const WebViewAuthResult(
            captured: true,
            cancelled: false,
            storage: {'access_token': 'tidal_storage_tok'},
          ),
        ),
        {'mode': 'access_token', 'access_token': 'tidal_storage_tok'},
      );
      expect(
        buildAuthParamsFromWebViewResult(
          'tidal',
          const WebViewAuthResult(
            captured: true,
            cancelled: false,
            headers: {'x-tidal-token': 'tidal_header_tok'},
          ),
        ),
        {'mode': 'access_token', 'access_token': 'tidal_header_tok'},
      );
      final qobuzMap = qobuzReq.toMap();
      expect(qobuzMap['cookieDomainSubstrings'], contains('.qobuz.com'));
      expect(qobuzMap['responseBodyUrlSubstrings'], contains('/user/login'));
      expect(qobuzMap['inspectWebStorage'], isTrue);
      expect(
        buildAuthParamsFromWebViewResult(
          'apple_music',
          const WebViewAuthResult(
            captured: true,
            cancelled: false,
            storage: {
              'developerToken': 'am_dev_tok',
              'media-user-token': 'am_user_tok',
            },
          ),
        ),
        {
          'mode': 'musickit_tokens',
          'developer_token': 'am_dev_tok',
          'music_user_token': 'am_user_tok',
        },
      );

      final appleReq = WebViewAuthRequest.presetFor('apple_music');
      expect(appleReq.initialUrl, 'https://music.apple.com');
      expect(
        buildAuthParamsFromWebViewResult(
          'apple_music',
          const WebViewAuthResult(
            captured: true,
            cancelled: false,
            headers: {'authorization': 'Bearer dev_jwt_1'},
            cookies: {'media-user-token': 'mut_cookie_1'},
          ),
        ),
        {
          'mode': 'musickit_tokens',
          'developer_token': 'dev_jwt_1',
          'music_user_token': 'mut_cookie_1',
        },
      );
    });
  });

  group('In-App WebView Auto-Capture Login & Plan B Fallback', () {
    testWidgets(
      'auto-captures across all 5 providers, validates live API, persists encrypted DPAPI credentials, closes dialog, and clears on logout',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 920);
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;

        final tempDir = Directory.systemTemp.createTempSync('lumina_wv2_test_');
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
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

            if (path == '/v1/me/storefront') {
              final auth = req.headers.value('authorization') ?? '';
              final mut = req.headers.value('music-user-token') ?? '';
              if (auth != 'Bearer apple_dev_ok' || mut != 'apple_user_ok') {
                return replyJson(HttpStatus.unauthorized, {
                  'errors': [{'detail': 'Invalid Apple token (401)'}],
                });
              }
              return replyJson(HttpStatus.ok, {
                'data': [
                  {
                    'id': 'tw',
                    'attributes': {'name': 'Taiwan', 'defaultLanguageTag': 'zh-Hant'},
                  },
                ],
              });
            }

            if (path == '/youtubei/v1/account/account_menu') {
              final auth = req.headers.value('authorization') ?? '';
              if (!auth.startsWith('SAPISIDHASH ')) {
                return replyJson(HttpStatus.unauthorized, {
                  'error': {'code': 401, 'message': 'Invalid SAPISIDHASH'},
                });
              }
              return replyJson(HttpStatus.ok, {
                'actions': [
                  {
                    'openPopupAction': {
                      'popup': {
                        'multiPageMenuRenderer': {
                          'header': {
                            'activeAccountHeaderRenderer': {
                              'accountName': {'simpleText': 'YTM Auto Listener'},
                              'channelHandle': {'simpleText': '@ytmauto'},
                              'manageAccountTitle': {'simpleText': 'Music Premium'},
                            },
                          },
                        },
                      },
                    },
                  },
                ],
              });
            }

            if (path == '/user/get') {
              final token = req.headers.value('x-user-auth-token') ?? '';
              final appId = req.headers.value('x-app-id') ?? '';
              if (token != 'qb_web_tok_ok' || appId != '285473059') {
                return replyJson(HttpStatus.unauthorized, {
                  'status': 'error',
                  'message': 'Invalid Qobuz web token',
                });
              }
              return replyJson(HttpStatus.ok, {
                'id': 901,
                'display_name': 'Qobuz Web Listener',
                'credential': {'label': 'Studio'},
              });
            }

            if (path == '/sessions') {
              final auth = req.headers.value('authorization') ?? '';
              if (auth != 'Bearer tidal_web_tok_ok') {
                return replyJson(HttpStatus.unauthorized, {
                  'userMessage': 'Invalid Tidal token',
                });
              }
              return replyJson(HttpStatus.ok, {
                'userId': 777,
                'countryCode': 'TW',
              });
            }

            if (path == '/users/777') {
              return replyJson(HttpStatus.ok, {
                'id': 777,
                'username': 'Tidal Web Listener',
              });
            }

            if (path == '/users/777/subscription') {
              return replyJson(HttpStatus.ok, {
                'subscription': {'type': 'HiFi Plus'},
                'highestSoundQuality': 'HI_RES_LOSSLESS',
              });
            }

            if (path == '/gw' && req.uri.queryParameters['method'] == 'deezer.getUserData') {
              final cookie = req.headers.value('cookie') ?? '';
              if (!cookie.contains('arl=dz_arl_web_ok')) {
                return replyJson(HttpStatus.ok, {
                  'error': {'VALID_TOKEN_REQUIRED': 'Invalid arl'},
                  'results': {'USER': {'USER_ID': 0}},
                });
              }
              return replyJson(HttpStatus.ok, {
                'results': {
                  'checkForm': 'csrf_web_1',
                  'USER': {
                    'USER_ID': 55501,
                    'BLOG_NAME': 'Deezer Web Listener',
                    'OPTIONS': {
                      'license_token': 'lic_web_1',
                      'web_lossless': true,
                      'web_hq': true,
                    },
                  },
                  'OFFER_NAME': 'Deezer HiFi',
                },
              });
            }

            return replyJson(HttpStatus.notFound, {'error': 'Not found'});
          });
          return srv;
        }))!;
        addTearDown(() {
          unawaited(server.close(force: true));
        });

        final baseUrl = 'http://127.0.0.1:${server.port}';
        final credFile = File('${tempDir.path}${Platform.pathSeparator}creds.dpapi.json');
        final dpapiStore = WindowsDpapiCredentialStore(
          storageFile: credFile,
          protectFn: (plain) async =>
              base64Encode(utf8.encode('DPAPI::$plain')),
          unprotectFn: (b64) async {
            final raw = utf8.decode(base64Decode(b64));
            return raw.startsWith('DPAPI::') ? raw.substring(7) : null;
          },
        );

        final fakeWebView = _FakeWebViewAuthService(available: true);
        fakeWebView.onOpen = (req) async {
          return switch (req.providerKind) {
            'apple_music' => const WebViewAuthResult(
                captured: true,
                cancelled: false,
                headers: {
                  'authorization': 'Bearer apple_dev_ok',
                  'media-user-token': 'apple_user_ok',
                },
                capturedUrl: 'https://music.apple.com/tw/home',
              ),
            'youtube_music' => const WebViewAuthResult(
                captured: true,
                cancelled: false,
                cookieHeader: 'SAPISID=yt_sap_ok; SID=yt_sid_ok',
                cookies: {'SAPISID': 'yt_sap_ok'},
                capturedUrl: 'https://music.youtube.com/',
              ),
            'qobuz' => const WebViewAuthResult(
                captured: true,
                cancelled: false,
                headers: {'x-user-auth-token': 'qb_web_tok_ok'},
                queryParams: {'app_id': '285473059'},
                capturedUrl: 'https://play.qobuz.com/featured',
              ),
            'tidal' => const WebViewAuthResult(
                captured: true,
                cancelled: false,
                headers: {'authorization': 'Bearer tidal_web_tok_ok'},
                capturedUrl: 'https://listen.tidal.com/',
              ),
            'deezer' => const WebViewAuthResult(
                captured: true,
                cancelled: false,
                cookies: {'arl': 'dz_arl_web_ok'},
                cookieHeader: 'arl=dz_arl_web_ok',
                capturedUrl: 'https://www.deezer.com/us/',
              ),
            _ => const WebViewAuthResult(captured: false, cancelled: true),
          };
        };

        final manager = StreamingManager(
          credentialStore: dpapiStore,
          webViewAuthService: fakeWebView,
          providers: {
            'apple_music': AppleMusicProvider(
              credentialStore: dpapiStore,
              apiBaseUrl: baseUrl,
            ),
            'youtube_music': YouTubeMusicProvider(
              credentialStore: dpapiStore,
              baseUrl: baseUrl,
            ),
            'qobuz': QobuzProvider(
              credentialStore: dpapiStore,
              baseUrl: baseUrl,
            ),
            'tidal': TidalProvider(
              credentialStore: dpapiStore,
              authBaseUrl: baseUrl,
              tokenBaseUrl: baseUrl,
              apiBaseUrl: baseUrl,
            ),
            'deezer': DeezerProvider(
              credentialStore: dpapiStore,
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

        Future<void> signInViaWebViewAndVerify(
          String kind,
          String expectedName,
          String expectedTier,
        ) async {
          await tester.ensureVisible(find.byKey(Key('btn_signin_$kind')));
          await tester.tap(find.byKey(Key('btn_signin_$kind')));
          await tester.pumpAndSettle();

          if (kind == 'apple_music') {
            expect(find.byKey(const Key('apple_music_drm_notice')), findsOneWidget);
          }
          expect(find.byKey(const Key('btn_webview_auto_login')), findsOneWidget);

          await tester.tap(find.byKey(const Key('btn_webview_auto_login')));
          await _pumpUntil(
            tester,
            () => find.byKey(Key('streaming_login_dialog_$kind')).evaluate().isEmpty,
          );
          await tester.pumpAndSettle();

          expect(find.byKey(Key('btn_logout_$kind')), findsOneWidget);
          expect(
            find.descendant(
              of: find.byKey(Key('provider_row_$kind')),
              matching: find.textContaining(expectedName),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: find.byKey(Key('provider_row_$kind')),
              matching: find.textContaining(expectedTier),
            ),
            findsOneWidget,
          );
        }

        await signInViaWebViewAndVerify('apple_music', 'Apple Music (Taiwan)', 'FairPlay DRM');
        await signInViaWebViewAndVerify('youtube_music', 'YTM Auto Listener', 'Music Premium');
        await signInViaWebViewAndVerify('qobuz', 'Qobuz Web Listener', 'Studio');
        await signInViaWebViewAndVerify('tidal', 'Tidal Web Listener', 'HiFi Plus');
        await signInViaWebViewAndVerify('deezer', 'Deezer Web Listener', 'Deezer HiFi');

        // Encrypted DPAPI credential file exists on disk without leaking raw tokens in plaintext.
        final rawFileContent = credFile.readAsStringSync();
        expect(rawFileContent, isNotNull);
        expect(rawFileContent, isNot(contains('apple_user_ok')));
        expect(rawFileContent, isNot(contains('yt_sap_ok')));
        expect(rawFileContent, isNot(contains('qb_web_tok_ok')));
        expect(rawFileContent, isNot(contains('tidal_web_tok_ok')));
        expect(rawFileContent, isNot(contains('dz_arl_web_ok')));

        // Qobuz token capture without app_secret honestly discloses missing app_secret.
        final qobuzProvider = manager.providerFor('qobuz') as QobuzProvider;
        expect(qobuzProvider.hasAppSecret, isFalse);
        expect(qobuzProvider.accountInfo?.drmNotice, contains('app_secret'));

        // Opening Qobuz dialog while connected shows missing app_secret notice cleanly.
        await tester.ensureVisible(find.byKey(const Key('btn_settings_qobuz')));
        await tester.tap(find.byKey(const Key('btn_settings_qobuz')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('qobuz_missing_secret_notice')), findsOneWidget);
        await tester.tap(find.byKey(const Key('btn_dialog_cancel_login')));
        await tester.pumpAndSettle();

        // Logout clears DPAPI credentials and restores disconnected state.
        for (final kind in const [
          'apple_music',
          'youtube_music',
          'qobuz',
          'tidal',
          'deezer',
        ]) {
          await tester.ensureVisible(find.byKey(Key('btn_logout_$kind')));
          await tester.tap(find.byKey(Key('btn_logout_$kind')));
          await _pumpUntil(
            tester,
            () => find.byKey(Key('btn_signin_$kind')).evaluate().isNotEmpty,
          );
          final storedAfter = await tester.runAsync(
            () => dpapiStore.read('streaming:$kind'),
          );
          expect(storedAfter, isNull);
          expect(find.byKey(Key('btn_signin_$kind')), findsOneWidget);
        }
        await tester.runAsync(() => server.close(force: true));
      },
    );

    testWidgets(
      'handles WebView window close as clean cancel without error, keeps dialog open on 401, and triggers Plan B fallback when WebView2 unavailable',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 920);
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final server = (await tester.runAsync(() async {
          final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          srv.listen((req) async {
            req.response.headers.contentType = ContentType.json;
            if (req.uri.path == '/v1/me/storefront') {
              req.response.statusCode = HttpStatus.unauthorized;
              req.response.write(jsonEncode({
                'errors': [{'detail': 'Expired Apple user token (401)'}],
              }));
              await req.response.close();
              return;
            }
            if (req.uri.path == '/v1/oauth2/token') {
              req.response.statusCode = HttpStatus.ok;
              req.response.write(jsonEncode({
                'access_token': 'pkce_plan_b_tok',
                'refresh_token': 'pkce_plan_b_ref',
                'expires_in': 3600,
                'user_id': 88,
              }));
              await req.response.close();
              return;
            }
            if (req.uri.path == '/sessions') {
              req.response.statusCode = HttpStatus.ok;
              req.response.write(jsonEncode({'userId': 88, 'countryCode': 'US'}));
              await req.response.close();
              return;
            }
            if (req.uri.path == '/users/88') {
              req.response.statusCode = HttpStatus.ok;
              req.response.write(jsonEncode({
                'id': 88,
                'username': 'Tidal Plan B User',
                'subscription': {'type': 'HIFI_PLUS'},
              }));
              await req.response.close();
              return;
            }
            req.response.statusCode = HttpStatus.notFound;
            await req.response.close();
          });
          return srv;
        }))!;
        addTearDown(() {
          unawaited(server.close(force: true));
        });

        final baseUrl = 'http://127.0.0.1:${server.port}';
        final credStore = MemorySecureCredentialStore();
        final fakeWebView = _FakeWebViewAuthService(available: true);
        final inFlightCompleter = Completer<WebViewAuthResult>();

        var mode = 'cancel';
        fakeWebView.onOpen = (_) async {
          if (mode == 'cancel') {
            return const WebViewAuthResult(captured: false, cancelled: true);
          }
          if (mode == 'in_flight') {
            return inFlightCompleter.future;
          }
          return const WebViewAuthResult(
            captured: true,
            cancelled: false,
            headers: {
              'authorization': 'Bearer dev_ok',
              'media-user-token': 'expired_401_tok',
            },
          );
        };

        final manager = StreamingManager(
          credentialStore: credStore,
          webViewAuthService: fakeWebView,
          providers: {
            'apple_music': AppleMusicProvider(
              credentialStore: credStore,
              apiBaseUrl: baseUrl,
            ),
            'youtube_music': YouTubeMusicProvider(
              credentialStore: credStore,
              baseUrl: baseUrl,
            ),
            'tidal': TidalProvider(
              credentialStore: credStore,
              authBaseUrl: baseUrl,
              tokenBaseUrl: baseUrl,
              apiBaseUrl: baseUrl,
              urlOpener: (authUrl) async {
                final uri = Uri.parse(authUrl);
                final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
                final state = uri.queryParameters['state']!;
                final cb = redirect.replace(
                  queryParameters: {'code': 'plan_b_code_1', 'state': state},
                );
                final client = HttpClient();
                final req = await client.getUrl(cb);
                final resp = await req.close();
                await resp.drain<void>();
                client.close();
                return true;
              },
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

        // 1. User closes WebView2 window -> clean cancellation without error box or error state.
        await tester.tap(find.byKey(const Key('btn_signin_apple_music')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_webview_auto_login')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('streaming_login_dialog_apple_music')), findsOneWidget);
        expect(find.byKey(const Key('login_dialog_error')), findsNothing);
        expect(manager.providerFor('apple_music')!.authState, StreamingAuthState.disconnected);

        // 2. Cancelling while WebView2 window is open calls closeAuthWindow().
        mode = 'in_flight';
        await tester.tap(find.byKey(const Key('btn_webview_auto_login')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('btn_dialog_cancel_login')));
        await tester.pump();
        expect(fakeWebView.closeCalls, 1);
        inFlightCompleter.complete(const WebViewAuthResult(captured: false, cancelled: true));
        await tester.pumpAndSettle();

        // 3. Captured 401 token -> keeps dialog open and displays real API error.
        mode = 'expired_401';
        await tester.tap(find.byKey(const Key('btn_webview_auto_login')));
        await _pumpUntil(
          tester,
          () => find.byKey(const Key('login_dialog_error')).evaluate().isNotEmpty,
        );
        expect(find.byKey(const Key('streaming_login_dialog_apple_music')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('login_dialog_error')),
            matching: find.textContaining('Expired Apple user token (401)'),
          ),
          findsOneWidget,
        );
        expect(await tester.runAsync(() => credStore.read('streaming:apple_music')), isNull);

        await tester.tap(find.byKey(const Key('btn_dialog_cancel_login')));
        await tester.pumpAndSettle();

        // 4. Plan B UI fallback when local browser is unavailable -> expands manual section honestly.
        fakeWebView.available = false;
        await tester.tap(find.byKey(const Key('btn_signin_tidal')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('input_tidal_client_id')), findsNothing);

        await tester.tap(find.byKey(const Key('btn_webview_auto_login')));
        await _pumpUntil(
          tester,
          () => find.byKey(const Key('login_dialog_error')).evaluate().isNotEmpty,
        );
        expect(find.byKey(const Key('tidal_byok_toggle')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('login_dialog_error')),
            matching: find.textContaining('本地瀏覽器'),
          ),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('btn_dialog_cancel_login')));
        await tester.pumpAndSettle();

        // 5. Plan B Loopback OAuth fallback succeeds for Tidal when client_id is supplied.
        await tester.runAsync(
          () => manager.authenticateWithWebView(
            'tidal',
            fallbackParams: {'client_id': 'tidal_plan_b_client'},
          ),
        );
        await tester.pumpAndSettle();
        expect(manager.providerFor('tidal')!.authState, StreamingAuthState.connected);
        expect(manager.providerFor('tidal')!.accountInfo?.displayName, 'Tidal Plan B User');
        await tester.runAsync(() async {
          manager.dispose();
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await server.close(force: true);
        });
      },
    );
  });
}
