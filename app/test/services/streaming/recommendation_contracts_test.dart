import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/recommendation_models.dart';
import 'package:lumina_app/models/stream_source_spec.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/playback_persistence_service.dart';
import 'package:lumina_app/services/recommendation_settings_controller.dart';
import 'package:lumina_app/services/streaming/autoplay_filter.dart';
import 'package:lumina_app/services/streaming/recommendation_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/track_matcher.dart';

const _cdFlac = AudioFormat(
  codec: AudioCodec.flac,
  sampleRateHz: 44100,
  bitDepth: 16,
  channels: 2,
);

const _hiResFlac = AudioFormat(
  codec: AudioCodec.flac,
  sampleRateHz: 96000,
  bitDepth: 24,
  channels: 2,
);

const _mp3High = AudioFormat(
  codec: AudioCodec.mp3,
  sampleRateHz: 44100,
  bitDepth: 16,
  channels: 2,
  bitrateKbps: 320,
);

const _mp3Low = AudioFormat(
  codec: AudioCodec.mp3,
  sampleRateHz: 44100,
  bitDepth: 16,
  channels: 2,
  bitrateKbps: 128,
);

TrackMetadata _meta({
  String providerId = 'qobuz',
  required String trackId,
  String title = 'Song',
  String artist = 'Artist',
  String? primaryArtist,
  String album = 'Album',
  int durationMs = 200000,
  String? isrc,
  String? qualityLabel,
  String? coverUrl,
  AudioFormat format = _cdFlac,
  String? artistId,
  String? filePath,
  String? providerName,
}) {
  return TrackMetadata(
    providerId: providerId,
    trackId: trackId,
    title: title,
    artist: artist,
    primaryArtist: primaryArtist,
    album: album,
    durationMs: durationMs,
    isrc: isrc,
    qualityLabel: qualityLabel,
    coverUrl: coverUrl,
    format: format,
    artistId: artistId,
    filePath: filePath,
    providerName: providerName,
  );
}

class _FakeRecProvider implements RecommendationProvider {
  @override
  String get recommendationProviderId => 'qobuz';

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities.qobuz;

