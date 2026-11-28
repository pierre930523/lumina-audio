import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/main.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/signal_path.dart';
import 'package:lumina_app/services/ffi_audio_service.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:material_ui/material_ui.dart';

void _writeSyntheticWav(File file, int sampleRate, int channels, int numFrames) {
  final byteData = ByteData(44 + numFrames * channels * 2);
  void writeAscii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      byteData.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  final blockAlign = channels * 2;
  final byteRate = sampleRate * blockAlign;
  final dataLen = numFrames * blockAlign;

  writeAscii(0, 'RIFF');
  byteData.setUint32(4, 36 + dataLen, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  byteData.setUint32(16, 16, Endian.little);
  byteData.setUint16(20, 1, Endian.little);
  byteData.setUint16(22, channels, Endian.little);
  byteData.setUint32(24, sampleRate, Endian.little);
  byteData.setUint32(28, byteRate, Endian.little);
  byteData.setUint16(32, blockAlign, Endian.little);
  byteData.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  byteData.setUint32(40, dataLen, Endian.little);

  var pos = 44;
  for (var n = 0; n < numFrames; n++) {
    final t = n / sampleRate;
    final sample = ((math.sin(2.0 * math.pi * 440.0 * t)) * 20000).round();
    for (var ch = 0; ch < channels; ch++) {
      byteData.setInt16(pos, sample, Endian.little);
      pos += 2;
    }
  }

  file.writeAsBytesSync(byteData.buffer.asUint8List());
}

void main() {
  testWidgets('LibraryBrowserView scans folder, filters via search, and plays', (
    WidgetTester tester,
  ) async {
    final service = MockAudioService();
    addTearDown(service.dispose);

    await tester.pumpWidget(LuminaApp(audioService: service));
    await tester.pumpAndSettle();

    // Switch to Library browser
    await tester.ensureVisible(find.byKey(const Key('capsule_nav_library')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('capsule_nav_library')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('track_queue_list')), findsOneWidget);
    expect(find.byKey(const Key('scan_directory_input')), findsNothing);
    expect(find.byKey(const Key('queue_track_trk-001')), findsOneWidget);
    expect(find.byKey(const Key('queue_track_trk-002')), findsOneWidget);

    // Search for Money
    await tester.enterText(
      find.byKey(const Key('library_search_input')),
      'Money',
    );
    await tester.pumpAndSettle();
    expect(find.text('Money'), findsWidgets);
    expect(find.byKey(const Key('queue_track_trk-001')), findsNothing);

    // Clear search and navigate into Settings -> Library via shortcut button
    await tester.enterText(
      find.byKey(const Key('library_search_input')),
      '',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('btn_open_library_settings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('library_settings_panel')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('scan_directory_input')),
      r'C:\Music',
    );
    await tester.tap(find.byKey(const Key('btn_scan_directory')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('scan_status_label')), findsOneWidget);
    expect(find.byKey(const Key(r'folder_entry_C:\Music')), findsOneWidget);

    // Verify excluded extension filter & import switches in Library Settings
    await tester.ensureVisible(find.byKey(const Key('switch_import_archives')));
    await tester.tap(find.byKey(const Key('switch_import_archives')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('chk_ext_.dsf')));
    await tester.tap(find.byKey(const Key('chk_ext_.dsf')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('btn_apply_excluded_types')),
    );
    await tester.tap(find.byKey(const Key('btn_apply_excluded_types')));
    await tester.pumpAndSettle();

    // Return to Library and confirm .dsf track is excluded while FLAC track plays
    await tester.ensureVisible(find.byKey(const Key('capsule_nav_library')));
    await tester.tap(find.byKey(const Key('capsule_nav_library')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('queue_track_trk-002')), findsNothing);
    expect(find.byKey(const Key('queue_track_trk-001')), findsOneWidget);

    await tester.tap(find.byKey(const Key('queue_track_trk-001')));
    await tester.pump();
    expect(service.currentState.track?.title, 'Time');
    expect(service.currentState.status, PlaybackStatus.playing);
  });

  test('FfiAudioService scans real WAV into SQLite, searches, plays via Rust, and toggles DSP bypass', () async {
    final tempDir = Directory.systemTemp.createTempSync('lumina_dart_ffi_');
    final albumDir = Directory(
      '${tempDir.path}${Platform.pathSeparator}Pink Floyd${Platform.pathSeparator}Animals',
    )..createSync(recursive: true);
    final wavFile = File('${albumDir.path}${Platform.pathSeparator}01 - Dogs.wav');
    _writeSyntheticWav(wavFile, 48000, 2, 96000);
    final dbPath = '${tempDir.path}${Platform.pathSeparator}ffi_test.db';

    final service = FfiAudioService(headless: true, databasePath: dbPath);
    try {
      expect(service.isNativeBound, isTrue);

      final scannedCount = await service.scanDirectory(tempDir.path);
      expect(scannedCount, 1);
      expect(service.queue.length, 1);
      expect(service.queue.first.title, 'Dogs');
      expect(service.queue.first.artist, 'Pink Floyd');
      expect(service.queue.first.album, 'Animals');
      expect(service.queue.first.filePath, isNotNull);

      final hits = await service.searchLibrary('Dogs');
      expect(hits.length, 1);
      expect(hits.first.id, service.queue.first.id);

      await service.play(track: hits.first);
      expect(service.currentState.status, PlaybackStatus.playing);
      expect(service.currentSignalPath.overallQuality, SignalQuality.enhanced);

      await service.toggleDspBypass();
      expect(service.currentSignalPath.overallQuality, SignalQuality.lossless);

      await service.stop();
      expect(service.currentState.status, PlaybackStatus.stopped);
    } finally {
      service.dispose();
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });
}
