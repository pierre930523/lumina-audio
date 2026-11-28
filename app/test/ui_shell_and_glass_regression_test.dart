import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/main.dart';
import 'package:lumina_app/models/home_layout_preset.dart';
import 'package:lumina_app/services/desktop_window_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/ui/common/frosted_glass_container.dart';
import 'package:lumina_app/ui/common/window_drag_bar.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<String> windowCalls = <String>[];

  setUp(() {
    windowCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('lumina/window'), (
          MethodCall call,
        ) async {
          windowCalls.add(call.method);
          if (call.method == 'isMaximized' || call.method == 'isFullScreen') {
            return false;
          }
          return null;
        });
    DesktopWindowController.instance = DesktopWindowController(
      isSupportedOverride: true,
    );
  });

  tearDown(() {
    DesktopWindowController.instance = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('lumina/window'), null);
  });

  group('Shell Layout, Unified Sidebar, Fade Mask & Settings Glass Regression', () {
    testWidgets(
      'Zero bottom gap & zero overlap between sidebar / workspace and bottom player bar across wide, medium, narrow, and 1.5x scale',
      (tester) async {
        addTearDown(tester.view.reset);

        final service = MockAudioService();
        final scaleCtrl = UiScaleController(
          initialHomeLayoutPreset: HomeLayoutPreset.classic,
        );
        addTearDown(() {
          service.dispose();
          scaleCtrl.dispose();
        });

        await tester.pumpWidget(
          LuminaApp(
            audioService: service,
            uiScaleController: scaleCtrl,
          ),
        );

        final cases = <({Size size, double scale, bool expectDesktopSidebar})>[
          (size: const Size(1440, 900), scale: 1.0, expectDesktopSidebar: true),
          (size: const Size(1280, 800), scale: 1.0, expectDesktopSidebar: true),
          (size: const Size(1440, 900), scale: 1.5, expectDesktopSidebar: true),
          (size: const Size(620, 520), scale: 1.0, expectDesktopSidebar: false),
          (size: const Size(400, 700), scale: 1.0, expectDesktopSidebar: false),
        ];

        for (final c in cases) {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = c.size;
          scaleCtrl.setScale(c.scale);
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'Overflow at ${c.size} @ ${c.scale}x',
          );

          final capsuleRect = tester.getRect(
            find.byKey(const Key('liquid_glass_capsule')),
          );
          final workspaceRect = tester.getRect(
            find.byKey(const Key('workspace_stage')),
          );

          expect(
            workspaceRect.height,
            greaterThan(200.0),
            reason:
                'Workspace must occupy main viewport above mini-player at ${c.size} @ ${c.scale}x',
          );
          expect(
            capsuleRect.height,
            inInclusiveRange(72.0, 160.0),
            reason:
                'Docked mini-player must stay compact (not expand full screen) at ${c.size} @ ${c.scale}x',
          );
          expect(
            (workspaceRect.bottom - capsuleRect.top).abs(),
            lessThan(0.5),
            reason:
                'Workspace bottom (${workspaceRect.bottom}) must touch capsule top (${capsuleRect.top}) at ${c.size} @ ${c.scale}x',
          );

          if (c.expectDesktopSidebar) {
            final sidebarFinder = find.byKey(
              const Key('main_sidebar_glass_container'),
            );
            expect(sidebarFinder, findsOneWidget);
            final sidebarRect = tester.getRect(sidebarFinder);
            expect(sidebarRect.top, closeTo(0.0, 0.5));
            expect(
              (sidebarRect.bottom - capsuleRect.top).abs(),
              lessThan(0.5),
              reason:
                  'Sidebar bottom (${sidebarRect.bottom}) must touch capsule top (${capsuleRect.top}) at ${c.size} @ ${c.scale}x',
            );
          }
        }
      },
    );

    testWidgets(
      'Single continuous sidebar FrostedGlassContainer wraps both Lumina Audio header and nav items; WindowDragBar stays transparent with no border even in Settings',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = MockAudioService();
        final scaleCtrl = UiScaleController(
          initialHomeLayoutPreset: HomeLayoutPreset.classic,
        );
        addTearDown(() {
          service.dispose();
          scaleCtrl.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: service,
              uiScaleController: scaleCtrl,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Single outer sidebar FrostedGlassContainer wraps both brand title & nav list.
        final sidebarFinder = find.byKey(
          const Key('main_sidebar_glass_container'),
        );
        expect(sidebarFinder, findsOneWidget);
        final sidebarGlass = tester.widget<FrostedGlassContainer>(
          sidebarFinder,
        );
        expect(sidebarGlass.color, LuminaTokens.glassSidebarBg);
        expect(sidebarGlass.blurSigma, LuminaTokens.glassSidebarBlur);

        expect(
          find.descendant(
            of: sidebarFinder,
            matching: find.text('Lumina Audio'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: sidebarFinder,
            matching: find.byKey(const Key('nav_tab_home')),
          ),
          findsOneWidget,
        );
        // Strictly 1 BackdropFilter across the entire sidebar (no inner blur on header).
        expect(
          find.descendant(
            of: sidebarFinder,
            matching: find.byType(BackdropFilter),
          ),
          findsOneWidget,
        );
        // Zero FrostedGlassContainer nested inside sidebar brand header.
        expect(
          find.descendant(
            of: find.byKey(const Key('sidebar_brand_header')),
            matching: find.byType(FrostedGlassContainer),
          ),
          findsNothing,
        );

        // Single full-width transparent WindowDragBar with no border on Home.
        final dragBarFinder = find.byType(WindowDragBar);
        expect(dragBarFinder, findsOneWidget);
        var dragBar = tester.widget<WindowDragBar>(dragBarFinder);
        expect(dragBar.backgroundColor, Colors.transparent);
        expect(dragBar.border, isNull);
        expect(tester.getSize(dragBarFinder), const Size(1440.0, 48.0));

        // Dragging over top-left Lumina Audio header still triggers window drag.
        windowCalls.clear();
        await tester.dragFrom(const Offset(50, 24), const Offset(40, 0));
        await tester.pump(const Duration(milliseconds: 300));
        expect(windowCalls.contains('startDragging'), isTrue);

        // Navigate to Settings: WindowDragBar still has border == null & transparent bg.
        await tester.tap(find.byKey(const Key('btn_open_settings_hub')));
        await tester.pumpAndSettle();
        dragBar = tester.widget<WindowDragBar>(dragBarFinder);
        expect(dragBar.backgroundColor, Colors.transparent);
        expect(dragBar.border, isNull);
      },
    );

    testWidgets(
      'ShaderMask(BlendMode.dstIn) wraps scrollable main content without wrapping outer sidebar or Settings rail glass shells',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = MockAudioService();
        final scaleCtrl = UiScaleController(
          initialHomeLayoutPreset: HomeLayoutPreset.classic,
        );
        addTearDown(() {
          service.dispose();
          scaleCtrl.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: service,
              uiScaleController: scaleCtrl,
            ),
          ),
        );
        await tester.pumpAndSettle();

        void assertMainFadeMaskAndUnmaskedChrome({bool expectSettingsRail = false}) {
          final maskHost = find.byKey(
            const Key('main_content_bottom_fade_mask'),
          );
          expect(maskHost, findsOneWidget);
          final shaderMaskFinder = find.descendant(
            of: maskHost,
            matching: find.byWidgetPredicate(
              (w) => w is ShaderMask && w.blendMode == BlendMode.dstIn,
            ),
          );
          expect(shaderMaskFinder, findsOneWidget);

          // Main sidebar glass shell must NOT be inside any ShaderMask.
          expect(
            find.ancestor(
              of: find.byKey(const Key('main_sidebar_glass_container')),
              matching: find.byType(ShaderMask),
            ),
            findsNothing,
          );

          if (expectSettingsRail) {
            expect(
              find.byKey(const Key('settings_secondary_rail')),
              findsOneWidget,
            );
          }
        }

        // Home tab
        assertMainFadeMaskAndUnmaskedChrome();

        // Library tab
        await tester.tap(find.byKey(const Key('nav_tab_library')));
        await tester.pumpAndSettle();
        assertMainFadeMaskAndUnmaskedChrome();

        // Settings tab
        await tester.tap(find.byKey(const Key('btn_open_settings_hub')));
        await tester.pumpAndSettle();
        assertMainFadeMaskAndUnmaskedChrome(expectSettingsRail: true);
      },
    );

    testWidgets(
      'Settings workspace centers symmetrically <=1060px with sticky frosted rail, single outer right scrollbar, and clears floating capsule at bottom',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = MockAudioService();
        final scaleCtrl = UiScaleController(
          initialHomeLayoutPreset: HomeLayoutPreset.auraQuickResume,
        );
        addTearDown(() {
          service.dispose();
          scaleCtrl.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: service,
              uiScaleController: scaleCtrl,
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('btn_open_settings_hub')));
        await tester.pumpAndSettle();

        final containerFinder = find.byKey(
          const Key('settings_centered_container'),
        );
        final railFinder = find.byKey(const Key('settings_secondary_rail'));
        final outerScrollFinder = find.byKey(const Key('settings_outer_scroll'));
        expect(containerFinder, findsOneWidget);
        expect(railFinder, findsOneWidget);
        expect(outerScrollFinder, findsOneWidget);

        // Symmetrically centered within <= 1060px on 1440px viewport.
        final containerRect = tester.getRect(containerFinder);
        expect(containerRect.width, lessThanOrEqualTo(1060.5));
        expect(
          (containerRect.left - (1440.0 - containerRect.right)).abs(),
          lessThan(2.0),
        );

        // Sticky frosted card rail (210-230px wide) with rounded corners & zero inner ScrollView.
        final railGlass = tester.widget<FrostedGlassContainer>(railFinder);
        expect(railGlass.color, LuminaTokens.glassSettingsRailBg);
        expect(railGlass.blurSigma, LuminaTokens.glassSettingsRailBlur);
        expect(railGlass.borderRadius, BorderRadius.circular(LuminaTokens.radiusLg));
        final railRect = tester.getRect(railFinder);
        expect(railRect.width, inInclusiveRange(210.0, 230.0));
        expect(
          find.descendant(
            of: find.byKey(const Key('general_settings_panel')),
            matching: find.byType(SingleChildScrollView),
          ),
          findsNothing,
        );

        // Selected Settings item uses rounded translucent pill (glassNavActiveBg) and zero blue left bar.
        final generalItem = find.byKey(const Key('nav_tab_general'));
        expect(generalItem, findsOneWidget);
        final selectedMaterial = tester.widget<Material>(
          find
              .ancestor(of: generalItem, matching: find.byType(Material))
              .first,
        );
        expect(selectedMaterial.color, LuminaTokens.glassNavActiveBg);
        expect(
          selectedMaterial.borderRadius,
          BorderRadius.circular(LuminaTokens.radiusSm),
        );

        for (final container in tester.widgetList<Container>(
          find.descendant(of: railFinder, matching: find.byType(Container)),
        )) {
          final dec = container.decoration;
          if (dec is BoxDecoration && dec.border is Border) {
            final border = dec.border as Border;
            expect(border.left.color, isNot(LuminaTokens.accentBlue));
          }
        }

        // Navigate to Network/Streaming tab -> rail remains sticky on scroll & bottom item clears mini capsule.
        await tester.tap(find.byKey(const Key('nav_tab_settings')));
        await tester.pumpAndSettle();
        final scrollable = tester.state<ScrollableState>(
          find.descendant(
            of: outerScrollFinder,
            matching: find.byType(Scrollable),
          ),
        );
        scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
        await tester.pumpAndSettle();

        final stickyRailRect = tester.getRect(railFinder);
        expect(stickyRailRect.top, greaterThanOrEqualTo(0.0));
        final capsuleRect = tester.getRect(
          find.byKey(const Key('liquid_glass_capsule')),
        );
        final webdavRow = find.byKey(const Key('provider_row_web_dav'));
        expect(webdavRow, findsOneWidget);
        expect(
          tester.getRect(webdavRow).bottom,
          lessThanOrEqualTo(capsuleRect.top + 0.5),
        );

        // Narrow window & 150% scale have zero overflow exceptions.
        scaleCtrl.setScale(1.5);
        tester.view.physicalSize = const Size(900, 720);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    test(
      'New frosted-glass tokens and Switch ON/OFF states satisfy WCAG AA contrast & buildDarkTheme switchTheme contract',
      () {
        for (final bg in const [
          LuminaTokens.glassSettingsRailBg,
          LuminaTokens.glassCardBg,
          LuminaTokens.glassSegmentSelectedBg,
          LuminaTokens.glassDialogBg,
          LuminaTokens.glassMenuBg,
        ]) {
          expect(
            LuminaTokens.contrastRatio(Colors.white, bg),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            LuminaTokens.contrastRatio(LuminaTokens.glassTextPrimary, bg),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            LuminaTokens.contrastRatio(LuminaTokens.glassTextSecondary, bg),
            greaterThanOrEqualTo(4.5),
          );
        }

        // Switch ON / OFF contrast checks
        expect(
          LuminaTokens.contrastRatio(
            LuminaTokens.glassSwitchOnThumb,
            LuminaTokens.glassSwitchOnTrack,
          ),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          LuminaTokens.contrastRatio(
            LuminaTokens.glassSwitchOnTrack,
            LuminaTokens.glassCardBg,
          ),
          greaterThanOrEqualTo(3.0),
        );
        expect(
          LuminaTokens.contrastRatio(
            LuminaTokens.glassSwitchOffThumb,
            LuminaTokens.glassSwitchOffTrack,
          ),
          greaterThanOrEqualTo(4.5),
        );

        // ThemeData.switchTheme contract
        final theme = LuminaTokens.buildDarkTheme();
        final sw = theme.switchTheme;
        expect(
          sw.trackColor?.resolve(const {WidgetState.selected}),
          LuminaTokens.glassSwitchOnTrack,
        );
        expect(
          sw.thumbColor?.resolve(const {WidgetState.selected}),
          LuminaTokens.glassSwitchOnThumb,
        );
        expect(
          sw.trackColor?.resolve(const <WidgetState>{}),
          LuminaTokens.glassSwitchOffTrack,
        );
        expect(
          sw.thumbColor?.resolve(const <WidgetState>{}),
          LuminaTokens.glassSwitchOffThumb,
        );
        expect(
          sw.trackOutlineColor?.resolve(const <WidgetState>{}),
          LuminaTokens.glassSwitchOffBorder,
        );
      },
    );
  });
}
