import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/lyrics/lyrics_view.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('LyricsView calculates DoF blur and opacity by line distance', () {
    expect(LyricsView.blurSigmaForDistance(0), 0.0);
    expect(LyricsView.blurSigmaForDistance(1), 1.5);
    expect(LyricsView.blurSigmaForDistance(2), 3.5);
    expect(LyricsView.blurSigmaForDistance(3), 5.0);

    expect(LyricsView.opacityForDistance(0), 1.0);
    expect(LyricsView.opacityForDistance(1), 0.65);
    expect(LyricsView.opacityForDistance(2), 0.35);
    expect(LyricsView.opacityForDistance(4), 0.18);
  });

  testWidgets('LyricsView renders lines and supports tap-to-seek', (
    WidgetTester tester,
  ) async {
    final service = MockAudioService();
    addTearDown(service.dispose);
    Duration? seekedTo;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LyricsView(
            lyrics: service.currentLyrics,
            currentPosition: const Duration(seconds: 2),
            onSeek: (pos) => seekedTo = pos,
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('lyric_line_0')), findsOneWidget);
    expect(find.byKey(const Key('lyric_line_1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('lyric_line_2')));
    await tester.pump();
    expect(seekedTo, const Duration(seconds: 12));
  });
}
