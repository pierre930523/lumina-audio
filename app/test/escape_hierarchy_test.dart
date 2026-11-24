import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/nav_entry.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/desktop_window_controller.dart';
import 'package:lumina_app/services/escape_dismiss_registry.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/now_playing_view_controller.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_provider.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

class _CancellableAuthProvider extends BaseStreamingProvider {
  bool cancelledDuringAuth = false;

  _CancellableAuthProvider({required super.credentialStore});

  @override
  String get kind => 'qobuz';

  @override
  Future<void> authenticate(
    Map<String, dynamic> params, {
    CancellationToken? cancel,
    void Function(String statusMsg)? onProgress,
  }) async {
    onProgress?.call('等待驗證完成...');
    final completer = Completer<void>();
    cancel?.addListener(() {
      cancelledDuringAuth = true;
      if (!completer.isCompleted) {
        completer.completeError(
          failWithError(
            const StreamingException('操作已取消', isCancelled: true),
          ),
        );
      }
    });
    await completer.future;
  }

  @override
  Future<void> restoreFromStorage() async {}

  @override
  Future<void> refreshSessionIfNeeded() async {}

  @override
  Future<void> logout() async => resetState();

  @override
  Future<StreamingCatalog> syncLibrary({CancellationToken? cancel}) async =>
      StreamingCatalog.empty();

  @override
  Future<List<TrackInfo>> fetchPlaylistTracks(String playlistId) async =>
      const [];

  @override
  Future<StreamingCatalog> search(
    String query, {
    CancellationToken? cancel,
  }) async =>
      StreamingCatalog.empty();

  @override
  Future<ResolvedStreamResult> resolveStream(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
  }) =>
      throw UnimplementedError();
}

bool _hasEditableTextFocus() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  if (ctx.widget is EditableText) return true;
  return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}

