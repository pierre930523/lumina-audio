import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/main.dart';
import 'package:lumina_app/models/audio_quality_tier.dart';
import 'package:lumina_app/models/home_layout_preset.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/media_sources_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/ui/albums/album_collection_card.dart';
import 'package:lumina_app/ui/artwork/album_artwork_view.dart';
import 'package:lumina_app/ui/common/audio_info_popover.dart';
import 'package:lumina_app/ui/common/bottom_player_bar_scope.dart';
import 'package:lumina_app/ui/common/preference_toggle_button.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

class _MenuScaleTestAudioService extends MockAudioService {
  late final List<CanonicalAlbumSummary> _albums = [
    for (var i = 1; i <= 24; i++)
      CanonicalAlbumSummary(
        id: 'alb-${i.toString().padLeft(2, '0')}',
        title: 'Scale Test Album $i',
        artist: 'Artist $i',
        year: 2000 + i,
      ),
  ];

  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({
    int limit = 100,
    bool includeHidden = false,
  }) async {
    return _albums.take(limit).toList();
  }
}

Future<void> _secondaryTapAt(WidgetTester tester, Offset position) async {
  final gesture = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.addPointer(location: position);
  try {
    await gesture.down(position);
    await gesture.up();
    await tester.pumpAndSettle();
  } finally {
    await gesture.removePointer();
  }
}

