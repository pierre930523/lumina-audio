import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/main.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('LuminaApp boots HomeScreen, mini-player, and lyrics', (
    WidgetTester tester,
  ) async {
    final service = MockAudioService();
    addTearDown(service.dispose);

    await tester.pumpWidget(LuminaApp(audioService: service));
    await tester.pumpAndSettle();

    expect(find.text('Lumina Audio'), findsOneWidget);
    expect(find.byKey(const Key('capsule_track_title')), findsOneWidget);
    expect(find.byKey(const Key('capsule_track_artist')), findsOneWidget);
    expect(find.text('Time'), findsWidgets);
    expect(find.text('Pink Floyd'), findsWidgets);
    expect(find.byKey(const Key('home_dashboard_view')), findsOneWidget);
    expect(find.byKey(const Key('home_quick_queue_card')), findsOneWidget);
    expect(find.byKey(const Key('nav_tab_lyrics')), findsNothing);
    expect(find.byKey(const Key('nav_tab_dsp')), findsNothing);
    expect(find.byKey(const Key('nav_tab_zones')), findsNothing);
    expect(find.byKey(const Key('nav_tab_settings')), findsNothing);

    // Click bottom-left track area to expand Focus View Now Playing overlay
    await tester.tap(find.byKey(const Key('btn_expand_now_playing')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('now_playing_overlay')), findsOneWidget);
    expect(find.byKey(const Key('lyrics_list_view')), findsNothing);

    // Switch to Split Lyrics inside Now Playing
    await tester.tap(find.byKey(const Key('btn_now_playing_mode_split')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('lyrics_list_view')), findsOneWidget);

    // Collapse back to workspace via overlay collapse button
    await tester.tap(find.byKey(const Key('btn_collapse_now_playing')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('now_playing_overlay')), findsNothing);
    expect(find.byKey(const Key('home_dashboard_view')), findsOneWidget);

    // Toggle overlay via mini-player lyrics button (opens Split Lyrics directly,
    // second tap returns to Cover Focus View, collapse closes back to Home)
    await tester.tap(find.byKey(const Key('btn_toggle_lyrics')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('now_playing_overlay')), findsOneWidget);
    expect(find.byKey(const Key('lyrics_list_view')), findsOneWidget);
    await tester.tap(find.byKey(const Key('btn_toggle_lyrics')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('now_playing_overlay')), findsOneWidget);
    expect(find.byKey(const Key('lyrics_list_view')), findsNothing);
    await tester.tap(find.byKey(const Key('btn_collapse_now_playing')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('now_playing_overlay')), findsNothing);
    expect(find.byKey(const Key('home_dashboard_view')), findsOneWidget);

    // Open bottom-right Quick Output Popover (ASIO / WASAPI + Restore Toggle)
    await tester.tap(find.byKey(const Key('btn_quick_output_popover')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick_output_popover')), findsOneWidget);
    expect(find.byKey(const Key('output_tab_asio')), findsOneWidget);
    expect(find.byKey(const Key('output_tab_wasapi')), findsOneWidget);
    expect(find.byKey(const Key('switch_restore_output_startup')), findsOneWidget);
    expect(find.byKey(const Key('quick_output_dev_asio-fiio-k9')), findsOneWidget);

    await tester.tap(find.byKey(const Key('output_tab_wasapi')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick_output_dev_usb-dac-mobile')), findsOneWidget);

    await tester.tap(find.byKey(const Key('btn_popover_open_zones')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick_output_popover')), findsNothing);
    expect(find.byKey(const Key('output_zone_panel')), findsOneWidget);

    // Navigate to Settings hub and verify General / Appearance & Scale / DSP / Zones / Settings tabs live there
    await tester.tap(find.byKey(const Key('nav_tab_general')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('general_settings_panel')), findsOneWidget);
    expect(find.byKey(const Key('nav_tab_appearance')), findsOneWidget);
    expect(find.byKey(const Key('nav_tab_dsp')), findsOneWidget);
    expect(find.byKey(const Key('nav_tab_zones')), findsOneWidget);
    expect(find.byKey(const Key('nav_tab_settings')), findsOneWidget);

    await tester.tap(find.byKey(const Key('nav_tab_appearance')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('appearance_scale_panel')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('btn_scale_preset_125')));
    await tester.tap(find.byKey(const Key('btn_scale_preset_125')));
    await tester.pumpAndSettle();
    expect(find.text('125%'), findsWidgets);
    expect(tester.getSize(find.byType(HomeScreen)), const Size(640, 480));

    await tester.ensureVisible(find.byKey(const Key('btn_scale_reset')));
    await tester.tap(find.byKey(const Key('btn_scale_reset')));
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsWidgets);
    expect(tester.getSize(find.byType(HomeScreen)), const Size(800, 600));

    // Navigate to Smart Playlists view and verify creating a custom rule playlist
    await tester.ensureVisible(find.byKey(const Key('nav_tab_smart_playlists')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nav_tab_smart_playlists')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('smart_playlists_view')), findsOneWidget);

    await tester.tap(find.byKey(const Key('btn_create_smart_playlist')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('input_smart_playlist_name')),
      '搖滾精選',
    );
    await tester.enterText(
      find.byKey(const Key('input_smart_playlist_keyword')),
      'Money',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('btn_save_smart_playlist')));
    await tester.pumpAndSettle();
    expect(find.text('搖滾精選'), findsWidgets);
    expect(find.text('Money'), findsWidgets);

    // Open Quick Queue Popover via bottom icon button and jump to Library queue view
    await tester.tap(find.byKey(const Key('btn_quick_queue_popover')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('quick_queue_popover')), findsOneWidget);
    expect(find.byKey(const Key('quick_queue_item_trk-001')), findsOneWidget);
    await tester.tap(find.byKey(const Key('btn_queue_open_library')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('track_queue_list')), findsOneWidget);
  });
}
