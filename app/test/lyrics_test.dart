import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/lyric.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/now_playing_view_controller.dart';
import 'package:lumina_app/ui/lyrics/lyrics_view.dart';
import 'package:lumina_app/ui/lyrics/word_by_word_text.dart';
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

  testWidgets('WordByWordText scales font size according to fontScale', (
    WidgetTester tester,
  ) async {
    final line = LyricLine(
      start: Duration.zero,
      end: const Duration(seconds: 10),
      text: 'Synchronized lyric line',
      words: [
        LyricWord(
          text: 'Synchronized ',
          start: Duration.zero,
          end: const Duration(seconds: 5),
        ),
        LyricWord(
          text: 'lyric line',
          start: const Duration(seconds: 5),
          end: const Duration(seconds: 10),
        ),
      ],
    );

    // Active line at 1.5x fontScale
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WordByWordText(
            line: line,
            currentPosition: const Duration(seconds: 2),
            isActiveLine: true,
            fontScale: 1.5,
          ),
        ),
      ),
    );

    final richText = tester.widget<RichText>(find.byType(RichText));
    final span = richText.text as TextSpan;
    expect(span.children, isNotNull);
    final firstWord = span.children!.first as TextSpan;
    expect(firstWord.style?.fontSize, 28.0 * 1.5);

    // Inactive line at 1.2x fontScale
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WordByWordText(
            line: line,
            currentPosition: const Duration(seconds: 2),
            isActiveLine: false,
            fontScale: 1.2,
          ),
        ),
      ),
    );

    final text = tester.widget<Text>(find.byType(Text));
    expect(text.style?.fontSize, closeTo(21.0 * 1.2, 0.01));
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

  testWidgets('LyricsView uses AnimatedOpacity and AnimatedDefaultTextStyle for smooth focus', (
    WidgetTester tester,
  ) async {
    final service = MockAudioService();
    addTearDown(service.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LyricsView(
            lyrics: service.currentLyrics,
            currentPosition: const Duration(seconds: 2),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AnimatedOpacity), findsWidgets);
    expect(find.byType(AnimatedDefaultTextStyle), findsWidgets);
  });

  testWidgets('LyricsView dynamic padding is exactly 50% viewport height and centers active line at 600h', (
    WidgetTester tester,
  ) async {
    final service = MockAudioService();
    addTearDown(service.dispose);

    const viewportH = 600.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: viewportH,
            child: LyricsView(
              lyrics: service.currentLyrics,
              currentPosition: const Duration(seconds: 13), // Line 2 is active
              isPlaying: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final listView = tester.widget<ListView>(find.byType(ListView));
    final padding = listView.padding as EdgeInsets?;
    expect(padding, isNotNull);
    expect(padding!.top, viewportH * 0.5);
    expect(padding.bottom, viewportH * 0.5);

    // Active line (line 2) center should align with viewport vertical center (300.0) within ±1.0px
    final lineCenter = tester.getCenter(find.byKey(const Key('lyric_line_2')));
    expect(lineCenter.dy, closeTo(viewportH * 0.5, 1.0));
  });

  testWidgets('LyricsView centers active line at 50% viewport height at 700h', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 700);
    addTearDown(tester.view.reset);

    final service = MockAudioService();
    addTearDown(service.dispose);

    const viewportH = 700.0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: viewportH,
            child: LyricsView(
              lyrics: service.currentLyrics,
              currentPosition: const Duration(seconds: 13),
              isPlaying: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final lineCenter = tester.getCenter(find.byKey(const Key('lyric_line_2')));
    expect(lineCenter.dy, closeTo(viewportH * 0.5, 1.0));
  });

  testWidgets('LyricsView active line center aligns with 50% viewport height under 150% scaling', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1.5;
    tester.view.physicalSize = const Size(1200, 900); // logical 800 x 600
    addTearDown(tester.view.reset);

    final service = MockAudioService();
    addTearDown(service.dispose);

    const viewportH = 600.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: viewportH,
            child: LyricsView(
              lyrics: service.currentLyrics,
              currentPosition: const Duration(seconds: 13),
              isPlaying: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final lineCenter = tester.getCenter(find.byKey(const Key('lyric_line_2')));
    expect(lineCenter.dy, closeTo(viewportH * 0.5, 1.0));
  });

  testWidgets('LyricsView centers Line 0 on initial load at track start within ±1.0px', (
    WidgetTester tester,
  ) async {
    final service = MockAudioService();
    addTearDown(service.dispose);

    const viewportH = 600.0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: viewportH,
            child: LyricsView(
              lyrics: service.currentLyrics,
              currentPosition: Duration.zero, // Line 0 active from start
              isPlaying: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final lineCenter = tester.getCenter(find.byKey(const Key('lyric_line_0')));
    expect(lineCenter.dy, closeTo(viewportH * 0.5, 1.0));
  });

  testWidgets('LyricsView sequential line playback across variable-length lines maintains ±1.0px centering under 150% scale', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1.5;
    tester.view.physicalSize = const Size(1200, 900); // logical 800 x 600
    addTearDown(tester.view.reset);

    const viewportH = 600.0;
    final variableLyrics = <LyricLine>[
      LyricLine(
        start: const Duration(seconds: 0),
        end: const Duration(seconds: 5),
        text: 'Opening phrase of the song',
      ),
      LyricLine(
        start: const Duration(seconds: 5),
        end: const Duration(seconds: 10),
        text: 'Short line',
      ),
      LyricLine(
        start: const Duration(seconds: 10),
        end: const Duration(seconds: 15),
        text: 'This is an exceptionally long multi-line verse that wraps across several visual lines in the lyrics viewport to verify that height expansion and collapse does not drift the scroll target',
      ),
      LyricLine(
        start: const Duration(seconds: 15),
        end: const Duration(seconds: 20),
        text: 'Synchronized word by word',
        words: [
          LyricWord(text: 'Synchronized ', start: const Duration(seconds: 15), end: const Duration(seconds: 17)),
          LyricWord(text: 'word ', start: const Duration(seconds: 17), end: const Duration(seconds: 18)),
          LyricWord(text: 'by ', start: const Duration(seconds: 18), end: const Duration(seconds: 19)),
          LyricWord(text: 'word', start: const Duration(seconds: 19), end: const Duration(seconds: 20)),
        ],
      ),
      LyricLine(
        start: const Duration(seconds: 20),
        end: const Duration(seconds: 25),
        text: 'Another very lengthy narrative passage with substantial text that produces a large render box height and shifts preceding vertical offsets significantly upon settling',
      ),
      LyricLine(
        start: const Duration(seconds: 25),
        end: const Duration(seconds: 30),
        text: 'Simple chorus line',
      ),
      LyricLine(
        start: const Duration(seconds: 30),
        end: const Duration(seconds: 35),
        text: 'Final closing line of the track',
      ),
    ];

    // Sequentially play through lines 0 to 6
    for (int i = 0; i < variableLyrics.length; i++) {
      final line = variableLyrics[i];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: viewportH,
              child: LyricsView(
                lyrics: variableLyrics,
                currentPosition: line.start + const Duration(milliseconds: 100),
                isPlaying: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final lineCenter = tester.getCenter(find.byKey(Key('lyric_line_$i')));
      expect(
        lineCenter.dy,
        closeTo(viewportH * 0.5, 1.0),
        reason: 'Line $i center (${lineCenter.dy}) deviated by > 1.0px from ${viewportH * 0.5}',
      );
    }
  });

  testWidgets('LyricsView dynamic font scale change preserves active line centering within ±1.0px', (
    WidgetTester tester,
  ) async {
    const viewportH = 600.0;
    final vc = NowPlayingViewController();
    addTearDown(vc.dispose);

    final variableLyrics = <LyricLine>[
      LyricLine(
        start: const Duration(seconds: 0),
        end: const Duration(seconds: 5),
        text: 'First line before multi-line verse',
      ),
      LyricLine(
        start: const Duration(seconds: 5),
        end: const Duration(seconds: 10),
        text: 'An expansive and long verse that wraps around multiple lines causing significant height changes when font scale is dynamically adjusted',
      ),
      LyricLine(
        start: const Duration(seconds: 10),
        end: const Duration(seconds: 15),
        text: 'Word by word line for font scaling test',
        words: [
          LyricWord(text: 'Word ', start: const Duration(seconds: 10), end: const Duration(seconds: 12)),
          LyricWord(text: 'by ', start: const Duration(seconds: 12), end: const Duration(seconds: 13)),
          LyricWord(text: 'word ', start: const Duration(seconds: 13), end: const Duration(seconds: 14)),
          LyricWord(text: 'line', start: const Duration(seconds: 14), end: const Duration(seconds: 15)),
        ],
      ),
      LyricLine(
        start: const Duration(seconds: 15),
        end: const Duration(seconds: 20),
        text: 'Closing line after active target',
      ),
    ];

    // Mount with line 2 active at 1.0 font scale
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: viewportH,
            child: LyricsView(
              lyrics: variableLyrics,
              currentPosition: const Duration(seconds: 11), // Line 2 active
              isPlaying: true,
              viewController: vc,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    var lineCenter = tester.getCenter(find.byKey(const Key('lyric_line_2')));
    expect(lineCenter.dy, closeTo(viewportH * 0.5, 1.0));

    // Scale font down to 0.7x
    vc.setLyricsFontScale(0.7);
    await tester.pumpAndSettle();

    lineCenter = tester.getCenter(find.byKey(const Key('lyric_line_2')));
    expect(lineCenter.dy, closeTo(viewportH * 0.5, 1.0));

    // Scale font up to 1.5x
    vc.setLyricsFontScale(1.5);
    await tester.pumpAndSettle();

    lineCenter = tester.getCenter(find.byKey(const Key('lyric_line_2')));
    expect(lineCenter.dy, closeTo(viewportH * 0.5, 1.0));
  });
}