Future<void> _hoverMoveTo(WidgetTester tester, Offset position) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(position);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    MediaSourcesController.instance.resetForTest();
  });

  group('LuminaApp integrated context menu & popover scale regression', () {
    for (final scale in const [1.0, 1.25, 1.50]) {
      testWidgets(
        'Album card right-click & Sidebar menus align at ${scale}x scale and clear capsule',
        (tester) async {
          addTearDown(tester.view.reset);
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = const Size(1920, 1080);

          final svc = _MenuScaleTestAudioService();
          final scaleCtrl = UiScaleController(
            initialHomeLayoutPreset: HomeLayoutPreset.classic,
          )..setScale(scale);
          addTearDown(() {
            svc.dispose();
            scaleCtrl.dispose();
          });

          await tester.pumpWidget(
            LuminaApp(audioService: svc, uiScaleController: scaleCtrl),
          );
          await tester.pumpAndSettle();

          final capsuleRect = tester.getRect(
            find.byKey(const Key('liquid_glass_capsule')),
          );

          // 1. Sidebar pinned smart playlist right-click alignment
          final spFinder = find.byKey(
            const Key('sidebar_smart_playlist_sp-all'),
          );
          expect(spFinder, findsOneWidget);
          await tester.ensureVisible(spFinder);
          await tester.pumpAndSettle();
          final spClick = tester.getCenter(spFinder);
          expect(spClick.dy, lessThan(capsuleRect.top));
          await _secondaryTapAt(tester, spClick);
          final spMenuRect = tester.getRect(
            find.byKey(const Key('sidebar_smart_playlist_menu')),
          );
          expect((spMenuRect.left - spClick.dx).abs(), lessThan(1.5));
          expect(spMenuRect.bottom, lessThanOrEqualTo(capsuleRect.top + 0.5));
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();

          // 2. Navigate to Albums and right-click top-left album card
          final albumsNavFinder = find.byKey(const Key('nav_tab_albums'));
          await tester.ensureVisible(albumsNavFinder);
          await tester.pumpAndSettle();
          await tester.tap(albumsNavFinder);
          await tester.pumpAndSettle();

          final firstCard = find.byKey(const Key('album_card_alb-01'));
          expect(firstCard, findsOneWidget);
          final firstCardRect = tester.getRect(firstCard);
          // Right-click near the upper cover so there is room to open downward at 1.0x..1.5x
          final cardClick = Offset(
            firstCardRect.center.dx,
            firstCardRect.top + 16.0 * scale,
          );
          await _secondaryTapAt(tester, cardClick);
          final albumMenuRect = tester.getRect(
            find.byKey(const Key('album_context_menu')),
          );
          expect(
            (albumMenuRect.left - cardClick.dx).abs(),
            lessThan(1.5),
            reason:
                'Album menu X drifted at ${scale}x: $albumMenuRect vs $cardClick',
          );
          expect(
            (albumMenuRect.top - cardClick.dy).abs(),
            lessThan(1.5),
            reason:
                'Album menu Y drifted at ${scale}x: $albumMenuRect vs $cardClick',
          );
          expect(albumMenuRect.bottom, lessThanOrEqualTo(capsuleRect.top + 0.5));
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
        },
      );
    }

    testWidgets(
      'PreferenceToggleButton & AudioQualityBadgeWithPopover(preferAbove: false) respect scale and bottom bar',
      (tester) async {
        addTearDown(tester.view.reset);
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 720);

        final svc = MockAudioService();
        addTearDown(svc.dispose);
        int? latestPref;

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            builder: (context, child) {
              final mq = MediaQuery.of(context);
              const scale = 1.5;
              final scaledSize = mq.size / scale;
              return MediaQuery(
                data: mq.copyWith(
                  size: scaledSize,
                  devicePixelRatio: mq.devicePixelRatio * scale,
                ),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Transform.scale(
                    scale: scale,
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: scaledSize.width,
                      height: scaledSize.height,
                      child: BottomPlayerBarScope(
                        clearanceListenable: ValueNotifier<double>(84.0),
                        child: child!,
                      ),
                    ),
                  ),
                ),
              );
            },
            home: Scaffold(
              body: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Center(
                    child: PreferenceToggleButton(
                      buttonKey: const Key('test_pref_btn'),
                      audioService: svc,
                      entityType: 'album_group',
                      entityId: 'alb-01',
                      preference: 0,
                      showLabel: true,
                      onChanged: (v) => latestPref = v,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 120),
                    child: AudioQualityBadgeWithPopover(
                      audioService: svc,
                      tier: AudioQualityTier.hiRes,
                      preferAbove: false,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final prefCenter = tester.getCenter(find.byKey(const Key('test_pref_btn')));
        await _secondaryTapAt(tester, prefCenter);
        final prefRect = tester.getRect(
          find.byKey(const Key('preference_picker_menu')),
        );
        expect((prefRect.left - prefCenter.dx).abs(), lessThan(1.5));
        expect((prefRect.top - prefCenter.dy).abs(), lessThan(1.5));
        await tester.tap(find.text('喜愛'));
        await tester.pumpAndSettle();
        expect(latestPref, 1);

        await tester.tap(find.byKey(const Key('quality_badge_button')));
        await tester.pumpAndSettle();
        final popRect = tester.getRect(
          find.byKey(const Key('audio_info_popover')),
        );
        expect(popRect.bottom, lessThanOrEqualTo(720.0 - 84.0 * 1.5 - 12.0 * 1.5 + 1.0));
      },
    );

    testWidgets(
      'AlbumLayoutSettingsButton & bottom-row album card menu never overlap liquid_glass_capsule at 150% scale on 1280x760',
      (tester) async {
        addTearDown(tester.view.reset);
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 760);

        final svc = _MenuScaleTestAudioService();
        final scaleCtrl = UiScaleController()..setScale(1.50);
        addTearDown(() {
          svc.dispose();
          scaleCtrl.dispose();
        });

        await tester.pumpWidget(
          LuminaApp(audioService: svc, uiScaleController: scaleCtrl),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('capsule_nav_albums')));
        await tester.pumpAndSettle();

        final capsuleRect = tester.getRect(
          find.byKey(const Key('liquid_glass_capsule')),
        );

        // Open album layout popover on short 150%-scaled window
        await tester.tap(find.byKey(const Key('btn_album_layout_settings')));
        await tester.pumpAndSettle();
        final layoutPopRect = tester.getRect(
          find.byKey(const Key('album_layout_popover')),
        );
        expect(
          layoutPopRect.bottom,
          lessThanOrEqualTo(capsuleRect.top + 0.5),
          reason:
              'AlbumLayoutPopover (${layoutPopRect.bottom}) overlapped capsule (${capsuleRect.top})',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        // Find the lowest visible album card above the bottom player bar and right-click near its bottom edge
        final cards = find.byType(AlbumCollectionCard);
        final cardRects = cards
            .evaluate()
            .map((e) => (
                  widget: e.widget as AlbumCollectionCard,
                  rect: tester.getRect(find.byWidget(e.widget)),
                ))
            .where(
              (entry) =>
                  entry.rect.top < capsuleRect.top - 24.0 &&
                  entry.rect.bottom > entry.rect.top,
            )
            .toList()
          ..sort((a, b) => b.rect.bottom.compareTo(a.rect.bottom));
        expect(cardRects, isNotEmpty);
        final bottomCard = cardRects.first;
        final desiredBottomY = bottomCard.rect.bottom < capsuleRect.top - 4.0
            ? bottomCard.rect.bottom - 6.0
            : capsuleRect.top - 12.0;
        final nearBottomPoint = Offset(
          bottomCard.rect.center.dx,
          desiredBottomY
              .clamp(bottomCard.rect.top + 8.0, capsuleRect.top - 6.0)
              .toDouble(),
        );
        await _secondaryTapAt(tester, nearBottomPoint);
        final bottomMenuRect = tester.getRect(
          find.byKey(const Key('album_context_menu')),
        );
        expect(bottomMenuRect.bottom, lessThanOrEqualTo(capsuleRect.top + 0.5));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        // Ensure alb-01's cover (including bottom-right ... button) is visible above capsule
        final gridFinder = find.byKey(const Key('album_grid_view'));
        final gridRect = tester.getRect(gridFinder);
        final coverFinder = find.descendant(
          of: find.byKey(const Key('album_card_alb-01')),
          matching: find.byType(AlbumArtworkView),
        );
        var coverRect = tester.getRect(coverFinder);
        if (coverRect.bottom > capsuleRect.top - 8.0) {
          final dy = -(coverRect.bottom - capsuleRect.top + 48.0);
          await tester.drag(gridFinder, Offset(0, dy));
          await tester.pumpAndSettle();
          coverRect = tester.getRect(coverFinder);
        }
        final visTop = math.max(coverRect.top, gridRect.top);
        final visBottom = math.min(coverRect.bottom, capsuleRect.top);
        await _hoverMoveTo(
          tester,
          Offset(coverRect.center.dx, (visTop + visBottom) * 0.5),
        );
        final moreBtn = find.byKey(const Key('album_card_more_alb-01'));
        expect(moreBtn, findsOneWidget);
        await tester.tap(moreBtn);
        await tester.pumpAndSettle();
        final moreMenuRect = tester.getRect(
          find.byKey(const Key('album_context_menu')),
        );
        expect(moreMenuRect.bottom, lessThanOrEqualTo(capsuleRect.top + 0.5));
        expect(moreMenuRect.right, lessThanOrEqualTo(1280.0));
      },
    );
  });
}
