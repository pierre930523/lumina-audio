import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/services/escape_dismiss_registry.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/streaming/providers/apple_music_provider.dart';
import 'package:lumina_app/services/streaming/providers/deezer_provider.dart';
import 'package:lumina_app/services/streaming/providers/qobuz_provider.dart';
import 'package:lumina_app/services/streaming/providers/tidal_provider.dart';
import 'package:lumina_app/services/streaming/providers/youtube_music_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:lumina_app/ui/home/home_dashboard_view.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxSteps = 100,
}) async {
  for (var step = 0; step < maxSteps && !condition(); step++) {
    await tester.pump(const Duration(milliseconds: 25));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 25));
  }
  if (!condition()) {
    throw TimeoutException('Timed out waiting for UI condition');
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 80));
}

void main() {
  group('Stage 5: Personalized Streaming Recommendations & Album Detail', () {
    test(
      'All 5 providers fetch real personalized recommendations and full CanonicalAlbumDetail from live HTTP endpoints',
      () async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
        });

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        server.listen((req) async {
          final path = req.uri.path;
          Future<void> replyJson(int status, Object body) async {
            req.response.statusCode = status;
            req.response.headers.contentType = ContentType.json;
            req.response.write(jsonEncode(body));
            await req.response.close();
          }

          // 1. Apple Music
          if (path == '/v1/me/storefront') {
            return replyJson(HttpStatus.ok, {
              'data': [
                {
                  'id': 'tw',
                  'attributes': {'name': 'Taiwan'},
                },
              ],
            });
          }
          if (path == '/v1/me/recommendations') {
            return replyJson(HttpStatus.ok, {
              'data': [
                {
                  'id': 'rec_group_1',
                  'type': 'personal-recommendation',
                  'relationships': {
                    'contents': {
                      'data': [
                        {
                          'id': '601',
                          'type': 'albums',
                          'attributes': {
                            'name': 'Apple Spatial Picks',
                            'artistName': 'Apple Studio Ensemble',
                            'releaseDate': '2025-02-14',
                            'trackCount': 2,
                          },
                        },
                      ],
                    },
                  },
                },
              ],
            });
          }
          if (path == '/v1/me/recent/played/tracks') {
            return replyJson(HttpStatus.ok, {
              'data': [
                {
                  'id': '6001',
                  'type': 'songs',
                  'attributes': {
                    'name': 'Apple Rec Song 1',
                    'artistName': 'Apple Studio Ensemble',
                    'albumName': 'Apple Spatial Picks',
                    'durationInMillis': 210000,
                    'previews': [
                      {'url': 'http://127.0.0.1:${server.port}/media/apple.m4a'},
                    ],
                  },
                },
              ],
            });
          }
          if (path == '/v1/catalog/tw/albums/601') {
            return replyJson(HttpStatus.ok, {
              'data': [
                {
                  'id': '601',
                  'type': 'albums',
                  'attributes': {
                    'name': 'Apple Spatial Picks',
                    'artistName': 'Apple Studio Ensemble',
                    'releaseDate': '2025-02-14',
                    'editorialNotes': {'short': 'Curated Spatial Audio'},
                  },
                  'relationships': {
                    'tracks': {
                      'data': [
                        {
                          'id': '6001',
                          'type': 'songs',
                          'attributes': {
                            'name': 'Apple Rec Song 1',
                            'artistName': 'Apple Studio Ensemble',
                            'albumName': 'Apple Spatial Picks',
                            'durationInMillis': 210000,
                            'trackNumber': 1,
                            'discNumber': 1,
                          },
                        },
                      ],
                    },
                  },
                },
              ],
            });
          }

          // 2. YouTube Music
          if (path == '/youtubei/v1/account/account_menu') {
            return replyJson(HttpStatus.ok, {
              'actions': [
                {
                  'openPopupAction': {
                    'popup': {
                      'multiPageMenuRenderer': {
                        'header': {
                          'activeAccountHeaderRenderer': {
                            'accountName': {'simpleText': 'YTM Listener'},
                          },
                        },
                      },
                    },
                  },
                },
              ],
            });
          }
          if (path == '/youtubei/v1/browse') {
            final bodyStr = await utf8.decoder.bind(req).join();
            final bodyJson = jsonDecode(bodyStr) as Map<String, dynamic>;
            final browseId = bodyJson['browseId']?.toString() ?? '';
            if (browseId == 'FEmusic_home') {
              return replyJson(HttpStatus.ok, {
                'contents': {
                  'albumItem': {
                    'musicTwoRowItemRenderer': {
                      'title': {'simpleText': 'YTM Supermix Album'},
                      'subtitle': {'simpleText': 'YTM Artist • 2024'},
                      'navigationEndpoint': {
                        'browseEndpoint': {
                          'browseId': 'MPREb_yt_rec_1',
                          'browseEndpointContextSupportedConfigs': {
                            'browseEndpointContextMusicConfig': {
                              'pageType': 'MUSIC_PAGE_TYPE_ALBUM',
                            },
                          },
                        },
                      },
                    },
                  },
                  'trackItem': {
                    'musicResponsiveListItemRenderer': {
                      'playlistItemData': {'videoId': 'yt_vid_99'},
                      'flexColumns': [
                        {
                          'musicResponsiveListItemFlexColumnRenderer': {
                            'text': {'simpleText': 'YTM Quick Pick Track'},
                          },
                        },
                        {
                          'musicResponsiveListItemFlexColumnRenderer': {
                            'text': {
                              'runs': [
                                {'text': 'YTM Artist'},
                                {'text': ' • '},
                                {'text': 'YTM Supermix Album'},
                                {'text': ' • '},
                                {'text': '3:45'},
                              ],
                            },
                          },
                        },
                      ],
                    },
                  },
                },
              });
            }
            if (browseId == 'MPREb_yt_rec_1') {
              return replyJson(HttpStatus.ok, {
                'header': {
                  'musicResponsiveHeaderRenderer': {
                    'title': {'simpleText': 'YTM Supermix Album'},
                    'straplineTextOne': {'simpleText': 'YTM Artist'},
                    'subtitle': {'simpleText': 'Album • 2024'},
                  },
                },
                'contents': {
                  'track1': {
                    'musicResponsiveListItemRenderer': {
                      'playlistItemData': {'videoId': 'yt_vid_99'},
                      'flexColumns': [
                        {
                          'musicResponsiveListItemFlexColumnRenderer': {
                            'text': {'simpleText': 'YTM Quick Pick Track'},
                          },
                        },
                        {
                          'musicResponsiveListItemFlexColumnRenderer': {
                            'text': {
                              'runs': [
                                {'text': 'YTM Artist'},
                                {'text': ' • '},
                                {'text': '3:45'},
                              ],
                            },
                          },
                        },
                      ],
                    },
                  },
                },
              });
            }
          }

          // 3. Qobuz
          if (path == '/user/login' || path == '/user/get') {
            return replyJson(HttpStatus.ok, {
              'id': 91,
              'display_name': 'Qobuz Audiophile',
              'credential': {'label': 'Studio Sublime'},
              'user_auth_token': 'qobuz_tok_1',
              'user': {
                'id': 91,
                'display_name': 'Qobuz Audiophile',
                'credential': {'label': 'Studio Sublime'},
              },
            });
          }
          if (path == '/album/getFeatured') {
            return replyJson(HttpStatus.ok, {
              'albums': {
                'items': [
                  {
                    'id': '701',
                    'title': 'Qobuz Grand Cru Masters',
                    'artist': {'name': 'Qobuz Philharmonic'},
                    'release_date_original': '2025-01-20',
                    'tracks_count': 2,
                    'maximum_sampling_rate': 192,
                    'maximum_bit_depth': 24,
                  },
                ],
              },
            });
          }
          if (path == '/favorite/getUserFavorites') {
            return replyJson(HttpStatus.ok, {
              'tracks': {
                'items': [
                  {
                    'id': 7001,
                    'title': 'Qobuz Rec Track 1',
                    'duration': 245,
                    'maximum_sampling_rate': 192,
                    'maximum_bit_depth': 24,
                    'performer': {'name': 'Qobuz Philharmonic'},
                    'album': {'title': 'Qobuz Grand Cru Masters'},
                  },
                ],
              },
            });
          }
          if (path == '/album/get') {
            return replyJson(HttpStatus.ok, {
              'id': '701',
              'title': 'Qobuz Grand Cru Masters',
              'artist': {'name': 'Qobuz Philharmonic'},
              'release_date_original': '2025-01-20',
              'maximum_sampling_rate': 192,
              'maximum_bit_depth': 24,
              'tracks': {
                'items': [
                  {
                    'id': 7001,
                    'title': 'Qobuz Rec Track 1',
                    'duration': 245,
                    'track_number': 1,
                    'media_number': 1,
                    'maximum_sampling_rate': 192,
                    'maximum_bit_depth': 24,
                    'performer': {'name': 'Qobuz Philharmonic'},
                    'album': {'title': 'Qobuz Grand Cru Masters'},
                  },
                ],
              },
            });
          }

          // 4. Tidal
          if (path == '/sessions') {
            return replyJson(HttpStatus.ok, {
              'userId': 777,
              'countryCode': 'TW',
            });
          }
          if (path == '/users/777') {
            return replyJson(HttpStatus.ok, {
              'id': 777,
              'fullName': 'Tidal Max User',
            });
          }
          if (path == '/users/777/subscription') {
            return replyJson(HttpStatus.ok, {
              'subscription': {'type': 'HI_RES'},
            });
          }
          if (path == '/pages/home' || path == '/v1/pages/home') {
            return replyJson(HttpStatus.ok, {
              'rows': [
                {
                  'modules': [
                    {
                      'type': 'ALBUM_LIST',
                      'pagedList': {
                        'items': [
                          {
                            'id': 901,
                            'title': 'Tidal Masters Selection',
                            'artist': {'name': 'Nordic Chamber'},
                            'releaseDate': '2024-11-10',
                            'numberOfTracks': 1,
                            'audioQuality': 'HI_RES_LOSSLESS',
                          },
                        ],
                      },
                    },
                    {
                      'type': 'TRACK_LIST',
                      'pagedList': {
                        'items': [
                          {
                            'id': 9001,
                            'title': 'Tidal Daily Discovery 1',
                            'duration': 198,
                            'trackNumber': 1,
                            'volumeNumber': 1,
                            'audioQuality': 'HI_RES_LOSSLESS',
                            'artist': {'name': 'Nordic Chamber'},
                            'album': {'id': 901, 'title': 'Tidal Masters Selection'},
                          },
                        ],
                      },
                    },
                  ],
                },
              ],
            });
          }
          if (path == '/albums/901' || path == '/v1/albums/901') {
            return replyJson(HttpStatus.ok, {
              'id': 901,
              'title': 'Tidal Masters Selection',
              'artist': {'name': 'Nordic Chamber'},
              'releaseDate': '2024-11-10',
              'audioQuality': 'HI_RES_LOSSLESS',
            });
          }
          if (path == '/albums/901/tracks' || path == '/v1/albums/901/tracks') {
            return replyJson(HttpStatus.ok, {
              'items': [
                {
                  'id': 9001,
                  'title': 'Tidal Daily Discovery 1',
                  'duration': 198,
                  'trackNumber': 1,
                  'volumeNumber': 1,
                  'audioQuality': 'HI_RES_LOSSLESS',
                  'artist': {'name': 'Nordic Chamber'},
                  'album': {'id': 901, 'title': 'Tidal Masters Selection'},
                },
              ],
            });
          }

          // 5. Deezer
          if (path == '/ajax/gw-light.php') {
            return replyJson(HttpStatus.ok, {
              'error': <String, dynamic>{},
              'results': {
                'checkForm': 'csrf_1',
                'USER': {
                  'USER_ID': 555,
                  'BLOG_NAME': 'Deezer HiFi User',
                  'OPTIONS': {
                    'license_token': 'lic_1',
                    'web_lossless': true,
                    'web_hq': true,
                  },
                },
              },
            });
          }
          if (path == '/user/555/recommendations/albums') {
            return replyJson(HttpStatus.ok, {
              'data': [
                {
                  'id': 801,
                  'title': 'Deezer Flow Album',
                  'artist': {'name': 'French Touch'},
                  'release_date': '2024-08-01',
                  'nb_tracks': 1,
                },
              ],
            });
          }
          if (path == '/user/555/recommendations/tracks') {
            return replyJson(HttpStatus.ok, {
              'data': [
                {
                  'id': 8001,
                  'title': 'Deezer Flow Track 1',
                  'duration': 215,
                  'artist': {'name': 'French Touch'},
                  'album': {'title': 'Deezer Flow Album'},
                },
              ],
            });
          }
          if (path == '/album/801') {
            return replyJson(HttpStatus.ok, {
              'id': 801,
              'title': 'Deezer Flow Album',
              'artist': {'name': 'French Touch'},
              'release_date': '2024-08-01',
              'tracks': {
                'data': [
                  {
                    'id': 8001,
                    'title': 'Deezer Flow Track 1',
                    'duration': 215,
                    'track_position': 1,
                    'disk_number': 1,
                    'artist': {'name': 'French Touch'},
                    'album': {'title': 'Deezer Flow Album'},
                  },
                ],
              },
            });
          }

          return replyJson(HttpStatus.notFound, {'error': 'Not found: $path'});
        });

        final baseUrl = 'http://127.0.0.1:${server.port}';
        final store = MemorySecureCredentialStore();

        final apple = AppleMusicProvider(
          credentialStore: store,
          apiBaseUrl: baseUrl,
        );
        final ytm = YouTubeMusicProvider(
          credentialStore: store,
          baseUrl: baseUrl,
          oauthBaseUrl: baseUrl,
        );
        final qobuz = QobuzProvider(
          credentialStore: store,
          baseUrl: baseUrl,
        );
        final tidal = TidalProvider(
          credentialStore: store,
          authBaseUrl: baseUrl,
          tokenBaseUrl: baseUrl,
          apiBaseUrl: baseUrl,
        );
        final deezer = DeezerProvider(
          credentialStore: store,
          gwUrl: '$baseUrl/ajax/gw-light.php',
          oauthBaseUrl: baseUrl,
          apiBaseUrl: baseUrl,
          mediaBaseUrl: '$baseUrl/media',
        );

        await apple.authenticate({
          'developer_token': 'dev_1',
          'music_user_token': 'mut_1',
        });
        await ytm.authenticate({
          'mode': 'cookie',
          'cookie': 'SAPISID=sap_1; SID=sid_1',
        });
        await qobuz.authenticate({
          'mode': 'token',
          'app_id': '950096963',
          'user_auth_token': 'qobuz_tok_1',
        });
        await tidal.authenticate({
          'mode': 'access_token',
          'access_token': 'tidal_tok_1',
        });
        await deezer.authenticate({
          'mode': 'arl',
          'arl': 'arl_tok_1',
        });

        final appleRec = await apple.fetchRecommendations();
        expect(appleRec.albums.single.title, 'Apple Spatial Picks');
        expect(appleRec.tracks.single.title, 'Apple Rec Song 1');
        final appleAlbum = await apple.fetchAlbumDetail('601');
        expect(appleAlbum?.title, 'Apple Spatial Picks');
        expect(appleAlbum?.versions.single.tracks.single.title, 'Apple Rec Song 1');

        final ytmRec = await ytm.fetchRecommendations();
        expect(ytmRec.albums.single.title, 'YTM Supermix Album');
        expect(ytmRec.tracks.single.title, 'YTM Quick Pick Track');
        final ytmAlbum = await ytm.fetchAlbumDetail('MPREb_yt_rec_1');
        expect(ytmAlbum?.title, 'YTM Supermix Album');
        expect(ytmAlbum?.versions.single.tracks.single.title, 'YTM Quick Pick Track');

        final qobuzRec = await qobuz.fetchRecommendations();
        expect(qobuzRec.albums.single.title, 'Qobuz Grand Cru Masters');
        expect(qobuzRec.tracks.single.title, 'Qobuz Rec Track 1');
        final qobuzAlbum = await qobuz.fetchAlbumDetail('701');
        expect(qobuzAlbum?.title, 'Qobuz Grand Cru Masters');
        expect(qobuzAlbum?.versions.single.tracks.single.title, 'Qobuz Rec Track 1');

        final tidalRec = await tidal.fetchRecommendations();
        expect(tidalRec.albums.single.title, 'Tidal Masters Selection');
        expect(tidalRec.tracks.single.title, 'Tidal Daily Discovery 1');
        final tidalAlbum = await tidal.fetchAlbumDetail('901');
        expect(tidalAlbum?.title, 'Tidal Masters Selection');
        expect(tidalAlbum?.versions.single.tracks.single.title, 'Tidal Daily Discovery 1');

        final deezerRec = await deezer.fetchRecommendations();
        expect(deezerRec.albums.single.title, 'Deezer Flow Album');
        expect(deezerRec.tracks.single.title, 'Deezer Flow Track 1');
        final deezerAlbum = await deezer.fetchAlbumDetail('801');
        expect(deezerAlbum?.title, 'Deezer Flow Album');
        expect(deezerAlbum?.versions.single.tracks.single.title, 'Deezer Flow Track 1');
      },
    );

    test(
      'StreamingManager 20-minute disk cache hydrates instantly within TTL, refreshes when expired or forced, and clears on logout',
      () async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        final tempDir = Directory.systemTemp.createTempSync('lumina_rec_cache_');
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        });

        var featuredCalls = 0;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        server.listen((req) async {
          final path = req.uri.path;
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType = ContentType.json;
          if (path == '/user/login' || path == '/user/get') {
            req.response.write(
              jsonEncode({
                'id': 91,
                'display_name': 'Qobuz Cache User',
                'user_auth_token': 'qobuz_tok_cache',
                'user': {'id': 91, 'display_name': 'Qobuz Cache User'},
              }),
            );
          } else if (path == '/album/getFeatured') {
            featuredCalls++;
            req.response.write(
              jsonEncode({
                'albums': {
                  'items': [
                    {
                      'id': '701',
                      'title': 'Qobuz Album Call #$featuredCalls',
                      'artist': {'name': 'Qobuz Artist'},
                    },
                  ],
                },
              }),
            );
          } else if (path == '/favorite/getUserFavorites') {
            req.response.write(
              jsonEncode({
                'tracks': {
                  'items': [
                    {
                      'id': 7001,
                      'title': 'Qobuz Track Call #$featuredCalls',
                      'duration': 180,
                      'performer': {'name': 'Qobuz Artist'},
                      'album': {'title': 'Qobuz Album'},
                    },
                  ],
                },
              }),
            );
          }
          await req.response.close();
        });

        final baseUrl = 'http://127.0.0.1:${server.port}';
        final store = MemorySecureCredentialStore();
        final cacheFile = File(
          '${tempDir.path}${Platform.pathSeparator}rec_cache.json',
        );
        var now = DateTime(2026, 11, 22, 12, 0, 0);

        StreamingManager buildManager() {
          return StreamingManager(
            credentialStore: store,
            recommendationsCacheFile: cacheFile,
            clock: () => now,
            providers: {
              'qobuz': QobuzProvider(
                credentialStore: store,
                baseUrl: baseUrl,
                clock: () => now,
              ),
            },
          );
        }

        final m1 = buildManager();
        await m1.initialize();
        await m1.authenticateProvider('qobuz', {
          'mode': 'token',
          'app_id': '950096963',
          'user_auth_token': 'qobuz_tok_cache',
        });
        // Wait for background recommendation fetch triggered on login.
        for (var i = 0; i < 40 && m1.isAnyRecommendationLoading; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(featuredCalls, 1);
        expect(
          m1.allRecommendedAlbums().single.title,
          'Qobuz Album Call #1',
        );
        expect(cacheFile.existsSync(), isTrue);
        m1.dispose();

        // Within 20 minutes (e.g. +10 min): hydrates immediately from disk cache without hitting /album/getFeatured.
        now = now.add(const Duration(minutes: 10));
        final m2 = buildManager();
        await m2.initialize();
        expect(
          m2.allRecommendedAlbums().single.title,
          'Qobuz Album Call #1',
        );
        expect(featuredCalls, 1);

        // Manual force refresh hits API and updates cache.
        await m2.refreshAllRecommendations(force: true);
        expect(featuredCalls, 2);
        expect(
          m2.allRecommendedAlbums().single.title,
          'Qobuz Album Call #2',
        );

        // Logout clears recommendations and removes provider from cache file.
        await m2.logoutProvider('qobuz');
        expect(m2.allRecommendedAlbums(), isEmpty);
        final rawCacheAfterLogout =
            jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
        expect(
          (rawCacheAfterLogout['providers'] as Map).containsKey('qobuz'),
          isFalse,
        );
        m2.dispose();
      },
    );

    testWidgets(
      'HomeDashboardView & HomeScreen render skeletons, filter capsules, badges, 401 error banner, open streaming AlbumDetailPage with Esc/< back, and play recommended tracks non-blockingly',
      (WidgetTester tester) async {
        EscapeDismissRegistry.instance.clear();
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1440, 960);
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          EscapeDismissRegistry.instance.clear();
        });

        var qobuzShouldReturn401 = false;
        final qobuzGate = Completer<void>();

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

            if (path == '/user/login' || path == '/user/get') {
              return replyJson(HttpStatus.ok, {
                'id': 91,
                'display_name': 'Qobuz UI User',
                'user_auth_token': 'qobuz_tok_ui',
                'user': {'id': 91, 'display_name': 'Qobuz UI User'},
              });
            }
            if (path == '/album/getFeatured') {
              if (!qobuzGate.isCompleted) {
                await qobuzGate.future;
              }
              if (qobuzShouldReturn401) {
                return replyJson(HttpStatus.unauthorized, {
                  'message': 'Qobuz token expired (401)',
                });
              }
              return replyJson(HttpStatus.ok, {
                'albums': {
                  'items': [
                    {
                      'id': '701',
                      'title': 'Qobuz UI Masterpiece',
                      'artist': {'name': 'Qobuz Symphony'},
                      'release_date_original': '2025-03-01',
                      'tracks_count': 2,
                      'maximum_sampling_rate': 96,
                      'maximum_bit_depth': 24,
                    },
                  ],
                },
              });
            }
            if (path == '/favorite/getUserFavorites') {
              if (qobuzShouldReturn401) {
                return replyJson(HttpStatus.unauthorized, {
                  'message': 'Qobuz token expired (401)',
                });
              }
              return replyJson(HttpStatus.ok, {
                'tracks': {
                  'items': [
                    {
                      'id': 7001,
                      'title': 'Qobuz Recommended Aria',
                      'duration': 200,
                      'maximum_sampling_rate': 96,
                      'maximum_bit_depth': 24,
                      'performer': {'name': 'Qobuz Symphony'},
                      'album': {'title': 'Qobuz UI Masterpiece'},
                    },
                  ],
                },
              });
            }
            if (path == '/album/get') {
              return replyJson(HttpStatus.ok, {
                'id': '701',
                'title': 'Qobuz UI Masterpiece',
                'artist': {'name': 'Qobuz Symphony'},
                'release_date_original': '2025-03-01',
                'maximum_sampling_rate': 96,
                'maximum_bit_depth': 24,
                'tracks': {
                  'items': [
                    {
                      'id': 7001,
                      'title': 'Qobuz Recommended Aria',
                      'duration': 200,
                      'track_number': 1,
                      'media_number': 1,
                      'maximum_sampling_rate': 96,
                      'maximum_bit_depth': 24,
                      'performer': {'name': 'Qobuz Symphony'},
                      'album': {'title': 'Qobuz UI Masterpiece'},
                    },
                    {
                      'id': 7002,
                      'title': 'Qobuz Finale Movement',
                      'duration': 240,
                      'track_number': 2,
                      'media_number': 1,
                      'maximum_sampling_rate': 96,
                      'maximum_bit_depth': 24,
                      'performer': {'name': 'Qobuz Symphony'},
                      'album': {'title': 'Qobuz UI Masterpiece'},
                    },
                  ],
                },
              });
            }
            if (path == '/track/getFileUrl') {
              return replyJson(HttpStatus.ok, {
                'track_id': 7001,
                'format_id': 7,
                'url': 'http://127.0.0.1:${srv.port}/stream/7001.flac',
                'sampling_rate': 96,
                'bit_depth': 24,
                'mime_type': 'audio/flac',
              });
            }
            if (path == '/sessions') {
              return replyJson(HttpStatus.ok, {
                'userId': 777,
                'countryCode': 'TW',
              });
            }
            if (path == '/users/777') {
              return replyJson(HttpStatus.ok, {
                'id': 777,
                'fullName': 'Tidal UI User',
              });
            }
            if (path == '/users/777/subscription') {
              return replyJson(HttpStatus.ok, {
                'subscription': {'type': 'HI_RES'},
              });
            }
            if (path == '/pages/home' || path == '/v1/pages/home') {
              return replyJson(HttpStatus.ok, {
                'rows': [
                  {
                    'modules': [
                      {
                        'type': 'ALBUM_LIST',
                        'pagedList': {
                          'items': [
                            {
                              'id': 901,
                              'title': 'Tidal UI Horizon',
                              'artist': {'name': 'Tidal Ensemble'},
                              'releaseDate': '2024-10-10',
                              'numberOfTracks': 1,
                              'audioQuality': 'HI_RES_LOSSLESS',
                            },
                          ],
                        },
                      },
                      {
                        'type': 'TRACK_LIST',
                        'pagedList': {
                          'items': [
                            {
                              'id': 9001,
                              'title': 'Tidal Recommended Pulse',
                              'duration': 185,
                              'trackNumber': 1,
                              'volumeNumber': 1,
                              'audioQuality': 'HI_RES_LOSSLESS',
                              'artist': {'name': 'Tidal Ensemble'},
                              'album': {'id': 901, 'title': 'Tidal UI Horizon'},
                            },
                          ],
                        },
                      },
                    ],
                  },
                ],
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
        final store = MemorySecureCredentialStore();
        final manager = StreamingManager(
          credentialStore: store,
          providers: {
            'qobuz': QobuzProvider(
              credentialStore: store,
              baseUrl: baseUrl,
            ),
            'tidal': TidalProvider(
              credentialStore: store,
              authBaseUrl: baseUrl,
              tokenBaseUrl: baseUrl,
              apiBaseUrl: baseUrl,
            ),
          },
        );
        addTearDown(manager.dispose);

        final audioService = MockAudioService();
        addTearDown(audioService.dispose);

        await tester.runAsync(() async {
          await manager.initialize();
          await manager.authenticateProvider('qobuz', {
            'mode': 'token',
            'app_id': '950096963',
            'app_secret': 'secret_qobuz_1',
            'user_auth_token': 'qobuz_tok_ui',
          });
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: audioService,
              streamingManager: manager,
            ),
          ),
        );
        await tester.pump();

        // While qobuzGate is uncompleted, skeleton placeholders are visible AND local library cards are NOT blocked.
        expect(find.byKey(const Key('stat_card_albums')), findsOneWidget);
        expect(find.byKey(const Key('home_recent_activity_card')), findsOneWidget);
        expect(find.byKey(const Key('rec_albums_skeleton')), findsOneWidget);
        expect(find.byKey(const Key('rec_tracks_skeleton')), findsOneWidget);

        // Release qobuzGate and connect Tidal as well.
        qobuzGate.complete();
        await tester.runAsync(() async {
          await manager.authenticateProvider('tidal', {
            'mode': 'access_token',
            'access_token': 'tidal_tok_ui',
          });
        });

        await _pumpUntil(
          tester,
          () =>
              find
                  .byKey(const Key('rec_album_card_qobuz_701'))
                  .evaluate()
                  .isNotEmpty &&
              find
                  .byKey(const Key('rec_album_card_tidal_901'))
                  .evaluate()
                  .isNotEmpty,
        );

        // Both platforms' recommendations and corner badges are rendered.
        expect(find.byKey(const Key('rec_album_badge_qobuz_701')), findsOneWidget);
        expect(find.byKey(const Key('rec_album_badge_tidal_901')), findsOneWidget);
        expect(find.byKey(const Key('rec_track_tile_qobuz:7001')), findsOneWidget);
        expect(find.byKey(const Key('rec_track_tile_tidal:9001')), findsOneWidget);

        // Multi-platform filter capsules filter between All, Qobuz, and Tidal.
        expect(find.byKey(const Key('rec_filter_all')), findsOneWidget);
        expect(find.byKey(const Key('rec_filter_qobuz')), findsOneWidget);
        expect(find.byKey(const Key('rec_filter_tidal')), findsOneWidget);

        await tester.ensureVisible(find.byKey(const Key('rec_filter_qobuz')));
        await tester.tap(find.byKey(const Key('rec_filter_qobuz')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('rec_album_card_qobuz_701')), findsOneWidget);
        expect(find.byKey(const Key('rec_album_card_tidal_901')), findsNothing);

        await tester.tap(find.byKey(const Key('rec_filter_all')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('rec_album_card_tidal_901')), findsOneWidget);

        // Simulate 401 token expiry on manual refresh -> displays rec_error_banner_qobuz without breaking local library.
        qobuzShouldReturn401 = true;
        await tester.ensureVisible(
          find.byKey(const Key('btn_refresh_streaming_recommendations')),
        );
        await tester.tap(
          find.byKey(const Key('btn_refresh_streaming_recommendations')),
        );
        await _pumpUntil(
          tester,
          () => find
              .byKey(const Key('rec_error_banner_qobuz'))
              .evaluate()
              .isNotEmpty,
        );
        expect(find.byKey(const Key('rec_error_banner_qobuz')), findsOneWidget);
        expect(find.byKey(const Key('stat_card_albums')), findsOneWidget);

        // Restore Qobuz 200 OK and tap retry on the banner.
        qobuzShouldReturn401 = false;
        await tester.tap(find.byKey(const Key('btn_retry_rec_qobuz')));
        await _pumpUntil(
          tester,
          () => find
              .byKey(const Key('rec_error_banner_qobuz'))
              .evaluate()
              .isEmpty,
        );

        // Clicking recommended track triggers Stage 3 non-blocking streaming playback.
        await tester.ensureVisible(
          find.byKey(const Key('rec_track_tile_qobuz:7001')),
        );
        await tester.tap(find.byKey(const Key('rec_track_tile_qobuz:7001')));
        await _pumpUntil(
          tester,
          () => audioService.currentState.track?.id == 'qobuz:7001',
        );
        expect(audioService.currentState.track?.title, 'Qobuz Recommended Aria');

        // Clicking recommended album opens AlbumDetailPage with full tracklist.
        await tester.ensureVisible(
          find.byKey(const Key('rec_album_card_qobuz_701')),
        );
        await tester.tap(find.byKey(const Key('rec_album_card_qobuz_701')));
        await _pumpUntil(
          tester,
          () =>
              find.byType(AlbumDetailPage).evaluate().isNotEmpty &&
              find.text('Qobuz Finale Movement').evaluate().isNotEmpty,
        );
        expect(find.byType(AlbumDetailPage), findsOneWidget);
        expect(find.text('Qobuz Finale Movement'), findsOneWidget);

        // Pressing Esc (Stage 1 Level 5) returns cleanly to HomeDashboardView.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(HomeDashboardView), findsOneWidget);

        // Open album again and use top-left '<' back button to return to HomeDashboardView.
        await tester.ensureVisible(
          find.byKey(const Key('rec_album_card_qobuz_701')),
        );
        await tester.tap(find.byKey(const Key('rec_album_card_qobuz_701')));
        await _pumpUntil(
          tester,
          () => find.byType(AlbumDetailPage).evaluate().isNotEmpty,
        );
        await tester.tap(find.byKey(const Key('btn_nav_back')));
        await tester.pumpAndSettle();
        expect(find.byType(HomeDashboardView), findsOneWidget);

        await tester.runAsync(() async {
          manager.dispose();
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await server.close(force: true);
        });
      },
    );
  });
}
