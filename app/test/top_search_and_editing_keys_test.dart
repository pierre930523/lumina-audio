import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/main.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:material_ui/material_ui.dart';

bool _isEditableTextFocused() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null || !ctx.mounted) return false;
  if (ctx.widget is EditableText) return true;
  return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}

TextField _topSearchField(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const Key('top_search_input')));

TextField _librarySearchField(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const Key('library_search_input')));

Focus _homeGlobalFocus(WidgetTester tester) {
  return tester.widget<Focus>(
    find.descendant(
      of: find.byType(HomeScreen),
      matching: find.byWidgetPredicate(
        (w) => w is Focus && w.onKeyEvent != null,
      ),
    ).first,
  );
}

void main() {
  group('Stage 2: Collapsible Top Search Box & Text Editing Key Handling', () {
    testWidgets(
      'Default collapsed state, click-to-expand auto-focus, and collapse transitions',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = MockAudioService();
        addTearDown(service.dispose);

        await tester.pumpWidget(LuminaApp(audioService: service));
        await tester.pumpAndSettle();

        // Collapsed by default.
        expect(find.byKey(const Key('btn_top_search_toggle')), findsOneWidget);
        expect(find.byKey(const Key('top_search_input')), findsNothing);
        expect(find.byKey(const Key('btn_top_search_clear')), findsNothing);
        expect(_isEditableTextFocused(), isFalse);

        // Click toggle expands & auto-focuses top_search_input without overflow.
        await tester.tap(find.byKey(const Key('btn_top_search_toggle')));
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(milliseconds: 60));
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(milliseconds: 120));
        expect(tester.takeException(), isNull);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        expect(find.byKey(const Key('top_search_input')), findsOneWidget);
        expect(find.byKey(const Key('btn_top_search_clear')), findsOneWidget);
        expect(find.byKey(const Key('btn_top_search_toggle')), findsNothing);
        expect(_isEditableTextFocused(), isTrue);

        // Clicking outside when empty unfocuses and collapses back to icon.
        await tester.tapAt(const Offset(500, 420));
        await tester.pumpAndSettle();
        expect(_isEditableTextFocused(), isFalse);
        expect(find.byKey(const Key('btn_top_search_toggle')), findsOneWidget);
        expect(find.byKey(const Key('top_search_input')), findsNothing);

        // Global shortcuts keep working immediately after collapse.
        final initialStatus = service.currentState.status;
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(service.currentState.status != initialStatus, isTrue);
      },
    );

    testWidgets(
      'Typing English + Traditional Chinese, Backspace/Delete/Ctrl+A, clear button, and Space/M passthrough',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = MockAudioService();
        addTearDown(service.dispose);

        await tester.pumpWidget(LuminaApp(audioService: service));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('btn_top_search_toggle')));
        await tester.pumpAndSettle();
        expect(_isEditableTextFocused(), isTrue);

        // Enter mixed English & Traditional Chinese text.
        await tester.enterText(
          find.byKey(const Key('top_search_input')),
          'Pink 月之暗面',
        );
        await tester.pumpAndSettle();
        final controller = _topSearchField(tester).controller!;
        expect(controller.text, 'Pink 月之暗面');

        // Verify HomeScreen Focus.onKeyEvent returns ignored for editing keys
        // while EditableText has focus.
        final globalFocus = _homeGlobalFocus(tester);
        final focusNode = globalFocus.focusNode ?? FocusNode();
        if (globalFocus.focusNode == null) addTearDown(focusNode.dispose);
        final onKeyEvent = globalFocus.onKeyEvent!;
        const editingKeys = [
          LogicalKeyboardKey.backspace,
          LogicalKeyboardKey.delete,
          LogicalKeyboardKey.space,
          LogicalKeyboardKey.keyM,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
        ];
        for (final key in editingKeys) {
          final downRes = onKeyEvent(
            focusNode,
            KeyDownEvent(
              physicalKey: PhysicalKeyboardKey.space,
              logicalKey: key,
              timeStamp: Duration.zero,
            ),
          );
          final repeatRes = onKeyEvent(
            focusNode,
            KeyRepeatEvent(
              physicalKey: PhysicalKeyboardKey.space,
              logicalKey: key,
              timeStamp: const Duration(milliseconds: 50),
            ),
          );
          expect(
            downRes,
            KeyEventResult.ignored,
            reason: 'KeyDown for $key must return ignored while editing',
          );
          expect(
            repeatRes,
            KeyEventResult.ignored,
            reason: 'KeyRepeat for $key must return ignored while editing',
          );
        }

        // Pressing Space & M must NOT toggle play/pause or mute.
        final initialStatus = service.currentState.status;
        final initialMute = service.currentState.isMuted;
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
        await tester.pumpAndSettle();
        expect(service.currentState.status, initialStatus);
        expect(service.currentState.isMuted, initialMute);

        // Backspace deletes characters instead of being swallowed or navigating.
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await tester.pumpAndSettle();
        expect(controller.text, 'Pink 月之暗');

        // Backspace KeyRepeat also deletes cleanly.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.backspace);
        await tester.pump();
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.backspace);
        await tester.pump();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.backspace);
        await tester.pumpAndSettle();
        expect(controller.text, 'Pink 月');

        // ArrowLeft + Delete deletes forward ('月').
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        await tester.pumpAndSettle();
        expect(controller.text, 'Pink ');

        // Ctrl+A selects all, then Backspace clears the entire field.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(controller.selection.baseOffset, 0);
        expect(controller.selection.extentOffset, controller.text.length);

        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await tester.pumpAndSettle();
        expect(controller.text, isEmpty);

        // Enter text again and test X clear button:
        // 1st click clears text and keeps search expanded & focused;
        // 2nd click collapses back to icon.
        await tester.enterText(
          find.byKey(const Key('top_search_input')),
          '肖邦夜曲',
        );
        await tester.pumpAndSettle();
        expect(controller.text, '肖邦夜曲');

        await tester.tap(find.byKey(const Key('btn_top_search_clear')));
        await tester.pumpAndSettle();
        expect(controller.text, isEmpty);
        expect(find.byKey(const Key('top_search_input')), findsOneWidget);
        expect(_isEditableTextFocused(), isTrue);

        await tester.tap(find.byKey(const Key('btn_top_search_clear')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('top_search_input')), findsNothing);
        expect(find.byKey(const Key('btn_top_search_toggle')), findsOneWidget);
      },
    );

    testWidgets(
      'Click outside keeps non-empty search open, Esc hierarchy unfocuses then collapses before nav back',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = MockAudioService();
        addTearDown(service.dispose);

        await tester.pumpWidget(LuminaApp(audioService: service));
        await tester.pumpAndSettle();

        // Navigate to Albums so nav history has a back entry.
        await tester.tap(find.byKey(const Key('capsule_nav_albums')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('album_grid_view')), findsOneWidget);

        // Expand top search via Ctrl+F and type text.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('top_search_input')), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('top_search_input')),
          'Mozart',
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('unified_search_results_view')), findsOneWidget);

        // Click outside when non-empty -> unfocuses, keeps search open with text.
        await tester.tapAt(const Offset(500, 420));
        await tester.pumpAndSettle();
        expect(_isEditableTextFocused(), isFalse);
        expect(find.byKey(const Key('top_search_input')), findsOneWidget);
        expect(_topSearchField(tester).controller!.text, 'Mozart');

        // Re-focus top_search_input, then test Esc hierarchy:
        await tester.tap(find.byKey(const Key('top_search_input')));
        await tester.pumpAndSettle();
        expect(_isEditableTextFocused(), isTrue);

        // 1st Esc (Level 1): unfocuses only, keeps non-empty search expanded.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(_isEditableTextFocused(), isFalse);
        expect(find.byKey(const Key('top_search_input')), findsOneWidget);
        expect(find.byKey(const Key('unified_search_results_view')), findsOneWidget);

        // 2nd Esc (Level 2): collapses expanded top search without navigating back.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('top_search_input')), findsNothing);
        expect(find.byKey(const Key('btn_top_search_toggle')), findsOneWidget);
        expect(find.byKey(const Key('unified_search_results_view')), findsOneWidget);

        // 3rd Esc (Level 5): navigates back from search results to Albums.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('album_grid_view')), findsOneWidget);

        // 4th Esc (Level 5): navigates back from Albums to Home.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('home_layout_aj')), findsOneWidget);

        // Re-open with Ctrl+F, clear text with X, then press Esc once:
        // when empty and focused, 1st Esc unfocuses AND collapses.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('top_search_input')), findsOneWidget);
        expect(_isEditableTextFocused(), isTrue);

        await tester.tap(find.byKey(const Key('btn_top_search_clear')));
        await tester.pumpAndSettle();
        expect(_topSearchField(tester).controller!.text, isEmpty);
        expect(find.byKey(const Key('top_search_input')), findsOneWidget);
        expect(_isEditableTextFocused(), isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(_isEditableTextFocused(), isFalse);
        expect(find.byKey(const Key('top_search_input')), findsNothing);
        expect(find.byKey(const Key('btn_top_search_toggle')), findsOneWidget);
      },
    );

    testWidgets(
      'Losing focus to another widget when empty collapses top search; LibraryBrowserView preserves query & clears with X',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = MockAudioService();
        addTearDown(service.dispose);

        await tester.pumpWidget(LuminaApp(audioService: service));
        await tester.pumpAndSettle();

        // Navigate to LibraryBrowserView, expand top search (empty), then tap
        // library_search_input -> focus moves away so top search collapses.
        await tester.tap(find.byKey(const Key('capsule_nav_library')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('btn_top_search_toggle')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('top_search_input')), findsOneWidget);

        await tester.tap(find.byKey(const Key('library_search_input')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('top_search_input')), findsNothing);
        expect(find.byKey(const Key('btn_top_search_toggle')), findsOneWidget);

        // Library search supports typing, Backspace, rebuild persistence, and X clear.
        expect(find.byKey(const Key('btn_library_search_clear')), findsNothing);
        await tester.enterText(
          find.byKey(const Key('library_search_input')),
          'Money',
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('btn_library_search_clear')), findsOneWidget);

        // Trigger PlaybackState stream rebuild -> query must NOT reset.
        await service.togglePlayPause();
        await tester.pumpAndSettle();
        expect(_librarySearchField(tester).controller!.text, 'Money');

        // Backspace deletes last char.
        await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
        await tester.pumpAndSettle();
        expect(_librarySearchField(tester).controller!.text, 'Mone');

        // Clear button clears query & restores queue tracks.
        await tester.tap(find.byKey(const Key('btn_library_search_clear')));
        await tester.pumpAndSettle();
        expect(_librarySearchField(tester).controller!.text, isEmpty);
        expect(find.byKey(const Key('btn_library_search_clear')), findsNothing);
        expect(find.byKey(const Key('queue_track_trk-001')), findsOneWidget);
      },
    );

    testWidgets(
      'Zero overflow in top bar at 100% & 150% scale and 800x600 & 1280x800',
      (WidgetTester tester) async {
        const cases = <({Size size, double dpr, double scale, bool expectDesktop})>[
          (size: Size(1280, 800), dpr: 1.0, scale: 1.0, expectDesktop: true),
          (size: Size(1280, 800), dpr: 1.0, scale: 1.5, expectDesktop: true),
          (size: Size(1280, 800), dpr: 1.5, scale: 1.0, expectDesktop: true),
          (size: Size(800, 600), dpr: 1.0, scale: 1.0, expectDesktop: false),
          (size: Size(800, 600), dpr: 1.0, scale: 1.5, expectDesktop: false),
          (size: Size(1200, 900), dpr: 1.5, scale: 1.0, expectDesktop: false),
        ];

        for (final c in cases) {
          tester.view.physicalSize = c.size;
          tester.view.devicePixelRatio = c.dpr;

          final service = MockAudioService();
          final scaleCtrl = UiScaleController();
          scaleCtrl.setScale(c.scale);

          await tester.pumpWidget(
            LuminaApp(
              audioService: service,
              uiScaleController: scaleCtrl,
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason:
                'Overflow in collapsed state at ${c.size} dpr=${c.dpr} scale=${c.scale}x',
          );

          await tester.tap(find.byKey(const Key('btn_top_search_toggle')));
          for (final ms in [16, 60, 120, 220]) {
            await tester.pump(Duration(milliseconds: ms));
            expect(
              tester.takeException(),
              isNull,
              reason:
                  'Overflow at ${ms}ms during expand for ${c.size} dpr=${c.dpr} scale=${c.scale}x',
            );
          }
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason:
                'Overflow after expand settle at ${c.size} dpr=${c.dpr} scale=${c.scale}x',
          );

          // Transform.scale maps child coords back to logical window coords (size / dpr).
          final windowViewportWidth = c.size.width / c.dpr;
          final searchRect = tester.getRect(
            find.byKey(const Key('top_search_input')),
          );
          final settingsRect = tester.getRect(
            find.byKey(const Key('btn_open_settings_hub')),
          );
          expect(
            searchRect.right,
            lessThanOrEqualTo(settingsRect.left + 1.0),
            reason:
                'Search box overlapped settings at ${c.size} dpr=${c.dpr} scale=${c.scale}x',
          );
          expect(
            settingsRect.right,
            lessThanOrEqualTo(windowViewportWidth + 0.5),
            reason:
                'Settings clipped at ${c.size} dpr=${c.dpr} scale=${c.scale}x',
          );
          if (c.expectDesktop) {
            final closeRect = tester.getRect(
              find.byKey(const Key('btn_window_close')),
            );
            expect(
              closeRect.right,
              lessThanOrEqualTo(windowViewportWidth + 0.5),
              reason:
                  'Window caption clipped at ${c.size} dpr=${c.dpr} scale=${c.scale}x',
            );
          }

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          scaleCtrl.dispose();
          service.dispose();
        }
        tester.view.reset();
      },
    );
  });
}
