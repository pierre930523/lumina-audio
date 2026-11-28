import 'dart:io';

import '../../../models/audio_format.dart';
import '../../../models/recommendation_models.dart';
import '../../../models/stream_source_spec.dart';
import '../../../models/streaming_models.dart';
import '../recommendation_provider.dart';
import '../streaming_provider.dart';
import '../track_matcher.dart';

/// External metadata-only Track Radio provider powered by Last.fm's public
/// similarity endpoints (`track.getSimilar`, `artist.getSimilar`,
/// `artist.getTopTracks`).
class LastFmRecommendationProvider implements RecommendationProvider {
  final String Function() apiKeyProvider;
  final String baseUrl;
  final StreamingHttpClient http;

  LastFmRecommendationProvider({
    required this.apiKeyProvider,
    this.baseUrl = 'https://ws.audioscrobbler.com/2.0/',
    StreamingHttpClient? http,
    HttpClient Function()? httpClientFactory,
  }) : http = http ?? StreamingHttpClient(clientFactory: httpClientFactory);

  @override
  String get recommendationProviderId => 'lastfm';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
    supportsTrackRadio: true,
    supportsPersonalFeed: false,
    supportsIsrcLookup: false,
  );

  @override
  Future<List<FeedSection>> getPersonalizedFeed({
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    return const <FeedSection>[];
  }

  @override
  Future<TrackMetadata?> matchTrack(
    TrackMatchQuery query, {
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    return null;
  }

  @override
  Future<RadioPage> getTrackRadio(
    TrackMetadata seed, {
    int limit = 10,
    String? cursor,
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    final apiKey = apiKeyProvider().trim();
    if (apiKey.isEmpty) {
      return const RadioPage(
        tracks: <TrackMetadata>[],
        sourceLabel: 'Last.fm',
      );
    }

    final effectiveLimit = limit > 0 ? limit : 10;
    final offset = int.tryParse(cursor?.trim() ?? '') ?? 0;
    final safeOffset = offset < 0 ? 0 : offset;

    final seedArtist = seed.primaryArtist.trim().isNotEmpty
        ? seed.primaryArtist.trim()
        : seed.artist.trim();
    final seedTitle = seed.title.trim();
    if (seedArtist.isEmpty || seedTitle.isEmpty) {
      return const RadioPage(
        tracks: <TrackMetadata>[],
        sourceLabel: 'Last.fm',
      );
    }

    final seedNormTitle = TrackMatcher.normalizeTitleForMatching(seedTitle);
    final seedNormArtist = TrackMatcher.normalizeArtistForMatching(seedArtist);

    final collected = <TrackMetadata>[];
    final seenKeys = <String>{};

    void addItem(Map<String, dynamic> raw) {
      final parsed = _parseLastFmTrack(raw);
      if (parsed == null) return;
      final normTitle = TrackMatcher.normalizeTitleForMatching(parsed.title);
      final normArtist =
          TrackMatcher.normalizeArtistForMatching(parsed.primaryArtist);
      if (normTitle == seedNormTitle && normArtist == seedNormArtist) {
        return;
      }
      final dedupKey = '$normArtist::$normTitle';
      if (seenKeys.add(dedupKey)) {
        collected.add(parsed);
      }
    }

    final requestLimit = safeOffset + effectiveLimit + 5;
    final similarJson = await _callApi(<String, String>{
      'method': 'track.getSimilar',
      'artist': seedArtist,
      'track': seedTitle,
      'autocorrect': '1',
      'limit': '$requestLimit',
      'api_key': apiKey,
      'format': 'json',
    }, cancel: cancel);

    if (similarJson != null) {
      final similarTracksObj = similarJson['similartracks'];
      final rawTracks = similarTracksObj is Map
          ? similarTracksObj['track']
          : similarJson['track'];
      for (final map in _asMapList(rawTracks)) {
        addItem(map);
      }
    }

    if (collected.length < safeOffset + effectiveLimit) {
      final similarArtistsJson = await _callApi(<String, String>{
        'method': 'artist.getSimilar',
        'artist': seedArtist,
        'autocorrect': '1',
        'limit': '4',
        'api_key': apiKey,
        'format': 'json',
      }, cancel: cancel);

      if (similarArtistsJson != null) {
        final simArtistsObj = similarArtistsJson['similarartists'];
        final artistList = _asMapList(
          simArtistsObj is Map
              ? simArtistsObj['artist']
              : similarArtistsJson['artist'],
        );
        for (final artistMap in artistList.take(3)) {
          if (collected.length >= safeOffset + effectiveLimit) break;
          final simArtistName = artistMap['name']?.toString().trim() ?? '';
          if (simArtistName.isEmpty) continue;

          final topTracksJson = await _callApi(<String, String>{
            'method': 'artist.getTopTracks',
            'artist': simArtistName,
            'autocorrect': '1',
            'limit': '$effectiveLimit',
            'api_key': apiKey,
            'format': 'json',
          }, cancel: cancel);
          if (topTracksJson == null) continue;
          final topTracksObj = topTracksJson['toptracks'];
          final rawTop = topTracksObj is Map
              ? topTracksObj['track']
              : topTracksJson['track'];
          for (final map in _asMapList(rawTop)) {
            addItem(map);
          }
        }
      }
    }

    final pageTracks = collected
        .skip(safeOffset)
        .take(effectiveLimit)
        .toList(growable: false);
    final nextCursor = collected.length > safeOffset + effectiveLimit
        ? '${safeOffset + effectiveLimit}'
        : null;

    return RadioPage(
      tracks: pageTracks,
      nextCursor: nextCursor,
      sourceLabel: 'Last.fm Radio',
    );
  }

  Future<Map<String, dynamic>?> _callApi(
    Map<String, String> query, {
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    final baseUri = Uri.parse(baseUrl);
    final uri = baseUri.replace(
      queryParameters: <String, String>{
        ...baseUri.queryParameters,
        ...query,
      },
    );
    try {
      final res = await http.sendJsonRaw(
        method: 'GET',
        uri: uri,
        headers: const <String, String>{'Accept': 'application/json'},
        cancel: cancel,
      );
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return null;
      }
      if (res.json['error'] != null) {
        return null;
      }
      return res.json;
    } on StreamingException catch (e) {
      if (e.isCancelled || cancel?.isCancelled == true) {
        throw RecError(
          kind: RecErrorKind.cancelled,
          message: e.message,
          statusCode: e.statusCode,
          providerId: recommendationProviderId,
        );
      }
      return null;
    } catch (_) {
      if (cancel?.isCancelled == true) {
        throw const RecError(
          kind: RecErrorKind.cancelled,
          message: '操作已取消',
          providerId: 'lastfm',
        );
      }
      return null;
    }
  }

  static List<Map<String, dynamic>> _asMapList(dynamic raw) {
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
    }
    if (raw is Map) {
      return <Map<String, dynamic>>[Map<String, dynamic>.from(raw)];
    }
    return const <Map<String, dynamic>>[];
  }

  static TrackMetadata? _parseLastFmTrack(Map<String, dynamic> map) {
    final title = map['name']?.toString().trim() ?? '';
    if (title.isEmpty) return null;

    final artistField = map['artist'];
    final String artistName;
    if (artistField is Map) {
      artistName = artistField['name']?.toString().trim() ?? '';
    } else {
      artistName = artistField?.toString().trim() ?? '';
    }
    if (artistName.isEmpty) return null;

    final rawDuration = map['duration'];
    final parsedDuration = rawDuration is num
        ? rawDuration.toInt()
        : int.tryParse(rawDuration?.toString().trim() ?? '') ?? 0;
    final durationMs = parsedDuration <= 0
        ? 0
        : (parsedDuration > 30000 ? parsedDuration : parsedDuration * 1000);

    final mbid = map['mbid']?.toString().trim();
    final url = map['url']?.toString().trim();
    final trackId = (mbid != null && mbid.isNotEmpty)
        ? mbid
        : ((url != null && url.isNotEmpty)
              ? url
              : '${artistName.toLowerCase()}::${title.toLowerCase()}');

    final coverUrl = _extractLastFmImage(map['image']);
    final primary = extractPrimaryArtistDisplay(artistName);

    return TrackMetadata(
      providerId: 'lastfm',
      trackId: trackId,
      title: title,
      artist: artistName,
      primaryArtist: primary.isNotEmpty ? primary : artistName,
      durationMs: durationMs,
      coverUrl: coverUrl,
      format: const AudioFormat(
        codec: AudioCodec.flac,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
      ),
      providerName: 'Last.fm',
    );
  }

  static const String _lastFmPlaceholderImageId =
      '2a96cbd8b46e442fc41c2b86b821562f';

  static String? _extractLastFmImage(dynamic images) {
    if (images is! List) return null;
    String? fallback;
    for (final preferredSize in const <String>[
      'mega',
      'extralarge',
      'large',
      'medium',
    ]) {
      for (final item in images) {
        if (item is! Map) continue;
        final text = BaseStreamingProvider.normalizeCoverUrl(
          item['#text']?.toString(),
        );
        if (text == null ||
            text.toLowerCase().contains(_lastFmPlaceholderImageId)) {
          continue;
        }
        fallback ??= text;
        if (item['size']?.toString().toLowerCase() == preferredSize) {
          return text;
        }
      }
    }
    return fallback;
  }
}
