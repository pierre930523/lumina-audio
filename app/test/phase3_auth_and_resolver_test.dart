import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/stream_source_spec.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/models/streaming_provider_meta.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/streaming/auth_manager.dart';
import 'package:lumina_app/services/streaming/l1_stream_cache.dart';
import 'package:lumina_app/services/streaming/pot_provider.dart';
import 'package:lumina_app/services/streaming/providers/deezer_provider.dart';
import 'package:lumina_app/services/streaming/providers/tidal_provider.dart';
import 'package:lumina_app/services/streaming/providers/youtube_music_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/single_flight_resolver.dart';
import 'package:lumina_app/services/streaming/stream_resolver.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';
import 'package:lumina_app/services/streaming/streaming_provider.dart';
import 'package:lumina_app/services/streaming/ytm_resident_resolver.dart';
import 'package:lumina_app/ui/settings/providers_and_remote_panel.dart';
import 'package:lumina_app/ui/streaming/streaming_service_view.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

class _TrackingPotProvider implements PotProvider {
  int invalidateCalls = 0;
  int disposeCalls = 0;
  final Completer<void> disposeGate = Completer<void>();
  bool blockDisposeUntilGate = false;

  @override
  Future<PoToken?> getGvsToken({
    required String sessionBinding,
    CancellationToken? cancelToken,
  }) async {
    return PoToken(
      token: 'gvs_tok_1',
      scope: PoTokenScope.gvs,
      bindingKey: sessionBinding,
      mintedAt: DateTime.now(),
      expiresAt: DateTime.now().add(const Duration(hours: 6)),
    );
  }

  @override
  Future<PoToken?> getPlayerToken({
    required String videoId,
    CancellationToken? cancelToken,
  }) async {
    return PoToken(
      token: 'player_tok_$videoId',
      scope: PoTokenScope.player,
      bindingKey: videoId,
      mintedAt: DateTime.now(),
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
  }

  @override
  void invalidateSession() {
    invalidateCalls++;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    if (blockDisposeUntilGate) {
      await disposeGate.future;
    }
  }
}

class _ControllableAuthProvider extends BaseStreamingProvider
    implements StreamResolver {
  @override
  final String kind;
  @override
  final ProviderCapabilities capabilities;
  final bool silentRefreshEnabled;

  Future<void> Function({bool force})? onRefresh;
  Future<StreamSourceSpec> Function(StreamKey key, CancellationToken? cancel)?
      onResolve;

  int refreshCalls = 0;
  int resolveCalls = 0;

  _ControllableAuthProvider({
    required this.kind,
    required this.capabilities,
    required super.credentialStore,
    this.silentRefreshEnabled = false,
    this.onRefresh,
    this.onResolve,
  }) {
    setConnected(
      StreamingAccountInfo(
        displayName: 'Test $kind User',
        planTier: 'HiFi',
      ),
    );
  }

  @override
  String get providerId => kind;

  @override
  bool get supportsSilentRefresh => silentRefreshEnabled;

  @override
  Future<void> forceRefreshSession() => refreshSessionIfNeeded(force: true);

  @override
  Future<void> restoreFromStorage() async {}

  @override
  Future<void> authenticate(
    Map<String, dynamic> params, {
    CancellationToken? cancel,
    void Function(String statusMsg)? onProgress,
  }) async {
    setConnected(
      StreamingAccountInfo(
        displayName: 'Re-logged $kind User',
        planTier: 'HiFi',
      ),
    );
  }

  @override
  Future<void> refreshSessionIfNeeded({bool force = false}) async {
    refreshCalls++;
    if (onRefresh != null) {
      await onRefresh!(force: force);
    }
  }

  @override
  Future<void> logout() async {
    resetState();
  }

  @override
  Future<StreamingCatalog> syncLibrary({CancellationToken? cancel}) async =>
      StreamingCatalog.empty();

  @override
  Future<List<TrackInfo>> fetchPlaylistTracks(String playlistId) async =>
      const <TrackInfo>[];

  @override
  Future<StreamingCatalog> search(
    String query, {
    CancellationToken? cancel,
  }) async => StreamingCatalog.empty();

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) async {
    resolveCalls++;
    if (onResolve != null) {
      return onResolve!(key, cancelToken);
    }
    final exp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
    return DirectRangeSpec(
      key: key,
      url: 'https://cdn.example.com/$kind/${key.trackId}.flac?exp=$exp',
      contentLength: 1000000,
      mimeType: 'audio/flac',
      expireAt: exp,
    );
  }

  @override
  Future<ResolvedStreamResult> resolveStream(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
  }) async {
    final spec = await resolve(
      StreamKey(kind, BaseStreamingProvider.stripTrackPrefix(track.id, kind), 'default'),
      cancelToken: cancel,
    );
    final url = switch (spec) {
      DirectRangeSpec() => spec.url,
      EncryptedRangeSpec() => spec.url,
      _ => '',
    };
    return ResolvedStreamResult(
      url: url,
      format: track.format,
    );
  }
}

