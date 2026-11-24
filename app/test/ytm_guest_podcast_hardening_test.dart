import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/podcast_models.dart';
import 'package:lumina_app/models/stream_source_spec.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/services/audio_service.dart';
import 'package:lumina_app/services/ffi_audio_service.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/podcast_store.dart';
import 'package:lumina_app/services/streaming/pot_provider.dart';
import 'package:lumina_app/services/streaming/providers/youtube_music_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';
import 'package:lumina_app/services/streaming/streaming_provider.dart';
import 'package:lumina_app/services/streaming/yt_dlp_service.dart';
import 'package:lumina_app/services/streaming/ytm_resident_resolver.dart';

Future<HttpServer> _startServer(
  FutureOr<void> Function(HttpRequest req, String body) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    try {
      final body = await utf8.decoder.bind(req).join();
      await handler(req, body);
    } catch (e) {
      req.response.statusCode = HttpStatus.internalServerError;
      req.response.write(jsonEncode({'error': e.toString()}));
      await req.response.close();
    }
  });
  return server;
}

Future<void> _sendJson(
  HttpResponse resp,
  int statusCode,
  Map<String, dynamic> payload,
) async {
  resp.statusCode = statusCode;
  resp.headers.contentType = ContentType.json;
  resp.write(jsonEncode(payload));
  await resp.close();
}

Future<T> _withRealHttp<T>(Future<T> Function() fn) async {
  final prev = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    return await fn();
  } finally {
    HttpOverrides.global = prev;
  }
}

class _RecordedYtDlpInvocation {
  final String videoId;
  final int playRequestId;
  final String? cookiesFilePath;
  final bool bypassCache;
  final String? formatSelector;
  final String? extractorArgs;
  final String? remoteComponents;

  const _RecordedYtDlpInvocation({
    required this.videoId,
    required this.playRequestId,
    required this.cookiesFilePath,
    required this.bypassCache,
    required this.formatSelector,
    required this.extractorArgs,
    required this.remoteComponents,
  });
}

class _SpyYtDlpService extends YtDlpService {
  final List<_RecordedYtDlpInvocation> calls = <_RecordedYtDlpInvocation>[];

  Future<YtDlpResolvedStream> Function(_RecordedYtDlpInvocation call)? onResolve;

  _SpyYtDlpService({super.clock});

  @override
  Future<YtDlpResolvedStream> resolveVideo(
    String videoId, {
    required int playRequestId,
    String? cookiesFilePath,
    bool bypassCache = false,
    String? formatSelector,
    String? extractorArgs,
    String? remoteComponents,
  }) async {
    final call = _RecordedYtDlpInvocation(
      videoId: videoId,
      playRequestId: playRequestId,
      cookiesFilePath: cookiesFilePath,
      bypassCache: bypassCache,
      formatSelector: formatSelector,
      extractorArgs: extractorArgs,
      remoteComponents: remoteComponents,
    );
    calls.add(call);
    if (onResolve != null) {
      return onResolve!(call);
    }
    throw const YtDlpException('yt-dlp spy had no handler configured');
  }
}

class _FakePotProvider implements PotProvider {
  final List<String> gvsBindings = <String>[];
  final List<String> playerVideoIds = <String>[];

  @override
  Future<PoToken?> getGvsToken({
    required String sessionBinding,
    CancellationToken? cancelToken,
  }) async {
    gvsBindings.add(sessionBinding);
    return PoToken(
      token: 'GVS_POT_$sessionBinding',
      scope: PoTokenScope.gvs,
      bindingKey: sessionBinding,
      mintedAt: DateTime.utc(2026, 11, 23, 12, 0, 0),
      expiresAt: DateTime.utc(2027, 1, 1),
    );
  }

  @override
  Future<PoToken?> getPlayerToken({
    required String videoId,
    CancellationToken? cancelToken,
  }) async {
    playerVideoIds.add(videoId);
    return PoToken(
      token: 'PLAYER_POT_$videoId',
      scope: PoTokenScope.player,
      bindingKey: videoId,
      mintedAt: DateTime.utc(2026, 11, 23, 12, 0, 0),
      expiresAt: DateTime.utc(2027, 1, 1),
    );
  }

  @override
  void invalidateSession() {}

  @override
  Future<void> dispose() async {}
}

Map<String, dynamic> _accountMenuOk({String visitorData = 'CgtBY2NvdW50VmQ='}) {
  return <String, dynamic>{
    'responseContext': <String, dynamic>{'visitorData': visitorData},
    'actions': <dynamic>[
      <String, dynamic>{
        'openPopupAction': <String, dynamic>{
          'popup': <String, dynamic>{
            'multiPageMenuRenderer': <String, dynamic>{
              'header': <String, dynamic>{
                'activeAccountHeaderRenderer': <String, dynamic>{
                  'accountName': <String, dynamic>{
                    'runs': <dynamic>[
                      <String, dynamic>{'text': 'Lumina Tester'},
                    ],
                  },
                  'email': <String, dynamic>{
                    'runs': <dynamic>[
                      <String, dynamic>{'text': 'tester@example.com'},
                    ],
                  },
                },
              },
            },
          },
        },
      },
    ],
  };
}

Map<String, dynamic> _player251Payload({
  required String url,
  int contentLength = 5200000,
  int expireAt = 1790050000,
  String? visitorData,
}) {
  return <String, dynamic>{
    if (visitorData != null)
      'responseContext': <String, dynamic>{'visitorData': visitorData},
    'playabilityStatus': <String, dynamic>{'status': 'OK'},
    'streamingData': <String, dynamic>{
      'expiresInSeconds': '21600',
      'adaptiveFormats': <dynamic>[
        <String, dynamic>{
          'itag': 140,
          'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
          'bitrate': 128000,
          'contentLength': '3900000',
          'audioSampleRate': '44100',
          'url':
              'https://rr1.googlevideo.com/videoplayback?itag=140&expire=$expireAt',
        },
        <String, dynamic>{
          'itag': 251,
          'mimeType': 'audio/webm; codecs="opus"',
          'bitrate': 160000,
          'contentLength': '$contentLength',
          'audioSampleRate': '48000',
          'audioChannels': 2,
          'url': url,
        },
      ],
    },
  };
}

