import 'dart:ui' show PointerDeviceKind;

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/main.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/streaming_provider_meta.dart';
import 'package:lumina_app/services/media_sources_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/ui_scale_controller.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:lumina_app/ui/artists/artist_detail_page.dart';
import 'package:lumina_app/ui/streaming/streaming_service_view.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

/// Resolves the nearest opaque-ish ancestor surface color for a [Text] element
/// when checking rendered WCAG AA contrast ratios in widget tests.
Color _resolveRenderedBgForText(Element textElement) {
  Color? foundBg;
  textElement.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is Material &&
        widget.color != null &&
        widget.color != Colors.transparent &&
        widget.color!.a >= 0.85) {
      foundBg = widget.color;
      return false;
    }
    if (widget is DecoratedBox) {
      final dec = widget.decoration;
      if (dec is BoxDecoration) {
        if (dec.color != null &&
            dec.color != Colors.transparent &&
            dec.color!.a >= 0.85) {
          foundBg = dec.color;
          return false;
        }
        if (dec.gradient is LinearGradient) {
          final grad = dec.gradient as LinearGradient;
          if (grad.colors.isNotEmpty) {
            foundBg = grad.colors.first;
            return false;
          }
        }
      }
    }
    if (widget is Container && widget.color != null && widget.color!.a >= 0.85) {
      foundBg = widget.color;
      return false;
    }
    if (widget is Scaffold && widget.backgroundColor != null) {
      foundBg = widget.backgroundColor;
      return false;
    }
    return true;
  });
  return foundBg ?? LuminaTokens.cardBg;
}

bool _isInsideDisabledControl(Element el) {
  var disabled = false;
  el.visitAncestorElements((ancestor) {
    final w = ancestor.widget;
    if (w is ButtonStyleButton && !w.enabled) {
      disabled = true;
      return false;
    }
    if (w is IconButton && w.onPressed == null) {
      disabled = true;
      return false;
    }
    return true;
  });
  return disabled;
}

void _assertRenderedViewCompliant(WidgetTester tester, String stageName) {
  // 1. Zero shrinkWrap ScrollViews in rendered browse/shell views.
  for (final sv in tester.widgetList<ScrollView>(find.byType(ScrollView))) {
    expect(
      sv.shrinkWrap,
      isFalse,
      reason: '[$stageName] ScrollView ${sv.key} must not use shrinkWrap: true',
    );
  }

  // 2. Every standalone IconButton must provide a descriptive tooltip.
  for (final btn in tester.widgetList<IconButton>(find.byType(IconButton))) {
    expect(
      btn.tooltip != null && btn.tooltip!.trim().isNotEmpty,
      isTrue,
      reason: '[$stageName] IconButton ${btn.key} is missing a tooltip',
    );
  }

  // 3. Every visible non-disabled Text must satisfy WCAG AA (>= 4.5:1 normal,
  // >= 3.0:1 large >= 18px or >= 14px bold) against its nearest surface.
  for (final el in find.byType(Text).evaluate()) {
    if (_isInsideDisabledControl(el)) continue;
    final textWidget = el.widget as Text;
    final data = textWidget.data ?? textWidget.textSpan?.toPlainText() ?? '';
    if (data.trim().isEmpty) continue;

    final style = textWidget.style;
    final fg = style?.color;
    if (fg == null) continue;

    final bg = _resolveRenderedBgForText(el);
    final fontSize = style?.fontSize ?? 14.0;
    final isBold =
        (style?.fontWeight?.value ?? FontWeight.w400.value) >=
        FontWeight.w700.value;
    final isLarge = fontSize >= 18.0 || (isBold && fontSize >= 14.0);
    final minRatio = isLarge ? 3.0 : 4.5;
    final ratio = LuminaTokens.contrastRatio(fg, bg);

    expect(
      ratio,
      greaterThanOrEqualTo(minRatio),
      reason:
          '[$stageName] Text "$data" ($fg on $bg) has contrast '
          '${ratio.toStringAsFixed(2)}:1 < $minRatio:1',
    );
  }
}