TrackInfo _streamingTrack(String providerKind, String trackId) {
  final meta = StreamingProviderMeta.byKind(providerKind)!;
  return TrackInfo(
    id: '$providerKind:$trackId',
    title: 'Track $trackId',
    artist: 'Artist',
    album: 'Album',
    duration: const Duration(seconds: 180),
    format: const AudioFormat(
      codec: AudioCodec.flac,
      sampleRateHz: 44100,
      bitDepth: 16,
      channels: 2,
    ),
    providerName: meta.name,
  );
}

void main() {
  group('Phase 3.1: AuthManager Single-Flight Refresh & Strict 401 Circuit Breaker', () {
    test(
      'deduplicates concurrent 401 refreshes on Tidal into exactly 1 /v1/oauth2/token call and retries once',
      () async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = prevOverrides);

        final store = MemorySecureCredentialStore();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final base = 'http://127.0.0.1:${server.port}';

        var refreshRequests = 0;
        final refreshGate = Completer<void>();

        server.listen((req) async {
          final path = req.uri.path;
          if (path == '/v1/oauth2/token') {
            refreshRequests++;
            await refreshGate.future;
            req.response.statusCode = 200;
            req.response.headers.contentType = ContentType.json;
            req.response.write(
              jsonEncode(<String, dynamic>{
                'access_token': 'tidal_fresh_tok_v2',
                'refresh_token': 'tidal_ref_v2',
                'expires_in': 3600,
              }),
            );
            await req.response.close();
            return;
          }
          if (path == '/v1/sessions') {
            req.response.statusCode = 200;
            req.response.headers.contentType = ContentType.json;
            req.response.write(
              jsonEncode(<String, dynamic>{
                'userId': 123,
                'countryCode': 'US',
              }),
            );
            await req.response.close();
            return;
          }
          if (path == '/v1/users/123') {
            req.response.statusCode = 200;
            req.response.headers.contentType = ContentType.json;
            req.response.write(
              jsonEncode(<String, dynamic>{
                'id': 123,
                'username': 'tidal_tester',
                'countryCode': 'US',
              }),
            );
            await req.response.close();
            return;
          }
          if (path == '/v1/users/123/subscription') {
            req.response.statusCode = 200;
            req.response.headers.contentType = ContentType.json;
            req.response.write(
              jsonEncode(<String, dynamic>{
                'subscription': <String, dynamic>{'type': 'HIFI_PLUS'},
                'highestSoundQuality': 'HI_RES_LOSSLESS',
              }),
            );
            await req.response.close();
            return;
          }
          if (path.startsWith('/v1/tracks/') &&
              path.endsWith('/playbackinfopostpaywall')) {
            final auth = req.headers.value('authorization') ?? '';
            if (auth == 'Bearer tidal_stale_tok_v1') {
              req.response.statusCode = 401;
              req.response.headers.contentType = ContentType.json;
              req.response.write(
                jsonEncode(<String, dynamic>{'userMessage': 'Token expired'}),
              );
              await req.response.close();
              return;
            }
            final trackId = path.split('/')[3];
            final bts = base64Encode(
              utf8.encode(
                jsonEncode(<String, dynamic>{
                  'mimeType': 'audio/flac',
                  'codecs': 'flac',
                  'encryptionType': 'NONE',
                  'urls': <String>[
                    'https://sp-cf.tidal.com/$trackId-refreshed.flac?Expires=1999999999',
                  ],
                }),
              ),
            );
            req.response.statusCode = 200;
            req.response.headers.contentType = ContentType.json;
            req.response.write(
              jsonEncode(<String, dynamic>{
                'audioQuality': 'LOSSLESS',
                'sampleRate': 44100,
                'bitDepth': 16,
                'trackReplayGain': -6.5,
                'trackPeakAmplitude': 0.91,
                'albumReplayGain': -5.0,
                'albumPeakAmplitude': 0.96,
                'manifestMimeType': 'application/vnd.tidal.bts',
                'manifest': bts,
              }),
            );
            await req.response.close();
            return;
          }
          req.response.statusCode = 404;
          await req.response.close();
        });

        final tidal = TidalProvider(
          credentialStore: store,
          authBaseUrl: base,
          tokenBaseUrl: base,
          apiBaseUrl: '$base/v1',
        );
        await tidal.authenticate(<String, dynamic>{
          'mode': 'access_token',
          'access_token': 'tidal_stale_tok_v1',
          'refresh_token': 'tidal_ref_v1',
          'client_id': 'cid',
        });
        expect(tidal.supportsSilentRefresh, isTrue);

        final manager = StreamingManager(
          credentialStore: store,
          providers: <String, StreamingProvider>{'tidal': tidal},
          enableLiveWarmup: false,
        );
        addTearDown(() => manager.disposeAsync());

        // Fire two distinct tracks concurrently against the stale access token.
        final f1 = manager.resolveSourceSpec(
          const StreamKey('tidal', '101', 'LOSSLESS'),
        );
        final f2 = manager.resolveSourceSpec(
          const StreamKey('tidal', '102', 'LOSSLESS'),
        );

        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(refreshRequests, equals(1));
        refreshGate.complete();

        final specs = await Future.wait<StreamSourceSpec>(<Future<StreamSourceSpec>>[
          f1,
          f2,
        ]);
        expect(refreshRequests, equals(1));
        expect(manager.isAuthRequired('tidal'), isFalse);

        final spec1 = specs[0] as DirectRangeSpec;
        final spec2 = specs[1] as DirectRangeSpec;
        expect(spec1.url, contains('101-refreshed.flac'));
        expect(spec2.url, contains('102-refreshed.flac'));
        expect(spec1.loudness, isNotNull);
        expect(spec1.loudness!.gainDb, closeTo(-2.5, 1e-6));
        expect(spec1.loudness!.peak, closeTo(0.91, 1e-6));
        expect(spec1.albumLoudness, isNotNull);
        expect(spec1.albumLoudness!.gainDb, closeTo(-1.0, 1e-6));
        expect(spec1.albumLoudness!.peak, closeTo(0.96, 1e-6));
      },
    );

    test(
      'non-refreshable 401 trips AuthRequired circuit breaker, cancels in-flight/prefetch for that provider only, blocks retries, and clears on re-login',
      () async {
        final store = MemorySecureCredentialStore();
        final inFlightGate = Completer<void>();

        final qobuz = _ControllableAuthProvider(
          kind: 'qobuz',
          capabilities: ProviderCapabilities.qobuz,
          credentialStore: store,
          silentRefreshEnabled: false,
          onResolve: (key, cancel) async {
            if (key.trackId == 'slow_in_flight') {
              final c = Completer<StreamSourceSpec>();
              cancel?.addListener(() {
                if (!c.isCompleted) {
                  c.completeError(
                    const StreamingException('cancelled', isCancelled: true),
                  );
                }
              });
              inFlightGate.future.then((_) {
                if (!c.isCompleted) {
                  c.complete(
                    DirectRangeSpec(
                      key: key,
                      url: 'https://cdn.qobuz.com/slow.flac',
                    ),
                  );
                }
              });
              return c.future;
            }
            throw const StreamingException(
              'Qobuz 授權已失效（HTTP 401）',
              statusCode: 401,
              isTokenExpired: true,
            );
          },
        );

        final tidal = _ControllableAuthProvider(
          kind: 'tidal',
          capabilities: ProviderCapabilities.tidal,
          credentialStore: store,
          silentRefreshEnabled: false,
        );

        final manager = StreamingManager(
          credentialStore: store,
          providers: <String, StreamingProvider>{
            'qobuz': qobuz,
            'tidal': tidal,
          },
          enableLiveWarmup: false,
        );
        addTearDown(() => manager.disposeAsync());

        final audioService = MockAudioService();
        addTearDown(audioService.dispose);
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audioService,
          streamingManager: manager,
          useResolverPipeline: true,
          debounceDelay: Duration.zero,
        );
        addTearDown(coordinator.dispose);

        // Pre-populate L1 cache for both providers.
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        manager.l1Cache.put(
          DirectRangeSpec(
            key: const StreamKey('qobuz', 'cached_1', 'default'),
            url: 'https://cdn.qobuz.com/cached_1.flac',
            expireAt: nowSec + 3600,
          ),
          ProviderCapabilities.qobuz,
        );
        manager.l1Cache.put(
          DirectRangeSpec(
            key: const StreamKey('tidal', 'cached_t1', 'default'),
            url: 'https://cdn.tidal.com/cached_t1.flac',
            expireAt: nowSec + 3600,
          ),
          ProviderCapabilities.tidal,
        );

        final authRequiredEvents = <String>[];
        manager.addAuthRequiredListener((pid, _) => authRequiredEvents.add(pid));

        // Start a slow in-flight resolve on Qobuz and attach expectation BEFORE
        // triggering cancellation so the async error is captured cleanly.
        final slowFuture = manager.resolveSourceSpec(
          const StreamKey('qobuz', 'slow_in_flight', 'default'),
        );
        final slowExpect = expectLater(
          slowFuture,
          throwsA(
            isA<StreamingException>()
                .having((e) => e.isCancelled, 'isCancelled', isTrue),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(manager.singleFlightResolver.inFlightCount, equals(1));

        // Trigger a 401 on another Qobuz track.
        await expectLater(
          manager.resolveSourceSpec(
            const StreamKey('qobuz', 'expired_track', 'default'),
          ),
          throwsA(
            isA<StreamingException>().having((e) => e.statusCode, 'statusCode', 401),
          ),
        );

        // Slow in-flight Qobuz resolution was cancelled automatically.
        await slowExpect;

        // Circuit breaker assertions.
        expect(manager.isAuthRequired('qobuz'), isTrue);
        expect(qobuz.authState, equals(StreamingAuthState.authRequired));
        expect(authRequiredEvents, equals(<String>['qobuz']));
        // Qobuz L1 cleared; Tidal L1 & auth state completely unaffected.
        expect(
          manager.peekCachedSpec(const StreamKey('qobuz', 'cached_1', 'default')),
          isNull,
        );
        expect(
          manager.peekCachedSpec(const StreamKey('tidal', 'cached_t1', 'default')),
          isNotNull,
        );
        expect(manager.isAuthRequired('tidal'), isFalse);

        // Subsequent resolve & prefetch calls for Qobuz MUST NOT hit provider (0 retries).
        final callsBefore = qobuz.resolveCalls;
        final qTrack = _streamingTrack('qobuz', 'next_99');
        expect(coordinator.canPrefetchTrack(qTrack), isFalse);
        await coordinator.prefetchTrack(qTrack);
        coordinator.requestHoverPrefetch(qTrack);
        expect(
          await manager.prefetchSourceSpec(
            const StreamKey('qobuz', 'next_99', 'default'),
          ),
          isNull,
        );
        await expectLater(
          manager.resolveSourceSpec(
            const StreamKey('qobuz', 'next_99', 'default'),
          ),
          throwsA(
            isA<StreamingException>().having((e) => e.statusCode, 'statusCode', 401),
          ),
        );
        expect(qobuz.resolveCalls, equals(callsBefore));

        // Re-login clears AuthRequired and restores prefetch & resolution.
        qobuz.onResolve = null;
        await manager.authenticateProvider('qobuz', const <String, dynamic>{});
        expect(manager.isAuthRequired('qobuz'), isFalse);
        expect(qobuz.authState, equals(StreamingAuthState.connected));
        expect(coordinator.canPrefetchTrack(qTrack), isTrue);
        final recovered = await manager.resolveSourceSpec(
          const StreamKey('qobuz', 'next_99', 'default'),
        );
        expect(recovered, isA<DirectRangeSpec>());
      },
    );

    test(
      'Deezer ARL refreshes stale api_token on 401 once, parses GAIN loudness, and trips AuthRequired without preview fallback when USER_ID == 0',
      () async {
        final prevOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = prevOverrides);

        final store = MemorySecureCredentialStore();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final base = 'http://127.0.0.1:${server.port}';

        var userDataCalls = 0;
        var arlRevoked = false;

        server.listen((req) async {
          final path = req.uri.path;
          final method = req.uri.queryParameters['method'];
          if (path == '/gw' && method == 'deezer.getUserData') {
            userDataCalls++;
            req.response.statusCode = 200;
            req.response.headers.contentType = ContentType.json;
            if (arlRevoked) {
              req.response.write(
                jsonEncode(<String, dynamic>{
                  'error': <dynamic>[],
                  'results': <String, dynamic>{
                    'USER': <String, dynamic>{'USER_ID': 0},
                  },
                }),
              );
            } else {
              req.response.write(
                jsonEncode(<String, dynamic>{
                  'error': <dynamic>[],
                  'results': <String, dynamic>{
                    'checkForm': 'csrf_v$userDataCalls',
                    'OFFER_NAME': 'Deezer HiFi',
                    'USER': <String, dynamic>{
                      'USER_ID': 9988,
                      'BLOG_NAME': 'DZ User',
                      'OPTIONS': <String, dynamic>{
                        'web_lossless': true,
                        'web_hq': true,
                        'license_token': 'lic_v$userDataCalls',
                      },
                    },
                  },
                }),
              );
            }
            await req.response.close();
            return;
          }
          if (path == '/gw' && method == 'song.getData') {
            final apiToken = req.uri.queryParameters['api_token'];
            req.response.statusCode = 200;
            req.response.headers.contentType = ContentType.json;
            if (apiToken == 'csrf_v1') {
              // Stale CSRF token on first call -> triggers single-flight ARL refresh.
              req.response.write(
                jsonEncode(<String, dynamic>{
                  'error': <String, dynamic>{
                    'VALID_TOKEN_REQUIRED': 'Invalid CSRF token',
                  },
                }),
              );
            } else {
              req.response.write(
                jsonEncode(<String, dynamic>{
                  'error': <dynamic>[],
                  'results': <String, dynamic>{
                    'TRACK_TOKEN': 'trk_tok_ok',
                    'GAIN': '-4.2',
                  },
                }),
              );
            }
            await req.response.close();
            return;
          }
          if (path == '/v1/get_url') {
            if (arlRevoked) {
              req.response.statusCode = 401;
              req.response.headers.contentType = ContentType.json;
              req.response.write(
                jsonEncode(<String, dynamic>{'message': 'License expired'}),
              );
              await req.response.close();
              return;
            }
            req.response.statusCode = 200;
            req.response.headers.contentType = ContentType.json;
            req.response.write(
              jsonEncode(<String, dynamic>{
                'data': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'media': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'format': 'FLAC',
                        'exp': 1999999999,
                        'sources': <Map<String, dynamic>>[
                          <String, dynamic>{
                            'url': 'https://e-cdns.dzcdn.net/stream/777.flac',
                          },
                        ],
                      },
                    ],
                  },
                ],
              }),
            );
            await req.response.close();
            return;
          }
          req.response.statusCode = 404;
          await req.response.close();
        });

        final deezer = DeezerProvider(
          credentialStore: store,
          gwUrl: '$base/gw',
          apiBaseUrl: base,
          mediaBaseUrl: '$base/v1/get_url',
        );
        await deezer.authenticate(<String, dynamic>{
          'mode': 'arl',
          'arl': 'a' * 64,
        });
        expect(deezer.supportsSilentRefresh, isTrue);
        expect(userDataCalls, equals(1));

        final manager = StreamingManager(
          credentialStore: store,
          providers: <String, StreamingProvider>{'deezer': deezer},
          enableLiveWarmup: false,
        );
        addTearDown(() => manager.disposeAsync());

        // Stale api_token triggers single-flight refresh (userDataCalls: 1 -> 2) and succeeds.
        final spec = await manager.resolveSourceSpec(
          const StreamKey('deezer', '777', 'FLAC'),
        );
        expect(userDataCalls, equals(2));
        expect(spec, isA<EncryptedRangeSpec>());
        final enc = spec as EncryptedRangeSpec;
        expect(enc.loudness, isNotNull);
        expect(enc.loudness!.gainDb, closeTo(-3.2, 1e-6));
        expect(enc.loudness!.peak, closeTo(1.0, 1e-6));

        // Now revoke ARL -> media endpoint returns 401 -> refresh sees USER_ID == 0 ->
        // MUST NOT silently downgrade to preview, MUST trip AuthRequired!
        arlRevoked = true;
        await expectLater(
          manager.resolveSourceSpec(
            const StreamKey('deezer', '778', 'FLAC'),
          ),
          throwsA(
            isA<StreamingException>().having((e) => e.statusCode, 'statusCode', 401),
          ),
        );
        expect(manager.isAuthRequired('deezer'), isTrue);
        expect(deezer.authState, equals(StreamingAuthState.authRequired));
      },
    );

    test(
      'AuthManager strict 401 vs 403/410 classification and failed silent refresh trips AuthRequired after single attempt',
      () async {
        expect(
          AuthManager.isUnauthorizedError(
            const StreamingException('Unauthorized', statusCode: 401),
          ),
          isTrue,
        );
        expect(
          AuthManager.isUnauthorizedError(
            const StreamingException('Expired', isTokenExpired: true),
          ),
          isTrue,
        );
        expect(
          AuthManager.isUnauthorizedError(
            const StreamingException('Forbidden', statusCode: 403),
          ),
          isFalse,
        );
        expect(
          AuthManager.isUnauthorizedError(
            const StreamingException('Gone', statusCode: 410),
          ),
          isFalse,
        );

        final store = MemorySecureCredentialStore();
        final refreshGate = Completer<void>();
        final tidal = _ControllableAuthProvider(
          kind: 'tidal',
          capabilities: ProviderCapabilities.tidal,
          credentialStore: store,
          silentRefreshEnabled: true,
          onRefresh: ({bool force = false}) async {
            await refreshGate.future;
            throw const StreamingException(
              'refresh_token revoked',
              statusCode: 401,
              isTokenExpired: true,
            );
          },
        );
        final manager = StreamingManager(
          credentialStore: store,
          providers: <String, StreamingProvider>{'tidal': tidal},
          enableLiveWarmup: false,
        );
        addTearDown(() => manager.disposeAsync());

        // Concurrent handleUnauthorized calls share 1 failed refresh and trip AuthRequired.
        final h1 = manager.authManager.handleUnauthorized('tidal', 'HTTP 401');
        final h2 = manager.authManager.handleUnauthorized('tidal', 'HTTP 401');
        await Future<void>.delayed(Duration.zero);
        expect(tidal.refreshCalls, equals(1));
        expect(manager.authManager.isRefreshInFlight('tidal'), isTrue);
        refreshGate.complete();

        final outcomes = await Future.wait<bool>(<Future<bool>>[h1, h2]);
        expect(outcomes, equals(<bool>[false, false]));
        expect(tidal.refreshCalls, equals(1));
        expect(manager.isAuthRequired('tidal'), isTrue);
        expect(tidal.authState, equals(StreamingAuthState.authRequired));
      },
    );
  });

  group('Phase 3.2: refreshAfter403 CAS, Strict 401 vs 403 Split & STREAM_FORMAT_CHANGED', () {
    test(
      'CAS preserves newer cached URL without evicting, coalesces concurrent 403s, detects STREAM_FORMAT_CHANGED, and never trips AuthRequired on 403',
      () async {
        final store = MemorySecureCredentialStore();
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        var version = 1;
        var nextContentLength = 5000000;
        var nextMime = 'audio/flac';
        var return403Error = false;
        var return401Error = false;

        final qobuz = _ControllableAuthProvider(
          kind: 'qobuz',
          capabilities: ProviderCapabilities.qobuz,
          credentialStore: store,
          onResolve: (key, cancel) async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            if (return401Error) {
              throw const StreamingException(
                'HTTP 401 Unauthorized',
                statusCode: 401,
                isTokenExpired: true,
              );
            }
            if (return403Error) {
              throw const StreamingException(
                'HTTP 403 Forbidden',
                statusCode: 403,
                isTokenExpired: false,
              );
            }
            final v = ++version;
            return DirectRangeSpec(
              key: key,
              url: 'https://cdn.qobuz.com/${key.trackId}_v$v.flac',
              contentLength: nextContentLength,
              mimeType: nextMime,
              expireAt: nowSec + 3600,
              audioFormat: const AudioFormat(
                codec: AudioCodec.flac,
                sampleRateHz: 96000,
                bitDepth: 24,
                channels: 2,
              ),
            );
          },
        );

        final manager = StreamingManager(
          credentialStore: store,
          providers: <String, StreamingProvider>{'qobuz': qobuz},
          enableLiveWarmup: false,
        );
        addTearDown(() => manager.disposeAsync());

        const key = StreamKey('qobuz', 'track_42', '24_96');
        const initialUrl = 'https://cdn.qobuz.com/track_42_v1.flac';
        manager.l1Cache.put(
          DirectRangeSpec(
            key: key,
            url: initialUrl,
            contentLength: 5000000,
            mimeType: 'audio/flac',
            expireAt: nowSec + 3600,
            audioFormat: const AudioFormat(
              codec: AudioCodec.flac,
              sampleRateHz: 96000,
              bitDepth: 24,
              channels: 2,
            ),
          ),
          ProviderCapabilities.qobuz,
        );

        // 1. Two concurrent refreshAfter403 calls for initialUrl coalesce into 1 upstream resolve.
        final results = await Future.wait<RefreshAfter403Result>(
          <Future<RefreshAfter403Result>>[
            manager.refreshAfter403(
              key,
              failedUrl: initialUrl,
              expectedContentLength: 5000000,
              expectedMimeType: 'audio/flac',
            ),
            manager.refreshAfter403(
              key,
              failedUrl: initialUrl,
              expectedContentLength: 5000000,
              expectedMimeType: 'audio/flac',
            ),
          ],
        );
        expect(qobuz.resolveCalls, equals(1));
        expect(results[0], isA<RefreshAfter403Updated>());
        expect(results[1], isA<RefreshAfter403Updated>());
        final refreshedUrl =
            ((results[0] as RefreshAfter403Updated).spec as DirectRangeSpec).url;
        expect(refreshedUrl, equals('https://cdn.qobuz.com/track_42_v2.flac'));

        // 2. Late stale 403 for initialUrl sees cached.url == v2 != v1 -> CAS does NOT evict,
        //    reuses cached v2 immediately with 0 extra network calls!
        final lateCas = await manager.refreshAfter403(
          key,
          failedUrl: initialUrl,
          expectedContentLength: 5000000,
          expectedMimeType: 'audio/flac',
        );
        expect(qobuz.resolveCalls, equals(1));
        expect(lateCas, isA<RefreshAfter403Updated>());
        expect((lateCas as RefreshAfter403Updated).reusedFromCache, isTrue);
        expect((lateCas.spec as DirectRangeSpec).url, equals(refreshedUrl));

        // 3. Re-resolve returning changed content_length emits STREAM_FORMAT_CHANGED.
        nextContentLength = 4800000;
        final drift = await manager.refreshAfter403(
          key,
          failedUrl: refreshedUrl,
          expectedContentLength: 5000000,
          expectedMimeType: 'audio/flac',
        );
        expect(drift, isA<RefreshAfter403FormatChanged>());
        expect(RefreshAfter403FormatChanged.code, equals('STREAM_FORMAT_CHANGED'));
        expect(
          (drift as RefreshAfter403FormatChanged).reason,
          contains('content_length'),
        );

        // 4. HTTP 403 failure during re-resolve NEVER trips AuthRequired!
        final latestUrl = (drift.spec as DirectRangeSpec).url;
        return403Error = true;
        final fail403 = await manager.refreshAfter403(
          key,
          failedUrl: latestUrl,
        );
        expect(fail403, isA<RefreshAfter403Failed>());
        expect((fail403 as RefreshAfter403Failed).statusCode, equals(403));
        expect(manager.isAuthRequired('qobuz'), isFalse);

        // 5. HTTP 401 failure during re-resolve DOES trip AuthRequired!
        return403Error = false;
        return401Error = true;
        final fail401 = await manager.refreshAfter403(
          key,
          failedUrl: latestUrl,
        );
        expect(fail401, isA<RefreshAfter403AuthRequired>());
        expect(manager.isAuthRequired('qobuz'), isTrue);
      },
    );
  });

  group('Phase 3.3: Network Epoch Reset Isolation, YTM Loudness, 401 Propagation & Clean Shutdown', () {
    test(
      'handleNetworkEpochChanged invalidates only YTM L1 + resets YTM HttpClient/GVS PO Token while preserving Qobuz/Tidal/Deezer',
      () async {
        final store = MemorySecureCredentialStore();
        final pot = _TrackingPotProvider();
        final ytmResolver = YtmResidentResolver(
          potProvider: pot,
          ownsPotProvider: true,
          requestHandler: ({
            required uri,
            required headers,
            required body,
            cancelToken,
          }) async {
            return YtmPlayerHttpResponse(
              statusCode: 200,
              body: jsonEncode(<String, dynamic>{
                'playabilityStatus': <String, dynamic>{'status': 'OK'},
                'playerConfig': <String, dynamic>{
                  'audioConfig': <String, dynamic>{'loudnessDb': 3.5},
                },
                'streamingData': <String, dynamic>{
                  'expiresInSeconds': '21600',
                  'adaptiveFormats': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'itag': 251,
                      'mimeType': 'audio/webm; codecs="opus"',
                      'bitrate': 160000,
                      'contentLength': '3456789',
                      'url':
                          'https://rr1---sn-test.googlevideo.com/videoplayback?expire=1999999999',
                    },
                  ],
                },
              }),
            );
          },
        );

        final ytm = YouTubeMusicProvider(
          credentialStore: store,
          residentResolver: ytmResolver,
        );
        final manager = StreamingManager(
          credentialStore: store,
          providers: <String, StreamingProvider>{'youtube_music': ytm},
          enableLiveWarmup: false,
        );
        addTearDown(() async {
          await manager.disposeAsync();
          await ytmResolver.disposeAsync();
        });

        // Resolve YTM track and verify NormalizedLoudness from loudnessDb (+3.5 -> -3.5 dB).
        const ytmKey = StreamKey('youtube_music', 'dQw4w9WgXcQ', 'default');
        final ytmSpec =
            await manager.resolveSourceSpec(ytmKey) as DirectRangeSpec;
        expect(ytmSpec.loudness, isNotNull);
        expect(ytmSpec.loudness!.gainDb, closeTo(-3.5, 1e-6));
        expect(ytmSpec.loudness!.peak, closeTo(1.0, 1e-6));

        // Populate Qobuz, Tidal, Deezer L1 entries alongside YTM.
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        const qKey = StreamKey('qobuz', 'q1', 'default');
        const tKey = StreamKey('tidal', 't1', 'default');
        const dKey = StreamKey('deezer', 'd1', 'default');
        manager.l1Cache.put(
          DirectRangeSpec(
            key: qKey,
            url: 'https://cdn.qobuz.com/q1.flac',
            expireAt: nowSec + 3600,
          ),
          ProviderCapabilities.qobuz,
        );
        manager.l1Cache.put(
          DirectRangeSpec(
            key: tKey,
            url: 'https://cdn.tidal.com/t1.flac',
            expireAt: nowSec + 3600,
          ),
          ProviderCapabilities.tidal,
        );
        manager.l1Cache.put(
          EncryptedRangeSpec(
            key: dKey,
            url: 'https://cdn.deezer.com/d1.flac',
            cipher: const DeezerBlowfishCipher(trackId: 'd1'),
            expireAt: nowSec + 3600,
          ),
          ProviderCapabilities.deezer,
        );

        final oldClient = ytmResolver.httpClient;
        manager.handleNetworkEpochChanged(2);

        expect(manager.l1Cache.networkEpoch, equals(2));
        expect(identical(ytmResolver.httpClient, oldClient), isFalse);
        expect(pot.invalidateCalls, equals(1));

        // YTM L1 invalidated; Qobuz/Tidal/Deezer survive intact!
        expect(
          manager.l1Cache.get(ytmKey, ProviderCapabilities.youtubeMusic),
          isNull,
        );
        expect(manager.l1Cache.get(qKey, ProviderCapabilities.qobuz), isNotNull);
        expect(manager.l1Cache.get(tKey, ProviderCapabilities.tidal), isNotNull);
        expect(manager.l1Cache.get(dKey, ProviderCapabilities.deezer), isNotNull);
      },
    );

    test(
      'YtmResidentResolver propagates HTTP 401 from authenticated WEB_REMIX instead of swallowing it',
      () async {
        final resolver = YtmResidentResolver(
          authProvider: () => const YtmAuthCredentials(
            authMode: 'cookie',
            cookie: 'SAPISID=secret123; SID=abc',
          ),
          requestHandler: ({
            required uri,
            required headers,
            required body,
            cancelToken,
          }) async {
            final client =
                ((body['context'] as Map)['client'] as Map)['clientName']
                    .toString();
            if (client == 'WEB_REMIX') {
              return const YtmPlayerHttpResponse(
                statusCode: 401,
                body: '{"error":{"code":401,"message":"UNAUTHENTICATED"}}',
              );
            }
            return const YtmPlayerHttpResponse(
              statusCode: 200,
              body: '{"playabilityStatus":{"status":"LOGIN_REQUIRED"}}',
            );
          },
        );
        addTearDown(() => resolver.disposeAsync());

        await expectLater(
          resolver.resolve(const StreamKey('youtube_music', 'dQw4w9WgXcQ', 'default')),
          throwsA(
            isA<StreamingException>()
                .having((e) => e.statusCode, 'statusCode', 401)
                .having((e) => e.isTokenExpired, 'isTokenExpired', isTrue),
          ),
        );
      },
    );

    test(
      'L1StreamCache persists and hydrates loudness & albumLoudness round-trip',
      () async {
        final persistence = InMemoryL1StreamCachePersistence();
        final now = DateTime.utc(2026, 11, 23, 12, 0, 0);
        final exp = (now.millisecondsSinceEpoch ~/ 1000) + 3600;

        final cache1 = L1StreamCache(persistence: persistence, clock: () => now);
        const key = StreamKey('tidal', '999', 'LOSSLESS');
        cache1.put(
          DirectRangeSpec(
            key: key,
            url: 'https://cdn.tidal.com/999.flac',
            expireAt: exp,
            loudness: const NormalizedLoudness(gainDb: -2.5, peak: 0.91),
            albumLoudness: const NormalizedLoudness(gainDb: -1.0, peak: 0.98),
          ),
          ProviderCapabilities.tidal,
        );
        await Future<void>.delayed(Duration.zero);

        final cache2 = L1StreamCache(persistence: persistence, clock: () => now);
        await cache2.hydrate();
        final hydrated =
            cache2.get(key, ProviderCapabilities.tidal) as DirectRangeSpec?;
        expect(hydrated, isNotNull);
        expect(
          hydrated!.loudness,
          equals(const NormalizedLoudness(gainDb: -2.5, peak: 0.91)),
        );
        expect(
          hydrated.albumLoudness,
          equals(const NormalizedLoudness(gainDb: -1.0, peak: 0.98)),
        );
      },
    );

    test(
      'StreamingManager.disposeAsync awaits PO Token sidecar disposal and cancels in-flight resolves cleanly',
      () async {
        final store = MemorySecureCredentialStore();
        final pot = _TrackingPotProvider()..blockDisposeUntilGate = true;
        final slowProvider = _ControllableAuthProvider(
          kind: 'qobuz',
          capabilities: ProviderCapabilities.qobuz,
          credentialStore: store,
          onResolve: (key, cancel) {
            final c = Completer<StreamSourceSpec>();
            cancel?.addListener(() {
              if (!c.isCompleted) {
                c.completeError(
                  const StreamingException('cancelled', isCancelled: true),
                );
              }
            });
            return c.future;
          },
        );
        final ytm = YouTubeMusicProvider(
          credentialStore: store,
          potProvider: pot,
          ownsPotProvider: true,
        );
        final manager = StreamingManager(
          credentialStore: store,
          providers: <String, StreamingProvider>{
            'qobuz': slowProvider,
            'youtube_music': ytm,
          },
          enableLiveWarmup: false,
        );

        final inFlight = manager.resolveSourceSpec(
          const StreamKey('qobuz', 'hang_1', 'default'),
        );
        final inFlightExpect = expectLater(
          inFlight,
          throwsA(
            isA<StreamingException>()
                .having((e) => e.isCancelled, 'isCancelled', isTrue),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(manager.singleFlightResolver.inFlightCount, equals(1));

        var disposeDone = false;
        final disposeFuture = manager.disposeAsync().then((_) {
          disposeDone = true;
        });
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(pot.disposeCalls, equals(1));
        expect(disposeDone, isFalse);

        // In-flight resolution cancelled immediately during disposeAsync.
        await inFlightExpect;

        pot.disposeGate.complete();
        await disposeFuture;
        expect(disposeDone, isTrue);
      },
    );
  });

  group('Phase 3.4: UI AuthRequired Banner & Re-login Surfacing', () {
    testWidgets(
      'StreamingServiceView and ProvidersAndRemotePanel surface authRequired banner and 重新登入 button',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final store = MemorySecureCredentialStore();
        final qobuz = _ControllableAuthProvider(
          kind: 'qobuz',
          capabilities: ProviderCapabilities.qobuz,
          credentialStore: store,
        );
        final manager = StreamingManager(
          credentialStore: store,
          providers: <String, StreamingProvider>{'qobuz': qobuz},
          enableLiveWarmup: false,
        );
        addTearDown(() => manager.disposeAsync());

        final audioService = MockAudioService();
        addTearDown(audioService.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              body: StreamingServiceView(
                audioService: audioService,
                provider: StreamingProviderMeta.byKind('qobuz')!,
                streamingManager: manager,
                onOpenProviderSettings: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('streaming_auth_required_banner_qobuz')),
          findsNothing,
        );

        // Trip AuthRequired -> banner & 重新登入 button appear immediately.
        manager.authManager.tripAuthRequired('qobuz', 'Qobuz 登入憑證已過期（HTTP 401）');
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('streaming_auth_required_banner_qobuz')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('btn_streaming_relogin_qobuz')),
          findsOneWidget,
        );
        expect(find.text('Qobuz 登入憑證已過期（HTTP 401）'), findsOneWidget);
        expect(find.text('重新登入'), findsOneWidget);

        // ProvidersAndRemotePanel also surfaces red 重新登入 button for authRequired.
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

        expect(find.byKey(const Key('btn_relogin_qobuz')), findsOneWidget);
        expect(find.text('Qobuz 登入憑證已過期（HTTP 401）'), findsOneWidget);
      },
    );
  });
}
