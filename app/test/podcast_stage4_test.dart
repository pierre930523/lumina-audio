import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/home_layout_preset.dart';
import 'package:lumina_app/models/nav_entry.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/podcast_models.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/services/desktop_window_controller.dart';
import 'package:lumina_app/services/escape_dismiss_registry.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/podcast_store.dart';
import 'package:lumina_app/services/streaming/providers/youtube_music_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:lumina_app/ui/podcasts/podcast_detail_page.dart';
import 'package:lumina_app/ui/podcasts/podcasts_view.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

typedef _RouteHandler = FutureOr<void> Function(HttpRequest req, String body);

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

class _FakePodcastStreamingManager extends StreamingManager {
  PodcastExploreResult exploreResult;
  PodcastLibraryResult myPodcastsResult;
  final Map<String, PodcastSearchResult> searchResultsByQuery;
  final Map<String, PodcastShowDetail> showDetailsById;
  final Map<String, PodcastShowDetail> showContinuations;
  bool connected;
  int fetchExploreCount = 0;
  int fetchMyCount = 0;
  final List<String> searchedQueries = <String>[];
  final List<String> fetchedShowIds = <String>[];
  final List<String> fetchedContinuations = <String>[];

  _FakePodcastStreamingManager({
    this.exploreResult = const PodcastExploreResult(),
    this.myPodcastsResult = const PodcastLibraryResult(),
    Map<String, PodcastSearchResult>? searchResultsByQuery,
    Map<String, PodcastShowDetail>? showDetailsById,
    Map<String, PodcastShowDetail>? showContinuations,
    this.connected = false,
  })  : searchResultsByQuery =
            searchResultsByQuery ?? <String, PodcastSearchResult>{},
        showDetailsById = showDetailsById ?? <String, PodcastShowDetail>{},
        showContinuations = showContinuations ?? <String, PodcastShowDetail>{},
        super(credentialStore: MemorySecureCredentialStore());

  @override
  bool get isYouTubeMusicConnected => connected;

  @override
  Future<void> initialize() async {}

  @override
  Future<PodcastExploreResult> fetchExplorePodcasts({
    String? continuation,
    CancellationToken? cancel,
  }) async {
    fetchExploreCount++;
    return exploreResult;
  }

  @override
  Future<PodcastLibraryResult> fetchMyPodcasts({
    CancellationToken? cancel,
  }) async {
    fetchMyCount++;
    if (!connected) return const PodcastLibraryResult();
    return myPodcastsResult;
  }

  @override
  Future<PodcastSearchResult> searchPodcasts(
    String query, {
    CancellationToken? cancel,
  }) async {
    searchedQueries.add(query.trim());
    return searchResultsByQuery[query.trim()] ??
        searchResultsByQuery['*'] ??
        const PodcastSearchResult();
  }

  @override
  Future<PodcastShowDetail> fetchPodcastShowDetail(
    String showBrowseId, {
    String? continuation,
    CancellationToken? cancel,
  }) async {
    if (continuation != null && continuation.isNotEmpty) {
      fetchedContinuations.add(continuation);
      return showContinuations[continuation] ??
          PodcastShowDetail(
            show: PodcastShow(id: showBrowseId, title: 'Show $showBrowseId'),
          );
    }
    fetchedShowIds.add(showBrowseId);
    return showDetailsById[showBrowseId] ??
        PodcastShowDetail(
          show: PodcastShow(id: showBrowseId, title: 'Show $showBrowseId'),
        );
  }

