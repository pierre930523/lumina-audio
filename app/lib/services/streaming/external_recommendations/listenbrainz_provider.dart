import 'dart:convert';
import 'dart:io';

import '../../../models/audio_format.dart';
import '../../../models/recommendation_models.dart';
import '../../../models/stream_source_spec.dart';
import '../../../models/streaming_models.dart';
import '../recommendation_provider.dart';
import '../streaming_provider.dart';
import '../track_matcher.dart';

/// Keyless open-metadata Track Radio provider backed by MusicBrainz MBID lookup,
/// ListenBrainz Labs `similar-recordings`, and ListenBrainz `/1/explore/lb-radio`.
class ListenBrainzRecommendationProvider implements RecommendationProvider {
  static const String _userAgent =
      'LuminaAudio/0.2.4 (https://github.com/lumina-audio)';
  static const String _defaultLabsAlgorithm =
      'session_based_days_7500_session_300_contribution_5_threshold_10_limit_100_filter_true_skip_30';

  final bool Function() enabledProvider;
  final String apiBaseUrl;
  final String labsBaseUrl;
  final String musicBrainzBaseUrl;
  final StreamingHttpClient http;

  ListenBrainzRecommendationProvider({
    required this.enabledProvider,
    this.apiBaseUrl = 'https://api.listenbrainz.org',
    this.labsBaseUrl = 'https://labs.api.listenbrainz.org',
    this.musicBrainzBaseUrl = 'https://musicbrainz.org/ws/2',
    StreamingHttpClient? http,
    HttpClient Function()? httpClientFactory,
  }) : http = http ?? StreamingHttpClient(clientFactory: httpClientFactory);

  @override
  String get recommendationProviderId => 'listenbrainz';

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
    if (!enabledProvider()) {
      return const RadioPage(
        tracks: <TrackMetadata>[],
        sourceLabel: 'ListenBrainz',
      );
    }

    final effectiveLimit = limit > 0 ? limit : 10;
    final offset = int.tryParse(cursor?.trim() ?? '') ?? 0;
    final safeOffset = offset < 0 ? 0 : offset;

    final seedArtist = seed.primaryArtist.trim().isNotEmpty
        ? seed.primaryArtist.trim()
        : seed.artist.trim();
    final seedTitle = seed.title.trim();
    if (seedArtist.isEmpty && seedTitle.isEmpty) {
      return const RadioPage(
        tracks: <TrackMetadata>[],
        sourceLabel: 'ListenBrainz',
      );
    }

    final seedNormTitle = TrackMatcher.normalizeTitleForMatching(seedTitle);
    final seedNormArtist = TrackMatcher.normalizeArtistForMatching(seedArtist);

    final collected = <TrackMetadata>[];
    final seenKeys = <String>{};

    void addCandidate(TrackMetadata? meta) {
      if (meta == null) return;
      final normTitle = TrackMatcher.normalizeTitleForMatching(meta.title);
      final normArtist =
          TrackMatcher.normalizeArtistForMatching(meta.primaryArtist);
      if (seedNormTitle.isNotEmpty &&
          normTitle == seedNormTitle &&
          (seedNormArtist.isEmpty || normArtist == seedNormArtist)) {
        return;
      }
      final key = meta.trackId.isNotEmpty
          ? 'id:${meta.trackId}'
          : '$normArtist::$normTitle';
      if (seenKeys.add(key)) {
        collected.add(meta);
      }
    }

    String? recordingMbid;
    String? artistMbid;

