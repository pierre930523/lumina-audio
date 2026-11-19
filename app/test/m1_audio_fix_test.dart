import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/ffi_audio_service.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/ui/mini_player/quick_output_popover.dart';
import 'package:material_ui/material_ui.dart';

class _WasapiOnlyMockAudioService extends MockAudioService {
  @override
  Future<List<AudioDeviceInfo>> listAudioDevices() async => const [
        AudioDeviceInfo(
          id: 'wasapi-speakers',
          name: 'Speakers (WASAPI Shared)',
          backend: 'windows_wasapi_shared',
          isDefault: true,
          isExclusive: false,
          supportedSampleRates: [44100, 48000, 96000],
        ),
      ];
}

void main() {
  test('FfiAudioService propagates playback error on missing file without throwing', () async {
    final tempDir = Directory.systemTemp.createTempSync('lumina_m1_err_');
    final dbPath = '${tempDir.path}${Platform.pathSeparator}err.db';
    final service = FfiAudioService(headless: true, databasePath: dbPath);
    try {
      expect(service.isNativeBound, isTrue);

      final missingTrack = TrackInfo(
        id: 'missing-1',
        title: 'Missing Audio',
        artist: 'Test',
        album: 'Test',
        duration: const Duration(seconds: 10),
        format: const AudioFormat(
          codec: AudioCodec.flac,
          sampleRateHz: 96000,
          bitDepth: 24,
          channels: 2,
        ),
        providerName: 'Local Library',
        filePath: '${tempDir.path}${Platform.pathSeparator}does_not_exist.wav',
      );

      await service.play(track: missingTrack);
      expect(service.currentState.status, PlaybackStatus.stopped);
      expect(service.lastError, isNotNull);
      expect(service.lastError, isNotEmpty);
    } finally {
      service.dispose();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  test('FfiAudioService plays built-in demo track via synth stream and advances position', () async {
    final tempDir = Directory.systemTemp.createTempSync('lumina_m1_synth_');
    final dbPath = '${tempDir.path}${Platform.pathSeparator}synth.db';
    final service = FfiAudioService(headless: true, databasePath: dbPath);
    try {
      expect(service.isNativeBound, isTrue);
      expect(service.queue, isNotEmpty);
      final demoTrack = service.queue.first;
      expect(demoTrack.filePath, isNull);

      await service.play(track: demoTrack);
      expect(service.lastError, isNull);
      expect(service.currentState.status, PlaybackStatus.playing);

      await Future<void>.delayed(const Duration(milliseconds: 280));
      expect(
        service.currentState.position,
        greaterThan(Duration.zero),
        reason: 'Synth demo track should advance real playback position',
      );

      await service.stop();
      expect(service.currentState.status, PlaybackStatus.stopped);
    } finally {
      service.dispose();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  testWidgets('QuickOutputPopover opens on WASAPI tab when no ASIO device exists', (
    WidgetTester tester,
  ) async {
    final service = _WasapiOnlyMockAudioService();
    addTearDown(service.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuickOutputPopover(
            audioService: service,
            onClose: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('quick_output_dev_wasapi-speakers')), findsOneWidget);
    expect(find.text('目前未偵測到 ASIO 驅動裝置'), findsNothing);
  });
}
