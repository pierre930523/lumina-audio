import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/services/desktop_window_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/ui/settings/general_settings_panel.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UiScaleController - minimizeToTrayOnClose Persistence', () {
    late Directory tempDir;
    late File testPrefsFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('tray_close_ctrl_test_');
      testPrefsFile = File(
        '${tempDir.path}${Platform.pathSeparator}ui_prefs.json',
      );
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('default value of minimizeToTrayOnClose is true', () {
      final ctrl = UiScaleController(prefsFileOverride: testPrefsFile);
      expect(ctrl.minimizeToTrayOnClose, isTrue);
    });

    test(
      'setMinimizeToTrayOnClose updates value, notifies listeners, and persists to ui_prefs.json',
      () {
        final ctrl = UiScaleController(prefsFileOverride: testPrefsFile);
        var notifications = 0;
        ctrl.addListener(() => notifications++);

        ctrl.setMinimizeToTrayOnClose(false);
        expect(ctrl.minimizeToTrayOnClose, isFalse);
        expect(notifications, equals(1));
        expect(testPrefsFile.existsSync(), isTrue);

        final decoded =
            jsonDecode(testPrefsFile.readAsStringSync())
                as Map<String, dynamic>;
        expect(decoded['minimize_to_tray_on_close'], isFalse);

        // Redundant call does not notify again.
        ctrl.setMinimizeToTrayOnClose(false);
        expect(notifications, equals(1));

        ctrl.setMinimizeToTrayOnClose(true);
        expect(ctrl.minimizeToTrayOnClose, isTrue);
        expect(notifications, equals(2));
      },
    );

    test('JSON round-trip restores minimizeToTrayOnClose across instances', () async {
      final ctrl1 = UiScaleController(prefsFileOverride: testPrefsFile);
      ctrl1.setMinimizeToTrayOnClose(false);

      final ctrl2 = UiScaleController(prefsFileOverride: testPrefsFile);
      await ctrl2.load();
      expect(ctrl2.minimizeToTrayOnClose, isFalse);

      ctrl2.setMinimizeToTrayOnClose(true);
      final ctrl3 = UiScaleController(prefsFileOverride: testPrefsFile);
      await ctrl3.load();
      expect(ctrl3.minimizeToTrayOnClose, isTrue);
    });

    test('supports camelCase fallback minimizeToTrayOnClose and invalid JSON defaults to true', () async {
      testPrefsFile.parent.createSync(recursive: true);
      testPrefsFile.writeAsStringSync(
        jsonEncode({'scale': 1.0, 'minimizeToTrayOnClose': false}),
      );

      final ctrlCamel = UiScaleController(prefsFileOverride: testPrefsFile);
      await ctrlCamel.load();
      expect(ctrlCamel.minimizeToTrayOnClose, isFalse);

      testPrefsFile.writeAsStringSync(
        jsonEncode({'scale': 1.0, 'minimize_to_tray_on_close': 'bad'}),
      );
      final ctrlInvalid = UiScaleController(prefsFileOverride: testPrefsFile);
      await ctrlInvalid.load();
      expect(ctrlInvalid.minimizeToTrayOnClose, isTrue);
    });
  });

  group('GeneralSettingsPanel - Minimize to Tray Switch', () {
    late Directory tempDir;
    late File testPrefsFile;
    late MockAudioService audioService;
    late UiScaleController scaleController;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('tray_panel_test_');
      testPrefsFile = File(
        '${tempDir.path}${Platform.pathSeparator}ui_prefs.json',
      );
      audioService = MockAudioService();
      scaleController = UiScaleController(prefsFileOverride: testPrefsFile);
    });

    tearDown(() {
      audioService.dispose();
      scaleController.dispose();
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    testWidgets(
      'renders switch with exact title and subtitle and toggles controller',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: GeneralSettingsPanel(
                audioService: audioService,
                scaleController: scaleController,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final switchRowFinder = find.byKey(
          const Key('switch_minimize_to_tray_on_close'),
        );
        expect(switchRowFinder, findsOneWidget);
        expect(
          find.text('關閉視窗時縮小至系統匣並繼續背景播放'),
          findsOneWidget,
        );
        expect(
          find.text(
            '開啟後，點擊右上角關閉按鈕將隱藏視窗並保持音樂播放，可從右下角系統匣還原或完全結束程式',
          ),
          findsOneWidget,
        );
        expect(scaleController.minimizeToTrayOnClose, isTrue);

        await tester.ensureVisible(switchRowFinder);
        await tester.tap(switchRowFinder);
        await tester.pumpAndSettle();

        expect(scaleController.minimizeToTrayOnClose, isFalse);

        final saved =
            jsonDecode(testPrefsFile.readAsStringSync())
                as Map<String, dynamic>;
        expect(saved['minimize_to_tray_on_close'], isFalse);

        await tester.tap(switchRowFinder);
        await tester.pumpAndSettle();
        expect(scaleController.minimizeToTrayOnClose, isTrue);
      },
    );
  });

  group('DesktopWindowController - Tray, Close Interception, URL, DPAPI', () {
    final List<MethodCall> calls = [];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('lumina/window'), (
            MethodCall call,
          ) async {
            calls.add(call);
            switch (call.method) {
              case 'dpapiProtect':
                return 'DPAPI:${call.arguments}';
              case 'dpapiUnprotect':
                final arg = call.arguments as String;
                if (arg.startsWith('DPAPI:')) {
                  return arg.substring(6);
                }
                throw PlatformException(code: 'DPAPI_UNPROTECT_FAILED');
              case 'openUrl':
                return true;
              default:
                return null;
            }
          });
    });

    tearDown(() {
      DesktopWindowController.instance = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('lumina/window'), null);
    });

    test(
      'invokes setPreventClose, hide, show, focus, destroy, and tray methods',
      () async {
        final controller = DesktopWindowController(isSupportedOverride: true);

        await controller.setPreventClose(true);
        expect(calls.last.method, equals('setPreventClose'));
        expect(calls.last.arguments, isTrue);

        expect(controller.isHiddenToTrayNotifier.value, isFalse);
        await controller.hide();
        expect(controller.isHiddenToTrayNotifier.value, isTrue);
        expect(calls.last.method, equals('hide'));

        await controller.show();
        expect(controller.isHiddenToTrayNotifier.value, isFalse);
        expect(controller.isMinimizedNotifier.value, isFalse);
        expect(calls.last.method, equals('show'));

        controller.isMinimizedNotifier.value = true;
        await controller.focus();
        expect(controller.isMinimizedNotifier.value, isFalse);
        expect(calls.last.method, equals('focus'));

        await controller.initTray(
          tooltip: 'Lumina Audio — Pink Floyd',
          nowPlayingLabel: 'Pink Floyd — Time',
          isPlaying: true,
        );
        expect(calls.last.method, equals('trayInit'));
        expect(calls.last.arguments, {
          'tooltip': 'Lumina Audio — Pink Floyd',
          'nowPlayingLabel': 'Pink Floyd — Time',
          'isPlaying': true,
        });

        await controller.updateTray(
          nowPlayingLabel: 'Pink Floyd — Money',
          isPlaying: false,
        );
        expect(calls.last.method, equals('trayUpdate'));
        expect(calls.last.arguments, {
          'nowPlayingLabel': 'Pink Floyd — Money',
          'isPlaying': false,
        });

        await controller.destroyTray();
        expect(calls.last.method, equals('trayDestroy'));

        await controller.hide();
        expect(controller.isHiddenToTrayNotifier.value, isTrue);
        await controller.destroy();
        expect(controller.isHiddenToTrayNotifier.value, isFalse);
        expect(calls.last.method, equals('destroy'));
      },
    );

    test('dpapiProtect and dpapiUnprotect round-trip and handle errors', () async {
      final controller = DesktopWindowController(isSupportedOverride: true);

      final encrypted = await controller.dpapiProtect('super_secret_token');
      expect(encrypted, equals('DPAPI:super_secret_token'));
      expect(calls.last.method, equals('dpapiProtect'));

      final decrypted = await controller.dpapiUnprotect(encrypted!);
      expect(decrypted, equals('super_secret_token'));
      expect(calls.last.method, equals('dpapiUnprotect'));

      final invalidResult = await controller.dpapiUnprotect('corrupted');
      expect(invalidResult, isNull);
    });

    test('openUrl allows http/https and blocks non-http/https schemes', () async {
      final controller = DesktopWindowController(isSupportedOverride: true);

      expect(await controller.openUrl('https://tidal.com/oauth'), isTrue);
      expect(calls.last.method, equals('openUrl'));
      expect(calls.last.arguments, equals('https://tidal.com/oauth'));

      expect(await controller.openUrl('http://127.0.0.1:9888/cb'), isTrue);
      expect(calls.last.method, equals('openUrl'));

      final countBefore = calls.length;
      expect(await controller.openUrl('file:///C:/Windows/win.ini'), isFalse);
      expect(await controller.openUrl('javascript:alert(1)'), isFalse);
      expect(await controller.openUrl('ms-settings:sound'), isFalse);
      expect(await controller.openUrl('not_a_url'), isFalse);
      expect(calls.length, equals(countBefore));
    });

    test('dispatches incoming native callbacks onWindowClose, onTrayClick, onTrayMenuAction', () async {
      final controller = DesktopWindowController(isSupportedOverride: true);

      var closeCount = 0;
      var trayClickCount = 0;
      final actions = <String>[];

      controller.onWindowClose = () => closeCount++;
      controller.onTrayClick = () => trayClickCount++;
      controller.onTrayMenuAction = actions.add;

      // Direct handleIncomingCall coverage.
      await controller.handleIncomingCall(const MethodCall('onWindowClose'));
      await controller.handleIncomingCall(const MethodCall('onTrayClick'));
      await controller.handleIncomingCall(
        const MethodCall('onTrayMenuAction', 'show'),
      );
      await controller.handleIncomingCall(
        const MethodCall('onTrayMenuAction', 'toggle_play_pause'),
      );

      expect(closeCount, equals(1));
      expect(trayClickCount, equals(1));
      expect(actions, equals(['show', 'toggle_play_pause']));

      // Platform message envelope coverage via real MethodChannel handler.
      Future<void> sendNative(String method, [dynamic args]) async {
        final data = const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, args),
        );
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage('lumina/window', data, (ByteData? _) {});
      }

      await sendNative('onWindowClose');
      await sendNative('onTrayClick');
      await sendNative('onTrayMenuAction', 'previous');
      await sendNative('onTrayMenuAction', 'next');
      await sendNative('onTrayMenuAction', 'quit');

      expect(closeCount, equals(2));
      expect(trayClickCount, equals(2));
      expect(
        actions,
        equals(['show', 'toggle_play_pause', 'previous', 'next', 'quit']),
      );
    });
  });
}
