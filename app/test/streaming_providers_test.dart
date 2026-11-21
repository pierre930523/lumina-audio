import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/services/streaming/oauth_helper.dart';
import 'package:lumina_app/services/streaming/providers/apple_music_provider.dart';
import 'package:lumina_app/services/streaming/providers/deezer_provider.dart';
import 'package:lumina_app/services/streaming/providers/qobuz_provider.dart';
import 'package:lumina_app/services/streaming/providers/tidal_provider.dart';
import 'package:lumina_app/services/streaming/providers/youtube_music_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_provider.dart';

typedef RouteHandler = FutureOr<void> Function(
  HttpRequest req,
  String body,
);

Future<HttpServer> _startTestServer(RouteHandler handler) async {
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

Future<void> _sendGet(String url) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close();
    await resp.drain<void>();
  } finally {
    client.close(force: true);
  }
}

Future<void> _sendPostJson(String url, Map<String, dynamic> body) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
    final resp = await req.close();
    await resp.drain<void>();
  } finally {
    client.close(force: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Allow real dart:io HttpClient connections to local HttpServer on 127.0.0.1.
  HttpOverrides.global = null;

  group('SecureCredentialStore & OAuth helpers', () {
    test(
        'WindowsDpapiCredentialStore stores only ciphertext and deletes cleanly',
        () async {
      final tempDir =
          await Directory.systemTemp.createTemp('lumina_dpapi_test_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final storageFile = File('${tempDir.path}\\credentials.dpapi.json');

      final store = WindowsDpapiCredentialStore(
        storageFile: storageFile,
        protectFn: (plain) async =>
            'DPAPI:${base64Encode(utf8.encode(plain))}',
        unprotectFn: (cipher) async {
          if (!cipher.startsWith('DPAPI:')) return null;
          return utf8.decode(base64Decode(cipher.substring(6)));
        },
      );

      await store.write('streaming:qobuz', '{"token":"super_secret_xyz"}');
      expect(storageFile.existsSync(), isTrue);

      final diskRaw = storageFile.readAsStringSync();
      expect(diskRaw.contains('super_secret_xyz'), isFalse);
      expect(diskRaw.contains('DPAPI:'), isTrue);

      final restored = await store.read('streaming:qobuz');
      expect(restored, '{"token":"super_secret_xyz"}');

      await store.delete('streaming:qobuz');
      expect(await store.read('streaming:qobuz'), isNull);
    });

    test(
        'WindowsDpapiCredentialStore never falls back to plaintext if DPAPI fails',
        () async {
      final tempDir =
          await Directory.systemTemp.createTemp('lumina_dpapi_fail_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final storageFile = File('${tempDir.path}\\credentials.dpapi.json');

      final store = WindowsDpapiCredentialStore(
        storageFile: storageFile,
        protectFn: (_) async => '',
        unprotectFn: (_) async => null,
      );

      await expectLater(
        store.write('streaming:tidal', 'secret'),
        throwsA(isA<StreamingException>()),
      );
      expect(storageFile.existsSync(), isFalse);
    });

    test(
        'MethodChannel lumina/window invokes dpapiProtect, dpapiUnprotect, and openUrl',
        () async {
      const channel = MethodChannel('lumina/window');
      final recorded = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        recorded.add(call);
        if (call.method == 'dpapiProtect') {
          return base64Encode(utf8.encode('enc:${call.arguments}'));
        }
        if (call.method == 'dpapiUnprotect') {
          final decoded = utf8.decode(base64Decode(call.arguments as String));
          return decoded.replaceFirst('enc:', '');
        }
        if (call.method == 'openUrl') {
          return null;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final tempDir =
          await Directory.systemTemp.createTemp('lumina_dpapi_ch_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final store = WindowsDpapiCredentialStore(
        channel: channel,
        storageFile: File('${tempDir.path}\\creds.json'),
      );

      await store.write('k1', 'top_secret_123');
      expect(await store.read('k1'), 'top_secret_123');
      expect(
        recorded.map((c) => c.method),
        containsAll(<String>['dpapiProtect', 'dpapiUnprotect']),
      );

      expect(
        await openSystemBrowser('https://example.com/auth', channel: channel),
        isTrue,
      );
      expect(recorded.last.method, 'openUrl');
      expect(recorded.last.arguments, 'https://example.com/auth');

      await expectLater(
        openSystemBrowser('javascript:alert(1)', channel: channel),
        throwsA(isA<StreamingException>()),
      );
      await expectLater(
        openSystemBrowser('file:///C:/Windows/win.ini', channel: channel),
        throwsA(isA<StreamingException>()),
      );
    });

    test(
        'buildMusicKitAuthHtml escapes developerToken to prevent script injection',
        () {
      final html = buildMusicKitAuthHtml(
        'jwt</script><script>alert(1)</script>',
        'http://127.0.0.1:9999/musickit-callback',
      );
      expect(html.contains('</script><script>alert(1)'), isFalse);
      expect(html.contains(r'<\/script><script>alert(1)<\/script>'), isTrue);
      expect(
        html.contains('https://js-cdn.music.apple.com/musickit/v3/musickit.js'),
        isTrue,
      );
    });
  });

  group('YouTubeMusicProvider', () {
    test(
        'validates SAPISIDHASH, parses InnerTube library/search/stream, and rejects 401/guest',
        () async {
      String? capturedAuthHeader;
      var rejectAuth = false;
      var returnGuestOnly = false;
      var returnCipheredOnly = false;

      final server = await _startTestServer((req, body) async {
        final path = req.uri.path;
        if (path == '/youtubei/v1/account/account_menu') {
          capturedAuthHeader = req.headers.value('authorization');
          if (rejectAuth) {
            return _sendJson(req.response, HttpStatus.unauthorized, {
              'error': {
                'code': 401,
                'message': 'Request had invalid credentials',
              }
            });
          }
          if (returnGuestOnly) {
            return _sendJson(req.response, HttpStatus.ok, {
              'actions': [
                {
                  'openPopupAction': {
                    'popup': {
                      'multiPageMenuRenderer': {
                        'sections': [
                          {'itemSectionRenderer': {}}
                        ]
                      }
                    }
                  }
                }
              ]
            });
          }
          return _sendJson(req.response, HttpStatus.ok, {
            'actions': [
              {
                'openPopupAction': {
                  'popup': {
                    'multiPageMenuRenderer': {
                      'header': {
                        'activeAccountHeaderRenderer': {
                          'accountName': {
                            'runs': [
                              {'text': 'Pierre Audio'}
                            ]
                          },
                          'email': {
                            'runs': [
                              {'text': 'pierre@example.com'}
                            ]
                          },
                          'manageAccountTitle': {
                            'runs': [
                              {'text': 'YouTube Music Premium'}
                            ]
                          }
                        }
                      }
                    }
                  }
                }
              }
            ]
          });
        }

        if (path == '/youtubei/v1/browse') {
          final reqJson = jsonDecode(body) as Map<String, dynamic>;
          final browseId = reqJson['browseId']?.toString();
          if (browseId == 'FEmusic_liked_videos' || browseId == 'VL_FAVS') {
            return _sendJson(req.response, HttpStatus.ok, {
              'contents': {
                'musicShelfRenderer': {
                  'contents': [
                    {
                      'musicResponsiveListItemRenderer': {
                        'playlistItemData': {'videoId': 'vid_ytm_1'},
                        'flexColumns': [
                          {
                            'musicResponsiveListItemFlexColumnRenderer': {
                              'text': {
                                'runs': [
                                  {'text': 'Night Drive'}
                                ]
                              }
                            }
                          },
                          {
                            'musicResponsiveListItemFlexColumnRenderer': {
                              'text': {
                                'runs': [
                                  {
                                    'text': 'Midnight Synth',
                                    'navigationEndpoint': {
                                      'browseEndpoint': {
                                        'browseId': 'UC123',
                                        'browseEndpointContextSupportedConfigs': {
                                          'browseEndpointContextMusicConfig': {
                                            'pageType': 'MUSIC_PAGE_TYPE_ARTIST'
                                          }
                                        }
                                      }
                                    }
                                  },
                                  {'text': ' • '},
                                  {
                                    'text': 'Neon Horizon',
                                    'navigationEndpoint': {
                                      'browseEndpoint': {
                                        'browseId': 'MPREb_1',
                                        'browseEndpointContextSupportedConfigs': {
                                          'browseEndpointContextMusicConfig': {
                                            'pageType': 'MUSIC_PAGE_TYPE_ALBUM'
                                          }
                                        }
                                      }
                                    }
                                  },
                                  {'text': ' • '},
                                  {'text': '4:12'}
                                ]
                              }
                            }
                          }
                        ],
                        'thumbnail': {
                          'musicThumbnailRenderer': {
                            'thumbnail': {
                              'thumbnails': [
                                {'url': 'https://lh3.example.com/ytm_cover.jpg'}
                              ]
                            }
                          }
                        }
                      }
                    }
                  ]
                }
              }
            });
          }
          if (browseId == 'FEmusic_liked_playlists') {
            return _sendJson(req.response, HttpStatus.ok, {
              'contents': {
                'gridRenderer': {
                  'items': [
                    {
                      'musicTwoRowItemRenderer': {
                        'title': {
                          'runs': [
                            {'text': 'Late Night Mix'}
                          ]
                        },
                        'subtitle': {
                          'runs': [
                            {'text': 'Playlist • 12 songs'}
                          ]
                        },
                        'navigationEndpoint': {
                          'browseEndpoint': {
                            'browseId': 'VL_FAVS',
                            'browseEndpointContextSupportedConfigs': {
                              'browseEndpointContextMusicConfig': {
                                'pageType': 'MUSIC_PAGE_TYPE_PLAYLIST'
                              }
                            }
                          }
                        }
                      }
                    }
                  ]
                }
              }
            });
          }
          if (browseId == 'FEmusic_liked_albums') {
            return _sendJson(req.response, HttpStatus.ok, {
              'contents': {
                'gridRenderer': {
                  'items': [
                    {
                      'musicTwoRowItemRenderer': {
                        'title': {
                          'runs': [
                            {'text': 'Neon Horizon'}
                          ]
                        },
                        'subtitle': {
                          'runs': [
                            {'text': 'Midnight Synth • 2024'}
                          ]
                        },
                        'navigationEndpoint': {
                          'browseEndpoint': {
                            'browseId': 'MPREb_1',
                            'browseEndpointContextSupportedConfigs': {
                              'browseEndpointContextMusicConfig': {
                                'pageType': 'MUSIC_PAGE_TYPE_ALBUM'
                              }
                            }
                          }
                        }
                      }
                    }
                  ]
                }
              }
            });
          }
        }

        if (path == '/youtubei/v1/search') {
          return _sendJson(req.response, HttpStatus.ok, {
            'contents': {
              'musicShelfRenderer': {
                'contents': [
                  {
                    'musicResponsiveListItemRenderer': {
                      'playlistItemData': {'videoId': 'vid_search_9'},
                      'flexColumns': [
                        {
                          'musicResponsiveListItemFlexColumnRenderer': {
                            'text': {
                              'runs': [
                                {'text': 'Search Track'}
                              ]
                            }
                          }
                        },
                        {
                          'musicResponsiveListItemFlexColumnRenderer': {
                            'text': {
                              'runs': [
                                {'text': 'Search Artist'}
                              ]
                            }
                          }
                        }
                      ]
                    }
                  }
                ]
              }
            }
          });
        }

        if (path == '/youtubei/v1/player') {
          if (returnCipheredOnly) {
            return _sendJson(req.response, HttpStatus.ok, {
              'playabilityStatus': {'status': 'OK'},
              'streamingData': {
                'adaptiveFormats': [
                  {
                    'itag': 251,
                    'mimeType': 'audio/webm; codecs="opus"',
                    'bitrate': 160000,
                    'signatureCipher': 's=encrypted'
                  }
                ]
              }
            });
          }
          return _sendJson(req.response, HttpStatus.ok, {
            'playabilityStatus': {'status': 'OK'},
            'streamingData': {
              'adaptiveFormats': [
                {
                  'itag': 140,
                  'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
                  'bitrate': 128000,
                  'audioSampleRate': '44100',
                  'audioChannels': 2,
                  'url': 'https://rr1.example.com/audio_140.m4a'
                },
                {
                  'itag': 251,
                  'mimeType': 'audio/webm; codecs="opus"',
                  'bitrate': 165000,
                  'audioSampleRate': '48000',
                  'audioChannels': 2,
                  'url': 'https://rr1.example.com/audio_251.webm'
                }
              ]
            }
          });
        }

        return _sendJson(req.response, HttpStatus.notFound, {'error': '404'});
      });
      addTearDown(() => server.close(force: true));

      final store = MemorySecureCredentialStore();
      DateTime fixedClock() =>
          DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final provider = YouTubeMusicProvider(
        credentialStore: store,
        baseUrl: 'http://127.0.0.1:${server.port}',
        clock: fixedClock,
      );

      // Reject cookie missing SAPISID.
      await expectLater(
        provider.authenticate({'mode': 'cookie', 'cookie': 'VISITOR=123'}),
        throwsA(isA<StreamingException>()),
      );
      expect(provider.authState, StreamingAuthState.error);
      expect(provider.lastError, isNotEmpty);

      // Reject HTTP 401.
      rejectAuth = true;
      await expectLater(
        provider.authenticate({
          'mode': 'cookie',
          'cookie': 'SAPISID=my_sapisid_val; SID=abc',
        }),
        throwsA(isA<StreamingException>()),
      );
      expect(provider.authState, StreamingAuthState.error);

      // Reject unauthenticated guest menu even with HTTP 200.
      rejectAuth = false;
      returnGuestOnly = true;
      await expectLater(
        provider.authenticate({
          'mode': 'cookie',
          'cookie': 'SAPISID=my_sapisid_val; SID=abc',
        }),
        throwsA(isA<StreamingException>()),
      );
      expect(provider.authState, StreamingAuthState.error);

      // Valid cookie login + exact SAPISIDHASH verification.
      returnGuestOnly = false;
      await provider.authenticate({
        'mode': 'cookie',
        'cookie': '__Secure-3PAPISID=sapi_secret_99; SID=abc',
      });
      expect(provider.authState, StreamingAuthState.connected);
      expect(provider.accountInfo?.displayName, 'Pierre Audio');
      expect(provider.accountInfo?.email, 'pierre@example.com');

      final expectedDigest = sha1
          .convert(
            utf8.encode('1700000000 sapi_secret_99 https://music.youtube.com'),
          )
          .toString();
      expect(capturedAuthHeader, 'SAPISIDHASH 1700000000_$expectedDigest');

      final catalog = await provider.syncLibrary();
      expect(catalog.tracks.length, 1);
      expect(catalog.tracks.first.id, 'ytm:vid_ytm_1');
      expect(catalog.tracks.first.title, 'Night Drive');
      expect(catalog.tracks.first.artist, 'Midnight Synth');
      expect(
        catalog.tracks.first.duration,
        const Duration(minutes: 4, seconds: 12),
      );
      expect(catalog.playlists.single.id, 'VL_FAVS');
      expect(catalog.albums.single.title, 'Neon Horizon');

      final playlistTracks = await provider.fetchPlaylistTracks('VL_FAVS');
      expect(playlistTracks.single.id, 'ytm:vid_ytm_1');

      final searchRes = await provider.search('Search');
      expect(searchRes.tracks.single.id, 'ytm:vid_search_9');

      final stream = await provider.resolveStream(catalog.tracks.first);
      expect(stream.url, 'https://rr1.example.com/audio_251.webm');
      expect(stream.format.codec, AudioCodec.opus);
      expect(stream.format.sampleRateHz, 48000);
      expect(stream.hintExtension, 'webm');

      returnCipheredOnly = true;
      await expectLater(
        provider.resolveStream(catalog.tracks.first),
        throwsA(isA<StreamingException>()),
      );
    });

    test(
        'supports Google OAuth Device Flow polling, cancellation, and refresh',
        () async {
      var pollCount = 0;
      var refreshCalls = 0;

      final server = await _startTestServer((req, body) async {
        final path = req.uri.path;
        if (path == '/device/code') {
          return _sendJson(req.response, HttpStatus.ok, {
            'device_code': 'dev_code_1',
            'user_code': 'ABCD-EFGH',
            'verification_url': 'https://www.google.com/device',
            'expires_in': 600,
            'interval': 0,
          });
        }
        if (path == '/token') {
          final form = Uri.splitQueryString(body);
          if (form['grant_type'] == 'refresh_token') {
            refreshCalls++;
            return _sendJson(req.response, HttpStatus.ok, {
              'access_token': 'ytm_refreshed_access',
              'expires_in': 3600,
            });
          }
          pollCount++;
          if (pollCount < 2) {
            return _sendJson(req.response, HttpStatus.preconditionRequired, {
              'error': 'authorization_pending',
            });
          }
          return _sendJson(req.response, HttpStatus.ok, {
            'access_token': 'ytm_access_1',
            'refresh_token': 'ytm_refresh_1',
            'expires_in': 30,
          });
        }
        if (path == '/youtubei/v1/account/account_menu') {
          final auth = req.headers.value('authorization');
          if (auth != 'Bearer ytm_access_1' &&
              auth != 'Bearer ytm_refreshed_access') {
            return _sendJson(req.response, HttpStatus.unauthorized, {
              'error': {'message': 'Invalid bearer'}
            });
          }
          return _sendJson(req.response, HttpStatus.ok, {
            'actions': [
              {
                'openPopupAction': {
                  'popup': {
                    'multiPageMenuRenderer': {
                      'header': {
                        'activeAccountHeaderRenderer': {
                          'accountName': {'simpleText': 'OAuth User'}
                        }
                      }
                    }
                  }
                }
              }
            ]
          });
        }
        return _sendJson(req.response, HttpStatus.notFound, {});
      });
      addTearDown(() => server.close(force: true));

      final store = MemorySecureCredentialStore();
      var openedUrl = '';
      final progressMsgs = <String>[];
      final provider = YouTubeMusicProvider(
        credentialStore: store,
        baseUrl: 'http://127.0.0.1:${server.port}',
        oauthBaseUrl: 'http://127.0.0.1:${server.port}',
        urlOpener: (url) async {
          openedUrl = url;
          return true;
        },
      );

      await provider.authenticate(
        {'mode': 'oauth_device', 'client_id': 'cid', 'client_secret': 'csec'},
        onProgress: progressMsgs.add,
      );
      expect(openedUrl, 'https://www.google.com/device');
      expect(progressMsgs.any((m) => m.contains('ABCD-EFGH')), isTrue);
      expect(provider.authState, StreamingAuthState.connected);
      expect(provider.accountInfo?.displayName, 'OAuth User');

      // Token expires in 30s (< 60s skew), so refreshSessionIfNeeded triggers refresh.
      await provider.refreshSessionIfNeeded();
      expect(refreshCalls, 1);

      // CancellationToken aborts device polling cleanly.
      pollCount = -100;
      final cancel = CancellationToken();
      Timer(const Duration(milliseconds: 20), cancel.cancel);
      await expectLater(
        provider.authenticate(
          {'mode': 'oauth_device', 'client_id': 'cid'},
          cancel: cancel,
        ),
        throwsA(
          predicate<StreamingException>((e) => e.isCancelled),
        ),
      );
      expect(provider.authState, StreamingAuthState.disconnected);
    });
  });

  group('TidalProvider', () {
    test(
        'verifies PKCE S256 OAuth, device flow, token refresh, Hi-Res BTS manifest, and DASH DRM error',
        () async {
      String? capturedChallenge;
      var returnDashDrm = false;
      var rejectToken = false;
      var devicePolls = 0;

      final server = await _startTestServer((req, body) async {
        final path = req.uri.path;
        if (path == '/v1/oauth2/device_authorization') {
          return _sendJson(req.response, HttpStatus.ok, {
            'deviceCode': 'tidal_dev_1',
            'userCode': 'TDL99',
            'verificationUriComplete': 'link.tidal.com/TDL99',
            'expiresIn': 300,
            'interval': 0,
          });
        }
        if (path == '/v1/oauth2/token') {
          final form = Uri.splitQueryString(body);
          if (form['grant_type'] == 'authorization_code') {
            final verifier = form['code_verifier'] ?? '';
            final computed = base64UrlEncode(
              sha256.convert(ascii.encode(verifier)).bytes,
            ).replaceAll('=', '');
            if (computed != capturedChallenge) {
              return _sendJson(req.response, HttpStatus.badRequest, {
                'error': 'invalid_grant',
                'error_description': 'PKCE verifier mismatch',
              });
            }
            return _sendJson(req.response, HttpStatus.ok, {
              'access_token': 'tidal_acc_1',
              'refresh_token': 'tidal_ref_1',
              'expires_in': 20,
              'user_id': 778899,
            });
          }
          if (form['grant_type'] == 'urn:ietf:params:oauth:grant-type:device_code') {
            devicePolls++;
            if (devicePolls < 2) {
              return _sendJson(req.response, HttpStatus.badRequest, {
                'error': 'authorization_pending',
              });
            }
            return _sendJson(req.response, HttpStatus.ok, {
              'access_token': 'tidal_acc_1',
              'refresh_token': 'tidal_ref_1',
              'expires_in': 3600,
              'user_id': 778899,
            });
          }
          if (form['grant_type'] == 'refresh_token') {
            return _sendJson(req.response, HttpStatus.ok, {
              'access_token': 'tidal_acc_refreshed',
              'refresh_token': 'tidal_ref_2',
              'expires_in': 3600,
            });
          }
        }
        if (path == '/sessions') {
          final auth = req.headers.value('authorization');
          if (rejectToken ||
              (auth != 'Bearer tidal_acc_1' &&
                  auth != 'Bearer tidal_acc_refreshed')) {
            return _sendJson(req.response, HttpStatus.unauthorized, {
              'userMessage': 'Token expired',
            });
          }
          return _sendJson(req.response, HttpStatus.ok, {
            'sessionId': 'sess-1',
            'userId': 778899,
            'countryCode': 'TW',
          });
        }
        if (path == '/users/778899') {
          return _sendJson(req.response, HttpStatus.ok, {
            'id': 778899,
            'username': 'audiophile_tw',
            'firstName': 'Pierre',
            'lastName': 'Lin',
            'email': 'tidal@example.com',
          });
        }
        if (path == '/users/778899/subscription') {
          return _sendJson(req.response, HttpStatus.ok, {
            'subscription': {'type': 'HI_RES_PLUS'},
            'highestSoundQuality': 'HI_RES_LOSSLESS',
          });
        }
        if (path == '/users/778899/favorites/tracks' ||
            path == '/playlists/pl-jazz-1/tracks' ||
            path == '/search/tracks') {
          return _sendJson(req.response, HttpStatus.ok, {
            'items': [
              {
                'item': {
                  'id': 555001,
                  'title': 'Kind of Blue',
                  'duration': 562,
                  'audioQuality': 'HI_RES_LOSSLESS',
                  'artist': {'name': 'Miles Davis'},
                  'album': {
                    'title': 'Kind of Blue (Legacy Edition)',
                    'cover': '1111-2222-3333-4444'
                  }
                }
              }
            ]
          });
        }
        if (path == '/users/778899/favorites/albums' ||
            path == '/search/albums') {
          return _sendJson(req.response, HttpStatus.ok, {
            'items': [
              {
                'item': {
                  'id': 9001,
                  'title': 'Kind of Blue (Legacy Edition)',
                  'releaseDate': '1959-08-17',
                  'numberOfTracks': 6,
                  'audioQuality': 'HI_RES_LOSSLESS',
                  'artist': {'name': 'Miles Davis'}
                }
              }
            ]
          });
        }
        if (path == '/users/778899/playlists') {
          return _sendJson(req.response, HttpStatus.ok, {
            'items': [
              {
                'uuid': 'pl-jazz-1',
                'title': 'Midnight Jazz',
                'numberOfTracks': 10,
              }
            ]
          });
        }
        if (path == '/tracks/555001/playbackinfopostpaywall') {
          if (returnDashDrm) {
            return _sendJson(req.response, HttpStatus.ok, {
              'manifestMimeType': 'application/dash+xml',
              'manifest': base64Encode(utf8.encode('<MPD></MPD>')),
            });
          }
          final btsManifest = jsonEncode({
            'mimeType': 'audio/flac',
            'codecs': 'flac',
            'encryptionType': 'NONE',
            'bitDepth': 24,
            'sampleRate': 192000,
            'urls': ['https://sp-pr-cf.audio.tidal.com/555001_192.flac'],
          });
          return _sendJson(req.response, HttpStatus.ok, {
            'audioQuality': 'HI_RES_LOSSLESS',
            'manifestMimeType': 'application/vnd.tidal.bts',
            'manifest': base64Encode(utf8.encode(btsManifest)),
          });
        }
        return _sendJson(req.response, HttpStatus.notFound, {});
      });
      addTearDown(() => server.close(force: true));

      final store = MemorySecureCredentialStore();
      final base = 'http://127.0.0.1:${server.port}';
      final provider = TidalProvider(
        credentialStore: store,
        authBaseUrl: base,
        tokenBaseUrl: base,
        apiBaseUrl: base,
        urlOpener: (authUrl) async {
          final uri = Uri.parse(authUrl);
          if (uri.path == '/authorize') {
            expect(uri.queryParameters['code_challenge_method'], 'S256');
            capturedChallenge = uri.queryParameters['code_challenge'];
            final redirectUri = uri.queryParameters['redirect_uri']!;
            final state = uri.queryParameters['state']!;
            unawaited(
              _sendGet('$redirectUri?code=tidal_auth_code_99&state=$state'),
            );
          }
          return true;
        },
      );

      await provider.authenticate({'mode': 'pkce', 'client_id': 'lumina_cid'});
      expect(provider.authState, StreamingAuthState.connected);
      expect(provider.accountInfo?.displayName, 'Pierre Lin');
      expect(provider.accountInfo?.countryCode, 'TW');
      expect(provider.accountInfo?.planTier, contains('HI_RES_PLUS'));

      // Verify refresh works cleanly when close to expiry.
      await provider.refreshSessionIfNeeded();
      final persisted = await store.read('streaming:tidal');
      expect(persisted, contains('tidal_acc_refreshed'));

      final catalog = await provider.syncLibrary();
      expect(catalog.tracks.single.id, 'tidal:555001');
      expect(catalog.tracks.single.format.bitDepth, 24);
      expect((await provider.fetchPlaylistTracks('pl-jazz-1')).length, 1);
      expect((await provider.search('Miles')).tracks.length, 1);

      final stream = await provider.resolveStream(catalog.tracks.single);
      expect(stream.url, 'https://sp-pr-cf.audio.tidal.com/555001_192.flac');
      expect(stream.format.codec, AudioCodec.flac);
      expect(stream.format.sampleRateHz, 192000);
      expect(stream.format.bitDepth, 24);

      returnDashDrm = true;
      await expectLater(
        provider.resolveStream(catalog.tracks.single),
        throwsA(predicate<StreamingException>((e) => e.isDrmRestricted)),
      );

      // Device flow works too.
      final progress = <String>[];
      await provider.authenticate(
        {'mode': 'device_code', 'client_id': 'lumina_cid'},
        onProgress: progress.add,
      );
      expect(progress.any((m) => m.contains('TDL99')), isTrue);
      expect(provider.authState, StreamingAuthState.connected);

      // 401 failure must transition authState to error.
      rejectToken = true;
      await expectLater(
        provider.authenticate({'mode': 'access_token', 'access_token': 'bad'}),
        throwsA(isA<StreamingException>()),
      );
      expect(provider.authState, StreamingAuthState.error);
      expect(provider.lastError, contains('Token expired'));
    });
  });

  group('QobuzProvider', () {
    test(
        'authenticates MD5 credentials & live token, verifies MD5 request_sig and Hi-Res resolution',
        () async {
      String? capturedSig;
      String? capturedTs;
      var rejectUserGet = false;
      const failFormat27 = true;

      const appSecret = 'qobuz_secret_key_77';

      final server = await _startTestServer((req, body) async {
        final path = req.uri.path;
        final appId = req.headers.value('x-app-id');
        if (appId == null || appId.isEmpty) {
          return _sendJson(req.response, HttpStatus.badRequest, {
            'message': 'Missing X-App-Id',
          });
        }

        if (path == '/user/login') {
          final form = Uri.splitQueryString(body);
          final expectedMd5 =
              md5.convert(utf8.encode('my_secret_pw')).toString();
          if (form['password'] != expectedMd5) {
            return _sendJson(req.response, HttpStatus.unauthorized, {
              'status': 'error',
              'message': 'Wrong email or password',
            });
          }
          return _sendJson(req.response, HttpStatus.ok, {
            'user_auth_token': 'qobuz_tok_valid',
            'user': {
              'id': 4242,
              'display_name': 'Qobuz Audiophile',
              'email': form['email'],
              'country_code': 'FR',
              'credential': {'label': 'Studio Premier'}
            }
          });
        }

        if (path == '/user/get') {
          final tok = req.headers.value('x-user-auth-token');
          if (rejectUserGet) {
            return _sendJson(req.response, HttpStatus.notFound, {
              'message': 'Endpoint disabled'
            });
          }
          if (tok != 'qobuz_tok_valid') {
            return _sendJson(req.response, HttpStatus.unauthorized, {
              'message': 'Invalid user_auth_token'
            });
          }
          return _sendJson(req.response, HttpStatus.ok, {
            'user': {
              'id': 4242,
              'login': 'qobuz_user',
              'display_name': 'Qobuz Audiophile',
              'credential': {'label': 'Studio Sublime'}
            }
          });
        }

        if (path == '/favorite/getUserFavorites' ||
            path == '/catalog/search' ||
            path == '/playlist/get') {
          if (req.headers.value('x-user-auth-token') != 'qobuz_tok_valid') {
            return _sendJson(req.response, HttpStatus.unauthorized, {
              'message': 'Unauthorized'
            });
          }
          return _sendJson(req.response, HttpStatus.ok, {
            'tracks': {
              'items': [
                {
                  'id': 889911,
                  'title': 'Take Five',
                  'duration': 324,
                  'maximum_sampling_rate': 192.0,
                  'maximum_bit_depth': 24,
                  'performer': {'name': 'The Dave Brubeck Quartet'},
                  'album': {
                    'title': 'Time Out',
                    'image': {'large': 'https://static.qobuz.com/cover.jpg'}
                  }
                }
              ]
            },
            'albums': {'items': []}
          });
        }

        if (path == '/playlist/getUserPlaylists') {
          return _sendJson(req.response, HttpStatus.ok, {
            'playlists': {
              'items': [
                {'id': 'qp1', 'name': 'Hi-Res Classics', 'tracks_count': 1}
              ]
            }
          });
        }

        if (path == '/track/getFileUrl') {
          final qp = req.uri.queryParameters;
          final fmt = int.parse(qp['format_id']!);
          final trackId = qp['track_id']!;
          capturedTs = qp['request_ts'];
          capturedSig = qp['request_sig'];

          final expected = md5
              .convert(
                utf8.encode(
                  'trackgetFileUrlformat_id${fmt}intentstreamtrack_id$trackId$capturedTs$appSecret',
                ),
              )
              .toString();
          if (capturedSig != expected) {
            return _sendJson(req.response, HttpStatus.badRequest, {
              'message': 'Invalid request signature'
            });
          }
          if (fmt == 27 && failFormat27) {
            return _sendJson(req.response, HttpStatus.notFound, {
              'message': 'Format 27 unavailable'
            });
          }
          return _sendJson(req.response, HttpStatus.ok, {
            'track_id': 889911,
            'format_id': fmt,
            'sampling_rate': 96.0,
            'bit_depth': 24,
            'mime_type': 'audio/flac',
            'url': 'https://streaming-qobuz.example.com/889911_24_96.flac',
          });
        }

        return _sendJson(req.response, HttpStatus.notFound, {});
      });
      addTearDown(() => server.close(force: true));

      final store = MemorySecureCredentialStore();
      final provider = QobuzProvider(
        credentialStore: store,
        baseUrl: 'http://127.0.0.1:${server.port}',
      );

      // Invalid password rejected.
      await expectLater(
        provider.authenticate({
          'mode': 'credentials',
          'email': 'hi@example.com',
          'password': 'wrong',
          'app_id': '12345',
        }),
        throwsA(isA<StreamingException>()),
      );
      expect(provider.authState, StreamingAuthState.error);

      // Missing app_secret prevents signed URL resolution honestly.
      await provider.authenticate({
        'mode': 'credentials',
        'email': 'hi@example.com',
        'password': 'my_secret_pw',
        'app_id': '12345',
      });
      expect(provider.authState, StreamingAuthState.connected);
      expect(provider.accountInfo?.planTier, 'Studio Premier');

      final catalog = await provider.syncLibrary();
      expect(catalog.tracks.single.id, 'qobuz:889911');
      expect(catalog.tracks.single.format.sampleRateHz, 192000);
      expect((await provider.fetchPlaylistTracks('qp1')).length, 1);
      expect((await provider.search('Take Five')).tracks.length, 1);

      await expectLater(
        provider.resolveStream(catalog.tracks.single),
        throwsA(
          predicate<StreamingException>((e) => e.message.contains('app_secret')),
        ),
      );

      // Token login with app_secret verifies MD5 signature & format fallback 27 -> 7.
      rejectUserGet = true;
      await provider.authenticate({
        'mode': 'token',
        'user_auth_token': 'qobuz_tok_valid',
        'app_id': '12345',
        'app_secret': appSecret,
      });
      expect(provider.authState, StreamingAuthState.connected);

      final stream = await provider.resolveStream(catalog.tracks.single);
      expect(
        stream.url,
        'https://streaming-qobuz.example.com/889911_24_96.flac',
      );
      expect(stream.format.codec, AudioCodec.flac);
      expect(stream.format.sampleRateHz, 96000);
      expect(stream.format.bitDepth, 24);
      expect(capturedSig, isNotEmpty);
    });
  });

  group('DeezerProvider', () {
    test(
        'rejects ARL USER_ID == 0, supports OAuth & HTTP-200 error rejection, resolves lossless & preview',
        () async {
      var returnEmptyMedia = false;
      var rejectOAuthUserMe = false;

      final server = await _startTestServer((req, body) async {
        final path = req.uri.path;
        if (path == '/gw-light.php') {
          final method = req.uri.queryParameters['method'];
          final cookie = req.headers.value('cookie') ?? '';
          if (method == 'deezer.getUserData') {
            if (!cookie.contains('arl=valid_arl_99')) {
              return _sendJson(req.response, HttpStatus.ok, {
                'error': [],
                'results': {
                  'USER': {'USER_ID': 0, 'BLOG_NAME': ''}
                }
              });
            }
            return _sendJson(req.response, HttpStatus.ok, {
              'error': [],
              'results': {
                'checkForm': 'dz_csrf_token',
                'OFFER_NAME': 'Deezer HiFi',
                'COUNTRY': 'TW',
                'USER': {
                  'USER_ID': 998877,
                  'BLOG_NAME': 'DeezerListener',
                  'EMAIL': 'dz@example.com',
                  'OPTIONS': {
                    'license_token': 'dz_lic_123',
                    'web_lossless': true,
                    'web_hq': true,
                  }
                }
              }
            });
          }
          if (method == 'song.getData') {
            return _sendJson(req.response, HttpStatus.ok, {
              'error': [],
              'results': {'SNG_ID': '3135556', 'TRACK_TOKEN': 'dz_track_tok'}
            });
          }
        }

        if (path == '/oauth/access_token.php') {
          return _sendJson(req.response, HttpStatus.ok, {
            'access_token': 'dz_oauth_tok',
            'expires': 0,
          });
        }

        if (path == '/user/me') {
          if (rejectOAuthUserMe) {
            return _sendJson(req.response, HttpStatus.ok, {
              'error': {
                'type': 'OAuthException',
                'message': 'Invalid OAuth access token',
                'code': 300,
              }
            });
          }
          return _sendJson(req.response, HttpStatus.ok, {
            'id': 998877,
            'name': 'Deezer OAuth User',
            'country': 'TW',
          });
        }

        if (path == '/v1/get_url') {
          if (returnEmptyMedia) {
            return _sendJson(req.response, HttpStatus.ok, {'data': []});
          }
          return _sendJson(req.response, HttpStatus.ok, {
            'data': [
              {
                'media': [
                  {
                    'format': 'FLAC',
                    'sources': [
                      {'url': 'https://e-cdns-proxy.dzcdn.net/3135556.flac'}
                    ]
                  }
                ]
              }
            ]
          });
        }

        if (path == '/user/998877/tracks' ||
            path == '/playlist/dz_pl_1/tracks' ||
            path == '/search/track') {
          return _sendJson(req.response, HttpStatus.ok, {
            'data': [
              {
                'id': 3135556,
                'title': 'Harder, Better, Faster, Stronger',
                'duration': 224,
                'preview': 'https://cdns-preview.dzcdn.net/3135556_preview.mp3',
                'artist': {'name': 'Daft Punk'},
                'album': {
                  'title': 'Discovery',
                  'cover_xl': 'https://e-cdns-images.dzcdn.net/discovery.jpg'
                }
              }
            ]
          });
        }

        if (path == '/user/998877/albums' ||
            path == '/user/998877/playlists' ||
            path == '/search/album') {
          return _sendJson(req.response, HttpStatus.ok, {'data': []});
        }

        if (path == '/track/3135556') {
          return _sendJson(req.response, HttpStatus.ok, {
            'id': 3135556,
            'preview': 'https://cdns-preview.dzcdn.net/3135556_preview.mp3',
          });
        }

        return _sendJson(req.response, HttpStatus.notFound, {});
      });
      addTearDown(() => server.close(force: true));

      final store = MemorySecureCredentialStore();
      final base = 'http://127.0.0.1:${server.port}';
      final provider = DeezerProvider(
        credentialStore: store,
        gwUrl: '$base/gw-light.php',
        oauthBaseUrl: base,
        apiBaseUrl: base,
        mediaBaseUrl: '$base/v1/get_url',
        urlOpener: (authUrl) async {
          final uri = Uri.parse(authUrl);
          final redirectUri = uri.queryParameters['redirect_uri']!;
          final state = uri.queryParameters['state']!;
          unawaited(_sendGet('$redirectUri?code=dz_code_1&state=$state'));
          return true;
        },
      );

      // USER_ID == 0 must be rejected even on HTTP 200!
      await expectLater(
        provider.authenticate({'mode': 'arl', 'arl': 'expired_arl'}),
        throwsA(
          predicate<StreamingException>(
            (e) => e.isTokenExpired && e.message.contains('USER_ID == 0'),
          ),
        ),
      );
      expect(provider.authState, StreamingAuthState.error);

      // Valid ARL succeeds and extracts lossless stream.
      await provider.authenticate({'mode': 'arl', 'arl': 'valid_arl_99'});
      expect(provider.authState, StreamingAuthState.connected);
      expect(provider.accountInfo?.displayName, 'DeezerListener');
      expect(provider.accountInfo?.planTier, 'Deezer HiFi');

      final catalog = await provider.syncLibrary();
      expect(catalog.tracks.single.id, 'deezer:3135556');
      expect((await provider.fetchPlaylistTracks('dz_pl_1')).length, 1);
      expect((await provider.search('Daft Punk')).tracks.length, 1);

      final lossless = await provider.resolveStream(catalog.tracks.single);
      expect(lossless.url, 'https://e-cdns-proxy.dzcdn.net/3135556.flac');
      expect(lossless.format.codec, AudioCodec.flac);
      expect(lossless.isPreviewOnly, isFalse);

      // Empty media endpoint falls back honestly to official MP3 preview.
      returnEmptyMedia = true;
      final preview = await provider.resolveStream(catalog.tracks.single);
      expect(preview.url, 'https://cdns-preview.dzcdn.net/3135556_preview.mp3');
      expect(preview.format.codec, AudioCodec.mp3);
      expect(preview.isPreviewOnly, isTrue);
      expect(preview.drmNotice, isNotEmpty);

      // OAuth loopback flow + honest preview only.
      await provider.authenticate({
        'mode': 'oauth',
        'app_id': 'dz_app',
        'app_secret': 'dz_sec',
      });
      expect(provider.authState, StreamingAuthState.connected);
      expect(provider.accountInfo?.displayName, 'Deezer OAuth User');
      final oauthStream = await provider.resolveStream(catalog.tracks.single);
      expect(oauthStream.isPreviewOnly, isTrue);

      // Deezer HTTP-200 OAuthException error object rejected cleanly.
      rejectOAuthUserMe = true;
      await expectLater(
        provider.authenticate({
          'mode': 'oauth',
          'app_id': 'dz_app',
          'app_secret': 'dz_sec',
          'code': 'dz_code_1',
        }),
        throwsA(predicate<StreamingException>((e) => e.isTokenExpired)),
      );
      expect(provider.authState, StreamingAuthState.error);
    });
  });

  group('AppleMusicProvider', () {
    test(
        'validates /v1/me/storefront, MusicKit browser callback, artwork sizing, and honest FairPlay DRM',
        () async {
      var stripPreview = false;

      final server = await _startTestServer((req, body) async {
        final auth = req.headers.value('authorization');
        final mut = req.headers.value('music-user-token');
        if (auth != 'Bearer dev_jwt_ok' || mut != 'user_tok_ok') {
          return _sendJson(req.response, HttpStatus.unauthorized, {
            'errors': [
              {'title': 'Unauthorized', 'detail': 'Invalid Music-User-Token'}
            ]
          });
        }

        final path = req.uri.path;
        if (path == '/v1/me/storefront') {
          return _sendJson(req.response, HttpStatus.ok, {
            'data': [
              {
                'id': 'tw',
                'attributes': {'name': 'Taiwan'}
              }
            ]
          });
        }
        if (path == '/v1/me/library/songs' ||
            path == '/v1/me/library/playlists/p.123/tracks') {
          return _sendJson(req.response, HttpStatus.ok, {
            'data': [
              {
                'id': 'i.libSong1',
                'attributes': {
                  'name': '夜に駆ける',
                  'artistName': 'YOASOBI',
                  'albumName': 'THE BOOK',
                  'durationInMillis': 261000,
                  'artwork': {
                    'url': 'https://is1-ssl.mzstatic.com/image/{w}x{h}bb.jpg'
                  },
                  'playParams': {'catalogId': '154321000'}
                }
              }
            ]
          });
        }
        if (path == '/v1/me/library/albums' ||
            path == '/v1/me/library/playlists') {
          return _sendJson(req.response, HttpStatus.ok, {'data': []});
        }
        if (path == '/v1/catalog/tw/search') {
          return _sendJson(req.response, HttpStatus.ok, {
            'results': {
              'songs': {
                'data': [
                  {
                    'id': '154321000',
                    'attributes': {
                      'name': '夜に駆ける',
                      'artistName': 'YOASOBI',
                      'albumName': 'THE BOOK',
                      'durationInMillis': 261000,
                      'url': 'https://music.apple.com/tw/song/154321000',
                      'previews': [
                        {'url': 'https://audio-ssl.itunes.apple.com/prev.m4a'}
                      ]
                    }
                  }
                ]
              }
            }
          });
        }
        if (path == '/v1/catalog/tw/songs/154321000' ||
            path == '/v1/catalog/tw/songs/999999999') {
          return _sendJson(req.response, HttpStatus.ok, {
            'data': [
              {
                'id': path.split('/').last,
                'attributes': {
                  'url': 'https://music.apple.com/tw/song/${path.split('/').last}',
                  'previews': (stripPreview || path.endsWith('999999999'))
                      ? []
                      : [
                          {'url': 'https://audio-ssl.itunes.apple.com/prev.m4a'}
                        ]
                }
              }
            ]
          });
        }
        return _sendJson(req.response, HttpStatus.notFound, {});
      });
      addTearDown(() => server.close(force: true));

      final store = MemorySecureCredentialStore();
      final provider = AppleMusicProvider(
        credentialStore: store,
        apiBaseUrl: 'http://127.0.0.1:${server.port}',
        urlOpener: (authPageUrl) async {
          final client = HttpClient();
          final htmlReq = await client.getUrl(Uri.parse(authPageUrl));
          final htmlResp = await htmlReq.close();
          final html = await utf8.decoder.bind(htmlResp).join();
          client.close(force: true);
          expect(html, contains('MusicKit.configure'));

          final baseUri = Uri.parse(authPageUrl);
          final cbUrl =
              'http://${baseUri.host}:${baseUri.port}/musickit-callback';
          unawaited(_sendPostJson(cbUrl, {'musicUserToken': 'user_tok_ok'}));
          return true;
        },
      );

      // Reject 401 token mode.
      await expectLater(
        provider.authenticate({
          'mode': 'musickit_tokens',
          'developer_token': 'dev_jwt_ok',
          'music_user_token': 'bad_token',
        }),
        throwsA(isA<StreamingException>()),
      );
      expect(provider.authState, StreamingAuthState.error);

      // Browser MusicKit callback mode + storefront validation.
      await provider.authenticate({
        'mode': 'musickit_browser',
        'developer_token': 'dev_jwt_ok',
      });
      expect(provider.authState, StreamingAuthState.connected);
      expect(provider.accountInfo?.countryCode, 'TW');
      expect(provider.accountInfo?.drmNotice, contains('FairPlay DRM'));

      final catalog = await provider.syncLibrary();
      expect(
        catalog.tracks.single.coverUrl,
        'https://is1-ssl.mzstatic.com/image/600x600bb.jpg',
      );
      expect((await provider.fetchPlaylistTracks('p.123')).length, 1);
      expect((await provider.search('YOASOBI')).tracks.length, 1);

      final preview = await provider.resolveStream(catalog.tracks.single);
      expect(preview.url, 'https://audio-ssl.itunes.apple.com/prev.m4a');
      expect(preview.format.codec, AudioCodec.aac);
      expect(preview.isPreviewOnly, isTrue);
      expect(preview.drmNotice, contains('FairPlay DRM'));
      expect(
        preview.externalWebUrl,
        'https://music.apple.com/tw/song/154321000',
      );

      stripPreview = true;
      await expectLater(
        provider.resolveStream(const TrackInfo(
          id: 'apple:999999999',
          title: '無試聽曲目',
          artist: 'YOASOBI',
          album: 'THE BOOK',
          duration: Duration(minutes: 4),
          format: AudioFormat(
            codec: AudioCodec.aac,
            sampleRateHz: 44100,
            bitDepth: 16,
            channels: 2,
          ),
          providerName: 'Apple Music',
        )),
        throwsA(predicate<StreamingException>((e) => e.isDrmRestricted)),
      );
    });
  });

  group('StreamingManager lifecycle', () {
    test(
        'restores valid/expired stored credentials, supports cancelLogin, logout & routing',
        () async {
      var rejectQobuzRestore = false;

      final server = await _startTestServer((req, body) async {
        if (req.uri.path == '/user/get') {
          if (rejectQobuzRestore) {
            return _sendJson(req.response, HttpStatus.unauthorized, {
              'message': 'Expired Qobuz session',
            });
          }
          return _sendJson(req.response, HttpStatus.ok, {
            'user': {
              'id': 1,
              'display_name': 'Manager Qobuz',
              'credential': {'label': 'Studio'}
            }
          });
        }
        if (req.uri.path == '/track/getFileUrl') {
          return _sendJson(req.response, HttpStatus.ok, {
            'format_id': 7,
            'sampling_rate': 96.0,
            'bit_depth': 24,
            'mime_type': 'audio/flac',
            'url': 'https://stream.example.com/ok.flac',
          });
        }
        if (req.uri.path == '/device/code') {
          return _sendJson(req.response, HttpStatus.ok, {
            'device_code': 'dc1',
            'user_code': 'U123',
            'verification_url': 'https://www.google.com/device',
            'expires_in': 600,
            'interval': 5,
          });
        }
        if (req.uri.path == '/token') {
          return _sendJson(req.response, HttpStatus.preconditionRequired, {
            'error': 'authorization_pending',
          });
        }
        return _sendJson(req.response, HttpStatus.notFound, {});
      });
      addTearDown(() => server.close(force: true));

      final store = MemorySecureCredentialStore();
      final qobuz = QobuzProvider(
        credentialStore: store,
        baseUrl: 'http://127.0.0.1:${server.port}',
      );
      await qobuz.authenticate({
        'mode': 'token',
        'app_id': 'aid',
        'app_secret': 'asec',
        'user_auth_token': 'tok_1',
      });

      // Restart with a fresh StreamingManager sharing the same DPAPI store.
      final manager1 = StreamingManager(
        credentialStore: store,
        providers: <String, StreamingProvider>{
          'qobuz': QobuzProvider(
            credentialStore: store,
            baseUrl: 'http://127.0.0.1:${server.port}',
          ),
          'youtube_music': YouTubeMusicProvider(
            credentialStore: store,
            baseUrl: 'http://127.0.0.1:${server.port}',
            oauthBaseUrl: 'http://127.0.0.1:${server.port}',
            urlOpener: (_) async => true,
          ),
        },
      );
      await manager1.initialize();
      expect(manager1.connectedProviders.map((p) => p.kind), ['qobuz']);

      final resolved = await manager1.resolveStreamForTrack(
        const TrackInfo(
          id: 'qobuz:100',
          title: 'Test',
          artist: 'Artist',
          album: 'Album',
          duration: Duration(minutes: 3),
          format: AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: 96000,
            bitDepth: 24,
            channels: 2,
          ),
          providerName: 'Qobuz',
        ),
      );
      expect(resolved.url, 'https://stream.example.com/ok.flac');

      // Cancel in-flight device login via StreamingManager.cancelLogin.
      final loginFuture = manager1.authenticateProvider(
        'youtube_music',
        {'mode': 'oauth_device', 'client_id': 'cid'},
      );
      Timer(const Duration(milliseconds: 30), () {
        manager1.cancelLogin('youtube_music');
      });
      await expectLater(
        loginFuture,
        throwsA(predicate<StreamingException>((e) => e.isCancelled)),
      );
      expect(
        manager1.providerFor('youtube_music')?.authState,
        StreamingAuthState.disconnected,
      );

      // Expired stored token marks provider as error cleanly without throwing.
      rejectQobuzRestore = true;
      final manager2 = StreamingManager(
        credentialStore: store,
        providers: <String, StreamingProvider>{
          'qobuz': QobuzProvider(
            credentialStore: store,
            baseUrl: 'http://127.0.0.1:${server.port}',
          ),
        },
      );
      await manager2.initialize();
      expect(
        manager2.providerFor('qobuz')?.authState,
        StreamingAuthState.error,
      );
      expect(manager2.connectedProviders, isEmpty);

      await manager2.logoutProvider('qobuz');
      expect(
        manager2.providerFor('qobuz')?.authState,
        StreamingAuthState.disconnected,
      );
      expect(await store.read('streaming:qobuz'), isNull);
    });
  });
}
