import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/main.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/mini_player/floating_capsule.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('FloatingCapsuleMiniPlayer controls playback, volume, and modal', (
    WidgetTester tester,
  ) async {
    final service = MockAudioService();
    addTearDown(service.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: FloatingCapsuleMiniPlayer(
              audioService: service,
              showLyrics: true,
              onToggleLyrics: () {},
            ),
          ),
        ),
      ),
    );

    expect(service.currentState.status, PlaybackStatus.paused);

    // Tap Play/Pause
    await tester.tap(find.byKey(const Key('btn_play_pause')));
    await tester.pump();
    expect(service.currentState.status, PlaybackStatus.playing);

    // Tap Next Track
    await tester.tap(find.byKey(const Key('btn_next')));
    await tester.pump();
    expect(service.currentState.track?.title, 'Money');

    // Tap Mute
    await tester.tap(find.byKey(const Key('btn_mute')));
    await tester.pump();
    expect(service.currentState.isMuted, isTrue);

    // Tap Quality Badge opens AudioInfoPopover, and action opens SignalPathModal
    await tester.tap(find.byKey(const Key('quality_badge_button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio_info_popover')), findsOneWidget);
    expect(find.text('等級'), findsOneWidget);
    expect(find.text('格式'), findsOneWidget);
    expect(find.text('取樣規格'), findsOneWidget);
    expect(find.text('即時串流率'), findsOneWidget);
    expect(find.text('當前輸出裝置'), findsOneWidget);

    await tester.tap(find.byKey(const Key('btn_open_signal_path_from_popover')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audio_info_popover')), findsNothing);
    expect(find.text('音訊訊號路徑'), findsOneWidget);
    expect(find.text('一鍵旁通 DSP（直出模式）'), findsOneWidget);
  });

  for (final size in [const Size(860, 700), const Size(1280, 800)]) {
    testWidgets(
      'Wide capsule at ${size.width.toInt()}x${size.height.toInt()} keeps single row without wrap',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = size;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final service = MockAudioService();
        addTearDown(service.dispose);
        await service.play(track: service.queue[2]); // "Comfortably Numb"

        await tester.pumpWidget(LuminaApp(audioService: service));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('capsule_track_title')), findsOneWidget);

        final titleCenter =
            tester.getCenter(find.byKey(const Key('capsule_track_title')));
        final playCenter =
            tester.getCenter(find.byKey(const Key('btn_play_pause')));
        final lyricsCenter =
            tester.getCenter(find.byKey(const Key('btn_toggle_lyrics')));

        expect((playCenter.dy - lyricsCenter.dy).abs(), lessThan(12.0));
        expect((titleCenter.dy - lyricsCenter.dy).abs(), lessThan(20.0));
      },
    );
  }

  for (final size in [const Size(600, 700), const Size(360, 700)]) {
    testWidgets(
      'Responsive LuminaApp renders cleanly with zero overflow at ${size.width.toInt()}x${size.height.toInt()}',
      (WidgetTester tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = size;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final service = MockAudioService();
        addTearDown(service.dispose);
        await service.play(track: service.queue[2]); // "Comfortably Numb"

        await tester.pumpWidget(LuminaApp(audioService: service));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // Switch to library browser and ensure toolbar is responsive too
        await tester.ensureVisible(find.byKey(const Key('capsule_nav_library')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('capsule_nav_library')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('track_queue_list')), findsOneWidget);

        // Toggle playback interactively
        await tester.tap(find.byKey(const Key('btn_play_pause')));
        await tester.pump();
        expect(service.currentState.status, PlaybackStatus.paused);
      },
    );
  }
}
