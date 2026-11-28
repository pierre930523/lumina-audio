part of 'home_layout_presets_test.dart';

void _registerNavAndResponsivePresetTests() {
  group('5. Sidebar-less Navigation Completeness (AI & AJ)', () {
    for (final preset in const [
      HomeLayoutPreset.topbarMinimal,
      HomeLayoutPreset.auraQuickResume,
    ]) {
      testWidgets(
        '${preset.badgeCode} collapses sidebar and navigates capsule + overflow drawer completely',
        (tester) async {
          _setupMockWindowChannel(tester);
          _setViewport(tester, const Size(1440, 900));
          addTearDown(tester.view.reset);

          final svc = MockAudioService();
          final scaleCtrl = UiScaleController(initialHomeLayoutPreset: preset);
          addTearDown(() {
            svc.dispose();
            scaleCtrl.dispose();
          });

          await tester.pumpWidget(
            LuminaApp(audioService: svc, uiScaleController: scaleCtrl),
          );
          await tester.pumpAndSettle();

          // Sidebar is hidden / 0-width
          final sidebarClip = find.ancestor(
            of: find.byKey(const Key('main_sidebar_glass_container')),
            matching: find.byType(ClipRect),
          ).first;
          expect(tester.getSize(sidebarClip).width, 0.0);
          expect(
            find.byKey(const Key('main_sidebar_glass_container')).hitTestable(),
            findsNothing,
          );

          // Centered capsule primary navigation
          expect(find.byKey(const Key('topbar_floating_nav_capsule')), findsOneWidget);
          await tester.tap(find.byKey(const Key('capsule_nav_albums')));
          await tester.pumpAndSettle();
          expect(find.byType(AlbumsAndCreditsView), findsOneWidget);

          await tester.tap(find.byKey(const Key('capsule_nav_artists')));
          await tester.pumpAndSettle();
          expect(find.byType(ArtistsView), findsOneWidget);

          await tester.tap(find.byKey(const Key('capsule_nav_library')));
          await tester.pumpAndSettle();
          expect(find.byType(LibraryBrowserView), findsOneWidget);

          await tester.tap(find.byKey(const Key('capsule_nav_home')));
          await tester.pumpAndSettle();
          final expectedHomeKey = preset == HomeLayoutPreset.topbarMinimal
              ? const Key('home_layout_ai')
              : const Key('home_layout_aj');
          expect(find.byKey(expectedHomeKey), findsOneWidget);

          // Overflow drawer navigates to folders, tags, listen later, smart playlists, credits & streaming
          const drawerRoutes = <({String key, Type viewType, String expectedKey})>[
            (key: 'drawer_nav_folders', viewType: FoldersView, expectedKey: 'folders_view'),
            (key: 'drawer_nav_tags', viewType: TagsView, expectedKey: 'tags_view'),
            (key: 'drawer_nav_listen_later', viewType: ListenLaterView, expectedKey: 'listen_later_view'),
            (key: 'drawer_nav_smart_playlists', viewType: SmartPlaylistsView, expectedKey: 'smart_playlists_view'),
            (key: 'drawer_nav_credits', viewType: AlbumsAndCreditsView, expectedKey: 'credits_graph_view'),
          ];

          for (final route in drawerRoutes) {
            await tester.tap(find.byKey(const Key('btn_topbar_library_drawer')));
            await tester.pumpAndSettle();
            expect(find.byKey(const Key('topbar_library_drawer_popover')), findsOneWidget);
            final target = find.byKey(Key(route.key));
            await tester.ensureVisible(target);
            await tester.tap(target);
            await tester.pumpAndSettle();
            expect(find.byType(route.viewType), findsOneWidget);
            expect(find.byKey(Key(route.expectedKey)), findsOneWidget);
          }

          // Navigate to a guest/connected streaming service via overflow drawer
          await tester.tap(find.byKey(const Key('btn_topbar_library_drawer')));
          await tester.pumpAndSettle();
          final streamingEntry = find.byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key as ValueKey<String>).value.startsWith('drawer_streaming_'),
          );
          expect(streamingEntry, findsWidgets);
          await tester.ensureVisible(streamingEntry.first);
          await tester.tap(streamingEntry.first);
          await tester.pumpAndSettle();
          expect(find.byType(StreamingServiceView), findsOneWidget);
        },
      );
    }
  });

  group('6. Responsive Scale, Light/Dark Contrast, Placeholders & Pill Geometry', () {
    test('LuminaGlassTheme.light and .dark text tokens satisfy WCAG AA >= 4.5:1', () {
      for (final glass in const [LuminaGlassTheme.dark, LuminaGlassTheme.light]) {
        for (final bg in [
          glass.canvasBg,
          glass.glassBg,
          glass.glassBgElevated,
          glass.sidebarBg,
          glass.playerBarBg,
        ]) {
          expect(
            LuminaTokens.contrastRatio(glass.textPrimary, bg, fallbackBg: glass.canvasBg),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            LuminaTokens.contrastRatio(glass.textSecondary, bg, fallbackBg: glass.canvasBg),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            LuminaTokens.contrastRatio(glass.textTertiary, bg, fallbackBg: glass.canvasBg),
            greaterThanOrEqualTo(4.5),
          );
        }
      }
    });

    testWidgets(
      'Missing cover uses low-saturation theme gradient + music icon without gray broken placeholder',
      (tester) async {
        for (final mode in const [ThemeMode.light, ThemeMode.dark]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: LuminaTokens.buildLightTheme(),
              darkTheme: LuminaTokens.buildDarkTheme(),
              themeMode: mode,
              home: const Scaffold(
                body: Center(
                  child: AlbumArtworkView(size: 160, frameless: true),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final expectedGlass = mode == ThemeMode.light
              ? LuminaGlassTheme.light
              : LuminaGlassTheme.dark;
          expect(find.byType(Image), findsNothing);
          final noteIcon = tester.widget<Icon>(find.byIcon(Icons.music_note_rounded));
          expect(noteIcon.color, expectedGlass.emptyCoverIconColor);

          final containers = tester.widgetList<Container>(find.byType(Container));
          final hasGradient = containers.any((c) {
            final dec = c.decoration;
            return dec is BoxDecoration &&
                dec.gradient is LinearGradient &&
                (dec.gradient as LinearGradient).colors.length >= 2 &&
                (dec.gradient as LinearGradient).colors.first ==
                    expectedGlass.emptyCoverGradient.first;
          });
          expect(hasGradient, isTrue);
        }
      },
    );

    testWidgets(
      'AI/AJ render zero overflow, zero overlap & inset rounded floating pill across scales, themes & sizes',
      (tester) async {
        _setupMockWindowChannel(tester);
        addTearDown(tester.view.reset);

        final svc = MockAudioService();
        final scaleCtrl = UiScaleController();
        addTearDown(() {
          svc.dispose();
          scaleCtrl.dispose();
        });

        await tester.pumpWidget(LuminaApp(audioService: svc, uiScaleController: scaleCtrl));
        await tester.pumpAndSettle();

        const presets = [
          HomeLayoutPreset.topbarMinimal,
          HomeLayoutPreset.auraQuickResume,
        ];
        const sizes = [
          Size(800, 600),
          Size(1280, 800),
          Size(1440, 900),
          Size(1920, 1080),
        ];

        for (final mode in const [ThemeMode.light, ThemeMode.dark]) {
          scaleCtrl.setThemeMode(mode);
          for (final preset in presets) {
            scaleCtrl.setHomeLayoutPreset(preset);
            for (final scale in const [1.0, 1.5]) {
              scaleCtrl.setScale(scale);
              for (final sz in sizes) {
                _setViewport(tester, sz);
                await tester.pumpAndSettle();
                expect(
                  tester.takeException(),
                  isNull,
                  reason: 'Exception at $mode $preset ${scale}x $sz',
                );

                // Floating capsule must be rounded, horizontally inset, and above bottom edge.
                final capsuleFinder = find.byKey(const Key('liquid_glass_capsule'));
                expect(capsuleFinder, findsOneWidget);
                final capsuleContainer = tester.widget<Container>(capsuleFinder);
                final boxDec = capsuleContainer.decoration! as BoxDecoration;
                expect(boxDec.borderRadius, BorderRadius.circular(22.0));

                final pillRect = tester.getRect(capsuleFinder);
                expect(pillRect.left, greaterThanOrEqualTo(10.0));
                expect(sz.width - pillRect.right, greaterThanOrEqualTo(10.0));
                expect(sz.height - pillRect.bottom, greaterThanOrEqualTo(6.0));
                expect(pillRect.top, greaterThan(0.0));

                // Verify quick-resume cards never overlap each other in AJ.
                if (preset == HomeLayoutPreset.auraQuickResume) {
                  final card0 = find.byKey(const Key('aj_quick_card_0'));
                  final card1 = find.byKey(const Key('aj_quick_card_1'));
                  if (card0.evaluate().isNotEmpty && card1.evaluate().isNotEmpty) {
                    expect(
                      tester.getRect(card0).overlaps(tester.getRect(card1)),
                      isFalse,
                    );
                  }
                }

                // Verify top capsule & layout switcher don't overlap wordmark on desktop sidebar-less view.
                if (preset.isSidebarless && sz.width >= 1280 && scale == 1.0) {
                  final wordmark = find.byKey(const Key('topbar_brand_wordmark'));
                  final capsuleNav = find.byKey(const Key('topbar_floating_nav_capsule'));
                  final switcherBtn = find.byKey(const Key('btn_home_layout_switcher'));
                  expect(
                    tester.getRect(wordmark).overlaps(tester.getRect(capsuleNav)),
                    isFalse,
                  );
                  expect(
                    tester.getRect(capsuleNav).overlaps(tester.getRect(switcherBtn)),
                    isFalse,
                  );
                }
              }
            }
          }
        }
      },
    );
  });
}
