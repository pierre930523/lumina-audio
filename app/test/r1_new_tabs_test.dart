import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/main.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/services/media_sources_controller.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:material_ui/material_ui.dart';

Future<void> _pump(
  WidgetTester tester,
  MockAudioService svc, {
  Size size = const Size(1400, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(LuminaApp(audioService: svc));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => MediaSourcesController.instance.resetForTest());

  testWidgets('藝術家分頁列出曲庫藝術家，可檢視作品並跳轉關係圖', (tester) async {
    final svc = MockAudioService();
    addTearDown(svc.dispose);
    await _pump(tester, svc);
    await tester.tap(find.byKey(const Key('nav_tab_artists')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('artists_list_view')), findsOneWidget);
    expect(find.byKey(const Key('artist_tile_Pink Floyd')), findsOneWidget);

    await tester.tap(find.byKey(const Key('artist_tile_Pink Floyd')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('artist_detail_back_btn')), findsNothing);
    expect(find.byKey(const Key('btn_artist_open_credits')), findsOneWidget);
    expect(find.byKey(const Key('artist_track_0')), findsOneWidget);

    await tester.tap(find.byKey(const Key('btn_artist_open_credits')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('credits_graph_view')), findsOneWidget);
  });

  testWidgets('有聲書／Podcast／廣播電台分頁可開啟、播放範例並新增自訂來源', (tester) async {
    final svc = MockAudioService();
    addTearDown(svc.dispose);
    await _pump(tester, svc);

    // 有聲書：播放範例
    await tester.tap(find.byKey(const Key('nav_tab_audiobooks')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('audiobooks_list_view')), findsOneWidget);
    await tester.tap(find.byKey(const Key('audiobook_tile_ab-001')));
    await tester.pumpAndSettle();
    expect(svc.currentState.status, PlaybackStatus.playing);
    expect(svc.currentState.track?.title, '原子習慣');

    // Podcast：YouTube Music Podcast 頁面（無假資料，含分段頁籤與搜尋列）
    await tester.tap(find.byKey(const Key('nav_tab_podcasts')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('podcasts_list_view')), findsOneWidget);
    expect(find.byKey(const Key('podcast_tab_my_shows')), findsOneWidget);
    expect(find.byKey(const Key('podcast_tab_explore')), findsOneWidget);
    expect(
      find.byKey(const Key('podcast_tab_latest_episodes')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('podcast_search_input')), findsOneWidget);
    expect(find.text('法客電台'), findsNothing);
    expect(find.text('The Vergecast'), findsNothing);

    // 廣播電台：新增自訂電台與播放
    await tester.tap(find.byKey(const Key('nav_tab_radio')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('radio_list_view')), findsOneWidget);
    await tester.tap(find.text('新增電台'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('media_source_name_field')),
      '測試電台',
    );
    await tester.enterText(
      find.byKey(const Key('media_source_url_field')),
      'https://example.com/live',
    );
    await tester.tap(find.byKey(const Key('media_source_confirm_btn')));
    await tester.pumpAndSettle();
    expect(find.text('測試電台'), findsOneWidget);
    expect(
      MediaSourcesController.instance.byKind(MediaSourceKind.radio),
      hasLength(1),
    );
  });

  testWidgets('點專輯卡片開啟獨立專輯詳情頁、切換版本、播放曲目並可返回', (tester) async {
    final svc = MockAudioService();
    addTearDown(svc.dispose);
    await _pump(tester, svc);
    await tester.tap(find.byKey(const Key('nav_tab_albums')));
    await tester.pumpAndSettle();
    final card = find.byWidgetPredicate(
      (w) => w.key.toString().contains('album_card_'),
    );
    expect(card, findsWidgets);
    await tester.tap(card.first);
    await tester.pumpAndSettle();
    expect(find.byType(AlbumDetailPage), findsOneWidget);
    expect(find.byKey(const Key('album_detail_back_btn')), findsNothing);
    expect(find.byKey(const Key('album_hero_title')), findsOneWidget);
    expect(find.byKey(const Key('album_track_0')), findsOneWidget);

    await tester.tap(find.byKey(const Key('album_track_0')));
    await tester.pumpAndSettle();
    expect(svc.currentState.status, PlaybackStatus.playing);

    await tester.tap(find.byKey(const Key('btn_nav_back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('album_grid_view')), findsOneWidget);
  });

  testWidgets('行動版窄螢幕自適應顯示新分頁不溢位', (tester) async {
    final svc = MockAudioService();
    addTearDown(svc.dispose);
    await _pump(tester, svc, size: const Size(390, 844));
    expect(find.byKey(const Key('nav_tab_artists')), findsOneWidget);
    final strip = find.byType(ListView).first;
    for (final k in ['nav_tab_audiobooks', 'nav_tab_podcasts', 'nav_tab_radio']) {
      await tester.drag(strip, const Offset(-180, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(Key(k)), findsOneWidget);
    }
  });
}
