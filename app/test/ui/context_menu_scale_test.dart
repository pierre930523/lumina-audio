import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/ui/common/bottom_player_bar_scope.dart';
import 'package:lumina_app/ui/common/lumina_context_menu.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:lumina_app/ui/theme/responsive_layout.dart';
import 'package:material_ui/material_ui.dart';

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

Widget _buildScaledHarness({
  required double scale,
  required double bottomClearance,
  required Widget child,
}) {
  return MaterialApp(
    theme: LuminaTokens.buildDarkTheme(),
    builder: (context, navChild) {
      if (navChild == null) return const SizedBox.shrink();
      final mq = MediaQuery.of(context);
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
                clearanceListenable: ValueNotifier<double>(bottomClearance),
                child: navChild,
              ),
            ),
          ),
        ),
      );
    },
    home: Scaffold(body: child),
  );
}

void main() {
  group('showLuminaContextMenu scale conversion, edge flip & clamping', () {
    for (final scale in const [1.0, 1.25, 1.50]) {
      testWidgets(
        'aligns right-click menu at top-left, center, right-flip & bottom-flip at ${scale}x scale',
        (tester) async {
          const viewport = Size(1280, 720);
          const bottomClearance = 84.0;
          tester.view.devicePixelRatio = 1.0;
          tester.view.physicalSize = viewport;
          addTearDown(tester.view.reset);

          String? lastResult;
          final entries = <LuminaContextMenuEntry<String>>[
            const LuminaContextMenuAction<String>(
              value: 'play',
              icon: Icons.play_arrow_rounded,
              label: '播放曲目',
            ),
            const LuminaContextMenuAction<String>(
              value: 'queue',
              icon: Icons.playlist_add_rounded,
              label: '加入播放佇列',
            ),
            const LuminaContextMenuDivider<String>(),
            const LuminaContextMenuAction<String>(
              value: 'edit',
              icon: Icons.edit_outlined,
              label: '編輯曲目資訊...',
            ),
          ];

          await tester.pumpWidget(
            _buildScaledHarness(
              scale: scale,
              bottomClearance: bottomClearance,
              child: Builder(
                builder: (ctx) => GestureDetector(
                  key: const Key('test_canvas'),
                  behavior: HitTestBehavior.opaque,
                  onSecondaryTapUp: (details) async {
                    lastResult = await showLuminaContextMenu<String>(
                      context: ctx,
                      globalPosition: details.globalPosition,
                      entries: entries,
                      menuKey: const Key('scaled_ctx_menu'),
                    );
                  },
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          // 1. Top-left click -> clamped inside edgeMargin, aligned near cursor
          final topLeftClick = Offset(30.0 * scale, 24.0 * scale);
          await _secondaryTapAt(tester, topLeftClick);
          final topLeftRect = tester.getRect(
            find.byKey(const Key('scaled_ctx_menu')),
          );
          expect((topLeftRect.left - topLeftClick.dx).abs(), lessThan(1.0));
          expect((topLeftRect.top - topLeftClick.dy).abs(), lessThan(1.0));
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();

          // 2. Center click -> opens down-right directly from cursor
          const centerClick = Offset(480, 260);
          await _secondaryTapAt(tester, centerClick);
          final centerRect = tester.getRect(
            find.byKey(const Key('scaled_ctx_menu')),
          );
          expect((centerRect.left - centerClick.dx).abs(), lessThan(1.0));
          expect((centerRect.top - centerClick.dy).abs(), lessThan(1.0));
          await tester.tap(find.text('播放曲目'));
          await tester.pumpAndSettle();
          expect(lastResult, 'play');

          // 3. Near right edge -> flips left of cursor and stays inside viewport
          const rightClick = Offset(1245, 220);
          await _secondaryTapAt(tester, rightClick);
          final rightRect = tester.getRect(
            find.byKey(const Key('scaled_ctx_menu')),
          );
          expect(
            (rightRect.right - rightClick.dx).abs(),
            lessThan(1.0),
            reason:
                'Near right edge menu should flip left of cursor ($rightRect)',
          );
          expect(
            rightRect.right,
            lessThanOrEqualTo(viewport.width - 12.0 * scale + 1.0),
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('scaled_ctx_menu')), findsNothing);

          // 4. Near bottom (just above bottom player bar) -> flips up & avoids player bar
          final playerBarTopRoot = viewport.height - bottomClearance * scale;
          final bottomClick = Offset(420, playerBarTopRoot - 20.0);
          await _secondaryTapAt(tester, bottomClick);
          final bottomRect = tester.getRect(
            find.byKey(const Key('scaled_ctx_menu')),
          );
          expect(
            bottomRect.bottom,
            lessThanOrEqualTo(bottomClick.dy + 1.0),
            reason: 'Near bottom menu should flip upward ($bottomRect)',
          );
          expect(
            bottomRect.bottom,
            lessThanOrEqualTo(playerBarTopRoot - 12.0 * scale + 1.0),
            reason:
                'Menu bottom (${bottomRect.bottom}) must clear bottom bar top ($playerBarTopRoot)',
          );
          await tester.tapAt(const Offset(20, 20));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('scaled_ctx_menu')), findsNothing);
        },
      );
    }

    testWidgets(
      'supports custom headerBuilder with quick actions and anchorContext at 1.5x scale',
      (tester) async {
        tester.view.devicePixelRatio = 1.0;
        tester.view.physicalSize = const Size(1280, 720);
        addTearDown(tester.view.reset);

        String? chosen;
        await tester.pumpWidget(
          _buildScaledHarness(
            scale: 1.5,
            bottomClearance: 84.0,
            child: Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 16, bottom: 92),
                child: Builder(
                  builder: (btnCtx) => IconButton(
                    key: const Key('btn_test_more'),
                    icon: const Icon(Icons.more_horiz_rounded),
                    onPressed: () async {
                      chosen = await showLuminaContextMenu<String>(
                        context: btnCtx,
                        anchorContext: btnCtx,
                        width: 228.0,
                        menuKey: const Key('header_ctx_menu'),
                        headerBuilder: (ctx, closeMenu) => Padding(
                          padding: const EdgeInsets.all(8),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'Test Track',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              IconButton(
                                key: const Key('btn_header_play_next'),
                                icon: const Icon(Icons.playlist_play_rounded),
                                onPressed: () => closeMenu('play_next'),
                              ),
                            ],
                          ),
                        ),
                        entries: const [
                          LuminaContextMenuSectionLabel<String>('曲目操作'),
                          LuminaContextMenuAction<String>(
                            value: 'tags',
                            label: '新增至標籤',
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('btn_test_more')));
        await tester.pumpAndSettle();
        final btnRect = tester.getRect(find.byKey(const Key('btn_test_more')));
        final menuRect = tester.getRect(find.byKey(const Key('header_ctx_menu')));
        expect(menuRect.right, lessThanOrEqualTo(1280 - 12.0 * 1.5 + 1.0));
        expect(menuRect.bottom, lessThanOrEqualTo(btnRect.top + 1.0));
        expect(
          menuRect.bottom,
          lessThanOrEqualTo(720 - 84.0 * 1.5 - 12.0 * 1.5 + 1.0),
        );

        await tester.tap(find.byKey(const Key('btn_header_play_next')));
        await tester.pumpAndSettle();
        expect(chosen, 'play_next');
        expect(find.byKey(const Key('header_ctx_menu')), findsNothing);
      },
    );

    test('LuminaResponsive.computeClampedPopover reserves bottomInset above player bar', () {
      final res = LuminaResponsive.computeClampedPopover(
        overlaySize: const Size(853, 506),
        targetTopLeft: const Offset(750, 120),
        targetSize: const Size(36, 34),
        preferredWidth: 316,
        preferredMaxHeight: 520,
        bottomInset: 84.0,
      );
      final bottomLimit = 506.0 - 84.0 - 12.0; // 410.0
      final popoverBottom = 120.0 + 34.0 + res.offset.dy + res.maxHeight;
      expect(popoverBottom, lessThanOrEqualTo(bottomLimit + 0.01));
    });
  });
}
