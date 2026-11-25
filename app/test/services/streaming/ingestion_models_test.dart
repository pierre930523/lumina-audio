import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/ingestion_models.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/stream_source_spec.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/models/streaming_provider_meta.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/streaming/auth_manager.dart';
import 'package:lumina_app/services/streaming/l1_stream_cache.dart';
import 'package:lumina_app/services/streaming/providers/apple_music_provider.dart';
import 'package:lumina_app/services/streaming/providers/deezer_provider.dart';
import 'package:lumina_app/services/streaming/providers/qobuz_provider.dart';
import 'package:lumina_app/services/streaming/providers/tidal_provider.dart';
import 'package:lumina_app/services/streaming/providers/youtube_music_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/single_flight_resolver.dart';
import 'package:lumina_app/services/streaming/stream_resolver.dart';
import 'package:lumina_app/services/streaming/streaming_provider.dart';
import 'package:lumina_app/services/streaming/yt_dlp_service.dart';

class _InMemoryCredentialStore implements SecureCredentialStore {
  final Map<String, String> _data = <String, String>{};

  @override
  Future<void> delete(String key) async => _data.remove(key);

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> clearAll() async => _data.clear();
}

class _StubErrorProvider extends BaseStreamingProvider implements StreamResolver {
  final StreamingException errorToThrow;
  int forceRefreshCalls = 0;

  _StubErrorProvider({required this.errorToThrow})
    : super(credentialStore: _InMemoryCredentialStore()) {
    setConnected(const StreamingAccountInfo(displayName: 'Test User'));
  }

  @override
  String get kind => 'qobuz';

  @override
  StreamingProviderMeta get meta => StreamingProviderMeta.byKind('qobuz')!;

  @override
  String get providerId => 'qobuz';

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities.qobuz;

  @override
  bool get supportsSilentRefresh => true;

  @override
  Future<void> forceRefreshSession() async {
    forceRefreshCalls++;
  }

  @override
  Future<StreamSourceSpec> resolve(
    StreamKey key, {
    CancellationToken? cancelToken,
  }) async {
    throw errorToThrow;
  }

  @override
  Future<void> authenticate(
    Map<String, dynamic> params, {
    CancellationToken? cancel,
    void Function(String statusMsg)? onProgress,
  }) async {}

  @override
  Future<List<TrackInfo>> fetchPlaylistTracks(String playlistId) async =>
      const [];

  @override
  Future<void> logout() async {}

  @override
  Future<void> refreshSessionIfNeeded() async {}

  @override
  Future<ResolvedStreamResult> resolveStream(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
  }) async {
    throw errorToThrow;
  }

  @override
  Future<void> restoreFromStorage() async {}

  @override
  Future<StreamingCatalog> search(
    String query, {
    CancellationToken? cancel,
  }) async => StreamingCatalog.empty();

  @override
  Future<StreamingCatalog> syncLibrary({CancellationToken? cancel}) async =>
      StreamingCatalog.empty();

  @override
  Future<CanonicalAlbumDetail?> fetchAlbumDetail(
    String albumId, {
    CancellationToken? cancel,
  }) async => null;
}

class _NoopYtDlpService extends YtDlpService {
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
    throw const YtDlpException('yt-dlp unavailable in unit test');
  }
}

Future<void> _sendJson(HttpResponse res, int status, Object body) async {
  res.statusCode = status;
  res.headers.contentType = ContentType.json;
  res.write(jsonEncode(body));
  await res.close();
}

