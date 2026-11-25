import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/main.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/signal_path.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/ui/artwork/album_artwork_view.dart';
import 'package:lumina_app/ui/common/audio_quality_badge.dart';
import 'package:lumina_app/ui/mini_player/playback_controls.dart';
import 'package:lumina_app/ui/mini_player/progress_bar.dart';
import 'package:lumina_app/ui/now_playing/now_playing_overlay.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('AudioFormat formats unified PCM label matching FLAC 44.1 kHz / 16-bit', () {
    const fmt = AudioFormat(
      codec: AudioCodec.flac,
      sampleRateHz: 44100,
      bitDepth: 16,
      channels: 2,
    );
    expect(fmt.label, 'FLAC 44.1 kHz / 16-bit');
  });

  for (final scale in [1.0, 1.5]) {
    for (final windowSize in [const Size(1280, 800), const Size(1920, 1080)]) {
      testWidgets(
        'Bottom bar Play/Pause centered, single QualityBadge, and NowPlaying Cover/Split unclipped at ${(scale * 100).round()}% (${windowSize.width.toInt()}x${windowSize.height.toInt()})',
        (WidgetTester tester) async {
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = windowSize;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });

          final service = MockAudioService();
          service.setSimulatedQuality(SignalQuality.highQuality);
          final scaleController = UiScaleController()..setScale(scale);
          addTearDown(() {
            service.dispose();
            scaleController.dispose();
          });

          await tester.pumpWidget(
            LuminaApp(
              audioService: service,
              uiScaleController: scaleController,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          // 1. Collapsed Home view: single Gold Hi-Res QualityBadge inside PlaybackControls.
          expect(find.byType(AudioQualityBadge), findsOneWidget);
          expect(find.text('Hi-Res'), findsOneWidget);
          expect(
            find.descendant(
              of: find.byType(PlaybackControls),
              matching: find.byType(AudioQualityBadge),
            ),
            findsOneWidget,
          );

          // 2. Play/Pause button aligns dead-center horizontally with bottom bar and linear progress bar.
          final capsuleRect =
              tester.getRect(find.byKey(const Key('liquid_glass_capsule')));
          final playCenter =
              tester.getCenter(find.byKey(const Key('btn_play_pause')));
          final progressCenter =
              tester.getCenter(find.byType(TrackProgressBar));
          final sliderCenter =
              tester.getCenter(find.byKey(const Key('track_progress_slider')));
          expect(
            (playCenter.dx - capsuleRect.center.dx).abs(),
            lessThan(1.0),
          );
          expect(
            (playCenter.dx - progressCenter.dx).abs(),
            lessThan(1.0),
          );
          expect(
            (playCenter.dx - sliderCenter.dx).abs(),
            lessThan(5.0),
          );

          // 3. Expand Now Playing overlay (defaults to Focus View, then switch to Split mode).
          await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('btn_now_playing_mode_split')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byKey(const Key('now_playing_overlay')), findsOneWidget);

          // Split mode left cover pane has NO SingleChildScrollView or Scrollbar around cover.
          expect(
            find.descendant(
              of: find.byType(NowPlayingOverlay),
              matching: find.byType(SingleChildScrollView),
            ),
            findsNothing,
          );
          expect(
            find.descendant(
              of: find.byType(NowPlayingOverlay),
              matching: find.byType(Scrollbar),
            ),
            findsNothing,
          );

          // Still ONLY ONE QualityBadge on screen (shared inside bottom bar PlaybackControls, NO duplicate in NowPlayingOverlay).
          expect(find.byType(AudioQualityBadge), findsOneWidget);
          expect(find.text('Hi-Res'), findsOneWidget);
          expect(
            find.descendant(
              of: find.byKey(const Key('liquid_glass_capsule')),
              matching: find.byType(AudioQualityBadge),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: find.byType(NowPlayingOverlay),
              matching: find.byType(AudioQualityBadge),
            ),
            findsNothing,
          );

          // Play/Pause stays dead-center horizontally even while NowPlayingOverlay is expanded.
          final playCenterExpanded =
              tester.getCenter(find.byKey(const Key('btn_play_pause')));
          expect(
            (playCenterExpanded.dx - capsuleRect.center.dx).abs(),
            lessThan(1.0),
          );

          // Verify quality badge sits cleanly inside bottom bar without vertical clipping.
          final overlayRect =
              tester.getRect(find.byKey(const Key('now_playing_overlay')));
          final badgeRect =
              tester.getRect(find.byKey(const Key('quality_badge_button')));
          expect(badgeRect.top, greaterThanOrEqualTo(capsuleRect.top));
          expect(badgeRect.bottom, lessThanOrEqualTo(capsuleRect.bottom));

          // 4. Switch to pure Cover View mode: NO Scrollable/Scrollbar, centered cover, generous shadow margins.
          await tester.tap(find.byKey(const Key('btn_now_playing_mode_cover')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          // Zero Scrollable/Scrollbar widgets inside NowPlayingOverlay in Cover mode.
          expect(
            find.descendant(
              of: find.byType(NowPlayingOverlay),
              matching: find.byType(Scrollable),
            ),
            findsNothing,
          );
          expect(
            find.descendant(
              of: find.byType(NowPlayingOverlay),
              matching: find.byType(SingleChildScrollView),
            ),
            findsNothing,
          );
          expect(
            find.descendant(
              of: find.byType(NowPlayingOverlay),
              matching: find.byType(Scrollbar),
            ),
            findsNothing,
          );

          // Single QualityBadge & unclipped bounds in Cover mode.
          expect(find.byType(AudioQualityBadge), findsOneWidget);
          final coverBadgeRect =
              tester.getRect(find.byKey(const Key('quality_badge_button')));
          expect(coverBadgeRect.top, greaterThanOrEqualTo(capsuleRect.top));
          expect(coverBadgeRect.bottom, lessThanOrEqualTo(capsuleRect.bottom));

          // Cover card is horizontally centered and has outer padding > BoxShadow reach on all 4 edges.
          final coverFinder = find.descendant(
            of: find.byType(NowPlayingOverlay),
            matching: find.byType(AlbumArtworkView),
          );
          expect(coverFinder, findsOneWidget);
          final coverRect = tester.getRect(coverFinder);
          expect(
            (coverRect.center.dx - overlayRect.center.dx).abs(),
            lessThan(1.0),
          );
          // Shadow blurRadius(48) + spreadRadius(0) = 48; offsetY = 20 => top reach = 28, bottom reach = 68.
          expect(coverRect.left - overlayRect.left, greaterThan(48.0));
          expect(overlayRect.right - coverRect.right, greaterThan(48.0));
          expect(coverRect.top - overlayRect.top, greaterThan(28.0));
          expect(overlayRect.bottom - coverRect.bottom, greaterThan(68.0));
        },
      );
    }
  }

  testWidgets(
    'NowPlaying Cover view handles tight 800x600 at 150% scale without RenderFlex overflow or Scrollable',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(800, 600);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final service = MockAudioService();
      service.setSimulatedQuality(SignalQuality.highQuality);
      final scaleController = UiScaleController()..setScale(1.5);
      addTearDown(() {
        service.dispose();
        scaleController.dispose();
      });

      await tester.pumpWidget(
        LuminaApp(
          audioService: service,
          uiScaleController: scaleController,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_now_playing_mode_cover')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byType(NowPlayingOverlay),
          matching: find.byType(Scrollable),
        ),
        findsNothing,
      );
      expect(find.byType(AudioQualityBadge), findsOneWidget);
      final capsuleRect =
          tester.getRect(find.byKey(const Key('liquid_glass_capsule')));
      final badgeRect =
          tester.getRect(find.byKey(const Key('quality_badge_button')));
      expect(badgeRect.top, greaterThanOrEqualTo(capsuleRect.top));
      expect(badgeRect.bottom, lessThanOrEqualTo(capsuleRect.bottom));
    },
  );

  testWidgets(
    'Long metadata + distinct albumArtist renders unclipped pills and zero overflow at 150% scale in Split and Cover modes',
    (WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final service = MockAudioService();
      service.setSimulatedQuality(SignalQuality.highQuality);
      final baseTrack = service.queue.first;
      await service.play(
        track: baseTrack.copyWith(
          title:
              'Very Long Symphonic Track Title That Wraps Across Two Lines Cleanly',
          artist: 'Featured Ensemble & Orchestra Soloist',
          albumArtist: 'Original Soundtrack Various Artists Collection',
          album: 'Hazbin Hotel (Original Soundtrack Deluxe Edition)',
          format: const AudioFormat(
            codec: AudioCodec.flac,
            sampleRateHz: 44100,
            bitDepth: 16,
            channels: 2,
          ),
        ),
      );
      final scaleController = UiScaleController()..setScale(1.5);
      addTearDown(() {
        service.dispose();
        scaleController.dispose();
      });

      await tester.pumpWidget(
        LuminaApp(
          audioService: service,
          uiScaleController: scaleController,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('FLAC 44.1 kHz / 16-bit'), findsOneWidget);
      expect(find.byType(AudioQualityBadge), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn_now_playing_mode_cover')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('FLAC 44.1 kHz / 16-bit'), findsOneWidget);
      expect(find.byType(AudioQualityBadge), findsOneWidget);

      final overlayRect =
          tester.getRect(find.byKey(const Key('now_playing_overlay')));
      final capsuleRect =
          tester.getRect(find.byKey(const Key('liquid_glass_capsule')));
      final formatRect =
          tester.getRect(find.text('FLAC 44.1 kHz / 16-bit'));
      final badgeRect =
          tester.getRect(find.byKey(const Key('quality_badge_button')));
      expect(formatRect.bottom, lessThanOrEqualTo(overlayRect.bottom));
      expect(badgeRect.top, greaterThanOrEqualTo(capsuleRect.top));
      expect(badgeRect.bottom, lessThanOrEqualTo(capsuleRect.bottom));
    },
  );
}
