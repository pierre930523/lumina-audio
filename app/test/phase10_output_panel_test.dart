import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_output_info.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/mini_player/volume_control.dart';
import 'package:lumina_app/ui/signal_path/signal_path_modal.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'Phase 10 SignalPathModal displays telemetry, Strict Mode locks SW volume and restores normal mode',
    (WidgetTester tester) async {
      final service = MockAudioService(startBypassed: false);
      addTearDown(service.dispose);

      await service.setVolume(0.45);
      expect(service.currentState.volume, closeTo(0.45, 0.001));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SignalPathModal(audioService: service),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('phase10_output_info_panel')), findsOneWidget);
      expect(find.text('SOURCE'), findsOneWidget);
      expect(find.text('DECODER'), findsOneWidget);
      expect(find.text('OUTPUT'), findsOneWidget);
      expect(find.text('VERIFICATION'), findsOneWidget);

      // Must never claim BIT-PERFECT without verified native hardware hashes
      expect(find.text('NOT VERIFIED'), findsWidgets);
      expect(find.text('BIT-PERFECT'), findsNothing);

      // Enable Strict Bit-Perfect Mode -> locks SW volume to 1.0x and hard-bypasses DSP
      final strictFinder = find.byKey(const Key('strict_bit_perfect_switch'));
      await tester.ensureVisible(strictFinder);
      await tester.tap(strictFinder);
      await tester.pumpAndSettle();

      expect(service.isStrictBitPerfect, isTrue);
      expect(service.currentState.volume, closeTo(1.0, 0.001));
      expect(service.currentSignalPath.dspBypassed, isTrue);

      // Trying to attenuate SW volume while Strict Mode is active keeps live gain at 1.0
      await service.setVolume(0.25);
      expect(service.currentState.volume, closeTo(1.0, 0.001));

      // Switch DSD mode to DoP
      final dopChip = find.byKey(const Key('dsd_mode_dop'));
      await tester.ensureVisible(dopChip);
      await tester.tap(dopChip);
      await tester.pumpAndSettle();
      expect(service.dsdOutputMode, DsdOutputModeOption.dop);

      // Turn Strict Mode off -> restores saved volume 0.25
      await tester.ensureVisible(strictFinder);
      await tester.tap(strictFinder);
      await tester.pumpAndSettle();

      expect(service.isStrictBitPerfect, isFalse);
      expect(service.currentState.volume, closeTo(0.25, 0.001));
    },
  );

  testWidgets('VolumeControl disables mute and slider when lockedUnity is true', (
    WidgetTester tester,
  ) async {
    var mutedTapped = false;
    double? sliderMovedTo;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VolumeControl(
            volume: 0.6,
            isMuted: false,
            lockedUnity: true,
            onVolumeChanged: (v) => sliderMovedTo = v,
            onToggleMute: () => mutedTapped = true,
          ),
        ),
      ),
    );

    final muteBtn = tester.widget<IconButton>(find.byKey(const Key('btn_mute')));
    final slider = tester.widget<Slider>(find.byKey(const Key('volume_slider')));
    expect(muteBtn.onPressed, isNull);
    expect(slider.onChanged, isNull);
    expect(slider.value, closeTo(1.0, 0.001));
    expect(mutedTapped, isFalse);
    expect(sliderMovedTo, isNull);
  });
}
