import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/services/ffi_audio_service.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/mini_player/quick_output_popover.dart';
import 'package:lumina_app/ui/zones/output_zone_panel.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('R4: 切換輸出裝置不覆蓋其他裝置的獨立播放狀態與音量', () async {
    final svc = MockAudioService();
    addTearDown(svc.dispose);
    final devs = await svc.listAudioDevices();
    final a = devs[0].id;
    final b = devs[1].id;
    await svc.selectAudioDevice(a);
    await svc.setVolume(0.75);
    await svc.play(track: svc.queue[0]);
    await svc.seek(const Duration(seconds: 30));
    final trackA = svc.currentState.track?.id;

    // 調整非作用中裝置 B 的音量，不應改變 A 的音量
    await svc.setDeviceVolume(b, 0.25);
    expect(svc.currentState.volume, closeTo(0.75, 0.001));

    await svc.selectAudioDevice(b);
    expect(svc.currentState.track, isNull);
    expect(svc.currentState.status, PlaybackStatus.stopped);
    expect(svc.currentState.volume, closeTo(0.25, 0.001));
    await svc.play(track: svc.queue[1]);

    final states = svc.devicePlaybackStates;
    expect(states[a]!.track!.id, trackA);
    expect(states[a]!.position, const Duration(seconds: 30));
    expect(states[a]!.status, PlaybackStatus.paused);
    expect(states[a]!.volume, closeTo(0.75, 0.001));
    expect(states[b]!.track!.id, svc.queue[1].id);
    expect(states[b]!.volume, closeTo(0.25, 0.001));

    await svc.selectAudioDevice(a);
    expect(svc.currentState.track!.id, trackA);
    expect(svc.currentState.volume, closeTo(0.75, 0.001));
    expect(svc.devicePlaybackStates[b]!.track!.id, svc.queue[1].id);
  });

  test('R4: 各音區（Zone）具備獨立播放狀態與音量控制', () async {
    final svc = MockAudioService();
    addTearDown(svc.dispose);
    await svc.listZones();
    await svc.play(track: svc.queue[0]);

    // 遙控網路音區播放與音量不影響本機音區曲目與音量
    await svc.toggleZonePlayPause('dlna-living-room');
    await svc.setZoneVolume('dlna-living-room', 0.35);

    final zStates = svc.zonePlaybackStates;
    expect(zStates['zone-local']!.status, PlaybackStatus.playing);
    expect(zStates['dlna-living-room']!.status, PlaybackStatus.playing);
    expect(zStates['dlna-living-room']!.volume, closeTo(0.35, 0.001));

    await svc.toggleZonePlayPause('dlna-living-room');
    expect(svc.zonePlaybackStates['dlna-living-room']!.status, PlaybackStatus.paused);
    expect(svc.zonePlaybackStates['zone-local']!.status, PlaybackStatus.playing);
  });

  test('R4: FfiAudioService 原生層同步維護多裝置獨立狀態', () async {
    final tempDir = Directory.systemTemp.createTempSync('lumina_r4_ffi_');
    final dbPath = '${tempDir.path}${Platform.pathSeparator}r4.db';
    final svc = FfiAudioService(headless: true, databasePath: dbPath);
    try {
      final devs = await svc.listAudioDevices();
      expect(svc.activeDeviceId, isNotNull);
      await svc.setDeviceVolume('virtual-other', 0.4);
      expect(svc.devicePlaybackStates['virtual-other']?.volume, closeTo(0.4, 0.01));
      if (devs.length >= 2) {
        await svc.selectAudioDevice(devs.last.id);
        expect(svc.activeDeviceId, devs.last.id);
      }
    } finally {
      svc.dispose();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  testWidgets('R4 UI: QuickOutputPopover 與 OutputZonePanel 顯示各裝置與音區獨立控制', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final svc = MockAudioService();
    addTearDown(svc.dispose);
    await svc.listAudioDevices();
    await svc.listZones();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              QuickOutputPopover(audioService: svc, onClose: () {}),
              Expanded(child: OutputZonePanel(audioService: svc)),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('quick_output_play_asio-fiio-k9')), findsOneWidget);
    expect(find.byKey(const Key('quick_output_vol_asio-fiio-k9')), findsOneWidget);
    expect(find.byKey(const Key('btn_zone_play_zone-local')), findsOneWidget);
    expect(find.byKey(const Key('btn_zone_play_dlna-living-room')), findsOneWidget);

    // 點擊網路音區播放鍵，狀態應切換且不干擾本機音區
    await tester.tap(find.byKey(const Key('btn_zone_play_dlna-living-room')));
    await tester.pumpAndSettle();
    expect(svc.zonePlaybackStates['dlna-living-room']!.status, PlaybackStatus.playing);
    expect(svc.zonePlaybackStates['zone-local']!.status, PlaybackStatus.paused);
  });
}
