import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/home_layout_preset.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/stream_source_spec.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/desktop_window_controller.dart';
import 'package:lumina_app/services/ffi_audio_service.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/playback_persistence_service.dart';
import 'package:lumina_app/services/streaming/pot_provider.dart';
import 'package:lumina_app/services/streaming/providers/youtube_music_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/stream_resolver.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_provider.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:lumina_app/ui/settings/general_settings_panel.dart';
import 'package:lumina_app/ui/settings/streaming_login_dialog.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

class _ConfigurableStreamingProvider extends BaseStreamingProvider
    implements StreamResolver {
  @override
  final String kind;
  @override
  final ProviderCapabilities capabilities;

  Future<StreamSourceSpec> Function(StreamKey key, CancellationToken? cancel)?
      onResolve;

  _ConfigurableStreamingProvider({
    required this.kind,
    required this.capabilities,
    required super.credentialStore,
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
  Future<void> refreshSessionIfNeeded() async {}

  @override
  Future<void> logout() async {
    resetState();
  }

  @override
  Future<StreamingCatalog> syncLibrary({CancellationToken? cancel}) async =>
      catalog;

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
    if (onResolve != null) {
      return onResolve!(key, cancelToken);
    }
    final exp = (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600;
    return DirectRangeSpec(
      key: key,
      url: 'https://cdn.example.com/$kind/${key.trackId}.flac',
      contentLength: 5000000,
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
      StreamKey(
        kind,
        BaseStreamingProvider.stripTrackPrefix(track.id, kind),
        'default',
      ),
      cancelToken: cancel,
    );
    return ResolvedStreamResult(
      url: spec is DirectRangeSpec ? spec.url : '',
      format: track.format,
    );
  }
}

class _OrderedShutdownPotProvider implements PotProvider {
  final List<String> events;
  final Completer<void> disposeGate = Completer<void>();

  _OrderedShutdownPotProvider(this.events);

  @override
  Future<PoToken?> getGvsToken({
    required String sessionBinding,
    CancellationToken? cancelToken,
  }) async => null;

  @override
  Future<PoToken?> getPlayerToken({
    required String videoId,
    CancellationToken? cancelToken,
  }) async => null;

  @override
  void invalidateSession() {}

  @override
  Future<void> dispose() async {
    events.add('pot_dispose_start');
    await disposeGate.future;
    events.add('pot_dispose_done');
  }
}

class _OrderedMockAudioService extends MockAudioService {
  final List<String> events;

  _OrderedMockAudioService(this.events);

  @override
  void dispose() {
    events.add('audio_dispose');
    super.dispose();
  }
}

void main() {
  group('Phase 3 Wave 2B: FfiAudioService Refresh Bridge & Deduped AUTH_REQUIRED', () {
    test(
      'handleStreamRefreshRequestJson matches streaming_bridge.rs schema for refreshed, format_changed, auth_required, and error',
      () async {
        final store = MemorySecureCredentialStore();
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        var mode = 'refreshed';

        final qobuz = _ConfigurableStreamingProvider(
          kind: 'qobuz',
          capabilities: ProviderCapabilities.qobuz,
          credentialStore: store,
          onResolve: (key, cancel) async {
            if (mode == 'error_403') {
              throw const StreamingException(
                'CDN still forbidden',
                statusCode: 403,
                isTokenExpired: false,
              );
            }
            if (mode == 'auth_401') {
              throw const StreamingException(
                'Qobuz token expired (401)',
                statusCode: 401,
                isTokenExpired: true,
              );
            }
            if (mode == 'format_changed') {
              return DirectRangeSpec(
                key: key,
                url: 'https://cdn.qobuz.com/${key.trackId}_v3.m4a',
                contentLength: 3100000,
                mimeType: 'audio/mp4',
                expireAt: nowSec + 3600,
              );
            }
            return DirectRangeSpec(
              key: key,
              url: 'https://cdn.qobuz.com/${key.trackId}_v2.flac',
              contentLength: 5000000,
              mimeType: 'audio/flac',
              expireAt: nowSec + 3600,
            );
          },
        );

        final manager = StreamingManager(
          credentialStore: store,
          providers: <String, StreamingProvider>{'qobuz': qobuz},
          enableLiveWarmup: false,
        );
        addTearDown(() => manager.disposeAsync());

        final ffiService = FfiAudioService(headless: true);
        addTearDown(ffiService.dispose);

        // Before attaching StreamingManager -> returns clean error JSON.
        final unattachedReply = jsonDecode(
          await ffiService.handleStreamRefreshRequestJson(
            jsonEncode(<String, dynamic>{
              'provider_id': 'qobuz',
              'track_id': '42',
              'quality_key': 'default',
              'failed_url': 'https://cdn.qobuz.com/42_v1.flac',
              'status_code': 403,
              'attempt': 1,
            }),
          ),
        ) as Map<String, dynamic>;
        expect(unattachedReply['status'], equals('error'));

        ffiService.attachStreamingManager(manager);

        // 1. Refreshed
        mode = 'refreshed';
        final refreshedReply = jsonDecode(
          await ffiService.handleStreamRefreshRequestJson(
            jsonEncode(<String, dynamic>{
              'provider_id': 'qobuz',
              'track_id': '42',
              'quality_key': 'default',
              'failed_url': 'https://cdn.qobuz.com/42_v1.flac',
              'status_code': 403,
              'attempt': 1,
              'expected_content_length': 5000000,
              'expected_mime_type': 'audio/flac',
              'expected_kind': 'direct_range',
            }),
          ),
        ) as Map<String, dynamic>;
        expect(refreshedReply['status'], equals('refreshed'));
        final specMap = refreshedReply['spec'] as Map<String, dynamic>;
        expect(specMap['kind'], equals('direct_range'));
        expect(specMap['url'], equals('https://cdn.qobuz.com/42_v2.flac'));

        // 2. FormatChanged
        mode = 'format_changed';
        final driftReply = jsonDecode(
          await ffiService.handleStreamRefreshRequestJson(
            jsonEncode(<String, dynamic>{
              'provider_id': 'qobuz',
              'track_id': '42',
              'quality_key': 'default',
              'failed_url': 'https://cdn.qobuz.com/42_v2.flac',
              'status_code': 403,
              'attempt': 1,
              'expected_content_length': 5000000,
              'expected_mime_type': 'audio/flac',
              'expected_kind': 'direct_range',
            }),
          ),
        ) as Map<String, dynamic>;
        expect(driftReply['status'], equals('format_changed'));
        expect((driftReply['reason'] as String), isNotEmpty);
        expect(
          (driftReply['spec'] as Map<String, dynamic>)['url'],
          equals('https://cdn.qobuz.com/42_v3.m4a'),
        );

        // 3. Error (403) must NOT trip AuthRequired
        mode = 'error_403';
        final errReply = jsonDecode(
          await ffiService.handleStreamRefreshRequestJson(
            jsonEncode(<String, dynamic>{
              'provider_id': 'qobuz',
              'track_id': '42',
              'quality_key': 'default',
              'failed_url': 'https://cdn.qobuz.com/42_v3.m4a',
              'status_code': 403,
              'attempt': 2,
            }),
          ),
        ) as Map<String, dynamic>;
        expect(errReply['status'], equals('error'));
        expect(errReply['message'], contains('forbidden'));
        expect(manager.isAuthRequired('qobuz'), isFalse);

        // 4. AuthRequired (401) DOES trip AuthRequired and encodes exact schema
        mode = 'auth_401';
        final authReply = jsonDecode(
          await ffiService.handleStreamRefreshRequestJson(
            jsonEncode(<String, dynamic>{
              'provider_id': 'qobuz',
              'track_id': '42',
              'quality_key': 'default',
              'failed_url': 'https://cdn.qobuz.com/42_v3.m4a',
              'status_code': 403,
              'attempt': 1,
            }),
          ),
        ) as Map<String, dynamic>;
        expect(authReply['status'], equals('auth_required'));
        expect(authReply['provider_id'], equals('qobuz'));
        expect((authReply['message'] as String), contains('401'));
        expect(manager.isAuthRequired('qobuz'), isTrue);

        ffiService.detachStreamingManager();
      },
    );

    test(
      'polled state JSON deduplicates AUTH_REQUIRED per event and ignores DEVICE_LOST / FORMAT_SWITCH_FAILED for auth breaker',
      () async {
        final store = MemorySecureCredentialStore();
        final qobuz = _ConfigurableStreamingProvider(
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

        final ffiService = FfiAudioService(headless: true);
        addTearDown(ffiService.dispose);
        ffiService.attachStreamingManager(manager);

        var listenerHits = 0;
        manager.addAuthRequiredListener((pid, _) {
          if (pid == 'qobuz') listenerHits++;
        });

        // Non-auth structured errors never trip AuthRequired.
        ffiService.processStateJsonForTest(<String, dynamic>{
          'state_code': 4,
          'position_ms': 0,
          'duration_ms': 1000,
          'device_lost': true,
          'last_error': 'DAC unplugged',
          'last_error_code': 'DEVICE_LOST',
          'last_error_provider': 'qobuz',
          'epoch': 1,
        });
        await Future<void>.delayed(Duration.zero);
        expect(manager.isAuthRequired('qobuz'), isFalse);
        expect(listenerHits, equals(0));

        // Repeated 200ms polls with identical AUTH_REQUIRED error fire exactly ONCE.
        final authStateJson = <String, dynamic>{
          'state_code': 4,
          'position_ms': 12000,
          'duration_ms': 180000,
          'last_error': 'HTTP 401 token revoked',
          'last_error_code': 'AUTH_REQUIRED',
          'last_error_provider': 'qobuz',
          'epoch': 2,
        };
        ffiService.processStateJsonForTest(authStateJson);
        ffiService.processStateJsonForTest(authStateJson);
        ffiService.processStateJsonForTest(authStateJson);
        await Future<void>.delayed(Duration.zero);

        expect(manager.isAuthRequired('qobuz'), isTrue);
        expect(qobuz.authState, equals(StreamingAuthState.authRequired));
        expect(listenerHits, equals(1));
      },
    );
  });

  group('Phase 3 Wave 2B: HomeScreen AuthRequired Sidebar, SnackBar CTA & Clean Exit Order', () {
    testWidgets(
      'authRequired keeps provider in sidebar with red indicator without kicking user out, and SnackBar 重新登入 opens StreamingLoginDialog',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final store = MemorySecureCredentialStore();
        final qobuzTrack = const TrackInfo(
          id: 'qobuz:555',
          title: 'Expired Track',
          artist: 'Tester',
          album: 'Test Album',
          duration: Duration(seconds: 210),
          format: AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: 96000,
            bitDepth: 24,
            channels: 2,
          ),
          providerName: 'Qobuz',
        );
        final qobuz = _ConfigurableStreamingProvider(
          kind: 'qobuz',
          capabilities: ProviderCapabilities.qobuz,
          credentialStore: store,
          onResolve: (key, cancel) async {
            throw const StreamingException(
              'Qobuz 授權已失效（HTTP 401）',
              statusCode: 401,
              isTokenExpired: true,
            );
          },
        )..setCatalog(
          StreamingCatalog(
            tracks: <TrackInfo>[qobuzTrack],
            albums: const <StreamingAlbum>[],
            playlists: const <StreamingPlaylist>[],
          ),
        );

        final manager = StreamingManager(
          credentialStore: store,
          providers: <String, StreamingProvider>{'qobuz': qobuz},
          enableLiveWarmup: false,
        );
        addTearDown(() => manager.disposeAsync());

        final audioService = MockAudioService();
        addTearDown(audioService.dispose);
        final scaleCtrl = UiScaleController(
          initialHomeLayoutPreset: HomeLayoutPreset.classic,
        );
        addTearDown(scaleCtrl.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: audioService,
              uiScaleController: scaleCtrl,
              streamingManager: manager,
              windowController: DesktopWindowController(
                isSupportedOverride: false,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Navigate to Qobuz streaming tab in sidebar.
        expect(find.byKey(const Key('nav_streaming_qobuz')), findsOneWidget);
        await tester.tap(find.byKey(const Key('nav_streaming_qobuz')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('streaming_service_view_qobuz')),
          findsOneWidget,
        );

        // Tap track -> 401 trips AuthRequired -> user STAYS on StreamingServiceView,
        // sidebar keeps Qobuz with red status dot, AND SnackBar shows 重新登入 CTA!
        await tester.tap(find.text('Expired Track'));
        await tester.pumpAndSettle();

        expect(manager.isAuthRequired('qobuz'), isTrue);
        expect(find.byKey(const Key('nav_streaming_qobuz')), findsOneWidget);
        expect(
          find.byKey(const Key('streaming_service_view_qobuz')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('streaming_auth_required_banner_qobuz')),
          findsOneWidget,
        );

        final dotContainer = tester.widget<Container>(
          find.byKey(const Key('nav_streaming_status_dot_qobuz')),
        );
        final dotDecoration = dotContainer.decoration as BoxDecoration;
        expect(dotDecoration.color, equals(LuminaTokens.statusError));

        // Tap SnackBar 重新登入 CTA -> opens StreamingLoginDialog.
        final snackBarAction = find.byKey(
          const Key('snackbar_action_relogin_qobuz'),
        );
        expect(snackBarAction, findsOneWidget);
        await tester.tap(snackBarAction);
        await tester.pumpAndSettle();
        expect(find.byType(StreamingLoginDialog), findsOneWidget);
      },
    );

    testWidgets(
      '_performCleanExit awaits StreamingManager.disposeAsync (PO Token sidecar stop) BEFORE audioService.dispose and windowController.destroy',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1280, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final events = <String>[];
        final tempDir = Directory.systemTemp.createTempSync(
          'lumina_phase3_exit_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        });

        const windowChannel = MethodChannel('lumina/window');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(windowChannel, (call) async {
              if (call.method == 'trayDestroy') {
                events.add('tray_destroy');
              } else if (call.method == 'destroy') {
                events.add('window_destroy');
              }
              return true;
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(windowChannel, null);
        });

        final scaleCtrl = UiScaleController(
          prefsFileOverride: File('${tempDir.path}/ui_prefs.json'),
        );
        scaleCtrl.setMinimizeToTrayOnClose(false);
        addTearDown(scaleCtrl.dispose);

        final persistSvc = PlaybackPersistenceService(
          prefsFileOverride: File('${tempDir.path}/playback.json'),
        );
        addTearDown(persistSvc.dispose);

        final pot = _OrderedShutdownPotProvider(events);
        final store = MemorySecureCredentialStore();
        final ytm = YouTubeMusicProvider(
          credentialStore: store,
          potProvider: pot,
          ownsPotProvider: true,
        );
        final manager = StreamingManager(
          credentialStore: store,
          providers: <String, StreamingProvider>{'youtube_music': ytm},
          enableLiveWarmup: false,
        );
        addTearDown(() => manager.disposeAsync());

        final audioService = _OrderedMockAudioService(events);
        addTearDown(audioService.dispose);

        final winCtrl = DesktopWindowController(isSupportedOverride: true);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: audioService,
              uiScaleController: scaleCtrl,
              windowController: winCtrl,
              streamingManager: manager,
              playbackPersistenceService: persistSvc,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Trigger native close event (minimizeToTrayOnClose == false -> _performCleanExit).
        winCtrl.onWindowClose?.call();
        for (var i = 0; i < 40 && !events.contains('pot_dispose_start'); i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        expect(events, equals(<String>['pot_dispose_start']));
        // audioService.dispose and window destroy MUST NOT have fired yet!
        expect(events.contains('audio_dispose'), isFalse);
        expect(events.contains('window_destroy'), isFalse);

        // Complete PO Token sidecar shutdown and pump until clean exit completes.
        pot.disposeGate.complete();
        for (var i = 0; i < 40 && !events.contains('window_destroy'); i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }

        expect(
          events,
          equals(<String>[
            'pot_dispose_start',
            'pot_dispose_done',
            'audio_dispose',
            'tray_destroy',
            'window_destroy',
          ]),
        );
      },
    );
  });

  group('Phase 3 Wave 2B: GeneralSettingsPanel Loudness Normalization (-14 LUFS)', () {
    testWidgets(
      'updates DspPipelineConfigModel.replayGainMode via audioService and locks cleanly under Strict Bit-Perfect Mode',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1000, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final audioService = MockAudioService();
        addTearDown(audioService.dispose);

        final tempDir = Directory.systemTemp.createTempSync(
          'lumina_phase3_gen_',
        );
        addTearDown(() {
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        });
        final scaleCtrl = UiScaleController(
          prefsFileOverride: File('${tempDir.path}/ui_prefs.json'),
        );
        addTearDown(scaleCtrl.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              body: GeneralSettingsPanel(
                audioService: audioService,
                scaleController: scaleCtrl,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('chip_loudness_mode_off')), findsOneWidget);
        expect(
          find.byKey(const Key('chip_loudness_mode_track')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('chip_loudness_mode_album')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('badge_loudness_strict_locked')),
          findsNothing,
        );

        // Select Track loudness normalization -> persists to audioService DSP config.
        await tester.tap(find.byKey(const Key('chip_loudness_mode_track')));
        await tester.pumpAndSettle();
        expect(
          (await audioService.getDspConfig()).replayGainMode,
          equals(ReplayGainModeOption.track),
        );

        // Select Album loudness normalization.
        await tester.tap(find.byKey(const Key('chip_loudness_mode_album')));
        await tester.pumpAndSettle();
        expect(
          (await audioService.getDspConfig()).replayGainMode,
          equals(ReplayGainModeOption.album),
        );

        // Enable Strict Bit-Perfect Mode -> badge appears and chips disable cleanly.
        await audioService.setStrictBitPerfect(true);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('badge_loudness_strict_locked')),
          findsOneWidget,
        );
        final offChip = tester.widget<ChoiceChip>(
          find.byKey(const Key('chip_loudness_mode_off')),
        );
        expect(offChip.onSelected, isNull);

        // Tapping disabled chip does NOT alter replayGainMode.
        await tester.tap(find.byKey(const Key('chip_loudness_mode_off')));
        await tester.pumpAndSettle();
        expect(
          (await audioService.getDspConfig()).replayGainMode,
          equals(ReplayGainModeOption.album),
        );
      },
    );
  });
}