void main() {
  group('Ingestion DTO JSON round-trips', () {
    test('SkipReason enum round-trips all variants with displayLabel', () {
      for (final reason in SkipReason.values) {
        final raw = reason.toJson();
        expect(SkipReason.fromJson(raw), reason);
        expect(reason.displayLabel, isNotEmpty);
      }
      expect(SkipReason.corruptHeader.toJson(), 'corrupt_header');
      expect(SkipReason.permissionDenied.toJson(), 'permission_denied');
      expect(SkipReason.unsupportedFormat.toJson(), 'unsupported_format');
      expect(SkipReason.unsplitCueOrIso.toJson(), 'unsplit_cue_or_iso');
      expect(SkipReason.garbledTags.toJson(), 'garbled_tags');
      expect(SkipReason.ioError.toJson(), 'io_error');
    });

    test('SkippedFileRecord round-trips snake_case JSON', () {
      const record = SkippedFileRecord(
        id: 'skip-001',
        providerId: 'local',
        filePath: r'C:\Music\broken.flac',
        reason: SkipReason.corruptHeader,
        detail: 'invalid fLaC header',
        fileSize: 4096,
        fileMtime: 1700000000,
        firstSeenAt: '2026-11-25T10:00:00Z',
        lastSeenAt: '2026-11-25T10:05:00Z',
        dismissed: false,
      );

      final json = record.toJson();
      expect(json['provider_id'], 'local');
      expect(json['file_path'], r'C:\Music\broken.flac');
      expect(json['reason'], 'corrupt_header');
      expect(json['file_size'], 4096);
      expect(json['file_mtime'], 1700000000);
      expect(json['first_seen_at'], '2026-11-25T10:00:00Z');
      expect(json['last_seen_at'], '2026-11-25T10:05:00Z');
      expect(json['dismissed'], isFalse);

      final parsed = SkippedFileRecord.fromJson(json);
      expect(parsed.id, record.id);
      expect(parsed.providerId, record.providerId);
      expect(parsed.filePath, record.filePath);
      expect(parsed.reason, record.reason);
      expect(parsed.detail, record.detail);
      expect(parsed.fileSize, record.fileSize);
      expect(parsed.fileMtime, record.fileMtime);
      expect(parsed.dismissed, isFalse);
    });

    test('ScanLifecycleState and ScanProgressEvent round-trip', () {
      for (final state in ScanLifecycleState.values) {
        expect(ScanLifecycleState.fromJson(state.toJson()), state);
      }

      const ev = ScanProgressEvent(
        scanId: 'scan-42',
        rootPath: r'D:\Lossless',
        state: ScanLifecycleState.probing,
        scanned: 250,
        added: 200,
        updated: 15,
        unchanged: 30,
        skipped: 5,
        pruned: 2,
        totalEstimated: 1000,
        currentPath: r'D:\Lossless\Album\01.flac',
        message: 'Probing headers',
      );
      final json = ev.toJson();
      expect(json['scan_id'], 'scan-42');
      expect(json['root_path'], r'D:\Lossless');
      expect(json['state'], 'probing');
      expect(json['total_estimated'], 1000);
      expect(json['current_path'], r'D:\Lossless\Album\01.flac');

      final parsed = ScanProgressEvent.fromJson(json);
      expect(parsed.scanId, ev.scanId);
      expect(parsed.state, ScanLifecycleState.probing);
      expect(parsed.scanned, 250);
      expect(parsed.added, 200);
      expect(parsed.updated, 15);
      expect(parsed.unchanged, 30);
      expect(parsed.skipped, 5);
      expect(parsed.pruned, 2);
      expect(parsed.totalEstimated, 1000);
      expect(parsed.currentPath, ev.currentPath);
      expect(parsed.message, ev.message);
    });

    test('WatchMode and WatchedRootRecord round-trip', () {
      expect(WatchMode.nativeOs.toJson(), 'native_os');
      expect(WatchMode.nasPolling.toJson(), 'nas_polling');
      expect(WatchMode.manual.toJson(), 'manual');
      for (final mode in WatchMode.values) {
        expect(WatchMode.fromJson(mode.toJson()), mode);
      }

      const root = WatchedRootRecord(
        id: 'root-nas-1',
        providerId: 'smb',
        rootPath: 'smb://nas.local/music',
        watchMode: WatchMode.nasPolling,
        pollIntervalSec: 600,
        isOnline: false,
        lastScanAt: '2026-11-25T12:00:00Z',
        updatedAt: '2026-11-25T12:01:00Z',
      );
      final json = root.toJson();
      expect(json['watch_mode'], 'nas_polling');
      expect(json['poll_interval_sec'], 600);
      expect(json['is_online'], isFalse);

      final parsed = WatchedRootRecord.fromJson(json);
      expect(parsed.id, root.id);
      expect(parsed.providerId, 'smb');
      expect(parsed.watchMode, WatchMode.nasPolling);
      expect(parsed.pollIntervalSec, 600);
      expect(parsed.isOnline, isFalse);
      expect(parsed.lastScanAt, root.lastScanAt);
    });

    test('MetadataLayer and MetadataOverrideRecord round-trip', () {
      expect(MetadataLayer.fileTag.toJson(), 'file_tag');
      expect(MetadataLayer.cloudEnrichment.toJson(), 'cloud_enrichment');
      expect(MetadataLayer.userEdit.toJson(), 'user_edit');
      for (final layer in MetadataLayer.values) {
        expect(MetadataLayer.fromJson(layer.toJson()), layer);
      }

      const ov = MetadataOverrideRecord(
        entityType: 'track',
        entityId: 'trk-99',
        fieldName: 'title',
        valueJson: '"Custom Remaster Title"',
        sourceLayer: MetadataLayer.userEdit,
        updatedAt: '2026-11-25T13:00:00Z',
      );
      final json = ov.toJson();
      expect(json['entity_type'], 'track');
      expect(json['source_layer'], 'user_edit');

      final parsed = MetadataOverrideRecord.fromJson(json);
      expect(parsed.entityType, 'track');
      expect(parsed.entityId, 'trk-99');
      expect(parsed.fieldName, 'title');
      expect(parsed.valueJson, '"Custom Remaster Title"');
      expect(parsed.sourceLayer, MetadataLayer.userEdit);
    });

    test(
      'ExternalCatalogIngestBatch.fromStreamingCatalog maps metadata and never leaks stream URLs',
      () {
        const leakyStreamUrl =
            'https://cdn.qobuz.com/expiring/stream.flac?exp=1799999999&sig=secret';
        final catalog = StreamingCatalog(
          albums: const [
            StreamingAlbum(
              id: 'qobuz:alb_100',
              title: 'Kind of Blue',
              artist: 'Miles Davis',
              year: 1959,
              coverUrl: 'https://static.qobuz.com/images/covers/alb_100.jpg',
              providerKind: 'qobuz',
            ),
          ],
          tracks: const [
            TrackInfo(
              id: 'qobuz:trk_1',
              title: 'So What',
              artist: 'Miles Davis',
              album: 'Kind of Blue',
              albumArtist: 'Miles Davis',
              duration: Duration(milliseconds: 562000),
              format: AudioFormat(
                codec: AudioCodec.flac,
                sampleRateHz: 192000,
                bitDepth: 24,
                channels: 2,
              ),
              providerName: 'Qobuz',
              filePath: leakyStreamUrl,
              isrc: 'USSM15900113',
              genre: 'Jazz',
              composer: 'Miles Davis',
              discNumber: 1,
              trackNumber: 1,
              year: 1959,
            ),
          ],
          playlists: const [
            StreamingPlaylist(
              id: 'pl_1',
              title: 'Late Night Jazz',
              providerKind: 'qobuz',
              tracks: [
                TrackInfo(
                  id: 'qobuz:trk_1',
                  title: 'So What',
                  artist: 'Miles Davis',
                  album: 'Kind of Blue',
                  duration: Duration(milliseconds: 562000),
                  format: AudioFormat(
                    codec: AudioCodec.flac,
                    sampleRateHz: 192000,
                    bitDepth: 24,
                    channels: 2,
                  ),
                  filePath: leakyStreamUrl,
                ),
                TrackInfo(
                  id: 'qobuz:trk_2',
                  title: 'Freddie Freeloader',
                  artist: 'Miles Davis',
                  album: 'Kind of Blue',
                  duration: Duration(milliseconds: 586000),
                  format: AudioFormat(
                    codec: AudioCodec.flac,
                    sampleRateHz: 192000,
                    bitDepth: 24,
                    channels: 2,
                  ),
                  filePath: leakyStreamUrl,
                  discNumber: 2,
                  trackNumber: 1,
                ),
              ],
            ),
          ],
        );

        final batch = ExternalCatalogIngestBatch.fromStreamingCatalog(
          'qobuz',
          catalog,
        );
        final json = batch.toJson();
        final encoded = jsonEncode(json);

        expect(json['provider'], 'qobuz');
        expect(batch.albums.length, 1);
        final album = batch.albums.single;
        expect(album.externalAlbumId, 'alb_100');
        expect(album.releaseYear, 1959);
        expect(album.discCount, 2);
        expect(album.tracks.length, 2);
        expect(album.tracks[0].externalTrackId, 'trk_1');
        expect(album.tracks[0].isrc, 'USSM15900113');
        expect(album.tracks[0].codec, 'flac');
        expect(album.tracks[0].sampleRateHz, 192000);
        expect(album.tracks[0].bitDepth, 24);
        expect(album.tracks[1].externalTrackId, 'trk_2');

        // Zero expiring audio stream URLs or file_path fields may leak.
        expect(encoded, isNot(contains(leakyStreamUrl)));
        expect(encoded, isNot(contains('stream_url')));
        expect(encoded, isNot(contains('file_path')));
        expect(encoded, isNot(contains('preview_url')));

        final roundTripped = ExternalCatalogIngestBatch.fromJson(json);
        expect(roundTripped.provider, 'qobuz');
        expect(roundTripped.albums.single.tracks.length, 2);
      },
    );
  });

  group('StreamingException error classification', () {
    test('infers kind from statusCode, legacy flags, and explicit kind', () {
      const geo451 = StreamingException('Blocked', statusCode: 451);
      expect(geo451.kind, StreamingErrorKind.regionRestricted);
      expect(geo451.isRegionRestricted, isTrue);
      expect(geo451.isUnavailable, isFalse);

      const gone410 = StreamingException('Gone', statusCode: 410);
      expect(gone410.kind, StreamingErrorKind.trackUnavailable);
      expect(gone410.isUnavailable, isTrue);

      const notFound404 = StreamingException('Missing', statusCode: 404);
      expect(notFound404.kind, StreamingErrorKind.trackUnavailable);

      const explicitRegion = StreamingException(
        'Not available in JP',
        statusCode: 403,
        kind: StreamingErrorKind.regionRestricted,
      );
      expect(explicitRegion.isRegionRestricted, isTrue);
      expect(explicitRegion.isTokenExpired, isFalse);

      const tokenExpired = StreamingException(
        'Expired',
        statusCode: 401,
        isTokenExpired: true,
      );
      expect(tokenExpired.kind, StreamingErrorKind.authExpired);

      const drm = StreamingException('FairPlay', isDrmRestricted: true);
      expect(drm.kind, StreamingErrorKind.drmRestricted);

      const cancelled = StreamingException('Cancelled', isCancelled: true);
      expect(cancelled.kind, StreamingErrorKind.cancelled);

      const rateLimited = StreamingException('Slow down', statusCode: 429);
      expect(rateLimited.kind, StreamingErrorKind.rateLimited);
    });

    test('classifyKind detects geo-block and takedown messages', () {
      expect(
        StreamingException.classifyKind(
          statusCode: 403,
          message: 'The uploader has not made this video available in your country',
        ),
        StreamingErrorKind.regionRestricted,
      );
      expect(
        StreamingException.classifyKind(
          message: 'NotAvailableInCountry',
          isDrmRestricted: true,
        ),
        StreamingErrorKind.regionRestricted,
      );
      expect(
        StreamingException.classifyKind(
          message: 'Track removed due to copyright claim takedown',
        ),
        StreamingErrorKind.trackUnavailable,
      );
    });
  });

  group('SingleFlightResolver non-auth handling for geo/takedown errors', () {
    test(
      'refreshAfter403 returns RefreshAfter403Failed without refresh or auth breaker on regionRestricted / trackUnavailable',
      () async {
        for (final err in const [
          StreamingException(
            'Geo-blocked in region',
            statusCode: 451,
            kind: StreamingErrorKind.regionRestricted,
          ),
          StreamingException(
            'Track taken down',
            statusCode: 404,
            kind: StreamingErrorKind.trackUnavailable,
          ),
        ]) {
          final provider = _StubErrorProvider(errorToThrow: err);
          final registry = StreamResolverRegistry()..register(provider);
          final cache = L1StreamCache();
          final resolver = SingleFlightResolver(
            registry: registry,
            l1Cache: cache,
          );
          var authBreakerTripped = false;
          final auth = AuthManager(
            providerLookup: (id) => id == 'qobuz' ? provider : null,
            l1Cache: cache,
            singleFlightResolver: resolver,
          )..addAuthRequiredListener((_, _) => authBreakerTripped = true);
          resolver.attachAuthManager(auth);

          const key = StreamKey('qobuz', 'trk_blocked', 'hi_res');
          final result = await resolver.refreshAfter403(
            key,
            failedUrl: 'https://cdn.example/old.flac',
          );

          expect(result, isA<RefreshAfter403Failed>());
          final failed = result as RefreshAfter403Failed;
          expect(failed.errorKind, err.kind);
          expect(failed.isRegionRestricted, err.isRegionRestricted);
          expect(failed.isUnavailable, err.isUnavailable);
          expect(provider.forceRefreshCalls, 0);
          expect(authBreakerTripped, isFalse);
          expect(auth.isAuthRequired('qobuz'), isFalse);
        }
      },
    );
  });

  group('Provider region/takedown classification', () {
    late HttpServer server;
    late String baseUrl;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://127.0.0.1:${server.port}';
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('QobuzProvider classifies HTTP 451 as regionRestricted', () async {
      server.listen((req) async {
        if (req.uri.path.endsWith('/user/get')) {
          await _sendJson(req.response, 200, {'id': 1, 'display_name': 'QUser'});
        } else if (req.uri.path.endsWith('/track/getFileUrl')) {
          await _sendJson(req.response, 451, {
            'status': 'error',
            'message': 'Unavailable in your country',
          });
        } else {
          await _sendJson(req.response, 404, {'error': 'not found'});
        }
      });

      final provider = QobuzProvider(
        credentialStore: _InMemoryCredentialStore(),
        baseUrl: baseUrl,
      );
      await provider.authenticate(<String, dynamic>{
        'user_auth_token': 'tok_123',
        'app_id': 'app_1',
        'app_secret': 'sec_1',
      });

      await expectLater(
        provider.resolve(const StreamKey('qobuz', '999', 'auto')),
        throwsA(
          isA<StreamingException>()
              .having((e) => e.isRegionRestricted, 'isRegionRestricted', isTrue)
              .having((e) => e.isTokenExpired, 'isTokenExpired', isFalse),
        ),
      );
    });

    test('TidalProvider fails fast with regionRestricted on HTTP 451', () async {
      var playbackCalls = 0;
      server.listen((req) async {
        if (req.uri.path.contains('/playbackinfopostpaywall')) {
          playbackCalls++;
          await _sendJson(req.response, 451, {
            'userMessage': 'Track is not available in your country',
          });
        } else if (req.uri.path.endsWith('/sessions')) {
          await _sendJson(req.response, 200, {
            'userId': 123,
            'countryCode': 'US',
          });
        } else if (req.uri.path.endsWith('/users/123')) {
          await _sendJson(req.response, 200, {
            'id': 123,
            'username': 'TUser',
            'countryCode': 'US',
          });
        } else {
          await _sendJson(req.response, 200, <String, dynamic>{});
        }
      });

      final store = _InMemoryCredentialStore();
      await store.write(
        'streaming:tidal',
        jsonEncode(<String, dynamic>{
          'access_token': 'acc_1',
          'refresh_token': 'ref_1',
          'expires_at': DateTime.now()
              .add(const Duration(hours: 1))
              .toUtc()
              .toIso8601String(),
          'user_id': '123',
          'country_code': 'US',
          'account': const StreamingAccountInfo(
            displayName: 'TUser',
            userId: '123',
          ).toJson(),
        }),
      );
      final provider = TidalProvider(
        credentialStore: store,
        apiBaseUrl: baseUrl,
      );
      await provider.restoreFromStorage();

      await expectLater(
        provider.resolve(const StreamKey('tidal', '777', 'hi_res')),
        throwsA(
          isA<StreamingException>().having(
            (e) => e.isRegionRestricted,
            'isRegionRestricted',
            isTrue,
          ),
        ),
      );
      expect(playbackCalls, 1);
    });

    test(
      'DeezerProvider does not misclassify gateway RIGHTS_ERROR as 401 authExpired',
      () async {
        server.listen((req) async {
          if (req.uri.queryParameters['method'] == 'deezer.getUserData') {
            await _sendJson(req.response, 200, {
              'error': <dynamic>[],
              'results': {
                'USER': {
                  'USER_ID': 42,
                  'BLOG_NAME': 'DUser',
                  'OPTIONS': {
                    'license_token': 'lic_tok',
                    'web_lossless': true,
                    'web_hq': true,
                  },
                },
                'checkForm': 'api_tok',
              },
            });
          } else if (req.uri.queryParameters['method'] == 'song.getData') {
            await _sendJson(req.response, 200, {
              'error': {'RIGHTS_ERROR': 'Track is geo-restricted in your region'},
              'results': <String, dynamic>{},
            });
          } else {
            await _sendJson(req.response, 200, <String, dynamic>{});
          }
        });

        final store = _InMemoryCredentialStore();
        await store.write(
          'streaming:deezer',
          jsonEncode(<String, dynamic>{
            'mode': 'arl',
            'arl': 'a' * 64,
            'user_id': '42',
            'api_token': 'api_tok',
            'license_token': 'lic_tok',
            'web_lossless': true,
            'web_hq': true,
            'account': const StreamingAccountInfo(
              displayName: 'DUser',
              userId: '42',
            ).toJson(),
          }),
        );
        final provider = DeezerProvider(
          credentialStore: store,
          gwUrl: '$baseUrl/gw',
          apiBaseUrl: baseUrl,
          mediaBaseUrl: '$baseUrl/media',
        );
        await provider.restoreFromStorage();

        await expectLater(
          provider.resolve(const StreamKey('deezer', '555', 'lossless')),
          throwsA(
            isA<StreamingException>()
                .having((e) => e.isRegionRestricted, 'isRegionRestricted', isTrue)
                .having((e) => e.isTokenExpired, 'isTokenExpired', isFalse),
          ),
        );
      },
    );

    test('AppleMusicProvider classifies storefront 451 as regionRestricted', () async {
      server.listen((req) async {
        if (req.uri.path.endsWith('/v1/me/storefront')) {
          await _sendJson(req.response, 200, {
            'data': [
              {'id': 'us'},
            ],
          });
        } else if (req.uri.path.contains('/v1/catalog/')) {
          await _sendJson(req.response, 451, {
            'errors': [
              {'detail': 'Not available in this storefront'},
            ],
          });
        } else {
          await _sendJson(req.response, 200, <String, dynamic>{});
        }
      });

      final store = _InMemoryCredentialStore();
      await store.write(
        'streaming:apple_music',
        jsonEncode(<String, dynamic>{
          'developer_token': 'dev_tok',
          'music_user_token': 'mut_tok',
          'storefront': 'us',
          'account': const StreamingAccountInfo(displayName: 'AUser').toJson(),
        }),
      );
      final provider = AppleMusicProvider(
        credentialStore: store,
        apiBaseUrl: baseUrl,
      );
      await provider.restoreFromStorage();

      await expectLater(
        provider.resolve(const StreamKey('apple_music', '123456', 'default')),
        throwsA(
          isA<StreamingException>().having(
            (e) => e.isRegionRestricted,
            'isRegionRestricted',
            isTrue,
          ),
        ),
      );
    });

    test(
      'YouTubeMusicProvider classifies UNPLAYABLE geo-blocked playabilityStatus as regionRestricted',
      () async {
        server.listen((req) async {
          if (req.uri.path.contains('account_menu')) {
            await _sendJson(req.response, 200, {
              'actions': [
                {
                  'openPopupAction': {
                    'popup': {
                      'multiPageMenuRenderer': {
                        'header': {
                          'activeAccountHeaderRenderer': {
                            'accountName': {'simpleText': 'YtmUser'},
                            'email': {'simpleText': 'ytm@example.com'},
                          },
                        },
                      },
                    },
                  },
                },
              ],
            });
          } else {
            await _sendJson(req.response, 200, {
              'playabilityStatus': {
                'status': 'UNPLAYABLE',
                'reason':
                    'The uploader has not made this video available in your country',
              },
            });
          }
        });

        final store = _InMemoryCredentialStore();
        await store.write(
          'streaming:youtube_music',
          jsonEncode(<String, dynamic>{
            'mode': 'oauth',
            'access_token': 'ytm_acc_1',
            'refresh_token': 'ytm_ref_1',
            'expires_at': DateTime.now()
                .add(const Duration(hours: 1))
                .toUtc()
                .toIso8601String(),
            'account': const StreamingAccountInfo(
              displayName: 'YtmUser',
            ).toJson(),
          }),
        );
        final provider = YouTubeMusicProvider(
          credentialStore: store,
          baseUrl: baseUrl,
          ytDlpService: _NoopYtDlpService(),
        );
        await provider.restoreFromStorage();
        await expectLater(
          provider.resolveStream(
            const TrackInfo(
              id: 'ytm:dQw4w9WgXcQ',
              title: 'Geo Blocked Track',
              artist: 'Artist',
              album: 'Album',
              duration: Duration(seconds: 180),
              format: AudioFormat(
                codec: AudioCodec.opus,
                sampleRateHz: 48000,
                bitDepth: 16,
                channels: 2,
              ),
            ),
          ),
          throwsA(
            isA<StreamingException>()
                .having((e) => e.isRegionRestricted, 'isRegionRestricted', isTrue)
                .having((e) => e.isTokenExpired, 'isTokenExpired', isFalse),
          ),
        );
      },
    );
  });
}
