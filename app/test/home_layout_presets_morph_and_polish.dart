part of 'home_layout_presets_test.dart';

class _PagedAlbumsMockAudioService extends MockAudioService {
  late final List<CanonicalAlbumSummary> _manyAlbums = [
    for (var i = 1; i <= 8; i++)
      CanonicalAlbumSummary(
        id: 'alb-page-$i',
        title: 'Gallery Album $i',
        artist: 'Artist $i',
        year: 2018 + i,
      ),
  ];

  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({
    int limit = 100,
    bool includeHidden = false,
  }) async {
    return _manyAlbums.take(limit).toList(growable: false);
  }
}

void _registerMorphAndPolishPresetTests() {
  group('7. Visual Polish, True Centering & Capsule-Origin Morph', () {
    testWidgets(
      'AJ TopAmbientAura spans full viewport continuously above top bar and scroll area with complete-column paging and zero ShaderMask',
      (tester) async {
        _setupMockWindowChannel(tester);
        _setViewport(tester, const Size(1440, 900));
        addTearDown(tester.view.reset);

        final svc = _PagedAlbumsMockAudioService();
        final scaleCtrl = UiScaleController(
          initialHomeLayoutPreset: HomeLayoutPreset.auraQuickResume,
        )..setScale(1.5);
        addTearDown(() {
          svc.dispose();
          scaleCtrl.dispose();
        });

        await tester.pumpWidget(
          LuminaApp(audioService: svc, uiScaleController: scaleCtrl),
        );
        await tester.pumpAndSettle();

        final ajScrollFinder = find.byKey(const Key('home_layout_aj'));
        final auraFinder = find.byKey(const Key('aj_top_ambient_aura'));
        expect(ajScrollFinder, findsOneWidget);
        expect(auraFinder, findsOneWidget);

        // TopAmbientAura lives on the full-screen ambient canvas (not trapped inside AJ scroll box)
        // so both header and scroll view float continuously with zero seams.
        expect(
          find.ancestor(of: auraFinder, matching: ajScrollFinder),
          findsNothing,
        );
        expect(tester.getRect(auraFinder).top, closeTo(0.0, 0.5));
        expect(tester.getRect(ajScrollFinder).top, closeTo(0.0, 0.5));
        expect(
          find.descendant(
            of: find.byType(TopAmbientAura),
            matching: find.byType(ShaderMask),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: find.byType(MinimalAlbumRow),
            matching: find.byType(ShaderMask),
          ),
          findsNothing,
        );

        final cards = find.byType(MinimalAlbumCard);
        expect(cards, findsWidgets);
        for (final el in cards.evaluate()) {
          final cardRect = tester.getRect(find.byWidget(el.widget));
          expect(cardRect.left, greaterThanOrEqualTo(0.0));
          expect(cardRect.right, lessThanOrEqualTo(1440.0 + 0.5));
        }

        // Verify ghost pager advances complete columns cleanly when > 1 page.
        expect(find.byKey(const Key('minimal_album_card_new_alb-page-1')), findsOneWidget);
        final nextPageBtns = find.descendant(
          of: find.byKey(const Key('aj_explore_row')),
          matching: find.byTooltip('下一頁'),
        );
        expect(nextPageBtns, findsOneWidget);
        await tester.ensureVisible(nextPageBtns);
        await tester.pumpAndSettle();
        await tester.tap(nextPageBtns);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('minimal_album_card_new_alb-page-5')), findsOneWidget);

        // Scrolling past threshold keeps TopAmbientAura continuous with zero vertical cut.
        await tester.drag(ajScrollFinder, const Offset(0, -180));
        await tester.pumpAndSettle();
        expect(tester.getRect(auraFinder).top, closeTo(0.0, 0.5));
      },
    );

    testWidgets(
      'AI truly window-centers top nav capsule with segment/pill harmony and refined missing-cover medallion',
      (tester) async {
        _setupMockWindowChannel(tester);
        _setViewport(tester, const Size(1440, 900));
        addTearDown(tester.view.reset);

        final svc = _PagedAlbumsMockAudioService();
        final scaleCtrl = UiScaleController(
          initialHomeLayoutPreset: HomeLayoutPreset.topbarMinimal,
        );
        addTearDown(() {
          svc.dispose();
          scaleCtrl.dispose();
        });

        await tester.pumpWidget(
          LuminaApp(audioService: svc, uiScaleController: scaleCtrl),
        );
        await tester.pumpAndSettle();

        final topCapsuleRect = tester.getRect(
          find.byKey(const Key('topbar_floating_nav_capsule')),
        );
        final segBarRect = tester.getRect(
          find.byKey(const Key('ai_segment_bar')),
        );
        final bottomPillRect = tester.getRect(
          find.byKey(const Key('liquid_glass_capsule')),
        );
        final wallRect = tester.getRect(
          find.byKey(const Key('ai_album_wall')),
        );

        expect((topCapsuleRect.center.dx - 720.0).abs(), lessThanOrEqualTo(1.5));
        expect(
          (topCapsuleRect.center.dx - segBarRect.center.dx).abs(),
          lessThanOrEqualTo(1.5),
        );
        expect(
          (topCapsuleRect.center.dx - bottomPillRect.center.dx).abs(),
          lessThanOrEqualTo(1.5),
        );
        expect(wallRect.bottom, lessThanOrEqualTo(bottomPillRect.top + 0.5));

        final wordmarkRect = tester.getRect(
          find.byKey(const Key('topbar_brand_wordmark')),
        );
        final switcherRect = tester.getRect(
          find.byKey(const Key('btn_home_layout_switcher')),
        );
        expect(wordmarkRect.overlaps(topCapsuleRect), isFalse);
        expect(topCapsuleRect.overlaps(switcherRect), isFalse);

        // Also check 1920x1080 @ 1.5x height-aware cap keeps AI wall above pill.
        _setViewport(tester, const Size(1920, 1080));
        scaleCtrl.setScale(1.5);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester.getRect(find.byKey(const Key('ai_album_wall'))).bottom,
          lessThanOrEqualTo(
            tester.getRect(find.byKey(const Key('liquid_glass_capsule'))).top +
                0.5,
          ),
        );

        // Verify refined missing-cover circular medallion & clamped icon scale.
        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              body: Column(
                children: [
                  AlbumArtworkView(
                    album: const CanonicalAlbumSummary(
                      id: 'alb-medallion',
                      title: 'No Art',
                      artist: 'Nobody',
                    ),
                    size: 160,
                    audioService: svc,
                  ),
                  AlbumArtworkView(
                    album: const CanonicalAlbumSummary(
                      id: 'alb-small-thumb',
                      title: 'Thumb',
                      artist: 'Nobody',
                    ),
                    size: 40,
                    audioService: svc,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final icons = tester.widgetList<Icon>(find.byIcon(Icons.music_note_rounded)).toList();
        expect(icons, hasLength(2));
        expect(icons[0].size, closeTo(38.4, 0.1));
        expect(icons[0].size!, lessThanOrEqualTo(44.0));
        expect(icons[1].size, 16.0);

        final medallionContainer = tester.widget<Container>(
          find.ancestor(
            of: find.byWidget(icons[0]),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Container &&
                  w.decoration is BoxDecoration &&
                  (w.decoration! as BoxDecoration).shape == BoxShape.circle,
            ),
          ).first,
        );
        expect(medallionContainer.constraints?.maxWidth, closeTo(38.4 * 1.9, 0.2));
      },
    );

    testWidgets(
      'Floating-pill NowPlayingOverlay uses GPU SlideTransition across 5 expand/collapse cycles at 150% scale with zero layout morph or mid-open BackdropFilter',
      (tester) async {
        _setupMockWindowChannel(tester);
        _setViewport(tester, const Size(1440, 900));
        addTearDown(tester.view.reset);

        final svc = MockAudioService();
        final scaleCtrl = UiScaleController(
          initialHomeLayoutPreset: HomeLayoutPreset.auraQuickResume,
        )..setScale(1.5);
        addTearDown(() {
          svc.dispose();
          scaleCtrl.dispose();
        });

        await tester.pumpWidget(
          LuminaApp(audioService: svc, uiScaleController: scaleCtrl),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('now_playing_capsule_morph')), findsNothing);
        expect(find.byKey(const Key('now_playing_slide_transition')), findsNothing);

        final initialMiniState = tester.state<State<FloatingCapsuleMiniPlayer>>(
          find.byType(FloatingCapsuleMiniPlayer),
        );
        final collapsedPillRect = tester.getRect(
          find.byKey(const Key('liquid_glass_capsule')),
        );
        expect(collapsedPillRect.left, greaterThanOrEqualTo(12.0));
        expect(1440.0 - collapsedPillRect.right, greaterThanOrEqualTo(12.0));

        for (var cycle = 0; cycle < 5; cycle++) {
          await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
          await tester.pump();

          expect(find.byKey(const Key('now_playing_capsule_morph')), findsNothing);
          final slideFinder = find.byKey(
            const Key('now_playing_slide_transition'),
          );
          expect(slideFinder, findsOneWidget);
          final slideWidget = tester.widget<SlideTransition>(slideFinder);
          expect(slideWidget.position.value, const Offset(0.0, 1.0));

          await tester.pump(const Duration(milliseconds: 140));
          expect(slideWidget.position.value.dy, greaterThan(0.0));
          expect(slideWidget.position.value.dy, lessThan(1.0));
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('home_now_playing_layer')),
              matching: find.byType(BackdropFilter),
            ),
            findsNothing,
          );
          expect(
            find.descendant(
              of: find.byType(FloatingCapsuleMiniPlayer),
              matching: find.byType(BackdropFilter),
            ),
            findsNothing,
          );
          expect(
            identical(
              tester.state<State<FloatingCapsuleMiniPlayer>>(
                find.byType(FloatingCapsuleMiniPlayer),
              ),
              initialMiniState,
            ),
            isTrue,
          );

          await tester.pumpAndSettle();
          expect(slideWidget.position.value, Offset.zero);
          expect(tester.takeException(), isNull);

          await tester.tap(find.byKey(const Key('btn_collapse_now_playing')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 110));
          expect(slideWidget.position.value.dy, greaterThan(0.0));
          expect(slideWidget.position.value.dy, lessThan(1.0));

          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('now_playing_stage')), findsNothing);
          expect(tester.takeException(), isNull);
        }

        final restoredDec = tester
            .widget<Container>(find.byKey(const Key('liquid_glass_capsule')))
            .decoration! as BoxDecoration;
        expect(restoredDec.borderRadius, BorderRadius.circular(22.0));
      },
    );
  });
}