    if (seedTitle.isNotEmpty) {
      final mbRecQuery = seedArtist.isNotEmpty
          ? 'recording:"$seedTitle" AND artist:"$seedArtist"'
          : 'recording:"$seedTitle"';
      final recSearchUri = BaseStreamingProvider.buildUri(
        musicBrainzBaseUrl,
        '/recording',
        <String, String>{
          'query': mbRecQuery,
          'fmt': 'json',
          'limit': '3',
        },
      );
      final recJson = await _sendFlexibleJson(
        method: 'GET',
        uri: recSearchUri,
        cancel: cancel,
      );
      if (recJson is Map) {
        final recs = recJson['recordings'];
        if (recs is List && recs.isNotEmpty && recs.first is Map) {
          final firstRec = Map<String, dynamic>.from(recs.first as Map);
          final rid = firstRec['id']?.toString().trim();
          if (rid != null && rid.isNotEmpty) {
            recordingMbid = rid;
          }
          final credits = firstRec['artist-credit'];
          if (credits is List && credits.isNotEmpty && credits.first is Map) {
            final art = (credits.first as Map)['artist'];
            if (art is Map) {
              final aid = art['id']?.toString().trim();
              if (aid != null && aid.isNotEmpty) {
                artistMbid = aid;
              }
            }
          }
        }
      }
    }