Future<void> _sendEscapeWithRepeats(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
  await tester.pump();
  await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
  await tester.pump();
  await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
  await tester.pump();
  await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EscapeDismissRegistry unit tests', () {
    tearDown(() {
      EscapeDismissRegistry.instance.clear();
    });

    test('dispatches in LIFO order, supports fallthrough, and clears cleanly', () {
      final calls = <String>[];
      late bool Function() h1;
      late bool Function() h2;
      late bool Function() h3;

      h1 = () {
        calls.add('h1');
        EscapeDismissRegistry.instance.unregister(h1);
        return true;
      };
      h2 = () {
        calls.add('h2');
        return false; // Simulate inactive handler falling through.
      };
      h3 = () {
        calls.add('h3');
        EscapeDismissRegistry.instance.unregister(h3);
        return true;
      };

      final registry = EscapeDismissRegistry.instance;
      expect(registry.hasActive, isFalse);

      registry.register(h1);
      registry.register(h2);
      registry.register(h3);
      // Re-registering h1 moves it to the top without duplicating.
      registry.register(h1);
      expect(registry.hasActive, isTrue);

      expect(registry.dismissTopmost(), isTrue);
      expect(calls, ['h1']);

      // Next topmost is h3.
      expect(registry.dismissTopmost(), isTrue);
      expect(calls, ['h1', 'h3']);

      // Remaining h2 returns false -> dismissTopmost returns false.
      expect(registry.dismissTopmost(), isFalse);
      expect(calls, ['h1', 'h3', 'h2']);

      registry.clear();
      expect(registry.hasActive, isFalse);
    });
  });

  group('HomeScreen 5-level hierarchical Esc handling', () {
    late MockAudioService audioService;
    late DesktopWindowController windowController;
    late bool mockFullScreen;

    setUp(() {
      EscapeDismissRegistry.instance.clear();
      mockFullScreen = false;
      audioService = MockAudioService();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('lumina/window'),
        (MethodCall call) async {
          switch (call.method) {
            case 'isFullScreen':
              return mockFullScreen;
            case 'setFullScreen':
              mockFullScreen = call.arguments as bool;
              return null;
            case 'toggleFullScreen':
              mockFullScreen = !mockFullScreen;
              return null;
            case 'isMaximized':
              return false;
            default:
              return null;
          }
        },
      );
      windowController = DesktopWindowController(isSupportedOverride: true);
      DesktopWindowController.instance = windowController;
    });

    tearDown(() {
      EscapeDismissRegistry.instance.clear();
      DesktopWindowController.instance = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('lumina/window'), null);
      audioService.dispose();
    });

    testWidgets(
      'Level 1: TextField unfocus runs first without exiting fullscreen or navigating back',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final nav = NavHistoryController();
        addTearDown(nav.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: audioService,
              windowController: windowController,
              navHistoryController: nav,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('nav_tab_library')));
        await tester.pumpAndSettle();
        expect(nav.canGoBack, isTrue);

        await windowController.setFullScreen(true);
        mockFullScreen = true;
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('library_search_input')));
        await tester.pumpAndSettle();
        expect(_hasEditableTextFocus(), isTrue);

        // 1st Esc: unfocus TextField only.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(_hasEditableTextFocus(), isFalse);
        expect(windowController.isFullScreenNotifier.value, isTrue);
        expect(nav.current.tab, HomeTab.library);

        // 2nd Esc: exit fullscreen (still on Library).
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(windowController.isFullScreenNotifier.value, isFalse);
        expect(nav.current.tab, HomeTab.library);

        // 3rd Esc: navigate back to Home.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(nav.current.tab, HomeTab.home);
      },
    );

    testWidgets(
      'Level 2a: OverlayEntry popovers (capsule queue/output & album layout) dismiss in LIFO order before fullscreen/nav',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final nav = NavHistoryController();
        addTearDown(nav.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: audioService,
              windowController: windowController,
              navHistoryController: nav,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('nav_tab_albums')));
        await tester.pumpAndSettle();

        // Open output popover -> Esc closes it.
        await tester.tap(find.byKey(const Key('btn_quick_output_popover')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('quick_output_popover')), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('quick_output_popover')), findsNothing);
        expect(nav.current.tab, HomeTab.albums);

        // Open quick queue popover -> Esc closes it.
        await tester.tap(find.byKey(const Key('btn_quick_queue_popover')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('quick_queue_popover')), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('quick_queue_popover')), findsNothing);
        expect(nav.current.tab, HomeTab.albums);

        // Open album layout popover AND push a higher floating handler -> LIFO closes top handler first, then album layout.
        await tester.tap(find.byKey(const Key('btn_album_layout_settings')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('album_layout_popover')), findsOneWidget);

        var topDismissed = false;
        late bool Function() topHandler;
        topHandler = () {
          topDismissed = true;
          EscapeDismissRegistry.instance.unregister(topHandler);
          return true;
        };
        EscapeDismissRegistry.instance.register(topHandler);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(topDismissed, isTrue);
        expect(find.byKey(const Key('album_layout_popover')), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('album_layout_popover')), findsNothing);
        expect(nav.current.tab, HomeTab.albums);
      },
    );

    testWidgets(
      'Level 2b: Navigator dialog (SignalPathModal & StreamingLoginDialog) cancels active auth on Esc after text unfocus',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final credStore = MemorySecureCredentialStore();
        final fakeQobuz = _CancellableAuthProvider(credentialStore: credStore);
        final streamingManager = StreamingManager(
          credentialStore: credStore,
          providers: <String, StreamingProvider>{'qobuz': fakeQobuz},
        );
        addTearDown(streamingManager.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: audioService,
              windowController: windowController,
              streamingManager: streamingManager,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // SignalPathModal closes via Esc.
        await tester.tap(find.byKey(const Key('quality_badge_button')));
        await tester.pumpAndSettle();
        expect(find.text('音訊訊號路徑'), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('音訊訊號路徑'), findsNothing);

        // Open Settings -> Streaming Login Dialog for Qobuz.
        await tester.tap(find.byKey(const Key('btn_open_settings_hub')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav_tab_settings')));
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.byKey(const Key('btn_signin_qobuz')));
        await tester.tap(find.byKey(const Key('btn_signin_qobuz')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('streaming_login_dialog_qobuz')),
          findsOneWidget,
        );

        // Expand manual login section, then focus a field inside the dialog:
        // 1st Esc unfocuses TextField without closing dialog.
        await tester.tap(
          find.byKey(const Key('btn_toggle_manual_token_section')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('input_qobuz_email')));
        await tester.pumpAndSettle();
        expect(_hasEditableTextFocus(), isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(_hasEditableTextFocus(), isFalse);
        expect(
          find.byKey(const Key('streaming_login_dialog_qobuz')),
          findsOneWidget,
        );

        // Start in-progress login; Esc pops StreamingLoginDialog and cancels active auth.
        await tester.tap(find.byKey(const Key('btn_dialog_submit_login')));
        await tester.pump();
        expect(streamingManager.isAuthenticating('qobuz'), isTrue);
        expect(fakeQobuz.cancelledDuringAuth, isFalse);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('streaming_login_dialog_qobuz')),
          findsNothing,
        );
        expect(fakeQobuz.cancelledDuringAuth, isTrue);
        expect(streamingManager.isAuthenticating('qobuz'), isFalse);
      },
    );

    testWidgets(
      'Level 5: Back navigation works from AlbumDetail, ArtistDetail, and Settings subpage',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final cache = LibraryIndexCache();
        addTearDown(cache.dispose);
        cache.putAlbumDetailSync(
          const CanonicalAlbumDetail(
            id: 'alb-esc-1',
            title: 'Wish You Were Here',
            artistName: 'Pink Floyd',
            releaseYear: 1975,
            versions: [],
          ),
        );

        final nav = NavHistoryController();
        addTearDown(nav.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: audioService,
              windowController: windowController,
              libraryCache: cache,
              navHistoryController: nav,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Push AlbumDetail -> Esc returns to Home.
        nav.push(NavEntry.album('alb-esc-1'));
        await tester.pumpAndSettle();
        expect(nav.current.tab, HomeTab.albumDetail);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(nav.current.tab, HomeTab.home);

        // Push ArtistDetail -> Esc returns to Home.
        nav.push(NavEntry.artist(artistName: 'Pink Floyd'));
        await tester.pumpAndSettle();
        expect(nav.current.tab, HomeTab.artistDetail);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(nav.current.tab, HomeTab.home);

        // Open Settings -> DSP subpage -> Esc steps back to General, then Home.
        await tester.tap(find.byKey(const Key('btn_open_settings_hub')));
        await tester.pumpAndSettle();
        expect(nav.current.tab, HomeTab.general);

        await tester.tap(find.byKey(const Key('nav_tab_dsp')));
        await tester.pumpAndSettle();
        expect(nav.current.tab, HomeTab.dsp);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(nav.current.tab, HomeTab.general);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(nav.current.tab, HomeTab.home);

        // Esc at root with nothing active is a safe no-op.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(nav.current.tab, HomeTab.home);
      },
    );

    testWidgets(
      'Combined multi-layer cascade: consumes strictly 1 layer per Esc press and KeyRepeatEvent never cascades',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final cache = LibraryIndexCache();
        addTearDown(cache.dispose);
        cache.putAlbumDetailSync(
          const CanonicalAlbumDetail(
            id: 'alb-cascade-1',
            title: 'Animals',
            artistName: 'Pink Floyd',
            releaseYear: 1977,
            versions: [],
          ),
        );

        final nav = NavHistoryController();
        addTearDown(nav.dispose);
        final nowPlayingCtrl = NowPlayingViewController();
        addTearDown(nowPlayingCtrl.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: audioService,
              windowController: windowController,
              libraryCache: cache,
              navHistoryController: nav,
              nowPlayingController: nowPlayingCtrl,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Build Level 5: Home -> Albums -> AlbumDetail.
        await tester.tap(find.byKey(const Key('nav_tab_albums')));
        await tester.pumpAndSettle();
        nav.push(NavEntry.album('alb-cascade-1'));
        await tester.pumpAndSettle();
        expect(nav.current.tab, HomeTab.albumDetail);

        // Build Level 4: Expand Now Playing.
        await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('now_playing_overlay')), findsOneWidget);

        // Build Level 3: Enter Fullscreen.
        await windowController.setFullScreen(true);
        mockFullScreen = true;
        await tester.pumpAndSettle();
        expect(windowController.isFullScreenNotifier.value, isTrue);

        // Build Level 2c: Open Lyrics Settings toolbar.
        await tester.tap(find.byKey(const Key('btn_lyrics_toolbar_toggle')));
        await tester.pumpAndSettle();
        expect(nowPlayingCtrl.lyricsSettingsExpanded, isTrue);
        expect(find.byKey(const Key('btn_lyrics_font_down')), findsOneWidget);

        // Build Level 2a: Open Quick Queue popover.
        await tester.tap(find.byKey(const Key('btn_quick_queue_popover')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('quick_queue_popover')), findsOneWidget);

        // Step 1 (Level 2a): Dismiss Quick Queue popover ONLY (repeats ignored).
        await _sendEscapeWithRepeats(tester);
        expect(find.byKey(const Key('quick_queue_popover')), findsNothing);
        expect(nowPlayingCtrl.lyricsSettingsExpanded, isTrue);
        expect(windowController.isFullScreenNotifier.value, isTrue);
        expect(find.byKey(const Key('now_playing_overlay')), findsOneWidget);
        expect(nav.current.tab, HomeTab.albumDetail);

        // Step 2 (Level 2c): Collapse Lyrics Settings toolbar ONLY (repeats ignored).
        await _sendEscapeWithRepeats(tester);
        expect(nowPlayingCtrl.lyricsSettingsExpanded, isFalse);
        expect(find.byKey(const Key('btn_lyrics_font_down')), findsNothing);
        expect(windowController.isFullScreenNotifier.value, isTrue);
        expect(find.byKey(const Key('now_playing_overlay')), findsOneWidget);
        expect(nav.current.tab, HomeTab.albumDetail);

        // Step 3 (Level 3): Exit Fullscreen ONLY (repeats ignored).
        await _sendEscapeWithRepeats(tester);
        expect(windowController.isFullScreenNotifier.value, isFalse);
        expect(find.byKey(const Key('now_playing_overlay')), findsOneWidget);
        expect(nav.current.tab, HomeTab.albumDetail);

        // Step 4 (Level 4): Collapse Now Playing ONLY (repeats ignored).
        await _sendEscapeWithRepeats(tester);
        expect(find.byKey(const Key('now_playing_overlay')), findsNothing);
        expect(nav.current.tab, HomeTab.albumDetail);

        // Step 5a (Level 5): Back from AlbumDetail to Albums ONLY (repeats ignored).
        await _sendEscapeWithRepeats(tester);
        expect(nav.current.tab, HomeTab.albums);

        // Step 5b (Level 5): Back from Albums to Home.
        await _sendEscapeWithRepeats(tester);
        expect(nav.current.tab, HomeTab.home);
      },
    );
  });
}
