import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/streaming/local_browser_auth_service.dart';
import 'package:lumina_app/services/streaming/oauth_helper.dart';
import 'package:lumina_app/services/streaming/providers/apple_music_provider.dart';
import 'package:lumina_app/services/streaming/providers/deezer_provider.dart';
import 'package:lumina_app/services/streaming/providers/qobuz_provider.dart';
import 'package:lumina_app/services/streaming/providers/tidal_provider.dart';
import 'package:lumina_app/services/streaming/providers/youtube_music_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_provider.dart';
import 'package:lumina_app/services/streaming/webview_auth_service.dart';
import 'package:lumina_app/ui/settings/providers_and_remote_panel.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

class _FakeBrowserProcess implements Process {
  @override
  final int pid;
  final bool exitOnKill;
  final Completer<int> _exitCompleter = Completer<int>();
  final StreamController<List<int>> _stdoutCtrl = StreamController<List<int>>();
  final StreamController<List<int>> _stderrCtrl = StreamController<List<int>>();

  int killCalls = 0;

  _FakeBrowserProcess({this.pid = 42424, this.exitOnKill = true});

  @override
  Future<int> get exitCode => _exitCompleter.future;

  @override
  Stream<List<int>> get stdout => _stdoutCtrl.stream;

  @override
  Stream<List<int>> get stderr => _stderrCtrl.stream;

  @override
  IOSink get stdin => throw UnimplementedError('stdin is unused');

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCalls++;
    if (exitOnKill) {
      completeExit(0);
    }
    return true;
  }

  void completeExit(int code) {
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(code);
    }
    if (!_stdoutCtrl.isClosed) {
      unawaited(_stdoutCtrl.close());
    }
    if (!_stderrCtrl.isClosed) {
      unawaited(_stderrCtrl.close());
    }
  }
}

class _MockCdpPageTarget {
  final String id;
  final String type = 'page';
  String url;
  WebSocket? socket;

  _MockCdpPageTarget({
    required this.id,
    required this.url,
  });
}

class _MockCdpServer {
  final HttpServer server;
  final List<_MockCdpPageTarget> targets;
  final List<String> receivedMethods = <String>[];
  final Map<String, List<WebSocket>> socketsByTarget =
      <String, List<WebSocket>>{};

  List<Map<String, dynamic>> Function(String targetId, List<String> urls)?
      cookiesProvider;
  List<Map<String, dynamic>> Function(String targetId)? storageCookiesProvider;
  List<Map<String, dynamic>> Function(String targetId)? allCookiesProvider;
  Map<String, dynamic>? Function(String targetId, String requestId)?
      responseBodyProvider;
  String Function(String targetId)? runtimeInnerTextProvider;
  String Function(String targetId, String expression)? runtimeEvaluateProvider;
  void Function(String targetId, String method, WebSocket socket)?
      onCommandReceived;
  bool serveEmptyTargetsInitially = false;

  _MockCdpServer._(this.server, this.targets);

  static Future<_MockCdpServer> start({
    required int port,
    required List<_MockCdpPageTarget> initialTargets,
    bool serveEmptyTargetsInitially = false,
  }) async {
    final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final mock = _MockCdpServer._(srv, List<_MockCdpPageTarget>.from(initialTargets))
      ..serveEmptyTargetsInitially = serveEmptyTargetsInitially;

    srv.listen((HttpRequest req) async {
      final path = req.uri.path;
      if (path == '/json/list') {
        req.response.statusCode = HttpStatus.ok;
        req.response.headers.contentType = ContentType.json;
        if (mock.serveEmptyTargetsInitially) {
          req.response.write('[]');
          await req.response.close();
          return;
        }
        req.response.write(
          jsonEncode(
            mock.targets
                .map(
                  (t) => <String, dynamic>{
                    'id': t.id,
                    'type': t.type,
                    'title': 'Mock Tab ${t.id}',
                    'url': t.url,
                    'webSocketDebuggerUrl':
                        'ws://127.0.0.1:${srv.port}/devtools/page/${t.id}',
                  },
                )
                .toList(),
          ),
        );
        await req.response.close();
        return;
      }

      if (path.startsWith('/devtools/page/')) {
        final targetId = path.substring('/devtools/page/'.length);
        final socket = await WebSocketTransformer.upgrade(req);
        unawaited(socket.done.catchError((_) {}));
        for (final t in mock.targets) {
          if (t.id == targetId) {
            t.socket = socket;
          }
        }
        mock.socketsByTarget.putIfAbsent(targetId, () => <WebSocket>[]).add(socket);

        socket.listen(
          (dynamic raw) {
            if (raw is! String) return;
            final decoded = jsonDecode(raw) as Map<String, dynamic>;
            final id = decoded['id'];
            final method = decoded['method']?.toString() ?? '';
            final params = decoded['params'] is Map
                ? Map<String, dynamic>.from(decoded['params'] as Map)
                : const <String, dynamic>{};

            mock.receivedMethods.add(method);

            Map<String, dynamic> result = <String, dynamic>{};
            if (method == 'Storage.getCookies' &&
                mock.storageCookiesProvider != null) {
              result = <String, dynamic>{
                'cookies': mock.storageCookiesProvider!(targetId),
              };
            } else if (method == 'Network.getAllCookies' &&
                mock.allCookiesProvider != null) {
              result = <String, dynamic>{
                'cookies': mock.allCookiesProvider!(targetId),
              };
            } else if (method == 'Network.getCookies') {
              final rawUrls = (params['urls'] as List<dynamic>? ?? const [])
                  .map((e) => e.toString())
                  .toList();
              final cookies =
                  mock.cookiesProvider?.call(targetId, rawUrls) ?? const [];
              result = <String, dynamic>{'cookies': cookies};
            } else if (method == 'Network.getResponseBody' &&
                mock.responseBodyProvider != null) {
              final reqId = params['requestId']?.toString() ?? '';
              result =
                  mock.responseBodyProvider!(targetId, reqId) ?? <String, dynamic>{};
            } else if (method == 'Runtime.evaluate') {
              final expr = params['expression']?.toString() ?? '';
              final text = mock.runtimeEvaluateProvider != null
                  ? mock.runtimeEvaluateProvider!(targetId, expr)
                  : (mock.runtimeInnerTextProvider?.call(targetId) ?? '');
              result = <String, dynamic>{
                'result': <String, dynamic>{
                  'type': 'string',
                  'value': text,
                },
              };
            }

            if (id != null && socket.readyState == WebSocket.open) {
              try {
                socket.add(
                  jsonEncode(<String, dynamic>{'id': id, 'result': result}),
                );
              } catch (_) {}
            }
            mock.onCommandReceived?.call(targetId, method, socket);
          },
          onError: (_) {},
          onDone: () {},
        );
        return;
      }

      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    });

    return mock;
  }

  void sendEvent(
    String targetId,
    String method,
    Map<String, dynamic> params,
  ) {
    final payload = jsonEncode(<String, dynamic>{
      'method': method,
      'params': params,
    });
    for (final s in socketsByTarget[targetId] ?? const <WebSocket>[]) {
      if (s.readyState == WebSocket.open) {
        try {
          s.add(payload);
        } catch (_) {}
      }
    }
  }

  Future<void> close() async {
    for (final list in socketsByTarget.values) {
      for (final s in list) {
        try {
          await s.close().timeout(const Duration(milliseconds: 100));
        } catch (_) {}
      }
    }
    await server.close(force: true);
  }
}

int _extractDebuggingPort(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('--remote-debugging-port=')) {
      return int.parse(arg.substring('--remote-debugging-port='.length));
    }
  }
  throw StateError('Missing --remote-debugging-port in $args');
}

