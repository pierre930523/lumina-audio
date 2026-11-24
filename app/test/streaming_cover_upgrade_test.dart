import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/podcast_models.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/playback_persistence_service.dart';
import 'package:lumina_app/services/streaming/streaming_provider.dart';

void main() {
  setUp(() {
    resetCoverUpgradeLogCache();
  });

  group('upgradeStreamingCoverUrl — Google / YouTube Music hosts', () {
    test('upgrades =w*-h* and =s* tokens across all supported Google hosts', () {
      expect(
        upgradeStreamingCoverUrl(
          'https://lh3.googleusercontent.com/abc123=w60-h60-l90-rj',
        ),
        'https://lh3.googleusercontent.com/abc123=w1200-h1200-l90-rj',
      );
      expect(
        upgradeStreamingCoverUrl(
          'https://lh3.googleusercontent.com/abc123=w120-h120-l90-rj',
        ),
        'https://lh3.googleusercontent.com/abc123=w1200-h1200-l90-rj',
      );
      expect(
        upgradeStreamingCoverUrl(
          'https://lh5.googleusercontent.com/abc123=w226-h226-p-l90-rj',
        ),
        'https://lh5.googleusercontent.com/abc123=w1200-h1200-l90-rj',
      );
      expect(
        upgradeStreamingCoverUrl(
          'https://yt3.ggpht.com/channel_art=s120-c',
        ),
        'https://yt3.ggpht.com/channel_art=w1200-h1200-l90-rj',
      );
      expect(
        upgradeStreamingCoverUrl(
          'https://yt3.googleusercontent.com/avatar=s60-c-k-c0x00ffffff-no-rj',
        ),
        'https://yt3.googleusercontent.com/avatar=w1200-h1200-l90-rj',
      );
      expect(
        BaseStreamingProvider.upgradeCoverUrl(
          'https://lh3.googleusercontent.com/abc123=w120-h120-l90-rj',
        ),
        'https://lh3.googleusercontent.com/abc123=w1200-h1200-l90-rj',
      );
    });

    test('normalizes protocol-relative // and preserves trailing query params', () {
      expect(
        upgradeStreamingCoverUrl(
          '  //lh3.googleusercontent.com/proto_rel=w120-h120-l90-rj  ',
        ),
        'https://lh3.googleusercontent.com/proto_rel=w1200-h1200-l90-rj',
      );
      expect(
        upgradeStreamingCoverUrl(
          'https://lh3.googleusercontent.com/with_q=w226-h226-p-l90-rj?foo=bar',
        ),
        'https://lh3.googleusercontent.com/with_q=w1200-h1200-l90-rj?foo=bar',
      );
    });

    test('appends =w1200-h1200-l90-rj on parameterless paths only when safe', () {
      expect(
        upgradeStreamingCoverUrl(
          'https://lh3.googleusercontent.com/a/ACg8ocXYZ_clean_path',
        ),
        'https://lh3.googleusercontent.com/a/ACg8ocXYZ_clean_path=w1200-h1200-l90-rj',
      );
      // Safety guards: do not append if query, fragment, '=', root, or trailing '/'
      expect(
        upgradeStreamingCoverUrl(
          'https://lh3.googleusercontent.com/abc?authuser=0',
        ),
        'https://lh3.googleusercontent.com/abc?authuser=0',
      );
      expect(
        upgradeStreamingCoverUrl(
          'https://lh3.googleusercontent.com/abc#frag',
        ),
        'https://lh3.googleusercontent.com/abc#frag',
      );
      expect(
        upgradeStreamingCoverUrl(
          'https://lh3.googleusercontent.com/abc=p-k-no',
        ),
        'https://lh3.googleusercontent.com/abc=p-k-no',
      );
      expect(
        upgradeStreamingCoverUrl('https://lh3.googleusercontent.com/'),
        'https://lh3.googleusercontent.com/',
      );
      expect(
        upgradeStreamingCoverUrl('https://lh3.googleusercontent.com'),
        'https://lh3.googleusercontent.com',
      );
    });

    test('is idempotent at targetSize and supports scene downsizing to 600 and 300', () {
      const upgraded1200 =
          'https://lh3.googleusercontent.com/img1=w1200-h1200-l90-rj';
      expect(
        upgradeStreamingCoverUrl(upgraded1200),
        upgraded1200,
      );
      expect(
        upgradeStreamingCoverUrl(upgraded1200, targetSize: 600),
        'https://lh3.googleusercontent.com/img1=w600-h600-l90-rj',
      );
      expect(
        upgradeStreamingCoverUrl(upgraded1200, targetSize: 300),
        'https://lh3.googleusercontent.com/img1=w300-h300-l90-rj',
      );
      expect(
        upgradeStreamingCoverUrl(
          'https://lh3.googleusercontent.com/img1=w120-h120-l90-rj',
          targetSize: 0,
        ),
        upgraded1200,
      );
    });

    test('leaves non-Google/non-YT hosts intact and returns null for invalid URLs', () {
      expect(
        upgradeStreamingCoverUrl(
          'https://static.qobuz.com/images/covers/a/b/c_600.jpg',
        ),
        'https://static.qobuz.com/images/covers/a/b/c_600.jpg',
      );
      expect(
        upgradeStreamingCoverUrl(
          'https://resources.tidal.com/images/abcd/1234/640x640.jpg',
        ),
        'https://resources.tidal.com/images/abcd/1234/640x640.jpg',
      );
      expect(upgradeStreamingCoverUrl(null), isNull);
      expect(upgradeStreamingCoverUrl('   '), isNull);
      expect(upgradeStreamingCoverUrl(r'C:\Music\cover.jpg'), isNull);
      expect(upgradeStreamingCoverUrl('/api/v1/artwork/1'), isNull);
      // Verify normalizeStreamingCoverUrl stays pure and does not append/upgrade
      expect(
        normalizeStreamingCoverUrl(
          '  //lh3.googleusercontent.com/abc=w120-h120-l90-rj  ',
        ),
        'https://lh3.googleusercontent.com/abc=w120-h120-l90-rj',
      );
    });
  });

  group('upgradeStreamingCoverUrl — YouTube thumbnail hosts', () {
    test('upgrades default/mq/hq/sd thumbnails on i.ytimg.com and img.youtube.com', () {
      for (final variant in const [
        'default.jpg',
        'mqdefault.jpg',
        'hqdefault.jpg',
        'sddefault.jpg',
      ]) {
        expect(
          upgradeStreamingCoverUrl('https://i.ytimg.com/vi/vid_001/$variant'),
          'https://i.ytimg.com/vi/vid_001/maxresdefault.jpg',
        );
        expect(
          upgradeStreamingCoverUrl(
            'https://img.youtube.com/vi/vid_002/$variant',
          ),
          'https://i.ytimg.com/vi/vid_002/maxresdefault.jpg',
        );
      }

      expect(
        upgradeStreamingCoverUrl(
          'https://i.ytimg.com/vi_webp/vid_webp_1/hqdefault.webp',
        ),
        'https://i.ytimg.com/vi/vid_webp_1/maxresdefault.jpg',
      );
    });

    test('strips sqp/rs query params on low-res and maxresdefault URLs', () {
      expect(
        upgradeStreamingCoverUrl(
          'https://i.ytimg.com/vi/vid_sqp/hqdefault.jpg?sqp=-oaymwEcCPYBEIoB&rs=AOn4CL',
        ),
        'https://i.ytimg.com/vi/vid_sqp/maxresdefault.jpg',
      );
      expect(
        upgradeStreamingCoverUrl(
          'https://i.ytimg.com/vi/vid_max_sqp/maxresdefault.jpg?sqp=-oaymwEm&rs=AOn4CL',
        ),
        'https://i.ytimg.com/vi/vid_max_sqp/maxresdefault.jpg',
      );
      expect(
        upgradeStreamingCoverUrl(
          'https://i.ytimg.com/vi_webp/vid_max_webp/maxresdefault.webp?sqp=1',
        ),
        'https://i.ytimg.com/vi/vid_max_webp/maxresdefault.jpg',
      );
      expect(
        upgradeStreamingCoverUrl(
          'https://i.ytimg.com/vi/vid_clean/maxresdefault.jpg',
        ),
        'https://i.ytimg.com/vi/vid_clean/maxresdefault.jpg',
      );
    });

    test('preserves hq720.jpg, 0.jpg, and /pl_c/... paths untouched', () {
      const hq720 = 'https://i.ytimg.com/vi/aBcDeFgHiJk/hq720.jpg';
      const zero = 'https://i.ytimg.com/vi/opus99/0.jpg';
      const playlistCover =
          'https://i.ytimg.com/pl_c/PL_show_alpha_01/cover_544.jpg';

      expect(upgradeStreamingCoverUrl(hq720), hq720);
      expect(upgradeStreamingCoverUrl(zero), zero);
      expect(upgradeStreamingCoverUrl(playlistCover), playlistCover);
    });
  });

  group('fallbackStreamingCoverUrl', () {
    test('returns normalized originalUrl when distinct from failedUrl', () {
      expect(
        fallbackStreamingCoverUrl(
          'https://i.ytimg.com/vi/vid1/maxresdefault.jpg',
          originalUrl: '  //i.ytimg.com/vi/vid1/hqdefault.jpg?sqp=abc&rs=def  ',
        ),
        'https://i.ytimg.com/vi/vid1/hqdefault.jpg?sqp=abc&rs=def',
      );
      expect(
        fallbackStreamingCoverUrl(
          'https://lh3.googleusercontent.com/a=w1200-h1200-l90-rj',
          originalUrl: 'https://lh3.googleusercontent.com/a=w120-h120-l90-rj',
        ),
        'https://lh3.googleusercontent.com/a=w120-h120-l90-rj',
      );
    });

    test('downgrades pre-upgraded maxresdefault to hqdefault when originalUrl matches or is null', () {
      expect(
        fallbackStreamingCoverUrl(
          'https://i.ytimg.com/vi/vid2/maxresdefault.jpg',
        ),
        'https://i.ytimg.com/vi/vid2/hqdefault.jpg',
      );
      expect(
        fallbackStreamingCoverUrl(
          'https://img.youtube.com/vi_webp/vid3/maxresdefault.webp',
          originalUrl: 'https://img.youtube.com/vi_webp/vid3/maxresdefault.webp',
        ),
        'https://i.ytimg.com/vi/vid3/hqdefault.jpg',
      );
    });

    test('returns null for non-upgraded URLs without a distinct originalUrl', () {
      expect(
        fallbackStreamingCoverUrl(
          'https://lh3.googleusercontent.com/a=w1200-h1200-l90-rj',
        ),
        isNull,
      );
      expect(
        fallbackStreamingCoverUrl(
          'https://i.ytimg.com/vi/vid4/hqdefault.jpg',
          originalUrl: 'https://i.ytimg.com/vi/vid4/hqdefault.jpg',
        ),
        isNull,
      );
      expect(fallbackStreamingCoverUrl(null), isNull);
    });
  });

  group('[CoverUpgrade] logging and deduplication', () {
    test('logs once per unique before->after transition and resets cleanly', () {
      final logs = <String>[];
      final prevDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() {
        debugPrint = prevDebugPrint;
      });

      const beforeYtm =
          'https://lh3.googleusercontent.com/log_test=w120-h120-l90-rj';
      const afterYtm =
          'https://lh3.googleusercontent.com/log_test=w1200-h1200-l90-rj';

      expect(upgradeStreamingCoverUrl(beforeYtm), afterYtm);
      expect(upgradeStreamingCoverUrl(beforeYtm), afterYtm);
      expect(
        logs,
        [
          '[CoverUpgrade] w120-h120 -> w1200-h1200 | $beforeYtm -> $afterYtm',
        ],
      );

      // No-op upgrade must not log
      expect(upgradeStreamingCoverUrl(afterYtm), afterYtm);
      expect(logs.length, 1);

      // Additional label formats
      upgradeStreamingCoverUrl('https://yt3.ggpht.com/ch=s120-c');
      upgradeStreamingCoverUrl('https://lh3.googleusercontent.com/raw_id');
      upgradeStreamingCoverUrl('https://i.ytimg.com/vi/v1/hqdefault.jpg');
      upgradeStreamingCoverUrl(
        'https://i.ytimg.com/vi/v2/maxresdefault.jpg?sqp=abc',
      );
      expect(
        logs[1],
        contains('[CoverUpgrade] s120 -> w1200-h1200 |'),
      );
      expect(
        logs[2],
        contains('[CoverUpgrade] raw -> w1200-h1200 |'),
      );
      expect(
        logs[3],
        contains('[CoverUpgrade] hqdefault.jpg -> maxresdefault.jpg |'),
      );
      expect(
        logs[4],
        contains('[CoverUpgrade] maxresdefault.jpg?sqp -> maxresdefault.jpg |'),
      );

      // Reset cache allows logging again
      resetCoverUpgradeLogCache();
      upgradeStreamingCoverUrl(beforeYtm);
      expect(logs.length, 6);
    });
  });

  group('Model, cache, and persistence hydration upgrades', () {
    test('StreamingAlbum.fromJson and StreamingRecommendations.trackFromJson upgrade cached URLs', () {
      final album = StreamingAlbum.fromJson(<String, dynamic>{
        'id': 'MPRE_cached_1',
        'title': 'Cached Album',
        'artist': 'Artist',
        'cover_url':
            'https://lh3.googleusercontent.com/cached_alb=w120-h120-l90-rj',
        'provider_kind': 'youtube_music',
      });
      expect(
        album.coverUrl,
        'https://lh3.googleusercontent.com/cached_alb=w1200-h1200-l90-rj',
      );

      final track = StreamingRecommendations.trackFromJson(<String, dynamic>{
        'id': 'ytm:vid_cached_1',
        'title': 'Cached Track',
        'artist': 'Artist',
        'album': 'Album',
        'duration_ms': 180000,
        'cover_url':
            'https://i.ytimg.com/vi/vid_cached_1/hqdefault.jpg?sqp=1&rs=2',
        'album_art_url':
            'https://lh3.googleusercontent.com/cached_art=s120-c',
        'provider_name': 'YouTube Music',
      });
      expect(
        track.coverUrl,
        'https://i.ytimg.com/vi/vid_cached_1/maxresdefault.jpg',
      );
      expect(
        track.albumArtUrl,
        'https://lh3.googleusercontent.com/cached_art=w1200-h1200-l90-rj',
      );
    });

    test('PodcastShow.fromJson and PodcastEpisode.fromJson upgrade cover URLs while keeping pl_c and hq720', () {
      final show = PodcastShow.fromJson(<String, dynamic>{
        'id': 'MPSP_1',
        'title': 'Podcast Show',
        'artworkUrl':
            '  https://lh3.googleusercontent.com/pod_show=w120-h120-l90-rj  ',
      });
      expect(
        show.artworkUrl,
        'https://lh3.googleusercontent.com/pod_show=w1200-h1200-l90-rj',
      );

      final plShow = PodcastShow.fromJson(<String, dynamic>{
        'id': 'MPSP_2',
        'title': 'Playlist Cover Show',
        'artworkUrl': 'https://i.ytimg.com/pl_c/PL_pod/cover_544.jpg',
      });
      expect(
        plShow.artworkUrl,
        'https://i.ytimg.com/pl_c/PL_pod/cover_544.jpg',
      );

      final ep = PodcastEpisode.fromJson(<String, dynamic>{
        'videoId': 'epVid123456',
        'title': 'Episode 1',
        'artworkUrl': 'https://i.ytimg.com/vi/epVid123456/hqdefault.jpg',
      });
      expect(
        ep.artworkUrl,
        'https://i.ytimg.com/vi/epVid123456/maxresdefault.jpg',
      );

      final epHq720 = PodcastEpisode.fromJson(<String, dynamic>{
        'videoId': 'epVid789012',
        'title': 'Episode 2',
        'artworkUrl': 'https://i.ytimg.com/vi/epVid789012/hq720.jpg',
      });
      expect(
        epHq720.artworkUrl,
        'https://i.ytimg.com/vi/epVid789012/hq720.jpg',
      );
    });

    test('PlaybackPersistenceService upgrades persisted YTM URLs while preserving local/API paths', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'lumina_cover_persist_test_',
      );
      final stateFile = File(
        '${tempDir.path}${Platform.pathSeparator}playback_state.json',
      );
      final persistence = PlaybackPersistenceService(
        prefsFileOverride: stateFile,
        throttleDuration: const Duration(milliseconds: 50),
      );
      addTearDown(() {
        persistence.dispose();
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      const ytmCoverBefore =
          'https://lh3.googleusercontent.com/persisted_ytm=w120-h120-l90-rj';
      const ytThumbBefore =
          'https://i.ytimg.com/vi/persisted01/hqdefault.jpg?sqp=abc';
      const localCoverPath = r'C:\Music\PersistedAlbum\folder.jpg';
      const localApiArtPath = '/api/v1/artwork/9876';

      stateFile.writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'version': 2,
          'timestamp': 1700000000000,
          'position_ms': 42000,
          'volume': 0.8,
          'is_muted': false,
          'queue_index': 0,
          'track': <String, dynamic>{
            'id': 'ytm:persisted01',
            'title': 'Persisted YTM Track',
            'artist': 'YTM Artist',
            'album': 'YTM Album',
            'duration_ms': 210000,
            'cover_url': ytmCoverBefore,
            'album_art_url': ytThumbBefore,
            'file_path': 'ytm:persisted01',
            'codec': 'opus',
            'sample_rate_hz': 48000,
            'bit_depth': 16,
            'channels': 2,
            'provider_name': 'YouTube Music',
          },
          'queue_tracks': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'ytm:persisted01',
              'title': 'Persisted YTM Track',
              'artist': 'YTM Artist',
              'album': 'YTM Album',
              'duration_ms': 210000,
              'cover_url': ytmCoverBefore,
              'album_art_url': ytThumbBefore,
              'file_path': 'ytm:persisted01',
              'codec': 'opus',
              'sample_rate_hz': 48000,
              'bit_depth': 16,
              'channels': 2,
              'provider_name': 'YouTube Music',
            },
            <String, dynamic>{
              'id': 'local_persisted_unique_1',
              'title': 'Local FLAC Track',
              'artist': 'Local Artist',
              'album': 'Local Album',
              'duration_ms': 300000,
              'cover_url': localCoverPath,
              'album_art_url': localApiArtPath,
              'file_path': r'C:\Music\PersistedAlbum\01.flac',
              'codec': 'flac',
              'sample_rate_hz': 96000,
              'bit_depth': 24,
              'channels': 2,
              'provider_name': 'local',
            },
          ],
        }),
      );

      final mockAudio = MockAudioService();
      addTearDown(mockAudio.dispose);

      final restored = await persistence.restoreSession(mockAudio);
      expect(restored, isTrue);

      final activeTrack = mockAudio.currentState.track;
      expect(activeTrack, isNotNull);
      expect(
        activeTrack!.coverUrl,
        'https://lh3.googleusercontent.com/persisted_ytm=w1200-h1200-l90-rj',
      );
      expect(
        activeTrack.albumArtUrl,
        'https://i.ytimg.com/vi/persisted01/maxresdefault.jpg',
      );

      final restoredLocal = mockAudio.queue.firstWhere(
        (t) => t.id == 'local_persisted_unique_1',
      );
      expect(restoredLocal.coverUrl, localCoverPath);
      expect(restoredLocal.albumArtUrl, localApiArtPath);
    });
  });
}
