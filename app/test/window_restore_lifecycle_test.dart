import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/home_layout_preset.dart';
import 'package:lumina_app/models/nav_entry.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/services/desktop_window_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/playback_persistence_service.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/ui/common/desktop_window_caption.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DesktopWindowController - Native Window Lifecycle Callbacks', () {
    final List<MethodCall> outgoingCalls = [];
    bool mockIsMaximized = false;

    setUp(() {
      outgoingCalls.clear();
      mockIsMaximized = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('lumina/window'),
        (MethodCall call) async {
          outgoingCalls.add(call);
          if (call.method == 'isMaximized') return mockIsMaximized;
          if (call.method == 'isFullScreen') return false;
          return null;
        },
      );
    });

    tearDown(() {
      DesktopWindowController.instance = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('lumina/window'), null);
    });

    Future<void> sendNativeCall(String method, [dynamic args]) async {
      final data = const StandardMethodCodec().encodeMethodCall(
        MethodCall(method, args),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage('lumina/window', data, (ByteData? _) {});
    }

    test('dispatches all 6 new native callbacks and updates notifiers', () async {
      final controller = DesktopWindowController(
        isSupportedOverride: true,
        installMethodHandler: false,
      );

      expect(controller.isMinimizedNotifier.value, isFalse);
      expect(controller.isHiddenToTrayNotifier.value, isFalse);
      expect(controller.isMaximizedNotifier.value, isFalse);
      expect(controller.isFocusedNotifier.value, isTrue);

      var minimizeCount = 0;
      var restoreCount = 0;
      var maximizeCount = 0;
      var unmaximizeCount = 0;
      var focusCount = 0;
      var blurCount = 0;

      controller.onWindowMinimize = () => minimizeCount++;
      controller.onWindowRestore = () => restoreCount++;
      controller.onWindowMaximize = () => maximizeCount++;
      controller.onWindowUnmaximize = () => unmaximizeCount++;
      controller.onWindowFocus = () => focusCount++;
      controller.onWindowBlur = () => blurCount++;

      expect(controller.onWindowMinimize, isNotNull);
      expect(controller.onWindowRestore, isNotNull);
      expect(controller.onWindowMaximize, isNotNull);
      expect(controller.onWindowUnmaximize, isNotNull);
      expect(controller.onWindowFocus, isNotNull);
      expect(controller.onWindowBlur, isNotNull);

      // 1. onWindowMinimize
      await controller.handleIncomingCall(const MethodCall('onWindowMinimize'));
      expect(controller.isMinimizedNotifier.value, isTrue);
      expect(minimizeCount, equals(1));

      // 2. onWindowRestore (clears minimized & hidden-to-tray)
      controller.isHiddenToTrayNotifier.value = true;
      await controller.handleIncomingCall(const MethodCall('onWindowRestore'));
      expect(controller.isMinimizedNotifier.value, isFalse);
      expect(controller.isHiddenToTrayNotifier.value, isFalse);
      expect(restoreCount, equals(1));

      // 3. onWindowMaximize
      controller.isMinimizedNotifier.value = true;
      controller.isHiddenToTrayNotifier.value = true;
      await controller.handleIncomingCall(const MethodCall('onWindowMaximize'));
      expect(controller.isMinimizedNotifier.value, isFalse);
      expect(controller.isHiddenToTrayNotifier.value, isFalse);
      expect(controller.isMaximizedNotifier.value, isTrue);
      expect(maximizeCount, equals(1));

      // 4. onWindowUnmaximize
      controller.isMinimizedNotifier.value = true;
      controller.isHiddenToTrayNotifier.value = true;
      await controller.handleIncomingCall(const MethodCall('onWindowUnmaximize'));
      expect(controller.isMinimizedNotifier.value, isFalse);
      expect(controller.isHiddenToTrayNotifier.value, isFalse);
      expect(controller.isMaximizedNotifier.value, isFalse);
      expect(unmaximizeCount, equals(1));

      // 5. onWindowBlur
      await controller.handleIncomingCall(const MethodCall('onWindowBlur'));
      expect(controller.isFocusedNotifier.value, isFalse);
      expect(blurCount, equals(1));

      // 6. onWindowFocus (clears minimized & hidden-to-tray, marks focused)
      controller.isMinimizedNotifier.value = true;
      controller.isHiddenToTrayNotifier.value = true;
      await controller.handleIncomingCall(const MethodCall('onWindowFocus'));
      expect(controller.isMinimizedNotifier.value, isFalse);
      expect(controller.isHiddenToTrayNotifier.value, isFalse);
      expect(controller.isFocusedNotifier.value, isTrue);
      expect(focusCount, equals(1));

      // Also verify real platform message envelope dispatch via installed handler
      await sendNativeCall('onWindowBlur');
      expect(controller.isFocusedNotifier.value, isFalse);
      expect(blurCount, equals(2));

      await sendNativeCall('onWindowMaximize');
      expect(controller.isMaximizedNotifier.value, isTrue);
      expect(maximizeCount, equals(2));

      await sendNativeCall('onWindowMinimize');
      expect(controller.isMinimizedNotifier.value, isTrue);
      expect(minimizeCount, equals(2));

      await sendNativeCall('onWindowFocus');
      expect(controller.isMinimizedNotifier.value, isFalse);
      expect(controller.isFocusedNotifier.value, isTrue);
      expect(focusCount, equals(2));

      await sendNativeCall('onWindowUnmaximize');
      expect(controller.isMaximizedNotifier.value, isFalse);
      expect(unmaximizeCount, equals(2));

      await sendNativeCall('onWindowRestore');
      expect(restoreCount, equals(2));

      // Clearing callbacks stops invocation while keeping notifier behavior intact
      controller.onWindowMinimize = null;
      controller.onWindowRestore = null;
      controller.onWindowMaximize = null;
      controller.onWindowUnmaximize = null;
      controller.onWindowFocus = null;
      controller.onWindowBlur = null;

      await controller.handleIncomingCall(const MethodCall('onWindowMinimize'));
      expect(controller.isMinimizedNotifier.value, isTrue);
      expect(minimizeCount, equals(2));
    });

    test('isMaximized() updates isMaximizedNotifier when supported', () async {
      final controller = DesktopWindowController(isSupportedOverride: true);
      expect(controller.isMaximizedNotifier.value, isFalse);

      mockIsMaximized = true;
      expect(await controller.isMaximized(), isTrue);
      expect(controller.isMaximizedNotifier.value, isTrue);

      mockIsMaximized = false;
      expect(await controller.isMaximized(), isFalse);
      expect(controller.isMaximizedNotifier.value, isFalse);
    });
  });

  group('HomeScreen - Window Minimize, Tray & Restore Lifecycle', () {
    late Directory tempDir;
    late MockAudioService audioService;
    late UiScaleController scaleController;
    late PlaybackPersistenceService persistenceService;
    late NavHistoryController navController;
    late DesktopWindowController windowController;
    late List<String> channelCalls;
    bool mockIsMaximized = false;
    bool mockIsFullScreen = false;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('window_restore_test_');
      channelCalls = [];
      mockIsMaximized = false;
      mockIsFullScreen = false;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('lumina/window'),
        (MethodCall call) async {
          channelCalls.add(call.method);
          switch (call.method) {
            case 'isMaximized':
              return mockIsMaximized;
            case 'maximize':
              mockIsMaximized = true;
              return null;
            case 'unmaximize':
              mockIsMaximized = false;
              return null;
            case 'toggleMaximize':
              mockIsMaximized = !mockIsMaximized;
              return null;
            case 'isFullScreen':
              return mockIsFullScreen;
            case 'setFullScreen':
              mockIsFullScreen = call.arguments as bool;
              return null;
            case 'toggleFullScreen':
              mockIsFullScreen = !mockIsFullScreen;
              return null;
            default:
              return null;
          }
        },
      );

      audioService = MockAudioService();
      scaleController = UiScaleController(
        initialHomeLayoutPreset: HomeLayoutPreset.classic,
        prefsFileOverride: File(
          '${tempDir.path}${Platform.pathSeparator}ui_prefs.json',
        ),
      );
      persistenceService = PlaybackPersistenceService(
        prefsFileOverride: File(
          '${tempDir.path}${Platform.pathSeparator}playback_session.json',
        ),
      );
      navController = NavHistoryController();
      windowController = DesktopWindowController(isSupportedOverride: true);
      DesktopWindowController.instance = windowController;
    });

    tearDown(() async {
      DesktopWindowController.instance = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('lumina/window'), null);
      navController.dispose();
      persistenceService.dispose();
      scaleController.dispose();
      audioService.dispose();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    Future<void> pumpHomeScreen(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaTokens.buildDarkTheme(),
          home: HomeScreen(
            audioService: audioService,
            uiScaleController: scaleController,
            playbackPersistenceService: persistenceService,
            navHistoryController: navController,
            windowController: windowController,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    TickerMode rootHomeTickerMode(WidgetTester tester) {
      return tester.widget<TickerMode>(
        find.descendant(
          of: find.byType(HomeScreen),
          matching: find.byType(TickerMode),
        ).first,
      );
    }

    Future<void> verifyUiInteractive(WidgetTester tester) async {
      final beforeStatus = audioService.currentState.status;
      await tester.tap(find.byKey(const Key('btn_play_pause')));
      await tester.pumpAndSettle();
      expect(
        audioService.currentState.status,
        isNot(equals(beforeStatus)),
        reason: 'Play/pause button must respond after window restore',
      );
      final expectedAfter = beforeStatus == PlaybackStatus.playing
          ? PlaybackStatus.paused
          : PlaybackStatus.playing;
      expect(audioService.currentState.status, equals(expectedAfter));

      final targetTab = navController.current.tab == HomeTab.library
          ? HomeTab.albums
          : HomeTab.library;
      final targetKey = targetTab == HomeTab.library
          ? const Key('nav_tab_library')
          : const Key('nav_tab_albums');
      await tester.tap(find.byKey(targetKey));
      await tester.pumpAndSettle();
      expect(
        navController.current.tab,
        equals(targetTab),
        reason: 'Sidebar navigation tabs must remain clickable after restore',
      );
    }

    void simulateLifecycleMinimizeAndResume(WidgetTester tester) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }

    testWidgets(
      'taskbar minimize keeps root TickerMode enabled and recovers cleanly on all restore signals',
      (WidgetTester tester) async {
        await pumpHomeScreen(tester);

        final restorePaths = <String, Future<void> Function()>{
          'onWindowRestore': () => windowController.handleIncomingCall(
            const MethodCall('onWindowRestore'),
          ),
          'onWindowFocus': () => windowController.handleIncomingCall(
            const MethodCall('onWindowFocus'),
          ),
          'onWindowMaximize': () async {
            mockIsMaximized = true;
            await windowController.handleIncomingCall(
              const MethodCall('onWindowMaximize'),
            );
          },
          'AppLifecycleState.resumed': () async {
            simulateLifecycleMinimizeAndResume(tester);
          },
        };

        for (final entry in restorePaths.entries) {
          await tester.tap(find.byKey(const Key('btn_window_minimize')));
          await tester.pumpAndSettle();

          expect(
            audioService.windowMinimized,
            isTrue,
            reason: '${entry.key}: minimize should set audioService.windowMinimized',
          );
          expect(
            windowController.isMinimizedNotifier.value,
            isTrue,
            reason: '${entry.key}: minimize should set isMinimizedNotifier',
          );
          expect(
            rootHomeTickerMode(tester).enabled,
            isTrue,
            reason:
                '${entry.key}: normal taskbar minimize must keep root TickerMode enabled',
          );

          await entry.value();
          await tester.pumpAndSettle();

          expect(
            audioService.windowMinimized,
            isFalse,
            reason: '${entry.key}: restore must clear audioService.windowMinimized',
          );
          expect(
            windowController.isMinimizedNotifier.value,
            isFalse,
            reason: '${entry.key}: restore must clear isMinimizedNotifier',
          );
          expect(rootHomeTickerMode(tester).enabled, isTrue);

          await verifyUiInteractive(tester);

          // Reset maximize state if needed before next iteration
          if (mockIsMaximized) {
            mockIsMaximized = false;
            await windowController.handleIncomingCall(
              const MethodCall('onWindowUnmaximize'),
            );
            await tester.pumpAndSettle();
          }
        }
      },
    );

    testWidgets(
      'closing to tray disables root TickerMode and restores cleanly across all wake triggers',
      (WidgetTester tester) async {
        await pumpHomeScreen(tester);
        expect(scaleController.minimizeToTrayOnClose, isTrue);

        final wakePaths = <String, Future<void> Function()>{
          'onTrayClick': () => windowController.handleIncomingCall(
            const MethodCall('onTrayClick'),
          ),
          'onSingleInstanceWakeup': () => windowController.handleIncomingCall(
            const MethodCall('onSingleInstanceWakeup'),
          ),
          'onWindowRestore': () => windowController.handleIncomingCall(
            const MethodCall('onWindowRestore'),
          ),
          'onWindowFocus': () => windowController.handleIncomingCall(
            const MethodCall('onWindowFocus'),
          ),
          'AppLifecycleState.resumed': () async {
            simulateLifecycleMinimizeAndResume(tester);
          },
        };

        for (final entry in wakePaths.entries) {
          channelCalls.clear();
          await windowController.handleIncomingCall(
            const MethodCall('onWindowClose'),
          );
          await tester.pumpAndSettle();

          expect(
            rootHomeTickerMode(tester).enabled,
            isFalse,
            reason: '${entry.key}: closing to tray must disable root TickerMode',
          );
          expect(audioService.windowMinimized, isTrue);
          expect(windowController.isHiddenToTrayNotifier.value, isTrue);
          expect(channelCalls, contains('hide'));

          await entry.value();
          await tester.pumpAndSettle();

          expect(
            rootHomeTickerMode(tester).enabled,
            isTrue,
            reason: '${entry.key}: restoring from tray must re-enable root TickerMode',
          );
          expect(audioService.windowMinimized, isFalse);
          expect(windowController.isHiddenToTrayNotifier.value, isFalse);
          expect(windowController.isMinimizedNotifier.value, isFalse);

          await verifyUiInteractive(tester);
        }
      },
    );

    testWidgets(
      'repeated maximize -> minimize -> restore -> unmaximize -> remaximize cycles keep caption icon synced and UI responsive',
      (WidgetTester tester) async {
        await pumpHomeScreen(tester);

        Finder captionButtonsFinder() =>
            find.byType(DesktopWindowCaptionButtons);
        Finder maximizeIconFinder() => find.descendant(
          of: captionButtonsFinder(),
          matching: find.byIcon(Icons.crop_square_rounded),
        );
        Finder restoreIconFinder() => find.descendant(
          of: captionButtonsFinder(),
          matching: find.byIcon(Icons.filter_none_rounded),
        );

        expect(maximizeIconFinder(), findsOneWidget);
        expect(restoreIconFinder(), findsNothing);

        for (var cycle = 0; cycle < 3; cycle++) {
          // 1. Maximize
          mockIsMaximized = true;
          await windowController.handleIncomingCall(
            const MethodCall('onWindowMaximize'),
          );
          await tester.pumpAndSettle();

          expect(windowController.isMaximizedNotifier.value, isTrue);
          expect(restoreIconFinder(), findsOneWidget);
          expect(maximizeIconFinder(), findsNothing);

          // 2. Minimize while maximized
          await tester.tap(find.byKey(const Key('btn_window_minimize')));
          await tester.pumpAndSettle();

          expect(audioService.windowMinimized, isTrue);
          expect(windowController.isMinimizedNotifier.value, isTrue);
          expect(rootHomeTickerMode(tester).enabled, isTrue);

          // 3. Restore back to maximized (OS restores Zoomed window + emits focus/resumed)
          await windowController.handleIncomingCall(
            const MethodCall('onWindowRestore'),
          );
          await windowController.handleIncomingCall(
            const MethodCall('onWindowFocus'),
          );
          simulateLifecycleMinimizeAndResume(tester);
          await tester.pumpAndSettle();

          expect(audioService.windowMinimized, isFalse);
          expect(windowController.isMinimizedNotifier.value, isFalse);
          expect(windowController.isMaximizedNotifier.value, isTrue);
          expect(restoreIconFinder(), findsOneWidget);
          expect(maximizeIconFinder(), findsNothing);
          await verifyUiInteractive(tester);

          // 4. Unmaximize
          mockIsMaximized = false;
          await windowController.handleIncomingCall(
            const MethodCall('onWindowUnmaximize'),
          );
          await tester.pumpAndSettle();

          expect(windowController.isMaximizedNotifier.value, isFalse);
          expect(maximizeIconFinder(), findsOneWidget);
          expect(restoreIconFinder(), findsNothing);
          await verifyUiInteractive(tester);

          // 5. Remaximize via caption button
          await tester.tap(find.byKey(const Key('btn_window_maximize')));
          await tester.pumpAndSettle();

          expect(mockIsMaximized, isTrue);
          expect(windowController.isMaximizedNotifier.value, isTrue);
          expect(restoreIconFinder(), findsOneWidget);
          expect(maximizeIconFinder(), findsNothing);
          await verifyUiInteractive(tester);

          // Reset to unmaximized before next cycle
          mockIsMaximized = false;
          await windowController.handleIncomingCall(
            const MethodCall('onWindowUnmaximize'),
          );
          await tester.pumpAndSettle();
          expect(maximizeIconFinder(), findsOneWidget);
        }
      },
    );
  });
}