String _extractUserDataDir(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('--user-data-dir=')) {
      return arg.substring('--user-data-dir='.length);
    }
  }
  throw StateError('Missing --user-data-dir in $args');
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met within $timeout');
    }
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<HttpServer> _startStreamingMockApiServer({
  bool includeGoogleDeviceOAuth = false,
  void Function(int port)? onStart,
}) async {
  final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  onStart?.call(srv.port);
  var devicePollCount = 0;

  srv.listen((req) async {
    final path = req.uri.path;
    Future<void> replyJson(int status, Object body) async {
      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(body));
      await req.response.close();
    }

    if (includeGoogleDeviceOAuth && path == '/device/code') {
      return replyJson(HttpStatus.ok, {
        'device_code': 'yt_dev_code_1',
        'user_code': 'GGL-4455',
        'verification_url': 'http://127.0.0.1:${srv.port}/google-device',
        'expires_in': 300,
        'interval': 0,
      });
    }

    if (includeGoogleDeviceOAuth && path == '/token') {
      devicePollCount++;
      if (devicePollCount == 1) {
        return replyJson(HttpStatus.badRequest, {'error': 'authorization_pending'});
      }
      return replyJson(HttpStatus.ok, {
        'access_token': 'yt_oauth_access_ok',
        'refresh_token': 'yt_oauth_refresh_ok',
        'expires_in': 3600,
      });
    }

    if (path == '/youtubei/v1/account/account_menu') {
      final auth = req.headers.value('authorization') ?? '';
      if (!auth.startsWith('SAPISIDHASH ') &&
          auth != 'Bearer yt_oauth_access_ok') {
        return replyJson(HttpStatus.unauthorized, {
          'error': {'code': 401, 'message': 'Invalid YouTube Music auth'},
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
                      'accountName': {'simpleText': 'CDP YTM Listener'},
                      'channelHandle': {'simpleText': '@cdpytm'},
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

    if (path == '/gw' && req.uri.queryParameters['method'] == 'deezer.getUserData') {
      final cookie = req.headers.value('cookie') ?? '';
      if (!cookie.contains('arl=dz_cdp_arl_ok')) {
        return replyJson(HttpStatus.ok, {
          'error': {'VALID_TOKEN_REQUIRED': 'Invalid arl'},
          'results': {'USER': {'USER_ID': 0}},
        });
      }
      return replyJson(HttpStatus.ok, {
        'results': {
          'checkForm': 'csrf_cdp_1',
          'USER': {
            'USER_ID': 9901,
            'BLOG_NAME': 'CDP Deezer Listener',
            'OPTIONS': {
              'license_token': 'lic_cdp_1',
              'web_lossless': true,
              'web_hq': true,
            },
          },
          'OFFER_NAME': 'Deezer HiFi',
        },
      });
    }

    if (path == '/user/get') {
      final token = req.headers.value('x-user-auth-token') ?? '';
      final appId = req.headers.value('x-app-id') ?? '';
      if (token != 'qb_cdp_tok_ok' || appId != '285473059') {
        return replyJson(HttpStatus.unauthorized, {
          'status': 'error',
          'message': 'Invalid Qobuz CDP token',
        });
      }
      return replyJson(HttpStatus.ok, {
        'id': 321,
        'display_name': 'CDP Qobuz Listener',
        'credential': {'label': 'Studio'},
      });
    }

    if (path == '/sessions') {
      final auth = req.headers.value('authorization') ?? '';
      if (auth != 'Bearer tidal_cdp_tok_ok' &&
          auth != 'Bearer tidal_pkce_ok') {
        return replyJson(HttpStatus.unauthorized, {
          'userMessage': 'Invalid Tidal token',
        });
      }
      return replyJson(HttpStatus.ok, {'userId': 777, 'countryCode': 'TW'});
    }

    if (path == '/users/777') {
      return replyJson(HttpStatus.ok, {
        'id': 777,
        'username': 'CDP Tidal Listener',
      });
    }

    if (path == '/users/777/subscription') {
      return replyJson(HttpStatus.ok, {
        'subscription': {'type': 'HiFi Plus'},
        'highestSoundQuality': 'HI_RES_LOSSLESS',
      });
    }

    if (path == '/v1/me/storefront') {
      final auth = req.headers.value('authorization') ?? '';
      final mut = req.headers.value('music-user-token') ?? '';
      if (auth != 'Bearer apple_cdp_dev_ok' || mut != 'apple_cdp_user_ok') {
        return replyJson(HttpStatus.unauthorized, {
          'errors': [{'detail': 'Invalid Apple token'}],
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

    if (path == '/v1/oauth2/token') {
      return replyJson(HttpStatus.ok, {
        'access_token': 'tidal_pkce_ok',
        'refresh_token': 'tidal_pkce_ref_ok',
        'expires_in': 3600,
        'user_id': 777,
      });
    }

    if (path == '/oauth/access_token.php') {
      return replyJson(HttpStatus.ok, {
        'access_token': 'dz_oauth_access_ok',
        'expires': 3600,
      });
    }

    if (path == '/user/me') {
      return replyJson(HttpStatus.ok, {
        'id': 888,
        'name': 'OAuth Deezer Listener',
        'country': 'TW',
      });
    }

    return replyJson(HttpStatus.notFound, {'error': 'Not found: $path'});
  });

  return srv;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  group('detectLocalBrowserPath', () {
    test('checks Windows browsers in priority order msedge -> chrome -> brave and returns null when missing', () {
      const env = <String, String>{
        'ProgramFiles(x86)': r'C:\Program Files (x86)',
        'ProgramFiles': r'C:\Program Files',
        'LocalAppData': r'C:\Users\Tester\AppData\Local',
      };

      final allExisting = <String>{
        r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
        r'C:\Program Files\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe',
      };
      expect(
        detectLocalBrowserPath(
          environmentOverride: env,
          isWindowsOverride: true,
          fileExistsOverride: allExisting.contains,
        ),
        r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
      );

      final chromeAndBraveOnly = <String>{
        r'C:\Program Files\Google\Chrome\Application\chrome.exe',
        r'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe',
      };
      expect(
        detectLocalBrowserPath(
          environmentOverride: env,
          isWindowsOverride: true,
          fileExistsOverride: chromeAndBraveOnly.contains,
        ),
        r'C:\Program Files\Google\Chrome\Application\chrome.exe',
      );

      final braveLocalOnly = <String>{
        r'C:\Users\Tester\AppData\Local\BraveSoftware\Brave-Browser\Application\brave.exe',
      };
      expect(
        detectLocalBrowserPath(
          environmentOverride: env,
          isWindowsOverride: true,
          fileExistsOverride: braveLocalOnly.contains,
        ),
        r'C:\Users\Tester\AppData\Local\BraveSoftware\Brave-Browser\Application\brave.exe',
      );

      expect(
        detectLocalBrowserPath(
          environmentOverride: env,
          isWindowsOverride: true,
          fileExistsOverride: (_) => false,
        ),
        isNull,
      );

      expect(
        detectLocalBrowserPath(
          candidatePathsOverride: const [
            r'D:\Missing\msedge.exe',
            r'D:\Portable\chrome.exe',
          ],
          fileExistsOverride: (p) => p == r'D:\Portable\chrome.exe',
        ),
        r'D:\Portable\chrome.exe',
      );
    });

    test('isWebView2Available and isLocalBrowserAvailable reflect detectLocalBrowserPath', () async {
      final availableSvc = LocalBrowserAuthService(
        candidatePathsOverride: const [r'C:\Fake\msedge.exe'],
        fileExistsOverride: (p) => p == r'C:\Fake\msedge.exe',
      );
      expect(await availableSvc.isLocalBrowserAvailable(), isTrue);
      expect(await availableSvc.isWebView2Available(), isTrue);

      final missingSvc = LocalBrowserAuthService(
        candidatePathsOverride: const [r'C:\Fake\missing.exe'],
        fileExistsOverride: (_) => false,
      );
      expect(await missingSvc.isLocalBrowserAvailable(), isFalse);
      expect(await missingSvc.isWebView2Available(), isFalse);
    });
  });

  group('LocalBrowserAuthService CDP capture across all 5 platforms & cleanup', () {
    test('captures credentials via real CDP HTTP/WS across all 5 platforms, verifies live APIs, persists via DPAPI, kills process, and deletes temp profile', () async {
      final tempRoot = await Directory.systemTemp.createTemp('lumina_stage3_all5_');
      addTearDown(() {
        if (tempRoot.existsSync()) {
          tempRoot.deleteSync(recursive: true);
        }
      });

      final apiServer = await _startStreamingMockApiServer();
      addTearDown(() => apiServer.close(force: true));
      final baseUrl = 'http://127.0.0.1:${apiServer.port}';

      final credFile = File('${tempRoot.path}${Platform.pathSeparator}creds.dpapi.json');
      final dpapiStore = WindowsDpapiCredentialStore(
        storageFile: credFile,
        protectFn: (plain) async => 'DPAPI:${base64Encode(utf8.encode(plain))}',
        unprotectFn: (cipher) async => cipher.startsWith('DPAPI:')
            ? utf8.decode(base64Decode(cipher.substring(6)))
            : null,
      );

      final createdProfiles = <Directory>[];
      final launchedProcesses = <_FakeBrowserProcess>[];
      final launchedArgs = <List<String>>[];
      _MockCdpServer? activeCdp;
      late String activeKind;

      final service = LocalBrowserAuthService(
        candidatePathsOverride: const [r'C:\FakeBrowser\msedge.exe'],
        fileExistsOverride: (_) => true,
        cdpDiscoveryInterval: const Duration(milliseconds: 25),
        pollInterval: const Duration(milliseconds: 50),
        timeout: const Duration(seconds: 5),
        processStarter: (exe, args) async {
          expect(exe, r'C:\FakeBrowser\msedge.exe');
          launchedArgs.add(args);
          final port = _extractDebuggingPort(args);
          final profileDir = Directory(_extractUserDataDir(args));
          expect(profileDir.existsSync(), isTrue);
          createdProfiles.add(profileDir);

          // Drop a sensitive temp file inside profile dir to verify recursive cleanup.
          File('${profileDir.path}${Platform.pathSeparator}Cookies')
              .writeAsStringSync('SENSITIVE_TEMP_COOKIE_DATA');

          final proc = _FakeBrowserProcess(pid: 51000 + launchedProcesses.length);
          launchedProcesses.add(proc);

          final initialUrl = WebViewAuthRequest.presetFor(activeKind).initialUrl;
          final cdp = await _MockCdpServer.start(
            port: port,
            initialTargets: [
              _MockCdpPageTarget(id: 'tab_main', url: initialUrl),
            ],
          );
          activeCdp = cdp;

          var injected = false;
          cdp.onCommandReceived = (targetId, method, socket) {
            if (injected || method != 'Runtime.enable') return;
            injected = true;

            scheduleMicrotask(() {
              switch (activeKind) {
                case 'youtube_music':
                  cdp.cookiesProvider = (_, _) => [
                        {'name': 'SAPISID', 'value': 'ytm_sap_cdp_ok'},
                        {'name': 'SID', 'value': 'ytm_sid_cdp_ok'},
                      ];
                  cdp.sendEvent(targetId, 'Page.frameNavigated', {
                    'frame': {'id': 'f1', 'url': 'https://music.youtube.com/'},
                  });
                  break;
                case 'deezer':
                  cdp.cookiesProvider = (_, _) => [
                        {'name': 'arl', 'value': 'dz_cdp_arl_ok'},
                      ];
                  cdp.sendEvent(targetId, 'Page.frameNavigated', {
                    'frame': {'id': 'f1', 'url': 'https://www.deezer.com/us/'},
                  });
                  break;
                case 'qobuz':
                  cdp.sendEvent(targetId, 'Page.frameNavigated', {
                    'frame': {'id': 'f1', 'url': 'https://play.qobuz.com/featured'},
                  });
                  cdp.sendEvent(targetId, 'Network.requestWillBeSent', {
                    'requestId': 'req_qb_1',
                    'request': {
                      'url': 'https://www.qobuz.com/api.json/0.2/user/get?app_id=285473059',
                      'headers': {'X-User-Auth-Token': 'qb_cdp_tok_ok'},
                    },
                  });
                  break;
                case 'tidal':
                  // Simulate popup OAuth target appearing in /json/list + SPA navigation
                  cdp.targets.add(
                    _MockCdpPageTarget(
                      id: 'tab_popup',
                      url: 'https://login.tidal.com/authorize',
                    ),
                  );
                  cdp.sendEvent(targetId, 'Page.navigatedWithinDocument', {
                    'frameId': null,
                    'url': 'https://listen.tidal.com/',
                  });
                  cdp.sendEvent(targetId, 'Network.requestWillBeSent', {
                    'requestId': 'req_td_1',
                    'request': {
                      'url': 'https://api.tidal.com/v1/sessions',
                      'headers': {'Authorization': 'Bearer tidal_cdp_tok_ok'},
                    },
                  });
                  break;
                case 'apple_music':
                  cdp.cookiesProvider = (_, _) => [
                        {'name': 'media-user-token', 'value': 'apple_cdp_user_ok'},
                      ];
                  cdp.sendEvent(targetId, 'Page.frameNavigated', {
                    'frame': {'id': 'f1', 'url': 'https://music.apple.com/tw/home'},
                  });
                  cdp.sendEvent(targetId, 'Network.requestWillBeSent', {
                    'requestId': 'req_am_1',
                    'request': {
                      'url': 'https://amp-api.music.apple.com/v1/me/storefront',
                      'headers': {'Authorization': 'Bearer apple_cdp_dev_ok'},
                    },
                  });
                  break;
              }
            });
          };

          return proc;
        },
      );

      final manager = StreamingManager(
        credentialStore: dpapiStore,
        webViewAuthService: service,
        providers: <String, StreamingProvider>{
          'youtube_music': YouTubeMusicProvider(
            credentialStore: dpapiStore,
            baseUrl: baseUrl,
          ),
          'deezer': DeezerProvider(
            credentialStore: dpapiStore,
            gwUrl: '$baseUrl/gw',
            apiBaseUrl: baseUrl,
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
          'apple_music': AppleMusicProvider(
            credentialStore: dpapiStore,
            apiBaseUrl: baseUrl,
          ),
        },
      );
      addTearDown(manager.dispose);

      for (final kind in const [
        'youtube_music',
        'deezer',
        'qobuz',
        'tidal',
        'apple_music',
      ]) {
        activeKind = kind;
        await manager.authenticateWithLocalBrowser(kind);
        await activeCdp?.close();
        activeCdp = null;

        final provider = manager.providerFor(kind)!;
        expect(provider.authState, StreamingAuthState.connected, reason: kind);
        expect(provider.accountInfo?.displayName, isNotEmpty, reason: kind);
        expect(launchedArgs.last, contains('--no-first-run'));
        expect(
          launchedArgs.last,
          contains('--disable-blink-features=AutomationControlled'),
        );
        expect(
          createdProfiles.last.existsSync(),
          isFalse,
          reason: 'Temp profile dir must be removed after $kind login',
        );
        expect(launchedProcesses.last.killCalls, greaterThanOrEqualTo(1));
      }

      // DPAPI file must exist and contain NO raw tokens in plaintext.
      final diskText = credFile.readAsStringSync();
      expect(diskText, contains('DPAPI:'));
      expect(diskText, isNot(contains('ytm_sap_cdp_ok')));
      expect(diskText, isNot(contains('dz_cdp_arl_ok')));
      expect(diskText, isNot(contains('qb_cdp_tok_ok')));
      expect(diskText, isNot(contains('tidal_cdp_tok_ok')));
      expect(diskText, isNot(contains('apple_cdp_user_ok')));
    });

    test('terminates browser, closes CDP sockets, deletes profile dir on cancelLogin, and supports taskkill fallback', () async {
      final apiServer = await _startStreamingMockApiServer();
      addTearDown(() => apiServer.close(force: true));
      final baseUrl = 'http://127.0.0.1:${apiServer.port}';

      final credStore = MemorySecureCredentialStore();
      late Directory capturedProfile;
      late _FakeBrowserProcess fakeProc;
      late _MockCdpServer cdpServer;
      final taskkilledPids = <int>[];
      final attachedCompleter = Completer<void>();

      final service = LocalBrowserAuthService(
        candidatePathsOverride: const [r'C:\FakeBrowser\chrome.exe'],
        fileExistsOverride: (_) => true,
        cdpDiscoveryInterval: const Duration(milliseconds: 20),
        pollInterval: const Duration(milliseconds: 60),
        killWaitTimeout: const Duration(milliseconds: 40),
        taskkillRunner: (pid) async {
          taskkilledPids.add(pid);
          fakeProc.completeExit(0);
          return ProcessResult(pid, 0, '', '');
        },
        processStarter: (exe, args) async {
          final port = _extractDebuggingPort(args);
          capturedProfile = Directory(_extractUserDataDir(args));
          fakeProc = _FakeBrowserProcess(pid: 65432, exitOnKill: false);
          cdpServer = await _MockCdpServer.start(
            port: port,
            initialTargets: [
              _MockCdpPageTarget(id: 'p1', url: 'https://www.deezer.com/login'),
            ],
          );
          cdpServer.onCommandReceived = (_, method, _) {
            if (method == 'Runtime.enable' && !attachedCompleter.isCompleted) {
              attachedCompleter.complete();
            }
          };
          return fakeProc;
        },
      );
      addTearDown(() async {
        await cdpServer.close();
      });

      final manager = StreamingManager(
        credentialStore: credStore,
        webViewAuthService: service,
        providers: <String, StreamingProvider>{
          'deezer': DeezerProvider(
            credentialStore: credStore,
            gwUrl: '$baseUrl/gw',
            apiBaseUrl: baseUrl,
          ),
        },
      );
      addTearDown(manager.dispose);

      final loginFuture = manager.authenticateWithLocalBrowser('deezer');
      await attachedCompleter.future.timeout(const Duration(seconds: 3));

      manager.cancelLogin('deezer');

      await expectLater(
        loginFuture,
        throwsA(
          isA<StreamingException>().having((e) => e.isCancelled, 'isCancelled', true),
        ),
      );

      expect(fakeProc.killCalls, greaterThanOrEqualTo(1));
      if (Platform.isWindows) {
        expect(taskkilledPids, contains(65432));
      }
      expect(capturedProfile.existsSync(), isFalse);
      expect(manager.providerFor('deezer')!.authState, StreamingAuthState.disconnected);
      expect(cdpServer.receivedMethods, containsAll(['Network.enable', 'Page.enable', 'Runtime.enable', 'Browser.close']));
    });

    test('detects user closing all browser tabs cleanly as cancelled without error', () async {
      late _FakeBrowserProcess fakeProc;
      late _MockCdpServer cdpServer;
      late Directory capturedProfile;
      final attachedCompleter = Completer<void>();

      final service = LocalBrowserAuthService(
        candidatePathsOverride: const [r'C:\FakeBrowser\msedge.exe'],
        fileExistsOverride: (_) => true,
        cdpDiscoveryInterval: const Duration(milliseconds: 20),
        pollInterval: const Duration(milliseconds: 40),
        processStarter: (_, args) async {
          final port = _extractDebuggingPort(args);
          capturedProfile = Directory(_extractUserDataDir(args));
          fakeProc = _FakeBrowserProcess(pid: 77111);
          cdpServer = await _MockCdpServer.start(
            port: port,
            initialTargets: [
              _MockCdpPageTarget(id: 'tab1', url: 'https://music.youtube.com'),
            ],
          );
          cdpServer.onCommandReceived = (_, method, _) {
            if (method == 'Runtime.enable' && !attachedCompleter.isCompleted) {
              attachedCompleter.complete();
            }
          };
          return fakeProc;
        },
      );
      addTearDown(() async => cdpServer.close());

      final future = service.openAuthWindow(
        WebViewAuthRequest.presetFor('youtube_music'),
      );
      await attachedCompleter.future.timeout(const Duration(seconds: 3));

      // Simulate user closing all tabs in the browser window.
      cdpServer.targets.clear();

      final result = await future;
      expect(result.captured, isFalse);
      expect(result.cancelled, isTrue);
      expect(capturedProfile.existsSync(), isFalse);
    });
  });

  group('Google anti-block detection & automatic OAuth Device fallback', () {
    test('detects Google /signin/rejected URL and blocked Runtime text, and auto-switches to oauth_device when client_id supplied', () async {
      final tempRoot = await Directory.systemTemp.createTemp('lumina_ytm_block_');
      addTearDown(() {
        if (tempRoot.existsSync()) {
          tempRoot.deleteSync(recursive: true);
        }
      });

      final apiServer = await _startStreamingMockApiServer(
        includeGoogleDeviceOAuth: true,
      );
      addTearDown(() => apiServer.close(force: true));
      final baseUrl = 'http://127.0.0.1:${apiServer.port}';

      final credFile = File('${tempRoot.path}${Platform.pathSeparator}creds.dpapi.json');
      final dpapiStore = WindowsDpapiCredentialStore(
        storageFile: credFile,
        protectFn: (plain) async => 'DPAPI:${base64Encode(utf8.encode(plain))}',
        unprotectFn: (cipher) async => cipher.startsWith('DPAPI:')
            ? utf8.decode(base64Decode(cipher.substring(6)))
            : null,
      );

      var blockMode = 'url'; // 'url' -> /signin/rejected, 'text' -> Runtime.evaluate
      final cdpServers = <_MockCdpServer>[];
      addTearDown(() async {
        for (final srv in cdpServers) {
          await srv.close();
        }
      });

      final service = LocalBrowserAuthService(
        candidatePathsOverride: const [r'C:\FakeBrowser\msedge.exe'],
        fileExistsOverride: (_) => true,
        cdpDiscoveryInterval: const Duration(milliseconds: 20),
        pollInterval: const Duration(milliseconds: 40),
        processStarter: (_, args) async {
          final port = _extractDebuggingPort(args);
          final proc = _FakeBrowserProcess(pid: 88000 + cdpServers.length);
          final cdp = await _MockCdpServer.start(
            port: port,
            initialTargets: [
              _MockCdpPageTarget(id: 'yt_tab', url: 'https://music.youtube.com'),
            ],
          );
          cdpServers.add(cdp);

          var sentNav = false;
          cdp.onCommandReceived = (targetId, method, _) {
            if (sentNav || method != 'Runtime.enable') return;
            sentNav = true;
            scheduleMicrotask(() {
              if (blockMode == 'url') {
                cdp.sendEvent(targetId, 'Page.frameNavigated', {
                  'frame': {
                    'id': 'f1',
                    'url': 'https://accounts.google.com/v3/signin/rejected?continue=https://music.youtube.com',
                  },
                });
              } else {
                cdp.runtimeInnerTextProvider = (_) =>
                    "Couldn’t sign you in. This browser or app may not be secure.";
                cdp.sendEvent(targetId, 'Page.frameNavigated', {
                  'frame': {
                    'id': 'f1',
                    'url': 'https://accounts.google.com/v3/signin/identifier',
                  },
                });
              }
            });
          };
          return proc;
        },
      );

      // 1. Direct Runtime text block detection on LocalBrowserAuthService
      blockMode = 'text';
      final directBlocked = await service.openAuthWindow(
        WebViewAuthRequest.presetFor('youtube_music'),
      );
      expect(directBlocked.captured, isFalse);
      expect(directBlocked.cancelled, isFalse);
      expect(directBlocked.isBlockedByPlatform, isTrue);

      // 2. StreamingManager auto-switches from blocked URL to YouTubeMusic oauth_device
      blockMode = 'url';
      final openedUrls = <String>[];
      final manager = StreamingManager(
        credentialStore: dpapiStore,
        webViewAuthService: service,
        providers: <String, StreamingProvider>{
          'youtube_music': YouTubeMusicProvider(
            credentialStore: dpapiStore,
            baseUrl: baseUrl,
            oauthBaseUrl: baseUrl,
            urlOpener: (url) async {
              openedUrls.add(url);
              return true;
            },
          ),
        },
      );
      addTearDown(manager.dispose);

      await manager.authenticateWithLocalBrowser(
        'youtube_music',
        fallbackParams: {'client_id': 'google_client_123'},
      );

      expect(openedUrls, hasLength(1));
      expect(openedUrls.single, contains('/google-device'));
      expect(manager.providerFor('youtube_music')!.authState, StreamingAuthState.connected);
      expect(manager.providerFor('youtube_music')!.accountInfo?.displayName, 'CDP YTM Listener');
      expect(credFile.readAsStringSync(), isNot(contains('yt_oauth_access_ok')));
    });

    testWidgets('expands manual token section cleanly without hanging when Google blocks and no client_id is set', (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 920);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final credStore = MemorySecureCredentialStore();
      _MockCdpServer? cdp;
      addTearDown(() {
        final active = cdp;
        if (active != null) {
          unawaited(active.close());
        }
      });

      final service = LocalBrowserAuthService(
        candidatePathsOverride: const [r'C:\FakeBrowser\msedge.exe'],
        fileExistsOverride: (_) => true,
        cdpDiscoveryInterval: const Duration(milliseconds: 20),
        pollInterval: const Duration(milliseconds: 40),
        processStarter: (_, args) async {
          final port = _extractDebuggingPort(args);
          final proc = _FakeBrowserProcess(pid: 89001);
          cdp = await Zone.root.run(
            () => _MockCdpServer.start(
              port: port,
              initialTargets: [
                _MockCdpPageTarget(id: 'yt_tab', url: 'https://music.youtube.com'),
              ],
            ),
          );
          var sent = false;
          cdp!.onCommandReceived = (targetId, method, _) {
            if (sent || method != 'Runtime.enable') return;
            sent = true;
            Zone.root.scheduleMicrotask(() {
              cdp!.runtimeInnerTextProvider = (_) => '這個瀏覽器或應用程式可能不安全';
              cdp!.sendEvent(targetId, 'Page.frameNavigated', {
                'frame': {
                  'id': 'f1',
                  'url': 'https://accounts.google.com/v3/signin/identifier',
                },
              });
            });
          };
          return proc;
        },
      );

      final manager = StreamingManager(
        credentialStore: credStore,
        webViewAuthService: service,
        providers: <String, StreamingProvider>{
          'youtube_music': YouTubeMusicProvider(credentialStore: credStore),
        },
      );
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

      await tester.tap(find.byKey(const Key('btn_signin_youtube_music')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('input_ytm_cookie')), findsNothing);

      await tester.tap(find.byKey(const Key('btn_webview_auto_login')));
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('login_dialog_error')).evaluate().isNotEmpty,
      );

      // Manual section auto-expanded and displays clear guidance without hanging
      expect(find.byKey(const Key('input_ytm_cookie')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('login_dialog_error')),
          matching: find.textContaining('Google 安全性機制阻擋'),
        ),
        findsOneWidget,
      );
      expect(
        manager.providerFor('youtube_music')!.authState,
        StreamingAuthState.disconnected,
      );
      await tester.runAsync(() async {
        await cdp?.close();
        cdp = null;
      });
    });
  });

  group('Path A Loopback OAuth 2.0 direct flow & cancellation', () {
    test('LoopbackOAuthServer returns success HTML page and Path A Tidal/Deezer authenticate directly without launching CDP browser', () async {
      final apiServer = await _startStreamingMockApiServer();
      addTearDown(() => apiServer.close(force: true));
      final baseUrl = 'http://127.0.0.1:${apiServer.port}';

      var cdpLaunchCount = 0;
      final service = LocalBrowserAuthService(
        candidatePathsOverride: const [r'C:\FakeBrowser\msedge.exe'],
        fileExistsOverride: (_) => true,
        processStarter: (_, _) async {
          cdpLaunchCount++;
          return _FakeBrowserProcess();
        },
      );

      late String lastSuccessHtml;
      Future<bool> autoAuthorizeOpener(String authUrl) async {
        final uri = Uri.parse(authUrl);
        final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
        final state = uri.queryParameters['state']!;
        final cb = redirect.replace(
          queryParameters: {'code': 'oauth_code_123', 'state': state},
        );
        final client = HttpClient();
        try {
          final req = await client.getUrl(cb);
          final resp = await req.close();
          lastSuccessHtml = await utf8.decoder.bind(resp).join();
          expect(resp.statusCode, HttpStatus.ok);
        } finally {
          client.close(force: true);
        }
        return true;
      }

      final credStore = MemorySecureCredentialStore();
      final manager = StreamingManager(
        credentialStore: credStore,
        webViewAuthService: service,
        providers: <String, StreamingProvider>{
          'tidal': TidalProvider(
            credentialStore: credStore,
            authBaseUrl: baseUrl,
            tokenBaseUrl: baseUrl,
            apiBaseUrl: baseUrl,
            urlOpener: autoAuthorizeOpener,
          ),
          'deezer': DeezerProvider(
            credentialStore: credStore,
            oauthBaseUrl: baseUrl,
            apiBaseUrl: baseUrl,
            urlOpener: autoAuthorizeOpener,
          ),
        },
      );
      addTearDown(manager.dispose);

      await manager.authenticateWithLocalBrowser(
        'tidal',
        fallbackParams: {'client_id': 'tidal_client_path_a'},
      );
      expect(cdpLaunchCount, 0);
      expect(lastSuccessHtml, contains('登入授權成功'));
      expect(lastSuccessHtml, contains('可以關閉此分頁'));
      expect(manager.providerFor('tidal')!.authState, StreamingAuthState.connected);

      await manager.authenticateWithLocalBrowser(
        'deezer',
        fallbackParams: {
          'app_id': 'dz_app_1',
          'app_secret': 'dz_sec_1',
        },
      );
      expect(cdpLaunchCount, 0);
      expect(lastSuccessHtml, contains('登入授權成功'));
      expect(manager.providerFor('deezer')!.authState, StreamingAuthState.connected);
    });

    test('LoopbackOAuthServer shuts down immediately on cancelLogin', () async {
      final apiServer = await _startStreamingMockApiServer();
      addTearDown(() => apiServer.close(force: true));
      final baseUrl = 'http://127.0.0.1:${apiServer.port}';

      late Uri capturedRedirectUri;
      final browserOpened = Completer<void>();

      final credStore = MemorySecureCredentialStore();
      final manager = StreamingManager(
        credentialStore: credStore,
        webViewAuthService: LocalBrowserAuthService(
          candidatePathsOverride: const [],
          fileExistsOverride: (_) => false,
        ),
        providers: <String, StreamingProvider>{
          'tidal': TidalProvider(
            credentialStore: credStore,
            authBaseUrl: baseUrl,
            tokenBaseUrl: baseUrl,
            apiBaseUrl: baseUrl,
            urlOpener: (url) async {
              capturedRedirectUri =
                  Uri.parse(Uri.parse(url).queryParameters['redirect_uri']!);
              if (!browserOpened.isCompleted) {
                browserOpened.complete();
              }
              return true;
            },
          ),
        },
      );
      addTearDown(manager.dispose);

      final future = manager.authenticateWithLocalBrowser(
        'tidal',
        fallbackParams: {'client_id': 'tidal_cancel_client'},
      );
      await browserOpened.future.timeout(const Duration(seconds: 2));

      manager.cancelLogin('tidal');
      await expectLater(
        future,
        throwsA(
          isA<StreamingException>().having((e) => e.isCancelled, 'isCancelled', true),
        ),
      );

      // Verify loopback port was closed by attempting a connection (must refuse).
      final client = HttpClient();
      try {
        await expectLater(
          client.getUrl(capturedRedirectUri).then((r) => r.close()),
          throwsA(isA<SocketException>()),
        );
      } finally {
        client.close(force: true);
      }
    });

    test('LoopbackOAuthServer standalone waitForCallback serves success HTML and closes on cancellation', () async {
      final server = LoopbackOAuthServer();
      await server.start(expectedState: 'st_ok');
      expect(server.isRunning, isTrue);
      final cbUrl = server.callbackUrl('/callback');

      final waitFuture = server.waitForCallback(expectedState: 'st_ok');

      final client = HttpClient();
      try {
        final req = await client.getUrl(
          Uri.parse('$cbUrl?code=abc123&state=st_ok'),
        );
        final resp = await req.close();
        final html = await utf8.decoder.bind(resp).join();
        expect(resp.statusCode, HttpStatus.ok);
        expect(html, contains('登入授權成功'));
        expect(html, contains('關閉此分頁'));
      } finally {
        client.close(force: true);
      }

      final payload = await waitFuture;
      expect(payload.code, 'abc123');
      expect(server.isRunning, isFalse);
    });

    test('Apple Music Path A musickit_browser executes directly without CDP browser when developer_token is supplied', () async {
      final apiServer = await _startStreamingMockApiServer();
      addTearDown(() => apiServer.close(force: true));
      final baseUrl = 'http://127.0.0.1:${apiServer.port}';

      var cdpLaunchCount = 0;
      final service = LocalBrowserAuthService(
        candidatePathsOverride: const [r'C:\FakeBrowser\msedge.exe'],
        fileExistsOverride: (_) => true,
        processStarter: (_, _) async {
          cdpLaunchCount++;
          return _FakeBrowserProcess();
        },
      );

      final credStore = MemorySecureCredentialStore();
      final manager = StreamingManager(
        credentialStore: credStore,
        webViewAuthService: service,
        providers: <String, StreamingProvider>{
          'apple_music': AppleMusicProvider(
            credentialStore: credStore,
            apiBaseUrl: baseUrl,
            urlOpener: (authPageUrl) async {
              final uri = Uri.parse(authPageUrl);
              final callbackUri = uri.replace(path: '/musickit-callback');
              final client = HttpClient();
              try {
                final getReq = await client.getUrl(uri);
                final getResp = await getReq.close();
                final html = await utf8.decoder.bind(getResp).join();
                expect(getResp.statusCode, HttpStatus.ok);
                expect(html, contains('Apple Music 帳號授權'));

                final postReq = await client.postUrl(callbackUri);
                postReq.headers.contentType = ContentType.json;
                postReq.write(jsonEncode({'musicUserToken': 'apple_cdp_user_ok'}));
                final postResp = await postReq.close();
                await postResp.drain<void>();
                expect(postResp.statusCode, HttpStatus.ok);
              } finally {
                client.close(force: true);
              }
              return true;
            },
          ),
        },
      );
      addTearDown(manager.dispose);

      await manager.authenticateWithLocalBrowser(
        'apple_music',
        fallbackParams: {'developer_token': 'apple_cdp_dev_ok'},
      );
      expect(cdpLaunchCount, 0);
      expect(
        manager.providerFor('apple_music')!.authState,
        StreamingAuthState.connected,
      );
    });
  });

  group('ExtraInfo capture & StreamingLoginDialog YouTube Music BYOK auto-fallback', () {
    test('captures headers delivered via Network.requestWillBeSentExtraInfo', () async {
      _MockCdpServer? cdpServer;
      addTearDown(() async => cdpServer?.close());

      final service = LocalBrowserAuthService(
        candidatePathsOverride: const [r'C:\FakeBrowser\msedge.exe'],
        fileExistsOverride: (_) => true,
        cdpDiscoveryInterval: const Duration(milliseconds: 20),
        pollInterval: const Duration(milliseconds: 40),
        processStarter: (_, args) async {
          final port = _extractDebuggingPort(args);
          final proc = _FakeBrowserProcess(pid: 91001);
          cdpServer = await _MockCdpServer.start(
            port: port,
            initialTargets: [
              _MockCdpPageTarget(id: 'td', url: 'https://listen.tidal.com/'),
            ],
          );
          var sent = false;
          cdpServer!.onCommandReceived = (targetId, method, _) {
            if (sent || method != 'Runtime.enable') return;
            sent = true;
            scheduleMicrotask(() {
              cdpServer!.sendEvent(targetId, 'Page.frameNavigated', {
                'frame': {'id': 'f1', 'url': 'https://listen.tidal.com/'},
              });
              cdpServer!.sendEvent(targetId, 'Network.requestWillBeSent', {
                'requestId': 'req_extra_1',
                'request': {
                  'url': 'https://api.tidal.com/v1/sessions',
                  'headers': <String, String>{},
                },
              });
              cdpServer!.sendEvent(targetId, 'Network.requestWillBeSentExtraInfo', {
                'requestId': 'req_extra_1',
                'headers': <String, String>{
                  'Authorization': 'Bearer extra_info_tok_99',
                },
              });
            });
          };
          return proc;
        },
      );

      final res = await service.openAuthWindow(
        WebViewAuthRequest.presetFor('tidal'),
      );
      expect(res.captured, isTrue);
      expect(res.header('authorization'), 'Bearer extra_info_tok_99');
    });

    testWidgets('StreamingLoginDialog collects youtube_music client_id for automatic Device Flow fallback on block', (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.5;
      tester.view.physicalSize = const Size(1280, 920);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final apiServer = await tester.runAsync(
        () => _startStreamingMockApiServer(includeGoogleDeviceOAuth: true),
      );
      addTearDown(() => unawaited(apiServer!.close(force: true)));
      final baseUrl = 'http://127.0.0.1:${apiServer!.port}';

      _MockCdpServer? cdp;
      addTearDown(() {
        final active = cdp;
        if (active != null) {
          unawaited(active.close());
        }
      });

      final service = LocalBrowserAuthService(
        candidatePathsOverride: const [r'C:\FakeBrowser\msedge.exe'],
        fileExistsOverride: (_) => true,
        cdpDiscoveryInterval: const Duration(milliseconds: 20),
        pollInterval: const Duration(milliseconds: 40),
        processStarter: (_, args) async {
          final port = _extractDebuggingPort(args);
          final proc = _FakeBrowserProcess(pid: 92001);
          cdp = await Zone.root.run(
            () => _MockCdpServer.start(
              port: port,
              initialTargets: [
                _MockCdpPageTarget(id: 'yt', url: 'https://music.youtube.com'),
              ],
            ),
          );
          var sent = false;
          cdp!.onCommandReceived = (targetId, method, _) {
            if (sent || method != 'Runtime.enable') return;
            sent = true;
            Zone.root.scheduleMicrotask(() {
              cdp!.sendEvent(targetId, 'Page.frameNavigated', {
                'frame': {
                  'id': 'f1',
                  'url': 'https://accounts.google.com/v3/signin/rejected',
                },
              });
            });
          };
          return proc;
        },
      );

      final credStore = MemorySecureCredentialStore();
      final openedUrls = <String>[];
      final manager = StreamingManager(
        credentialStore: credStore,
        webViewAuthService: service,
        providers: <String, StreamingProvider>{
          'youtube_music': YouTubeMusicProvider(
            credentialStore: credStore,
            baseUrl: baseUrl,
            oauthBaseUrl: baseUrl,
            urlOpener: (url) async {
              openedUrls.add(url);
              return true;
            },
          ),
        },
      );
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

      await tester.tap(find.byKey(const Key('btn_signin_youtube_music')));
      await tester.pumpAndSettle();

      // Fill BYOK Google Client ID inside collapsible manual section, then click primary login button.
      await tester.tap(find.byKey(const Key('btn_toggle_manual_token_section')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('login_tab_youtube_music_1')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('input_ytm_client_id')),
        'yt_dialog_client_id',
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('btn_webview_auto_login')));
      await tester.tap(find.byKey(const Key('btn_webview_auto_login')));
      await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('streaming_login_dialog_youtube_music')).evaluate().isEmpty,
      );
      await tester.pumpAndSettle();

      expect(openedUrls, hasLength(1));
      expect(openedUrls.single, contains('/google-device'));
      expect(
        manager.providerFor('youtube_music')!.authState,
        StreamingAuthState.connected,
      );
      await tester.runAsync(() async {
        await cdp?.close();
        cdp = null;
      });
    });
  });

  group('Stage 1 Windows Registry Default Browser, CDP Full Capture & Non-Chromium Safeguard', () {
    test('parseCommandExecutablePath, parseRegQueryOutput, isChromiumBrowserExecutable, and maskSecretForLog handle all formats', () {
      expect(
        parseCommandExecutablePath(
          r'"C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe" --single-argument %1',
        ),
        r'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe',
      );
      expect(
        parseCommandExecutablePath(
          r'C:\Program Files\Zen Browser\zen.exe -osint -url "%1"',
        ),
        r'C:\Program Files\Zen Browser\zen.exe',
      );
      expect(
        parseCommandExecutablePath(
          r'"%ProgramFiles%\Mozilla Firefox\firefox.exe" -osint -url "%1"',
          environmentOverride: const {'ProgramFiles': r'C:\Program Files'},
        ),
        r'C:\Program Files\Mozilla Firefox\firefox.exe',
      );
      expect(parseCommandExecutablePath('   '), isNull);

      const userChoiceStdout = '''
HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\Shell\\Associations\\UrlAssociations\\https\\UserChoice
    ProgId    REG_SZ    BraveHTML
''';
      expect(
        parseRegQueryOutput(userChoiceStdout, expectedValueName: 'ProgId'),
        'BraveHTML',
      );

      const commandStdout = '''
HKEY_CLASSES_ROOT\\BraveHTML\\shell\\open\\command
    (Default)    REG_SZ    "C:\\Program Files\\BraveSoftware\\Brave-Browser\\Application\\brave.exe" --single-argument %1
''';
      expect(
        parseRegQueryOutput(commandStdout),
        r'"C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe" --single-argument %1',
      );

      const localizedDefaultStdout = '''
HKEY_CLASSES_ROOT\\BraveHTML\\shell\\open\\command
    (預設)    REG_SZ    "C:\\Program Files\\BraveSoftware\\Brave-Browser\\Application\\brave.exe" --single-argument %1
''';
      expect(
        parseRegQueryOutput(localizedDefaultStdout),
        r'"C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe" --single-argument %1',
      );

      expect(
        isChromiumBrowserExecutable(
          r'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe',
          progId: 'BraveHTML',
        ),
        isTrue,
      );
      expect(
        isChromiumBrowserExecutable(
          r'C:\Program Files\Google\Chrome\Application\chrome.exe',
          progId: 'ChromeHTML',
        ),
        isTrue,
      );
      expect(
        isChromiumBrowserExecutable(
          r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
          progId: 'MSEdgeHTM',
        ),
        isTrue,
      );
      expect(
        isChromiumBrowserExecutable(
          r'C:\Program Files\Mozilla Firefox\firefox.exe',
          progId: 'FirefoxURL-308046B0AF4A39CB',
        ),
        isFalse,
      );
      expect(
        isChromiumBrowserExecutable(
          r'C:\Program Files\Zen Browser\zen.exe',
          progId: 'ZenURL',
        ),
        isFalse,
      );

      expect(maskSecretForLog('ytm_secret_token_999'), 'ytm_***');
      expect(maskSecretForLog('ab'), '***');
      expect(maskSecretForLog('abcd'), 'a***');
      expect(maskSecretForLog(''), '***');
    });

    test('detectWindowsDefaultBrowser parses BraveHTML, ChromeHTML, MSEdgeHTM (HKCU & HKCR), and FirefoxURL without falling back to Edge', () {
      const braveExe =
          r'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe';
      final braveReg = <String, String>{
        r'HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice|ProgId':
            'BraveHTML',
        r'HKCR\BraveHTML\shell\open\command|':
            '"$braveExe" --single-argument %1',
      };
      final braveDetected = detectWindowsDefaultBrowser(
        isWindowsOverride: true,
        registryReader: (k, v) => braveReg['$k|${v ?? ''}'],
        fileExistsOverride: (p) => p == braveExe,
      );
      expect(braveDetected, isNotNull);
      expect(braveDetected!.progId, 'BraveHTML');
      expect(braveDetected.executablePath, braveExe);
      expect(braveDetected.executableName, 'brave.exe');
      expect(braveDetected.displayName, 'Brave');
      expect(braveDetected.isChromium, isTrue);
      expect(braveDetected.fromRegistry, isTrue);

      // HKCU\Software\Classes\<ProgId> takes priority over HKCR\<ProgId>
      const chromeExe = r'C:\Users\Tester\AppData\Local\Google\Chrome\Application\chrome.exe';
      final chromeReg = <String, String>{
        r'HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice|ProgId':
            'ChromeHTML',
        r'HKCU\Software\Classes\ChromeHTML\shell\open\command|':
            '"$chromeExe" --single-argument %1',
        r'HKCR\ChromeHTML\shell\open\command|':
            r'"C:\Program Files\Google\Chrome\Application\chrome.exe" %1',
      };
      final chromeDetected = detectWindowsDefaultBrowser(
        isWindowsOverride: true,
        registryReader: (k, v) => chromeReg['$k|${v ?? ''}'],
        fileExistsOverride: (p) => p == chromeExe,
      );
      expect(chromeDetected!.executablePath, chromeExe);
      expect(chromeDetected.displayName, 'Google Chrome');
      expect(chromeDetected.isChromium, isTrue);

      const edgeExe =
          r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe';
      final edgeReg = <String, String>{
        r'HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice|ProgId':
            'MSEdgeHTM',
        r'HKCR\MSEdgeHTM\shell\open\command|':
            '"$edgeExe" --single-argument %1',
      };
      final edgeDetected = detectWindowsDefaultBrowser(
        isWindowsOverride: true,
        registryReader: (k, v) => edgeReg['$k|${v ?? ''}'],
        fileExistsOverride: (p) => p == edgeExe,
      );
      expect(edgeDetected!.executablePath, edgeExe);
      expect(edgeDetected.displayName, 'Microsoft Edge');
      expect(edgeDetected.isChromium, isTrue);

      // Non-Chromium FirefoxURL MUST NOT fall back to Edge even when Edge exists on disk!
      const firefoxExe = r'C:\Program Files\Mozilla Firefox\firefox.exe';
      final firefoxReg = <String, String>{
        r'HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice|ProgId':
            'FirefoxURL-308046B0AF4A39CB',
        r'HKCR\FirefoxURL-308046B0AF4A39CB\shell\open\command|':
            '"$firefoxExe" -osint -url "%1"',
      };
      final firefoxService = LocalBrowserAuthService(
        isWindowsOverride: true,
        registryReader: (k, v) => firefoxReg['$k|${v ?? ''}'],
        environmentOverride: const {
          'ProgramFiles(x86)': r'C:\Program Files (x86)',
          'ProgramFiles': r'C:\Program Files',
        },
        fileExistsOverride: (p) => p == firefoxExe || p == edgeExe,
      );
      final resolvedFf = firefoxService.resolveDetectedBrowser();
      expect(resolvedFf, isNotNull);
      expect(resolvedFf!.executablePath, firefoxExe);
      expect(resolvedFf.displayName, 'Firefox');
      expect(resolvedFf.isChromium, isFalse);
      expect(resolvedFf.fromRegistry, isTrue);
      // resolveBrowserPath returns null for non-Chromium so CDP never launches Edge!
      expect(firefoxService.resolveBrowserPath(), isNull);
    });

    test('buildLaunchArguments includes --remote-allow-origins=* and timestamped --user-data-dir, and logs 5s CDP warning before recovering', () async {
      final args = LocalBrowserAuthService.buildLaunchArguments(
        port: 9222,
        profileDirPath: r'C:\Temp\lumina_auth_qobuz_1700000000000_xyz',
        initialUrl: 'https://play.qobuz.com/login',
      );
      expect(args, contains('--remote-allow-origins=*'));
      expect(args, contains('--remote-debugging-port=9222'));
      expect(
        args,
        contains(r'--user-data-dir=C:\Temp\lumina_auth_qobuz_1700000000000_xyz'),
      );
      expect(args, contains('--no-first-run'));
      expect(args, contains('--no-default-browser-check'));
      expect(args, contains('--disable-default-apps'));
      expect(args, contains('--new-window'));
      expect(args, contains('--disable-blink-features=AutomationControlled'));
      expect(args.last, 'https://play.qobuz.com/login');

      const braveExe =
          r'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe';
      final reg = <String, String>{
        r'HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice|ProgId':
            'BraveHTML',
        r'HKCR\BraveHTML\shell\open\command|': '"$braveExe" --single-argument %1',
      };

      final logs = <String>[];
      late _MockCdpServer cdpServer;
      late List<String> capturedArgs;
      addTearDown(() async => cdpServer.close());

      final service = LocalBrowserAuthService(
        isWindowsOverride: true,
        registryReader: (k, v) => reg['$k|${v ?? ''}'],
        fileExistsOverride: (p) => p == braveExe,
        cdpDiscoveryInterval: const Duration(milliseconds: 25),
        cdpWarningThreshold: const Duration(milliseconds: 70),
        cdpDiscoveryTimeout: const Duration(seconds: 3),
        pollInterval: const Duration(milliseconds: 40),
        logSink: logs.add,
        processStarter: (exe, launchArgs) async {
          expect(exe, braveExe);
          capturedArgs = launchArgs;
          final port = _extractDebuggingPort(launchArgs);
          cdpServer = await _MockCdpServer.start(
            port: port,
            serveEmptyTargetsInitially: true,
            initialTargets: [
              _MockCdpPageTarget(id: 'dz1', url: 'https://www.deezer.com/us/'),
            ],
          );
          cdpServer.storageCookiesProvider = (_) => [
                {
                  'name': 'arl',
                  'value': 'dz_secret_arl_value_999',
                  'domain': '.deezer.com',
                  'httpOnly': true,
                },
                {
                  'name': 'unrelated',
                  'value': 'ignored_cookie',
                  'domain': '.otherdomain.com',
                },
              ];
          // Delay /json/list readiness past cdpWarningThreshold (70ms)
          Timer(const Duration(milliseconds: 140), () {
            cdpServer.serveEmptyTargetsInitially = false;
          });
          return _FakeBrowserProcess(pid: 93001);
        },
      );

      final result = await service.openAuthWindow(
        WebViewAuthRequest.presetFor('deezer'),
      );
      expect(result.captured, isTrue);
      expect(result.detectedBrowserName, 'Brave');
      expect(result.cookie('arl'), 'dz_secret_arl_value_999');
      expect(result.cookie('unrelated'), isNull);
      expect(capturedArgs, contains('--remote-allow-origins=*'));
      final profileDirArg = _extractUserDataDir(capturedArgs);
      expect(
        RegExp(r'lumina_auth_deezer_\d+_').hasMatch(profileDirArg),
        isTrue,
      );

      final joinedLogs = logs.join('\n');
      expect(joinedLogs, contains('[BrowserAuth] Default browser detected: Brave'));
      expect(joinedLogs, contains('[BrowserAuth] Launching Brave'));
      expect(joinedLogs, contains('[BrowserAuth] WARNING: CDP port'));
      expect(joinedLogs, contains('did not respond within'));
      expect(joinedLogs, contains('[BrowserAuth] CDP connected to target dz1'));
      expect(joinedLogs, contains('[BrowserAuth] Captured deezer credentials'));
      expect(joinedLogs, contains('dz_s***'));
      expect(joinedLogs, isNot(contains('dz_secret_arl_value_999')));
      expect(joinedLogs, contains('tempProfileDeleted=true'));
    });

    test('captures HttpOnly cookies via Storage.getCookies, Qobuz /user/login via Network.responseReceived + getResponseBody, and localStorage/sessionStorage across platforms', () async {
      _MockCdpServer? cdpServer;
      addTearDown(() async => cdpServer?.close());

      late String activeCase;
      final logs = <String>[];

      final service = LocalBrowserAuthService(
        candidatePathsOverride: const [r'C:\FakeBrowser\brave.exe'],
        fileExistsOverride: (_) => true,
        cdpDiscoveryInterval: const Duration(milliseconds: 20),
        pollInterval: const Duration(milliseconds: 40),
        logSink: logs.add,
        processStarter: (_, args) async {
          final port = _extractDebuggingPort(args);
          final cdp = await _MockCdpServer.start(
            port: port,
            initialTargets: [
              _MockCdpPageTarget(
                id: 't1',
                url: switch (activeCase) {
                  'ytm_storage_cookies' => 'https://music.youtube.com/',
                  'qobuz_response' => 'https://play.qobuz.com/login',
                  'qobuz_storage' => 'https://play.qobuz.com/featured',
                  'tidal_storage' => 'https://listen.tidal.com/',
                  'apple_storage' => 'https://music.apple.com/tw/home',
                  _ => 'about:blank',
                },
              ),
            ],
          );
          cdpServer = cdp;

          var sent = false;
          cdp.onCommandReceived = (targetId, method, _) {
            if (sent || method != 'Runtime.enable') return;
            sent = true;
            scheduleMicrotask(() {
              switch (activeCase) {
                case 'ytm_storage_cookies':
                  cdp.storageCookiesProvider = (_) => [
                        {
                          'name': '__Secure-3PAPISID',
                          'value': 'ytm_http_only_sapisid_888',
                          'domain': '.youtube.com',
                          'httpOnly': true,
                        },
                        {
                          'name': 'unrelated_google',
                          'value': 'ignore_me',
                          'domain': '.google.com',
                        },
                      ];
                  break;
                case 'qobuz_response':
                  cdp.responseBodyProvider = (_, reqId) {
                    if (reqId == 'qb_login_1') {
                      return {
                        'body': jsonEncode({
                          'user': {'id': 42, 'display_name': 'Qobuz User'},
                          'user_auth_token': 'qb_resp_tok_secret_77',
                          'app_id': '285473059',
                        }),
                        'base64Encoded': false,
                      };
                    }
                    return null;
                  };
                  cdp.sendEvent(targetId, 'Network.responseReceived', {
                    'requestId': 'qb_login_1',
                    'response': {
                      'url': 'https://www.qobuz.com/api.json/0.2/user/login',
                      'status': 200,
                    },
                  });
                  break;
                case 'qobuz_storage':
                  cdp.runtimeEvaluateProvider = (_, expr) {
                    if (expr.contains('localStorage')) {
                      return jsonEncode({
                        'local:qobuz_auth': jsonEncode({
                          'user_auth_token': 'qb_ls_tok_secret_11',
                          'app_id': '285473059',
                        }),
                      });
                    }
                    return '';
                  };
                  break;
                case 'tidal_storage':
                  cdp.runtimeEvaluateProvider = (_, expr) {
                    if (expr.contains('localStorage')) {
                      return jsonEncode({
                        'local:_tidal_session': jsonEncode({
                          'oAuthAccessToken': 'tidal_ls_bearer_secret_22',
                        }),
                      });
                    }
                    return '';
                  };
                  break;
                case 'apple_storage':
                  cdp.runtimeEvaluateProvider = (_, expr) {
                    if (expr.contains('localStorage')) {
                      return jsonEncode({
                        'local:developerToken': 'apple_ls_dev_jwt_33',
                        'session:media-user-token': 'apple_ss_mut_tok_44',
                      });
                    }
                    return '';
                  };
                  break;
              }
            });
          };
          return _FakeBrowserProcess(pid: 94000);
        },
      );

      // 1. YouTube Music Storage.getCookies domain-filtered HttpOnly capture
      activeCase = 'ytm_storage_cookies';
      final ytmRes = await service.openAuthWindow(
        WebViewAuthRequest.presetFor('youtube_music'),
      );
      await cdpServer?.close();
      expect(ytmRes.captured, isTrue);
      expect(ytmRes.cookie('__Secure-3PAPISID'), 'ytm_http_only_sapisid_888');
      expect(ytmRes.cookie('unrelated_google'), isNull);
      expect(
        buildAuthParamsFromWebViewResult('youtube_music', ytmRes)['cookie'],
        contains('__Secure-3PAPISID=ytm_http_only_sapisid_888'),
      );

      // 2. Qobuz /api.json/0.2/user/login response body capture (even while URL is /login)
      activeCase = 'qobuz_response';
      final qbRespRes = await service.openAuthWindow(
        WebViewAuthRequest.presetFor('qobuz'),
      );
      await cdpServer?.close();
      expect(qbRespRes.captured, isTrue);
      expect(
        qbRespRes.responseValue('user_auth_token'),
        'qb_resp_tok_secret_77',
      );
      expect(
        buildAuthParamsFromWebViewResult('qobuz', qbRespRes),
        {
          'mode': 'token',
          'user_auth_token': 'qb_resp_tok_secret_77',
          'app_id': '285473059',
        },
      );

      // 3. Qobuz localStorage capture
      activeCase = 'qobuz_storage';
      final qbLsRes = await service.openAuthWindow(
        WebViewAuthRequest.presetFor('qobuz'),
      );
      await cdpServer?.close();
      expect(qbLsRes.captured, isTrue);
      expect(
        buildAuthParamsFromWebViewResult('qobuz', qbLsRes),
        {
          'mode': 'token',
          'user_auth_token': 'qb_ls_tok_secret_11',
          'app_id': '285473059',
        },
      );

      // 4. Tidal localStorage capture
      activeCase = 'tidal_storage';
      final tdLsRes = await service.openAuthWindow(
        WebViewAuthRequest.presetFor('tidal'),
      );
      await cdpServer?.close();
      expect(tdLsRes.captured, isTrue);
      expect(
        buildAuthParamsFromWebViewResult('tidal', tdLsRes),
        {
          'mode': 'access_token',
          'access_token': 'tidal_ls_bearer_secret_22',
        },
      );

      // 5. Apple Music localStorage + sessionStorage capture
      activeCase = 'apple_storage';
      final amLsRes = await service.openAuthWindow(
        WebViewAuthRequest.presetFor('apple_music'),
      );
      await cdpServer?.close();
      expect(amLsRes.captured, isTrue);
      expect(
        buildAuthParamsFromWebViewResult('apple_music', amLsRes),
        {
          'mode': 'musickit_tokens',
          'developer_token': 'apple_ls_dev_jwt_33',
          'music_user_token': 'apple_ss_mut_tok_44',
        },
      );

      // Verify zero raw tokens leaked in [BrowserAuth] logs
      final allLogs = logs.join('\n');
      expect(allLogs, isNot(contains('ytm_http_only_sapisid_888')));
      expect(allLogs, isNot(contains('qb_resp_tok_secret_77')));
      expect(allLogs, isNot(contains('qb_ls_tok_secret_11')));
      expect(allLogs, isNot(contains('tidal_ls_bearer_secret_22')));
      expect(allLogs, isNot(contains('apple_ss_mut_tok_44')));
    });

    test('Non-Chromium Firefox/Zen loopback helper serves assisted page, captures POST /submit, and closes cleanly on /close', () async {
      const firefoxExe = r'C:\Program Files\Mozilla Firefox\firefox.exe';
      const edgeExe =
          r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe';
      final firefoxReg = <String, String>{
        r'HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice|ProgId':
            'FirefoxURL-308046B0AF4A39CB',
        r'HKCR\FirefoxURL-308046B0AF4A39CB\shell\open\command|':
            '"$firefoxExe" -osint -url "%1"',
      };

      var chromiumLaunchCount = 0;
      final openedUrls = <String>[];
      final logs = <String>[];

      late String helperUrl;
      var helperReady = Completer<void>();
      final helperService = LocalBrowserAuthService(
        isWindowsOverride: true,
        registryReader: (k, v) => firefoxReg['$k|${v ?? ''}'],
        fileExistsOverride: (p) => p == firefoxExe || p == edgeExe,
        logSink: logs.add,
        systemUrlOpener: (url) async {
          openedUrls.add(url);
          return true;
        },
        processStarter: (_, _) async {
          chromiumLaunchCount++;
          return _FakeBrowserProcess();
        },
        enableNonChromiumLoopbackHelper: true,
        onNonChromiumLoopbackReady: (url) {
          helperUrl = url;
          if (!helperReady.isCompleted) helperReady.complete();
        },
      );

      final assistedFuture = helperService.openAuthWindow(
        WebViewAuthRequest.presetFor('deezer'),
      );
      await helperReady.future.timeout(const Duration(seconds: 2));
      expect(chromiumLaunchCount, 0);
      expect(openedUrls.single, 'https://www.deezer.com/login');

      final client = HttpClient();
      try {
        final getReq = await client.getUrl(Uri.parse(helperUrl));
        final getResp = await getReq.close();
        final html = await utf8.decoder.bind(getResp).join();
        expect(getResp.statusCode, HttpStatus.ok);
        expect(html, contains('Firefox'));

        final req = await client.postUrl(Uri.parse('${helperUrl}submit'));
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode({'arl': 'dz_firefox_assisted_arl_ok'}));
        final resp = await req.close();
        expect(resp.statusCode, HttpStatus.ok);
        await resp.drain<void>();
      } finally {
        client.close(force: true);
      }

      final assistedRes = await assistedFuture;
      expect(assistedRes.captured, isTrue);
      expect(assistedRes.isNonChromiumDefault, isTrue);
      expect(assistedRes.detectedBrowserName, 'Firefox');
      expect(assistedRes.cookie('arl'), 'dz_firefox_assisted_arl_ok');
      expect(chromiumLaunchCount, 0);

      // Verify /close returns non-captured isNonChromiumDefault: true cleanly
      helperReady = Completer<void>();
      final closeFuture = helperService.openAuthWindow(
        WebViewAuthRequest.presetFor('qobuz'),
      );
      await helperReady.future.timeout(const Duration(seconds: 2));
      final closeClient = HttpClient();
      try {
        final req = await closeClient.postUrl(Uri.parse('${helperUrl}close'));
        final resp = await req.close();
        expect(resp.statusCode, HttpStatus.ok);
        await resp.drain<void>();
      } finally {
        closeClient.close(force: true);
      }
      final closeRes = await closeFuture;
      expect(closeRes.captured, isFalse);
      expect(closeRes.cancelled, isFalse);
      expect(closeRes.isNonChromiumDefault, isTrue);
      expect(closeRes.detectedBrowserName, 'Firefox');
      expect(chromiumLaunchCount, 0);
    });

    testWidgets('Non-Chromium Firefox/Zen default opens real default browser (never Edge) and displays detected browser name in StreamingLoginDialog', (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 920);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const firefoxExe = r'C:\Program Files\Mozilla Firefox\firefox.exe';
      const edgeExe =
          r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe';
      final firefoxReg = <String, String>{
        r'HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice|ProgId':
            'FirefoxURL-308046B0AF4A39CB',
        r'HKCR\FirefoxURL-308046B0AF4A39CB\shell\open\command|':
            '"$firefoxExe" -osint -url "%1"',
      };

      var chromiumLaunchCount = 0;
      final openedUrls = <String>[];
      final logs = <String>[];

      final dialogService = LocalBrowserAuthService(
        isWindowsOverride: true,
        registryReader: (k, v) => firefoxReg['$k|${v ?? ''}'],
        fileExistsOverride: (p) => p == firefoxExe || p == edgeExe,
        logSink: logs.add,
        systemUrlOpener: (url) async {
          openedUrls.add(url);
          return true;
        },
        processStarter: (_, _) async {
          chromiumLaunchCount++;
          return _FakeBrowserProcess();
        },
      );

      final credStore = MemorySecureCredentialStore();
      final manager = StreamingManager(
        credentialStore: credStore,
        webViewAuthService: dialogService,
        logSink: logs.add,
        providers: <String, StreamingProvider>{
          'deezer': DeezerProvider(credentialStore: credStore),
        },
      );
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

      await tester.tap(find.byKey(const Key('btn_signin_deezer')));
      await tester.pumpAndSettle();

      // Dialog displays detected browser name (Firefox) instead of hardcoded Edge/Chrome
      expect(find.textContaining('Firefox'), findsWidgets);

      await tester.tap(find.byKey(const Key('btn_webview_auto_login')));
      await _pumpUntil(
        tester,
        () => find.byKey(const Key('non_chromium_assisted_banner')).evaluate().isNotEmpty,
      );

      expect(chromiumLaunchCount, 0);
      expect(openedUrls.single, 'https://www.deezer.com/login');
      expect(find.byKey(const Key('input_deezer_arl')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('non_chromium_assisted_banner')),
          matching: find.textContaining('Firefox'),
        ),
        findsOneWidget,
      );
      expect(
        manager.providerFor('deezer')!.authState,
        StreamingAuthState.disconnected,
      );
    });
  });
}
