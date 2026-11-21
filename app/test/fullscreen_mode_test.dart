import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/services/desktop_window_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/ui/common/desktop_window_caption.dart';
import 'package:lumina_app/ui/common/window_drag_bar.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:lumina_app/ui/mini_player/floating_capsule.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Requirement R5: Fullscreen Mode & DesktopWindowController Unit Tests', () {
    final List<String> channelInvocations = [];
    bool mockIsFullScreen = false;
    bool mockIsMaximized = false;

    setUp(() {
      channelInvocations.clear();
      mockIsFullScreen = false;
      mockIsMaximized = false;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('lumina/window'),
        (MethodCall call) async {
          channelInvocations.add(call.method);
          if (call.method == 'isFullScreen') return mockIsFullScreen;
          if (call.method == 'setFullScreen') {
            mockIsFullScreen = call.arguments as bool;
            return null;
          }
          if (call.method == 'toggleFullScreen') {
            mockIsFullScreen = !mockIsFullScreen;
            return null;
          }
          if (call.method == 'isMaximized') return mockIsMaximized;
          if (call.method == 'minimize') return null;
          if (call.method == 'restore') return null;
          if (call.method == 'maximize') {
            mockIsMaximized = true;
            return null;
          }
          if (call.method == 'toggleMaximize') {
            mockIsMaximized = !mockIsMaximized;
            return null;
          }
          return null;
        },
      );
    });

    tearDown(() {
      DesktopWindowController.instance = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('lumina/window'), null);
    });

    test('DesktopWindowController windowManager alias points to instance', () {
      final instance = DesktopWindowController.instance;
      expect(DesktopWindowController.windowManager, same(instance));
    });

    test('isFullScreen, setFullScreen, and toggleFullScreen manage state correctly', () async {
      final controller = DesktopWindowController(isSupportedOverride: true);

      expect(controller.isFullScreenNotifier.value, isFalse);
      expect(await controller.isFullScreen(), isFalse);

      await controller.setFullScreen(true);
      expect(controller.isFullScreenNotifier.value, isTrue);
      expect(channelInvocations, contains('setFullScreen'));

      await controller.toggleFullScreen();
      expect(controller.isFullScreenNotifier.value, isFalse);

      await controller.toggleFullScreen();
      expect(controller.isFullScreenNotifier.value, isTrue);
    });

    test('minimize and restore update isMinimizedNotifier correctly', () async {
      final controller = DesktopWindowController(isSupportedOverride: true);

      expect(controller.isMinimizedNotifier.value, isFalse);

      await controller.minimize();
      expect(controller.isMinimizedNotifier.value, isTrue);
      expect(channelInvocations, contains('minimize'));

      await controller.restore();
      expect(controller.isMinimizedNotifier.value, isFalse);
      expect(channelInvocations, contains('restore'));
    });
  });

  group('Requirement R5: DesktopWindowCaptionButtons Fullscreen & Minimize Tests', () {
    final List<String> channelCalls = [];
    late DesktopWindowController controller;
    late MockAudioService audioService;
    bool mockFullScreen = false;
    bool mockMaximized = false;

    setUp(() {
      channelCalls.clear();
      mockFullScreen = false;
      mockMaximized = false;
      audioService = MockAudioService();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('lumina/window'),
        (MethodCall call) async {
          channelCalls.add(call.method);
          if (call.method == 'isFullScreen') return mockFullScreen;
          if (call.method == 'setFullScreen') {
            mockFullScreen = call.arguments as bool;
            return null;
          }
          if (call.method == 'isMaximized') return mockMaximized;
          if (call.method == 'toggleMaximize') {
            mockMaximized = !mockMaximized;
            return null;
          }
          return null;
        },
      );

      controller = DesktopWindowController(isSupportedOverride: true);
      DesktopWindowController.instance = controller;
    });

    tearDown(() {
      DesktopWindowController.instance = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('lumina/window'), null);
    });

    testWidgets('Renders fullscreen button with correct initial tooltip and icon', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopWindowCaptionButtons(
              controller: controller,
              audioService: audioService,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final fsBtnFinder = find.byKey(const Key('btn_window_fullscreen'));
      expect(fsBtnFinder, findsOneWidget);

      final tooltipFinder = find.byWidgetPredicate(
        (widget) => widget is Tooltip && widget.message == '全螢幕 (F11)',
      );
      expect(tooltipFinder, findsOneWidget);

      expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
    });

    testWidgets('Tapping fullscreen button toggles fullscreen and adapts maximize button', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopWindowCaptionButtons(
              controller: controller,
              audioService: audioService,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap fullscreen button to enter fullscreen
      await tester.tap(find.byKey(const Key('btn_window_fullscreen')));
      await tester.pumpAndSettle();

      expect(mockFullScreen, isTrue);
      expect(controller.isFullScreenNotifier.value, isTrue);

      // Verify fullscreen button tooltip changed to '退出全螢幕 (Esc)' and icon to exit
      expect(
        find.byWidgetPredicate(
          (widget) => widget is Tooltip && widget.message == '退出全螢幕 (Esc)',
        ),
        findsNWidgets(2), // Both fullscreen button and adapted maximize button!
      );
      expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);
      expect(find.byIcon(Icons.filter_none_rounded), findsOneWidget);

      // Tapping the adapted maximize button in fullscreen mode should exit fullscreen mode
      await tester.tap(find.byKey(const Key('btn_window_maximize')));
      await tester.pumpAndSettle();

      expect(mockFullScreen, isFalse);
      expect(controller.isFullScreenNotifier.value, isFalse);
      expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
    });

    testWidgets('Tapping minimize button calls audioService.setWindowMinimized(true) before minimize()', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopWindowCaptionButtons(
              controller: controller,
              audioService: audioService,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(audioService.windowMinimized, isFalse);

      await tester.tap(find.byKey(const Key('btn_window_minimize')));
      await tester.pumpAndSettle();

      expect(audioService.windowMinimized, isTrue);
      expect(channelCalls, contains('minimize'));
      expect(controller.isMinimizedNotifier.value, isTrue);
    });
  });

  group('Requirement R5: WindowDragBar Fullscreen Drag Suppression Tests', () {
    late DesktopWindowController controller;
    final List<String> channelCalls = [];

    setUp(() {
      channelCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('lumina/window'),
        (MethodCall call) async {
          channelCalls.add(call.method);
          return null;
        },
      );
      controller = DesktopWindowController(isSupportedOverride: true);
      DesktopWindowController.instance = controller;
    });

    tearDown(() {
      DesktopWindowController.instance = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('lumina/window'), null);
    });

    testWidgets('Normal mode allows drag and double-tap maximize', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WindowDragBar(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final gestureFinder = find.byType(GestureDetector);
      expect(gestureFinder, findsOneWidget);

      // Pan drag
      await tester.drag(gestureFinder, const Offset(50, 0));
      await tester.pumpAndSettle();
      expect(channelCalls, contains('startDragging'));

      // Double tap
      channelCalls.clear();
      await tester.tap(gestureFinder);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(gestureFinder);
      await tester.pumpAndSettle();
      expect(channelCalls, contains('toggleMaximize'));
    });

    testWidgets('Fullscreen mode suppresses drag and double-tap maximize gestures', (
      WidgetTester tester,
    ) async {
      controller.isFullScreenNotifier.value = true;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WindowDragBar(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final gestureFinder = find.byType(GestureDetector);
      expect(gestureFinder, findsOneWidget);

      // Pan drag in fullscreen
      await tester.drag(gestureFinder, const Offset(50, 0));
      await tester.pumpAndSettle();
      expect(channelCalls, isNot(contains('startDragging')));

      // Double tap in fullscreen
      await tester.tap(gestureFinder);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(gestureFinder);
      await tester.pumpAndSettle();
      expect(channelCalls, isNot(contains('toggleMaximize')));
    });
  });

  group('Requirement R5: HomeScreen Shortcuts (F11 & Esc priority)', () {
    late DesktopWindowController controller;
    late MockAudioService audioService;
    bool mockFullScreen = false;

    setUp(() {
      mockFullScreen = false;
      audioService = MockAudioService();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('lumina/window'),
        (MethodCall call) async {
          if (call.method == 'isFullScreen') return mockFullScreen;
          if (call.method == 'setFullScreen') {
            mockFullScreen = call.arguments as bool;
            return null;
          }
          if (call.method == 'toggleFullScreen') {
            mockFullScreen = !mockFullScreen;
            return null;
          }
          return null;
        },
      );

      controller = DesktopWindowController(isSupportedOverride: true);
      DesktopWindowController.instance = controller;
    });

    tearDown(() {
      DesktopWindowController.instance = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('lumina/window'), null);
    });

    testWidgets('F11 shortcut toggles fullscreen mode', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            audioService: audioService,
            windowController: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(controller.isFullScreenNotifier.value, isFalse);

      // Press F11
      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();

      expect(mockFullScreen, isTrue);
      expect(controller.isFullScreenNotifier.value, isTrue);

      // Press F11 again
      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();

      expect(mockFullScreen, isFalse);
      expect(controller.isFullScreenNotifier.value, isFalse);
    });

    testWidgets('Esc shortcut exits fullscreen FIRST without dismissing Now Playing overlay', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            audioService: audioService,
            windowController: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open now playing overlay by tapping expand button on mini player
      final expandBtnFinder = find.byKey(const Key('btn_expand_now_playing'));
      expect(expandBtnFinder, findsOneWidget);
      await tester.tap(expandBtnFinder);
      await tester.pumpAndSettle();

      // Now Playing overlay should be open
      expect(find.byKey(const Key('now_playing_overlay')), findsOneWidget);

      // Enter fullscreen mode
      await controller.setFullScreen(true);
      mockFullScreen = true;
      await tester.pumpAndSettle();
      expect(await controller.isFullScreen(), isTrue);

      // Press Escape: Must exit fullscreen mode first, keeping Now Playing overlay OPEN!
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(await controller.isFullScreen(), isFalse);
      expect(mockFullScreen, isFalse);
      expect(find.byKey(const Key('now_playing_overlay')), findsOneWidget);

      // Press Escape again: Now that we are not in fullscreen, closes Now Playing overlay
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('now_playing_overlay')), findsNothing);
    });

    testWidgets('F11 shortcut while Now Playing overlay is open toggles fullscreen and keeps overlay open', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            audioService: audioService,
            windowController: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open now playing overlay
      final expandBtnFinder = find.byKey(const Key('btn_expand_now_playing'));
      await tester.tap(expandBtnFinder);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('now_playing_overlay')), findsOneWidget);

      // Press F11 while Now Playing overlay is open
      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();

      expect(mockFullScreen, isTrue);
      expect(controller.isFullScreenNotifier.value, isTrue);
      expect(find.byKey(const Key('now_playing_overlay')), findsOneWidget);

      // Press F11 again
      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();

      expect(mockFullScreen, isFalse);
      expect(controller.isFullScreenNotifier.value, isFalse);
      expect(find.byKey(const Key('now_playing_overlay')), findsOneWidget);
    });
  });

  group('Requirements R1 & R2: Maximized & Normal Fullscreen Transition & Restoration Tests', () {
    final List<String> callSequence = [];
    bool isMaximizedState = false;
    bool isFullScreenState = false;
    Map<String, dynamic> currentBounds = {
      'x': 150.0,
      'y': 120.0,
      'width': 1280.0,
      'height': 800.0,
    };
    Map<String, dynamic>? restoredBounds;

    setUp(() {
      callSequence.clear();
      isMaximizedState = false;
      isFullScreenState = false;
      restoredBounds = null;
      currentBounds = {
        'x': 150.0,
        'y': 120.0,
        'width': 1280.0,
        'height': 800.0,
      };

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('lumina/window'),
        (MethodCall call) async {
          callSequence.add(call.method);
          switch (call.method) {
            case 'isMaximized':
              return isMaximizedState;
            case 'maximize':
              isMaximizedState = true;
              return null;
            case 'unmaximize':
            case 'restore':
              isMaximizedState = false;
              return null;
            case 'isFullScreen':
              return isFullScreenState;
            case 'setFullScreen':
              isFullScreenState = call.arguments as bool;
              return null;
            case 'toggleFullScreen':
              isFullScreenState = !isFullScreenState;
              return null;
            case 'getBounds':
              return currentBounds;
            case 'setBounds':
              restoredBounds = Map<String, dynamic>.from(call.arguments as Map);
              return null;
            default:
              return null;
          }
        },
      );
    });

    tearDown(() {
      DesktopWindowController.instance = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('lumina/window'), null);
    });

    test('Maximized -> Fullscreen: unmaximizes first with wasMaximizedBeforeFullScreen, then restores maximized on exit', () async {
      final controller = DesktopWindowController(isSupportedOverride: true);
      isMaximizedState = true;

      // Enter fullscreen from maximized state
      await controller.setFullScreen(true);

      expect(controller.wasMaximizedBeforeFullScreen, isTrue);
      expect(controller.isFullScreenNotifier.value, isTrue);
      expect(isFullScreenState, isTrue);

      // Verify sequence: isMaximized was checked, unmaximize called BEFORE setFullScreen
      final unmaxIndex = callSequence.indexOf('unmaximize');
      final setFsIndex = callSequence.indexOf('setFullScreen');
      expect(unmaxIndex, isNonNegative, reason: 'unmaximize must be invoked');
      expect(setFsIndex, isNonNegative, reason: 'setFullScreen must be invoked');
      expect(unmaxIndex, lessThan(setFsIndex), reason: 'unmaximize must precede setFullScreen');

      // Exit fullscreen
      callSequence.clear();
      await controller.setFullScreen(false);

      expect(controller.wasMaximizedBeforeFullScreen, isFalse);
      expect(controller.isFullScreenNotifier.value, isFalse);
      expect(isFullScreenState, isFalse);

      // Verify sequence: setFullScreen(false) called, followed by maximize()
      expect(callSequence, contains('setFullScreen'));
      expect(callSequence, contains('maximize'));
      final exitFsIndex = callSequence.indexOf('setFullScreen');
      final maxIndex = callSequence.indexOf('maximize');
      expect(exitFsIndex, lessThan(maxIndex), reason: 'setFullScreen(false) must precede maximize()');
      expect(isMaximizedState, isTrue, reason: 'Window should be restored to maximized state');
    });

    test('Normal window -> Fullscreen: records bounds, then restores exact bounds on exit', () async {
      final controller = DesktopWindowController(isSupportedOverride: true);
      isMaximizedState = false;
      currentBounds = {
        'x': 200.0,
        'y': 150.0,
        'width': 1024.0,
        'height': 768.0,
      };

      // Enter fullscreen from normal window
      await controller.setFullScreen(true);

      expect(controller.wasMaximizedBeforeFullScreen, isFalse);
      expect(controller.savedBoundsBeforeFullScreen, isNotNull);
      expect(controller.savedBoundsBeforeFullScreen!.left, equals(200.0));
      expect(controller.savedBoundsBeforeFullScreen!.top, equals(150.0));
      expect(controller.savedBoundsBeforeFullScreen!.width, equals(1024.0));
      expect(controller.savedBoundsBeforeFullScreen!.height, equals(768.0));
      expect(controller.isFullScreenNotifier.value, isTrue);

      // Verify sequence: getBounds invoked before setFullScreen
      final getBoundsIndex = callSequence.indexOf('getBounds');
      final setFsIndex = callSequence.indexOf('setFullScreen');
      expect(getBoundsIndex, isNonNegative);
      expect(setFsIndex, isNonNegative);
      expect(getBoundsIndex, lessThan(setFsIndex));

      // Exit fullscreen
      callSequence.clear();
      await controller.setFullScreen(false);

      expect(controller.isFullScreenNotifier.value, isFalse);
      expect(controller.savedBoundsBeforeFullScreen, isNull);
      expect(callSequence, contains('setBounds'));
      expect(restoredBounds, isNotNull);
      expect(restoredBounds!['x'], equals(200.0));
      expect(restoredBounds!['y'], equals(150.0));
      expect(restoredBounds!['width'], equals(1024.0));
      expect(restoredBounds!['height'], equals(768.0));
    });

    test('Secondary monitor with negative coordinates -> Fullscreen: restores exact negative bounds on exit', () async {
      final controller = DesktopWindowController(isSupportedOverride: true);
      isMaximizedState = false;
      // Secondary monitor placed to the left of primary monitor
      currentBounds = {
        'x': -1920.0,
        'y': 50.0,
        'width': 1920.0,
        'height': 1080.0,
      };

      await controller.setFullScreen(true);

      expect(controller.wasMaximizedBeforeFullScreen, isFalse);
      expect(controller.savedBoundsBeforeFullScreen, isNotNull);
      expect(controller.savedBoundsBeforeFullScreen!.left, equals(-1920.0));
      expect(controller.savedBoundsBeforeFullScreen!.top, equals(50.0));
      expect(controller.savedBoundsBeforeFullScreen!.width, equals(1920.0));
      expect(controller.savedBoundsBeforeFullScreen!.height, equals(1080.0));
      expect(controller.isFullScreenNotifier.value, isTrue);

      callSequence.clear();
      await controller.setFullScreen(false);

      expect(controller.isFullScreenNotifier.value, isFalse);
      expect(controller.savedBoundsBeforeFullScreen, isNull);
      expect(callSequence, contains('setBounds'));
      expect(restoredBounds, isNotNull);
      expect(restoredBounds!['x'], equals(-1920.0));
      expect(restoredBounds!['y'], equals(50.0));
      expect(restoredBounds!['width'], equals(1920.0));
      expect(restoredBounds!['height'], equals(1080.0));
    });

    test('Direct DesktopWindowController unmaximize(), getBounds(), setBounds() APIs work', () async {
      final controller = DesktopWindowController(isSupportedOverride: true);

      await controller.unmaximize();
      expect(callSequence, contains('unmaximize'));

      final bounds = await controller.getBounds();
      expect(bounds.left, equals(150.0));
      expect(bounds.top, equals(120.0));
      expect(bounds.width, equals(1280.0));
      expect(bounds.height, equals(800.0));

      const newBounds = Rect.fromLTWH(50, 60, 800, 600);
      await controller.setBounds(newBounds);
      expect(callSequence, contains('setBounds'));
      expect(restoredBounds!['x'], equals(50.0));
      expect(restoredBounds!['y'], equals(60.0));
      expect(restoredBounds!['width'], equals(800.0));
      expect(restoredBounds!['height'], equals(600.0));
    });

    test('Idempotency: calling setFullScreen with identical target is a safe no-op', () async {
      final controller = DesktopWindowController(isSupportedOverride: true);
      isMaximizedState = true;

      await controller.setFullScreen(true);
      expect(controller.wasMaximizedBeforeFullScreen, isTrue);
      final countBefore = callSequence.length;

      // Duplicate call while already in fullscreen
      await controller.setFullScreen(true);
      expect(callSequence.length, equals(countBefore), reason: 'Duplicate call must not invoke channel');

      // Exit fullscreen
      await controller.setFullScreen(false);
      final countAfterExit = callSequence.length;

      // Duplicate call while not in fullscreen
      await controller.setFullScreen(false);
      expect(callSequence.length, equals(countAfterExit));
    });

    test('Normal window with dirty wasMaximizedBeforeFullScreen resets flag and restores bounds', () async {
      final controller = DesktopWindowController(isSupportedOverride: true);
      // Simulate dirty or leftover wasMaximizedBeforeFullScreen flag
      controller.wasMaximizedBeforeFullScreen = true;
      isMaximizedState = false;
      currentBounds = {
        'x': 320.0,
        'y': 180.0,
        'width': 1000.0,
        'height': 600.0,
      };

      await controller.setFullScreen(true);
      // Flag must be cleared to false and bounds must be captured!
      expect(controller.wasMaximizedBeforeFullScreen, isFalse);
      expect(controller.savedBoundsBeforeFullScreen, isNotNull);
      expect(controller.savedBoundsBeforeFullScreen!.width, equals(1000.0));

      // Exit fullscreen
      callSequence.clear();
      await controller.setFullScreen(false);

      expect(callSequence, contains('setBounds'));
      expect(callSequence, isNot(contains('maximize')));
      expect(restoredBounds!['x'], equals(320.0));
      expect(restoredBounds!['y'], equals(180.0));
      expect(restoredBounds!['width'], equals(1000.0));
      expect(restoredBounds!['height'], equals(600.0));
    });

    test('Concurrent re-entrant calls to setFullScreen are guarded by transition lock', () async {
      final controller = DesktopWindowController(isSupportedOverride: true);
      isMaximizedState = false;

      // Fire two setFullScreen calls concurrently
      final f1 = controller.setFullScreen(true);
      final f2 = controller.setFullScreen(true);
      await Future.wait([f1, f2]);

      expect(controller.isFullScreenNotifier.value, isTrue);
      final setFsCalls = callSequence.where((m) => m == 'setFullScreen').length;
      expect(setFsCalls, equals(1), reason: 'Re-entrant call must be dropped by transition lock');

      // Exit fullscreen concurrently
      final f3 = controller.setFullScreen(false);
      final f4 = controller.setFullScreen(false);
      await Future.wait([f3, f4]);

      expect(controller.isFullScreenNotifier.value, isFalse);
    });

    test('Exiting fullscreen when savedBounds is Rect.zero resets savedBounds and does not call setBounds', () async {
      final controller = DesktopWindowController(isSupportedOverride: true);
      isMaximizedState = false;
      currentBounds = {'x': 0.0, 'y': 0.0, 'width': 0.0, 'height': 0.0};

      await controller.setFullScreen(true);
      expect(controller.savedBoundsBeforeFullScreen, equals(Rect.zero));

      callSequence.clear();
      await controller.setFullScreen(false);

      expect(controller.savedBoundsBeforeFullScreen, isNull);
      expect(callSequence, isNot(contains('setBounds')));
    });
  });

  group('Requirements R1 & R3: Caption Buttons Interaction with Maximized Fullscreen State', () {
    final List<String> channelCalls = [];
    late DesktopWindowController controller;
    late MockAudioService audioService;
    bool mockFullScreen = false;
    bool mockMaximized = false;

    setUp(() {
      channelCalls.clear();
      mockFullScreen = false;
      mockMaximized = true; // Started as maximized!
      audioService = MockAudioService();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('lumina/window'),
        (MethodCall call) async {
          channelCalls.add(call.method);
          if (call.method == 'isFullScreen') return mockFullScreen;
          if (call.method == 'setFullScreen') {
            mockFullScreen = call.arguments as bool;
            return null;
          }
          if (call.method == 'isMaximized') return mockMaximized;
          if (call.method == 'maximize') {
            mockMaximized = true;
            return null;
          }
          if (call.method == 'unmaximize') {
            mockMaximized = false;
            return null;
          }
          if (call.method == 'toggleMaximize') {
            mockMaximized = !mockMaximized;
            return null;
          }
          return null;
        },
      );

      controller = DesktopWindowController(isSupportedOverride: true);
      DesktopWindowController.instance = controller;
    });

    tearDown(() {
      DesktopWindowController.instance = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('lumina/window'), null);
    });

    testWidgets('Tapping fullscreen button from maximized unmaximizes, and tapping maximize button exits and re-maximizes', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopWindowCaptionButtons(
              controller: controller,
              audioService: audioService,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap fullscreen button to enter fullscreen
      await tester.tap(find.byKey(const Key('btn_window_fullscreen')));
      await tester.pumpAndSettle();

      expect(mockFullScreen, isTrue);
      expect(controller.wasMaximizedBeforeFullScreen, isTrue);
      expect(channelCalls, contains('unmaximize'));
      expect(channelCalls, contains('setFullScreen'));

      // In fullscreen, tapping the maximize button exits fullscreen and restores maximized state
      await tester.tap(find.byKey(const Key('btn_window_maximize')));
      await tester.pumpAndSettle();

      expect(mockFullScreen, isFalse);
      expect(controller.wasMaximizedBeforeFullScreen, isFalse);
      expect(channelCalls, contains('maximize'));
      expect(mockMaximized, isTrue);
    });
  });

  group('Requirement R3: Multi-monitor, Windows DPI & App UI Scale Fullscreen Responsiveness & Integrity', () {
    late DesktopWindowController controller;
    late MockAudioService audioService;
    late UiScaleController scaleController;
    bool mockFullScreen = false;

    setUp(() {
      mockFullScreen = false;
      audioService = MockAudioService();
      scaleController = UiScaleController();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('lumina/window'),
        (MethodCall call) async {
          if (call.method == 'isFullScreen') return mockFullScreen;
          if (call.method == 'setFullScreen') {
            mockFullScreen = call.arguments as bool;
            return null;
          }
          if (call.method == 'toggleFullScreen') {
            mockFullScreen = !mockFullScreen;
            return null;
          }
          if (call.method == 'isMaximized') return false;
          if (call.method == 'getBounds') {
            return {'x': 100.0, 'y': 100.0, 'width': 1200.0, 'height': 800.0};
          }
          return null;
        },
      );

      controller = DesktopWindowController(isSupportedOverride: true);
      DesktopWindowController.instance = controller;
    });

    tearDown(() {
      scaleController.dispose();
      DesktopWindowController.instance = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('lumina/window'), null);
    });

    testWidgets('Across multi-monitor resolutions, Windows DPI (100%, 125%, 150%) and UI scales (100%, 120%, 150%), bottom player bar aligns flush to screen bottom in Home and Now Playing without overflow', (
      WidgetTester tester,
    ) async {
      final displayConfigs = [
        (physicalSize: const Size(1920, 1080), dpr: 1.0, uiScale: 1.0),
        (physicalSize: const Size(2560, 1440), dpr: 1.25, uiScale: 1.2),
        (physicalSize: const Size(3840, 2160), dpr: 1.5, uiScale: 1.5),
      ];

      for (final cfg in displayConfigs) {
        tester.view.physicalSize = cfg.physicalSize;
        tester.view.devicePixelRatio = cfg.dpr;
        scaleController.setScale(cfg.uiScale);

        await tester.pumpWidget(
          MaterialApp(
            home: HomeScreen(
              audioService: audioService,
              windowController: controller,
              uiScaleController: scaleController,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 1. Enter fullscreen
        await controller.setFullScreen(true);
        mockFullScreen = true;
        await tester.pumpAndSettle();

        final logicalHeight = cfg.physicalSize.height / cfg.dpr;

        // Find the visible floating mini player capsule at bottom
        final miniPlayers = tester.widgetList<FloatingCapsuleMiniPlayer>(
          find.byType(FloatingCapsuleMiniPlayer),
        );
        expect(miniPlayers, isNotEmpty);

        final miniPlayerFinder = find.byWidgetPredicate(
          (widget) =>
              widget is FloatingCapsuleMiniPlayer &&
              widget.key != null &&
              widget.key == const Key('floating_capsule_mini_player') ||
              widget is FloatingCapsuleMiniPlayer,
        );
        // Check the last one in the tree (the positioned overlay layer)
        final lastMiniPlayer = miniPlayerFinder.last;
        final miniPlayerRect = tester.getRect(lastMiniPlayer);

        expect(
          miniPlayerRect.bottom,
          closeTo(logicalHeight, 1.0),
          reason: 'Mini player must be pinned flush to screen bottom in fullscreen',
        );

        // Verify zero overflow exceptions
        expect(tester.takeException(), isNull);

        // 2. Open Now Playing overlay in fullscreen
        final expandBtn = find.byKey(const Key('btn_expand_now_playing'));
        expect(expandBtn, findsOneWidget);
        await tester.tap(expandBtn);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('now_playing_stage')), findsOneWidget);
        final overlayPlayerRect = tester.getRect(lastMiniPlayer);
        expect(
          overlayPlayerRect.bottom,
          closeTo(logicalHeight, 1.0),
          reason: 'Now Playing bottom player bar must remain flush at screen bottom in fullscreen',
        );
        expect(tester.takeException(), isNull);

        // 3. Exit fullscreen
        await controller.setFullScreen(false);
        mockFullScreen = false;
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);

        // Reset for next config
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
      tester.view.reset();
    });
  });
}
