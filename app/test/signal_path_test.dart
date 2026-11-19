import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/signal_path.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/signal_path/quality_badge.dart';
import 'package:lumina_app/ui/signal_path/signal_path_modal.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('QualityBadge maps Lossless/Enhanced/HighQuality to distinct colors', () {
    expect(
      QualityBadge.colorForQuality(SignalQuality.lossless),
      const Color(0xFFA855F7), // Purple
    );
    expect(
      QualityBadge.colorForQuality(SignalQuality.enhanced),
      const Color(0xFF10B981), // Green
    );
    expect(
      QualityBadge.colorForQuality(SignalQuality.highQuality),
      const Color(0xFFF59E0B), // Yellow
    );
  });

  testWidgets('SignalPathModal toggles One-Click DSP Bypass from Enhanced to Lossless', (
    WidgetTester tester,
  ) async {
    final service = MockAudioService(startBypassed: false);
    addTearDown(service.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SignalPathModal(audioService: service),
          ),
        ),
      ),
    );

    expect(service.currentSignalPath.overallQuality, SignalQuality.enhanced);
    expect(find.text('已啟用 64 位元浮點 DSP 處理'), findsOneWidget);

    // Toggle One-Click DSP Bypass switch
    await tester.tap(find.byKey(const Key('dsp_bypass_switch')));
    await tester.pumpAndSettle();

    expect(service.currentSignalPath.overallQuality, SignalQuality.lossless);
    expect(find.text('位元精準無損音訊串流'), findsOneWidget);

    // Verify HighQuality tier simulation
    service.setSimulatedQuality(SignalQuality.highQuality);
    await tester.pumpAndSettle();
    expect(find.text('經由系統混音或有損轉換輸出'), findsOneWidget);
  });
}