  @override
  Future<List<FeedSection>> getPersonalizedFeed({
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    return const <FeedSection>[];
  }

  @override
  Future<RadioPage> getTrackRadio(
    TrackMetadata seed, {
    int limit = 10,
    String? cursor,
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    return const RadioPage(tracks: <TrackMetadata>[]);
  }

  @override
  Future<TrackMetadata?> matchTrack(
    TrackMatchQuery query, {
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    return null;
  }
}

void main() {
  group('ProviderCapabilities recommendation presets & JSON', () {
    test('presets expose expected recommendation flags', () {
      expect(ProviderCapabilities.youtubeMusic.supportsTrackRadio, isTrue);
      expect(ProviderCapabilities.youtubeMusic.supportsPersonalFeed, isTrue);
      expect(ProviderCapabilities.youtubeMusic.supportsIsrcLookup, isFalse);

      for (final cap in const [
        ProviderCapabilities.tidal,
        ProviderCapabilities.deezer,
        ProviderCapabilities.qobuz,
        ProviderCapabilities.appleMusic,
      ]) {
        expect(cap.supportsTrackRadio, isTrue);
        expect(cap.supportsPersonalFeed, isTrue);
        expect(cap.supportsIsrcLookup, isTrue);
      }

      for (final cap in const [
        ProviderCapabilities.local,
        ProviderCapabilities.podcastRss,
      ]) {
        expect(cap.supportsTrackRadio, isFalse);
        expect(cap.supportsPersonalFeed, isFalse);
        expect(cap.supportsIsrcLookup, isFalse);
      }
    });

    test('JSON roundtrip, legacy defaults, equality and hashCode', () {
      final ytmJson = ProviderCapabilities.youtubeMusic.toJson();
      expect(ytmJson['supports_track_radio'], isTrue);
      expect(ytmJson['supports_personal_feed'], isTrue);
      expect(ytmJson['supports_isrc_lookup'], isFalse);

      final roundTrip = ProviderCapabilities.fromJson(ytmJson);
      expect(roundTrip, equals(ProviderCapabilities.youtubeMusic));
      expect(
        roundTrip.hashCode,
        equals(ProviderCapabilities.youtubeMusic.hashCode),
      );

      final legacy = ProviderCapabilities.fromJson(const <String, dynamic>{
        'supports_l1_url_cache': true,
        'supports_l2_head_cache': true,
        'requires_range_chunking': true,
        'needs_network_epoch_reset': false,
        'default_l1_safety_margin_sec': 60,
      });
      expect(legacy.supportsTrackRadio, isFalse);
      expect(legacy.supportsPersonalFeed, isFalse);
      expect(legacy.supportsIsrcLookup, isFalse);
      expect(legacy, isNot(equals(ProviderCapabilities.qobuz)));
    });
  });

  group('TrackInfo extended fields & PlaybackPersistenceService', () {
    test('copyWith and persistence preserve isrc, qualityLabel, artistId', () async {
      final dir = await Directory.systemTemp.createTemp('lumina_rec_persist_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final file = File('${dir.path}${Platform.pathSeparator}state.json');
      final persistence = PlaybackPersistenceService(prefsFileOverride: file);
      addTearDown(persistence.dispose);

      const base = TrackInfo(
        id: 'tidal:999',
        title: 'Digital Love',
        artist: 'Daft Punk',
        album: 'Discovery',
        duration: Duration(seconds: 301),
        format: _hiResFlac,
        providerName: 'Tidal',
        isrc: 'GBDUW0000059',
        qualityLabel: 'HI_RES_LOSSLESS',
        artistId: 'artist-daft-punk',
      );

      final updated = base.copyWith(qualityLabel: 'MAX_24_96');
      expect(updated.isrc, equals('GBDUW0000059'));
      expect(updated.qualityLabel, equals('MAX_24_96'));
      expect(updated.artistId, equals('artist-daft-punk'));

      final snap = persistence.buildSnapshot(
        state: PlaybackState(
          status: PlaybackStatus.paused,
          track: updated,
          position: const Duration(seconds: 40),
        ),
        queue: [updated],
        queueIndex: 0,
      );
      await persistence.saveImmediate(snap);

      final audio = MockAudioService();
      addTearDown(audio.dispose);
      final restored = await persistence.restoreSession(audio);
      expect(restored, isTrue);
      expect(audio.currentState.track?.isrc, equals('GBDUW0000059'));
      expect(audio.currentState.track?.qualityLabel, equals('MAX_24_96'));
      expect(audio.currentState.track?.artistId, equals('artist-daft-punk'));
    });

    test('PlaybackPersistenceService restores legacy snapshot missing new fields', () async {
      final dir = await Directory.systemTemp.createTemp('lumina_rec_legacy_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final file = File('${dir.path}${Platform.pathSeparator}state.json');
      await file.writeAsString(
        jsonEncode({
          'version': 2,
          'position_ms': 15000,
          'volume': 0.8,
          'is_muted': false,
          'track': {
            'id': 'qobuz:1234',
            'title': 'Legacy Track',
            'artist': 'Legacy Artist',
            'album': 'Legacy Album',
            'duration_ms': 180000,
            'codec': 'flac',
            'sample_rate_hz': 44100,
            'bit_depth': 16,
            'channels': 2,
            'provider_name': 'Qobuz',
          },
          'queue_index': 0,
          'queue_tracks': [],
        }),
      );

      final persistence = PlaybackPersistenceService(prefsFileOverride: file);
      addTearDown(persistence.dispose);
      final audio = MockAudioService();
      addTearDown(audio.dispose);

      expect(await persistence.restoreSession(audio), isTrue);
      expect(audio.currentState.track?.title, equals('Legacy Track'));
      expect(audio.currentState.track?.isrc, isNull);
      expect(audio.currentState.track?.qualityLabel, isNull);
      expect(audio.currentState.track?.artistId, isNull);
    });
  });

  group('TrackMetadata, RecommendationModels & RecommendationProvider', () {
    test('fromTrackInfo infers providerId across local, ID prefixes, and providerName', () {
      final localMeta = TrackMetadata.fromTrackInfo(
        const TrackInfo(
          id: 'trk-local-1',
          title: 'Local FLAC',
          artist: 'Daft Punk feat. Julian Casablancas',
          album: 'RAM',
          duration: Duration(seconds: 336),
          filePath: 'D:/Music/InstantCrush.flac',
          format: _hiResFlac,
          providerName: 'Qobuz Hi-Res',
          isrc: 'USQX91300108',
          qualityLabel: '24-bit / 96 kHz',
          artistId: 'art-1',
        ),
      );
      expect(localMeta.providerId, equals('local'));
      expect(localMeta.trackId, equals('trk-local-1'));
      expect(localMeta.primaryArtist, equals('Daft Punk'));
      expect(localMeta.toTrackInfo().id, equals('trk-local-1'));
      expect(localMeta.toTrackInfo().filePath, equals('D:/Music/InstantCrush.flac'));

      final cases = <({String id, String expectedProvider, String expectedTrackId, String expectedRoundtripId})>[
        (
          id: 'ytm:dQw4w9WgXcQ',
          expectedProvider: 'youtube_music',
          expectedTrackId: 'dQw4w9WgXcQ',
          expectedRoundtripId: 'ytm:dQw4w9WgXcQ',
        ),
        (
          id: 'youtube_music:abc123',
          expectedProvider: 'youtube_music',
          expectedTrackId: 'abc123',
          expectedRoundtripId: 'ytm:abc123',
        ),
        (
          id: 'streaming:youtube_music:xyz789',
          expectedProvider: 'youtube_music',
          expectedTrackId: 'xyz789',
          expectedRoundtripId: 'ytm:xyz789',
        ),
        (
          id: 'tidal:888999',
          expectedProvider: 'tidal',
          expectedTrackId: '888999',
          expectedRoundtripId: 'tidal:888999',
        ),
        (
          id: 'qobuz:555666',
          expectedProvider: 'qobuz',
          expectedTrackId: '555666',
          expectedRoundtripId: 'qobuz:555666',
        ),
        (
          id: 'deezer:3135556',
          expectedProvider: 'deezer',
          expectedTrackId: '3135556',
          expectedRoundtripId: 'deezer:3135556',
        ),
        (
          id: 'apple:1440857781',
          expectedProvider: 'apple_music',
          expectedTrackId: '1440857781',
          expectedRoundtripId: 'apple:1440857781',
        ),
      ];

      for (final c in cases) {
        final track = TrackInfo(
          id: c.id,
          title: 'Track',
          artist: 'Artist',
          album: 'Album',
          duration: const Duration(minutes: 3),
          format: _cdFlac,
          coverUrl: 'https://cdn.example.com/art.jpg',
          providerName: 'Streaming',
          isrc: 'USRC17607839',
          qualityLabel: 'LOSSLESS',
          artistId: 'artist-42',
        );
        final meta = TrackMetadata.fromTrackInfo(track);
        expect(meta.providerId, equals(c.expectedProvider));
        expect(meta.trackId, equals(c.expectedTrackId));

        final back = meta.toTrackInfo();
        expect(back.id, equals(c.expectedRoundtripId));
        expect(back.isrc, equals('USRC17607839'));
        expect(back.qualityLabel, equals('LOSSLESS'));
        expect(back.artistId, equals('artist-42'));
        expect(back.coverUrl, equals('https://cdn.example.com/art.jpg'));
        expect(back.providerName, equals('Streaming'));
      }

      final fallback = TrackMetadata.fromTrackInfo(
        const TrackInfo(
          id: 'raw_id_1',
          title: 'Track',
          artist: 'Artist',
          album: 'Album',
          duration: Duration(minutes: 3),
          format: _cdFlac,
          providerName: 'CustomProvider',
        ),
      );
      expect(fallback.providerId, equals('CustomProvider'));

      final overridden = TrackMetadata.fromTrackInfo(
        const TrackInfo(
          id: 'raw_id_2',
          title: 'Track',
          artist: 'Artist',
          album: 'Album',
          duration: Duration(minutes: 3),
          format: _cdFlac,
          providerName: 'CustomProvider',
        ),
        providerIdOverride: 'deezer',
      );
      expect(overridden.providerId, equals('deezer'));
    });

    test('RecommendationProvider contract & RecError formatting work cleanly', () async {
      final provider = _FakeRecProvider();
      expect(provider.recommendationProviderId, equals('qobuz'));
      expect(provider.capabilities.supportsTrackRadio, isTrue);

      final token = CancellationToken()..cancel();
      await expectLater(
        provider.getPersonalizedFeed(cancel: token),
        throwsA(isA<StreamingException>()),
      );

      const err = RecError(
        kind: RecErrorKind.rateLimited,
        message: 'Too many requests',
        statusCode: 429,
        providerId: 'listenbrainz',
      );
      expect(err.toString(), contains('rateLimited'));
      expect(err.toString(), contains('429'));
      expect(err.toString(), contains('listenbrainz'));
    });
  });

  group('TrackMatcher', () {
    test('normalizes ISRC, full-width characters, titles, and primary artists', () {
      expect(TrackMatcher.normalizeIsrc(' us-rc1-76-07839 '), equals('USRC17607839'));
      expect(TrackMatcher.normalizeIsrc('  ---  '), isNull);
      expect(TrackMatcher.normalizeIsrc(null), isNull);

      expect(
        TrackMatcher.normalizeWidthAndCase('Ｈｅｌｌｏ　Ｗｏｒｌｄ！'),
        equals('hello world!'),
      );
      expect(
        TrackMatcher.normalizeTitleForMatching(
          'Ｓｏｎｇ　Ｔｉｔｌｅ　（２０２３　Ｒｅｍａｓｔｅｒ）',
        ),
        equals('song title'),
      );
      expect(
        TrackMatcher.normalizeTitleForMatching(
          'Bohemian Rhapsody (Remastered 2011) [Deluxe Edition] (Official Audio) (Explicit)',
        ),
        equals('bohemian rhapsody'),
      );
      expect(
        TrackMatcher.normalizeTitleForMatching(
          'Hotel California - Remastered 2013',
        ),
        equals('hotel california'),
      );
      expect(
        TrackMatcher.normalizeTitleForMatching(
          'Get Lucky (feat. Pharrell Williams) (Official Video) (Clean)',
        ),
        equals('get lucky'),
      );

      expect(
        TrackMatcher.extractPrimaryArtist('Daft Punk feat. Pharrell Williams'),
        equals('daft punk'),
      );
      expect(
        TrackMatcher.extractPrimaryArtist('Daft Punk (ft. Pharrell Williams)'),
        equals('daft punk'),
      );
      expect(
        TrackMatcher.extractPrimaryArtist('Artist A featuring Artist B & Artist C'),
        equals('artist a'),
      );
      expect(TrackMatcher.extractPrimaryArtist('Artist A & Artist B'), equals('artist a'));
      expect(TrackMatcher.extractPrimaryArtist('Artist A, Artist B'), equals('artist a'));
      expect(TrackMatcher.extractPrimaryArtist('Artist A × Artist B'), equals('artist a'));
      expect(TrackMatcher.extractPrimaryArtist('Artist A · Artist B'), equals('artist a'));
      expect(TrackMatcher.extractPrimaryArtist('Artist A; Artist B'), equals('artist a'));
      expect(TrackMatcher.extractPrimaryArtist('Artist A x Artist B'), equals('artist a'));

      // Normal band names should NOT be split unnecessarily.
      expect(TrackMatcher.extractPrimaryArtist('Lil Nas X'), equals('lil nas x'));
      expect(TrackMatcher.extractPrimaryArtist('AC/DC'), equals('ac/dc'));
      expect(
        TrackMatcher.extractPrimaryArtist('Of Monsters and Men'),
        equals('of monsters and men'),
      );
      expect(TrackMatcher.extractPrimaryArtist('Jay-Z'), equals('jay-z'));
    });

    test('scoreMatch handles exact ISRC, duration delta > 5000ms rejection, and fuzzy match', () {
      const query = TrackMatchQuery(
        isrc: 'US-RC1-76-07839',
        title: 'Get Lucky (feat. Pharrell Williams)',
        artist: 'Daft Punk',
        durationMs: 248000,
      );

      // Exact normalized ISRC matches 1.0 even if title/duration differ slightly.
      final isrcHit = _meta(
        trackId: 't1',
        title: 'Different Subtitle',
        artist: 'Daft Punk',
        durationMs: 260000,
        isrc: 'usrc17607839',
      );
      expect(TrackMatcher.scoreMatch(query, isrcHit), equals(1.0));

      // Without matching ISRC, duration delta > 5000ms is rejected.
      const noIsrcQuery = TrackMatchQuery(
        title: 'Get Lucky',
        artist: 'Daft Punk',
        durationMs: 248000,
      );
      final tooLong = _meta(
        trackId: 't2',
        title: 'Get Lucky',
        artist: 'Daft Punk',
        durationMs: 253001,
      );
      expect(TrackMatcher.scoreMatch(noIsrcQuery, tooLong), isNull);

      // Within 5000ms passes.
      final withinDelta = _meta(
        trackId: 't3',
        title: 'Get Lucky - Remastered 2023',
        artist: 'Daft Punk feat. Pharrell Williams',
        durationMs: 253000,
      );
      final score = TrackMatcher.scoreMatch(noIsrcQuery, withinDelta);
      expect(score, isNotNull);
      expect(score!, greaterThanOrEqualTo(0.80));

      // Distinct track number is rejected.
      final wrongTrack = _meta(
        trackId: 't4',
        title: 'Track 2',
        artist: 'Artist B',
        durationMs: 248000,
      );
      expect(
        TrackMatcher.scoreMatch(
          const TrackMatchQuery(title: 'Track 1', artist: 'Artist A', durationMs: 248000),
          wrongTrack,
        ),
        isNull,
      );
    });

    test('qualityRank & selectBestMatch prefer ISRC first, then score, then highest quality', () {
      final lowLossy = _meta(providerId: 'youtube_music', trackId: '1', format: _mp3Low);
      final highLossy = _meta(providerId: 'youtube_music', trackId: '2', format: _mp3High);
      final streamLossless = _meta(providerId: 'tidal', trackId: '3', format: _cdFlac);
      final localLossless = _meta(
        providerId: 'local',
        trackId: '4',
        filePath: 'D:/Music/song.flac',
        format: _cdFlac,
      );
      final hiRes = _meta(
        providerId: 'qobuz',
        trackId: '5',
        qualityLabel: 'HI_RES_LOSSLESS',
        format: _hiResFlac,
      );

      expect(
        TrackMatcher.qualityRank(hiRes),
        greaterThan(TrackMatcher.qualityRank(localLossless)),
      );
      expect(
        TrackMatcher.qualityRank(localLossless),
        greaterThan(TrackMatcher.qualityRank(streamLossless)),
      );
      expect(
        TrackMatcher.qualityRank(streamLossless),
        greaterThan(TrackMatcher.qualityRank(highLossy)),
      );
      expect(
        TrackMatcher.qualityRank(highLossy),
        greaterThan(TrackMatcher.qualityRank(lowLossy)),
      );

      // Exact ISRC match beats non-ISRC higher-quality candidate.
      const q = TrackMatchQuery(
        isrc: 'GBAYE0601498',
        title: 'Starlight',
        artist: 'Muse',
        durationMs: 240000,
      );
      final best = TrackMatcher.selectBestMatch(q, [
        hiRes.copyWith(title: 'Starlight', artist: 'Muse', durationMs: 240000, isrc: null),
        streamLossless.copyWith(
          trackId: 'isrc-cd',
          title: 'Starlight',
          artist: 'Muse',
          durationMs: 240000,
          isrc: 'GB-AYE-06-01498',
        ),
      ]);
      expect(best?.trackId, equals('isrc-cd'));

      // Among equal-score non-ISRC matches, highest quality wins.
      const qNoIsrc = TrackMatchQuery(
        title: 'Starlight',
        artist: 'Muse',
        durationMs: 240000,
      );
      final bestQuality = TrackMatcher.selectBestMatch(qNoIsrc, [
        highLossy.copyWith(trackId: 'yt', title: 'Starlight', artist: 'Muse', durationMs: 240000),
        localLossless.copyWith(trackId: 'loc', title: 'Starlight', artist: 'Muse', durationMs: 240000),
        hiRes.copyWith(trackId: 'qb', title: 'Starlight', artist: 'Muse', durationMs: 240000),
      ]);
      expect(bestQuality?.trackId, equals('qb'));
    });
  });

  group('AutoplayFilter, RecentHistoryWindow & EffectiveSeedPool', () {
    test('RecentHistoryWindow enforces 50-track capacity & 3-layer deduplication', () {
      final window = RecentHistoryWindow(maxSize: 50);
      final firstTrack = _meta(
        providerId: 'tidal',
        trackId: 'track-0',
        title: 'First Song (Remastered 2020)',
        artist: 'First Artist feat. Guest',
        isrc: 'US-ABC-20-00001',
      );
      window.record(firstTrack);

      // Layer 1: same (providerId, trackId)
      expect(
        window.contains(_meta(providerId: 'tidal', trackId: 'track-0', title: 'Other', artist: 'Other')),
        isTrue,
      );
      // Layer 2: same normalized ISRC across different provider
      expect(
        window.contains(_meta(providerId: 'qobuz', trackId: 'q-999', title: 'Other', artist: 'Other', isrc: 'usabc2000001')),
        isTrue,
      );
      // Layer 3: same normalized title + primary artist across different provider & no ISRC
      expect(
        window.contains(_meta(providerId: 'youtube_music', trackId: 'yt-1', title: 'First Song', artist: 'First Artist')),
        isTrue,
      );

      // Fill 50 more distinct tracks -> evicts firstTrack.
      for (var i = 1; i <= 50; i++) {
        window.record(_meta(
          providerId: 'tidal',
          trackId: 'track-$i',
          title: 'Song $i',
          artist: 'Artist $i',
          isrc: 'ISRC$i',
        ));
      }
      expect(window.length, equals(50));
      expect(window.contains(firstTrack), isFalse);
    });

    test('variant filter rejects unwanted tags without false positives on Alive/Deliver', () {
      // False-positive safety checks
      expect(AutoplayFilter.isDisallowedVariant('Alive', seedTitle: 'Seed'), isFalse);
      expect(AutoplayFilter.isDisallowedVariant('Stayin Alive', seedTitle: 'Seed'), isFalse);
      expect(AutoplayFilter.isDisallowedVariant('Deliver Us', seedTitle: 'Seed'), isFalse);
      expect(AutoplayFilter.isDisallowedVariant('Live Forever', seedTitle: 'Seed'), isFalse);
      expect(AutoplayFilter.isDisallowedVariant('Slow Dancing', seedTitle: 'Seed'), isFalse);

      // Variant tags rejected when seed doesn't have them
      for (final variant in [
        'Song (Live)',
        'Song [Live at Budokan]',
        'Song - Live',
        'Song (Karaoke Version)',
        'Song [Instrumental]',
        'Song (Slowed + Reverb)',
        'Song [Sped Up]',
        'Song - Nightcore',
        'Song (8D Audio)',
        'Song [8D]',
      ]) {
        expect(
          AutoplayFilter.isDisallowedVariant(variant, seedTitle: 'Song'),
          isTrue,
          reason: '$variant should be disallowed for studio seed',
        );
      }

      // Allowed if seed itself has the matching variant tag
      expect(
        AutoplayFilter.isDisallowedVariant('Other Song (Live at Tokyo)', seedTitle: 'Seed (Live)'),
        isFalse,
      );
      expect(
        AutoplayFilter.isDisallowedVariant('Other Song (Karaoke)', seedTitle: 'Seed (Live)'),
        isTrue,
      );
    });

    test('filterCandidates enforces 3-layer dedup, variants, and 3-consecutive artist cooldown', () {
      final filter = AutoplayFilter();
      final now = DateTime.utc(2026, 11, 24, 12, 0);
      final seed = _meta(providerId: 'qobuz', trackId: 's0', title: 'Seed Song', artist: 'Seed Artist');
      filter.recentHistory.record(
        _meta(providerId: 'tidal', trackId: 'hist-1', title: 'Played Song', artist: 'Played Artist', isrc: 'HIST1'),
      );

      final activeTail = [
        _meta(providerId: 'qobuz', trackId: 'tail-1', title: 'Tail 1', artist: 'Artist Alpha'),
        _meta(providerId: 'qobuz', trackId: 'tail-2', title: 'Tail 2', artist: 'Artist Beta'),
      ];

      final candidates = [
        // Duplicate via history ISRC
        _meta(providerId: 'qobuz', trackId: 'c1', title: 'Played Alt', artist: 'Other', isrc: 'hist-1'),
        // Duplicate via activeQueueTail title+artist
        _meta(providerId: 'deezer', trackId: 'c2', title: 'Tail 1 (Remastered 2023)', artist: 'Artist Alpha feat. Someone'),
        // Disallowed variant
        _meta(providerId: 'qobuz', trackId: 'c3', title: 'Fresh (Nightcore)', artist: 'Artist Gamma'),
        // Blocked initially by activeQueueTail window [Alpha, Beta]
        _meta(providerId: 'qobuz', trackId: 'c4', title: 'Alpha Next', artist: 'Artist Alpha'),
        _meta(providerId: 'qobuz', trackId: 'c5', title: 'Beta Next', artist: 'Artist Beta'),
        // Eligible 1st pick -> Gamma (window becomes [Beta, Gamma])
        _meta(providerId: 'qobuz', trackId: 'c6', title: 'Gamma Track', artist: 'Artist Gamma'),
        // Duplicate within same candidate batch
        _meta(providerId: 'tidal', trackId: 'c6-dup', title: 'Gamma Track', artist: 'Artist Gamma'),
        // Eligible 3rd pick -> Delta
        _meta(providerId: 'qobuz', trackId: 'c7', title: 'Delta Track', artist: 'Artist Delta'),
      ];

      final filtered = filter.filterCandidates(
        candidates: candidates,
        seed: seed,
        activeQueueTail: activeTail,
        now: now,
        limit: 4,
      );

      // Sequence after [Alpha, Beta] must pick Gamma first, then Alpha (now allowed!),
      // then Beta (now allowed!), then Delta -> [c6, c4, c5, c7].
      expect(
        filtered.map((t) => t.trackId).toList(),
        equals(['c6', 'c4', 'c5', 'c7']),
      );
    });

    test('EffectiveSeedPool qualifies >=45s or >=60%, rotates last 3, and enforces 30m quick-skip cooldown', () {
      expect(
        EffectiveSeedPool.isQualifiedSeed(const Duration(seconds: 45), const Duration(minutes: 5)),
        isTrue,
      );
      expect(
        EffectiveSeedPool.isQualifiedSeed(const Duration(seconds: 30), const Duration(seconds: 50)),
        isTrue, // 60%
      );
      expect(
        EffectiveSeedPool.isQualifiedSeed(const Duration(seconds: 44), const Duration(minutes: 5)),
        isFalse,
      );
      expect(
        EffectiveSeedPool.isQualifiedSeed(const Duration(seconds: 9), const Duration(seconds: 60)),
        isFalse,
      );

      final pool = EffectiveSeedPool();
      final t0 = DateTime.utc(2026, 11, 24, 12, 0);

      // Quick-skip auto track (< 10s): never enters seed pool, blocks fallback, triggers 30m artist downrank.
      final skippedAuto = _meta(
        trackId: 'auto-bad',
        title: 'Skip Me',
        artist: 'Disliked Artist feat. Guest',
      );
      pool.recordQuickSkip(skippedAuto, t0);
      expect(pool.isEmpty, isTrue);
      expect(pool.nextSeedForRefill(fallbackSeed: skippedAuto), isNull);
      expect(pool.isArtistDownranked('Disliked Artist', t0.add(const Duration(minutes: 29))), isTrue);
      expect(pool.isArtistDownranked('Disliked Artist', t0.add(const Duration(minutes: 30))), isFalse);

      // Fallback works when pool is empty and track was not quick-skipped.
      final manualFallback = _meta(trackId: 'manual-0', title: 'Manual', artist: 'Manual Artist');
      expect(pool.nextSeedForRefill(fallbackSeed: manualFallback), equals(manualFallback));

      // Add 5 qualified seeds; pool keeps newest 5 and rotates newest 3.
      for (var i = 1; i <= 5; i++) {
        pool.recordQualifiedSeed(_meta(trackId: 'seed-$i', title: 'Seed $i', artist: 'Artist $i'));
      }
      expect(pool.length, equals(5));
      expect(pool.seeds.first.trackId, equals('seed-1'));

      final rotated = [
        pool.nextSeedForRefill()?.trackId,
        pool.nextSeedForRefill()?.trackId,
        pool.nextSeedForRefill()?.trackId,
        pool.nextSeedForRefill()?.trackId,
      ];
      expect(rotated, equals(['seed-5', 'seed-4', 'seed-3', 'seed-5']));

      // AutoplayFilter excludes downranked artist for 30 minutes, then allows again.
      final filter = AutoplayFilter(seedPool: pool);
      final badCandidate = _meta(trackId: 'cand-bad', title: 'Another Song', artist: 'Disliked Artist');
      final goodCandidate = _meta(trackId: 'cand-good', title: 'Good Song', artist: 'Good Artist');
      final duringCooldown = filter.filterCandidates(
        candidates: [badCandidate, goodCandidate],
        seed: manualFallback,
        activeQueueTail: const [],
        now: t0.add(const Duration(minutes: 10)),
      );
      expect(duringCooldown.map((t) => t.trackId), equals(['cand-good']));

      final afterCooldown = filter.filterCandidates(
        candidates: [badCandidate, goodCandidate],
        seed: manualFallback,
        activeQueueTail: const [],
        now: t0.add(const Duration(minutes: 31)),
      );
      expect(afterCooldown.map((t) => t.trackId), equals(['cand-bad', 'cand-good']));
    });
  });

  group('RecommendationSettingsController', () {
    test('defaults, JSON persistence, secure Last.fm key isolation, and priority reordering', () async {
      final dir = await Directory.systemTemp.createTemp('lumina_rec_settings_');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final prefsFile = File('${dir.path}${Platform.pathSeparator}recommendation_prefs.json');
      final credStore = MemorySecureCredentialStore();

      final ctrl = RecommendationSettingsController(
        prefsFileOverride: prefsFile,
        credentialStore: credStore,
      );

      expect(ctrl.autoplayEnabled, isTrue);
      expect(ctrl.crossPlatformRoutingEnabled, isTrue);
      expect(
        ctrl.platformPriority,
        equals(const ['local', 'tidal', 'qobuz', 'deezer', 'youtube_music']),
      );
      expect(ctrl.listenBrainzEnabled, isTrue);
      expect(ctrl.lastFmApiKey, isEmpty);

      var notifications = 0;
      ctrl.addListener(() => notifications++);

      await ctrl.setAutoplayEnabled(false);
      await ctrl.setCrossPlatformRoutingEnabled(false);
      await ctrl.movePlatformPriority(2, 0); // move 'qobuz' to index 0
      expect(
        ctrl.platformPriority,
        equals(const ['qobuz', 'local', 'tidal', 'deezer', 'youtube_music']),
      );
      await ctrl.setListenBrainzEnabled(false);
      await ctrl.setLastFmApiKey('  lfm_secret_123  ');
      expect(ctrl.lastFmApiKey, equals('lfm_secret_123'));
      expect(notifications, equals(5));

      // API key is stored in SecureCredentialStore, never plaintext in prefs JSON.
      expect(
        await credStore.read(RecommendationSettingsController.lastFmApiKeyCredentialKey),
        equals('lfm_secret_123'),
      );
      final rawJson = await prefsFile.readAsString();
      expect(rawJson, isNot(contains('lfm_secret_123')));

      // Reload into a fresh controller instance.
      final reloaded = RecommendationSettingsController(
        prefsFileOverride: prefsFile,
        credentialStore: credStore,
      );
      await reloaded.load();
      expect(reloaded.autoplayEnabled, isFalse);
      expect(reloaded.crossPlatformRoutingEnabled, isFalse);
      expect(
        reloaded.platformPriority,
        equals(const ['qobuz', 'local', 'tidal', 'deezer', 'youtube_music']),
      );
      expect(reloaded.listenBrainzEnabled, isFalse);
      expect(reloaded.lastFmApiKey, equals('lfm_secret_123'));

      await reloaded.resetPlatformPriority();
      expect(
        reloaded.platformPriority,
        equals(RecommendationSettingsController.defaultPlatformPriority),
      );
      await reloaded.setPlatformPriority(const ['tidal', 'qobuz']);
      expect(reloaded.platformPriority, equals(const ['tidal', 'qobuz']));

      // Safely handles null credentialStore and FLUTTER_TEST default (no prefsFileOverride).
      final noStoreCtrl = RecommendationSettingsController();
      await noStoreCtrl.load();
      await noStoreCtrl.setLastFmApiKey('ephemeral_key');
      expect(noStoreCtrl.lastFmApiKey, equals('ephemeral_key'));
    });
  });
}