    if (recordingMbid != null) {
      final labsUri = BaseStreamingProvider.buildUri(
        labsBaseUrl,
        '/similar-recordings/json',
      );
      final labsPayload = await _sendFlexibleJson(
        method: 'POST',
        uri: labsUri,
        headers: const <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'recording_mbids': <String>[recordingMbid],
            'algorithm': _defaultLabsAlgorithm,
          },
        ]),
        cancel: cancel,
      );

      var labsItems = _extractCandidateMaps(labsPayload);
      if (labsItems.isEmpty) {
        final labsGetUri = BaseStreamingProvider.buildUri(
          labsBaseUrl,
          '/similar-recordings/json',
          <String, String>{'recording_mbids': recordingMbid},
        );
        final labsGetPayload = await _sendFlexibleJson(
          method: 'GET',
          uri: labsGetUri,
          cancel: cancel,
        );
        labsItems = _extractCandidateMaps(labsGetPayload);
      }

      for (final item in labsItems) {
        addCandidate(_parseListenBrainzTrack(item));
      }
    }

    if (collected.length < safeOffset + effectiveLimit) {
      if (artistMbid == null && seedArtist.isNotEmpty) {
        final artistUri = BaseStreamingProvider.buildUri(
          musicBrainzBaseUrl,
          '/artist',
          <String, String>{
            'query': 'artist:"$seedArtist"',
            'fmt': 'json',
            'limit': '1',
          },
        );
        final artistJson = await _sendFlexibleJson(
          method: 'GET',
          uri: artistUri,
          cancel: cancel,
        );
        if (artistJson is Map) {
          final artists = artistJson['artists'];
          if (artists is List && artists.isNotEmpty && artists.first is Map) {
            final aid = (artists.first as Map)['id']?.toString().trim();
            if (aid != null && aid.isNotEmpty) {
              artistMbid = aid;
            }
          }
        }
      }

      final promptTarget = (artistMbid != null && artistMbid.isNotEmpty)
          ? artistMbid
          : seedArtist;
      if (promptTarget.isNotEmpty) {
        final lbRadioUri = BaseStreamingProvider.buildUri(
          apiBaseUrl,
          '/1/explore/lb-radio',
          <String, String>{
            'prompt': 'artist:($promptTarget)',
            'mode': 'medium',
          },
        );
        final radioJson = await _sendFlexibleJson(
          method: 'GET',
          uri: lbRadioUri,
          cancel: cancel,
        );
        for (final item in _extractCandidateMaps(radioJson)) {
          addCandidate(_parseListenBrainzTrack(item));
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
      sourceLabel: 'ListenBrainz Radio',
    );
  }

  Future<dynamic> _sendFlexibleJson({
    required String method,
    required Uri uri,
    Map<String, String> headers = const <String, String>{},
    String? body,
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    try {
      final resp = await http.send(
        method: method,
        uri: uri,
        headers: <String, String>{
          'User-Agent': _userAgent,
          'Accept': 'application/json',
          ...headers,
        },
        body: body,
        cancel: cancel,
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return null;
      }
      if (resp.body.trim().isEmpty) return null;
      return jsonDecode(resp.body);
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
          providerId: 'listenbrainz',
        );
      }
      return null;
    }
  }

  static List<Map<String, dynamic>> _extractCandidateMaps(dynamic root) {
    if (root == null) return const <Map<String, dynamic>>[];
    if (root is List) {
      final out = <Map<String, dynamic>>[];
      for (final item in root) {
        if (item is Map) {
          final map = Map<String, dynamic>.from(item);
          if (map['similar_recordings'] is List) {
            out.addAll(_extractCandidateMaps(map['similar_recordings']));
          } else {
            out.add(map);
          }
        }
      }
      return out;
    }
    if (root is Map) {
      final map = Map<String, dynamic>.from(root);
      final payload = map['payload'] is Map
          ? Map<String, dynamic>.from(map['payload'] as Map)
          : map;

      final jspf = payload['jspf'];
      if (jspf is Map && jspf['playlist'] is Map) {
        final playlist = jspf['playlist'] as Map;
        if (playlist['track'] is List) {
          return _extractCandidateMaps(playlist['track']);
        }
      }
      for (final key in const <String>[
        'tracks',
        'recordings',
        'similar_recordings',
        'data',
      ]) {
        if (payload[key] is List) {
          return _extractCandidateMaps(payload[key]);
        }
      }
    }
    return const <Map<String, dynamic>>[];
  }

  static TrackMetadata? _parseListenBrainzTrack(Map<String, dynamic> map) {
    final title = (map['recording_name'] ??
            map['title'] ??
            map['track_name'] ??
            map['name'])
        ?.toString()
        .trim();
    if (title == null || title.isEmpty) return null;

    var artistName = (map['artist_credit_name'] ??
            map['creator'] ??
            map['artist_name'] ??
            map['artist'])
        ?.toString()
        .trim();
    String? artistMbid;

    final ext = map['extension'];
    if (ext is Map) {
      final trackExt = ext['https://musicbrainz.org/track/'];
      if (trackExt is Map && trackExt['additional_metadata'] is Map) {
        final addMeta = trackExt['additional_metadata'] as Map;
        final artists = addMeta['artists'];
        if (artists is List && artists.isNotEmpty && artists.first is Map) {
          final firstArt = artists.first as Map;
          artistName ??= firstArt['artist_credit_name']?.toString().trim();
          artistMbid = firstArt['artist_mbid']?.toString().trim();
        }
      }
    }

    if (artistName == null || artistName.isEmpty) return null;

    String? recordingMbid =
        (map['recording_mbid'] ?? map['mbid'])?.toString().trim();
    if (recordingMbid == null || recordingMbid.isEmpty) {
      final identifier = map['identifier'];
      if (identifier is List && identifier.isNotEmpty) {
        recordingMbid = _extractMbidFromIdentifier(identifier.first?.toString());
      } else if (identifier is String) {
        recordingMbid = _extractMbidFromIdentifier(identifier);
      }
    }

    final trackId = (recordingMbid != null && recordingMbid.isNotEmpty)
        ? recordingMbid
        : '${artistName.toLowerCase()}::${title.toLowerCase()}';
    final album =
        (map['release_name'] ?? map['album'] ?? '')?.toString().trim() ?? '';

    final rawDuration = map['duration'] ?? map['length'] ?? map['duration_ms'];
    final parsedDuration = rawDuration is num
        ? rawDuration.toInt()
        : int.tryParse(rawDuration?.toString().trim() ?? '') ?? 0;
    final durationMs = parsedDuration <= 0
        ? 0
        : (parsedDuration > 30000 ? parsedDuration : parsedDuration * 1000);

    final primary = extractPrimaryArtistDisplay(artistName);
    return TrackMetadata(
      providerId: 'listenbrainz',
      trackId: trackId,
      title: title,
      artist: artistName,
      primaryArtist: primary.isNotEmpty ? primary : artistName,
      album: album,
      durationMs: durationMs,
      artistId: (artistMbid != null && artistMbid.isNotEmpty)
          ? artistMbid
          : null,
      format: const AudioFormat(
        codec: AudioCodec.flac,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
      ),
      providerName: 'ListenBrainz',
    );
  }

  static String? _extractMbidFromIdentifier(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.pathSegments.isNotEmpty) {
      final last = uri.pathSegments.last.trim();
      if (last.isNotEmpty) return last;
    }
    return trimmed;
  }
}
