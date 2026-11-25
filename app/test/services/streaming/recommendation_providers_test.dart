import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/recommendation_models.dart';
import 'package:lumina_app/models/stream_source_spec.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/services/streaming/cross_platform_track_router.dart';
import 'package:lumina_app/services/streaming/external_recommendation_providers.dart';
import 'package:lumina_app/services/streaming/providers/apple_music_provider.dart';
import 'package:lumina_app/services/streaming/providers/deezer_provider.dart';
import 'package:lumina_app/services/streaming/providers/qobuz_provider.dart';
import 'package:lumina_app/services/streaming/providers/tidal_provider.dart';
import 'package:lumina_app/services/streaming/providers/youtube_music_provider.dart';
import 'package:lumina_app/services/streaming/recommendation_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_provider.dart';

class _RecordedHttpRequest {
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String body;

  const _RecordedHttpRequest({
    required this.method,
    required this.uri,
    required this.headers,
    required this.body,
  });
}

class _MockHttpResult {
  final int statusCode;
  final String body;
  final Map<String, String> headers = const <String, String>{
    'content-type': 'application/json',
  };

  const _MockHttpResult({
    this.statusCode = 200,
    required this.body,
  });

  factory _MockHttpResult.json(
    Object payload, {
    int statusCode = 200,
  }) {
    return _MockHttpResult(
      statusCode: statusCode,
      body: jsonEncode(payload),
    );
  }
}

typedef _MockHttpHandler = FutureOr<_MockHttpResult> Function(
  _RecordedHttpRequest req,
);

class _MockHttpHeaders implements HttpHeaders {
  final Map<String, List<String>> _values = <String, List<String>>{};

  _MockHttpHeaders([Map<String, String> initial = const {}]) {
    initial.forEach((k, v) => set(k, v));
  }

