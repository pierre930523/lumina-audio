import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/main.dart';
import 'package:lumina_app/models/nav_entry.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:lumina_app/ui/library/library_browser_view.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('HomeScreen Desktop Shortcuts & Dynamic Sticky Title', () {
    testWidgets('Preserves all required top-bar and nav keys', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final service = MockAudioService();
      addTearDown(service.dispose);

      await tester.pumpWidget(LuminaApp(audioService: service));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('btn_nav_back')), findsOneWidget);
      expect(find.byKey(const Key('btn_nav_forward')), findsOneWidget);
      expect(find.byKey(const Key('btn_open_settings_hub')), findsOneWidget);
      expect(find.byKey(const Key('btn_quick_scale_menu')), findsOneWidget);
      expect(find.byKey(const Key('nav_tab_home')), findsOneWidget);
      expect(find.byKey(const Key('nav_tab_albums')), findsOneWidget);
      expect(find.byKey(const Key('nav_tab_library')), findsOneWidget);
    });

    testWidgets('Global shortcuts: Space toggles play/pause when not in text field', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final service = MockAudioService();
      addTearDown(service.dispose);

      await tester.pumpWidget(LuminaApp(audioService: service));
      await tester.pumpAndSettle();

      final initialStatus = service.currentState.status;

      // Press Space -> toggles play/pause
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(service.currentState.status != initialStatus, isTrue);

      // Press Space again -> toggles back
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(service.currentState.status, initialStatus);
    });

    testWidgets('Global shortcuts: Alt+Left / Backspace go back, Alt+Right goes forward', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final service = MockAudioService();
      addTearDown(service.dispose);

      await tester.pumpWidget(LuminaApp(audioService: service));
      await tester.pumpAndSettle();

      // Navigate to Albums
      await tester.tap(find.byKey(const Key('nav_tab_albums')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('album_grid_view')), findsOneWidget);

      // Alt + Left -> goes back to Home
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home_dashboard_view')), findsOneWidget);

      // Alt + Right -> goes forward to Albums
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('album_grid_view')), findsOneWidget);

      // Backspace -> goes back to Home
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home_dashboard_view')), findsOneWidget);
    });

    testWidgets('Global shortcuts: Ctrl+F expands & focuses top search box while nav_tab_library opens LibraryBrowserView', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final service = MockAudioService();
      addTearDown(service.dispose);

      await tester.pumpWidget(LuminaApp(audioService: service));
      await tester.pumpAndSettle();

      // Ensure we start on home with top search collapsed
      expect(find.byKey(const Key('home_dashboard_view')), findsOneWidget);
      expect(find.byKey(const Key('btn_top_search_toggle')), findsOneWidget);
      expect(find.byKey(const Key('top_search_input')), findsNothing);

      // Press Ctrl + F -> expands & focuses top_search_input
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('top_search_input')), findsOneWidget);
      expect(find.byKey(const Key('btn_top_search_toggle')), findsNothing);
      final focusCtx = FocusManager.instance.primaryFocus?.context;
      expect(focusCtx, isNotNull);
      expect(
        focusCtx!.widget is EditableText ||
            focusCtx.findAncestorWidgetOfExactType<EditableText>() != null,
        isTrue,
      );

      // Sidebar nav_tab_library still navigates to LibraryBrowserView
      await tester.tap(find.byKey(const Key('nav_tab_library')));
      await tester.pumpAndSettle();
      expect(find.byType(LibraryBrowserView), findsOneWidget);
      expect(find.byKey(const Key('library_search_input')), findsOneWidget);
    });

    testWidgets('Global shortcuts: M toggles mute', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final service = MockAudioService();
      addTearDown(service.dispose);

      await tester.pumpWidget(LuminaApp(audioService: service));
      await tester.pumpAndSettle();

      expect(service.currentState.isMuted, isFalse);

      // Press M -> mute
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pumpAndSettle();
      expect(service.currentState.isMuted, isTrue);

      // Press M again -> unmute
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pumpAndSettle();
      expect(service.currentState.isMuted, isFalse);
    });

    testWidgets('Global shortcuts: Escape collapses Now Playing overlay', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final service = MockAudioService();
      addTearDown(service.dispose);

      await tester.pumpWidget(LuminaApp(audioService: service));
      await tester.pumpAndSettle();

      // Expand now playing overlay
      await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('now_playing_overlay')), findsOneWidget);

      // Press Escape -> collapses overlay
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('now_playing_overlay')), findsNothing);
      expect(find.byKey(const Key('home_dashboard_view')), findsOneWidget);
    });

    testWidgets('Global shortcuts: Typing in TextField does NOT trigger Space/M/Backspace shortcuts', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final service = MockAudioService();
      addTearDown(service.dispose);

      await tester.pumpWidget(LuminaApp(audioService: service));
      await tester.pumpAndSettle();

      // Go to Library search tab
      await tester.tap(find.byKey(const Key('nav_tab_library')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('library_search_input')), findsOneWidget);

      // Focus the search text input
      await tester.tap(find.byKey(const Key('library_search_input')));
      await tester.pumpAndSettle();

      final initialStatus = service.currentState.status;
      final initialMute = service.currentState.isMuted;

      // Press Space while focused on text input -> must not toggle playback
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(service.currentState.status, initialStatus);

      // Press M while focused on text input -> must not toggle mute
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.pumpAndSettle();
      expect(service.currentState.isMuted, initialMute);

      // Press Backspace while focused on text input -> must not navigate back
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('library_search_input')), findsOneWidget);
    });

    testWidgets('Top bar sticky title: shows album title on scroll > 200 in AlbumDetailPage', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final service = MockAudioService();
      addTearDown(service.dispose);

      final cache = LibraryIndexCache();
      addTearDown(cache.dispose);
      cache.putAlbumDetailSync(
        const CanonicalAlbumDetail(
          id: 'test-album-1',
          title: 'The Dark Side of the Moon',
          artistName: 'Pink Floyd',
          releaseYear: 1973,
          versions: [
            AlbumVersionInfo(
              id: 'ver-1',
              provider: 'local',
              externalAlbumId: 'ext-1',
              editionLabel: 'Original Master',
              codec: 'flac',
              sampleRateHz: 96000,
              bitDepth: 24,
              tracks: [
                AlbumVersionTrackInfo(
                  id: 't-1',
                  title: 'Speak to Me',
                  discNumber: 1,
                  trackNumber: 1,
                  durationMs: 90000,
                  codec: 'flac',
                  sampleRateHz: 96000,
                  bitDepth: 24,
                  externalTrackId: 'ext-t-1',
                ),
                AlbumVersionTrackInfo(
                  id: 't-2',
                  title: 'Breathe',
                  discNumber: 1,
                  trackNumber: 2,
                  durationMs: 163000,
                  codec: 'flac',
                  sampleRateHz: 96000,
                  bitDepth: 24,
                  externalTrackId: 'ext-t-2',
                ),
                AlbumVersionTrackInfo(
                  id: 't-3',
                  title: 'On the Run',
                  discNumber: 1,
                  trackNumber: 3,
                  durationMs: 216000,
                  codec: 'flac',
                  sampleRateHz: 96000,
                  bitDepth: 24,
                  externalTrackId: 'ext-t-3',
                ),
                AlbumVersionTrackInfo(
                  id: 't-4',
                  title: 'Time',
                  discNumber: 1,
                  trackNumber: 4,
                  durationMs: 421000,
                  codec: 'flac',
                  sampleRateHz: 96000,
                  bitDepth: 24,
                  externalTrackId: 'ext-t-4',
                ),
                AlbumVersionTrackInfo(
                  id: 't-5',
                  title: 'The Great Gig in the Sky',
                  discNumber: 1,
                  trackNumber: 5,
                  durationMs: 276000,
                  codec: 'flac',
                  sampleRateHz: 96000,
                  bitDepth: 24,
                  externalTrackId: 'ext-t-5',
                ),
                AlbumVersionTrackInfo(
                  id: 't-6',
                  title: 'Money',
                  discNumber: 1,
                  trackNumber: 6,
                  durationMs: 382000,
                  codec: 'flac',
                  sampleRateHz: 96000,
                  bitDepth: 24,
                  externalTrackId: 'ext-t-6',
                ),
                AlbumVersionTrackInfo(
                  id: 't-7',
                  title: 'Us and Them',
                  discNumber: 1,
                  trackNumber: 7,
                  durationMs: 462000,
                  codec: 'flac',
                  sampleRateHz: 96000,
                  bitDepth: 24,
                  externalTrackId: 'ext-t-7',
                ),
                AlbumVersionTrackInfo(
                  id: 't-8',
                  title: 'Any Colour You Like',
                  discNumber: 1,
                  trackNumber: 8,
                  durationMs: 205000,
                  codec: 'flac',
                  sampleRateHz: 96000,
                  bitDepth: 24,
                  externalTrackId: 'ext-t-8',
                ),
                AlbumVersionTrackInfo(
                  id: 't-9',
                  title: 'Brain Damage',
                  discNumber: 1,
                  trackNumber: 9,
                  durationMs: 228000,
                  codec: 'flac',
                  sampleRateHz: 96000,
                  bitDepth: 24,
                  externalTrackId: 'ext-t-9',
                ),
                AlbumVersionTrackInfo(
                  id: 't-10',
                  title: 'Eclipse',
                  discNumber: 1,
                  trackNumber: 10,
                  durationMs: 123000,
                  codec: 'flac',
                  sampleRateHz: 96000,
                  bitDepth: 24,
                  externalTrackId: 'ext-t-10',
                ),
              ],
            ),
          ],
        ),
      );

      final nav = NavHistoryController(
        initialEntry: NavEntry.album('test-album-1'),
      );
      addTearDown(nav.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaTokens.buildDarkTheme(),
          home: HomeScreen(
            audioService: service,
            libraryCache: cache,
            navHistoryController: nav,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially at offset 0, top_bar_sticky_title FadeTransition opacity is 0.0
      final stickyTitleFinder = find.byKey(const Key('top_bar_sticky_title'));
      expect(stickyTitleFinder, findsOneWidget);
      final fadeAtZero = tester.widget<FadeTransition>(
        find.ancestor(of: stickyTitleFinder, matching: find.byType(FadeTransition)).first,
      );
      expect(fadeAtZero.opacity.value, 0.0);

      // Scroll detail page past 200px
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -350));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      // Top bar sticky title is now visible with opacity 1.0 and displays the album title
      final fadePast200 = tester.widget<FadeTransition>(
        find.ancestor(of: stickyTitleFinder, matching: find.byType(FadeTransition)).first,
      );
      expect(fadePast200.opacity.value, 1.0);
      final textWidget = tester.widget<Text>(stickyTitleFinder);
      expect(textWidget.data, 'The Dark Side of the Moon');

      // Scroll back up to top (offset < 200)
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 350));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      // Fades back to 0.0
      final fadeBackAtTop = tester.widget<FadeTransition>(
        find.ancestor(of: stickyTitleFinder, matching: find.byType(FadeTransition)).first,
      );
      expect(fadeBackAtTop.opacity.value, 0.0);
    });

    testWidgets('Top bar sticky title: shows artist name on scroll > 200 in ArtistDetailPage', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final service = MockAudioService();
      addTearDown(service.dispose);

      final cache = LibraryIndexCache();
      addTearDown(cache.dispose);
      cache.seedFromQueueSync(service.queue);
      await cache.prime(service);

      final nav = NavHistoryController(
        initialEntry: NavEntry.artist(artistName: 'Pink Floyd'),
      );
      addTearDown(nav.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaTokens.buildDarkTheme(),
          home: HomeScreen(
            audioService: service,
            libraryCache: cache,
            navHistoryController: nav,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final stickyTitleFinder = find.byKey(const Key('top_bar_sticky_title'));
      expect(stickyTitleFinder, findsOneWidget);
      final fadeAtZero = tester.widget<FadeTransition>(
        find.ancestor(of: stickyTitleFinder, matching: find.byType(FadeTransition)).first,
      );
      expect(fadeAtZero.opacity.value, 0.0);

      // Scroll artist detail past 200px
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -350));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();

      final fadePast200 = tester.widget<FadeTransition>(
        find.ancestor(of: stickyTitleFinder, matching: find.byType(FadeTransition)).first,
      );
      expect(fadePast200.opacity.value, 1.0);
      final textWidget = tester.widget<Text>(stickyTitleFinder);
      expect(textWidget.data, 'Pink Floyd');
    });
  });
}