Map<String, dynamic> _player140Payload({
  required String url,
  int contentLength = 3900000,
}) {
  return <String, dynamic>{
    'playabilityStatus': <String, dynamic>{'status': 'OK'},
    'streamingData': <String, dynamic>{
      'expiresInSeconds': '21600',
      'adaptiveFormats': <dynamic>[
        <String, dynamic>{
          'itag': 140,
          'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
          'bitrate': 128000,
          'contentLength': '$contentLength',
          'audioSampleRate': '44100',
          'url': url,
        },
      ],
    },
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Guest YouTube Music & YouTube Podcast native playback + Auth decoupling', () {
    test(
      'Guest mode resolves & prefetches both YouTube Music and YouTube Podcast without ever tripping AuthManager AuthRequired',
      () async {
        await _withRealHttp(() async {
          final now = DateTime.utc(2026, 11, 23, 12, 0, 0);
          final expireAt = (now.millisecondsSinceEpoch ~/ 1000) + 21600;
          final server = await _startServer((req, body) async {
            if (req.uri.path == '/youtubei/v1/player') {
              final decoded = jsonDecode(body) as Map<String, dynamic>;
              final vid = decoded['videoId'].toString();
              return _sendJson(
                req.response,
                HttpStatus.ok,
                _player251Payload(
                  url:
                      'https://rr1.googlevideo.com/videoplayback?id=$vid&itag=251&expire=$expireAt',
                  expireAt: expireAt,
                ),
              );
            }
            return _sendJson(req.response, HttpStatus.notFound, {});
          });
          addTearDown(() => server.close(force: true));

          final store = MemorySecureCredentialStore();
          final spyYtDlp = _SpyYtDlpService(clock: () => now);
          addTearDown(spyYtDlp.dispose);

          final ytm = YouTubeMusicProvider(
            credentialStore: store,
            baseUrl: 'http://127.0.0.1:${server.port}',
            clock: () => now,
            ytDlpService: spyYtDlp,
          );
          final manager = StreamingManager(
            credentialStore: store,
            providers: <String, StreamingProvider>{'youtube_music': ytm},
            clock: () => now,
            ytDlpService: spyYtDlp,
            enableLiveWarmup: false,
          );
          addTearDown(() => manager.disposeAsync());

          final ffiService = FfiAudioService(headless: true);
          ffiService.attachStreamingManager(manager);
          addTearDown(ffiService.dispose);

          final audio = MockAudioService();
          final coordinator = StreamingPlaybackCoordinator(
            audioService: audio,
            streamingManager: manager,
            useResolverPipeline: true,
            clock: () => now,
          );
          addTearDown(coordinator.dispose);

          var authListenerCalls = 0;
          manager.addAuthRequiredListener((_, _) => authListenerCalls++);

          expect(ytm.authState, equals(StreamingAuthState.disconnected));
          expect(manager.authManager.isGuestPlaybackCapable('youtube_music'), isTrue);
          expect(manager.isAuthRequired('youtube_music'), isFalse);
          expect(manager.isPlaybackAuthBlocked('youtube_music'), isFalse);

          final musicTrack = TrackInfo(
            id: 'ytm:dQw4w9WgXcQ',
            title: 'Guest Song',
            artist: 'Guest Artist',
            album: 'Guest Album',
            duration: const Duration(seconds: 213),
            format: const AudioFormat(
              codec: AudioCodec.opus,
              sampleRateHz: 48000,
              bitDepth: 16,
              channels: 2,
            ),
            providerName: 'YouTube Music',
          );

          const podcastEpisode = PodcastEpisode(
            videoId: 'DYptgVvkVLQ',
            showId: 'MPSPPL1234',
            title: 'Guest Podcast Ep 1',
            showTitle: 'Tech Talk',
            duration: Duration(minutes: 42),
          );
          final podcastTrack = podcastEpisode.toTrack();
          expect(podcastTrack.id, equals('ytm:DYptgVvkVLQ'));
          expect(podcastTrack.providerName, equals('Podcast'));

          // Both Music and Podcast derive canonical providerId == 'youtube_music'.
          final musicKey = manager.resolverRegistry.deriveKey(musicTrack);
          final podcastKey = manager.resolverRegistry.deriveKey(podcastTrack);
          expect(musicKey.providerId, equals('youtube_music'));
          expect(podcastKey.providerId, equals('youtube_music'));
          expect(podcastKey.trackId, equals('DYptgVvkVLQ'));

          // Prefetch is allowed in Guest mode for both Music & Podcast.
          expect(coordinator.canPrefetchTrack(musicTrack), isTrue);
          expect(coordinator.canPrefetchTrack(podcastTrack), isTrue);

          await coordinator.prefetchTrack(podcastTrack);
          final cachedPodcast =
              manager.peekCachedSpec(podcastKey) as DirectRangeSpec?;
          expect(cachedPodcast, isNotNull);
          expect(cachedPodcast!.url, contains('id=DYptgVvkVLQ'));
          expect(cachedPodcast.mimeType, startsWith('audio/webm'));
          expect(cachedPodcast.hintExtension, equals('webm'));

          // Direct resolution works in Guest mode with 0 yt-dlp spawns when ANDROID_VR succeeds.
          final resolvedMusic = await manager.resolveSourceSpecForTrack(
            musicTrack,
            useL1Cache: true,
          );
          expect(resolvedMusic, isA<DirectRangeSpec>());
          expect((resolvedMusic as DirectRangeSpec).url, contains('id=dQw4w9WgXcQ'));
          expect(spyYtDlp.calls, isEmpty);

          // Attempting to trip AuthRequired or report AUTH_REQUIRED in Guest mode MUST be a complete no-op!
          manager.authManager.tripAuthRequired('youtube_music', 'LOGIN_REQUIRED');
          final refreshed = await manager.authManager.handleUnauthorized(
            'youtube_music',
            'HTTP 401 Unauthorized',
          );
          expect(refreshed, isFalse);

          await ffiService.handlePolledPlaybackStateError(
            status: PlaybackStatus.error,
            lastErrorCode: 'AUTH_REQUIRED',
            lastErrorProvider: 'youtube_music',
            lastError: 'HTTP 401 Unauthorized',
            epoch: 1,
          );

          expect(manager.isAuthRequired('youtube_music'), isFalse);
          expect(manager.isPlaybackAuthBlocked('youtube_music'), isFalse);
          expect(authListenerCalls, equals(0));
          // L1 cache for both Music & Podcast MUST remain intact.
          expect(manager.peekCachedSpec(musicKey), isNotNull);
          expect(manager.peekCachedSpec(podcastKey), isNotNull);
          expect(coordinator.canPrefetchTrack(podcastTrack), isTrue);
        });
      },
    );

    test(
      'Logged-in playlist sync works, and a 401 on syncLibrary never evicts L1 cache or blocks Guest-capable playback/prefetch',
      () async {
        await _withRealHttp(() async {
          final now = DateTime.utc(2026, 11, 23, 12, 0, 0);
          final expireAt = (now.millisecondsSinceEpoch ~/ 1000) + 21600;
          var failBrowseWith401 = false;

          final server = await _startServer((req, body) async {
            if (req.uri.path == '/youtubei/v1/account/account_menu') {
              return _sendJson(req.response, HttpStatus.ok, _accountMenuOk());
            }
            if (req.uri.path == '/youtubei/v1/browse') {
              if (failBrowseWith401) {
                return _sendJson(req.response, HttpStatus.unauthorized, {
                  'error': {'code': 401, 'message': 'UNAUTHENTICATED'},
                });
              }
              return _sendJson(req.response, HttpStatus.ok, {
                'contents': {
                  'singleColumnBrowseResultsRenderer': {
                    'tabs': [
                      {
                        'tabRenderer': {
                          'content': {
                            'sectionListRenderer': {
                              'contents': [
                                {
                                  'gridRenderer': {
                                    'items': [
                                      {
                                        'musicTwoRowItemRenderer': {
                                          'title': {
                                            'runs': [
                                              {'text': 'My Synced Mix'},
                                            ],
                                          },
                                          'navigationEndpoint': {
                                            'browseEndpoint': {
                                              'browseId': 'VLPL123456',
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
            }
            if (req.uri.path == '/youtubei/v1/player') {
              final decoded = jsonDecode(body) as Map<String, dynamic>;
              final vid = decoded['videoId'].toString();
              return _sendJson(
                req.response,
                HttpStatus.ok,
                _player251Payload(
                  url:
                      'https://rr1.googlevideo.com/videoplayback?id=$vid&itag=251&expire=$expireAt',
                  expireAt: expireAt,
                ),
              );
            }
            return _sendJson(req.response, HttpStatus.notFound, {});
          });
          addTearDown(() => server.close(force: true));

          final store = MemorySecureCredentialStore();
          final spyYtDlp = _SpyYtDlpService(clock: () => now);
          addTearDown(spyYtDlp.dispose);

          final ytm = YouTubeMusicProvider(
            credentialStore: store,
            baseUrl: 'http://127.0.0.1:${server.port}',
            clock: () => now,
            ytDlpService: spyYtDlp,
          );
          final manager = StreamingManager(
            credentialStore: store,
            providers: <String, StreamingProvider>{'youtube_music': ytm},
            clock: () => now,
            ytDlpService: spyYtDlp,
            enableLiveWarmup: false,
          );
          addTearDown(() => manager.disposeAsync());

          final coordinator = StreamingPlaybackCoordinator(
            audioService: MockAudioService(),
            streamingManager: manager,
            useResolverPipeline: true,
            clock: () => now,
          );
          addTearDown(coordinator.dispose);

          await manager.authenticateProvider('youtube_music', {
            'mode': 'cookie',
            'cookie': 'SAPISID=valid_sapisid_123; SID=valid_sid',
          });
          expect(ytm.authState, equals(StreamingAuthState.connected));

          // Logged-in playlist sync works normally.
          final catalog = await manager.syncProvider('youtube_music');
          expect(catalog.playlists.map((p) => p.title), contains('My Synced Mix'));

          // Warm L1 cache with a resolved track.
          const key = StreamKey('youtube_music', 'dQw4w9WgXcQ', 'default');
          final spec1 = await manager.resolveSourceSpec(key);
          expect(spec1, isA<DirectRangeSpec>());
          expect(manager.peekCachedSpec(key), isNotNull);

          // Now cookies expire during library sync (HTTP 401):
          failBrowseWith401 = true;
          await expectLater(
            manager.syncProvider('youtube_music'),
            throwsA(isA<StreamingException>()),
          );

          // Sync reports authRequired for account UI, BUT playback & L1 cache are NOT blocked!
          expect(manager.isAuthRequired('youtube_music'), isTrue);
          expect(manager.isPlaybackAuthBlocked('youtube_music'), isFalse);
          expect(manager.peekCachedSpec(key), isNotNull);

          final nextTrack = TrackInfo(
            id: 'ytm:YhiQDARUJ7Y',
            title: 'Still Playable',
            artist: 'Artist',
            album: 'Album',
            duration: const Duration(seconds: 180),
            format: const AudioFormat(
              codec: AudioCodec.opus,
              sampleRateHz: 48000,
              bitDepth: 16,
              channels: 2,
            ),
            providerName: 'YouTube Music',
          );
          expect(coordinator.canPrefetchTrack(nextTrack), isTrue);
          final spec2 = await manager.resolveSourceSpecForTrack(
            nextTrack,
            useL1Cache: true,
          );
          expect(spec2, isA<DirectRangeSpec>());
          expect((spec2 as DirectRangeSpec).url, contains('id=YhiQDARUJ7Y'));
        });
      },
    );
  });

  group('InnerTube Hardening: Zero TVHTML5, Zero Cookie Leak in ANDROID_VR, Cold-start visitorData + PO Token, JS Runtime Fallback', () {
    test(
      'ANDROID_VR cold-start fetches guest visitorData via /sw.js_data, binds PO Token, retries cleanly with ZERO web auth headers and ZERO TVHTML5',
      () async {
        await _withRealHttp(() async {
          final now = DateTime.utc(2026, 11, 23, 12, 0, 0);
          final expireAt = (now.millisecondsSinceEpoch ~/ 1000) + 21600;
          final playerRequests = <({
            String clientName,
            String? clientHeader,
            Map<String, String> headers,
            Map<String, dynamic> body,
          })>[];

          final server = await _startServer((req, body) async {
            if (req.uri.path == '/sw.js_data') {
              req.response.statusCode = HttpStatus.ok;
              req.response.write(")]}'\n[[\"CgtHdWVzdFZpc2l0b3IxMjM=\"]]");
              await req.response.close();
              return;
            }
            if (req.uri.path == '/youtubei/v1/player') {
              final headers = <String, String>{};
              req.headers.forEach((k, v) => headers[k.toLowerCase()] = v.join(', '));
              final decoded = jsonDecode(body) as Map<String, dynamic>;
              final client = (decoded['context'] as Map)['client'] as Map;
              final clientName = client['clientName'].toString();
              playerRequests.add((
                clientName: clientName,
                clientHeader: headers['x-youtube-client-name'],
                headers: headers,
                body: decoded,
              ));

              // Simulate YouTube gating ANDROID_VR when visitorData is missing.
              final vd = client['visitorData']?.toString();
              if (clientName == 'ANDROID_VR' && (vd == null || vd.isEmpty)) {
                return _sendJson(req.response, HttpStatus.ok, {
                  'playabilityStatus': {
                    'status': 'LOGIN_REQUIRED',
                    'reason': 'Sign in to confirm you are not a bot',
                  },
                });
              }

              if (clientName == 'ANDROID_VR' && vd == 'CgtHdWVzdFZpc2l0b3IxMjM=') {
                return _sendJson(
                  req.response,
                  HttpStatus.ok,
                  _player251Payload(
                    url:
                        'https://rr3.googlevideo.com/videoplayback?itag=251&c=ANDROID_VR&expire=$expireAt',
                    expireAt: expireAt,
                    visitorData: vd,
                  ),
                );
              }
            }
            return _sendJson(req.response, HttpStatus.notFound, {});
          });
          addTearDown(() => server.close(force: true));

          final pot = _FakePotProvider();
          final baseUrl = 'http://127.0.0.1:${server.port}';
          final resolver = YtmResidentResolver(
            webBaseUrl: baseUrl,
            musicBaseUrl: baseUrl,
            potProvider: pot,
            clock: () => now,
            // Even when logged-in cookies exist, ANDROID_VR MUST NOT receive them!
            authProvider: () => const YtmAuthCredentials(
              authMode: 'cookie',
              cookie: 'SAPISID=super_secret_cookie; SID=secret_sid',
              visitorData: 'CgtBdXRoVmlzaXRvck5vdEZvclZS',
            ),
          );
          addTearDown(() => resolver.disposeAsync());

          final spec = await resolver.resolve(
            const StreamKey('youtube_music', 'dQw4w9WgXcQ', 'default'),
          );
          expect(spec, isA<DirectRangeSpec>());
          final direct = spec as DirectRangeSpec;
          expect(direct.url, contains('itag=251'));
          expect(Uri.parse(direct.url).queryParameters['pot'], isNotEmpty);
          expect(direct.mimeType, startsWith('audio/webm'));
          expect(direct.hintExtension, equals('webm'));
          expect(direct.headers['User-Agent'], contains('youtube.vr.oculus'));

          expect(playerRequests.length, equals(2));
          for (final req in playerRequests) {
            expect(req.clientName, equals('ANDROID_VR'));
            expect(req.clientHeader, equals('28'));
            expect(req.clientName, isNot(contains('TVHTML5')));
            expect(req.clientHeader, isNot('85'));
            expect(req.headers['cookie'], isNull);
            expect(req.headers['authorization'], isNull);
            expect(req.headers['origin'], isNull);
            expect(req.headers['x-origin'], isNull);
            expect(req.headers['referer'], isNull);
            expect(req.headers['x-goog-authuser'], isNull);
          }
          // Second ANDROID_VR attempt carried guest visitorData from /sw.js_data,
          // NEVER the authenticated account's visitorData.
          expect(
            playerRequests.last.headers['x-goog-visitor-id'],
            equals('CgtHdWVzdFZpc2l0b3IxMjM='),
          );
          expect(
            ((playerRequests.last.body['context'] as Map)['client'] as Map)['visitorData'],
            equals('CgtHdWVzdFZpc2l0b3IxMjM='),
          );
        });
      },
    );

    test(
      'ANDROID_VR LOGIN_REQUIRED + WEB_REMIX signatureCipher-only falls back to yt-dlp + deno EJS with PO Token, visitorData, itag 251 preference, and valid StreamSourceSpec wire headers/mime_type',
      () async {
        await _withRealHttp(() async {
          final now = DateTime.utc(2026, 11, 23, 12, 0, 0);
          final expireAt = (now.millisecondsSinceEpoch ~/ 1000) + 18000;
          final seenClients = <String>[];

          final server = await _startServer((req, body) async {
            if (req.uri.path == '/sw.js_data') {
              req.response.statusCode = HttpStatus.ok;
              req.response.write(")]}'\n[[\"CgtHdWVzdFZpc2l0b3JKRg==\"]]");
              await req.response.close();
              return;
            }
            if (req.uri.path == '/youtubei/v1/player') {
              final decoded = jsonDecode(body) as Map<String, dynamic>;
              final clientName =
                  ((decoded['context'] as Map)['client'] as Map)['clientName']
                      .toString();
              seenClients.add(clientName);

              if (clientName == 'ANDROID_VR') {
                return _sendJson(req.response, HttpStatus.ok, {
                  'playabilityStatus': {'status': 'LOGIN_REQUIRED'},
                });
              }
              if (clientName == 'WEB_REMIX') {
                // Realistic YouTube WEB_REMIX response: status=OK but only signatureCipher!
                return _sendJson(req.response, HttpStatus.ok, {
                  'playabilityStatus': {'status': 'OK'},
                  'streamingData': {
                    'adaptiveFormats': [
                      {
                        'itag': 251,
                        'mimeType': 'audio/webm; codecs="opus"',
                        'bitrate': 160000,
                        'signatureCipher':
                            's=ENCRYPTED_SIG&sp=sig&url=https%3A%2F%2Frr1.googlevideo.com%2Fvideoplayback%3Fitag%3D251',
                      },
                    ],
                  },
                });
              }
            }
            return _sendJson(req.response, HttpStatus.notFound, {});
          });
          addTearDown(() => server.close(force: true));

          final pot = _FakePotProvider();
          final spyYtDlp = _SpyYtDlpService(clock: () => now)
            ..onResolve = (call) async {
              return YtDlpResolvedStream(
                videoId: call.videoId,
                url:
                    'https://rr5.googlevideo.com/videoplayback?itag=251&c=WEB_REMIX&expire=$expireAt&n=DECRYPTED_N',
                httpHeaders: const <String, String>{
                  'User-Agent': 'Mozilla/5.0 Chrome/131.0',
                  'Accept-Language': 'en-US,en;q=0.9',
                  // Verify sensitive auth headers are stripped from CDN fetch headers.
                  'Cookie': 'SHOULD_NOT_LEAK=1',
                  'Authorization': 'SAPISIDHASH should_not_leak',
                },
                ext: 'webm',
                acodec: 'opus',
                mimeType: 'audio/webm',
                contentLength: 4321000,
                bitrateKbps: 160,
                sampleRateHz: 48000,
                expiresAt: DateTime.fromMillisecondsSinceEpoch(
                  expireAt * 1000,
                  isUtc: true,
                ),
              );
            };
          addTearDown(spyYtDlp.dispose);

          final provider = YouTubeMusicProvider(
            credentialStore: MemorySecureCredentialStore(),
            baseUrl: 'http://127.0.0.1:${server.port}',
            clock: () => now,
            ytDlpService: spyYtDlp,
            potProvider: pot,
          );
          addTearDown(() => provider.disposeAsync());

          final spec = await provider.resolve(
            const StreamKey('youtube_music', 'dQw4w9WgXcQ', 'default'),
          );
          expect(spec, isA<DirectRangeSpec>());
          final direct = spec as DirectRangeSpec;

          // Deprecated TVHTML5 was NEVER attempted.
          expect(seenClients.any((c) => c.contains('TVHTML5')), isFalse);
          expect(seenClients, containsAllInOrder(<String>['ANDROID_VR', 'WEB_REMIX']));

          // yt-dlp + deno EJS fallback ran once with Opus-preferred selector,
          // ejs:github remote component, PO Tokens, and guest visitorData.
          expect(spyYtDlp.calls.length, equals(1));
          final call = spyYtDlp.calls.single;
          expect(
            call.formatSelector,
            equals(YtDlpService.opusPreferredAudioFormatSelector),
          );
          expect(call.remoteComponents, equals('ejs:github'));
          expect(call.extractorArgs, contains('po_token=web.gvs+GVS_POT_'));
          expect(call.extractorArgs, contains('web.player+PLAYER_POT_dQw4w9WgXcQ'));
          expect(call.extractorArgs, contains('visitor_data=CgtHdWVzdFZpc2l0b3JKRg=='));

          // Returned StreamSourceSpec matches Rust FFI wire schema strictly.
          expect(direct.url, contains('itag=251'));
          expect(Uri.parse(direct.url).queryParameters['pot'], startsWith('GVS_POT_'));
          expect(direct.mimeType, equals('audio/webm'));
          expect(direct.hintExtension, equals('webm'));
          expect(direct.contentLength, equals(4321000));
          expect(direct.bitrateBps, equals(160000));
          expect(direct.headers['User-Agent'], equals('Mozilla/5.0 Chrome/131.0'));
          expect(direct.headers['Origin'], equals('https://music.youtube.com'));
          expect(direct.headers['Referer'], equals('https://music.youtube.com/'));
          expect(direct.headers['Cookie'], isNull);
          expect(direct.headers['Authorization'], isNull);

          final wire = direct.toJson();
          expect(wire['kind'], equals('direct_range'));
          expect(wire.containsKey('headers'), isTrue);
          expect(wire.containsKey('http_headers'), isFalse);
          expect((wire['headers'] as Map)['User-Agent'], isNotEmpty);
          expect(wire['mime_type'], equals('audio/webm'));
          expect(wire['hint_extension'], equals('webm'));
          expect((wire['key'] as Map)['provider_id'], equals('youtube_music'));
        });
      },
    );

    test(
      'Expired logged-in cookies (WEB_REMIX 401 + cookie yt-dlp failure) gracefully fall back to Guest yt-dlp without breaking playback',
      () async {
        await _withRealHttp(() async {
          final now = DateTime.utc(2026, 11, 23, 12, 0, 0);
          final expireAt = (now.millisecondsSinceEpoch ~/ 1000) + 18000;

          final server = await _startServer((req, body) async {
            if (req.uri.path == '/youtubei/v1/account/account_menu') {
              return _sendJson(req.response, HttpStatus.ok, _accountMenuOk());
            }
            if (req.uri.path == '/youtubei/v1/player') {
              final decoded = jsonDecode(body) as Map<String, dynamic>;
              final clientName =
                  ((decoded['context'] as Map)['client'] as Map)['clientName']
                      .toString();
              if (clientName == 'ANDROID_VR') {
                return _sendJson(req.response, HttpStatus.ok, {
                  'playabilityStatus': {'status': 'LOGIN_REQUIRED'},
                });
              }
              if (clientName == 'WEB_REMIX') {
                return _sendJson(req.response, HttpStatus.unauthorized, {
                  'error': {'code': 401, 'message': 'UNAUTHENTICATED'},
                });
              }
            }
            return _sendJson(req.response, HttpStatus.notFound, {});
          });
          addTearDown(() => server.close(force: true));

          final spyYtDlp = _SpyYtDlpService(clock: () => now)
            ..onResolve = (call) async {
              if (call.cookiesFilePath != null) {
                throw const YtDlpException('ERROR: expired cookies rejected');
              }
              return YtDlpResolvedStream(
                videoId: call.videoId,
                url:
                    'https://rr7.googlevideo.com/videoplayback?itag=140&c=WEB&expire=$expireAt',
                httpHeaders: const <String, String>{
                  'User-Agent': 'Mozilla/5.0 Chrome/131.0',
                },
                ext: 'm4a',
                acodec: 'mp4a.40.2',
                mimeType: 'audio/mp4',
                contentLength: 3456789,
                bitrateKbps: 128,
                sampleRateHz: 44100,
                expiresAt: DateTime.fromMillisecondsSinceEpoch(
                  expireAt * 1000,
                  isUtc: true,
                ),
              );
            };
          addTearDown(spyYtDlp.dispose);

          final provider = YouTubeMusicProvider(
            credentialStore: MemorySecureCredentialStore(),
            baseUrl: 'http://127.0.0.1:${server.port}',
            clock: () => now,
            ytDlpService: spyYtDlp,
          );
          addTearDown(() => provider.disposeAsync());

          await provider.authenticate({
            'mode': 'cookie',
            'cookie': 'SAPISID=expired_sapisid; SID=expired_sid',
          });

          final spec = await provider.resolve(
            const StreamKey('youtube_music', 'dQw4w9WgXcQ', 'default'),
          ) as DirectRangeSpec;

          // Attempt 1 tried cookies; Attempt 2 cleanly succeeded in Guest mode.
          expect(spyYtDlp.calls.length, equals(2));
          expect(spyYtDlp.calls[0].cookiesFilePath, isNotNull);
          expect(spyYtDlp.calls[1].cookiesFilePath, isNull);
          expect(spyYtDlp.calls[1].bypassCache, isTrue);

          expect(spec.url, contains('itag=140'));
          expect(spec.mimeType, equals('audio/mp4'));
          expect(spec.hintExtension, equals('m4a'));
          expect(spec.headers['Origin'], equals('https://www.youtube.com'));
          expect(spec.headers['Referer'], equals('https://www.youtube.com/'));
        });
      },
    );

    test(
      'YtDlpService.buildResolveArgs wires --remote-components ejs:github, opus selector, and deno js-runtime when present',
      () {
        final args = YtDlpService.buildResolveArgs(
          videoId: 'dQw4w9WgXcQ',
          denoPath: r'C:\vendor\deno.exe',
          formatSelector: YtDlpService.opusPreferredAudioFormatSelector,
          extractorArgs:
              'youtube:player_client=default,-tv_samsung;po_token=web.gvs+TOK',
          remoteComponents: YtDlpService.defaultRemoteComponents,
        );
        expect(args, containsAllInOrder(['-f', YtDlpService.opusPreferredAudioFormatSelector]));
        expect(args, containsAllInOrder(['--js-runtimes', r'deno:C:\vendor\deno.exe']));
        expect(args, containsAllInOrder(['--remote-components', 'ejs:github']));
        expect(
          args,
          containsAllInOrder([
            '--extractor-args',
            'youtube:player_client=default,-tv_samsung;po_token=web.gvs+TOK',
          ]),
        );
      },
    );
  });

  group('External RSS Podcast resolution (ExternalPodcastRssResolver)', () {
    test(
      'PodcastEpisode with external audioUrl resolves via podcast_rss with browser headers, accurate mimeType, and zero YouTube videoId parsing',
      () async {
        final now = DateTime.utc(2026, 11, 23, 12, 0, 0);
        final store = MemorySecureCredentialStore();
        final manager = StreamingManager(
          credentialStore: store,
          clock: () => now,
          enableLiveWarmup: false,
        );
        addTearDown(() => manager.disposeAsync());

        const mp3Episode = PodcastEpisode(
          videoId: 'rss-ep-42',
          showId: 'rss-show-1',
          title: 'External MP3 Episode',
          showTitle: 'Indie Podcast',
          duration: Duration(minutes: 30),
          audioUrl: 'https://cdn.example.com/podcasts/ep42.mp3?token=abc',
        );
        expect(mp3Episode.isExternalRssAudio, isTrue);

        final mp3Track = mp3Episode.toTrack();
        expect(
          mp3Track.id,
          equals('podcast_rss:https://cdn.example.com/podcasts/ep42.mp3?token=abc'),
        );
        expect(mp3Track.providerName, equals('Podcast'));
        expect(AudioService.isStreamingTrackId(mp3Track.id), isTrue);
        expect(
          PodcastStore.normalizeVideoId(mp3Track.id),
          equals('https://cdn.example.com/podcasts/ep42.mp3?token=abc'),
        );
        // External RSS tracks must NOT falsely map to YouTubeMusicProvider.
        expect(manager.resolveProviderForTrack(mp3Track), isNull);

        final mp3Spec = await manager.resolveSourceSpecForTrack(
          mp3Track,
          useL1Cache: true,
        );
        expect(mp3Spec, isA<DirectRangeSpec>());
        final directMp3 = mp3Spec as DirectRangeSpec;
        expect(directMp3.key.providerId, equals('podcast_rss'));
        expect(
          directMp3.url,
          equals('https://cdn.example.com/podcasts/ep42.mp3?token=abc'),
        );
        expect(directMp3.headers['User-Agent'], contains('Mozilla/5.0'));
        expect(directMp3.headers['Accept'], isNotEmpty);
        expect(directMp3.headers['Accept-Language'], isNotEmpty);
        expect(directMp3.mimeType, equals('audio/mpeg'));
        expect(directMp3.hintExtension, equals('mp3'));
        expect(directMp3.audioFormat?.codec, equals(AudioCodec.mp3));

        // Capabilities match Rust ChunkedStreamProxy expectations (no L1/L2 cache).
        final caps = manager.resolverRegistry.capabilitiesFor('podcast_rss')!;
        expect(caps, equals(ProviderCapabilities.podcastRss));
        expect(caps.supportsL1UrlCache, isFalse);
        expect(caps.supportsL2HeadCache, isFalse);
        expect(caps.requiresRangeChunking, isTrue);

        // Extensionless tracking/redirect RSS URLs leave mimeType/hintExtension null
        // so Rust probes the redirected bytes accurately instead of mis-hinting.
        const redirectEpisode = PodcastEpisode(
          videoId: 'rss-ep-99',
          showId: 'rss-show-2',
          title: 'Redirected Episode',
          showTitle: 'Anchor Show',
          audioUrl: 'https://anchor.fm/s/123456/podcast/play/987654/audio',
        );
        final redirectSpec = await manager.resolveSourceSpecForTrack(
          redirectEpisode.toTrack(),
          useL1Cache: true,
        ) as DirectRangeSpec;
        expect(redirectSpec.key.providerId, equals('podcast_rss'));
        expect(
          redirectSpec.url,
          equals('https://anchor.fm/s/123456/podcast/play/987654/audio'),
        );
        expect(redirectSpec.headers['User-Agent'], contains('Mozilla/5.0'));
        expect(redirectSpec.mimeType, isNull);
        expect(redirectSpec.hintExtension, isNull);

        // JSON round-trip preserves audioUrl on PodcastEpisode.
        final roundTrip = PodcastEpisode.fromJson(mp3Episode.toJson());
        expect(roundTrip.audioUrl, equals(mp3Episode.audioUrl));
        expect(roundTrip, equals(mp3Episode));
      },
    );
  });

  group('Expired L1 URL -> CAS invalidation + 403 refresh for YouTube Music & Podcast (including offset=0 initial probe)', () {
    test(
      'FfiAudioService.handleStreamRefreshRequestJson refreshes expired L1 URL for YouTube Music and Podcast, allows format change on is_initial_probe=true, and flags format_changed mid-stream',
      () async {
        await _withRealHttp(() async {
          final now = DateTime.utc(2026, 11, 23, 12, 0, 0);
          final expireAt = (now.millisecondsSinceEpoch ~/ 1000) + 21600;
          var resolveGeneration = 0;
          var return140InsteadOf251 = false;

          final server = await _startServer((req, body) async {
            if (req.uri.path == '/youtubei/v1/player') {
              resolveGeneration++;
              final decoded = jsonDecode(body) as Map<String, dynamic>;
              final vid = decoded['videoId'].toString();
              if (return140InsteadOf251) {
                return _sendJson(
                  req.response,
                  HttpStatus.ok,
                  _player140Payload(
                    url:
                        'https://rr2.googlevideo.com/videoplayback?id=$vid&itag=140&gen=$resolveGeneration&expire=$expireAt',
                  ),
                );
              }
              return _sendJson(
                req.response,
                HttpStatus.ok,
                _player251Payload(
                  url:
                      'https://rr1.googlevideo.com/videoplayback?id=$vid&itag=251&gen=$resolveGeneration&expire=$expireAt',
                  expireAt: expireAt,
                ),
              );
            }
            return _sendJson(req.response, HttpStatus.notFound, {});
          });
          addTearDown(() => server.close(force: true));

          final store = MemorySecureCredentialStore();
          final spyYtDlp = _SpyYtDlpService(clock: () => now);
          addTearDown(spyYtDlp.dispose);
          final ytm = YouTubeMusicProvider(
            credentialStore: store,
            baseUrl: 'http://127.0.0.1:${server.port}',
            clock: () => now,
            ytDlpService: spyYtDlp,
          );
          final manager = StreamingManager(
            credentialStore: store,
            providers: <String, StreamingProvider>{'youtube_music': ytm},
            clock: () => now,
            ytDlpService: spyYtDlp,
            enableLiveWarmup: false,
          );
          addTearDown(() => manager.disposeAsync());

          final ffiService = FfiAudioService(headless: true);
          ffiService.attachStreamingManager(manager);
          addTearDown(ffiService.dispose);

          // 1) Seed L1 cache for a YouTube Podcast episode (`providerName: 'Podcast'`,
          //    canonical `key.providerId == 'youtube_music'`).
          final podcastTrack = const PodcastEpisode(
            videoId: 'DYptgVvkVLQ',
            showId: 'MPSPPL99',
            title: 'Podcast 403 Recovery',
            showTitle: 'Show',
          ).toTrack();
          final initialPodSpec = await manager.resolveSourceSpecForTrack(
            podcastTrack,
            useL1Cache: true,
          ) as DirectRangeSpec;
          expect(initialPodSpec.key.providerId, equals('youtube_music'));
          expect(initialPodSpec.url, contains('gen=1'));

          // Simulate Rust FFI 403 refresh callback using defensive legacy 'Podcast' provider_id.
          final refreshRespJson =
              await ffiService.handleStreamRefreshRequestJson(
            jsonEncode(<String, dynamic>{
              'provider_id': 'Podcast',
              'track_id': 'DYptgVvkVLQ',
              'quality_key': 'default',
              'failed_url': initialPodSpec.url,
              'status_code': 403,
              'attempt': 1,
              'expected_content_length': initialPodSpec.contentLength,
              'expected_mime_type': initialPodSpec.mimeType,
              'expected_kind': 'direct_range',
            }),
          );
          final refreshResp = jsonDecode(refreshRespJson) as Map<String, dynamic>;
          expect(refreshResp['status'], equals('refreshed'));
          final refreshedSpec = refreshResp['spec'] as Map<String, dynamic>;
          expect(refreshedSpec['url'], contains('gen=2'));
          expect((refreshedSpec['headers'] as Map)['User-Agent'], isNotEmpty);
          expect(refreshedSpec['mime_type'], startsWith('audio/webm'));

          // 2) Offset=0 initial probe 403 recovery (`is_initial_probe: true`) MUST
          //    allow format change (itag 251 -> itag 140) and return `status: 'refreshed'`.
          return140InsteadOf251 = true;
          final probeRefreshJson =
              await ffiService.handleStreamRefreshRequestJson(
            jsonEncode(<String, dynamic>{
              'provider_id': 'youtube_music',
              'track_id': 'DYptgVvkVLQ',
              'quality_key': 'default',
              'failed_url': refreshedSpec['url'],
              'status_code': 403,
              'attempt': 1,
              'expected_content_length': 5200000,
              'expected_mime_type': 'audio/webm; codecs="opus"',
              'expected_kind': 'direct_range',
              'is_initial_probe': true,
            }),
          );
          final probeRefresh =
              jsonDecode(probeRefreshJson) as Map<String, dynamic>;
          expect(probeRefresh['status'], equals('refreshed'));
          expect(
            (probeRefresh['spec'] as Map)['url'],
            contains('itag=140'),
          );
          expect(
            (probeRefresh['spec'] as Map)['mime_type'],
            startsWith('audio/mp4'),
          );

          // 3) Mid-stream 403 (`is_initial_probe` false/omitted) when format drifts
          //    (audio/webm -> audio/mp4) still reports `status: 'format_changed'` with spec.
          const musicKey = StreamKey('youtube_music', 'dQw4w9WgXcQ', 'default');
          return140InsteadOf251 = false;
          final initialMusic =
              await manager.resolveSourceSpec(musicKey) as DirectRangeSpec;
          expect(initialMusic.mimeType, startsWith('audio/webm'));

          return140InsteadOf251 = true;
          final midStreamJson =
              await ffiService.handleStreamRefreshRequestJson(
            jsonEncode(<String, dynamic>{
              'provider_id': 'youtube_music',
              'track_id': 'dQw4w9WgXcQ',
              'quality_key': 'default',
              'failed_url': initialMusic.url,
              'status_code': 403,
              'attempt': 1,
              'expected_content_length': initialMusic.contentLength,
              'expected_mime_type': initialMusic.mimeType,
              'expected_kind': 'direct_range',
              'is_initial_probe': false,
            }),
          );
          final midStream = jsonDecode(midStreamJson) as Map<String, dynamic>;
          expect(midStream['status'], equals('format_changed'));
          expect(midStream['spec'], isNotNull);
          expect((midStream['spec'] as Map)['url'], contains('itag=140'));
        });
      },
    );
  });

  group(
    'Phase 2 Hardening: IPv4, VISIONOS, pot/n integrity, yt-dlp headers/loudness & Podcast routing',
    () {
      test(
        'resolvePreferredIpv4Address prefers IPv4 and createIpv4HttpClient connects over IPv4',
        () async {
          final v4 = await resolvePreferredIpv4Address(
            'example.test',
            ipv4Lookup: (_) async => <InternetAddress>[
              InternetAddress('2001:4860:4860::8888'),
              InternetAddress('142.251.155.4'),
            ],
          );
          expect(v4, isNotNull);
          expect(v4!.type, equals(InternetAddressType.IPv4));
          expect(v4.address, equals('142.251.155.4'));

          // IP literal bypasses DNS lookup directly.
          var lookupCalls = 0;
          final literal = await resolvePreferredIpv4Address(
            '127.0.0.1',
            ipv4Lookup: (_) async {
              lookupCalls++;
              return <InternetAddress>[];
            },
          );
          expect(literal?.address, equals('127.0.0.1'));
          expect(lookupCalls, equals(0));

          // End-to-end HTTP request through createIpv4HttpClient hits IPv4 loopback.
          await _withRealHttp(() async {
            final server = await _startServer((req, body) async {
              return _sendJson(req.response, HttpStatus.ok, <String, dynamic>{
                'ok': true,
              });
            });
            addTearDown(() => server.close(force: true));

            final client = createIpv4HttpClient(
              ipv4Lookup: (_) async => <InternetAddress>[
                InternetAddress.loopbackIPv4,
              ],
            );
            addTearDown(() => client.close(force: true));

            final req = await client.getUrl(
              Uri.parse('http://ipv4-test.local:${server.port}/ping'),
            );
            final resp = await req.close();
            final text = await utf8.decoder.bind(resp).join();
            expect(resp.statusCode, equals(HttpStatus.ok));
            expect(jsonDecode(text), equals(<String, dynamic>{'ok': true}));
          });
        },
      );

      test(
        'VISIONOS leg resolves YouTube Podcast after ANDROID_VR LOGIN_REQUIRED with zero web auth and zero yt-dlp spawns',
        () async {
          final now = DateTime.utc(2026, 11, 24, 6, 0, 0);
          final expireAt = (now.millisecondsSinceEpoch ~/ 1000) + 18000;
          final seenClients = <String>[];
          final visionHeaders = <String, String>{};
          final spyYtDlp = _SpyYtDlpService(clock: () => now);
          addTearDown(spyYtDlp.dispose);

          final resolver = YtmResidentResolver(
            clock: () => now,
            authProvider: () => const YtmAuthCredentials(
              authMode: 'cookie',
              cookie: 'SAPISID=should_never_leak; SID=abc',
            ),
            fallbackResolver: ({
              required key,
              required videoId,
              required auth,
              required gvsToken,
              required playerToken,
              required visitorData,
              cancelToken,
            }) async {
              fail('yt-dlp fallback must NOT be invoked when VISIONOS succeeds');
            },
            requestHandler: ({
              required uri,
              required headers,
              required body,
              cancelToken,
            }) async {
              final clientName =
                  ((body['context'] as Map)['client'] as Map)['clientName']
                      .toString();
              seenClients.add(clientName);
              if (clientName == 'ANDROID_VR') {
                return const YtmPlayerHttpResponse(
                  statusCode: 200,
                  body: '{"playabilityStatus":{"status":"LOGIN_REQUIRED"}}',
                );
              }
              if (clientName == 'VISIONOS') {
                visionHeaders.addAll(headers);
                return YtmPlayerHttpResponse(
                  statusCode: 200,
                  body: jsonEncode(<String, dynamic>{
                    'playabilityStatus': <String, dynamic>{'status': 'OK'},
                    'playerConfig': <String, dynamic>{
                      'audioConfig': <String, dynamic>{'loudnessDb': -2.5},
                    },
                    'streamingData': <String, dynamic>{
                      'expiresInSeconds': '21600',
                      'adaptiveFormats': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'itag': 251,
                          'mimeType': 'audio/webm; codecs="opus"',
                          'bitrate': 160000,
                          'contentLength': '6100000',
                          'audioSampleRate': '48000',
                          'audioChannels': 2,
                          'url':
                              'https://rr2.googlevideo.com/videoplayback?itag=251&c=VISIONOS&expire=$expireAt',
                        },
                      ],
                    },
                  }),
                );
              }
              return const YtmPlayerHttpResponse(statusCode: 404, body: '{}');
            },
          );
          addTearDown(resolver.dispose);

          final spec = await resolver.resolve(
            const StreamKey('youtube_music', 'Lgu9tejOOHQ', 'default'),
          );
          expect(spec, isA<DirectRangeSpec>());
          final direct = spec as DirectRangeSpec;
          expect(seenClients, equals(<String>['ANDROID_VR', 'VISIONOS']));
          expect(spyYtDlp.calls, isEmpty);
          expect(direct.url, contains('c=VISIONOS'));
          expect(direct.headers['User-Agent'], contains('Safari/605.1.15'));
          expect(direct.loudness?.gainDb, closeTo(2.5, 1e-6));

          // Strictly zero web auth leakage on VISIONOS request headers.
          final lowerKeys = visionHeaders.keys.map((k) => k.toLowerCase()).toSet();
          expect(lowerKeys.contains('cookie'), isFalse);
          expect(lowerKeys.contains('authorization'), isFalse);
          expect(lowerKeys.contains('origin'), isFalse);
          expect(lowerKeys.contains('referer'), isFalse);
          expect(visionHeaders['X-YouTube-Client-Name'], equals('101'));
        },
      );

      test(
        'appendPotQueryParam preserves signed query encoding untouched and skips duplicate pot',
        () {
          const signedUrl =
              'https://rr1---sn-test.googlevideo.com/videoplayback?expire=1790000000&sparams=expire%2Cei%2Cip%2Cid%2Caitags&sig=AbC%2B123%3D%3D&itag=251';
          final withPot = YtmResidentResolver.appendPotQueryParam(
            signedUrl,
            'Mn+Token/With=Chars',
          );
          // Every byte before &pot= must remain identical (no re-encoding of %2C / %2B / %3D).
          expect(withPot, startsWith('$signedUrl&pot='));
          expect(
            withPot,
            equals('$signedUrl&pot=${Uri.encodeQueryComponent('Mn+Token/With=Chars')}'),
          );
          // Calling a second time is a no-op because `pot` already exists.
          expect(
            YtmResidentResolver.appendPotQueryParam(withPot, 'SECOND_TOKEN'),
            equals(withPot),
          );
        },
      );

      test(
        'WEB_REMIX rejects undecrypted n-parameter URLs and falls through to yt-dlp + deno',
        () async {
          final now = DateTime.utc(2026, 11, 24, 6, 0, 0);
          final expireAt = (now.millisecondsSinceEpoch ~/ 1000) + 18000;
          var fallbackCalls = 0;

          final resolver = YtmResidentResolver(
            clock: () => now,
            requestHandler: ({
              required uri,
              required headers,
              required body,
              cancelToken,
            }) async {
              final clientName =
                  ((body['context'] as Map)['client'] as Map)['clientName']
                      .toString();
              if (clientName == 'ANDROID_VR' || clientName == 'VISIONOS') {
                return const YtmPlayerHttpResponse(
                  statusCode: 200,
                  body: '{"playabilityStatus":{"status":"LOGIN_REQUIRED"}}',
                );
              }
              return YtmPlayerHttpResponse(
                statusCode: 200,
                body: jsonEncode(<String, dynamic>{
                  'playabilityStatus': <String, dynamic>{'status': 'OK'},
                  'streamingData': <String, dynamic>{
                    'adaptiveFormats': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'itag': 251,
                        'mimeType': 'audio/webm; codecs="opus"',
                        'bitrate': 160000,
                        'url':
                            'https://rr1.googlevideo.com/videoplayback?itag=251&c=WEB_REMIX&n=UNDECRYPTED_N_PARAM&expire=$expireAt',
                      },
                    ],
                  },
                }),
              );
            },
            fallbackResolver: ({
              required key,
              required videoId,
              required auth,
              required gvsToken,
              required playerToken,
              required visitorData,
              cancelToken,
            }) async {
              fallbackCalls++;
              return DirectRangeSpec(
                key: key,
                url:
                    'https://rr9.googlevideo.com/videoplayback?itag=251&n=DECRYPTED_BY_DENO&expire=$expireAt',
                headers: const <String, String>{'User-Agent': 'Chrome/131'},
                mimeType: 'audio/webm',
                hintExtension: 'webm',
                expireAt: expireAt,
              );
            },
          );
          addTearDown(resolver.dispose);

          final spec = await resolver.resolve(
            const StreamKey('youtube_music', 'dQw4w9WgXcQ', 'default'),
          ) as DirectRangeSpec;
          expect(fallbackCalls, equals(1));
          expect(spec.url, contains('n=DECRYPTED_BY_DENO'));
        },
      );

      test(
        'yt-dlp fallback strips Accept-Encoding/Range and propagates loudnessDb with +6.0 dB positive cap',
        () async {
          await _withRealHttp(() async {
            final now = DateTime.utc(2026, 11, 24, 6, 0, 0);
            final expireAt = (now.millisecondsSinceEpoch ~/ 1000) + 18000;

            final server = await _startServer((req, body) async {
              if (req.uri.path == '/youtubei/v1/player') {
                return _sendJson(req.response, HttpStatus.ok, <String, dynamic>{
                  'playabilityStatus': <String, dynamic>{
                    'status': 'LOGIN_REQUIRED',
                  },
                });
              }
              return _sendJson(req.response, HttpStatus.notFound, {});
            });
            addTearDown(() => server.close(force: true));

            final spyYtDlp = _SpyYtDlpService(clock: () => now)
              ..onResolve = (call) async {
                return YtDlpResolvedStream(
                  videoId: call.videoId,
                  url:
                      'https://rr4.googlevideo.com/videoplayback?itag=251&c=WEB_REMIX&expire=$expireAt',
                  httpHeaders: const <String, String>{
                    'User-Agent': 'Mozilla/5.0 Chrome/131.0',
                    'Accept-Encoding': 'gzip, deflate',
                    'Range': 'bytes=0-1023',
                    'Cookie': 'SHOULD_STRIP=1',
                    'Accept-Language': 'en-US',
                  },
                  ext: 'webm',
                  acodec: 'opus',
                  mimeType: 'audio/webm',
                  loudnessDb: -10.0,
                  expiresAt: DateTime.fromMillisecondsSinceEpoch(
                    expireAt * 1000,
                    isUtc: true,
                  ),
                );
              };
            addTearDown(spyYtDlp.dispose);

            final provider = YouTubeMusicProvider(
              credentialStore: MemorySecureCredentialStore(),
              baseUrl: 'http://127.0.0.1:${server.port}',
              clock: () => now,
              ytDlpService: spyYtDlp,
            );
            addTearDown(() => provider.disposeAsync());

            final spec = await provider.resolve(
              const StreamKey('youtube_music', 'dQw4w9WgXcQ', 'default'),
            ) as DirectRangeSpec;

            final lowerHeaders = spec.headers.keys
                .map((k) => k.toLowerCase())
                .toSet();
            expect(lowerHeaders.contains('accept-encoding'), isFalse);
            expect(lowerHeaders.contains('range'), isFalse);
            expect(lowerHeaders.contains('cookie'), isFalse);
            expect(spec.headers['User-Agent'], equals('Mozilla/5.0 Chrome/131.0'));
            expect(spec.headers['Accept-Language'], equals('en-US'));
            // -10.0 loudnessDb requests +10 dB gain, safely clamped to +6.0 dB.
            expect(spec.loudness, isNotNull);
            expect(spec.loudness!.gainDb, closeTo(6.0, 1e-6));
          });

          // Verify NormalizedLoudness gain clamps directly across sources.
          expect(
            NormalizedLoudness.fromYtmLoudnessDb(-12.0).gainDb,
            closeTo(6.0, 1e-6),
          );
          expect(
            NormalizedLoudness.fromYtmLoudnessDb(3.5).gainDb,
            closeTo(-3.5, 1e-6),
          );
          expect(
            NormalizedLoudness.fromReplayGain(5.0).gainDb,
            closeTo(6.0, 1e-6),
          );
          expect(
            NormalizedLoudness.fromJson(const <String, dynamic>{
              'gain_db': 11.5,
              'peak': 0.98,
            }).gainDb,
            closeTo(6.0, 1e-6),
          );
        },
      );

      test(
        'External RSS podcast episodes are NOT treated as external Apple Music handoff and use canonical track IDs',
        () async {
          const rssEpisode = PodcastEpisode(
            videoId: 'rss-ep-42',
            showId: 'rss:https://feeds.example.com/show.xml',
            title: 'External RSS Episode',
            showTitle: 'Indie Podcast',
            audioUrl: 'https://cdn.example.com/episodes/ep42.mp3',
          );
          const ytEpisode = PodcastEpisode(
            videoId: 'Lgu9tejOOHQ',
            showId: 'MPSPPL123',
            title: 'YouTube Podcast Episode',
            showTitle: 'YT Show',
          );

          final rssTrack = rssEpisode.toTrack();
          final ytTrack = ytEpisode.toTrack();
          expect(
            rssTrack.id,
            equals('podcast_rss:https://cdn.example.com/episodes/ep42.mp3'),
          );
          expect(ytTrack.id, equals('ytm:Lgu9tejOOHQ'));

          // Verify PodcastStore progress keyed by tracker (`track.id`) is found
          // when UI queries `progressFor(episode.toTrack().id)`.
          final podcastStore = PodcastStore();
          addTearDown(podcastStore.dispose);
          podcastStore.updateProgress(
            videoId: PodcastStore.normalizeVideoId(rssTrack.id),
            position: const Duration(seconds: 120),
            duration: const Duration(seconds: 600),
            immediate: true,
          );
          expect(podcastStore.progressFor(rssTrack.id)?.positionSeconds, equals(120));
          expect(podcastStore.progressFor(rssEpisode.videoId), isNull);

          final mockAudio = MockAudioService();
          final manager = StreamingManager(
            credentialStore: MemorySecureCredentialStore(),
            enableLiveWarmup: false,
          );
          final coordinator = StreamingPlaybackCoordinator(
            audioService: mockAudio,
            streamingManager: manager,
          );
          addTearDown(() async {
            coordinator.dispose();
            await manager.disposeAsync();
            mockAudio.dispose();
          });

          expect(coordinator.isExternalTrackForTesting(rssTrack), isFalse);
          expect(coordinator.isExternalTrackForTesting(ytTrack), isFalse);
        },
      );
    },
  );
}
