import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/audio_quality_tier.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/services/escape_dismiss_registry.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/now_playing_view_controller.dart';
import 'package:lumina_app/ui/common/audio_info_popover.dart';
import 'package:lumina_app/ui/common/audio_quality_badge.dart';
import 'package:lumina_app/ui/common/frosted_glass_container.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:lumina_app/ui/mini_player/floating_capsule.dart';
import 'package:lumina_app/ui/now_playing/now_playing_overlay.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

TrackInfo _track({
  required String id,
  required String title,
  required AudioFormat format,
  String providerName = 'Local',
  String? filePath,
}) {
  return TrackInfo(
    id: id,
    title: title,
    artist: 'Test Artist',
    album: 'Test Album',
    duration: const Duration(minutes: 4, seconds: 12),
    format: format,
    providerName: providerName,
    filePath: filePath,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    EscapeDismissRegistry.instance.clear();
  });

  group('AudioQualityBadge 4-tier visual specification', () {
    final tierExpectations =
        <(
          AudioQualityTier tier,
          String text,
          Color borderColor,
          Color textColor,
          Color bgColor,
          Color? shadowColor,
          double? shadowBlur,
        )>[
          (
            AudioQualityTier.hiRes,
            'Hi-Res',
            const Color.fromRGBO(229, 193, 88, 0.78),
            const Color(0xFFE5C158),
            const Color.fromRGBO(229, 193, 88, 0.08),
            const Color.fromRGBO(229, 193, 88, 0.22),
            10.0,
          ),
          (
            AudioQualityTier.lossless,
            'LOSSLESS',
            const Color.fromRGBO(255, 255, 255, 0.45),
            const Color(0xFFFFFFFF),
            const Color.fromRGBO(255, 255, 255, 0.10),
            const Color.fromRGBO(255, 255, 255, 0.15),
            8.0,
          ),
          (
            AudioQualityTier.hqLossy,
            'HQ',
            const Color.fromRGBO(255, 255, 255, 0.22),
            const Color.fromRGBO(255, 255, 255, 0.85),
            const Color.fromRGBO(255, 255, 255, 0.06),
            null,
            null,
          ),
          (
            AudioQualityTier.standard,
            'SD',
            const Color.fromRGBO(255, 255, 255, 0.12),
            const Color.fromRGBO(255, 255, 255, 0.50),
            Colors.transparent,
            null,
            null,
          ),
        ];

    for (final spec in tierExpectations) {
      testWidgets('renders exact visual tokens for ${spec.$1.code}', (
        WidgetTester tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              body: Center(
                child: AudioQualityBadge(
                  tier: spec.$1,
                  onTap: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text(spec.$2), findsOneWidget);

        final inkWell = tester.widget<InkWell>(
          find.byKey(const Key('quality_badge_button')),
        );
        expect(inkWell.mouseCursor, SystemMouseCursors.click);

        final container = tester.widget<AnimatedContainer>(
          find.descendant(
            of: find.byType(AudioQualityBadge),
            matching: find.byType(AnimatedContainer),
          ),
        );
        expect(container.duration, const Duration(milliseconds: 200));
        expect(container.curve, Curves.ease);
        expect(
          container.padding,
          const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
        );

        final decoration = container.decoration! as BoxDecoration;
        expect(decoration.color, spec.$5);
        expect(decoration.borderRadius, BorderRadius.circular(4));
        expect(decoration.border, Border.all(color: spec.$3, width: 1));
        if (spec.$6 != null) {
          expect(decoration.boxShadow, isNotNull);
          expect(decoration.boxShadow!.length, 1);
          expect(decoration.boxShadow!.first.color, spec.$6);
          expect(decoration.boxShadow!.first.blurRadius, spec.$7);
        } else {
          expect(decoration.boxShadow ?? const <BoxShadow>[], isEmpty);
        }

        final labelText = tester.widget<Text>(find.text(spec.$2));
        expect(labelText.style?.color, spec.$4);
        expect(labelText.style?.fontSize, 10);
        expect(labelText.style?.fontWeight, FontWeight.w600);
        expect(labelText.style?.height, 1.0);
        expect(labelText.style?.letterSpacing, 0.5);
      });
    }
  });

  group('Bottom Bar & Now Playing dynamic track switching', () {
    testWidgets(
      'FloatingCapsule places badge right of Repeat, vertically centered, and updates reactively across all 4 tiers',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = MockAudioService();
        addTearDown(service.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: FloatingCapsuleMiniPlayer(
                  audioService: service,
                  showLyrics: false,
                  onToggleLyrics: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Initial MockAudioService track is FLAC 24-bit/96 kHz -> Hi-Res
        expect(find.byType(AudioQualityBadge), findsOneWidget);
        expect(find.text('Hi-Res'), findsOneWidget);

        // Placement: directly to the right of Repeat button, vertically center-aligned.
        final repeatRect = tester.getRect(find.byKey(const Key('btn_repeat')));
        final badgeRect = tester.getRect(
          find.byKey(const Key('quality_badge_button')),
        );
        expect(badgeRect.left, greaterThanOrEqualTo(repeatRect.right));
        expect(badgeRect.left - repeatRect.right, lessThanOrEqualTo(16.0));
        expect((badgeRect.center.dy - repeatRect.center.dy).abs(), lessThan(2.0));

        // Switch to CD Lossless (FLAC 16/44.1) -> LOSSLESS
        await service.play(
          track: _track(
            id: 'trk-cd',
            title: 'CD Master',
            format: const AudioFormat(
              codec: AudioCodec.flac,
              sampleRateHz: 44100,
              bitDepth: 16,
              channels: 2,
              bitrateKbps: 940,
            ),
            filePath: '/music/cd_master.flac',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('LOSSLESS'), findsOneWidget);
        expect(find.text('Hi-Res'), findsNothing);

        // Switch to HQ Lossy (AAC 320 kbps) -> HQ
        await service.play(
          track: _track(
            id: 'trk-hq',
            title: 'AAC High',
            format: const AudioFormat(
              codec: AudioCodec.aac,
              sampleRateHz: 48000,
              bitDepth: 16,
              channels: 2,
              bitrateKbps: 320,
            ),
            providerName: 'Apple Music',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('HQ'), findsOneWidget);

        // Switch to Standard Lossy (Opus 160 kbps @ 48 kHz MUST be SD) -> SD
        await service.play(
          track: _track(
            id: 'trk-sd',
            title: 'Opus 160k',
            format: const AudioFormat(
              codec: AudioCodec.opus,
              sampleRateHz: 48000,
              bitDepth: 16,
              channels: 2,
              bitrateKbps: 160,
            ),
            providerName: 'YouTube Music',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('SD'), findsOneWidget);

        // Switch to DSD64 -> Hi-Res
        await service.play(
          track: _track(
            id: 'trk-dsd',
            title: 'DSD64 Master',
            format: const AudioFormat(
              codec: AudioCodec.dsf,
              sampleRateHz: 2822400,
              bitDepth: 1,
              channels: 2,
              isDsd: true,
            ),
            filePath: '/music/master.dsf',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Hi-Res'), findsOneWidget);
      },
    );

    testWidgets(
      'NowPlayingOverlay cover-underneath spec capsule and standalone badge stay synced with active tier',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = MockAudioService();
        final controller = NowPlayingViewController()
          ..setMode(NowPlayingViewMode.cover);
        addTearDown(() {
          service.dispose();
          controller.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              body: NowPlayingOverlay(
                audioService: service,
                controller: controller,
                onCollapse: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Standalone bottom controls place AudioQualityBadge right of Repeat, vertically centered.
        final repeatRect = tester.getRect(find.byKey(const Key('btn_repeat')));
        final badgeRect = tester.getRect(
          find.byKey(const Key('quality_badge_button')),
        );
        expect(badgeRect.left, greaterThanOrEqualTo(repeatRect.right));
        expect((badgeRect.center.dy - repeatRect.center.dy).abs(), lessThan(2.0));
        expect(find.text('Hi-Res'), findsOneWidget);

        BoxDecoration specDecoration() {
          final container = tester.widget<AnimatedContainer>(
            find.byKey(const Key('now_playing_format_spec_capsule')),
          );
          return container.decoration! as BoxDecoration;
        }

        Color? specDotColor() {
          final dot = tester.widget<AnimatedContainer>(
            find.byKey(const Key('now_playing_format_spec_dot')),
          );
          return (dot.decoration! as BoxDecoration).color;
        }

        // 1. Hi-Res FLAC 24/96
        expect(find.text('FLAC 96 kHz / 24-bit'), findsOneWidget);
        expect(
          specDecoration().border,
          Border.all(color: AudioQualityBadgeStyle.hiRes.borderColor, width: 1),
        );
        expect(specDotColor(), AudioQualityBadgeStyle.hiRes.textColor);

        // 2. Switch to CD Lossless (FLAC 16/44.1)
        await service.play(
          track: _track(
            id: 'np-cd',
            title: 'CD Album Track',
            format: const AudioFormat(
              codec: AudioCodec.flac,
              sampleRateHz: 44100,
              bitDepth: 16,
              channels: 2,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('LOSSLESS'), findsOneWidget);
        expect(find.text('FLAC 44.1 kHz / 16-bit'), findsOneWidget);
        expect(
          specDecoration().border,
          Border.all(
            color: AudioQualityBadgeStyle.lossless.borderColor,
            width: 1,
          ),
        );
        expect(specDotColor(), AudioQualityBadgeStyle.lossless.textColor);

        // 3. Switch to HQ Opus 48 kHz (no explicit bitrate -> YouTube Music HQ fallback)
        await service.play(
          track: _track(
            id: 'np-hq',
            title: 'Stream HQ',
            format: const AudioFormat(
              codec: AudioCodec.opus,
              sampleRateHz: 48000,
              bitDepth: 16,
              channels: 2,
            ),
            providerName: 'YouTube Music',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('HQ'), findsOneWidget);
        expect(find.text('Opus 48 kHz / 16-bit'), findsOneWidget);
        expect(
          specDecoration().border,
          Border.all(
            color: AudioQualityBadgeStyle.hqLossy.borderColor,
            width: 1,
          ),
        );
        expect(specDotColor(), AudioQualityBadgeStyle.hqLossy.textColor);

        // 4. Same format.label ("Opus 48 kHz / 16-bit") with explicit 160 kbps -> SD
        await service.play(
          track: _track(
            id: 'np-hq',
            title: 'Stream HQ',
            format: const AudioFormat(
              codec: AudioCodec.opus,
              sampleRateHz: 48000,
              bitDepth: 16,
              channels: 2,
              bitrateKbps: 160,
            ),
            providerName: 'YouTube Music',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('SD'), findsOneWidget);
        expect(find.text('Opus 48 kHz / 16-bit'), findsOneWidget);
        expect(
          specDecoration().border,
          Border.all(
            color: AudioQualityBadgeStyle.standard.borderColor,
            width: 1,
          ),
        );
        expect(specDotColor(), AudioQualityBadgeStyle.standard.textColor);
      },
    );
  });

  group('AudioInfoPopover overlay, technical fields & dismissal', () {
    testWidgets(
      'displays all 5 technical rows with exact frosted styling, dismisses on Esc and outside tap, and stays mutually exclusive with sibling popovers',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = MockAudioService();
        addTearDown(service.dispose);
        await service.play(
          track: _track(
            id: 'trk-hi',
            title: 'Hi-Res Reference',
            format: const AudioFormat(
              codec: AudioCodec.flac,
              sampleRateHz: 96000,
              bitDepth: 24,
              channels: 2,
              bitrateKbps: 2840,
            ),
            filePath: '/music/reference.flac',
          ),
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(audioService: service),
          ),
        );
        await tester.pumpAndSettle();

        // Open AudioInfoPopover from bottom bar quality badge.
        await tester.tap(find.byKey(const Key('quality_badge_button')));
        await tester.pumpAndSettle();

        final popoverFinder = find.byKey(const Key('audio_info_popover'));
        expect(popoverFinder, findsOneWidget);
        expect(find.byType(AudioInfoPopover), findsOneWidget);

        // Verify FrostedGlassContainer visual tokens (blur 20, bg, border, radius, padding).
        final glass = tester.widget<FrostedGlassContainer>(popoverFinder);
        expect(glass.blurSigma, 20.0);
        expect(glass.color, const Color.fromRGBO(20, 22, 28, 0.85));
        expect(glass.borderRadius, BorderRadius.circular(10));
        expect(
          glass.border,
          Border.all(
            color: const Color.fromRGBO(255, 255, 255, 0.12),
            width: 1,
          ),
        );
        expect(
          glass.padding,
          const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        );
        expect(
          find.descendant(
            of: popoverFinder,
            matching: find.byType(BackdropFilter),
          ),
          findsOneWidget,
        );

        // Verify all 5 required readout rows & formatted values.
        expect(find.text('等級'), findsOneWidget);
        expect(find.text('Hi-Res 高解析無損'), findsOneWidget);
        expect(find.text('格式'), findsOneWidget);
        expect(find.text('FLAC'), findsOneWidget);
        expect(find.text('取樣規格'), findsOneWidget);
        expect(find.text('24-bit / 96 kHz'), findsOneWidget);
        expect(find.text('即時串流率'), findsOneWidget);
        expect(find.text('2,840 kbps'), findsOneWidget);
        expect(find.text('當前輸出裝置'), findsOneWidget);
        expect(find.text('ASIO: FiiO K9 Pro USB ASIO'), findsOneWidget);

        // Verify popover fits cleanly inside viewport bounds.
        final popoverRect = tester.getRect(popoverFinder);
        expect(popoverRect.left, greaterThanOrEqualTo(0.0));
        expect(popoverRect.top, greaterThanOrEqualTo(0.0));
        expect(popoverRect.right, lessThanOrEqualTo(1280.0));
        expect(popoverRect.bottom, lessThanOrEqualTo(800.0));

        // Pressing Esc closes AudioInfoPopover.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(popoverFinder, findsNothing);

        // Re-open -> tapping outside dismisses AudioInfoPopover.
        await tester.tap(find.byKey(const Key('quality_badge_button')));
        await tester.pumpAndSettle();
        expect(popoverFinder, findsOneWidget);

        await tester.tapAt(const Offset(640, 160));
        await tester.pumpAndSettle();
        expect(popoverFinder, findsNothing);

        // Mutual exclusion with QuickOutputPopover:
        // Open QuickOutputPopover -> tapping badge dismisses output overlay; next tap opens AudioInfoPopover.
        await tester.tap(find.byKey(const Key('btn_quick_output_popover')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('quick_output_popover')), findsOneWidget);

        await tester.tap(
          find.byKey(const Key('quality_badge_button')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('quick_output_popover')), findsNothing);

        await tester.tap(find.byKey(const Key('quality_badge_button')));
        await tester.pumpAndSettle();
        expect(popoverFinder, findsOneWidget);

        // Click '檢視完整訊號路徑' -> closes popover and opens SignalPathModal.
        await tester.tap(
          find.byKey(const Key('btn_open_signal_path_from_popover')),
        );
        await tester.pumpAndSettle();
        expect(popoverFinder, findsNothing);
        expect(find.text('音訊訊號路徑'), findsOneWidget);

        // SignalPathModal closes via Esc.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('音訊訊號路徑'), findsNothing);
      },
    );

    testWidgets(
      'AudioInfoPopover clamps cleanly inside a tight 720x380 window without overflow',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(720, 380);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final service = MockAudioService();
        addTearDown(service.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: FloatingCapsuleMiniPlayer(
                  audioService: service,
                  showLyrics: false,
                  onToggleLyrics: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('quality_badge_button')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final popoverFinder = find.byKey(const Key('audio_info_popover'));
        expect(popoverFinder, findsOneWidget);
        final rect = tester.getRect(popoverFinder);
        expect(rect.left, greaterThanOrEqualTo(0.0));
        expect(rect.top, greaterThanOrEqualTo(0.0));
        expect(rect.right, lessThanOrEqualTo(720.0));
        expect(rect.bottom, lessThanOrEqualTo(380.0));
      },
    );
  });
}