  @override
  Future<ResolvedStreamResult> resolveStreamForTrack(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
    bool bypassCache = false,
  }) async {
    return ResolvedStreamResult(
      url: 'https://stream.example.com/${track.id}.m4a',
      hintExtension: 'm4a',
      format: track.format,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sampleShowA = PodcastShow(
    id: 'MPSPPL_show_alpha_01',
    title: 'Deep Tech Weekly',
    author: 'Lumina Labs',
    artworkUrl: 'https://i.ytimg.com/pl_c/PL_show_alpha_01/cover_544.jpg',
    description: 'Deep dives into systems programming, audio DSP, and AI.',
    episodeCountLabel: '48 集',
    latestEpisodeTitle: 'Ep 48: WASAPI Exclusive Internals',
  );

  const sampleShowB = PodcastShow(
    id: 'MPSPPL_show_beta_02',
    title: 'Acoustic Frontiers',
    author: 'Studio Reference',
    artworkUrl: 'https://i.ytimg.com/pl_c/PL_show_beta_02/cover_544.jpg',
    description: 'Mastering engineers discuss room acoustics.',
    episodeCountLabel: '24 集',
    latestEpisodeTitle: 'Ep 24: Ribbon Tweeters Explained',
  );

  const sampleEp1 = PodcastEpisode(
    videoId: 'aBcDeFgHiJk',
    showId: 'MPSPPL_show_alpha_01',
    showTitle: 'Deep Tech Weekly',
    title: 'Ep 48: WASAPI Exclusive Internals',
    author: 'Lumina Labs',
    artworkUrl: 'https://i.ytimg.com/vi/aBcDeFgHiJk/hq720.jpg',
    publishedLabel: '2 天前',
    duration: Duration(minutes: 42, seconds: 15),
    description: 'Exploring bit-perfect audio pipelines on Windows.',
  );

  const sampleEp2 = PodcastEpisode(
    videoId: 'lMnOpQrStUv',
    showId: 'MPSPPL_show_alpha_01',
    showTitle: 'Deep Tech Weekly',
    title: 'Ep 47: Zero-Copy Ring Buffers',
    author: 'Lumina Labs',
    artworkUrl: 'https://i.ytimg.com/vi/lMnOpQrStUv/hq720.jpg',
    publishedLabel: '1 週前',
    duration: Duration(minutes: 35),
    description: 'Lock-free concurrency patterns for real-time audio threads.',
  );

  const sampleEp3Page2 = PodcastEpisode(
    videoId: 'wXyZ0123456',
    showId: 'MPSPPL_show_alpha_01',
    showTitle: 'Deep Tech Weekly',
    title: 'Ep 46: FIR Filter Design',
    author: 'Lumina Labs',
    artworkUrl: 'https://i.ytimg.com/vi/wXyZ0123456/hq720.jpg',
    publishedLabel: '2 週前',
    duration: Duration(minutes: 50),
    description: 'Linear-phase vs minimum-phase crossovers.',
  );

  setUp(() {
    PodcastStore.instance.resetForTest();
    EscapeDismissRegistry.instance.clear();
  });

  tearDown(() {
    PodcastStore.instance.resetForTest();
    EscapeDismissRegistry.instance.clear();
  });

  group('1. Zero hardcoded fake Podcast data', () {
    test('podcasts_view.dart source contains zero legacy mock shows or items', () {
      final file = File('lib/ui/podcasts/podcasts_view.dart');
      expect(file.existsSync(), isTrue);
      final source = file.readAsStringSync();
      expect(source.contains('法客電台'), isFalse);
      expect(source.contains('The Vergecast'), isFalse);
      expect(source.contains('pod-001'), isFalse);
      expect(source.contains('pod-002'), isFalse);
      expect(source.contains('_PodcastItem'), isFalse);
      expect(source.contains('_podcasts'), isFalse);
    });

    testWidgets('rendered PodcastsView contains zero hardcoded mock titles', (
      tester,
    ) async {
      final svc = MockAudioService();
      addTearDown(svc.dispose);
      final sm = _FakePodcastStreamingManager(
        exploreResult: const PodcastExploreResult(
          shows: <PodcastShow>[sampleShowA],
          episodes: <PodcastEpisode>[sampleEp1],
        ),
      );
      addTearDown(sm.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaTokens.buildDarkTheme(),
          home: Scaffold(
            body: PodcastsView(
              audioService: svc,
              streamingManager: sm,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('法客電台'), findsNothing);
      expect(find.text('The Vergecast'), findsNothing);
      expect(find.text('法律白話文運動'), findsNothing);
      expect(find.text('Deep Tech Weekly'), findsWidgets);
    });
  });

  group('2. InnerTube Podcast JSON parsing (YouTubeMusicProvider)', () {
    setUp(() {
      HttpOverrides.global = null;
    });

    test(
      'fetchExplorePodcasts falls back from FEmusic_podcasts 404 to FEmusic_non_music_audio and parses musicTwoRowItemRenderer & musicMultiRowListItemRenderer',
      () async {
        final requestedBrowseIds = <String>[];
        final server = await _startServer((req, body) async {
          if (req.uri.path == '/youtubei/v1/browse') {
            final decoded = jsonDecode(body) as Map<String, dynamic>;
            final bid = decoded['browseId']?.toString() ?? '';
            requestedBrowseIds.add(bid);
            if (bid == 'FEmusic_podcasts') {
              await _sendJson(req.response, 404, <String, dynamic>{
                'error': <String, dynamic>{
                  'code': 404,
                  'message': 'Requested entity was not found.',
                },
              });
              return;
            }
            if (bid == 'FEmusic_non_music_audio') {
              await _sendJson(req.response, 200, <String, dynamic>{
                'responseContext': <String, dynamic>{
                  'visitorData': 'CgtExploreVisitorData12345',
                },
                'contents': <String, dynamic>{
                  'singleColumnBrowseResultsRenderer': <String, dynamic>{
                    'tabs': <dynamic>[
                      <String, dynamic>{
                        'tabRenderer': <String, dynamic>{
                          'content': <String, dynamic>{
                            'sectionListRenderer': <String, dynamic>{
                              'contents': <dynamic>[
                                <String, dynamic>{
                                  'musicCarouselShelfRenderer':
                                      <String, dynamic>{
                                    'contents': <dynamic>[
                                      <String, dynamic>{
                                        'musicTwoRowItemRenderer':
                                            <String, dynamic>{
                                          'title': <String, dynamic>{
                                            'runs': <dynamic>[
                                              <String, dynamic>{
                                                'text': 'Deep Tech Weekly',
                                              },
                                            ],
                                          },
                                          'subtitle': <String, dynamic>{
                                            'runs': <dynamic>[
                                              <String, dynamic>{
                                                'text': 'Podcast',
                                              },
                                              <String, dynamic>{'text': ' • '},
                                              <String, dynamic>{
                                                'text': 'Lumina Labs',
                                              },
                                              <String, dynamic>{'text': ' • '},
                                              <String, dynamic>{
                                                'text': '48 集',
                                              },
                                            ],
                                          },
                                          'navigationEndpoint':
                                              <String, dynamic>{
                                            'browseEndpoint': <String, dynamic>{
                                              'browseId':
                                                  'MPSPPL_show_alpha_01',
                                              'browseEndpointContextSupportedConfigs':
                                                  <String, dynamic>{
                                                'browseEndpointContextMusicConfig':
                                                    <String, dynamic>{
                                                  'pageType':
                                                      'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE',
                                                },
                                              },
                                            },
                                          },
                                          'thumbnailRenderer':
                                              <String, dynamic>{
                                            'musicThumbnailRenderer':
                                                <String, dynamic>{
                                              'thumbnail': <String, dynamic>{
                                                'thumbnails': <dynamic>[
                                                  <String, dynamic>{
                                                    'url':
                                                        'https://i.ytimg.com/pl_c/PL_show_alpha_01/low_60.jpg',
                                                    'width': 60,
                                                    'height': 60,
                                                  },
                                                  <String, dynamic>{
                                                    'url':
                                                        'https://i.ytimg.com/pl_c/PL_show_alpha_01/high_544.jpg',
                                                    'width': 544,
                                                    'height': 544,
                                                  },
                                                ],
                                              },
                                            },
                                          },
                                        },
                                      },
                                    ],
                                  },
                                },
                                <String, dynamic>{
                                  'musicShelfRenderer': <String, dynamic>{
                                    'contents': <dynamic>[
                                      <String, dynamic>{
                                        'musicMultiRowListItemRenderer':
                                            <String, dynamic>{
                                          'title': <String, dynamic>{
                                            'runs': <dynamic>[
                                              <String, dynamic>{
                                                'text':
                                                    'Ep 48: WASAPI Exclusive Internals',
                                              },
                                            ],
                                          },
                                          'subtitle': <String, dynamic>{
                                            'runs': <dynamic>[
                                              <String, dynamic>{
                                                'text': '2 天前',
                                              },
                                              <String, dynamic>{'text': ' • '},
                                              <String, dynamic>{
                                                'text': 'Deep Tech Weekly',
                                                'navigationEndpoint':
                                                    <String, dynamic>{
                                                  'browseEndpoint':
                                                      <String, dynamic>{
                                                    'browseId':
                                                        'MPSPPL_show_alpha_01',
                                                    'browseEndpointContextSupportedConfigs':
                                                        <String, dynamic>{
                                                      'browseEndpointContextMusicConfig':
                                                          <String, dynamic>{
                                                        'pageType':
                                                            'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE',
                                                      },
                                                    },
                                                  },
                                                },
                                              },
                                            ],
                                          },
                                          'description': <String, dynamic>{
                                            'runs': <dynamic>[
                                              <String, dynamic>{
                                                'text':
                                                    'Exploring bit-perfect audio pipelines on Windows.',
                                              },
                                            ],
                                          },
                                          'onTap': <String, dynamic>{
                                            'watchEndpoint': <String, dynamic>{
                                              'videoId': 'aBcDeFgHiJk',
                                            },
                                          },
                                          'playbackProgress': <String, dynamic>{
                                            'musicPlaybackProgressRenderer':
                                                <String, dynamic>{
                                              'durationText': <String, dynamic>{
                                                'runs': <dynamic>[
                                                  <String, dynamic>{
                                                    'text': ' • ',
                                                  },
                                                  <String, dynamic>{
                                                    'text': '42 分鐘',
                                                  },
                                                ],
                                              },
                                            },
                                          },
                                          'thumbnail': <String, dynamic>{
                                            'musicThumbnailRenderer':
                                                <String, dynamic>{
                                              'thumbnail': <String, dynamic>{
                                                'thumbnails': <dynamic>[
                                                  <String, dynamic>{
                                                    'url':
                                                        'https://i.ytimg.com/vi/aBcDeFgHiJk/hqdefault.jpg',
                                                    'width': 400,
                                                    'height': 225,
                                                  },
                                                  <String, dynamic>{
                                                    'url':
                                                        'https://i.ytimg.com/vi/aBcDeFgHiJk/hq720.jpg',
                                                    'width': 853,
                                                    'height': 479,
                                                  },
                                                ],
                                              },
                                            },
                                          },
                                        },
                                      },
                                    ],
                                  },
                                },
                              ],
                            },
                          },
                        },
                      },
                    ],
                  },
                },
              });
              return;
            }
          }
          await _sendJson(req.response, 404, const <String, dynamic>{});
        });
        addTearDown(server.close);

        final provider = YouTubeMusicProvider(
          credentialStore: MemorySecureCredentialStore(),
          baseUrl: 'http://${server.address.host}:${server.port}',
        );

        final res = await provider.fetchExplorePodcasts();
        expect(
          requestedBrowseIds,
          <String>['FEmusic_podcasts', 'FEmusic_non_music_audio'],
        );
        expect(res.shows, hasLength(1));
        expect(res.shows.first.id, 'MPSPPL_show_alpha_01');
        expect(res.shows.first.title, 'Deep Tech Weekly');
        expect(res.shows.first.author, 'Lumina Labs');
        expect(res.shows.first.episodeCountLabel, '48 集');
        expect(
          res.shows.first.artworkUrl,
          'https://i.ytimg.com/pl_c/PL_show_alpha_01/high_544.jpg',
        );

        expect(res.episodes, hasLength(1));
        final ep = res.episodes.first;
        expect(ep.videoId, 'aBcDeFgHiJk');
        expect(ep.showId, 'MPSPPL_show_alpha_01');
        expect(ep.showTitle, 'Deep Tech Weekly');
        expect(ep.publishedLabel, '2 天前');
        expect(ep.duration, const Duration(minutes: 42));
        expect(
          ep.artworkUrl,
          'https://i.ytimg.com/vi/aBcDeFgHiJk/hq720.jpg',
        );

        final track = ep.toTrack();
        expect(track.id, 'ytm:aBcDeFgHiJk');
        expect(track.providerName, 'Podcast');
        expect(track.album, 'Deep Tech Weekly');
        expect(track.artworkUrl, 'https://i.ytimg.com/vi/aBcDeFgHiJk/hq720.jpg');
      },
    );

    test(
      'searchPodcasts & fetchPodcastShowDetail parse header description shelf, episodes, and continuation pagination',
      () async {
        final server = await _startServer((req, body) async {
          final decoded = jsonDecode(body) as Map<String, dynamic>;
          if (req.uri.path == '/youtubei/v1/search') {
            final params = decoded['params']?.toString() ?? '';
            if (params == YouTubeMusicProvider.podcastShowsSearchParams) {
              await _sendJson(req.response, 200, <String, dynamic>{
                'contents': <String, dynamic>{
                  'musicShelfRenderer': <String, dynamic>{
                    'contents': <dynamic>[
                      <String, dynamic>{
                        'musicResponsiveListItemRenderer': <String, dynamic>{
                          'navigationEndpoint': <String, dynamic>{
                            'browseEndpoint': <String, dynamic>{
                              'browseId': 'MPSPPL_show_alpha_01',
                              'browseEndpointContextSupportedConfigs':
                                  <String, dynamic>{
                                'browseEndpointContextMusicConfig':
                                    <String, dynamic>{
                                  'pageType':
                                      'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE',
                                },
                              },
                            },
                          },
                          'thumbnail': <String, dynamic>{
                            'musicThumbnailRenderer': <String, dynamic>{
                              'thumbnail': <String, dynamic>{
                                'thumbnails': <dynamic>[
                                  <String, dynamic>{
                                    'url':
                                        'https://i.ytimg.com/pl_c/PL_show_alpha_01/cover_544.jpg',
                                    'width': 544,
                                    'height': 544,
                                  },
                                ],
                              },
                            },
                          },
                          'flexColumns': <dynamic>[
                            <String, dynamic>{
                              'musicResponsiveListItemFlexColumnRenderer':
                                  <String, dynamic>{
                                'text': <String, dynamic>{
                                  'runs': <dynamic>[
                                    <String, dynamic>{
                                      'text': 'Deep Tech Weekly',
                                    },
                                  ],
                                },
                              },
                            },
                            <String, dynamic>{
                              'musicResponsiveListItemFlexColumnRenderer':
                                  <String, dynamic>{
                                'text': <String, dynamic>{
                                  'runs': <dynamic>[
                                    <String, dynamic>{
                                      'text': 'Lumina Labs',
                                      'navigationEndpoint': <String, dynamic>{
                                        'browseEndpoint': <String, dynamic>{
                                          'browseId': 'UC_lumina_labs',
                                          'browseEndpointContextSupportedConfigs':
                                              <String, dynamic>{
                                            'browseEndpointContextMusicConfig':
                                                <String, dynamic>{
                                              'pageType':
                                                  'MUSIC_PAGE_TYPE_USER_CHANNEL',
                                            },
                                          },
                                        },
                                      },
                                    },
                                  ],
                                },
                              },
                            },
                          ],
                        },
                      },
                    ],
                  },
                },
              });
              return;
            }
            // Episodes filter response
            await _sendJson(req.response, 200, <String, dynamic>{
              'contents': <String, dynamic>{
                'musicShelfRenderer': <String, dynamic>{
                  'contents': <dynamic>[
                    <String, dynamic>{
                      'musicResponsiveListItemRenderer': <String, dynamic>{
                        'playlistItemData': <String, dynamic>{
                          'videoId': 'aBcDeFgHiJk',
                        },
                        'thumbnail': <String, dynamic>{
                          'musicThumbnailRenderer': <String, dynamic>{
                            'thumbnail': <String, dynamic>{
                              'thumbnails': <dynamic>[
                                <String, dynamic>{
                                  'url':
                                      'https://i.ytimg.com/vi/aBcDeFgHiJk/hq720.jpg',
                                  'width': 800,
                                  'height': 450,
                                },
                              ],
                            },
                          },
                        },
                        'flexColumns': <dynamic>[
                          <String, dynamic>{
                            'musicResponsiveListItemFlexColumnRenderer':
                                <String, dynamic>{
                              'text': <String, dynamic>{
                                'runs': <dynamic>[
                                  <String, dynamic>{
                                    'text':
                                        'Ep 48: WASAPI Exclusive Internals',
                                    'navigationEndpoint': <String, dynamic>{
                                      'browseEndpoint': <String, dynamic>{
                                        'browseId': 'MPEDaBcDeFgHiJk',
                                        'browseEndpointContextSupportedConfigs':
                                            <String, dynamic>{
                                          'browseEndpointContextMusicConfig':
                                              <String, dynamic>{
                                            'pageType':
                                                'MUSIC_PAGE_TYPE_NON_MUSIC_AUDIO_TRACK_PAGE',
                                          },
                                        },
                                      },
                                    },
                                  },
                                ],
                              },
                            },
                          },
                          <String, dynamic>{
                            'musicResponsiveListItemFlexColumnRenderer':
                                <String, dynamic>{
                              'text': <String, dynamic>{
                                'runs': <dynamic>[
                                  <String, dynamic>{'text': '7月30日'},
                                  <String, dynamic>{'text': ' • '},
                                  <String, dynamic>{
                                    'text': 'Deep Tech Weekly',
                                    'navigationEndpoint': <String, dynamic>{
                                      'browseEndpoint': <String, dynamic>{
                                        'browseId': 'MPSPPL_show_alpha_01',
                                        'browseEndpointContextSupportedConfigs':
                                            <String, dynamic>{
                                          'browseEndpointContextMusicConfig':
                                              <String, dynamic>{
                                            'pageType':
                                                'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE',
                                          },
                                        },
                                      },
                                    },
                                  },
                                ],
                              },
                            },
                          },
                        ],
                      },
                    },
                  ],
                },
              },
            });
            return;
          }

          if (req.uri.path == '/youtubei/v1/browse') {
            final cont = decoded['continuation']?.toString() ??
                req.uri.queryParameters['continuation'] ??
                '';
            if (cont == 'CONT_PAGE_2') {
              await _sendJson(req.response, 200, <String, dynamic>{
                'continuationContents': <String, dynamic>{
                  'musicShelfContinuation': <String, dynamic>{
                    'contents': <dynamic>[
                      <String, dynamic>{
                        'musicMultiRowListItemRenderer': <String, dynamic>{
                          'title': <String, dynamic>{
                            'runs': <dynamic>[
                              <String, dynamic>{
                                'text': 'Ep 46: FIR Filter Design',
                              },
                            ],
                          },
                          'onTap': <String, dynamic>{
                            'watchEndpoint': <String, dynamic>{
                              'videoId': 'wXyZ0123456',
                            },
                          },
                          'playbackProgress': <String, dynamic>{
                            'musicPlaybackProgressRenderer': <String, dynamic>{
                              'durationText': <String, dynamic>{
                                'runs': <dynamic>[
                                  <String, dynamic>{'text': ' • '},
                                  <String, dynamic>{'text': '50 分鐘'},
                                ],
                              },
                            },
                          },
                        },
                      },
                    ],
                  },
                },
              });
              return;
            }

            await _sendJson(req.response, 200, <String, dynamic>{
              'header': <String, dynamic>{
                'musicResponsiveHeaderRenderer': <String, dynamic>{
                  'title': <String, dynamic>{
                    'runs': <dynamic>[
                      <String, dynamic>{'text': 'Deep Tech Weekly'},
                    ],
                  },
                  'straplineTextOne': <String, dynamic>{
                    'runs': <dynamic>[
                      <String, dynamic>{'text': 'Lumina Labs'},
                    ],
                  },
                  'description': <String, dynamic>{
                    'musicDescriptionShelfRenderer': <String, dynamic>{
                      'description': <String, dynamic>{
                        'runs': <dynamic>[
                          <String, dynamic>{
                            'text':
                                'Deep dives into systems programming, audio DSP, and AI.',
                          },
                        ],
                      },
                    },
                  },
                  'thumbnail': <String, dynamic>{
                    'musicThumbnailRenderer': <String, dynamic>{
                      'thumbnail': <String, dynamic>{
                        'thumbnails': <dynamic>[
                          <String, dynamic>{
                            'url':
                                'https://i.ytimg.com/pl_c/PL_show_alpha_01/cover_544.jpg',
                            'width': 544,
                            'height': 544,
                          },
                        ],
                      },
                    },
                  },
                },
              },
              'contents': <String, dynamic>{
                'twoColumnBrowseResultsRenderer': <String, dynamic>{
                  'secondaryContents': <String, dynamic>{
                    'sectionListRenderer': <String, dynamic>{
                      'contents': <dynamic>[
                        <String, dynamic>{
                          'musicShelfRenderer': <String, dynamic>{
                            'contents': <dynamic>[
                              <String, dynamic>{
                                'musicMultiRowListItemRenderer':
                                    <String, dynamic>{
                                  'title': <String, dynamic>{
                                    'runs': <dynamic>[
                                      <String, dynamic>{
                                        'text':
                                            'Ep 48: WASAPI Exclusive Internals',
                                      },
                                    ],
                                  },
                                  'subtitle': <String, dynamic>{
                                    'runs': <dynamic>[
                                      <String, dynamic>{
                                        'text': '觀看次數：1.2萬次',
                                      },
                                      <String, dynamic>{'text': ' • '},
                                      <String, dynamic>{'text': '2 天前'},
                                    ],
                                  },
                                  'onTap': <String, dynamic>{
                                    'watchEndpoint': <String, dynamic>{
                                      'videoId': 'aBcDeFgHiJk',
                                    },
                                  },
                                  'playbackProgress': <String, dynamic>{
                                    'musicPlaybackProgressRenderer':
                                        <String, dynamic>{
                                      'durationText': <String, dynamic>{
                                        'runs': <dynamic>[
                                          <String, dynamic>{'text': ' • '},
                                          <String, dynamic>{
                                            'text': '1 小時 12 分鐘',
                                          },
                                        ],
                                      },
                                    },
                                  },
                                },
                              },
                            ],
                            'continuations': <dynamic>[
                              <String, dynamic>{
                                'nextContinuationData': <String, dynamic>{
                                  'continuation': 'CONT_PAGE_2',
                                },
                              },
                            ],
                          },
                        },
                      ],
                    },
                  },
                },
              },
            });
            return;
          }
          await _sendJson(req.response, 404, const <String, dynamic>{});
        });
        addTearDown(server.close);

        final provider = YouTubeMusicProvider(
          credentialStore: MemorySecureCredentialStore(),
          baseUrl: 'http://${server.address.host}:${server.port}',
        );

        // Search Podcasts
        final searchRes = await provider.searchPodcasts('Deep Tech');
        expect(searchRes.shows, hasLength(1));
        expect(searchRes.shows.first.id, 'MPSPPL_show_alpha_01');
        expect(searchRes.shows.first.author, 'Lumina Labs');
        expect(searchRes.episodes, hasLength(1));
        expect(searchRes.episodes.first.videoId, 'aBcDeFgHiJk');
        expect(searchRes.episodes.first.publishedLabel, '7月30日');
        expect(searchRes.episodes.first.showId, 'MPSPPL_show_alpha_01');

        // Show Detail Page 1
        final detailPage1 = await provider.fetchPodcastShowDetail(
          'MPSPPL_show_alpha_01',
        );
        expect(detailPage1.show.title, 'Deep Tech Weekly');
        expect(detailPage1.show.author, 'Lumina Labs');
        expect(
          detailPage1.show.description,
          'Deep dives into systems programming, audio DSP, and AI.',
        );
        expect(detailPage1.episodes, hasLength(1));
        expect(detailPage1.episodes.first.videoId, 'aBcDeFgHiJk');
        expect(detailPage1.episodes.first.publishedLabel, '2 天前');
        expect(
          detailPage1.episodes.first.duration,
          const Duration(hours: 1, minutes: 12),
        );
        expect(detailPage1.continuationToken, 'CONT_PAGE_2');

        // Show Detail Continuation Page 2
        final detailPage2 = await provider.fetchPodcastShowDetail(
          'MPSPPL_show_alpha_01',
          continuation: detailPage1.continuationToken,
        );
        expect(detailPage2.episodes, hasLength(1));
        expect(detailPage2.episodes.first.videoId, 'wXyZ0123456');
        expect(detailPage2.episodes.first.title, 'Ep 46: FIR Filter Design');
        expect(
          detailPage2.episodes.first.duration,
          const Duration(minutes: 50),
        );

        // Unauthenticated fetchMyPodcasts returns empty gracefully
        final guestMy = await provider.fetchMyPodcasts();
        expect(guestMy.shows, isEmpty);
        expect(guestMy.episodes, isEmpty);
      },
    );
  });

  group(
    '3. Podcast main page tabs, guest login guidance, direct explore playback, search & bookmarking, and high-res artwork',
    () {
      testWidgets(
        'supports 我的節目 / 探索推薦 / 最新單集 tabs, guest login prompt, direct guest playback, search, bookmarking, and high-res NetworkImage',
        (tester) async {
          tester.view.physicalSize = const Size(1400, 900);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          final svc = MockAudioService();
          addTearDown(svc.dispose);
          final store = PodcastStore();
          addTearDown(store.dispose);

          final sm = _FakePodcastStreamingManager(
            connected: false,
            exploreResult: const PodcastExploreResult(
              shows: <PodcastShow>[sampleShowA],
              episodes: <PodcastEpisode>[sampleEp1],
            ),
            searchResultsByQuery: <String, PodcastSearchResult>{
              'Acoustic': const PodcastSearchResult(
                shows: <PodcastShow>[sampleShowB],
                episodes: <PodcastEpisode>[sampleEp2],
              ),
            },
          );
          addTearDown(sm.dispose);

          var loginOpened = false;
          TrackInfo? playedTrack;

          await tester.pumpWidget(
            MaterialApp(
              theme: LuminaTokens.buildDarkTheme(),
              home: Scaffold(
                body: PodcastsView(
                  audioService: svc,
                  streamingManager: sm,
                  podcastStore: store,
                  onOpenLogin: () => loginOpened = true,
                  onPlayStreamingTrack: (track, {queueContext}) async {
                    playedTrack = track;
                    await svc.play(track: track);
                  },
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          // In guest mode with no bookmarks, defaults to 探索推薦 and renders show + episode + high-res cover art.
          expect(
            find.byKey(const Key('podcast_show_card_MPSPPL_show_alpha_01')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('podcast_episode_tile_aBcDeFgHiJk')),
            findsOneWidget,
          );

          final networkImages = tester
              .widgetList<Image>(find.byType(Image))
              .where((img) => img.image is NetworkImage)
              .map((img) => (img.image as NetworkImage).url)
              .toList();
          expect(
            networkImages,
            contains(
              'https://i.ytimg.com/pl_c/PL_show_alpha_01/cover_544.jpg',
            ),
          );
          expect(
            networkImages,
            contains('https://i.ytimg.com/vi/aBcDeFgHiJk/hq720.jpg'),
          );

          // Direct playback in 探索推薦 without login
          await tester.tap(
            find.byKey(const Key('btn_play_episode_aBcDeFgHiJk')),
          );
          await tester.pumpAndSettle();
          expect(playedTrack, isNotNull);
          expect(playedTrack!.id, 'ytm:aBcDeFgHiJk');
          expect(playedTrack!.providerName, 'Podcast');
          expect(svc.currentState.status, PlaybackStatus.playing);

          // Switch to 最新單集 tab
          await tester.tap(
            find.byKey(const Key('podcast_tab_latest_episodes')),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('podcast_episode_tile_aBcDeFgHiJk')),
            findsOneWidget,
          );

          // Switch to 我的節目 tab -> shows guest login guidance card
          await tester.tap(find.byKey(const Key('podcast_tab_my_shows')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('podcast_guest_login_card')),
            findsOneWidget,
          );
          expect(
            find.text('登入 YouTube Music 同步訂閱節目與最新單集'),
            findsOneWidget,
          );

          await tester.tap(find.byKey(const Key('btn_podcast_open_login')));
          await tester.pumpAndSettle();
          expect(loginOpened, isTrue);

          // Search for 'Acoustic' -> shows sampleShowB and sampleEp2 -> bookmark sampleShowB
          await tester.enterText(
            find.byKey(const Key('podcast_search_input')),
            'Acoustic',
          );
          await tester.testTextInput.receiveAction(TextInputAction.search);
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('podcast_show_card_MPSPPL_show_beta_02')),
            findsOneWidget,
          );
          await tester.tap(
            find.byKey(const Key('btn_bookmark_show_MPSPPL_show_beta_02')),
          );
          await tester.pumpAndSettle();
          expect(store.isBookmarked('MPSPPL_show_beta_02'), isTrue);

          // Clear search and verify bookmarked show appears in 我的節目
          await tester.tap(find.byKey(const Key('btn_podcast_search_clear')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('podcast_show_card_MPSPPL_show_beta_02')),
            findsOneWidget,
          );
        },
      );

      testWidgets(
        'authenticated mode defaults to 我的節目 and merges remote subscribed shows with local bookmarks without guest login card',
        (tester) async {
          tester.view.physicalSize = const Size(1400, 900);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          final svc = MockAudioService();
          addTearDown(svc.dispose);
          final store = PodcastStore();
          addTearDown(store.dispose);
          await store.addBookmark(sampleShowB);

          final sm = _FakePodcastStreamingManager(
            connected: true,
            myPodcastsResult: const PodcastLibraryResult(
              shows: <PodcastShow>[sampleShowA],
              episodes: <PodcastEpisode>[sampleEp1],
            ),
            exploreResult: const PodcastExploreResult(
              shows: <PodcastShow>[sampleShowA],
              episodes: <PodcastEpisode>[sampleEp1],
            ),
          );
          addTearDown(sm.dispose);

          await tester.pumpWidget(
            MaterialApp(
              theme: LuminaTokens.buildDarkTheme(),
              home: Scaffold(
                body: PodcastsView(
                  audioService: svc,
                  streamingManager: sm,
                  podcastStore: store,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('podcast_guest_login_card')),
            findsNothing,
          );
          expect(
            find.byKey(const Key('podcast_show_card_MPSPPL_show_alpha_01')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('podcast_show_card_MPSPPL_show_beta_02')),
            findsOneWidget,
          );
        },
      );
    },
  );

  group(
    '4. Navigation stack (HomeTab.podcasts -> HomeTab.podcastDetail -> < / > / Esc) & 播放最新一集 + 載入更多單集',
    () {
      testWidgets(
        'pushes PodcastDetailPage, plays latest episode, paginates continuation, and supports < / > / Esc history navigation',
        (tester) async {
          tester.view.physicalSize = const Size(1400, 900);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          final svc = MockAudioService();
          addTearDown(svc.dispose);
          final nav = NavHistoryController();
          addTearDown(nav.dispose);
          final store = PodcastStore();
          addTearDown(store.dispose);
          final win = DesktopWindowController(isSupportedOverride: false);

          final sm = _FakePodcastStreamingManager(
            exploreResult: const PodcastExploreResult(
              shows: <PodcastShow>[sampleShowA],
              episodes: <PodcastEpisode>[sampleEp1],
            ),
            showDetailsById: <String, PodcastShowDetail>{
              'MPSPPL_show_alpha_01': const PodcastShowDetail(
                show: sampleShowA,
                episodes: <PodcastEpisode>[sampleEp1, sampleEp2],
                continuationToken: 'TOKEN_MORE_EPS',
              ),
            },
            showContinuations: <String, PodcastShowDetail>{
              'TOKEN_MORE_EPS': const PodcastShowDetail(
                show: sampleShowA,
                episodes: <PodcastEpisode>[sampleEp3Page2],
              ),
            },
          );
          addTearDown(sm.dispose);

          final scaleCtrl = UiScaleController(
            initialHomeLayoutPreset: HomeLayoutPreset.classic,
          );
          addTearDown(scaleCtrl.dispose);

          await tester.pumpWidget(
            MaterialApp(
              theme: LuminaTokens.buildDarkTheme(),
              home: HomeScreen(
                audioService: svc,
                uiScaleController: scaleCtrl,
                streamingManager: sm,
                navHistoryController: nav,
                windowController: win,
                podcastStore: store,
              ),
            ),
          );
          await tester.pumpAndSettle();

          // Navigate to Podcasts tab
          await tester.tap(find.byKey(const Key('nav_tab_podcasts')));
          await tester.pumpAndSettle();
          expect(nav.current.tab, HomeTab.podcasts);

          // Tap show card -> pushes HomeTab.podcastDetail
          await tester.tap(
            find.byKey(const Key('podcast_show_card_MPSPPL_show_alpha_01')),
          );
          await tester.pumpAndSettle();
          expect(nav.current.tab, HomeTab.podcastDetail);
          expect(find.byType(PodcastDetailPage), findsOneWidget);
          expect(
            find.byKey(const Key('podcast_detail_title')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('podcast_episode_tile_aBcDeFgHiJk')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('podcast_episode_tile_lMnOpQrStUv')),
            findsOneWidget,
          );

          // Tap "播放最新一集"
          await tester.tap(find.byKey(const Key('btn_podcast_play_latest')));
          await tester.pumpAndSettle();
          expect(svc.currentState.status, PlaybackStatus.playing);
          expect(svc.currentState.track?.id, 'ytm:aBcDeFgHiJk');
          expect(svc.currentState.track?.providerName, 'Podcast');

          // Tap "載入更多單集" (continuation pagination)
          expect(
            find.byKey(const Key('btn_podcast_load_more_episodes')),
            findsOneWidget,
          );
          await tester.ensureVisible(
            find.byKey(const Key('btn_podcast_load_more_episodes')),
          );
          await tester.tap(
            find.byKey(const Key('btn_podcast_load_more_episodes')),
          );
          await tester.pumpAndSettle();
          expect(sm.fetchedContinuations, contains('TOKEN_MORE_EPS'));
          expect(
            find.byKey(const Key('podcast_episode_tile_wXyZ0123456')),
            findsOneWidget,
          );

          // Step back via '<' button -> HomeTab.podcasts
          await tester.tap(find.byKey(const Key('btn_nav_back')));
          await tester.pumpAndSettle();
          expect(nav.current.tab, HomeTab.podcasts);

          // Step forward via '>' button -> HomeTab.podcastDetail
          await tester.tap(find.byKey(const Key('btn_nav_forward')));
          await tester.pumpAndSettle();
          expect(nav.current.tab, HomeTab.podcastDetail);

          // Press Esc -> returns to HomeTab.podcasts
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(nav.current.tab, HomeTab.podcasts);
        },
      );
    },
  );

  group(
    '5. Episode listening progress persistence, auto-resume seek, and -15s / +30s seek clamping',
    () {
      test(
        'persists episode progress & bookmarks to JSON file, reloads cleanly, and marks completed near end',
        () async {
          final tempDir = await Directory.systemTemp.createTemp(
            'lumina_podcast_stage4_test_',
          );
          addTearDown(() async {
            if (tempDir.existsSync()) {
              await tempDir.delete(recursive: true);
            }
          });
          final stateFile = File(
            '${tempDir.path}${Platform.pathSeparator}podcast_state.json',
          );

          final store1 = PodcastStore(storageFile: stateFile);
          await store1.addBookmark(sampleShowA);
          store1.updateProgress(
            videoId: 'ytm:aBcDeFgHiJk',
            position: const Duration(minutes: 12, seconds: 34),
            duration: const Duration(minutes: 42, seconds: 15),
            immediate: true,
          );
          expect(stateFile.existsSync(), isTrue);

          final saved1 = store1.progressFor('aBcDeFgHiJk');
          expect(saved1, isNotNull);
          expect(saved1!.positionSeconds, 754);
          expect(saved1.formattedPosition, '12:34');
          expect(saved1.completed, isFalse);

          // Reload from disk in a brand-new PodcastStore instance
          final store2 = PodcastStore(storageFile: stateFile)..loadSync();
          expect(store2.isBookmarked('MPSPPL_show_alpha_01'), isTrue);
          final reloaded = store2.progressFor('ytm:aBcDeFgHiJk');
          expect(reloaded, isNotNull);
          expect(reloaded!.positionSeconds, 754);
          expect(reloaded.completed, isFalse);

          // Update position to within last 10 seconds -> auto-marks completed
          store2.updateProgress(
            videoId: 'aBcDeFgHiJk',
            position: const Duration(minutes: 42, seconds: 8),
            duration: const Duration(minutes: 42, seconds: 15),
            immediate: true,
          );
          expect(store2.progressFor('aBcDeFgHiJk')!.completed, isTrue);
          store1.dispose();
          store2.dispose();
        },
      );

      testWidgets(
        'auto-resumes saved episode progress on play (one-shot) and clamps -15s / +30s buttons in bottom bar and NowPlayingOverlay',
        (tester) async {
          tester.view.physicalSize = const Size(1400, 900);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);

          final svc = MockAudioService();
          addTearDown(svc.dispose);
          final store = PodcastStore();
          addTearDown(store.dispose);
          final win = DesktopWindowController(isSupportedOverride: false);

          // Pre-populate saved listening progress at 120 seconds (02:00) for sampleEp1 (duration 2535s).
          store.updateProgress(
            videoId: sampleEp1.videoId,
            position: const Duration(seconds: 120),
            duration: sampleEp1.duration,
            immediate: true,
          );

          final sm = _FakePodcastStreamingManager(
            exploreResult: const PodcastExploreResult(
              shows: <PodcastShow>[sampleShowA],
              episodes: <PodcastEpisode>[sampleEp1],
            ),
          );
          addTearDown(sm.dispose);

          final scaleCtrl = UiScaleController(
            initialHomeLayoutPreset: HomeLayoutPreset.classic,
          );
          addTearDown(scaleCtrl.dispose);

          await tester.pumpWidget(
            MaterialApp(
              theme: LuminaTokens.buildDarkTheme(),
              home: HomeScreen(
                audioService: svc,
                uiScaleController: scaleCtrl,
                streamingManager: sm,
                windowController: win,
                podcastStore: store,
              ),
            ),
          );
          await tester.pumpAndSettle();

          // Before playing a Podcast track, -15s / +30s buttons are hidden in bottom bar.
          expect(
            find.byKey(const Key('btn_podcast_skip_back_15s')),
            findsNothing,
          );
          expect(
            find.byKey(const Key('btn_podcast_skip_forward_30s')),
            findsNothing,
          );

          // Navigate to Podcasts -> episode row shows saved progress badge "已播 02:00"
          await tester.tap(find.byKey(const Key('nav_tab_podcasts')));
          await tester.pumpAndSettle();
          expect(find.text('已播 02:00'), findsOneWidget);

          // Play sampleEp1 -> auto-resumes to 120s!
          await tester.tap(
            find.byKey(const Key('btn_play_episode_aBcDeFgHiJk')),
          );
          await tester.pumpAndSettle();
          expect(svc.currentState.status, PlaybackStatus.playing);
          expect(svc.currentState.position, const Duration(seconds: 120));

          // Bottom bar now shows -15s and +30s buttons!
          expect(
            find.byKey(const Key('btn_podcast_skip_back_15s')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('btn_podcast_skip_forward_30s')),
            findsOneWidget,
          );

          // Active episode row also shows inline -15s and +30s buttons!
          expect(
            find.byKey(const Key('btn_episode_skip_back_aBcDeFgHiJk')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('btn_episode_skip_forward_aBcDeFgHiJk')),
            findsOneWidget,
          );

          // Tap +30s in bottom bar -> seeks from 120s to 150s
          await tester.tap(
            find.byKey(const Key('btn_podcast_skip_forward_30s')),
          );
          await tester.pumpAndSettle();
          expect(svc.currentState.position, const Duration(seconds: 150));

          // Tap -15s in bottom bar -> seeks from 150s to 135s
          await tester.tap(
            find.byKey(const Key('btn_podcast_skip_back_15s')),
          );
          await tester.pumpAndSettle();
          expect(svc.currentState.position, const Duration(seconds: 135));

          // Seek near start (5s) and tap -15s -> clamps to Duration.zero (0s)
          await svc.seek(const Duration(seconds: 5));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const Key('btn_podcast_skip_back_15s')),
          );
          await tester.pumpAndSettle();
          expect(svc.currentState.position, Duration.zero);

          // Expand NowPlayingOverlay and verify -15s / +30s buttons & upper-bound clamping
          await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('btn_now_playing_skip_back_15s')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('btn_now_playing_skip_forward_30s')),
            findsOneWidget,
          );

          // Seek to 10s before end and tap +30s in NowPlayingOverlay -> clamps to track.duration
          final almostEnd = sampleEp1.duration - const Duration(seconds: 10);
          await svc.seek(almostEnd);
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const Key('btn_now_playing_skip_forward_30s')),
          );
          await tester.pumpAndSettle();
          expect(svc.currentState.position, sampleEp1.duration);
        },
      );
    },
  );
}
