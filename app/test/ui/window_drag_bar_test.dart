import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/home_layout_preset.dart';
import 'package:lumina_app/services/desktop_window_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/ui/common/desktop_window_caption.dart';
import 'package:lumina_app/ui/common/window_drag_bar.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:lumina_app/ui/now_playing/now_playing_overlay.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WindowDragBar Unit & Interaction Tests', () {
    final List<String> methodCalls = [];

    setUp(() {
      methodCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('lumina/window'),
        (MethodCall call) async {
          methodCalls.add(call.method);
          if (call.method == 'isMaximized') return false;
          return null;
        },
      );
      DesktopWindowController.instance =
          DesktopWindowController(isSupportedOverride: true);
    });

    tearDown(() {
      DesktopWindowController.instance = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('lumina/window'),
        null,
      );
    });

    testWidgets('Drag bar spans 100% width and default 48px height', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                WindowDragBar(
                  child: Row(
                    children: [
                      Text('Title'),
                    ],
                  ),
                ),
                Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final dragBarFinder = find.byType(WindowDragBar);
      expect(dragBarFinder, findsOneWidget);
      final size = tester.getSize(dragBarFinder);
      expect(size.width, 1000.0);
      expect(size.height, WindowDragBar.kDefaultHeight);
      final origin = tester.getTopLeft(dragBarFinder);
      expect(origin.dx, 0.0);
      expect(origin.dy, 0.0);
    });

    testWidgets('Blank space pan triggers startDragging', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                WindowDragBar(),
                Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      methodCalls.clear();
      // Drag on blank space in WindowDragBar
      await tester.drag(
        find.byType(WindowDragBar),
        const Offset(100, 0),
        touchSlopX: 0,
        touchSlopY: 0,
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(methodCalls.contains('startDragging'), isTrue);
    });

    testWidgets('Blank space double-tap triggers toggleMaximize', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                WindowDragBar(),
                Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      methodCalls.clear();
      final center = tester.getCenter(find.byType(WindowDragBar));

      // Simulate double tap
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(center);
      await tester.pumpAndSettle();

      expect(methodCalls.contains('toggleMaximize'), isTrue);
    });

    testWidgets('Title text wrapped in IgnorePointer forwards pan to startDragging', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                WindowDragBar(
                  child: Row(
                    children: [
                      IgnorePointer(
                        child: Text(
                          'Lumina Audio Title',
                          key: Key('drag_title'),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      methodCalls.clear();
      final titleFinder = find.byKey(const Key('drag_title'));
      expect(titleFinder, findsOneWidget);

      await tester.drag(
        titleFinder,
        const Offset(60, 0),
        warnIfMissed: false,
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(methodCalls.contains('startDragging'), isTrue);
    });

    testWidgets('Interactive button consumes click without triggering startDragging', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      bool buttonClicked = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                WindowDragBar(
                  child: Row(
                    children: [
                      IconButton(
                        key: const Key('test_btn'),
                        icon: const Icon(Icons.settings),
                        onPressed: () {
                          buttonClicked = true;
                        },
                      ),
                    ],
                  ),
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      methodCalls.clear();
      await tester.tap(find.byKey(const Key('test_btn')));
      await tester.pumpAndSettle();

      expect(buttonClicked, isTrue);
      expect(methodCalls.contains('startDragging'), isFalse);
    });

    testWidgets('HomeScreen integrates WindowDragBar at 100% width across sidebar', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final service = MockAudioService();
      addTearDown(service.dispose);
      final scaleCtrl = UiScaleController(
        initialHomeLayoutPreset: HomeLayoutPreset.classic,
      );
      addTearDown(scaleCtrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            audioService: service,
            uiScaleController: scaleCtrl,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final dragBarFinder = find.byType(WindowDragBar);
      expect(dragBarFinder, findsOneWidget);

      final dragBarSize = tester.getSize(dragBarFinder);
      expect(dragBarSize.width, 1280.0);
      expect(dragBarSize.height, 48.0);

      // Verify buttons exist and are responsive
      expect(find.byKey(const Key('btn_nav_back')), findsOneWidget);
      expect(find.byKey(const Key('btn_nav_forward')), findsOneWidget);
      expect(find.byKey(const Key('btn_open_settings_hub')), findsOneWidget);
      expect(find.byKey(const Key('btn_window_minimize')), findsOneWidget);
      expect(find.byKey(const Key('btn_window_maximize')), findsOneWidget);
      expect(find.byKey(const Key('btn_window_close')), findsOneWidget);

      // Verify dragging on top-left area (above sidebar) calls startDragging
      methodCalls.clear();
      await tester.dragFrom(const Offset(50, 24), const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(methodCalls.contains('startDragging'), isTrue);
    });

    testWidgets('NowPlayingOverlay integrates WindowDragBar with clickable collapse and mode toggles', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      bool collapsed = false;
      final service = MockAudioService();
      addTearDown(service.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NowPlayingOverlay(
              audioService: service,
              onCollapse: () => collapsed = true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final dragBarFinder = find.byType(WindowDragBar);
      expect(dragBarFinder, findsOneWidget);
      final dragBarSize = tester.getSize(dragBarFinder);
      expect(dragBarSize.width, 1280.0);
      expect(dragBarSize.height, 48.0);

      // Verify collapse button works
      await tester.tap(find.byKey(const Key('btn_collapse_now_playing')));
      await tester.pumpAndSettle();
      expect(collapsed, isTrue);

      // Verify mode buttons exist
      expect(find.byKey(const Key('btn_now_playing_mode_split')), findsOneWidget);
      expect(find.byKey(const Key('btn_now_playing_mode_lyrics')), findsOneWidget);
      expect(find.byKey(const Key('btn_now_playing_mode_cover')), findsOneWidget);

      // Verify dragging middle blank area triggers startDragging
      methodCalls.clear();
      await tester.dragFrom(const Offset(400, 24), const Offset(50, 0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(methodCalls.contains('startDragging'), isTrue);
    });

    testWidgets('DesktopWindowCaptionButtons updates maximized state on didChangeMetrics', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      bool currentMax = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('lumina/window'),
        (MethodCall call) async {
          if (call.method == 'isMaximized') return currentMax;
          return null;
        },
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DesktopWindowCaptionButtons(height: 48.0),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Initially not maximized -> Icons.crop_square_rounded
      expect(find.byIcon(Icons.crop_square_rounded), findsOneWidget);
      expect(find.byIcon(Icons.filter_none_rounded), findsNothing);

      // Simulate OS maximize (e.g. Aero Snap, Win+Up, double click)
      currentMax = true;
      tester.view.physicalSize = const Size(1920, 1080);
      await tester.pump();
      await tester.pumpAndSettle();

      // Observer should have called _checkMaximizedState upon metric change
      expect(find.byIcon(Icons.filter_none_rounded), findsOneWidget);
      expect(find.byIcon(Icons.crop_square_rounded), findsNothing);
    });
  });
}
