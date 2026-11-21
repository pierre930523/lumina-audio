import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';

void main() {
  group('UiScaleController - Visualizer Setting Persistence', () {
    late Directory tempDir;
    late File testPrefsFile;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('ui_scale_ctrl_test_');
      testPrefsFile = File('${tempDir.path}${Platform.pathSeparator}ui_prefs.json');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('default value of enableAudioVisualizer is true', () {
      final ctrl = UiScaleController(prefsFileOverride: testPrefsFile);
      expect(ctrl.enableAudioVisualizer, isTrue);
    });

    test('setEnableAudioVisualizer to false notifies listeners and writes to disk', () async {
      final ctrl = UiScaleController(prefsFileOverride: testPrefsFile);
      var notificationCount = 0;
      ctrl.addListener(() {
        notificationCount++;
      });

      ctrl.setEnableAudioVisualizer(false);

      expect(ctrl.enableAudioVisualizer, isFalse);
      expect(notificationCount, equals(1));
      expect(testPrefsFile.existsSync(), isTrue);

      final content = testPrefsFile.readAsStringSync();
      expect(content, contains('"enableAudioVisualizer":false'));
    });

    test('redundant toggle does not notify listeners and does not rewrite', () async {
      final ctrl = UiScaleController(prefsFileOverride: testPrefsFile);
      ctrl.setEnableAudioVisualizer(true); // already true by default

      var notificationCount = 0;
      ctrl.addListener(() {
        notificationCount++;
      });

      ctrl.setEnableAudioVisualizer(true);
      expect(notificationCount, equals(0));

      ctrl.setEnableAudioVisualizer(false);
      expect(notificationCount, equals(1));

      // Redundant set to false
      ctrl.setEnableAudioVisualizer(false);
      expect(notificationCount, equals(1));
    });

    test('JSON deserialization restores state across new controller instance', () async {
      final ctrl1 = UiScaleController(prefsFileOverride: testPrefsFile);
      ctrl1.setEnableAudioVisualizer(false);
      expect(ctrl1.enableAudioVisualizer, isFalse);

      final ctrl2 = UiScaleController(prefsFileOverride: testPrefsFile);
      await ctrl2.load();
      expect(ctrl2.enableAudioVisualizer, isFalse);
    });

    test('supports snake_case fallback enable_audio_visualizer', () async {
      testPrefsFile.parent.createSync(recursive: true);
      testPrefsFile.writeAsStringSync(jsonEncode({
        'scale': 1.0,
        'restore_on_startup': true,
        'enable_audio_visualizer': false,
      }));

      final ctrl = UiScaleController(prefsFileOverride: testPrefsFile);
      await ctrl.load();
      expect(ctrl.enableAudioVisualizer, isFalse);
    });

    test('corrupted or invalid JSON values gracefully default to true', () async {
      testPrefsFile.parent.createSync(recursive: true);
      testPrefsFile.writeAsStringSync(jsonEncode({
        'scale': 1.0,
        'enableAudioVisualizer': 'invalid_string',
      }));

      final ctrlString = UiScaleController(prefsFileOverride: testPrefsFile);
      await ctrlString.load();
      expect(ctrlString.enableAudioVisualizer, isTrue);

      testPrefsFile.writeAsStringSync(jsonEncode({
        'scale': 1.0,
        'enableAudioVisualizer': 42,
      }));

      final ctrlNumber = UiScaleController(prefsFileOverride: testPrefsFile);
      await ctrlNumber.load();
      expect(ctrlNumber.enableAudioVisualizer, isTrue);

      testPrefsFile.writeAsStringSync('{ malformed json file');
      final ctrlCorrupt = UiScaleController(prefsFileOverride: testPrefsFile);
      await ctrlCorrupt.load();
      expect(ctrlCorrupt.enableAudioVisualizer, isTrue);
    });

    test('when prefsFileOverride is null and in test mode, load and save are no-op', () async {
      final ctrl = UiScaleController(); // no override, in FLUTTER_TEST
      expect(ctrl.enableAudioVisualizer, isTrue);
      ctrl.setEnableAudioVisualizer(false);
      expect(ctrl.enableAudioVisualizer, isFalse);
      // Calling load should not crash or access disk
      await ctrl.load();
      expect(ctrl.enableAudioVisualizer, isFalse);
    });
  });
}
