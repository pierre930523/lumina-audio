import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/lyric.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/library_settings_controller.dart';
import 'package:lumina_app/ui/artwork/album_artwork_view.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:lumina_app/ui/lyrics/lyrics_view.dart';
import 'package:lumina_app/ui/mini_player/progress_bar.dart';
import 'package:lumina_app/ui/settings/library_settings_panel.dart';

void main() {
  group('Feature F13: Playback Seeking, Clock & Progress Bar', () {
    test('PlaybackStatus enum maps all 9 lifecycle states to/from codes', () {
      final expectations = {
        0: PlaybackStatus.uninitialized,
        1: PlaybackStatus.stopped,
        2: PlaybackStatus.playing,
        3: PlaybackStatus.paused,
        4: PlaybackStatus.error,
        5: PlaybackStatus.loading,
        6: PlaybackStatus.seeking,
        7: PlaybackStatus.buffering,
        8: PlaybackStatus.ended,
      };

      for (final entry in expectations.entries) {
        expect(PlaybackStatus.fromCode(entry.key), entry.value);
        expect(entry.value.code, entry.key);
      }
      expect(PlaybackStatus.fromCode(999), PlaybackStatus.stopped);
    });

    testWidgets('TrackProgressBar displays position, duration, and toggles remaining time', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TrackProgressBar(
              position: const Duration(minutes: 1, seconds: 15),
              duration: const Duration(minutes: 4, seconds: 0),
              onSeek: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('01:15'), findsOneWidget);
      expect(find.text('04:00'), findsOneWidget);

      // Tap on duration text to toggle remaining time
      await tester.tap(find.byKey(const Key('progress_duration_text')));
      await tester.pump();

      // Remaining duration: 4:00 - 1:15 = 2:45
      expect(find.text('-02:45'), findsOneWidget);

      // Tap again to toggle back to total duration
      await tester.tap(find.byKey(const Key('progress_duration_text')));
      await tester.pump();
      expect(find.text('04:00'), findsOneWidget);
    });

    testWidgets('TrackProgressBar drag triggers preview and commits seek without feedback loop', (
      tester,
    ) async {
      Duration? startedAt;
      Duration? changedTo;
      Duration? committedAt;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: TrackProgressBar(
                position: const Duration(seconds: 30),
                duration: const Duration(seconds: 120),
                onSeek: (pos) => committedAt = pos,
                onChangeStart: (pos) => startedAt = pos,
                onChanged: (pos) => changedTo = pos,
                onChangeEnd: (pos) {},
              ),
            ),
          ),
        ),
      );

      final sliderFinder = find.byKey(const Key('track_progress_slider'));
      expect(sliderFinder, findsOneWidget);

      // Drag the slider from left to right
      final topLeft = tester.getTopLeft(sliderFinder);
      final bottomRight = tester.getBottomRight(sliderFinder);
      final midPoint = Offset(
        (topLeft.dx + bottomRight.dx) / 2,
        (topLeft.dy + bottomRight.dy) / 2,
      );

      final gesture = await tester.startGesture(midPoint);
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();

      expect(startedAt, isNotNull);
      expect(changedTo, isNotNull);

      await gesture.up();
      await tester.pump();

      expect(committedAt, isNotNull);
      expect(committedAt!.inMilliseconds, greaterThan(30000));
    });

    test('togglePlayPause resumes paused tracks at current position instead of 0', () async {
      final service = MockAudioService();
      addTearDown(service.dispose);

      // Initial state is paused at 3 seconds
      expect(service.currentState.status, PlaybackStatus.paused);
      expect(service.currentState.position, const Duration(seconds: 3));

      // togglePlayPause should resume playback
      await service.togglePlayPause();
      expect(service.currentState.status, PlaybackStatus.playing);
      expect(service.currentState.position, const Duration(seconds: 3));

      // togglePlayPause while playing should pause
      await service.togglePlayPause();
      expect(service.currentState.status, PlaybackStatus.paused);
      expect(service.currentState.position, const Duration(seconds: 3));
    });
  });

  group('Feature F11: Album Artwork & Metadata UI', () {
    testWidgets('AlbumArtworkView renders with distinct ValueKey across track switches', (
      tester,
    ) async {
      const trackA = TrackInfo(
        id: 'trk-001',
        title: 'Track A',
        artist: 'Artist A',
        album: 'Album A',
        duration: Duration(minutes: 3),
        format: AudioFormat(codec: AudioCodec.flac, sampleRateHz: 44100, bitDepth: 16, channels: 2),
        artworkCacheKey: 'cache_key_a',
      );

      const trackB = TrackInfo(
        id: 'trk-002',
        title: 'Track B',
        artist: 'Artist B',
        album: 'Album B',
        duration: Duration(minutes: 4),
        format: AudioFormat(codec: AudioCodec.flac, sampleRateHz: 44100, bitDepth: 16, channels: 2),
        artworkCacheKey: 'cache_key_b',
      );

      // Render track A
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AlbumArtworkView(track: trackA, size: 80),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('artwork_container_cache_key_a')), findsOneWidget);
      expect(find.byKey(const ValueKey('artwork_container_cache_key_b')), findsNothing);

      // Switch to track B - ValueKey forces clean rebuild with zero stale residue
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AlbumArtworkView(track: trackB, size: 80),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('artwork_container_cache_key_a')), findsNothing);
      expect(find.byKey(const ValueKey('artwork_container_cache_key_b')), findsOneWidget);
    });

    test('AudioService artwork override & rescan endpoints roundtrip correctly', () async {
      final service = MockAudioService();
      addTearDown(service.dispose);

      // Artwork query
      final initialArt = await service.getArtwork('trk-001');
      expect(initialArt, isNotNull);

      // Set user cover
      final setOk = await service.setUserCover('trk-001', 'C:\\Music\\custom.jpg');
      expect(setOk, isTrue);

      final updatedArt = await service.getArtwork('trk-001');
      expect(updatedArt?['found'], isTrue);
      expect(updatedArt?['cache_path'], 'C:\\Music\\custom.jpg');

      // Clear user cover
      final clearOk = await service.clearUserCover('trk-001');
      expect(clearOk, isTrue);

      // Rescan tags
      final rescan = await service.rescanTags(force: true);
      expect(rescan, isNotNull);
      expect(rescan?['status'], 'ok');
    });

    test('TrackInfo and CanonicalAlbumSummary distinguish Artist vs Album Artist', () {
      const trackWithDistinctArtist = TrackInfo(
        id: 'trk-solo',
        title: 'Solo',
        artist: 'Featured Vocalist',
        albumArtist: 'Main Band',
        album: 'Collaboration Album',
        duration: Duration(minutes: 3),
        format: AudioFormat(codec: AudioCodec.flac, sampleRateHz: 44100, bitDepth: 16, channels: 2),
      );

      expect(trackWithDistinctArtist.hasDistinctAlbumArtist, isTrue);
      expect(trackWithDistinctArtist.effectiveAlbumArtist, 'Main Band');

      const trackSameArtist = TrackInfo(
        id: 'trk-normal',
        title: 'Normal',
        artist: 'Pink Floyd',
        albumArtist: 'Pink Floyd',
        album: 'The Wall',
        duration: Duration(minutes: 3),
        format: AudioFormat(codec: AudioCodec.flac, sampleRateHz: 44100, bitDepth: 16, channels: 2),
      );

      expect(trackSameArtist.hasDistinctAlbumArtist, isFalse);

      final albumSummary = CanonicalAlbumSummary.fromJson({
        'id': 'alb-1',
        'title': 'Test Album',
        'artist_name': 'Various Artists',
        'album_artist': 'Curator Band',
        'cover_url': 'http://example.com/cover.jpg',
      });
      expect(albumSummary.albumArtist, 'Curator Band');
      expect(albumSummary.coverUrl, 'http://example.com/cover.jpg');
    });

    testWidgets('AlbumDetailPage exposes cover controls and LibrarySettingsPanel exposes rescan tags', (
      tester,
    ) async {
      final service = MockAudioService();
      addTearDown(service.dispose);

      // Verify AlbumDetailPage has cover buttons
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AlbumDetailPage(
              albumId: 'alb-dsotm',
              audioService: service,
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('btn_set_album_cover')), findsOneWidget);
      expect(find.byKey(const Key('btn_clear_album_cover')), findsOneWidget);

      // Verify LibrarySettingsPanel has rescan tags button
      final controller = LibrarySettingsController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibrarySettingsPanel(
              audioService: service,
              settingsController: controller,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('btn_rescan_tags')), findsOneWidget);
    });
  });

  group('Feature F12: Lyrics Engine & UI', () {
    testWidgets('LyricsView renders empty state cleanly without sticking in loading', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LyricsView(
              lyrics: [],
              currentPosition: Duration.zero,
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('lyrics_empty_state')), findsOneWidget);
      expect(find.text('尚無歌詞資訊'), findsOneWidget);
      expect(find.byKey(const Key('btn_load_lyrics_file')), findsOneWidget);
    });

    testWidgets('LyricsView renders synchronized lyrics, autoscrolls and handles font/offset adjustments', (
      tester,
    ) async {
      final service = MockAudioService();
      addTearDown(service.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LyricsView(
              lyrics: service.currentLyrics,
              currentPosition: const Duration(seconds: 8),
              onSeek: (pos) {},
            ),
          ),
        ),
      );

      // Check lines rendered
      expect(find.byKey(const Key('lyrics_list_view')), findsOneWidget);
      expect(find.byKey(const Key('lyric_line_0')), findsOneWidget);
      expect(find.byKey(const Key('lyric_line_1')), findsOneWidget);

      // Open lyrics settings toolbar
      await tester.tap(find.byKey(const Key('btn_lyrics_toolbar_toggle')));
      await tester.pumpAndSettle();

      // Test font up
      expect(find.byKey(const Key('btn_lyrics_font_up')), findsOneWidget);
      await tester.tap(find.byKey(const Key('btn_lyrics_font_up')));
      await tester.pumpAndSettle();
      expect(find.text('110%'), findsOneWidget);

      // Test offset adjustment
      expect(find.byKey(const Key('btn_lyrics_offset_plus')), findsOneWidget);
      await tester.tap(find.byKey(const Key('btn_lyrics_offset_plus')));
      await tester.pumpAndSettle();
      expect(find.text('+0.5s'), findsOneWidget);
    });

    testWidgets('LyricsView renders unsynchronized lyrics cleanly', (tester) async {
      const unsyncedLines = [
        LyricLine(start: Duration.zero, end: Duration.zero, text: 'First unsynced line', isSynced: false),
        LyricLine(start: Duration.zero, end: Duration.zero, text: 'Second unsynced line', isSynced: false),
        LyricLine(start: Duration.zero, end: Duration.zero, text: 'Third unsynced line', isSynced: false),
      ];

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LyricsView(
              lyrics: unsyncedLines,
              currentPosition: Duration(seconds: 5),
            ),
          ),
        ),
      );

      expect(find.byKey(const Key('lyrics_list_view')), findsOneWidget);
      expect(find.text('First unsynced line'), findsOneWidget);
      expect(find.text('Second unsynced line'), findsOneWidget);
      expect(find.text('Third unsynced line'), findsOneWidget);
    });

    test('AudioService sets and clears user lyrics override', () async {
      final service = MockAudioService();
      addTearDown(service.dispose);

      final lyricsRes = await service.getLyrics('trk-001');
      expect(lyricsRes?['found'], isTrue);

      final setOk = await service.setUserLyrics('trk-002', 'C:\\Music\\song2.lrc');
      expect(setOk, isTrue);

      final customRes = await service.getLyrics('trk-002');
      expect(customRes?['found'], isTrue);
      expect(customRes?['source'], 'user_file');

      final clearOk = await service.clearUserLyrics('trk-002');
      expect(clearOk, isTrue);
    });
  });
}