  Map<String, String> toSingleValueMap() {
    return <String, String>{
      for (final e in _values.entries) e.key: e.value.join(', '),
    };
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = <String>[value.toString()];
  }

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _values
        .putIfAbsent(name.toLowerCase(), () => <String>[])
        .add(value.toString());
  }

  @override
  String? value(String name) {
    final list = _values[name.toLowerCase()];
    if (list == null || list.isEmpty) return null;
    return list.first;
  }

  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _values.forEach(action);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  @override
  final int statusCode;
  @override
  final HttpHeaders headers;
  final List<int> _bytes;

  _MockHttpClientResponse({
    required this.statusCode,
    required String body,
    required this.headers,
  }) : _bytes = utf8.encode(body);

  @override
  int get contentLength => _bytes.length;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable(<List<int>>[_bytes]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpClientRequest implements HttpClientRequest {
  @override
  final String method;
  @override
  final Uri uri;
  final _MockHttpHeaders _headers = _MockHttpHeaders();
  final _MockHttpHandler _handler;
  final List<int> _bodyBytes = <int>[];

  @override
  int contentLength = -1;

  _MockHttpClientRequest(this.method, this.uri, this._handler);

  @override
  HttpHeaders get headers => _headers;

  @override
  void add(List<int> data) {
    _bodyBytes.addAll(data);
  }

  @override
  Future<HttpClientResponse> close() async {
    final recorded = _RecordedHttpRequest(
      method: method,
      uri: uri,
      headers: _headers.toSingleValueMap(),
      body: utf8.decode(_bodyBytes),
    );
    final res = await _handler(recorded);
    return _MockHttpClientResponse(
      statusCode: res.statusCode,
      body: res.body,
      headers: _MockHttpHeaders(res.headers),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockHttpClient implements HttpClient {
  final _MockHttpHandler handler;
  final List<_RecordedHttpRequest> requests = <_RecordedHttpRequest>[];

  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  int? maxConnectionsPerHost;
  @override
  Duration? connectionTimeout;

  _MockHttpClient(this.handler);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    return _MockHttpClientRequest(method, url, (req) async {
      requests.add(req);
      return handler(req);
    });
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemoryCredentialStore implements SecureCredentialStore {
  final Map<String, String> _data = <String, String>{};

  @override
  Future<void> clearAll() async => _data.clear();

  @override
  Future<void> delete(String key) async => _data.remove(key);

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('YouTubeMusicProvider RecommendationProvider', () {
    test(
      'Guest getTrackRadio uses RDAMVM + continuation pagination without auth',
      () async {
        final requests = <_RecordedHttpRequest>[];
        final provider = YouTubeMusicProvider(
          credentialStore: _MemoryCredentialStore(),
          httpClientFactory: () => _MockHttpClient((req) {
            requests.add(req);
            final body = jsonDecode(req.body) as Map<String, dynamic>;
            if (req.uri.path == '/youtubei/v1/next') {
              final cont = body['continuation']?.toString();
              if (cont == 'cont_page_2') {
                return _MockHttpResult.json({
                  'contents': {
                    'singleColumnMusicWatchNextResultsRenderer': {
                      'tabbedRenderer': {
                        'watchNextTabbedResultsRenderer': {
                          'tabs': [
                            {
                              'tabRenderer': {
                                'content': {
                                  'musicQueueRenderer': {
                                    'content': {
                                      'playlistPanelRenderer': {
                                        'contents': [
                                          {
                                            'playlistPanelVideoRenderer': {
                                              'videoId': 'vidPage2_01',
                                              'title': {
                                                'simpleText': 'YTM Radio Page 2',
                                              },
                                              'longBylineText': {
                                                'simpleText': 'Page Two Artist',
                                              },
                                              'lengthText': {
                                                'simpleText': '4:10',
                                              },
                                            },
                                          },
                                        ],
                                      },
                                    },
                                  },
                                },
                              },
                            },
                          ],
                        },
                      },
                    },
                  },
                });
              }
              return _MockHttpResult.json({
                'contents': {
                  'singleColumnMusicWatchNextResultsRenderer': {
                    'tabbedRenderer': {
                      'watchNextTabbedResultsRenderer': {
                        'tabs': [
                          {
                            'tabRenderer': {
                              'content': {
                                'musicQueueRenderer': {
                                  'content': {
                                    'playlistPanelRenderer': {
                                      'continuations': [
                                        {
                                          'nextContinuationData': {
                                            'continuation': 'cont_page_2',
                                          },
                                        },
                                      ],
                                      'contents': [
                                        {
                                          'playlistPanelVideoRenderer': {
                                            'videoId': 'dQw4w9WgXcQ',
                                            'title': {'simpleText': 'Seed Song'},
                                            'longBylineText': {
                                              'simpleText': 'Seed Artist',
                                            },
                                          },
                                        },
                                        {
                                          'playlistPanelVideoRenderer': {
                                            'videoId': 'abc12345678',
                                            'title': {
                                              'simpleText': 'Radio Track 1',
                                            },
                                            'longBylineText': {
                                              'simpleText': 'Artist One • Album',
                                            },
                                            'lengthText': {'simpleText': '3:20'},
                                          },
                                        },
                                      ],
                                    },
                                  },
                                },
                              },
                            },
                          },
                        ],
                      },
                    },
                  },
                },
              });
            }
            return _MockHttpResult.json({});
          }),
        );
        addTearDown(provider.dispose);

        expect(provider, isA<RecommendationProvider>());
        expect(provider.authState, equals(StreamingAuthState.disconnected));
        expect(provider.recommendationProviderId, equals('youtube_music'));
        expect(provider.capabilities, equals(ProviderCapabilities.youtubeMusic));

        const seed = TrackMetadata(
          providerId: 'youtube_music',
          trackId: 'ytm:dQw4w9WgXcQ',
          title: 'Seed Song',
          artist: 'Seed Artist',
        );

        final page1 = await provider.getTrackRadio(seed, limit: 10);
        expect(page1.tracks, hasLength(1));
        expect(page1.tracks.first.trackId, equals('abc12345678'));
        expect(page1.tracks.first.providerId, equals('youtube_music'));
        expect(page1.tracks.first.durationMs, equals(200000));
        expect(page1.nextCursor, equals('cont_page_2'));

        final firstBody = jsonDecode(requests.first.body) as Map<String, dynamic>;
        expect(firstBody['playlistId'], equals('RDAMVMdQw4w9WgXcQ'));
        expect(firstBody['videoId'], equals('dQw4w9WgXcQ'));
        expect(firstBody['isAudioOnly'], isTrue);
        expect(requests.first.headers.containsKey('cookie'), isFalse);
        expect(requests.first.headers.containsKey('authorization'), isFalse);

        final page2 = await provider.getTrackRadio(
          seed,
          limit: 10,
          cursor: page1.nextCursor,
        );
        expect(page2.tracks, hasLength(1));
        expect(page2.tracks.first.trackId, equals('vidPage2_01'));
        expect(page2.nextCursor, isNull);

        final secondReq = requests[1];
        expect(secondReq.uri.queryParameters['ctoken'], equals('cont_page_2'));
        expect(
          secondReq.uri.queryParameters['continuation'],
          equals('cont_page_2'),
        );
        final secondBody = jsonDecode(secondReq.body) as Map<String, dynamic>;
        expect(secondBody['continuation'], equals('cont_page_2'));
      },
    );

    test(
      'Cross-platform seed falls back to Guest search and matchTrack works in Guest mode',
      () async {
        final requests = <_RecordedHttpRequest>[];
        final provider = YouTubeMusicProvider(
          credentialStore: _MemoryCredentialStore(),
          httpClientFactory: () => _MockHttpClient((req) {
            requests.add(req);
            if (req.uri.path == '/youtubei/v1/search') {
              return _MockHttpResult.json({
                'contents': {
                  'tabbedSearchResultsRenderer': {
                    'tabs': [
                      {
                        'tabRenderer': {
                          'content': {
                            'sectionListRenderer': {
                              'contents': [
                                {
                                  'musicShelfRenderer': {
                                    'contents': [
                                      {
                                        'musicResponsiveListItemRenderer': {
                                          'playlistItemData': {
                                            'videoId': 'searchSeed1',
                                          },
                                          'flexColumns': [
                                            {
                                              'musicResponsiveListItemFlexColumnRenderer': {
                                                'text': {
                                                  'simpleText': 'Midnight City',
                                                },
                                              },
                                            },
                                            {
                                              'musicResponsiveListItemFlexColumnRenderer': {
                                                'text': {
                                                  'runs': [
                                                    {'text': 'M83'},
                                                    {'text': ' • '},
                                                    {'text': 'Hurry Up'},
                                                    {'text': ' • '},
                                                    {'text': '4:03'},
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
                              ],
                            },
                          },
                        },
                      },
                    ],
                  },
                },
              });
            }
            if (req.uri.path == '/youtubei/v1/next') {
              return _MockHttpResult.json({
                'contents': {
                  'playlistPanelRenderer': {
                    'contents': [
                      {
                        'playlistPanelVideoRenderer': {
                          'videoId': 'nextTrack11',
                          'title': {'simpleText': 'Wait'},
                          'longBylineText': {'simpleText': 'M83'},
                        },
                      },
                    ],
                  },
                },
              });
            }
            return _MockHttpResult.json({});
          }),
        );
        addTearDown(provider.dispose);

        final matched = await provider.matchTrack(
          const TrackMatchQuery(
            title: 'Midnight City',
            artist: 'M83',
            durationMs: 243000,
          ),
        );
        expect(matched, isNotNull);
        expect(matched!.trackId, equals('searchSeed1'));

        final radio = await provider.getTrackRadio(
          const TrackMetadata(
            providerId: 'local',
            trackId: 'local_track_1',
            title: 'Midnight City',
            artist: 'M83',
            durationMs: 243000,
          ),
        );
        expect(radio.tracks, hasLength(1));
        expect(radio.tracks.first.trackId, equals('nextTrack11'));
        expect(
          requests.where((r) => r.uri.path == '/youtubei/v1/next'),
          hasLength(1),
        );
      },
    );

    test(
      'getPersonalizedFeed is strictly gated on connected auth',
      () async {
        var browseCount = 0;
        final provider = YouTubeMusicProvider(
          credentialStore: _MemoryCredentialStore(),
          httpClientFactory: () => _MockHttpClient((req) {
            if (req.uri.path == '/youtubei/v1/account/account_menu') {
              return _MockHttpResult.json({
                'header': {
                  'activeAccountHeaderRenderer': {
                    'accountName': {'simpleText': 'YTM User'},
                  },
                },
              });
            }
            if (req.uri.path == '/youtubei/v1/browse') {
              browseCount++;
              return _MockHttpResult.json({
                'contents': {
                  'musicCarouselShelfRenderer': {
                    'header': {
                      'musicCarouselShelfBasicHeaderRenderer': {
                        'title': {'simpleText': 'Quick picks'},
                      },
                    },
                    'contents': [
                      {
                        'musicResponsiveListItemRenderer': {
                          'playlistItemData': {'videoId': 'homeVid1111'},
                          'flexColumns': [
                            {
                              'musicResponsiveListItemFlexColumnRenderer': {
                                'text': {'simpleText': 'Home Pick'},
                              },
                            },
                            {
                              'musicResponsiveListItemFlexColumnRenderer': {
                                'text': {'simpleText': 'Home Artist'},
                              },
                            },
                          ],
                        },
                      },
                    ],
                  },
                },
              });
            }
            return _MockHttpResult.json({});
          }),
        );
        addTearDown(provider.dispose);

        // Disconnected -> returns [] with zero HTTP calls.
        final guestFeed = await provider.getPersonalizedFeed();
        expect(guestFeed, isEmpty);
        expect(browseCount, equals(0));

        // Connected -> fetches FEmusic_home shelves.
        await provider.authenticate(<String, dynamic>{
          'mode': 'cookie',
          'cookie': 'SAPISID=abc_sapisid; SID=xyz',
        });
        final authFeed = await provider.getPersonalizedFeed();
        expect(browseCount, equals(1));
        expect(authFeed, hasLength(1));
        expect(authFeed.first.title, equals('Quick picks'));
        expect(authFeed.first.tracks.first.trackId, equals('homeVid1111'));
      },
    );
  });

  group('TidalProvider RecommendationProvider', () {
    test(
      'preserves ISRC & HI_RES quality, supports /tracks/{id}/radio, ISRC-first matchTrack, and throws RecError.authRequired on 401 without retry',
      () async {
        var radioCalls = 0;
        var return401OnRadio = false;
        final provider = TidalProvider(
          credentialStore: _MemoryCredentialStore(),
          httpClientFactory: () => _MockHttpClient((req) {
            if (req.uri.path == '/v1/sessions') {
              return _MockHttpResult.json({
                'userId': 123,
                'countryCode': 'US',
              });
            }
            if (req.uri.path == '/v1/users/123') {
              return _MockHttpResult.json({
                'id': 123,
                'username': 'tidal_user',
                'countryCode': 'US',
              });
            }
            if (req.uri.path == '/v1/users/123/subscription') {
              return _MockHttpResult.json({
                'subscription': {'type': 'HIFI_PLUS'},
                'highestSoundQuality': 'HI_RES_LOSSLESS',
              });
            }
            if (req.uri.path == '/v1/tracks/100/radio') {
              radioCalls++;
              if (return401OnRadio) {
                return _MockHttpResult.json(
                  {'userMessage': 'Token expired'},
                  statusCode: 401,
                );
              }
              return _MockHttpResult.json({
                'items': [
                  {
                    'id': 201,
                    'title': 'HiRes Radio Track',
                    'duration': 210,
                    'isrc': 'USRC17607839',
                    'audioQuality': 'HI_RES_LOSSLESS',
                    'artist': {'id': 55, 'name': 'Tidal Artist'},
                    'album': {'id': 99, 'title': 'Tidal Album'},
                  },
                ],
              });
            }
            if (req.uri.path == '/v1/search/tracks') {
              return _MockHttpResult.json({
                'items': [
                  {
                    'id': 301,
                    'title': 'Target Song',
                    'duration': 200,
                    'isrc': 'GBDUW0000059',
                    'audioQuality': 'LOSSLESS',
                    'artist': {'id': 10, 'name': 'Daft Punk'},
                    'album': {'id': 11, 'title': 'Discovery'},
                  },
                  {
                    'id': 302,
                    'title': 'Target Song',
                    'duration': 200,
                    'isrc': 'GBDUW0000059',
                    'audioQuality': 'HI_RES_LOSSLESS',
                    'artist': {'id': 10, 'name': 'Daft Punk'},
                    'album': {'id': 12, 'title': 'Discovery (Hi-Res)'},
                  },
                ],
              });
            }
            if (req.uri.path == '/v2/home/feed/static') {
              return _MockHttpResult.json({
                'items': [
                  {
                    'title': 'Tidal Masters',
                    'items': [
                      {
                        'id': 401,
                        'title': 'Feed Master Track',
                        'duration': 180,
                        'audioQuality': 'HI_RES',
                        'artist': {'id': 12, 'name': 'Feed Artist'},
                        'album': {'id': 22, 'title': 'Feed Album'},
                      },
                    ],
                  },
                ],
              });
            }
            return _MockHttpResult.json({});
          }),
        );

        // Disconnected -> immediate RecError.authRequired
        await expectLater(
          provider.getTrackRadio(
            const TrackMetadata(
              providerId: 'tidal',
              trackId: '100',
              title: 'Seed',
              artist: 'Artist',
            ),
          ),
          throwsA(
            isA<RecError>().having(
              (e) => e.kind,
              'kind',
              RecErrorKind.authRequired,
            ),
          ),
        );

        await provider.authenticate(<String, dynamic>{
          'mode': 'access_token',
          'access_token': 'tidal_tok',
        });

        final radio = await provider.getTrackRadio(
          const TrackMetadata(
            providerId: 'tidal',
            trackId: '100',
            title: 'Seed',
            artist: 'Artist',
          ),
          limit: 1,
        );
        expect(radio.tracks, hasLength(1));
        expect(radio.tracks.first.isrc, equals('USRC17607839'));
        expect(radio.tracks.first.qualityLabel, equals('HI_RES_LOSSLESS'));
        expect(radio.tracks.first.artistId, equals('55'));
        expect(radio.nextCursor, equals('1'));

        // ISRC-first match prefers HI_RES_LOSSLESS over LOSSLESS
        final match = await provider.matchTrack(
          const TrackMatchQuery(
            isrc: 'gb-duw-0000059',
            title: 'Target Song',
            artist: 'Daft Punk',
          ),
        );
        expect(match, isNotNull);
        expect(match!.trackId, equals('302'));
        expect(match.qualityLabel, equals('HI_RES_LOSSLESS'));

        final feed = await provider.getPersonalizedFeed();
        expect(feed, isNotEmpty);
        expect(feed.first.title, equals('Tidal Masters'));
        expect(feed.first.tracks.first.qualityLabel, equals('HI_RES'));

        // 401 -> immediate RecError.authRequired with ZERO retry
        return401OnRadio = true;
        final prevCalls = radioCalls;
        await expectLater(
          provider.getTrackRadio(
            const TrackMetadata(
              providerId: 'tidal',
              trackId: '100',
              title: 'Seed',
              artist: 'Artist',
            ),
          ),
          throwsA(
            isA<RecError>()
                .having((e) => e.kind, 'kind', RecErrorKind.authRequired)
                .having((e) => e.statusCode, 'statusCode', 401),
          ),
        );
        expect(radioCalls, equals(prevCalls + 1));
      },
    );
  });

  group('DeezerProvider RecommendationProvider', () {
    test(
      'public getTrackRadio (/artist/{id}/radio + /related + /top) and /track/isrc matchTrack work without login',
      () async {
        final provider = DeezerProvider(
          credentialStore: _MemoryCredentialStore(),
          httpClientFactory: () => _MockHttpClient((req) {
            if (req.uri.path == '/track/777') {
              return _MockHttpResult.json({
                'id': 777,
                'title': 'Seed Track',
                'artist': {'id': 42, 'name': 'Justice'},
              });
            }
            if (req.uri.path == '/artist/42/radio') {
              return _MockHttpResult.json({
                'data': [
                  {
                    'id': 801,
                    'title': 'Radio Song A',
                    'duration': 200,
                    'isrc': 'FR001',
                    'artist': {'id': 42, 'name': 'Justice'},
                    'album': {'id': 1, 'title': 'Cross'},
                  },
                  {
                    'id': 802,
                    'title': 'Radio Song B',
                    'duration': 210,
                    'artist': {'id': 43, 'name': 'SebastiAn'},
                    'album': {'id': 2, 'title': 'Total'},
                  },
                ],
              });
            }
            if (req.uri.path == '/artist/42/related') {
              return _MockHttpResult.json({
                'data': [
                  {'id': 43, 'name': 'SebastiAn'},
                ],
              });
            }
            if (req.uri.path == '/artist/43/top') {
              return _MockHttpResult.json({
                'data': [
                  {
                    'id': 901,
                    'title': 'Related Top Track',
                    'duration': 190,
                    'isrc': 'FR002',
                    'artist': {'id': 43, 'name': 'SebastiAn'},
                    'album': {'id': 2, 'title': 'Total'},
                  },
                ],
              });
            }
            if (req.uri.path == '/track/isrc:GBDUW0000059') {
              return _MockHttpResult.json({
                'id': 5001,
                'title': 'Digital Love',
                'duration': 301,
                'isrc': 'GBDUW0000059',
                'artist': {'id': 27, 'name': 'Daft Punk'},
                'album': {'id': 10, 'title': 'Discovery'},
              });
            }
            return _MockHttpResult.json({});
          }),
        );

        expect(provider.authState, equals(StreamingAuthState.disconnected));

        final radio = await provider.getTrackRadio(
          const TrackMetadata(
            providerId: 'deezer',
            trackId: '777',
            title: 'Seed Track',
            artist: 'Justice',
          ),
          limit: 2,
        );
        expect(radio.tracks, hasLength(2));
        expect(radio.tracks[0].trackId, equals('801'));
        expect(radio.tracks[0].isrc, equals('FR001'));
        expect(radio.tracks[0].artistId, equals('42'));
        expect(radio.tracks[1].trackId, equals('901'));
        expect(radio.nextCursor, equals('2'));

        final page2 = await provider.getTrackRadio(
          const TrackMetadata(
            providerId: 'deezer',
            trackId: '777',
            title: 'Seed Track',
            artist: 'Justice',
          ),
          limit: 2,
          cursor: radio.nextCursor,
        );
        expect(page2.tracks, hasLength(1));
        expect(page2.tracks.first.trackId, equals('802'));
        expect(page2.nextCursor, isNull);

        final matched = await provider.matchTrack(
          const TrackMatchQuery(
            isrc: 'GBDUW0000059',
            title: 'Digital Love',
            artist: 'Daft Punk',
          ),
        );
        expect(matched, isNotNull);
        expect(matched!.trackId, equals('5001'));
        expect(matched.isrc, equals('GBDUW0000059'));
        expect(matched.artistId, equals('27'));
        expect(await provider.getPersonalizedFeed(), isEmpty);
      },
    );

    test(
      'connected DeezerProvider returns personalized tracks & albums FeedSections',
      () async {
        final provider = DeezerProvider(
          credentialStore: _MemoryCredentialStore(),
          httpClientFactory: () => _MockHttpClient((req) {
            if (req.uri.path == '/ajax/gw-light.php') {
              return _MockHttpResult.json({
                'error': <String, dynamic>{},
                'results': {
                  'checkForm': 'csrf',
                  'USER': {'USER_ID': 555, 'BLOG_NAME': 'DZ User'},
                },
              });
            }
            if (req.uri.path == '/user/me/recommendations/tracks') {
              return _MockHttpResult.json({
                'data': [
                  {
                    'id': 8801,
                    'title': 'Personal Track',
                    'duration': 200,
                    'isrc': 'FR8801',
                    'artist': {'id': 90, 'name': 'Phoenix'},
                    'album': {'id': 1, 'title': 'Wolfgang'},
                  },
                ],
              });
            }
            if (req.uri.path == '/user/me/recommendations/albums') {
              return _MockHttpResult.json({
                'data': [
                  {
                    'id': 8901,
                    'title': 'Personal Album',
                    'artist': {'id': 90, 'name': 'Phoenix'},
                  },
                ],
              });
            }
            return _MockHttpResult.json({});
          }),
        );

        await provider.authenticate(<String, dynamic>{
          'mode': 'arl',
          'arl': 'test_arl',
        });
        final feed = await provider.getPersonalizedFeed();
        expect(feed, hasLength(2));
        expect(feed[0].tracks.first.isrc, equals('FR8801'));
        expect(feed[1].albums.first.title, equals('Personal Album'));
      },
    );
  });

  group('QobuzProvider RecommendationProvider', () {
    test(
      '401 throws RecError.authRequired with zero retries; ISRC/search and HI_RES qualityLabel work when connected',
      () async {
        var searchCalls = 0;
        var force401 = false;
        final provider = QobuzProvider(
          credentialStore: _MemoryCredentialStore(),
          httpClientFactory: () => _MockHttpClient((req) {
            if (req.uri.path == '/api.json/0.2/user/get') {
              return _MockHttpResult.json({
                'user': {
                  'id': 77,
                  'display_name': 'Qobuz HiRes',
                },
              });
            }
            if (req.uri.path == '/api.json/0.2/catalog/search') {
              searchCalls++;
              if (force401) {
                return _MockHttpResult.json(
                  {'message': 'Unauthorized'},
                  statusCode: 401,
                );
              }
              return _MockHttpResult.json({
                'tracks': {
                  'items': [
                    {
                      'id': 610,
                      'title': 'So What',
                      'duration': 562,
                      'isrc': 'USSM15900112',
                      'maximum_bit_depth': 24,
                      'maximum_sampling_rate': 192,
                      'performer': {'id': 88, 'name': 'Miles Davis'},
                      'album': {'title': 'Kind of Blue'},
                    },
                  ],
                },
              });
            }
            if (req.uri.path == '/api.json/0.2/album/getFeatured') {
              return _MockHttpResult.json({
                'albums': {
                  'items': [
                    {
                      'id': 'alb1',
                      'title': 'Blue Note Master',
                      'artist': {'name': 'Miles Davis'},
                      'maximum_bit_depth': 24,
                      'maximum_sampling_rate': 96,
                    },
                  ],
                },
              });
            }
            if (req.uri.path == '/api.json/0.2/favorite/getUserFavorites') {
              return _MockHttpResult.json({
                'tracks': {
                  'items': [
                    {
                      'id': 611,
                      'title': 'Blue in Green',
                      'duration': 327,
                      'maximum_bit_depth': 16,
                      'maximum_sampling_rate': 44.1,
                      'performer': {'name': 'Miles Davis'},
                      'album': {'title': 'Kind of Blue'},
                    },
                  ],
                },
              });
            }
            return _MockHttpResult.json({});
          }),
        );

        await expectLater(
          provider.getTrackRadio(
            const TrackMetadata(
              providerId: 'qobuz',
              trackId: '610',
              title: 'So What',
              artist: 'Miles Davis',
            ),
          ),
          throwsA(
            isA<RecError>().having(
              (e) => e.kind,
              'kind',
              RecErrorKind.authRequired,
            ),
          ),
        );
        expect(searchCalls, equals(0));

        await provider.authenticate(<String, dynamic>{
          'mode': 'token',
          'app_id': 'app_1',
          'user_auth_token': 'tok_1',
        });

        final matched = await provider.matchTrack(
          const TrackMatchQuery(
            isrc: 'USSM15900112',
            title: 'So What',
            artist: 'Miles Davis',
          ),
        );
        expect(matched, isNotNull);
        expect(matched!.qualityLabel, equals('HI_RES'));
        expect(matched.isrc, equals('USSM15900112'));

        final feed = await provider.getPersonalizedFeed();
        expect(feed, hasLength(2));
        expect(feed[1].tracks.first.qualityLabel, equals('LOSSLESS'));

        force401 = true;
        final before = searchCalls;
        await expectLater(
          provider.getTrackRadio(
            const TrackMetadata(
              providerId: 'qobuz',
              trackId: '999',
              title: 'So What',
              artist: 'Miles Davis',
            ),
          ),
          throwsA(
            isA<RecError>()
                .having((e) => e.kind, 'kind', RecErrorKind.authRequired)
                .having((e) => e.statusCode, 'statusCode', 401),
          ),
        );
        expect(searchCalls, equals(before + 1));

        // 403/404 restriction on Qobuz returns empty RadioPage cleanly
        final restrictedProvider = QobuzProvider(
          credentialStore: _MemoryCredentialStore(),
          httpClientFactory: () => _MockHttpClient((req) {
            if (req.uri.path == '/api.json/0.2/user/get') {
              return _MockHttpResult.json({
                'user': {'id': 77, 'display_name': 'Qobuz User'},
              });
            }
            return _MockHttpResult.json(
              {'message': 'Forbidden'},
              statusCode: 403,
            );
          }),
        );
        await restrictedProvider.authenticate(<String, dynamic>{
          'mode': 'token',
          'app_id': 'app_1',
          'user_auth_token': 'tok_1',
        });
        final restrictedRadio = await restrictedProvider.getTrackRadio(
          const TrackMetadata(
            providerId: 'qobuz',
            trackId: '999',
            title: 'So What',
            artist: 'Miles Davis',
          ),
        );
        expect(restrictedRadio.tracks, isEmpty);
      },
    );
  });

  group('AppleMusicProvider RecommendationProvider', () {
    test(
      'enforces connected auth gating and supports ISRC & search when connected',
      () async {
        var httpCalls = 0;
        final provider = AppleMusicProvider(
          credentialStore: _MemoryCredentialStore(),
          httpClientFactory: () => _MockHttpClient((req) {
            httpCalls++;
            if (req.uri.path == '/v1/me/storefront') {
              return _MockHttpResult.json({
                'data': [
                  {
                    'id': 'us',
                    'attributes': {'name': 'United States'},
                  },
                ],
              });
            }
            if (req.uri.path == '/v1/me/recommendations') {
              return _MockHttpResult.json({
                'data': [
                  {
                    'id': 'group1',
                    'attributes': {
                      'title': {'stringForDisplay': 'Made for You'},
                    },
                    'relationships': {
                      'contents': {
                        'data': [
                          {
                            'id': '7001',
                            'type': 'songs',
                            'attributes': {
                              'name': 'Apple Pick',
                              'artistName': 'Apple Artist',
                              'albumName': 'Apple Album',
                              'durationInMillis': 205000,
                              'isrc': 'USAM12345678',
                            },
                          },
                        ],
                      },
                    },
                  },
                ],
              });
            }
            if (req.uri.path == '/v1/catalog/us/songs') {
              return _MockHttpResult.json({
                'data': [
                  {
                    'id': '7002',
                    'type': 'songs',
                    'attributes': {
                      'name': 'Matched Apple Song',
                      'artistName': 'Matched Artist',
                      'albumName': 'Matched Album',
                      'durationInMillis': 215000,
                      'isrc': 'USAM99999999',
                    },
                  },
                ],
              });
            }
            return _MockHttpResult.json({});
          }),
        );

        expect(await provider.getPersonalizedFeed(), isEmpty);
        expect(httpCalls, equals(0));
        await expectLater(
          provider.matchTrack(
            const TrackMatchQuery(
              isrc: 'USAM99999999',
              title: 'Matched Apple Song',
              artist: 'Matched Artist',
            ),
          ),
          throwsA(
            isA<RecError>().having(
              (e) => e.kind,
              'kind',
              RecErrorKind.authRequired,
            ),
          ),
        );
        await expectLater(
          provider.getTrackRadio(
            const TrackMetadata(
              providerId: 'apple_music',
              trackId: '7001',
              title: 'Apple Pick',
              artist: 'Apple Artist',
            ),
          ),
          throwsA(
            isA<RecError>().having(
              (e) => e.kind,
              'kind',
              RecErrorKind.authRequired,
            ),
          ),
        );

        await provider.authenticate(<String, dynamic>{
          'mode': 'musickit_tokens',
          'developer_token': 'dev_jwt',
          'music_user_token': 'user_tok',
        });

        final feed = await provider.getPersonalizedFeed();
        expect(feed, hasLength(1));
        expect(feed.first.title, equals('Made for You'));
        expect(feed.first.tracks.first.isrc, equals('USAM12345678'));

        final matched = await provider.matchTrack(
          const TrackMatchQuery(
            isrc: 'USAM99999999',
            title: 'Matched Apple Song',
            artist: 'Matched Artist',
          ),
        );
        expect(matched, isNotNull);
        expect(matched!.trackId, equals('7002'));
        expect(matched.isrc, equals('USAM99999999'));
      },
    );
  });

  group('External Recommendation Providers & LocalLibraryTrackMatcher', () {
    test(
      'LastFmRecommendationProvider handles empty key and combines track.getSimilar + artist.getSimilar/getTopTracks',
      () async {
        var apiKey = '';
        final provider = LastFmRecommendationProvider(
          apiKeyProvider: () => apiKey,
          httpClientFactory: () => _MockHttpClient((req) {
            final method = req.uri.queryParameters['method'];
            if (method == 'track.getSimilar') {
              return _MockHttpResult.json({
                'similartracks': {
                  'track': [
                    {
                      'name': 'Similar One',
                      'duration': 210,
                      'mbid': 'mbid-1',
                      'artist': {'name': 'Similar Artist 1'},
                    },
                  ],
                },
              });
            }
            if (method == 'artist.getSimilar') {
              return _MockHttpResult.json({
                'similarartists': {
                  'artist': [
                    {'name': 'Related Artist 2'},
                  ],
                },
              });
            }
            if (method == 'artist.getTopTracks') {
              return _MockHttpResult.json({
                'toptracks': {
                  'track': [
                    {
                      'name': 'Top Track Two',
                      'duration': '245',
                      'mbid': 'mbid-2',
                      'artist': {'name': 'Related Artist 2'},
                    },
                  ],
                },
              });
            }
            return _MockHttpResult.json({});
          }),
        );

        const seed = TrackMetadata(
          providerId: 'local',
          trackId: 'loc-1',
          title: 'Seed Track',
          artist: 'Seed Artist',
        );

        final emptyPage = await provider.getTrackRadio(seed, limit: 5);
        expect(emptyPage.tracks, isEmpty);

        apiKey = 'lfm_test_key';
        final page = await provider.getTrackRadio(seed, limit: 5);
        expect(page.tracks, hasLength(2));
        expect(page.tracks[0].providerId, equals('lastfm'));
        expect(page.tracks[0].durationMs, equals(210000));
        expect(page.tracks[1].title, equals('Top Track Two'));
        expect(page.tracks[1].durationMs, equals(245000));
      },
    );

    test(
      'ListenBrainzRecommendationProvider supports keyless Labs + lb-radio and degrades cleanly on 404/429',
      () async {
        var enabled = true;
        var return429 = false;
        final provider = ListenBrainzRecommendationProvider(
          enabledProvider: () => enabled,
          httpClientFactory: () => _MockHttpClient((req) {
            if (return429) {
              return _MockHttpResult.json(
                {'error': 'rate limited'},
                statusCode: 429,
              );
            }
            if (req.uri.path == '/ws/2/recording') {
              return _MockHttpResult.json({
                'recordings': [
                  {
                    'id': 'rec-mbid-1',
                    'artist-credit': [
                      {
                        'artist': {'id': 'art-mbid-1', 'name': 'Seed Artist'},
                      },
                    ],
                  },
                ],
              });
            }
            if (req.uri.path == '/similar-recordings/json') {
              // Real ListenBrainz Labs returns a top-level JSON array!
              return _MockHttpResult.json([
                {
                  'recording_mbid': 'lb-rec-1',
                  'recording_name': 'Labs Similar Track',
                  'artist_credit_name': 'Labs Artist',
                  'release_name': 'Labs Album',
                },
              ]);
            }
            if (req.uri.path == '/1/explore/lb-radio') {
              return _MockHttpResult.json({
                'payload': {
                  'jspf': {
                    'playlist': {
                      'track': [
                        {
                          'title': 'LB Radio Track',
                          'creator': 'LB Radio Artist',
                          'album': 'LB Album',
                          'duration': 195000,
                          'identifier': [
                            'https://musicbrainz.org/recording/lb-rec-2',
                          ],
                        },
                      ],
                    },
                  },
                },
              });
            }
            return _MockHttpResult.json({}, statusCode: 404);
          }),
        );

        const seed = TrackMetadata(
          providerId: 'local',
          trackId: 'loc-1',
          title: 'Seed Track',
          artist: 'Seed Artist',
        );

        final page = await provider.getTrackRadio(seed, limit: 5);
        expect(page.tracks, hasLength(2));
        expect(page.tracks[0].providerId, equals('listenbrainz'));
        expect(page.tracks[0].trackId, equals('lb-rec-1'));
        expect(page.tracks[1].trackId, equals('lb-rec-2'));
        expect(page.tracks[1].durationMs, equals(195000));

        return429 = true;
        final degraded = await provider.getTrackRadio(seed, limit: 5);
        expect(degraded.tracks, isEmpty);

        enabled = false;
        return429 = false;
        final disabledPage = await provider.getTrackRadio(seed, limit: 5);
        expect(disabledPage.tracks, isEmpty);
      },
    );

    test(
      'LocalLibraryTrackMatcher prefers local lossless over lossy candidates',
      () async {
        final matcher = LocalLibraryTrackMatcher(
          searchLibrary: (q) async => <TrackInfo>[
            const TrackInfo(
              id: 'local_mp3',
              title: 'Instant Crush',
              artist: 'Daft Punk',
              album: 'RAM',
              duration: Duration(milliseconds: 337000),
              filePath: 'D:/Music/InstantCrush.mp3',
              format: AudioFormat(
                codec: AudioCodec.mp3,
                sampleRateHz: 44100,
                bitDepth: 16,
                channels: 2,
                bitrateKbps: 320,
              ),
              providerName: 'Local',
            ),
            const TrackInfo(
              id: 'local_flac',
              title: 'Instant Crush',
              artist: 'Daft Punk',
              album: 'RAM',
              duration: Duration(milliseconds: 337000),
              filePath: 'D:/Music/InstantCrush.flac',
              format: AudioFormat(
                codec: AudioCodec.flac,
                sampleRateHz: 96000,
                bitDepth: 24,
                channels: 2,
              ),
              providerName: 'Local',
            ),
          ],
        );

        final best = await matcher.matchTrack(
          const TrackMatchQuery(
            title: 'Instant Crush',
            artist: 'Daft Punk',
            durationMs: 337000,
          ),
        );
        expect(best, isNotNull);
        expect(best!.providerId, equals('local'));
        expect(best.trackId, equals('local_flac'));
        expect(best.format.codec, equals(AudioCodec.flac));
      },
    );
  });

  group('StreamingManager RecommendationProvider integration', () {
    test(
      'exposes recommendationProviders and aggregates fetchPersonalizedFeeds across healthy connected providers',
      () async {
        final ytm = YouTubeMusicProvider(
          credentialStore: _MemoryCredentialStore(),
          httpClientFactory: () => _MockHttpClient((req) {
            if (req.uri.path == '/youtubei/v1/account/account_menu') {
              return _MockHttpResult.json({
                'header': {
                  'activeAccountHeaderRenderer': {
                    'accountName': {'simpleText': 'YTM User'},
                  },
                },
              });
            }
            if (req.uri.path == '/youtubei/v1/browse') {
              return _MockHttpResult.json({
                'contents': {
                  'musicShelfRenderer': {
                    'title': {'simpleText': 'YTM Feed'},
                    'contents': [
                      {
                        'musicResponsiveListItemRenderer': {
                          'playlistItemData': {'videoId': 'ytFeed00001'},
                          'flexColumns': [
                            {
                              'musicResponsiveListItemFlexColumnRenderer': {
                                'text': {'simpleText': 'YTM Track'},
                              },
                            },
                            {
                              'musicResponsiveListItemFlexColumnRenderer': {
                                'text': {'simpleText': 'YTM Artist'},
                              },
                            },
                          ],
                        },
                      },
                    ],
                  },
                },
              });
            }
            return _MockHttpResult.json({});
          }),
        );

        final tidal = TidalProvider(
          credentialStore: _MemoryCredentialStore(),
          httpClientFactory: () => _MockHttpClient((req) {
            if (req.uri.path == '/v1/sessions') {
              return _MockHttpResult.json({
                'userId': 1,
                'countryCode': 'US',
              });
            }
            if (req.uri.path == '/v1/users/1') {
              return _MockHttpResult.json({
                'id': 1,
                'username': 'u1',
                'countryCode': 'US',
              });
            }
            if (req.uri.path == '/v1/users/1/subscription') {
              return _MockHttpResult.json({'highestSoundQuality': 'LOSSLESS'});
            }
            return _MockHttpResult.json({'error': 'boom'}, statusCode: 500);
          }),
        );

        final manager = StreamingManager(
          credentialStore: _MemoryCredentialStore(),
          enableLiveWarmup: false,
          providers: <String, StreamingProvider>{
            'youtube_music': ytm,
            'tidal': tidal,
            'deezer': DeezerProvider(credentialStore: _MemoryCredentialStore()),
            'qobuz': QobuzProvider(credentialStore: _MemoryCredentialStore()),
            'apple_music': AppleMusicProvider(
              credentialStore: _MemoryCredentialStore(),
            ),
          },
        );
        addTearDown(manager.dispose);

        expect(manager.recommendationProviders.keys, containsAll(<String>[
          'apple_music',
          'youtube_music',
          'qobuz',
          'tidal',
          'deezer',
        ]));
        expect(
          manager.recommendationProviderFor('youtube_music'),
          same(ytm),
        );

        await ytm.authenticate(<String, dynamic>{
          'mode': 'cookie',
          'cookie': 'SAPISID=s1; SID=s2',
        });
        await tidal.authenticate(<String, dynamic>{
          'mode': 'access_token',
          'access_token': 'tok_tidal',
        });

        // Tidal 500 error in getPersonalizedFeed is caught safely; YTM section is returned.
        final feeds = await manager.fetchPersonalizedFeeds();
        expect(feeds, hasLength(1));
        expect(feeds.first.providerId, equals('youtube_music'));
        expect(feeds.first.title, equals('YTM Feed'));
      },
    );
  });

  group('High-res cover_url & recommendation metadata preservation', () {
    test(
      'YouTubeMusicProvider RDAMVM extracts album from longBylineText, skips views/years/duration, and guarantees coverUrl',
      () async {
        final provider = YouTubeMusicProvider(
          credentialStore: _MemoryCredentialStore(),
          httpClientFactory: () => _MockHttpClient((req) {
            if (req.uri.path == '/youtubei/v1/next') {
              return _MockHttpResult.json({
                'contents': {
                  'singleColumnMusicWatchNextResultsRenderer': {
                    'tabbedRenderer': {
                      'watchNextTabbedResultsRenderer': {
                        'tabs': [
                          {
                            'tabRenderer': {
                              'content': {
                                'musicQueueRenderer': {
                                  'content': {
                                    'playlistPanelRenderer': {
                                      'contents': [
                                        {
                                          'playlistPanelVideoRenderer': {
                                            'videoId': 'ytmThumbTr1',
                                            'title': {
                                              'simpleText': 'Instant Crush',
                                            },
                                            'longBylineText': {
                                              'runs': [
                                                {
                                                  'text': 'Daft Punk',
                                                  'navigationEndpoint': {
                                                    'browseEndpoint': {
                                                      'browseId': 'UCdaft',
                                                      'browseEndpointContextSupportedConfigs': {
                                                        'browseEndpointContextMusicConfig': {
                                                          'pageType':
                                                              'MUSIC_PAGE_TYPE_ARTIST',
                                                        },
                                                      },
                                                    },
                                                  },
                                                },
                                                {'text': ' • '},
                                                {
                                                  'text':
                                                      'Random Access Memories',
                                                  'navigationEndpoint': {
                                                    'browseEndpoint': {
                                                      'browseId': 'MPREb_ram',
                                                      'browseEndpointContextSupportedConfigs': {
                                                        'browseEndpointContextMusicConfig': {
                                                          'pageType':
                                                              'MUSIC_PAGE_TYPE_ALBUM',
                                                        },
                                                      },
                                                    },
                                                  },
                                                },
                                                {'text': ' • '},
                                                {'text': '2013'},
                                              ],
                                            },
                                            'lengthText': {'simpleText': '5:37'},
                                            'thumbnail': {
                                              'thumbnails': [
                                                {
                                                  'url':
                                                      'https://lh3.googleusercontent.com/coverhash=w120-h120-l90-rj',
                                                  'width': 120,
                                                  'height': 120,
                                                },
                                              ],
                                            },
                                          },
                                        },
                                        {
                                          'playlistPanelVideoRenderer': {
                                            'videoId': 'ytmNoThumb1',
                                            'title': {'simpleText': '   '},
                                            'longBylineText': {
                                              'runs': [
                                                {'text': 'Channel X'},
                                                {'text': ' • '},
                                                {'text': '12M views'},
                                                {'text': ' • '},
                                                {'text': '2021'},
                                                {'text': ' • '},
                                                {'text': '4:10'},
                                              ],
                                            },
                                            'lengthText': {'simpleText': '4:10'},
                                          },
                                        },
                                        {
                                          'playlistPanelVideoRenderer': {
                                            'videoId': 'ytmPlainAl1',
                                            'title': {
                                              'simpleText': 'Bullet Track',
                                            },
                                            'longBylineText': {
                                              'simpleText':
                                                  'Artist B • My Album • 500萬次觀看 • 2022 • 3:45',
                                            },
                                          },
                                        },
                                      ],
                                    },
                                  },
                                },
                              },
                            },
                          },
                        ],
                      },
                    },
                  },
                },
              });
            }
            return _MockHttpResult.json({});
          }),
        );
        addTearDown(provider.dispose);

        final radio = await provider.getTrackRadio(
          const TrackMetadata(
            providerId: 'youtube_music',
            trackId: 'ytm:seedVid9999',
            title: 'Seed',
            artist: 'Seed Artist',
          ),
          limit: 10,
        );

        expect(radio.tracks, hasLength(3));

        expect(radio.tracks[0].title, equals('Instant Crush'));
        expect(radio.tracks[0].artist, equals('Daft Punk'));
        expect(radio.tracks[0].album, equals('Random Access Memories'));
        expect(
          radio.tracks[0].coverUrl,
          equals('https://lh3.googleusercontent.com/coverhash=w1200-h1200-l90-rj'),
        );

        expect(radio.tracks[1].title, equals('未命名曲目'));
        expect(radio.tracks[1].artist, equals('Channel X'));
        expect(radio.tracks[1].album, equals('YouTube Music Radio'));
        expect(
          radio.tracks[1].coverUrl,
          equals('https://i.ytimg.com/vi/ytmNoThumb1/maxresdefault.jpg'),
        );

        expect(radio.tracks[2].artist, equals('Artist B'));
        expect(radio.tracks[2].album, equals('My Album'));
        expect(
          radio.tracks[2].coverUrl,
          equals('https://i.ytimg.com/vi/ytmPlainAl1/maxresdefault.jpg'),
        );
      },
    );

    test(
      'TidalProvider uses 1280x1280 coverUrl for radio, matchTrack, and personalized feed',
      () async {
        final provider = TidalProvider(
          credentialStore: _MemoryCredentialStore(),
          httpClientFactory: () => _MockHttpClient((req) {
            if (req.uri.path == '/v1/sessions') {
              return _MockHttpResult.json({
                'userId': 123,
                'countryCode': 'US',
              });
            }
            if (req.uri.path == '/v1/users/123') {
              return _MockHttpResult.json({
                'id': 123,
                'username': 'tidal_user',
                'countryCode': 'US',
              });
            }
            if (req.uri.path == '/v1/users/123/subscription') {
              return _MockHttpResult.json({
                'highestSoundQuality': 'HI_RES_LOSSLESS',
              });
            }
            if (req.uri.path == '/v1/tracks/100/radio') {
              return _MockHttpResult.json({
                'items': [
                  {
                    'id': 201,
                    'title': 'Tidal Radio Track',
                    'duration': 210,
                    'audioQuality': 'LOSSLESS',
                    'artist': {'id': 55, 'name': 'Tidal Artist'},
                    'album': {
                      'id': 99,
                      'title': 'Tidal Album',
                      'cover': '11111111-2222-3333-4444-555555555555',
                    },
                  },
                ],
              });
            }
            if (req.uri.path == '/v1/search/tracks') {
              return _MockHttpResult.json({
                'items': [
                  {
                    'id': 301,
                    'title': 'Matched Tidal Track',
                    'duration': 200,
                    'isrc': 'USTIDAL0001',
                    'audioQuality': 'HI_RES_LOSSLESS',
                    'artist': {'id': 10, 'name': 'Artist'},
                    'album': {
                      'id': 11,
                      'title': 'Album',
                      'cover': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
                    },
                  },
                ],
              });
            }
            if (req.uri.path == '/v2/home/feed/static') {
              return _MockHttpResult.json({
                'items': [
                  {
                    'title': 'Tidal Auto Queue Feed',
                    'items': [
                      {
                        'id': 401,
                        'title': 'Feed Track',
                        'duration': 180,
                        'audioQuality': 'LOSSLESS',
                        'artist': {'id': 12, 'name': 'Feed Artist'},
                        'album': {
                          'id': 22,
                          'title': 'Feed Album',
                          'cover': '99999999-8888-7777-6666-555555555555',
                        },
                      },
                    ],
                  },
                ],
              });
            }
            return _MockHttpResult.json({});
          }),
        );

        await provider.authenticate(<String, dynamic>{
          'mode': 'access_token',
          'access_token': 'tidal_tok',
        });

        final radio = await provider.getTrackRadio(
          const TrackMetadata(
            providerId: 'tidal',
            trackId: '100',
            title: 'Seed',
            artist: 'Seed Artist',
          ),
        );
        expect(radio.tracks, hasLength(1));
        expect(
          radio.tracks.first.coverUrl,
          equals(
            'https://resources.tidal.com/images/11111111/2222/3333/4444/555555555555/1280x1280.jpg',
          ),
        );

        final matched = await provider.matchTrack(
          const TrackMatchQuery(
            isrc: 'USTIDAL0001',
            title: 'Matched Tidal Track',
            artist: 'Artist',
          ),
        );
        expect(matched, isNotNull);
        expect(
          matched!.coverUrl,
          equals(
            'https://resources.tidal.com/images/aaaaaaaa/bbbb/cccc/dddd/eeeeeeeeeeee/1280x1280.jpg',
          ),
        );

        final feed = await provider.getPersonalizedFeed();
        expect(feed, isNotEmpty);
        expect(
          feed.first.tracks.first.coverUrl,
          equals(
            'https://resources.tidal.com/images/99999999/8888/7777/6666/555555555555/1280x1280.jpg',
          ),
        );
      },
    );

    test(
      'DeezerProvider prioritizes cover_xl over cover_big and upgrades md5_image fallback to 1000x1000',
      () async {
        final provider = DeezerProvider(
          credentialStore: _MemoryCredentialStore(),
          httpClientFactory: () => _MockHttpClient((req) {
            if (req.uri.path == '/artist/42/radio') {
              return _MockHttpResult.json({
                'data': [
                  {
                    'id': 801,
                    'title': 'XL Cover Track',
                    'duration': 200,
                    'artist': {'id': 42, 'name': 'Justice'},
                    'album': {
                      'id': 1,
                      'title': 'Cross',
                      'cover_big': 'https://cdn.dz.test/500x500.jpg',
                      'cover_xl': 'https://cdn.dz.test/1000x1000.jpg',
                    },
                  },
                  {
                    'id': 802,
                    'title': 'MD5 Fallback Track',
                    'duration': 210,
                    'md5_image': 'abc123md5hash',
                    'artist': {'id': 42, 'name': 'Justice'},
                    'album': {'id': 2, 'title': 'Audio Video Disco'},
                  },
                ],
              });
            }
            if (req.uri.path == '/track/isrc:FRDEEZER01') {
              return _MockHttpResult.json({
                'id': 803,
                'title': 'Matched MD5 Track',
                'duration': 205,
                'isrc': 'FRDEEZER01',
                'md5_image': 'matchmd5hash99',
                'artist': {'id': 42, 'name': 'Justice'},
                'album': {'id': 3, 'title': 'Woman'},
              });
            }
            return _MockHttpResult.json({});
          }),
        );

        final radio = await provider.getTrackRadio(
          const TrackMetadata(
            providerId: 'deezer',
            trackId: '777',
            title: 'Seed',
            artist: 'Justice',
            artistId: '42',
          ),
          limit: 5,
        );
        expect(radio.tracks, hasLength(2));
        expect(
          radio.tracks[0].coverUrl,
          equals('https://cdn.dz.test/1000x1000.jpg'),
        );
        expect(
          radio.tracks[1].coverUrl,
          equals(
            'https://e-cdns-images.dzcdn.net/images/cover/abc123md5hash/1000x1000-000000-80-0-0.jpg',
          ),
        );

        final matched = await provider.matchTrack(
          const TrackMatchQuery(
            isrc: 'FRDEEZER01',
            title: 'Matched MD5 Track',
            artist: 'Justice',
          ),
        );
        expect(
          matched?.coverUrl,
          equals(
            'https://e-cdns-images.dzcdn.net/images/cover/matchmd5hash99/1000x1000-000000-80-0-0.jpg',
          ),
        );
      },
    );

    test(
      'QobuzProvider prioritizes mega > extralarge > large cover URLs',
      () async {
        final provider = QobuzProvider(
          credentialStore: _MemoryCredentialStore(),
          httpClientFactory: () => _MockHttpClient((req) {
            if (req.uri.path == '/api.json/0.2/user/get') {
              return _MockHttpResult.json({
                'user': {'id': 77, 'display_name': 'Qobuz User'},
              });
            }
            if (req.uri.path == '/api.json/0.2/catalog/search') {
              final q = req.uri.queryParameters['query'] ?? '';
              if (q == 'USQOBUZMEGA1') {
                return _MockHttpResult.json({
                  'tracks': {
                    'items': [
                      {
                        'id': 610,
                        'title': 'Mega Track',
                        'duration': 200,
                        'isrc': 'USQOBUZMEGA1',
                        'performer': {'name': 'Artist'},
                        'album': {
                          'title': 'Album Mega',
                          'image': {
                            'large': 'https://static.qobuz.com/600.jpg',
                            'extralarge': 'https://static.qobuz.com/1200.jpg',
                            'mega': 'https://static.qobuz.com/max.jpg',
                          },
                        },
                      },
                    ],
                  },
                });
              }
              return _MockHttpResult.json({
                'tracks': {
                  'items': [
                    {
                      'id': 611,
                      'title': 'ExtraLarge Track',
                      'duration': 200,
                      'isrc': 'USQOBUZXL001',
                      'performer': {'name': 'Artist'},
                      'album': {
                        'title': 'Album XL',
                        'image': {
                          'large': 'https://static.qobuz.com/600.jpg',
                          'extralarge': 'https://static.qobuz.com/1200.jpg',
                        },
                      },
                    },
                  ],
                },
              });
            }
            return _MockHttpResult.json({});
          }),
        );

        await provider.authenticate(<String, dynamic>{
          'mode': 'token',
          'app_id': 'app_1',
          'user_auth_token': 'tok_1',
        });

        final megaMatch = await provider.matchTrack(
          const TrackMatchQuery(
            isrc: 'USQOBUZMEGA1',
            title: 'Mega Track',
            artist: 'Artist',
          ),
        );
        expect(megaMatch?.coverUrl, equals('https://static.qobuz.com/max.jpg'));

        final xlMatch = await provider.matchTrack(
          const TrackMatchQuery(
            isrc: 'USQOBUZXL001',
            title: 'ExtraLarge Track',
            artist: 'Artist',
          ),
        );
        expect(xlMatch?.coverUrl, equals('https://static.qobuz.com/1200.jpg'));
      },
    );

    test(
      'LastFmRecommendationProvider prioritizes mega image and filters blank star placeholders',
      () async {
        const placeholderUrl =
            'https://lastfm.freetls.fastly.net/i/u/300x300/2a96cbd8b46e442fc41c2b86b821562f.png';
        final provider = LastFmRecommendationProvider(
          apiKeyProvider: () => 'lfm_key',
          httpClientFactory: () => _MockHttpClient((req) {
            final method = req.uri.queryParameters['method'];
            if (method == 'track.getSimilar') {
              return _MockHttpResult.json({
                'similartracks': {
                  'track': [
                    {
                      'name': 'Mega Image Track',
                      'duration': 200,
                      'mbid': 'mbid-mega',
                      'artist': {'name': 'Artist 1'},
                      'image': [
                        {'#text': 'https://lfm.test/large.jpg', 'size': 'large'},
                        {
                          '#text': 'https://lfm.test/extralarge.jpg',
                          'size': 'extralarge',
                        },
                        {'#text': 'https://lfm.test/mega.jpg', 'size': 'mega'},
                      ],
                    },
                    {
                      'name': 'Placeholder Only Track',
                      'duration': 210,
                      'mbid': 'mbid-placeholder',
                      'artist': {'name': 'Artist 2'},
                      'image': [
                        {'#text': placeholderUrl, 'size': 'extralarge'},
                        {'#text': placeholderUrl, 'size': 'mega'},
                      ],
                    },
                    {
                      'name': 'Mixed Placeholder Track',
                      'duration': 220,
                      'mbid': 'mbid-mixed',
                      'artist': {'name': 'Artist 3'},
                      'image': [
                        {'#text': placeholderUrl, 'size': 'mega'},
                        {
                          '#text': 'https://lfm.test/real_xl.jpg',
                          'size': 'extralarge',
                        },
                      ],
                    },
                  ],
                },
              });
            }
            return _MockHttpResult.json({});
          }),
        );

        final page = await provider.getTrackRadio(
          const TrackMetadata(
            providerId: 'local',
            trackId: 'loc-1',
            title: 'Seed',
            artist: 'Seed Artist',
          ),
          limit: 10,
        );

        expect(page.tracks, hasLength(3));
        expect(page.tracks[0].coverUrl, equals('https://lfm.test/mega.jpg'));
        expect(page.tracks[1].coverUrl, isNull);
        expect(page.tracks[2].coverUrl, equals('https://lfm.test/real_xl.jpg'));
      },
    );

    test(
      'CrossPlatformTrackRouter preserves candidate coverUrl and album when matched hit lacks them',
      () async {
        final stubProvider = _StubRouterRecommendationProvider(
          providerId: 'qobuz',
          matchHandler: (query) async {
            if (query.title == 'Own Metadata') {
              return TrackMetadata(
                providerId: 'qobuz',
                trackId: 'qb-own',
                title: query.title,
                artist: query.artist,
                album: 'Qobuz Album',
                durationMs: query.durationMs ?? 0,
                coverUrl: 'https://qobuz.example.com/own_cover.jpg',
              );
            }
            return TrackMetadata(
              providerId: 'qobuz',
              trackId: 'qb-999',
              title: query.title,
              artist: query.artist,
              album: '',
              durationMs: query.durationMs ?? 0,
              coverUrl: null,
            );
          },
        );

        final router = CrossPlatformTrackRouter(
          providerLookup: (pid) => pid == 'qobuz' ? stubProvider : null,
          authStateLookup: (pid) => pid == 'qobuz'
              ? StreamingAuthState.connected
              : StreamingAuthState.disconnected,
          localMatcher: (query, {cancel}) async {
            if (query.title == 'Local Missing Meta') {
              return TrackMetadata(
                providerId: 'local',
                trackId: 'loc-1',
                title: query.title,
                artist: query.artist,
                album: '',
                durationMs: query.durationMs ?? 0,
                filePath: 'D:/Music/track.flac',
                coverUrl: '',
              );
            }
            return null;
          },
          priorityOrderProvider: () => const <String>['local', 'qobuz'],
        );

        const candidate = TrackMetadata(
          providerId: 'listenbrainz',
          trackId: 'lb-123',
          title: 'Starlight',
          artist: 'Muse',
          album: 'Black Holes and Revelations',
          durationMs: 240000,
          coverUrl: 'https://cover.example.com/starlight_1200.jpg',
        );

        final resolved = await router.resolveBestPlayableTrack(
          candidate,
          crossPlatformEnabled: true,
        );
        expect(resolved, isNotNull);
        expect(resolved!.providerId, equals('qobuz'));
        expect(resolved.trackId, equals('qb-999'));
        expect(
          resolved.coverUrl,
          equals('https://cover.example.com/starlight_1200.jpg'),
        );
        expect(resolved.album, equals('Black Holes and Revelations'));

        // Verify cached entry also preserves enriched metadata.
        final cached = await router.resolveBestPlayableTrack(
          candidate,
          crossPlatformEnabled: true,
        );
        expect(
          cached?.coverUrl,
          equals('https://cover.example.com/starlight_1200.jpg'),
        );
        expect(cached?.album, equals('Black Holes and Revelations'));

        // Local matcher hit also preserves candidate coverUrl & album.
        const localCandidate = TrackMetadata(
          providerId: 'youtube_music',
          trackId: 'ytm-local-1',
          title: 'Local Missing Meta',
          artist: 'Muse',
          album: 'Candidate Album',
          durationMs: 210000,
          coverUrl: 'https://cover.example.com/local_fallback.jpg',
        );
        final resolvedLocal = await router.resolveBestPlayableTrack(
          localCandidate,
          crossPlatformEnabled: true,
        );
        expect(resolvedLocal?.providerId, equals('local'));
        expect(
          resolvedLocal?.coverUrl,
          equals('https://cover.example.com/local_fallback.jpg'),
        );
        expect(resolvedLocal?.album, equals('Candidate Album'));

        // Matched provider with non-empty metadata is not overwritten.
        const ownCandidate = TrackMetadata(
          providerId: 'lastfm',
          trackId: 'lfm-own',
          title: 'Own Metadata',
          artist: 'Artist',
          album: 'Candidate Album',
          durationMs: 200000,
          coverUrl: 'https://cover.example.com/candidate.jpg',
        );
        final resolvedOwn = await router.resolveBestPlayableTrack(
          ownCandidate,
          crossPlatformEnabled: true,
        );
        expect(
          resolvedOwn?.coverUrl,
          equals('https://qobuz.example.com/own_cover.jpg'),
        );
        expect(resolvedOwn?.album, equals('Qobuz Album'));
      },
    );
  });
}

class _StubRouterRecommendationProvider implements RecommendationProvider {
  @override
  final String recommendationProviderId;
  final Future<TrackMetadata?> Function(TrackMatchQuery query) matchHandler;

  _StubRouterRecommendationProvider({
    required String providerId,
    required this.matchHandler,
  }) : recommendationProviderId = providerId;

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
    supportsTrackRadio: false,
    supportsPersonalFeed: false,
    supportsIsrcLookup: true,
  );

  @override
  Future<List<FeedSection>> getPersonalizedFeed({
    CancellationToken? cancel,
  }) async =>
      const <FeedSection>[];

  @override
  Future<RadioPage> getTrackRadio(
    TrackMetadata seed, {
    int limit = 10,
    String? cursor,
    CancellationToken? cancel,
  }) async =>
      const RadioPage(tracks: <TrackMetadata>[], sourceLabel: 'Stub');

  @override
  Future<TrackMetadata?> matchTrack(
    TrackMatchQuery query, {
    CancellationToken? cancel,
  }) =>
      matchHandler(query);
}