class _StreamingAuditAudioService extends MockAudioService {
  @override
  List<TrackInfo> get queue => const [
    TrackInfo(
      id: 'trk-qobuz-1',
      title: 'Qobuz Hi-Res Track',
      artist: 'Artist Q',
      album: 'Album Q',
      duration: Duration(minutes: 4),
      format: AudioFormat(
        codec: AudioCodec.flac,
        sampleRateHz: 192000,
        bitDepth: 24,
        channels: 2,
      ),
      providerName: 'Qobuz',
    ),
    TrackInfo(
      id: 'trk-deezer-1',
      title: 'Deezer HiFi Track',
      artist: 'Artist D',
      album: 'Album D',
      duration: Duration(minutes: 3, seconds: 30),
      format: AudioFormat(
        codec: AudioCodec.flac,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
      ),
      providerName: 'Deezer',
    ),
  ];
}

void main() {
  setUp(() => MediaSourcesController.instance.resetForTest());

  group('LuminaTokens WCAG AA Dark Mode Contrast', () {
    test('textPrimary, textSecondary, textMuted achieve >= 4.5:1 on surfaces', () {
      const surfaces = [
        LuminaTokens.canvasBg,
        LuminaTokens.sidebarBg,
        LuminaTokens.cardBg,
        LuminaTokens.cardElevatedBg,
        LuminaTokens.cardHoverBg,
      ];
      const readableTexts = [
        LuminaTokens.textPrimary,
        LuminaTokens.textSecondary,
        LuminaTokens.textMuted,
      ];
      for (final bg in surfaces) {
        for (final fg in readableTexts) {
          final ratio = LuminaTokens.contrastRatio(fg, bg);
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason: 'Token $fg on $bg measured ${ratio.toStringAsFixed(2)}:1',
          );
        }
      }
    });

    test('borderControl, focusRing, accents & status tokens satisfy WCAG AA', () {
      for (final bg in const [
        LuminaTokens.canvasBg,
        LuminaTokens.cardBg,
        LuminaTokens.cardElevatedBg,
      ]) {
        expect(
          LuminaTokens.contrastRatio(LuminaTokens.borderControl, bg),
          greaterThanOrEqualTo(3.0),
        );
        expect(
          LuminaTokens.contrastRatio(LuminaTokens.focusRing, bg),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          LuminaTokens.contrastRatio(LuminaTokens.accentBlue, bg),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          LuminaTokens.contrastRatio(LuminaTokens.accentPurple, bg),
          greaterThanOrEqualTo(3.0),
        );
        expect(
          LuminaTokens.contrastRatio(LuminaTokens.accentPurpleText, bg),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          LuminaTokens.contrastRatio(LuminaTokens.statusSuccess, bg),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          LuminaTokens.contrastRatio(LuminaTokens.statusWarning, bg),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          LuminaTokens.contrastRatio(LuminaTokens.statusError, bg),
          greaterThanOrEqualTo(4.5),
        );
      }

      // Dark ink on solid accent button fill
      expect(
        LuminaTokens.contrastRatio(
          LuminaTokens.onAccentDark,
          LuminaTokens.accentBlue,
        ),
        greaterThanOrEqualTo(4.5),
      );

      // Legacy white38 fails 4.5:1 on cardBg, confirming why textMuted is used
      expect(
        LuminaTokens.contrastRatio(Colors.white38, LuminaTokens.cardBg),
        lessThan(4.5),
      );
    });
  });

  group('UI/UX Pro Max Rendered Tab Audits', () {
    testWidgets(
      'verifies contrast, tooltips, and non-shrinkWrap across Home, Albums, AlbumDetail, Artists, ArtistDetail, Library, SmartPlaylists, Audiobooks, Podcasts, Radio',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final svc = MockAudioService();
        addTearDown(svc.dispose);
        final scaleCtrl = UiScaleController();
        addTearDown(scaleCtrl.dispose);

        await tester.pumpWidget(
          LuminaApp(audioService: svc, uiScaleController: scaleCtrl),
        );
        await tester.pumpAndSettle();

        // 1. Home (including hovered recent album card contrast check)
        expect(find.byKey(const Key('home_dashboard_view')), findsOneWidget);
        _assertRenderedViewCompliant(tester, 'Home');

        final recentCard = find.byKey(
          const Key('home_recent_album_alb-dsotm'),
        );
        if (recentCard.evaluate().isNotEmpty) {
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: Offset.zero);
          addTearDown(mouse.removePointer);
          await mouse.moveTo(tester.getCenter(recentCard));
          await tester.pumpAndSettle();
          final hoveredTitle = tester.widget<Text>(
            find
                .descendant(of: recentCard, matching: find.byType(Text))
                .at(1),
          );
          expect(
            LuminaTokens.contrastRatio(
              hoveredTitle.style!.color!,
              const Color(0xFF454D79),
            ),
            greaterThanOrEqualTo(4.5),
          );
          await mouse.moveTo(Offset.zero);
          await tester.pumpAndSettle();
        }

        // 2. Albums -> AlbumDetail
        await tester.tap(find.byKey(const Key('nav_tab_albums')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('album_grid_view')), findsOneWidget);
        _assertRenderedViewCompliant(tester, 'Albums');

        final albumCard = find.byWidgetPredicate(
          (w) => w.key.toString().contains('album_card_'),
        );
        expect(albumCard, findsWidgets);
        await tester.tap(albumCard.first);
        await tester.pumpAndSettle();
        expect(find.byType(AlbumDetailPage), findsOneWidget);
        _assertRenderedViewCompliant(tester, 'AlbumDetail');

        // 3. Artists -> ArtistDetail
        await tester.tap(find.byKey(const Key('nav_tab_artists')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('artists_list_view')), findsOneWidget);
        _assertRenderedViewCompliant(tester, 'Artists');

        await tester.tap(find.byKey(const Key('artist_tile_Pink Floyd')));
        await tester.pumpAndSettle();
        expect(find.byType(ArtistDetailPage), findsOneWidget);
        _assertRenderedViewCompliant(tester, 'ArtistDetail');

        // 4. Library
        await tester.tap(find.byKey(const Key('nav_tab_library')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('track_queue_list')), findsOneWidget);
        _assertRenderedViewCompliant(tester, 'Library');

        // 5. Smart Playlists
        await tester.tap(find.byKey(const Key('nav_tab_smart_playlists')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('smart_playlists_view')), findsOneWidget);
        _assertRenderedViewCompliant(tester, 'SmartPlaylists');

        // 6. Media tabs (Audiobooks, Podcasts, Radio)
        await tester.tap(find.byKey(const Key('nav_tab_audiobooks')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('audiobooks_list_view')), findsOneWidget);
        _assertRenderedViewCompliant(tester, 'Audiobooks');

        await tester.tap(find.byKey(const Key('nav_tab_podcasts')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('podcasts_list_view')), findsOneWidget);
        _assertRenderedViewCompliant(tester, 'Podcasts');

        await tester.tap(find.byKey(const Key('nav_tab_radio')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('radio_list_view')), findsOneWidget);
        _assertRenderedViewCompliant(tester, 'Radio');
      },
    );

    testWidgets(
      'StreamingServiceView passes WCAG AA contrast for Qobuz & Deezer selected tracks and zero shrinkWrap',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final svc = _StreamingAuditAudioService();
        addTearDown(svc.dispose);

        for (final kind in const ['qobuz', 'deezer']) {
          final meta = StreamingProviderMeta.byKind(kind)!;
          await tester.pumpWidget(
            MaterialApp(
              theme: LuminaTokens.buildDarkTheme(),
              home: Scaffold(
                backgroundColor: LuminaTokens.canvasBg,
                body: StreamingServiceView(
                  audioService: svc,
                  provider: meta,
                  activeTrackId: 'trk-$kind-1',
                  onOpenProviderSettings: () {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(Key('streaming_track_trk-$kind-1')),
            findsOneWidget,
          );
          _assertRenderedViewCompliant(tester, 'StreamingServiceView_$kind');
        }
      },
    );

    testWidgets(
      'renders all owned tabs cleanly at 100% and 150% UI scale with zero overflow',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final svc = MockAudioService();
        addTearDown(svc.dispose);
        final scaleCtrl = UiScaleController();
        addTearDown(scaleCtrl.dispose);

        await tester.pumpWidget(
          LuminaApp(audioService: svc, uiScaleController: scaleCtrl),
        );
        await tester.pumpAndSettle();

        for (final scale in const [1.0, 1.5]) {
          scaleCtrl.setScale(scale);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          for (final navKey in const [
            'nav_tab_home',
            'nav_tab_albums',
            'nav_tab_artists',
            'nav_tab_library',
            'nav_tab_smart_playlists',
            'nav_tab_audiobooks',
            'nav_tab_podcasts',
            'nav_tab_radio',
          ]) {
            await tester.tap(find.byKey(Key(navKey)));
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: 'Overflow or exception on $navKey at ${scale}x scale',
            );
          }
        }
      },
    );
  });
}
