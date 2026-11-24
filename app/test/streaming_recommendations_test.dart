import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/services/desktop_window_controller.dart';
import 'package:lumina_app/services/escape_dismiss_registry.dart';
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
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:lumina_app/ui/home/home_dashboard_view.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:lumina_app/ui/streaming/streaming_service_view.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxSteps = 250,
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
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Stage 6: Streaming Recommendations & Genuine Refresh Rotation', () {
    test(
      'All 5 providers fetch real personalized recommendations, rotate batches with pagination/continuation/no-cache headers on forceRefresh, and fetch full CanonicalAlbumDetail',
      () async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
        });

        final seenNoCacheHeaders = <String>[];
        final seenQobuzTypes = <String>[];

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        server.listen((req) async {
          final path = req.uri.path;
          final cacheControl = req.headers.value('cache-control') ?? '';
          if (cacheControl.contains('no-cache')) {
            seenNoCacheHeaders.add(path);
          }

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
            final offset = req.uri.queryParameters['offset'] ?? '0';
            if (offset == '10') {
              return replyJson(HttpStatus.ok, {
                'data': [
                  {
                    'id': 'rec_group_2',
                    'type': 'personal-recommendation',
                    'relationships': {
                      'contents': {
                        'data': [
                          {
                            'id': '602',
                            'type': 'albums',
                            'attributes': {
                              'name': 'Apple Spatial Wave 2',
                              'artistName': 'Apple Chamber',
                              'releaseDate': '2025-03-01',
                              'trackCount': 3,
                            },
                          },
                        ],
                      },
                    },
                  },
                ],
              });
            }
            return replyJson(HttpStatus.ok, {
              'next': '/v1/me/recommendations?offset=10',
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
            final offset = req.uri.queryParameters['offset'] ?? '0';
            return replyJson(HttpStatus.ok, {
              'data': [
                if (offset == '10')
                  {
                    'id': '6002',
                    'type': 'songs',
                    'attributes': {
                      'name': 'Apple Rec Song 2',
                      'artistName': 'Apple Chamber',
                      'albumName': 'Apple Spatial Wave 2',
                      'durationInMillis': 225000,
                    },
                  }
                else
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
          if (path == '/v1/me/library/recently-added' ||
              path == '/v1/catalog/tw/charts') {
            return replyJson(HttpStatus.ok, {'data': <Object>[]});
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
            final continuation = bodyJson['continuation']?.toString() ?? '';
            if (browseId == 'FEmusic_explore') {
              return replyJson(HttpStatus.ok, {
                'contents': {
                  'albumItem': {
                    'musicTwoRowItemRenderer': {
                      'title': {'simpleText': 'YTM Explore Album 2'},
                      'subtitle': {'simpleText': 'YTM Explore Artist • 2025'},
                      'navigationEndpoint': {
                        'browseEndpoint': {
                          'browseId': 'MPREb_yt_rec_2',
                          'browseEndpointContextSupportedConfigs': {
                            'browseEndpointContextMusicConfig': {
                              'pageType': 'MUSIC_PAGE_TYPE_ALBUM',
                            },
                          },
                        },
                      },
                    },
                  },
                },
              });
            }
            if (browseId == 'FEmusic_home' && continuation == 'ctoken_home_2') {
              return replyJson(HttpStatus.ok, {
                'contents': {
                  'albumItem': {
                    'musicTwoRowItemRenderer': {
                      'title': {'simpleText': 'YTM Continued Album 3'},
                      'subtitle': {'simpleText': 'YTM Cont Artist • 2025'},
                      'navigationEndpoint': {
                        'browseEndpoint': {
                          'browseId': 'MPREb_yt_rec_3',
                          'browseEndpointContextSupportedConfigs': {
                            'browseEndpointContextMusicConfig': {
                              'pageType': 'MUSIC_PAGE_TYPE_ALBUM',
                            },
                          },
                        },
                      },
                    },
                  },
                },
              });
            }
            if (browseId == 'FEmusic_home') {
              return replyJson(HttpStatus.ok, {
                'continuations': [
                  {
                    'nextContinuationData': {'continuation': 'ctoken_home_2'},
                  },
                ],
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
          if (path == '/youtubei/v1/next') {
            return replyJson(HttpStatus.ok, {
              'contents': {
                'panelTrack': {
                  'playlistPanelVideoRenderer': {
                    'videoId': 'yt_vid_100',
                    'title': {'simpleText': 'YTM Radio Track 2'},
                    'longBylineText': {'simpleText': 'YTM Radio Artist'},
                    'lengthText': {'simpleText': '4:12'},
                  },
                },
              },
            });
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
            final featType =
                req.uri.queryParameters['type'] ?? 'new-releases-full';
            seenQobuzTypes.add(featType);
            final isBatch2 = featType == 'ideal-discography';
            return replyJson(HttpStatus.ok, {
              'albums': {
                'items': [
                  {
                    'id': isBatch2 ? '702' : '701',
                    'title': isBatch2
                        ? 'Qobuz Ideal Discography 2'
                        : 'Qobuz Grand Cru Masters',
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
            final offset = req.uri.queryParameters['offset'] ?? '0';
            final isSecond = offset != '0';
            return replyJson(HttpStatus.ok, {
              'tracks': {
                'items': [
                  {
                    'id': isSecond ? 7002 : 7001,
                    'title': isSecond
                        ? 'Qobuz Rec Track 2'
                        : 'Qobuz Rec Track 1',
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
          if (path == '/pages/explore_new_music' ||
              path == '/v1/pages/explore_new_music') {
            return replyJson(HttpStatus.ok, {
              'rows': [
                {
                  'modules': [
                    {
                      'type': 'ALBUM_LIST',
                      'pagedList': {
                        'items': [
                          {
                            'id': 902,
                            'title': 'Tidal New Music 2',
                            'artist': {'name': 'Nordic Chamber'},
                            'releaseDate': '2025-02-01',
                            'numberOfTracks': 3,
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
                            'id': 9002,
                            'title': 'Tidal Explore Discovery 2',
                            'duration': 202,
                            'trackNumber': 1,
                            'volumeNumber': 1,
                            'audioQuality': 'HI_RES_LOSSLESS',
                            'artist': {'name': 'Nordic Chamber'},
                            'album': {'id': 902, 'title': 'Tidal New Music 2'},
                          },
                        ],
                      },
                    },
                  ],
                },
              ],
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
            final idx = req.uri.queryParameters['index'] ?? '0';
            final isSecond = idx == '10';
            return replyJson(HttpStatus.ok, {
              'data': [
                {
                  'id': isSecond ? 802 : 801,
                  'title': isSecond
                      ? 'Deezer Flow Album 2'
                      : 'Deezer Flow Album',
                  'artist': {'name': 'French Touch'},
                  'release_date': '2024-08-01',
                  'nb_tracks': 1,
                },
              ],
            });
          }
          if (path == '/user/555/recommendations/tracks') {
            final idx = req.uri.queryParameters['index'] ?? '0';
            final isSecond = idx == '10';
            return replyJson(HttpStatus.ok, {
              'data': [
                {
                  'id': isSecond ? 8002 : 8001,
                  'title': isSecond
                      ? 'Deezer Flow Track 2'
                      : 'Deezer Flow Track 1',
                  'duration': 215,
                  'artist': {'name': 'French Touch'},
                  'album': {'title': 'Deezer Flow Album'},
                },
              ],
            });
          }
          if (path == '/chart/0/albums' ||
              path == '/user/555/flow' ||
              path == '/track/8002/radio') {
            return replyJson(HttpStatus.ok, {'data': <Object>[]});
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

        // Batch 0 across all 5 providers
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

        final qobuzRec = await qobuz.fetchRecommendations();
        expect(qobuzRec.albums.single.title, 'Qobuz Grand Cru Masters');
        expect(qobuzRec.tracks.single.title, 'Qobuz Rec Track 1');
        final qobuzAlbum = await qobuz.fetchAlbumDetail('701');
        expect(qobuzAlbum?.title, 'Qobuz Grand Cru Masters');

        final tidalRec = await tidal.fetchRecommendations();
        expect(tidalRec.albums.single.title, 'Tidal Masters Selection');
        expect(tidalRec.tracks.single.title, 'Tidal Daily Discovery 1');
        final tidalAlbum = await tidal.fetchAlbumDetail('901');
        expect(tidalAlbum?.title, 'Tidal Masters Selection');

        final deezerRec = await deezer.fetchRecommendations();
        expect(deezerRec.albums.single.title, 'Deezer Flow Album');
        expect(deezerRec.tracks.single.title, 'Deezer Flow Track 1');
        final deezerAlbum = await deezer.fetchAlbumDetail('801');
        expect(deezerAlbum?.title, 'Deezer Flow Album');

        // Batch 1 (forceRefresh: true) rotates pagination / continuation / endpoints / no-cache headers across ALL 5 providers!
        final appleRec2 = await apple.fetchRecommendations(
          forceRefresh: true,
          batchIndex: 1,
          excludeAlbumIds: const {'601'},
          excludeTrackIds: const {'apple:6001'},
        );
        expect(appleRec2.albums.first.id, '602');
        expect(appleRec2.tracks.first.id, 'apple:6002');

        final ytmRec2 = await ytm.fetchRecommendations(
          forceRefresh: true,
          batchIndex: 1,
          excludeAlbumIds: const {'MPREb_yt_rec_1'},
          excludeTrackIds: const {'ytm:yt_vid_99'},
        );
        expect(
          ytmRec2.albums.map((a) => a.id),
          containsAll(['MPREb_yt_rec_2', 'MPREb_yt_rec_3']),
        );
        expect(ytmRec2.albums.first.id, isNot('MPREb_yt_rec_1'));
        expect(ytmRec2.tracks.first.id, 'ytm:yt_vid_100');

        final qobuzRec2 = await qobuz.fetchRecommendations(
          forceRefresh: true,
          batchIndex: 1,
          excludeAlbumIds: const {'701'},
          excludeTrackIds: const {'qobuz:7001'},
        );
        expect(seenQobuzTypes, containsAll(['new-releases-full', 'ideal-discography']));
        expect(qobuzRec2.albums.first.id, '702');
        expect(qobuzRec2.tracks.first.id, 'qobuz:7002');

        final tidalRec2 = await tidal.fetchRecommendations(
          forceRefresh: true,
          batchIndex: 1,
          excludeAlbumIds: const {'901'},
          excludeTrackIds: const {'tidal:9001'},
        );
        expect(tidalRec2.albums.first.id, '902');
        expect(tidalRec2.tracks.first.id, 'tidal:9002');

        final deezerRec2 = await deezer.fetchRecommendations(
          forceRefresh: true,
          batchIndex: 1,
          excludeAlbumIds: const {'801'},
          excludeTrackIds: const {'deezer:8001'},
        );
        expect(deezerRec2.albums.first.id, '802');
        expect(deezerRec2.tracks.first.id, 'deezer:8002');

        expect(seenNoCacheHeaders, isNotEmpty);
      },
    );

    test(
      'StreamingManager hydrates within 20-min TTL, purges memory & disk cache BEFORE refetch on force: true, and rotates batches on consecutive refreshes',
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
        Completer<void>? forceGate;
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
            final gate = forceGate;
            if (gate != null && !gate.isCompleted) {
              await gate.future;
            }
            req.response.write(
              jsonEncode({
                'albums': {
                  'items': [
                    {
                      'id': 'alb_$featuredCalls',
                      'title': 'Qobuz Album Call #$featuredCalls',
                      'artist': {'name': 'Qobuz Artist'},
                      'image': {
                        'large':
                            'https://static.qobuz.com/images/covers/test/alb_${featuredCalls}_600.jpg',
                      },
                      'maximum_sampling_rate': 96,
                      'maximum_bit_depth': 24,
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
                      'id': 7000 + featuredCalls,
                      'title': 'Qobuz Track Call #$featuredCalls',
                      'duration': 180,
                      'performer': {'name': 'Qobuz Artist'},
                      'album': {
                        'title': 'Qobuz Album',
                        'image': {
                          'large':
                              'https://static.qobuz.com/images/covers/test/trk_${featuredCalls}_600.jpg',
                        },
                      },
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
              'youtube_music': YouTubeMusicProvider(
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
        for (var i = 0; i < 40 && m1.isAnyRecommendationLoading; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(featuredCalls, 1);
        final rec1 = m1.recommendationsFor('qobuz')!;
        expect(rec1.albums.single.title, 'Qobuz Album Call #1');
        expect(cacheFile.existsSync(), isTrue);
        m1.dispose();

        // Within 20 minutes: hydrates immediately from disk cache without hitting /album/getFeatured.
        now = now.add(const Duration(minutes: 10));
        final m2 = buildManager();
        await m2.initialize();
        expect(
          m2.allRecommendedAlbums().single.title,
          'Qobuz Album Call #1',
        );
        expect(featuredCalls, 1);

        // Manual force refresh purges memory AND disk cache BEFORE the HTTP response returns!
        forceGate = Completer<void>();
        final refreshFuture = m2.refreshRecommendationsFor('qobuz', force: true);
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(m2.recommendationsFor('qobuz'), isNull);
        final purgedCache =
            jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
        expect(
          (purgedCache['providers'] as Map).containsKey('qobuz'),
          isFalse,
        );

        forceGate.complete();
        final rec2 = await refreshFuture;
        expect(featuredCalls, 2);
        expect(rec2.albums.single.title, 'Qobuz Album Call #2');
        expect(identical(rec1.albums, rec2.albums), isFalse);

        // Second consecutive refresh produces batch #3.
        forceGate = null;
        now = now.add(const Duration(seconds: 1));
        final rec3 = await m2.refreshRecommendationsFor('qobuz', force: true);
        expect(featuredCalls, 3);
        expect(rec3.albums.single.title, 'Qobuz Album Call #3');

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
      'HomeDashboardView stays isolated from streaming recommendations; StreamingServiceView renders skeletons, 24-bit Hi-Res badges, 2+ consecutive 換一批 rotations, error Toast + retry, non-blocking playback, and AlbumDetailPage Esc/< navigation',
      (WidgetTester tester) async {
        EscapeDismissRegistry.instance.clear();
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1440, 960);
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;

        final tempDir = Directory.systemTemp.createTempSync('stage6_ui_');
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
          HttpOverrides.global = prevOverrides;
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          EscapeDismissRegistry.instance.clear();
          if (tempDir.existsSync()) {
            try {
              tempDir.deleteSync(recursive: true);
            } catch (_) {}
          }
        });

        var qobuzShouldReturn401 = false;
        var qobuzBatch = 0;
        Completer<void>? qobuzGate;

        final pngBytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
        );

        final server = (await tester.runAsync(() async {
          final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          srv.listen((req) async {
            final path = req.uri.path;
            if (path.startsWith('/covers/')) {
              req.response.persistentConnection = false;
              req.response.statusCode = HttpStatus.ok;
              req.response.headers.contentType = ContentType('image', 'png');
              req.response.add(pngBytes);
              await req.response.close();
              return;
            }
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
                'credential': {'label': 'Studio'},
                'user_auth_token': 'qobuz_tok_ui',
                'user': {
                  'id': 91,
                  'display_name': 'Qobuz UI User',
                  'credential': {'label': 'Studio'},
                },
              });
            }
            if (path == '/album/getFeatured') {
              final gate = qobuzGate;
              if (gate != null && !gate.isCompleted) {
                await gate.future;
              }
              if (qobuzShouldReturn401) {
                return replyJson(HttpStatus.unauthorized, {
                  'message': 'Qobuz token expired (401)',
                });
              }
              qobuzBatch++;
              return replyJson(HttpStatus.ok, {
                'albums': {
                  'items': [
                    {
                      'id': '70$qobuzBatch',
                      'title': 'Qobuz Masterpiece Batch $qobuzBatch',
                      'artist': {'name': 'Qobuz Symphony'},
                      'release_date_original': '2025-03-01',
                      'tracks_count': 2,
                      'maximum_sampling_rate': 96,
                      'maximum_bit_depth': 24,
                      'image': {
                        'large':
                            'http://127.0.0.1:${srv.port}/covers/qobuz_alb_$qobuzBatch.png',
                      },
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
                      'id': 7000 + qobuzBatch,
                      'title': 'Qobuz Aria Batch $qobuzBatch',
                      'duration': 200,
                      'maximum_sampling_rate': 96,
                      'maximum_bit_depth': 24,
                      'performer': {'name': 'Qobuz Symphony'},
                      'album': {
                        'title': 'Qobuz Masterpiece Batch $qobuzBatch',
                        'image': {
                          'large':
                              'http://127.0.0.1:${srv.port}/covers/qobuz_trk_$qobuzBatch.png',
                        },
                      },
                    },
                  ],
                },
              });
            }
            if (path == '/album/get') {
              return replyJson(HttpStatus.ok, {
                'id': '703',
                'title': 'Qobuz Masterpiece Batch 3',
                'artist': {'name': 'Qobuz Symphony'},
                'release_date_original': '2025-03-01',
                'maximum_sampling_rate': 96,
                'maximum_bit_depth': 24,
                'image': {
                  'large': 'http://127.0.0.1:${srv.port}/covers/qobuz_703.png',
                },
                'tracks': {
                  'items': [
                    {
                      'id': 7003,
                      'title': 'Qobuz Aria Batch 3',
                      'duration': 200,
                      'track_number': 1,
                      'media_number': 1,
                      'maximum_sampling_rate': 96,
                      'maximum_bit_depth': 24,
                      'performer': {'name': 'Qobuz Symphony'},
                      'album': {'title': 'Qobuz Masterpiece Batch 3'},
                    },
                    {
                      'id': 7099,
                      'title': 'Qobuz Finale Movement',
                      'duration': 240,
                      'track_number': 2,
                      'media_number': 1,
                      'maximum_sampling_rate': 96,
                      'maximum_bit_depth': 24,
                      'performer': {'name': 'Qobuz Symphony'},
                      'album': {'title': 'Qobuz Masterpiece Batch 3'},
                    },
                  ],
                },
              });
            }
            if (path == '/track/getFileUrl') {
              return replyJson(HttpStatus.ok, {
                'track_id': 7003,
                'format_id': 7,
                'url': 'http://127.0.0.1:${srv.port}/stream/7003.flac',
                'sampling_rate': 96,
                'bit_depth': 24,
                'mime_type': 'audio/flac',
              });
            }
            return replyJson(HttpStatus.notFound, {'error': 'Not found: $path'});
          });
          return srv;
        }))!;
        addTearDown(() => server.close(force: true));

        final baseUrl = 'http://127.0.0.1:${server.port}';
        final store = MemorySecureCredentialStore();
        final cacheFile = File(
          '${tempDir.path}${Platform.pathSeparator}ui_rec_cache.json',
        );
        final manager = StreamingManager(
          credentialStore: store,
          recommendationsCacheFile: cacheFile,
          providers: {
            'qobuz': QobuzProvider(
              credentialStore: store,
              baseUrl: baseUrl,
            ),
            'youtube_music': YouTubeMusicProvider(
              credentialStore: store,
              baseUrl: baseUrl,
            ),
          },
        );
        addTearDown(manager.dispose);

        final audioService = MockAudioService();
        addTearDown(audioService.dispose);
        final scaleCtrl = UiScaleController(
          prefsFileOverride: File(
            '${tempDir.path}${Platform.pathSeparator}ui_prefs.json',
          ),
        );
        addTearDown(scaleCtrl.dispose);
        final persistSvc = PlaybackPersistenceService(
          prefsFileOverride: File(
            '${tempDir.path}${Platform.pathSeparator}playback.json',
          ),
        );
        addTearDown(persistSvc.dispose);

        await tester.runAsync(() async {
          await manager.initialize();
          await manager.authenticateProvider('qobuz', {
            'mode': 'token',
            'app_id': '950096963',
            'app_secret': 'secret_qobuz_1',
            'user_auth_token': 'qobuz_tok_ui',
          });
          while (manager.isAnyRecommendationLoading) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: audioService,
              uiScaleController: scaleCtrl,
              streamingManager: manager,
              playbackPersistenceService: persistSvc,
            ),
          ),
        );
        await _pumpUntil(
          tester,
          () => find.byKey(const Key('nav_streaming_qobuz')).evaluate().isNotEmpty,
        );

        // 1. Isolation check: HomeDashboardView must NEVER render streaming recommendations!
        expect(find.byType(HomeDashboardView), findsOneWidget);
        expect(
          find.byKey(const Key('home_streaming_recommendations_panel')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('home_recommended_albums_section')),
          findsNothing,
        );

        // 2. Navigate to dedicated StreamingServiceView for Qobuz.
        await tester.ensureVisible(find.byKey(const Key('nav_streaming_qobuz')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('nav_streaming_qobuz')));
        await _pumpUntil(
          tester,
          () => find
              .byKey(const Key('streaming_service_view_qobuz'))
              .evaluate()
              .isNotEmpty,
        );

        // Switch to 探索推薦 tab (batch 1 loaded).
        await tester.tap(find.byKey(const Key('streaming_tab_explore')));
        await _pumpUntil(
          tester,
          () => find
              .byKey(const Key('streaming_rec_album_701'))
              .evaluate()
              .isNotEmpty,
        );
        expect(find.text('為你推薦的專輯'), findsOneWidget);
        expect(find.text('推薦歌曲'), findsOneWidget);
        expect(find.text('24-bit Hi-Res'), findsWidgets);
        expect(find.byKey(const Key('streaming_track_qobuz:7001')), findsOneWidget);

        // 3. Consecutive 換一批 #1 -> gate pauses to verify skeleton placeholders first!
        qobuzGate = Completer<void>();
        await tester.tap(
          find.byKey(const Key('btn_streaming_refresh_recommendations')),
        );
        await tester.pump();
        expect(find.byKey(const Key('rec_albums_skeleton')), findsOneWidget);
        expect(find.byKey(const Key('rec_tracks_skeleton')), findsOneWidget);

        qobuzGate.complete();
        await _pumpUntil(
          tester,
          () =>
              !manager.isAnyRecommendationLoading &&
              find.byKey(const Key('streaming_rec_album_702')).evaluate().isNotEmpty,
        );
        expect(find.byKey(const Key('streaming_rec_album_701')), findsNothing);
        expect(find.byKey(const Key('streaming_rec_album_702')), findsOneWidget);
        expect(find.byKey(const Key('streaming_track_qobuz:7002')), findsOneWidget);

        // 4. Consecutive 換一批 #2 -> visibly updates again to batch 3!
        qobuzGate = null;
        await tester.tap(
          find.byKey(const Key('btn_streaming_refresh_recommendations')),
        );
        await _pumpUntil(
          tester,
          () =>
              !manager.isAnyRecommendationLoading &&
              find.byKey(const Key('streaming_rec_album_703')).evaluate().isNotEmpty,
        );
        expect(find.byKey(const Key('streaming_rec_album_702')), findsNothing);
        expect(find.byKey(const Key('streaming_rec_album_703')), findsOneWidget);
        expect(find.byKey(const Key('streaming_track_qobuz:7003')), findsOneWidget);

        // 5. Simulate 401 failure on manual 換一批 -> error Toast + inline retry banner!
        qobuzShouldReturn401 = true;
        await tester.tap(
          find.byKey(const Key('btn_streaming_refresh_recommendations')),
        );
        await _pumpUntil(
          tester,
          () =>
              !manager.isAnyRecommendationLoading &&
              find.byKey(const Key('rec_error_banner_qobuz')).evaluate().isNotEmpty,
        );
        expect(find.byKey(const Key('rec_error_banner_qobuz')), findsOneWidget);
        expect(
          find.byKey(const Key('streaming_rec_toast_error_qobuz')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('btn_retry_rec_qobuz')), findsOneWidget);
        expect(
          find.byKey(const Key('btn_rec_open_settings_qobuz')),
          findsOneWidget,
        );

        // Restore 200 OK and tap retry on banner.
        qobuzShouldReturn401 = false;
        await tester.tap(find.byKey(const Key('btn_retry_rec_qobuz')));
        await _pumpUntil(
          tester,
          () =>
              !manager.isAnyRecommendationLoading &&
              find.byKey(const Key('rec_error_banner_qobuz')).evaluate().isEmpty &&
              find.byKey(const Key('streaming_rec_album_704')).evaluate().isNotEmpty,
        );

        // 6. Tap recommended track -> non-blocking playback starts.
        await tester.ensureVisible(
          find.byKey(const Key('streaming_track_qobuz:7004')),
        );
        await tester.tap(find.byKey(const Key('streaming_track_qobuz:7004')));
        await _pumpUntil(
          tester,
          () => audioService.currentState.track?.id == 'qobuz:7004',
        );
        expect(audioService.currentState.track?.title, 'Qobuz Aria Batch 4');

        // 7. Tap recommended album -> opens AlbumDetailPage, Esc & '<' return cleanly to StreamingServiceView.
        await tester.ensureVisible(
          find.byKey(const Key('streaming_rec_album_704')),
        );
        await tester.tap(find.byKey(const Key('streaming_rec_album_704')));
        await _pumpUntil(
          tester,
          () =>
              find.byType(AlbumDetailPage).evaluate().isNotEmpty &&
              find.text('Qobuz Finale Movement').evaluate().isNotEmpty,
        );
        expect(find.byType(AlbumDetailPage), findsOneWidget);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
        await _pumpUntil(
          tester,
          () => find.byType(StreamingServiceView).evaluate().isNotEmpty,
        );
        expect(find.byType(StreamingServiceView), findsOneWidget);

        // Open album from top strip on default tab and return via top-left '<' button.
        await tester.ensureVisible(
          find.byKey(const Key('streaming_rec_strip_album_704')),
        );
        await tester.tap(
          find.byKey(const Key('streaming_rec_strip_album_704')),
        );
        await _pumpUntil(
          tester,
          () => find.byType(AlbumDetailPage).evaluate().isNotEmpty,
        );
        await tester.tap(find.byKey(const Key('btn_nav_back')));
        await _pumpUntil(
          tester,
          () => find.byType(StreamingServiceView).evaluate().isNotEmpty,
        );
        expect(find.byType(StreamingServiceView), findsOneWidget);
      },
    );
  });

  group('Stage 2: Cover Art Extraction, Normalization & Cache Self-Healing', () {
    test('BaseStreamingProvider.normalizeCoverUrl normalizes // and rejects invalid URLs', () {
      expect(BaseStreamingProvider.normalizeCoverUrl(null), isNull);
      expect(BaseStreamingProvider.normalizeCoverUrl('   '), isNull);
      expect(
        BaseStreamingProvider.normalizeCoverUrl(
          '  //lh3.googleusercontent.com/abc=w544-h544  ',
        ),
        'https://lh3.googleusercontent.com/abc=w544-h544',
      );
      expect(
        BaseStreamingProvider.normalizeCoverUrl(
          'https://static.qobuz.com/images/covers/a/b/c_600.jpg',
        ),
        'https://static.qobuz.com/images/covers/a/b/c_600.jpg',
      );
      expect(
        BaseStreamingProvider.normalizeCoverUrl('http://127.0.0.1:8080/a.png'),
        'http://127.0.0.1:8080/a.png',
      );
      expect(BaseStreamingProvider.normalizeCoverUrl('/api/v1/artwork/1'), isNull);
      expect(BaseStreamingProvider.normalizeCoverUrl('ftp://host/a.jpg'), isNull);
      expect(BaseStreamingProvider.normalizeCoverUrl('javascript:alert(1)'), isNull);
      expect(BaseStreamingProvider.normalizeCoverUrl('https://'), isNull);
      expect(
        BaseStreamingProvider.defaultImageHttpHeaders['User-Agent'],
        contains('Mozilla/5.0'),
      );
    });

    test(
      'All 5 providers extract, normalize, and inherit parent album cover URLs on recommended tracks and album detail tracks',
      () async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
        });

        var qobuzAlbumGetCalls = 0;
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

          // 1. Qobuz (batchIndex == 0 with empty favorite tracks -> must still fetch /album/get and inherit parent cover!)
          if (path == '/user/login' || path == '/user/get') {
            return replyJson(HttpStatus.ok, {
              'id': 91,
              'display_name': 'Qobuz Cover User',
              'user_auth_token': 'qobuz_tok_cov',
              'user': {'id': 91, 'display_name': 'Qobuz Cover User'},
            });
          }
          if (path == '/album/getFeatured') {
            return replyJson(HttpStatus.ok, {
              'albums': {
                'items': [
                  {
                    'id': 'qb_alb_1',
                    'title': 'Qobuz Featured Album',
                    'artist': {'name': 'Qobuz Artist'},
                    'image': {
                      'small': '//static.qobuz.com/images/covers/qb/alb1_230.jpg',
                    },
                    'maximum_sampling_rate': 96,
                    'maximum_bit_depth': 24,
                  },
                  {
                    'id': 'qb_alb_2',
                    'title': 'Qobuz Thumb Album',
                    'artist': {'name': 'Qobuz Artist 2'},
                    'image': {
                      'thumbnail':
                          'https://static.qobuz.com/images/covers/qb/alb2_thumb.jpg',
                    },
                  },
                ],
              },
            });
          }
          if (path == '/favorite/getUserFavorites') {
            return replyJson(HttpStatus.ok, {
              'tracks': {'items': <Object>[]},
              'albums': {'items': <Object>[]},
            });
          }
          if (path == '/album/get') {
            qobuzAlbumGetCalls++;
            return replyJson(HttpStatus.ok, {
              'id': 'qb_alb_1',
              'title': 'Qobuz Featured Album',
              'artist': {'name': 'Qobuz Artist'},
              'image': {
                'large': '//static.qobuz.com/images/covers/qb/alb1_600.jpg',
              },
              'maximum_sampling_rate': 96,
              'maximum_bit_depth': 24,
              'tracks': {
                'items': [
                  {
                    'id': 9101,
                    'title': 'Qobuz Track Without Nested Album Image',
                    'duration': 210,
                    'track_number': 1,
                    'media_number': 1,
                    // Real Qobuz /album/get track items omit album['image']!
                  },
                  {
                    'id': 9102,
                    'title': 'Qobuz Track With Thumbnail Only',
                    'duration': 185,
                    'image': {
                      'thumbnail':
                          'https://static.qobuz.com/images/covers/qb/trk_thumb.jpg',
                    },
                  },
                ],
              },
            });
          }

          // 2. YouTube Music (// URL, out-of-order width*height resolution picking, header/json fallback inheritance)
          if (path == '/youtubei/v1/account/account_menu') {
            return replyJson(HttpStatus.ok, {
              'actions': [
                {
                  'openPopupAction': {
                    'popup': {
                      'multiPageMenuRenderer': {
                        'header': {
                          'activeAccountHeaderRenderer': {
                            'accountName': {'simpleText': 'YTM Cover User'},
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
                'header': {
                  'thumbnail': {
                    'musicThumbnailRenderer': {
                      'thumbnail': {
                        'thumbnails': [
                          {
                            'url': '//lh3.googleusercontent.com/ytm_header_600',
                            'width': 600,
                            'height': 600,
                          },
                        ],
                      },
                    },
                  },
                },
                'contents': {
                  'track1': {
                    'musicResponsiveListItemRenderer': {
                      'playlistItemData': {'videoId': 'yt_cov_1'},
                      'thumbnail': {
                        'musicThumbnailRenderer': {
                          'thumbnail': {
                            'thumbnails': [
                              // Out-of-order: largest resolution is FIRST, not last!
                              {
                                'url': '//lh3.googleusercontent.com/ytm_best_544',
                                'width': 544,
                                'height': 544,
                              },
                              {
                                'url': '//lh3.googleusercontent.com/ytm_small_120',
                                'width': 120,
                                'height': 120,
                              },
                            ],
                          },
                        },
                      },
                      'flexColumns': [
                        {
                          'musicResponsiveListItemFlexColumnRenderer': {
                            'text': {'simpleText': 'YTM High-Res Thumb Track'},
                          },
                        },
                        {
                          'musicResponsiveListItemFlexColumnRenderer': {
                            'text': {
                              'runs': [
                                {'text': 'YTM Artist'},
                                {'text': ' • '},
                                {'text': '3:20'},
                              ],
                            },
                          },
                        },
                      ],
                    },
                  },
                  'track2': {
                    'musicResponsiveListItemRenderer': {
                      'playlistItemData': {'videoId': 'yt_cov_2'},
                      // Missing row thumbnail -> inherits header['thumbnail']!
                      'flexColumns': [
                        {
                          'musicResponsiveListItemFlexColumnRenderer': {
                            'text': {'simpleText': 'YTM Inherited Cover Track'},
                          },
                        },
                        {
                          'musicResponsiveListItemFlexColumnRenderer': {
                            'text': {
                              'runs': [
                                {'text': 'YTM Artist'},
                                {'text': ' • '},
                                {'text': '2:50'},
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
            if (browseId == 'MPREb_cov_1') {
              return replyJson(HttpStatus.ok, {
                'header': {
                  'musicResponsiveHeaderRenderer': {
                    'title': {'simpleText': 'YTM Fallback Thumb Album'},
                    'straplineTextOne': {'simpleText': 'YTM Artist'},
                    'thumbnail': {
                      'musicThumbnailRenderer': {
                        'thumbnail': {
                          'thumbnails': [
                            {'url': '//lh3.googleusercontent.com/ytm_alb_first'},
                            {'url': '//lh3.googleusercontent.com/ytm_alb_last'},
                          ],
                        },
                      },
                    },
                  },
                },
                'contents': {
                  'track1': {
                    'musicResponsiveListItemRenderer': {
                      'playlistItemData': {'videoId': 'yt_cov_3'},
                      'flexColumns': [
                        {
                          'musicResponsiveListItemFlexColumnRenderer': {
                            'text': {'simpleText': 'YTM Album Child Track'},
                          },
                        },
                      ],
                    },
                  },
                },
              });
            }
          }

          // 3. Tidal (UUID -> 640x640.jpg + album inheritance + imageCover/imageId)
          if (path == '/sessions') {
            return replyJson(HttpStatus.ok, {'userId': 777, 'countryCode': 'TW'});
          }
          if (path == '/users/777') {
            return replyJson(HttpStatus.ok, {'id': 777, 'fullName': 'Tidal Cover'});
          }
          if (path == '/users/777/subscription') {
            return replyJson(HttpStatus.ok, {
              'subscription': {'type': 'HI_RES'},
            });
          }
          if (path == '/pages/home') {
            return replyJson(HttpStatus.ok, {
              'rows': [
                {
                  'modules': [
                    {
                      'type': 'ALBUM_LIST',
                      'pagedList': {
                        'items': [
                          {
                            'id': 950,
                            'title': 'Tidal UUID Album',
                            'cover': '12345678-90ab-cdef-1234-567890abcdef',
                            'artist': {'name': 'Tidal Artist'},
                            'numberOfTracks': 2,
                          },
                        ],
                      },
                    },
                    {
                      'type': 'TRACK_LIST',
                      'pagedList': {
                        'items': [
                          {
                            'id': 9501,
                            'title': 'Tidal Track Inherited From Sibling Album',
                            'duration': 205,
                            'artist': {'name': 'Tidal Artist'},
                            'album': {'id': 950, 'title': 'Tidal UUID Album'},
                          },
                          {
                            'id': 9502,
                            'title': 'Tidal Track ImageId',
                            'duration': 190,
                            'imageId': 'aaaa1111-2222-3333-4444-555566667777',
                            'artist': {'name': 'Tidal Artist'},
                            'album': {'title': 'Single'},
                          },
                        ],
                      },
                    },
                  ],
                },
              ],
            });
          }
          if (path == '/albums/950') {
            return replyJson(HttpStatus.ok, {
              'id': 950,
              'title': 'Tidal UUID Album',
              'cover': '12345678-90ab-cdef-1234-567890abcdef',
              'artist': {'name': 'Tidal Artist'},
              'items': [
                {'id': 9501, 'title': 'Tidal Album Track 1', 'duration': 205},
              ],
            });
          }

          // 4. Apple Music ({w}x{h} -> 600x600, {f} -> jpg, parent album attributes.artwork inheritance)
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
                  'id': 'rec_group_cov',
                  'type': 'personal-recommendation',
                  'relationships': {
                    'contents': {
                      'data': [
                        {
                          'id': '650',
                          'type': 'albums',
                          'attributes': {
                            'name': 'Apple Parent Artwork Album',
                            'artistName': 'Apple Ensemble',
                            'artwork': {
                              'url':
                                  '//is1-ssl.mzstatic.com/image/thumb/{w}x{h}bb.{f}',
                            },
                          },
                          'relationships': {
                            'tracks': {
                              'data': [
                                {
                                  'id': '6501',
                                  'type': 'songs',
                                  'attributes': {
                                    'name': 'Apple Child Song Inherited Art',
                                    'artistName': 'Apple Ensemble',
                                    'durationInMillis': 200000,
                                    // Missing attributes.artwork -> inherits parent album artwork!
                                  },
                                },
                              ],
                            },
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
            return replyJson(HttpStatus.ok, {'data': <Object>[]});
          }

          // 5. Deezer (cover_big / cover / md5_image fallback)
          if (path == '/ajax/gw-light.php') {
            return replyJson(HttpStatus.ok, {
              'error': <String, dynamic>{},
              'results': {
                'checkForm': 'csrf_cov',
                'USER': {'USER_ID': 555, 'BLOG_NAME': 'Deezer Cover User'},
              },
            });
          }
          if (path == '/user/555/recommendations/albums') {
            return replyJson(HttpStatus.ok, {
              'data': [
                {
                  'id': 850,
                  'title': 'Deezer Cover Album',
                  'artist': {'name': 'French Touch'},
                  'cover_big': '//cdn-images.dzcdn.net/images/cover/big500.jpg',
                },
                {
                  'id': 851,
                  'title': 'Deezer MD5 Album',
                  'artist': {'name': 'French Touch'},
                  'md5_image': 'abc123md5hash',
                },
              ],
            });
          }
          if (path == '/user/555/recommendations/tracks') {
            return replyJson(HttpStatus.ok, {
              'data': [
                {
                  'id': 8501,
                  'title': 'Deezer Track Cover Key',
                  'duration': 195,
                  'artist': {'name': 'French Touch'},
                  'album': {
                    'title': 'Deezer Cover Album',
                    'cover': 'https://api.deezer.com/album/850/image',
                  },
                },
                {
                  'id': 8502,
                  'title': 'Deezer Track MD5 Fallback',
                  'duration': 205,
                  'md5_image': 'deadbeef0123456789abcdef',
                  'artist': {'name': 'French Touch'},
                  'album': {'title': 'Single'},
                },
              ],
            });
          }
          if (path == '/chart/0/albums' ||
              path == '/user/555/flow' ||
              path == '/user/555/tracks') {
            return replyJson(HttpStatus.ok, {'data': <Object>[]});
          }

          return replyJson(HttpStatus.notFound, {'error': 'Not found: $path'});
        });

        final baseUrl = 'http://127.0.0.1:${server.port}';
        final store = MemorySecureCredentialStore();

        final qobuz = QobuzProvider(credentialStore: store, baseUrl: baseUrl);
        final ytm = YouTubeMusicProvider(
          credentialStore: store,
          baseUrl: baseUrl,
          oauthBaseUrl: baseUrl,
        );
        final tidal = TidalProvider(
          credentialStore: store,
          authBaseUrl: baseUrl,
          tokenBaseUrl: baseUrl,
          apiBaseUrl: baseUrl,
        );
        final apple = AppleMusicProvider(
          credentialStore: store,
          apiBaseUrl: baseUrl,
        );
        final deezer = DeezerProvider(
          credentialStore: store,
          gwUrl: '$baseUrl/ajax/gw-light.php',
          oauthBaseUrl: baseUrl,
          apiBaseUrl: baseUrl,
          mediaBaseUrl: '$baseUrl/media',
        );

        await qobuz.authenticate({
          'mode': 'token',
          'app_id': '950096963',
          'user_auth_token': 'qobuz_tok_cov',
        });
        await ytm.authenticate({
          'mode': 'cookie',
          'cookie': 'SAPISID=sap_1; SID=sid_1',
        });
        await tidal.authenticate({
          'mode': 'access_token',
          'access_token': 'tidal_tok_cov',
        });
        await apple.authenticate({
          'developer_token': 'dev_cov',
          'music_user_token': 'mut_cov',
        });
        await deezer.authenticate({
          'mode': 'arl',
          'arl': 'arl_cov',
        });

        // Qobuz assertions (even batchIndex == 0 fetches /album/get when tracks empty!)
        final qobuzRec = await qobuz.fetchRecommendations();
        expect(qobuzAlbumGetCalls, 1);
        expect(
          qobuzRec.albums.first.coverUrl,
          'https://static.qobuz.com/images/covers/qb/alb1_230.jpg',
        );
        expect(
          qobuzRec.albums[1].coverUrl,
          'https://static.qobuz.com/images/covers/qb/alb2_thumb.jpg',
        );
        expect(
          qobuzRec.tracks.first.coverUrl,
          'https://static.qobuz.com/images/covers/qb/alb1_600.jpg',
        );
        expect(qobuzRec.tracks.first.album, 'Qobuz Featured Album');
        expect(qobuzRec.tracks.first.artist, 'Qobuz Artist');
        expect(
          qobuzRec.tracks[1].coverUrl,
          'https://static.qobuz.com/images/covers/qb/trk_thumb.jpg',
        );

        // YTM assertions
        final ytmRec = await ytm.fetchRecommendations();
        expect(
          ytmRec.tracks.first.coverUrl,
          'https://lh3.googleusercontent.com/ytm_best_544=w1200-h1200-l90-rj',
        );
        expect(
          ytmRec.tracks[1].coverUrl,
          'https://lh3.googleusercontent.com/ytm_header_600=w1200-h1200-l90-rj',
        );
        final ytmAlb = await ytm.fetchAlbumDetail('MPREb_cov_1');
        expect(
          ytmAlb?.coverUrl,
          'https://lh3.googleusercontent.com/ytm_alb_last=w1200-h1200-l90-rj',
        );

        // Tidal assertions
        final tidalRec = await tidal.fetchRecommendations();
        expect(
          tidalRec.albums.single.coverUrl,
          'https://resources.tidal.com/images/12345678/90ab/cdef/1234/567890abcdef/640x640.jpg',
        );
        expect(
          tidalRec.tracks.first.coverUrl,
          'https://resources.tidal.com/images/12345678/90ab/cdef/1234/567890abcdef/640x640.jpg',
        );
        expect(
          tidalRec.tracks[1].coverUrl,
          'https://resources.tidal.com/images/aaaa1111/2222/3333/4444/555566667777/640x640.jpg',
        );

        // Apple Music assertions
        final appleRec = await apple.fetchRecommendations();
        expect(
          appleRec.albums.single.coverUrl,
          'https://is1-ssl.mzstatic.com/image/thumb/600x600bb.jpg',
        );
        expect(
          appleRec.tracks.single.coverUrl,
          'https://is1-ssl.mzstatic.com/image/thumb/600x600bb.jpg',
        );
        expect(appleRec.tracks.single.album, 'Apple Parent Artwork Album');

        // Deezer assertions
        final deezerRec = await deezer.fetchRecommendations();
        expect(
          deezerRec.albums.first.coverUrl,
          'https://cdn-images.dzcdn.net/images/cover/big500.jpg',
        );
        expect(
          deezerRec.albums[1].coverUrl,
          'https://e-cdns-images.dzcdn.net/images/cover/abc123md5hash/500x500-000000-80-0-0.jpg',
        );
        expect(
          deezerRec.tracks.first.coverUrl,
          'https://api.deezer.com/album/850/image',
        );
        expect(
          deezerRec.tracks[1].coverUrl,
          'https://e-cdns-images.dzcdn.net/images/cover/deadbeef0123456789abcdef/500x500-000000-80-0-0.jpg',
        );
      },
    );

    test(
      'StreamingRecommendations JSON round-trip preserves/normalizes coverUrl & albumArtUrl, and StreamingManager auto-invalidates cover-less disk cache',
      () async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        final tempDir = Directory.systemTemp.createTempSync('lumina_cov_heal_');
        addTearDown(() {
          HttpOverrides.global = prevOverrides;
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        });

        // 1. JSON round-trip & normalization check
        final sampleRec = StreamingRecommendations(
          providerKind: 'youtube_music',
          fetchedAt: DateTime.utc(2026, 11, 22, 12, 0, 0),
          albums: const [
            StreamingAlbum(
              id: 'alb_rt',
              title: 'RoundTrip Album',
              artist: 'Artist',
              coverUrl: '//cdn.example.com/alb.jpg',
              providerKind: 'youtube_music',
            ),
          ],
          tracks: const [
            TrackInfo(
              id: 'ytm:trk_rt',
              title: 'RoundTrip Track',
              artist: 'Artist',
              album: 'RoundTrip Album',
              duration: Duration(seconds: 210),
              coverUrl: '//cdn.example.com/trk.jpg',
              albumArtUrl: '//cdn.example.com/trk.jpg',
              format: AudioFormat(
                codec: AudioCodec.opus,
                sampleRateHz: 48000,
                bitDepth: 16,
                channels: 2,
              ),
              providerName: 'YouTube Music',
            ),
          ],
        );
        final decodedRec = StreamingRecommendations.fromJson(
          jsonDecode(jsonEncode(sampleRec.toJson())) as Map<String, dynamic>,
        );
        expect(decodedRec.albums.single.coverUrl, 'https://cdn.example.com/alb.jpg');
        expect(decodedRec.tracks.single.coverUrl, 'https://cdn.example.com/trk.jpg');
        expect(decodedRec.tracks.single.albumArtUrl, 'https://cdn.example.com/trk.jpg');

        final fallbackParsed = StreamingRecommendations.trackFromJson({
          'id': 'qobuz:1',
          'title': 'Fallback Art',
          'artist': 'Artist',
          'album': 'Album',
          'duration_ms': 180000,
          'cover_url': '   ',
          'album_art_url': '//static.qobuz.com/fallback.jpg',
        });
        expect(fallbackParsed.coverUrl, 'https://static.qobuz.com/fallback.jpg');
        expect(fallbackParsed.albumArtUrl, 'https://static.qobuz.com/fallback.jpg');

        // 2. Cover-less disk cache auto-invalidation and live refetch
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
                'display_name': 'Qobuz Self-Heal',
                'user_auth_token': 'qb_heal_tok',
                'user': {'id': 91, 'display_name': 'Qobuz Self-Heal'},
              }),
            );
          } else if (path == '/album/getFeatured') {
            featuredCalls++;
            req.response.write(
              jsonEncode({
                'albums': {
                  'items': [
                    {
                      'id': 'qb_heal_alb',
                      'title': 'Fresh Covered Album',
                      'artist': {'name': 'Qobuz Orchestra'},
                      'image': {
                        'large': 'https://static.qobuz.com/images/fresh_alb_600.jpg',
                      },
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
                      'id': 8801,
                      'title': 'Fresh Covered Track',
                      'duration': 200,
                      'performer': {'name': 'Qobuz Orchestra'},
                      'album': {
                        'title': 'Fresh Covered Album',
                        'image': {
                          'large': 'https://static.qobuz.com/images/fresh_trk_600.jpg',
                        },
                      },
                    },
                  ],
                },
              }),
            );
          }
          await req.response.close();
        });

        final now = DateTime(2026, 11, 22, 12, 0, 0);
        final store = MemorySecureCredentialStore();
        await store.write(
          'streaming:qobuz',
          jsonEncode({
            'app_id': '950096963',
            'user_auth_token': 'qb_heal_tok',
          }),
        );

        final cacheFile = File(
          '${tempDir.path}${Platform.pathSeparator}rec_poisoned_cache.json',
        );
        // Write a "fresh-timestamp" disk cache whose tracks ALL lack cover_url & album_art_url!
        cacheFile.writeAsStringSync(
          jsonEncode({
            'version': 1,
            'updated_at': now.toUtc().toIso8601String(),
            'providers': {
              'qobuz': {
                'provider_kind': 'qobuz',
                'fetched_at': now.toUtc().toIso8601String(),
                'albums': [
                  {
                    'id': 'stale_alb',
                    'title': 'Stale Album',
                    'artist': 'Old Artist',
                    'cover_url': 'https://static.qobuz.com/old_alb.jpg',
                    'provider_kind': 'qobuz',
                  },
                ],
                'tracks': [
                  {
                    'id': 'qobuz:stale_1',
                    'title': 'Stale Coverless Track',
                    'artist': 'Old Artist',
                    'album': 'Stale Album',
                    'duration_ms': 180000,
                    'provider_name': 'Qobuz',
                  },
                ],
              },
            },
          }),
        );

        final manager = StreamingManager(
          credentialStore: store,
          recommendationsCacheFile: cacheFile,
          clock: () => now,
          providers: {
            'qobuz': QobuzProvider(
              credentialStore: store,
              baseUrl: 'http://127.0.0.1:${server.port}',
              clock: () => now,
            ),
            'youtube_music': YouTubeMusicProvider(
              credentialStore: store,
              baseUrl: 'http://127.0.0.1:${server.port}',
              clock: () => now,
            ),
          },
        );
        addTearDown(manager.dispose);

        await manager.initialize();
        for (var i = 0; i < 50 && manager.isAnyRecommendationLoading; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        expect(featuredCalls, 1);
        final healed = manager.recommendationsFor('qobuz')!;
        expect(healed.tracks.single.id, 'qobuz:8801');
        expect(
          healed.tracks.single.coverUrl,
          'https://static.qobuz.com/images/fresh_trk_600.jpg',
        );
      },
    );
  });
}
