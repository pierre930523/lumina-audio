import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/audio_format.dart';
import '../models/audio_output_info.dart';
import '../models/ingestion_models.dart';
import '../models/lyric.dart';
import '../models/playback_state.dart';
import '../models/recommendation_models.dart';
import '../models/signal_path.dart';
import '../models/stream_source_spec.dart';
import '../models/studio_models.dart';
import 'audio_service.dart';
import 'per_device_playback_tracker.dart';
import 'playback_persistence_service.dart';

class _DirectHttpOverrides extends HttpOverrides {}

class MdnsDiscoveryClient {
  static Uint8List buildPtrQueryPacket({
    String serviceType = '_lumina._tcp.local.',
  }) {
    final builder = BytesBuilder();
    // DNS Header: ID=0, Flags=0, QD=1, AN=0, NS=0, AR=0
    builder.add([0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    for (final label in serviceType.split('.').where((l) => l.isNotEmpty)) {
      final bytes = utf8.encode(label);
      builder.addByte(bytes.length);
      builder.add(bytes);
    }
    builder.addByte(0);
    // QTYPE = PTR (12), QCLASS = IN (1)
    builder.add([0, 12, 0, 1]);
    return builder.toBytes();
  }

  static (String, int) _decodeDnsName(Uint8List pkt, int offset) {
    final labels = <String>[];
    var pos = offset;
    var origNext = offset;
    var jumped = false;
    final seen = <int>{};

    while (pos < pkt.length) {
      if (!seen.add(pos)) break;
      final len = pkt[pos];
      if (len == 0) {
        if (!jumped) origNext = pos + 1;
        break;
      }
      if ((len & 0xC0) == 0xC0 && pos + 1 < pkt.length) {
        final ptr = ((len & 0x3F) << 8) | pkt[pos + 1];
        if (!jumped) origNext = pos + 2;
        jumped = true;
        pos = ptr;
        continue;
      }
      pos += 1;
      if (pos + len > pkt.length) break;
      labels.add(utf8.decode(pkt.sublist(pos, pos + len), allowMalformed: true));
      pos += len;
    }
    return ('${labels.join('.')}.', origNext);
  }

  static DiscoveredServerInfo? parseDnsSdResponsePacket(Uint8List pkt) {
    if (pkt.length < 12) return null;
    final qdCount = (pkt[4] << 8) | pkt[5];
    final anCount = (pkt[6] << 8) | pkt[7];
    final nsCount = (pkt[8] << 8) | pkt[9];
    final arCount = (pkt[10] << 8) | pkt[11];

    var pos = 12;
    for (var i = 0; i < qdCount && pos < pkt.length; i++) {
      final (_, nextPos) = _decodeDnsName(pkt, pos);
      pos = nextPos + 4;
    }

    String? serverName;
    String? ipv4;
    int port = 9888;
    final txt = <String, String>{};

    final totalRr = anCount + nsCount + arCount;
    for (var i = 0; i < totalRr && pos + 10 <= pkt.length; i++) {
      final (rrName, afterName) = _decodeDnsName(pkt, pos);
      if (afterName + 10 > pkt.length) break;
      final bd = ByteData.sublistView(pkt, afterName, afterName + 10);
      final rtype = bd.getUint16(0);
      final rdLen = bd.getUint16(8);
      final rdataStart = afterName + 10;
      if (rdataStart + rdLen > pkt.length) break;

      if (rtype == 12) {
        final (target, _) = _decodeDnsName(pkt, rdataStart);
        serverName ??= target.split('.').first;
      } else if (rtype == 33 && rdLen >= 6) {
        final srvBd = ByteData.sublistView(pkt, rdataStart, rdataStart + 6);
        port = srvBd.getUint16(4);
        serverName ??= rrName.split('.').first;
      } else if (rtype == 16) {
        var tpos = rdataStart;
        final end = rdataStart + rdLen;
        while (tpos < end) {
          final slen = pkt[tpos];
          tpos += 1;
          if (tpos + slen > end) break;
          final entry = utf8.decode(
            pkt.sublist(tpos, tpos + slen),
            allowMalformed: true,
          );
          tpos += slen;
          final eq = entry.indexOf('=');
          if (eq > 0) {
            txt[entry.substring(0, eq)] = entry.substring(eq + 1);
          }
        }
      } else if (rtype == 1 && rdLen == 4) {
        ipv4 =
            '${pkt[rdataStart]}.${pkt[rdataStart + 1]}.${pkt[rdataStart + 2]}.${pkt[rdataStart + 3]}';
      }
      pos = rdataStart + rdLen;
    }

    if (ipv4 == null && txt.isEmpty) return null;
    return DiscoveredServerInfo(
      serverName: txt['server_name'] ?? serverName ?? 'Lumina-Desktop',
      host: ipv4 ?? '127.0.0.1',
      port: port,
      txtRecords: txt,
    );
  }

  static Future<List<DiscoveredServerInfo>> discover({
    String targetHost = '224.0.0.251',
    int port = 5353,
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    final bindAddr = targetHost == '127.0.0.1'
        ? InternetAddress.loopbackIPv4
        : InternetAddress.anyIPv4;
    final socket = await RawDatagramSocket.bind(bindAddr, 0);
    final found = <String, DiscoveredServerInfo>{};
    final completer = Completer<void>();
    final queryPkt = buildPtrQueryPacket();
    final targetAddr = InternetAddress.tryParse(targetHost) ??
        InternetAddress('127.0.0.1');
    Timer? retryTimer;

    void finishDiscovery() {
      retryTimer?.cancel();
      if (!completer.isCompleted) {
        completer.complete();
      }
    }

    late final StreamSubscription<RawSocketEvent> sub;
    sub = socket.listen((event) {
      if (event == RawSocketEvent.write) {
        try {
          socket.send(queryPkt, targetAddr, port);
        } catch (_) {}
        socket.writeEventsEnabled = false;
      }
      if (event == RawSocketEvent.read) {
        while (true) {
          final dg = socket.receive();
          if (dg == null) break;
          final parsed = parseDnsSdResponsePacket(dg.data);
          if (parsed != null) {
            found['${parsed.host}:${parsed.port}'] = parsed;
            if (targetHost == '127.0.0.1') {
              finishDiscovery();
            }
          }
        }
      }
    });

    try {
      socket.send(queryPkt, targetAddr, port);
    } catch (_) {}

    retryTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
      if (found.isNotEmpty || completer.isCompleted) {
        retryTimer?.cancel();
        return;
      }
      try {
        socket.send(queryPkt, targetAddr, port);
      } catch (_) {}
    });

    Timer(timeout, finishDiscovery);

    await completer.future;
    retryTimer.cancel();
    await sub.cancel();
    socket.close();
    return found.values.toList();
  }

  static ({String host, int port, String pin})? parsePairingQrUri(String uri) {
    final parsed = Uri.tryParse(uri.trim());
    if (parsed == null || parsed.scheme != 'lumina') return null;
    final pin = parsed.queryParameters['pin'] ?? '';
    final host = parsed.queryParameters['host'] ?? '';
    final port = int.tryParse(parsed.queryParameters['port'] ?? '') ?? 9888;
    if (pin.length != 6 || host.isEmpty) return null;
    return (host: host, port: port, pin: pin);
  }
}

class ServerAudioService implements AudioService {
  final PerDevicePlaybackTracker _tracker = PerDevicePlaybackTracker();

  @override
  Map<String, PlaybackState> get devicePlaybackStates =>
      _tracker.snapshotDevices(_state);

  @override
  Map<String, PlaybackState> get zonePlaybackStates =>
      _tracker.snapshotZones(activeLocalState: _state);

  @override
  String? get activeDeviceId => _tracker.activeDeviceId;

  String _baseUrl;
  String? _bearerToken;
  bool _allowSelfSignedTls;
  ConnectionMode _mode;

  final StreamController<PlaybackState> _stateController =
      StreamController<PlaybackState>.broadcast();
  final StreamController<SignalPath> _signalPathController =
      StreamController<SignalPath>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<ScanProgressEvent> _scanProgressController =
      StreamController<ScanProgressEvent>.broadcast();

  WebSocket? _ws;
  StreamSubscription<dynamic>? _wsSub;
  PlaybackState _state = PlaybackState(
    status: PlaybackStatus.stopped,
    position: Duration.zero,
    volume: 1.0,
    isMuted: false,
    track: null,
  );
  SignalPath _signalPath = const SignalPath(
    overallQuality: SignalQuality.lossless,
    description: '遠端核心伺服器',
    nodes: [],
    dspBypassed: true,
  );
  List<TrackInfo> _queue = [];
  StreamingTrackHandler? _streamingTrackHandler;
  void Function()? _playbackInterruptHandler;
  String? _lastError;
  bool _needsLoadOnResume = false;
  int _activeEpoch = 0;
  int _lastCancelledEpoch = 0;
  int _lastObservedSwapGeneration = 0;
  HttpClient? _activePlayHttpClient;
  bool _disposed = false;

  void _abortActivePlayRequest() {
    final active = _activePlayHttpClient;
    _activePlayHttpClient = null;
    if (active != null) {
      try {
        active.close(force: true);
      } catch (_) {}
    }
  }

  ServerAudioService({
    String baseUrl = 'http://127.0.0.1:9888',
    String? bearerToken,
    bool allowSelfSignedTls = false,
    ConnectionMode mode = ConnectionMode.lanRemote,
  }) : this._internal(
         _normalizeBaseUrl(baseUrl),
         bearerToken,
         allowSelfSignedTls,
         mode,
       );

  ServerAudioService._internal(
    this._baseUrl,
    this._bearerToken,
    this._allowSelfSignedTls,
    this._mode,
  );

  static String _normalizeBaseUrl(String raw) {
    final trimmed = raw.trim();
    return trimmed.endsWith('/') ? trimmed.substring(0, trimmed.length - 1) : trimmed;
  }

  static final HttpOverrides _directHttpOverrides = _DirectHttpOverrides();

  HttpClient _buildHttpClient() {
    // Bypass TestWidgetsFlutterBinding's mock HTTP 400 override when run inside widget test suites.
    final client = _directHttpOverrides.createHttpClient(null);
    client.connectionTimeout = const Duration(seconds: 5);
    if (_allowSelfSignedTls) {
      client.badCertificateCallback = (_, _, _) => true;
    }
    return client;
  }

  Future<(int, dynamic)> _requestJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool authenticated = true,
    bool trackAsPlayRequest = false,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (trackAsPlayRequest) {
      _abortActivePlayRequest();
    }
    final client = _buildHttpClient();
    if (trackAsPlayRequest) {
      _activePlayHttpClient = client;
    }
    try {
      final uri = Uri.parse('$_baseUrl$path');
      final req = await client.openUrl(method, uri).timeout(timeout);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      if (authenticated && _bearerToken != null) {
        req.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $_bearerToken',
        );
      }
      if (body != null) {
        req.write(jsonEncode(body));
      }
      final resp = await req.close().timeout(timeout);
      final text = await utf8.decodeStream(resp).timeout(timeout);
      dynamic parsed;
      if (text.trim().isNotEmpty) {
        try {
          parsed = jsonDecode(text);
        } catch (_) {
          parsed = text;
        }
      }
      return (resp.statusCode, parsed);
    } finally {
      if (identical(_activePlayHttpClient, client)) {
        _activePlayHttpClient = null;
      }
      client.close(force: true);
    }
  }

  String _wsUrl() {
    final uri = Uri.parse(_baseUrl);
    final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';
    final hostPort = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
    final encodedTok = Uri.encodeQueryComponent(_bearerToken ?? '');
    return '$wsScheme://$hostPort/api/v1/ws?snapshot=true&token=$encodedTok';
  }

  Future<void> connectWebSocket() async {
    await _wsSub?.cancel();
    await _ws?.close();
    final client = _buildHttpClient();
    _ws = await WebSocket.connect(
      _wsUrl(),
      headers: _bearerToken != null
          ? {'Authorization': 'Bearer $_bearerToken'}
          : null,
      customClient: client,
    );
    _wsSub = _ws!.listen(
      (raw) {
        if (raw is! String) return;
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            _handleWsMessage(decoded);
          }
        } catch (_) {}
      },
      onError: (_) {},
      onDone: () {},
    );
  }

  @visibleForTesting
  void handleWsMessageForTest(Map<String, dynamic> msg) =>
      _handleWsMessage(msg);

  static String? _nonEmptyString(dynamic raw) {
    final s = raw?.toString().trim();
    return (s != null && s.isNotEmpty) ? s : null;
  }

  static String _providerDisplayName(String? providerId) {
    final normalized = providerId?.trim().toLowerCase() ?? '';
    return switch (normalized) {
      'qobuz' => 'Qobuz',
      'tidal' => 'Tidal',
      'deezer' => 'Deezer',
      'youtube_music' || 'ytm' => 'YouTube Music',
      'apple_music' || 'apple' => 'Apple Music',
      'podcast_rss' || 'podcast' => 'Podcast',
      'local' => 'Local Library',
      _ => (providerId != null && providerId.trim().isNotEmpty)
          ? providerId.trim()
          : 'Remote Core',
    };
  }

  static String _normalizedTrackKey(String rawId, {String? providerId}) {
    final probe = TrackInfo(
      id: rawId,
      title: '',
      artist: '',
      album: '',
      duration: Duration.zero,
      format: const AudioFormat(
        codec: AudioCodec.flac,
        sampleRateHz: 44100,
        bitDepth: 16,
        channels: 2,
      ),
      providerName: _providerDisplayName(providerId),
    );
    final meta = TrackMetadata.fromTrackInfo(
      probe,
      providerIdOverride:
          (providerId != null && providerId.trim().isNotEmpty)
              ? providerId.trim()
              : null,
    );
    return '${meta.providerId}:${meta.trackId}';
  }

  static bool _tracksReferToSame(TrackInfo? current, TrackInfo? incoming) {
    if (current == null || incoming == null) return false;
    if (current.id == incoming.id) return true;
    if (current.id.isEmpty || incoming.id.isEmpty) return false;
    return current.responsiveArtworkKey == incoming.responsiveArtworkKey;
  }

  static bool _trackMatchesId(
    TrackInfo candidate,
    String reportedId,
    String? providerId,
  ) {
    if (candidate.id == reportedId) return true;
    if (reportedId.isEmpty) return false;
    return candidate.responsiveArtworkKey ==
        _normalizedTrackKey(reportedId, providerId: providerId);
  }

  TrackInfo _parseTrackFromMap(
    Map<String, dynamic> item, {
    String defaultProvider = 'Remote Core',
    int fallbackDurationMs = 0,
  }) {
    final rawId =
        _nonEmptyString(item['track_id']) ??
        _nonEmptyString(item['id']) ??
        _nonEmptyString(item['external_track_id']) ??
        '';
    final providerId = _nonEmptyString(item['provider_id']);
    final title = _nonEmptyString(item['title']) ?? '';
    final artist =
        _nonEmptyString(item['artist_name']) ??
        _nonEmptyString(item['artist']) ??
        '';
    final album = _nonEmptyString(item['album']) ?? '';
    final coverUrl =
        _nonEmptyString(item['cover_url']) ??
        _nonEmptyString(item['album_art_url']) ??
        _nonEmptyString(item['artwork_url']);
    final durMs = (item['duration_ms'] as num?)?.toInt() ?? fallbackDurationMs;
    final canonicalId =
        (providerId != null &&
            providerId != 'local' &&
            rawId.isNotEmpty &&
            !rawId.contains(':'))
        ? TrackMetadata(
            providerId: providerId,
            trackId: rawId,
            title: title,
            artist: artist,
          ).toTrackInfo().id
        : rawId;
    final providerName =
        _nonEmptyString(item['provider_name']) ??
        (providerId != null ? _providerDisplayName(providerId) : defaultProvider);
    return TrackInfo(
      id: canonicalId,
      title: title,
      artist: artist,
      album: album,
      duration: Duration(milliseconds: durMs > 0 ? durMs : 0),
      format: AudioFormat(
        codec: AudioCodec.fromString(item['codec']?.toString()),
        sampleRateHz: (item['sample_rate_hz'] as num?)?.toInt() ?? 44100,
        bitDepth: (item['bit_depth'] as num?)?.toInt() ?? 16,
        channels: (item['channels'] as num?)?.toInt() ?? 2,
        isDsd: item['is_dsd'] == true,
        bitrateKbps: _parseBitrateKbps(item),
      ),
      providerName: providerName,
      filePath: _nonEmptyString(item['file_path']),
      coverUrl: coverUrl,
      albumArtUrl: coverUrl,
      artworkCacheKey: _nonEmptyString(item['artwork_cache_key']),
      hasLyrics: item['has_lyrics'] == true,
    );
  }

  TrackInfo? _hydrateTrackFromPayload(
    Map<String, dynamic> payload, {
    int fallbackDurationMs = 0,
  }) {
    final rawTrackObj =
        payload['track'] ?? payload['current_track'] ?? payload['active_track'];
    final rawTrackMap = rawTrackObj is Map
        ? Map<String, dynamic>.from(rawTrackObj)
        : null;
    final reportedId =
        _nonEmptyString(rawTrackMap?['track_id']) ??
        _nonEmptyString(rawTrackMap?['id']) ??
        _nonEmptyString(payload['track_id']) ??
        _nonEmptyString(payload['current_track_id']);
    final reportedProviderId =
        _nonEmptyString(rawTrackMap?['provider_id']) ??
        _nonEmptyString(payload['provider_id']);
    final mapDurMs =
        (rawTrackMap?['duration_ms'] as num?)?.toInt() ??
        (payload['duration_ms'] as num?)?.toInt() ??
        fallbackDurationMs;

    TrackInfo? baseMatch;
    if (reportedId != null) {
      for (final q in _queue) {
        if (_trackMatchesId(q, reportedId, reportedProviderId)) {
          baseMatch = q;
          break;
        }
      }
      if (baseMatch == null &&
          _state.track != null &&
          _trackMatchesId(_state.track!, reportedId, reportedProviderId)) {
        baseMatch = _state.track;
      }
    }

    TrackInfo? parsedPayloadTrack;
    if (rawTrackMap != null) {
      parsedPayloadTrack = _parseTrackFromMap(
        rawTrackMap,
        fallbackDurationMs: mapDurMs,
      );
    } else if (reportedId != null || _nonEmptyString(payload['title']) != null) {
      parsedPayloadTrack = _parseTrackFromMap(<String, dynamic>{
        'track_id': ?reportedId,
        'provider_id': ?reportedProviderId,
        if (payload['title'] != null) 'title': payload['title'],
        if (payload['artist'] != null) 'artist': payload['artist'],
        if (payload['album'] != null) 'album': payload['album'],
        if (payload['cover_url'] != null) 'cover_url': payload['cover_url'],
        if (payload['album_art_url'] != null)
          'album_art_url': payload['album_art_url'],
        if (mapDurMs > 0) 'duration_ms': mapDurMs,
      }, fallbackDurationMs: mapDurMs);
    }

    if (baseMatch == null && parsedPayloadTrack == null) {
      if (_state.track != null && mapDurMs > 0) {
        return _state.track!.copyWith(
          duration: Duration(milliseconds: mapDurMs),
        );
      }
      return _state.track;
    }
    if (baseMatch == null) {
      final p = parsedPayloadTrack!;
      if (p.title.isEmpty) {
        return p.copyWith(
          title: p.id.isNotEmpty ? p.id : '未知曲目',
          artist: p.artist.isEmpty ? '未知藝術家' : p.artist,
        );
      }
      return p;
    }
    if (parsedPayloadTrack == null) {
      return mapDurMs > 0
          ? baseMatch.copyWith(duration: Duration(milliseconds: mapDurMs))
          : baseMatch;
    }

    final mergedTitle = parsedPayloadTrack.title.isNotEmpty
        ? parsedPayloadTrack.title
        : baseMatch.title;
    final mergedArtist = parsedPayloadTrack.artist.isNotEmpty
        ? parsedPayloadTrack.artist
        : baseMatch.artist;
    final mergedAlbum = parsedPayloadTrack.album.isNotEmpty
        ? parsedPayloadTrack.album
        : baseMatch.album;
    final mergedCover =
        (parsedPayloadTrack.coverUrl != null &&
            parsedPayloadTrack.coverUrl!.isNotEmpty)
        ? parsedPayloadTrack.coverUrl
        : baseMatch.coverUrl;
    final mergedAlbumArt =
        (parsedPayloadTrack.albumArtUrl != null &&
            parsedPayloadTrack.albumArtUrl!.isNotEmpty)
        ? parsedPayloadTrack.albumArtUrl
        : (baseMatch.albumArtUrl ?? mergedCover);
    final mergedDur = mapDurMs > 0
        ? Duration(milliseconds: mapDurMs)
        : (parsedPayloadTrack.duration > Duration.zero
              ? parsedPayloadTrack.duration
              : baseMatch.duration);
    final mergedProvider = baseMatch.providerName.isNotEmpty &&
            baseMatch.providerName != 'Remote Core'
        ? baseMatch.providerName
        : parsedPayloadTrack.providerName;

    return baseMatch.copyWith(
      title: mergedTitle,
      artist: mergedArtist,
      album: mergedAlbum,
      coverUrl: mergedCover,
      albumArtUrl: mergedAlbumArt,
      duration: mergedDur,
      providerName: mergedProvider,
    );
  }

  static PlaybackStatus _parsePlaybackStatus(String? raw) {
    return switch (raw?.trim().toLowerCase()) {
      'playing' => PlaybackStatus.playing,
      'paused' => PlaybackStatus.paused,
      'error' => PlaybackStatus.error,
      'loading' => PlaybackStatus.loading,
      'seeking' => PlaybackStatus.seeking,
      'buffering' => PlaybackStatus.buffering,
      'ended' => PlaybackStatus.ended,
      'uninitialized' => PlaybackStatus.uninitialized,
      _ => PlaybackStatus.stopped,
    };
  }

  Future<void> _refreshLyricsForTrack(TrackInfo track) async {
    await _fetchLyrics(track.id, path: track.filePath);
    if (_disposed) return;
    if (_state.track?.id == track.id && !_stateController.isClosed) {
      _stateController.add(_state);
    }
  }

  void _handleWsMessage(Map<String, dynamic> msg) {
    final type = msg['type']?.toString();
    if (type == 'PlaybackStateChanged') {
      final payload = msg['payload'] as Map<String, dynamic>? ?? const {};
      final msgEpoch = PlaybackState.parsePlaybackEpoch(payload);
      if (_activeEpoch > 0 && msgEpoch < _activeEpoch) {
        return;
      }
      final effectiveEpoch = msgEpoch > 0 ? msgEpoch : _activeEpoch;
      final status = _parsePlaybackStatus(payload['status']?.toString());
      final posMs = (payload['position_ms'] as num?)?.toInt() ?? 0;
      final durMs = (payload['duration_ms'] as num?)?.toInt() ?? 0;
      final seekEpoch =
          (payload['seek_epoch'] as num?)?.toInt() ?? _state.seekEpoch;
      final isSeeking = payload['is_seeking'] == true;
      final deviceLost = payload['device_lost'] == true;
      final lastErr = payload['last_error']?.toString();
      final clockSrc = payload['clock_source']?.toString() ?? _state.clockSource;
      final swapGen =
          (payload['swap_generation'] as num?)?.toInt() ??
          (payload['swapGeneration'] as num?)?.toInt() ??
          _state.swapGeneration;

      final hydratedTrack = _hydrateTrackFromPayload(
        payload,
        fallbackDurationMs: durMs,
      );
      final swapIncremented =
          swapGen > _lastObservedSwapGeneration && swapGen > 0;
      final trackIdChanged =
          hydratedTrack != null &&
          !_tracksReferToSame(_state.track, hydratedTrack);
      final trackChanged = swapIncremented || trackIdChanged;
      final hadPreviousTrack = _state.track != null;
      if (swapGen != _lastObservedSwapGeneration) {
        _lastObservedSwapGeneration = swapGen;
      }

      final nextPos = (hadPreviousTrack && trackChanged)
          ? Duration.zero
          : Duration(milliseconds: posMs < 0 ? 0 : posMs);

      if (trackChanged) {
        _currentLyrics = const [];
        if (hydratedTrack != null && status == PlaybackStatus.playing) {
          unawaited(_refreshLyricsForTrack(hydratedTrack));
        }
      }

      _state = _state.copyWith(
        status: status,
        track: hydratedTrack,
        position: nextPos,
        seekEpoch: seekEpoch,
        isSeeking: isSeeking,
        deviceLost: deviceLost,
        lastError: lastErr,
        clearLastError: lastErr == null || lastErr.isEmpty,
        clockSource: clockSrc,
        swapGeneration: swapGen,
        playbackEpoch: effectiveEpoch,
      );
      if (!_stateController.isClosed) _stateController.add(_state);
      if (!_positionController.isClosed) {
        _positionController.add(_state.position);
      }
    } else if (type == 'event') {
      final eventName = msg['event']?.toString();
      final rawPayload = msg['payload'];
      final payload = rawPayload is Map
          ? Map<String, dynamic>.from(rawPayload)
          : const <String, dynamic>{};
      if (eventName == 'track_changed') {
        final msgEpoch = PlaybackState.parsePlaybackEpoch(payload);
        if (_activeEpoch > 0 && msgEpoch < _activeEpoch) {
          return;
        }
        final effectiveEpoch = msgEpoch > 0 ? msgEpoch : _activeEpoch;
        final swapGen =
            (payload['swap_generation'] as num?)?.toInt() ??
            (payload['swapGeneration'] as num?)?.toInt() ??
            _state.swapGeneration;
        final durMs = (payload['duration_ms'] as num?)?.toInt() ?? 0;
        final hydratedTrack = _hydrateTrackFromPayload(
          payload,
          fallbackDurationMs: durMs,
        );
        final swapIncremented =
            swapGen > _lastObservedSwapGeneration && swapGen > 0;
        final trackIdChanged =
            hydratedTrack != null &&
            !_tracksReferToSame(_state.track, hydratedTrack);
        final trackChanged = swapIncremented || trackIdChanged;
        if (swapGen != _lastObservedSwapGeneration) {
          _lastObservedSwapGeneration = swapGen;
        }
        final statusStr = _nonEmptyString(payload['status']);
        final nextStatus = statusStr != null
            ? _parsePlaybackStatus(statusStr)
            : (_state.status == PlaybackStatus.paused
                  ? PlaybackStatus.paused
                  : PlaybackStatus.playing);

        if (trackChanged) {
          _currentLyrics = const [];
          if (hydratedTrack != null && nextStatus == PlaybackStatus.playing) {
            unawaited(_refreshLyricsForTrack(hydratedTrack));
          }
        }
        _state = _state.copyWith(
          status: nextStatus,
          track: hydratedTrack,
          position: Duration.zero,
          swapGeneration: swapGen,
          playbackEpoch: effectiveEpoch,
          clearLastError: true,
        );
        _tracker.updateActiveDeviceState(_state);
        if (!_stateController.isClosed) _stateController.add(_state);
        if (!_positionController.isClosed) {
          _positionController.add(Duration.zero);
        }
      } else if (eventName == 'queue_updated') {
        final msgEpoch = PlaybackState.parsePlaybackEpoch(payload);
        if (_activeEpoch > 0 && msgEpoch < _activeEpoch) {
          return;
        }
        final rawQueue = payload['queue'] ?? payload['tracks'];
        if (rawQueue is List) {
          _queue = rawQueue
              .whereType<Map>()
              .map(
                (item) => _parseTrackFromMap(
                  Map<String, dynamic>.from(item),
                ),
              )
              .toList();
        }
        final swapGen =
            (payload['swap_generation'] as num?)?.toInt() ??
            (payload['swapGeneration'] as num?)?.toInt() ??
            _state.swapGeneration;
        if (swapGen > _lastObservedSwapGeneration) {
          _lastObservedSwapGeneration = swapGen;
        }
        final hydrated = _hydrateTrackFromPayload(payload);
        final nextTrack =
            (hydrated != null && _tracksReferToSame(_state.track, hydrated))
            ? hydrated
            : _state.track;
        _state = _state.copyWith(
          track: nextTrack,
          swapGeneration: swapGen,
          playbackEpoch: msgEpoch > 0 ? msgEpoch : _activeEpoch,
        );
        if (!_stateController.isClosed) _stateController.add(_state);
      } else if (eventName == 'library.scan_progress') {
        try {
          final progress = ScanProgressEvent.fromJson(payload);
          if (!_scanProgressController.isClosed) {
            _scanProgressController.add(progress);
          }
        } catch (_) {}
      }
    } else if (type == 'SignalPathUpdated') {
      final payload = msg['payload'] as Map<String, dynamic>? ?? const {};
      _signalPath = _parseSignalPath(payload);
      if (!_signalPathController.isClosed) {
        _signalPathController.add(_signalPath);
      }
    } else if (type == 'state_changed' && msg.containsKey('volume')) {
      final vol = (msg['volume'] as num?)?.toDouble();
      if (vol != null) {
        _state = _state.copyWith(volume: vol, isMuted: vol == 0.0);
        if (!_stateController.isClosed) _stateController.add(_state);
      }
    }
  }

  SignalPath _parseSignalPath(Map<String, dynamic> json) {
    SignalQuality parseQ(String? raw) => switch (raw?.toLowerCase()) {
      'lossless' => SignalQuality.lossless,
      'enhanced' => SignalQuality.enhanced,
      _ => SignalQuality.highQuality,
    };
    final qStr = json['quality']?.toString() ?? json['overall_quality']?.toString();
    final q = parseQ(qStr);
    final rawNodes = json['nodes'] as List<dynamic>? ?? const [];
    final nodes = rawNodes.whereType<Map<String, dynamic>>().map((n) {
      final stage = n['stage']?.toString() ?? 'Stage';
      return SignalPathNode(
        title: stage,
        subtitle: stage,
        detail: n['detail']?.toString() ?? '',
        quality: parseQ(n['quality']?.toString()),
      );
    }).toList();
    return SignalPath(
      overallQuality: q,
      description: q.description,
      nodes: nodes,
      dspBypassed: q == SignalQuality.lossless,
    );
  }

  Future<bool> checkHealth() async {
    try {
      final (code, data) = await _requestJson(
        'GET',
        '/api/v1/health',
        authenticated: false,
      );
      return code == 200 && data is Map && data['status'] == 'ok';
    } catch (_) {
      return false;
    }
  }

  Future<void> syncInitialState() async {
    final (stCode, stData) = await _requestJson('GET', '/api/v1/playback/state');
    if (stCode == 200 && stData is Map<String, dynamic>) {
      _handleWsMessage({'type': 'PlaybackStateChanged', 'payload': stData});
    }
    final (spCode, spData) = await _requestJson('GET', '/api/v1/signal-path');
    if (spCode == 200 && spData is Map<String, dynamic>) {
      _handleWsMessage({'type': 'SignalPathUpdated', 'payload': spData});
    }
    final (trkCode, trkData) = await _requestJson('GET', '/api/v1/library/tracks');
    if (trkCode == 200 && trkData is List) {
      _queue = trkData
          .whereType<Map<String, dynamic>>()
          .map(_parseTrackFromMap)
          .toList();
    }
  }

  int? _parseBitrateKbps(Map<String, dynamic> item) {
    final kbps = (item['bitrate_kbps'] as num?)?.toInt();
    if (kbps != null && kbps > 0) return kbps;
    final raw =
        (item['bitrate_bps'] as num?)?.toInt() ??
        (item['bitrate'] as num?)?.toInt();
    if (raw == null || raw <= 0) return null;
    return raw > 10000 ? (raw / 1000.0).round() : raw;
  }

  @override
  bool get isNativeBound => false;

  @override
  ConnectionMode get connectionMode => _mode;

  @override
  String? get activeServerUrl => _baseUrl;

  String? get bearerToken => _bearerToken;

  @override
  Stream<PlaybackState> get stateStream => _stateController.stream;

  @override
  Stream<SignalPath> get signalPathStream => _signalPathController.stream;

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  PlaybackState get currentState => _state;

  @override
  SignalPath get currentSignalPath => _signalPath;

  List<LyricLine> _currentLyrics = const [];

  @override
  List<LyricLine> get currentLyrics => _currentLyrics;

  Future<void> _fetchLyrics(String trackId, {String? path}) async {
    try {
      final res = await getLyrics(trackId, path: path);
      if (res != null && res['found'] == true && res['lines'] is List) {
        final rawLines = res['lines'] as List;
        final parsed = <LyricLine>[];
        for (final l in rawLines) {
          if (l is Map<String, dynamic>) {
            final words = <LyricWord>[];
            if (l['words'] is List) {
              for (final w in l['words']) {
                if (w is Map<String, dynamic>) {
                  words.add(
                    LyricWord(
                      text: w['text']?.toString() ?? '',
                      start: Duration(milliseconds: (w['start_ms'] as num?)?.toInt() ?? 0),
                      end: Duration(milliseconds: (w['end_ms'] as num?)?.toInt() ?? 0),
                    ),
                  );
                }
              }
            }
            parsed.add(
              LyricLine(
                start: Duration(milliseconds: (l['start_ms'] as num?)?.toInt() ?? 0),
                end: Duration(milliseconds: (l['end_ms'] as num?)?.toInt() ?? 0),
                text: l['text']?.toString() ?? '',
                words: words,
                isSynced: l['start_ms'] != null || words.isNotEmpty,
              ),
            );
          }
        }
        _currentLyrics = parsed;
      } else {
        _currentLyrics = const [];
      }
    } catch (_) {
      _currentLyrics = const [];
    }
  }

  @override
  List<TrackInfo> get queue => _queue;

  @override
  Future<int> scanDirectory(String path) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/scan',
      body: {'path': path},
    );
    await syncInitialState();
    if (code == 200 && data is Map) {
      return (data['tracks_count'] as num?)?.toInt() ?? _queue.length;
    }
    return _queue.length;
  }

  @override
  Future<List<TrackInfo>> searchLibrary(String query) async {
    final q = query.trim();
    if (q.isEmpty) return List<TrackInfo>.from(_queue);
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/search?q=${Uri.encodeQueryComponent(q)}',
    );
    if (code == 200 && data is List) {
      return data
          .whereType<Map<String, dynamic>>()
          .map(
            (e) => TrackInfo(
              id: e['id']?.toString() ?? '',
              title: e['title']?.toString() ?? '',
              artist: e['artist']?.toString() ?? '',
              album: 'Search Hit',
              duration: Duration.zero,
              format: const AudioFormat(
                codec: AudioCodec.flac,
                sampleRateHz: 44100,
                bitDepth: 16,
                channels: 2,
              ),
              providerName: 'Remote Core',
            ),
          )
          .toList();
    }
    return const [];
  }

  @override
  void setStreamingTrackHandler(StreamingTrackHandler? handler) {
    _streamingTrackHandler = handler;
  }

  @override
  void setPlaybackInterruptHandler(void Function()? handler) {
    _playbackInterruptHandler = handler;
  }

  @override
  void beginOptimisticTrackLoad(TrackInfo track, {List<TrackInfo>? queue}) {
    if (queue != null && queue.isNotEmpty) {
      _queue = List<TrackInfo>.from(queue);
    } else if (PlaybackPersistenceService.findTrackIndex(_queue, track) < 0) {
      _queue = [track, ..._queue];
    }
    _needsLoadOnResume = false;
    _lastError = null;
    _state = _state.copyWith(
      status: PlaybackStatus.loading,
      track: track,
      position: Duration.zero,
      playbackEpoch: _activeEpoch,
      clearLastError: true,
    );
    final idx = PlaybackPersistenceService.findTrackIndex(_queue, track);
    _tracker.updateActiveDeviceState(_state, queueIndex: idx >= 0 ? idx : 0);
    if (!_stateController.isClosed) _stateController.add(_state);
    if (!_positionController.isClosed) _positionController.add(Duration.zero);
  }

  @override
  void beginOptimisticTrackLoadAtEpoch(
    TrackInfo track, {
    List<TrackInfo>? queue,
    required int epoch,
  }) {
    if (epoch > _activeEpoch) {
      _activeEpoch = epoch;
      _abortActivePlayRequest();
    }
    beginOptimisticTrackLoad(track, queue: queue);
  }

  @override
  void failOptimisticTrackLoad(TrackInfo track, String message) {
    _lastError = message;
    _state = _state.copyWith(
      status: PlaybackStatus.error,
      track: track,
      position: Duration.zero,
      playbackEpoch: _activeEpoch,
      lastError: message,
    );
    if (!_stateController.isClosed) _stateController.add(_state);
  }

  @override
  Future<void> cancelPendingPlayback({int epoch = 0}) async {
    if (epoch > _activeEpoch) {
      _activeEpoch = epoch;
    }
    if (epoch > 0) {
      _lastCancelledEpoch = _activeEpoch;
    }
    _abortActivePlayRequest();
    if (_state.status == PlaybackStatus.loading) {
      _state = _state.copyWith(
        status: PlaybackStatus.stopped,
        position: Duration.zero,
        playbackEpoch: _activeEpoch,
      );
      if (!_stateController.isClosed) _stateController.add(_state);
    }
  }

  @override
  Future<void> cancelPendingPlaybackAtEpoch(int epoch) =>
      cancelPendingPlayback(epoch: epoch);

  @override
  Future<void> skipToTrack(TrackInfo track, {List<TrackInfo>? queueContext}) =>
      play(track: track);

  @override
  Future<void> play({TrackInfo? track}) async {
    if (_streamingTrackHandler != null) {
      final candidate =
          track ?? _state.track ?? (_queue.isNotEmpty ? _queue.first : null);
      final needsFreshLoad = track != null ||
          _needsLoadOnResume ||
          _state.status == PlaybackStatus.stopped ||
          _state.status == PlaybackStatus.error ||
          _state.status == PlaybackStatus.ended;
      if (candidate != null &&
          needsFreshLoad &&
          AudioService.isStreamingTrackId(candidate.id)) {
        await _streamingTrackHandler!(
          candidate,
          queueContext: null,
          debounce: false,
        );
        return;
      }
    }
    final opEpoch = ++_activeEpoch;
    _lastCancelledEpoch = 0;
    _needsLoadOnResume = false;
    _currentLyrics = const [];
    final body = <String, dynamic>{
      'playback_epoch': opEpoch,
      'epoch': opEpoch,
    };
    if (track != null) {
      if (!AudioService.isStreamingTrackId(track.id)) {
        _playbackInterruptHandler?.call();
      }
      body['track_id'] = track.id;
      if (track.filePath != null) body['file_path'] = track.filePath;
      _needsLoadOnResume = false;
      _state = _state.copyWith(
        track: track,
        playbackEpoch: opEpoch,
        clearLastError: true,
      );
    }
    final dynamic responseBody;
    try {
      final (_, data) = await _requestJson(
        'POST',
        '/api/v1/playback/play',
        body: body,
        trackAsPlayRequest: true,
      );
      responseBody = data;
    } catch (_) {
      if (_disposed || opEpoch != _activeEpoch) return;
      rethrow;
    }
    _applyPlayResponse(responseBody, opEpoch: opEpoch, track: track);
  }

  void _applyPlayResponse(
    dynamic responseBody, {
    required int opEpoch,
    TrackInfo? track,
  }) {
    if (_disposed || opEpoch != _activeEpoch) return;
    final rawStatus = responseBody is Map
        ? responseBody['status']?.toString().toLowerCase().trim()
        : null;
    if (rawStatus == 'ignored') {
      return;
    }
    _lastError = null;
    if (rawStatus == 'loading' || rawStatus == 'buffering') {
      final nextStatus = rawStatus == 'buffering'
          ? PlaybackStatus.buffering
          : PlaybackStatus.loading;
      _state = _state.copyWith(
        status: nextStatus,
        playbackEpoch: opEpoch,
        clearLastError: true,
      );
      if (!_stateController.isClosed) _stateController.add(_state);
      return;
    }
    if (track != null) {
      unawaited(_fetchLyrics(track.id, path: track.filePath));
    }
    _state = _state.copyWith(
      status: PlaybackStatus.playing,
      playbackEpoch: opEpoch,
      clearLastError: true,
    );
    if (!_stateController.isClosed) _stateController.add(_state);
  }

  @override
  Future<void> playStreamUrl({
    required TrackInfo track,
    required String streamUrl,
    Map<String, String> headers = const {},
    String? hintExtension,
  }) => _playStreamUrlInternal(
    track: track,
    streamUrl: streamUrl,
    headers: headers,
    hintExtension: hintExtension,
    epoch: _activeEpoch + 1,
  );

  Future<void> _playStreamUrlInternal({
    required TrackInfo track,
    required String streamUrl,
    Map<String, String> headers = const {},
    String? hintExtension,
    required int epoch,
    bool debounced = false,
  }) async {
    if (epoch < _activeEpoch) return;
    _activeEpoch = epoch;
    _lastCancelledEpoch = 0;
    _currentLyrics = const [];
    final body = <String, dynamic>{
      'track_id': track.id,
      'stream_url': streamUrl,
      'playback_epoch': epoch,
      'epoch': epoch,
      if (debounced) 'debounced': true,
      if (track.filePath != null) 'file_path': track.filePath,
      if (headers.isNotEmpty) 'headers': headers,
      if (hintExtension != null && hintExtension.isNotEmpty)
        'hint_extension': hintExtension,
      'source': track.providerName,
    };
    _needsLoadOnResume = false;
    _state = _state.copyWith(
      track: track,
      playbackEpoch: epoch,
      clearLastError: true,
    );
    final dynamic responseBody;
    try {
      final (_, data) = await _requestJson(
        'POST',
        '/api/v1/playback/play',
        body: body,
        trackAsPlayRequest: true,
      );
      responseBody = data;
    } catch (_) {
      if (_disposed || epoch != _activeEpoch) return;
      rethrow;
    }
    _applyPlayResponse(responseBody, opEpoch: epoch, track: track);
  }

  @override
  Future<void> playStreamUrlAsync({
    required TrackInfo track,
    required String streamUrl,
    Map<String, String> headers = const {},
    String? hintExtension,
    required int requestId,
  }) {
    if (requestId > 0 && requestId < _activeEpoch) {
      return Future<void>.value();
    }
    return _playStreamUrlInternal(
      track: track,
      streamUrl: streamUrl,
      headers: headers,
      hintExtension: hintExtension,
      epoch: requestId > 0 ? requestId : (_activeEpoch + 1),
    );
  }

  @override
  Future<void> playStreamSpecAsync(
    TrackInfo track,
    StreamSourceSpec spec, {
    required int epoch,
  }) => playStreamSpecWithOptions(track, spec, epoch: epoch, debounced: false);

  @override
  Future<void> playStreamSpecWithOptions(
    TrackInfo track,
    StreamSourceSpec spec, {
    required int epoch,
    bool debounced = false,
  }) async {
    if (spec is ExternalBackendSpec) {
      throw StateError(
        'ExternalBackendSpec (${spec.providerId}) cannot enter ServerAudioService',
      );
    }
    if (epoch < _activeEpoch) return;
    _activeEpoch = epoch;
    _lastCancelledEpoch = 0;
    _currentLyrics = const [];

    final body = <String, dynamic>{
      'track_id': track.id,
      'playback_epoch': epoch,
      'epoch': epoch,
      if (debounced) 'debounced': true,
      'source_spec': spec.toJson(),
      'source': track.providerName,
    };
    switch (spec) {
      case DirectRangeSpec():
        body['stream_url'] = spec.url;
        if (spec.headers.isNotEmpty) body['headers'] = spec.headers;
        if (spec.hintExtension != null && spec.hintExtension!.isNotEmpty) {
          body['hint_extension'] = spec.hintExtension;
        }
      case EncryptedRangeSpec():
        body['stream_url'] = spec.url;
        if (spec.headers.isNotEmpty) body['headers'] = spec.headers;
        if (spec.hintExtension != null && spec.hintExtension!.isNotEmpty) {
          body['hint_extension'] = spec.hintExtension;
        }
      case SegmentedManifestSpec():
        if (spec.headers.isNotEmpty) body['headers'] = spec.headers;
      case LocalFileSpec():
        body['file_path'] = spec.path;
      case ExternalBackendSpec():
        throw StateError(
          'ExternalBackendSpec (${spec.providerId}) cannot enter ServerAudioService',
        );
    }

    _needsLoadOnResume = false;
    _state = _state.copyWith(
      track: track,
      playbackEpoch: epoch,
      clearLastError: true,
    );
    final dynamic responseBody;
    try {
      final (_, data) = await _requestJson(
        'POST',
        '/api/v1/playback/play',
        body: body,
        trackAsPlayRequest: true,
      );
      responseBody = data;
    } catch (_) {
      if (_disposed || epoch != _activeEpoch) return;
      rethrow;
    }
    _applyPlayResponse(responseBody, opEpoch: epoch, track: track);
  }

  @override
  Future<void> restorePlaybackSession({
    required TrackInfo track,
    required Duration position,
    List<TrackInfo>? queue,
    int? queueIndex,
    double? volume,
    bool? isMuted,
  }) async {
    if (queue != null && queue.isNotEmpty) {
      _queue = List<TrackInfo>.from(queue);
    } else if (PlaybackPersistenceService.findTrackIndex(_queue, track) < 0) {
      _queue = [track, ..._queue];
    }
    final maxDur = track.duration > Duration.zero
        ? track.duration
        : const Duration(hours: 24);
    final clampedPos = position < Duration.zero
        ? Duration.zero
        : (position > maxDur ? maxDur : position);
    final effVol = (volume ?? _state.volume).clamp(0.0, 1.0);
    final muted = isMuted ?? (effVol == 0.0);
    _needsLoadOnResume = true;
    _state = PlaybackState(
      status: PlaybackStatus.paused,
      track: track,
      position: clampedPos,
      volume: effVol,
      isMuted: muted,
      seekEpoch: _state.seekEpoch,
      isSeeking: false,
      lastError: null,
      deviceLost: _state.deviceLost,
      clockSource: _state.clockSource,
    );
    _tracker.updateActiveDeviceState(_state, queueIndex: queueIndex);
    if (!_stateController.isClosed) _stateController.add(_state);
    if (!_positionController.isClosed) _positionController.add(_state.position);
  }

  @override
  Future<void> pause() async {
    _playbackInterruptHandler?.call();
    await _requestJson('POST', '/api/v1/playback/pause');
    _state = _state.copyWith(status: PlaybackStatus.paused);
    if (!_stateController.isClosed) _stateController.add(_state);
  }

  @override
  Future<void> resume() async {
    if (_needsLoadOnResume && _state.track != null) {
      await play(track: null);
      return;
    }
    await _requestJson('POST', '/api/v1/playback/resume');
    _state = _state.copyWith(status: PlaybackStatus.playing);
    if (!_stateController.isClosed) _stateController.add(_state);
  }

  @override
  Future<void> togglePlayPause() async {
    if (_state.status == PlaybackStatus.playing) {
      await pause();
    } else if (_state.status == PlaybackStatus.paused) {
      if (_needsLoadOnResume && _state.track != null) {
        await play(track: null);
      } else {
        await resume();
      }
    } else {
      await play();
    }
  }

  @override
  Future<void> reconnectDevice() async {
    await _requestJson('POST', '/api/v1/playback/reconnect');
  }

  @override
  Future<Map<String, dynamic>?> getPlaybackState() async {
    final (code, data) = await _requestJson('GET', '/api/v1/playback/state');
    if (code == 200 && data is Map<String, dynamic>) {
      return data;
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>?> getArtwork(
    String trackId, {
    String? path,
    int maxDim = 512,
  }) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/artwork/${Uri.encodeComponent(trackId)}?max_dim=$maxDim',
    );
    if (code == 200 && data is Map<String, dynamic>) return data;
    return null;
  }

  @override
  Future<bool> setUserCover(
    String trackId,
    String imagePath, {
    String? path,
  }) async {
    final (code, _) = await _requestJson(
      'POST',
      '/api/v1/library/artwork/${Uri.encodeComponent(trackId)}/override',
      body: {'image_path': imagePath, 'file_path': ?path},
    );
    return code == 200;
  }

  @override
  Future<bool> clearUserCover(String trackId, {String? path}) async {
    final (code, _) = await _requestJson(
      'DELETE',
      '/api/v1/library/artwork/${Uri.encodeComponent(trackId)}/override',
    );
    return code == 200;
  }

  @override
  Future<Map<String, dynamic>?> rescanTags({
    String? directory,
    bool force = false,
  }) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/rescan',
      body: {'directory': directory, 'force': force},
    );
    if (code == 200 && data is Map<String, dynamic>) return data;
    return null;
  }

  @override
  Future<Map<String, dynamic>?> getLyrics(
    String trackId, {
    String? path,
  }) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/lyrics/${Uri.encodeComponent(trackId)}',
    );
    if (code == 200 && data is Map<String, dynamic>) return data;
    return null;
  }

  @override
  Future<bool> setUserLyrics(
    String trackId,
    String filePath, {
    String? path,
  }) async {
    final (code, _) = await _requestJson(
      'POST',
      '/api/v1/lyrics/${Uri.encodeComponent(trackId)}/override',
      body: {'file_path': filePath, 'path': ?path},
    );
    if (code == 200) {
      unawaited(_fetchLyrics(trackId, path: path));
      return true;
    }
    return false;
  }

  @override
  Future<bool> clearUserLyrics(String trackId, {String? path}) async {
    final (code, _) = await _requestJson(
      'DELETE',
      '/api/v1/lyrics/${Uri.encodeComponent(trackId)}/override',
    );
    if (code == 200) {
      _currentLyrics = const [];
      return true;
    }
    return false;
  }

  @override
  Future<void> stop() async {
    _playbackInterruptHandler?.call();
    _abortActivePlayRequest();
    if (_activeEpoch > 0 && _activeEpoch != _lastCancelledEpoch) {
      _activeEpoch++;
    }
    _lastCancelledEpoch = 0;
    final stopEpoch = _activeEpoch;
    await _requestJson('POST', '/api/v1/playback/stop');
    if (_disposed || stopEpoch != _activeEpoch) return;
    _state = _state.copyWith(
      status: PlaybackStatus.stopped,
      position: Duration.zero,
      playbackEpoch: _activeEpoch,
    );
    if (!_stateController.isClosed) _stateController.add(_state);
  }

  @override
  Future<void> seek(Duration position) async {
    await _requestJson(
      'POST',
      '/api/v1/playback/seek',
      body: {'position_ms': position.inMilliseconds},
    );
    _state = _state.copyWith(position: position);
    if (!_stateController.isClosed) _stateController.add(_state);
  }

  @override
  Future<void> setVolume(double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    await _requestJson(
      'POST',
      '/api/v1/playback/volume',
      body: {'volume': clamped},
    );
    _state = _state.copyWith(volume: clamped, isMuted: clamped == 0.0);
    if (!_stateController.isClosed) _stateController.add(_state);
  }

  @override
  Future<void> toggleMute() async {
    final nextMuted = !_state.isMuted;
    await setVolume(nextMuted ? 0.0 : _state.volume);
    _state = _state.copyWith(isMuted: nextMuted);
  }

  @override
  Future<void> next() async {
    await _requestJson('POST', '/api/v1/playback/next');
  }

  @override
  Future<void> previous() async {
    await _requestJson('POST', '/api/v1/playback/previous');
  }

  @override
  Future<void> toggleDspBypass() async {
    final cfg = await getDspConfig();
    await setDspConfig(cfg.copyWith(bypass: !cfg.bypass));
  }

  @override
  void setSimulatedQuality(SignalQuality quality) {}

  @override
  Future<List<CanonicalAlbumSummary>> getAlbums({int limit = 100}) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/albums?limit=$limit',
    );
    if (code == 200 && data is List) {
      return data
          .whereType<Map<String, dynamic>>()
          .map(CanonicalAlbumSummary.fromJson)
          .toList();
    }
    return const [];
  }

  @override
  Future<CanonicalAlbumDetail?> getAlbumDetail(String albumId) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/albums/${Uri.encodeComponent(albumId)}',
    );
    if (code == 200 && data is Map<String, dynamic>) {
      return CanonicalAlbumDetail.fromJson(data);
    }
    return null;
  }

  @override
  Future<ArtistDetailInfo?> getArtistDetail(String artistId) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/artists/${Uri.encodeComponent(artistId)}',
    );
    if (code == 200 && data is Map<String, dynamic>) {
      return ArtistDetailInfo.fromJson(data);
    }
    return null;
  }

  @override
  Future<int> deduplicateLibrary() async {
    final (code, data) = await _requestJson('POST', '/api/v1/library/deduplicate');
    if (code == 200 && data is Map) {
      return (data['merged_albums'] as num?)?.toInt() ?? 0;
    }
    return 0;
  }

  @override
  Future<Map<String, dynamic>> enrichLibraryCredits({
    String? musicBrainzBaseUrl,
    String? discogsBaseUrl,
  }) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/enrich',
      body: {
        'musicbrainz_base_url': ?musicBrainzBaseUrl,
        'discogs_base_url': ?discogsBaseUrl,
      },
    );
    if (code == 200 && data is Map<String, dynamic>) return data;
    return const {};
  }

  @override
  Future<DspPipelineConfigModel> getDspConfig() async {
    final (code, data) = await _requestJson('GET', '/api/v1/dsp/config');
    if (code == 200 && data is Map<String, dynamic>) {
      return DspPipelineConfigModel.fromJson(data);
    }
    return const DspPipelineConfigModel();
  }

  @override
  Future<void> setDspConfig(DspPipelineConfigModel config) async {
    await _requestJson('PUT', '/api/v1/dsp/config', body: config.toJson());
    await syncInitialState();
  }

  @override
  Future<List<PeqBandModel>> importAutoEqProfile(String autoEqTxt) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/dsp/autoeq',
      body: {'text': autoEqTxt, 'apply': true},
    );
    if (code == 200 && data is Map<String, dynamic>) {
      final raw = data['peq_bands'] as List<dynamic>? ?? const [];
      return raw
          .whereType<Map<String, dynamic>>()
          .map(PeqBandModel.fromJson)
          .toList();
    }
    return const [];
  }

  @override
  Future<List<AudioDeviceInfo>> listAudioDevices() async {
    final (code, data) = await _requestJson('GET', '/api/v1/audio/devices');
    if (code == 200 && data is List) {
      final devs = data
          .whereType<Map<String, dynamic>>()
          .map(AudioDeviceInfo.fromJson)
          .toList();
      _tracker.syncActiveFromDevices(devs);
      return devs;
    }
    return const [];
  }

  @override
  Future<void> setDeviceVolume(String deviceId, double volume) async {
    if (deviceId == activeDeviceId) {
      await setVolume(volume);
      return;
    }
    _tracker.setDeviceVolume(deviceId, volume);
  }

  @override
  Future<void> toggleDevicePlayPause(String deviceId) async {
    if (deviceId == activeDeviceId) {
      await togglePlayPause();
      return;
    }
    await selectAudioDevice(deviceId);
    if (_state.status == PlaybackStatus.playing) {
      await pause();
    } else {
      await play(track: _state.track ?? _queue.firstOrNull);
    }
  }

  @override
  Future<void> toggleZonePlayPause(String zoneId) async {
    final zones = await listZones();
    final z = zones.where((item) => item.id == zoneId).firstOrNull;
    final isPlaying =
        zonePlaybackStates[zoneId]?.status == PlaybackStatus.playing;
    if (z == null || !z.backend.startsWith('network_')) {
      await togglePlayPause();
      _tracker.updateZoneAction(
        zoneId,
        _state.status == PlaybackStatus.playing ? 'play' : 'pause',
        track: _state.track,
      );
      return;
    }
    await castToZone(zoneId, isPlaying ? 'pause' : 'play');
  }

  @override
  Future<void> selectAudioDevice(String? deviceId, {int backendIndex = -1}) async {
    final res = _tracker.switchDevice(
      nextDeviceId: deviceId,
      currentState: _state,
      currentQueueIndex: 0,
    );
    await _requestJson(
      'POST',
      '/api/v1/audio/devices/select',
      body: {'device_id': deviceId},
    );
    if (res.switched) {
      _state = res.restoredState;
      _tracker.updateActiveDeviceState(_state);
      if (!_stateController.isClosed) _stateController.add(_state);
    }
  }

  @override
  Future<List<AudioZoneInfo>> listZones() async {
    final (code, data) = await _requestJson('GET', '/api/v1/zones');
    if (code == 200 && data is List) {
      final zones = data
          .whereType<Map<String, dynamic>>()
          .map(AudioZoneInfo.fromJson)
          .toList();
      _tracker.syncZones(zones, activeLocalState: _state);
      return zones;
    }
    return const [];
  }

  @override
  Future<List<AudioZoneInfo>> discoverZones({
    String? ssdpAddr,
    List<String>? airplayAddrs,
    String? clockSyncAddr,
  }) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/zones/discover',
      body: {
        'ssdp_addr': ?ssdpAddr,
        'airplay_addrs': ?airplayAddrs,
        'clock_sync_addr': ?clockSyncAddr,
      },
    );
    if (code == 200 && data is List) {
      final zones = data
          .whereType<Map<String, dynamic>>()
          .map(AudioZoneInfo.fromJson)
          .toList();
      _tracker.syncZones(zones, activeLocalState: _state);
      return zones;
    }
    return const [];
  }

  @override
  Future<void> groupZones(String groupId, List<String> zoneIds) async {
    await _requestJson(
      'POST',
      '/api/v1/zones/group',
      body: {'group_id': groupId, 'zone_ids': zoneIds},
    );
  }

  @override
  Future<void> setZoneVolume(String zoneId, double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    await _requestJson(
      'POST',
      '/api/v1/zones/${Uri.encodeComponent(zoneId)}/volume',
      body: {'volume': clamped},
    );
    _tracker.setZoneVolume(zoneId, clamped);
  }

  @override
  Future<ClockSyncMeasurementModel> syncZoneClock(
    String zoneId, {
    String? clockAddr,
  }) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/zones/${Uri.encodeComponent(zoneId)}/sync',
      body: {'clock_addr': ?clockAddr},
    );
    if (code == 200 && data is Map<String, dynamic>) {
      return ClockSyncMeasurementModel.fromJson(zoneId, data);
    }
    return ClockSyncMeasurementModel(
      zoneId: zoneId,
      offsetUs: 0,
      rttUs: 0,
      driftPpm: 0.0,
    );
  }

  @override
  Future<Map<String, dynamic>> castToZone(
    String zoneId,
    String action, {
    String? mediaUri,
  }) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/zones/${Uri.encodeComponent(zoneId)}/cast',
      body: {'action': action, 'media_uri': ?mediaUri},
    );
    _tracker.updateZoneAction(
      zoneId,
      action,
      track: _state.track ?? _queue.firstOrNull,
    );
    if (code == 200 && data is Map<String, dynamic>) return data;
    return const {};
  }

  @override
  Future<List<ProviderStatusInfo>> listProviders() async {
    final (code, data) = await _requestJson('GET', '/api/v1/providers');
    if (code == 200 && data is List) {
      return data
          .whereType<Map<String, dynamic>>()
          .map(ProviderStatusInfo.fromJson)
          .toList();
    }
    return const [];
  }

  @override
  Future<bool> configureProvider(String kind, Map<String, dynamic> config) async {
    final route = switch (kind) {
      'qobuz' => '/api/v1/providers/qobuz',
      'deezer' => '/api/v1/providers/deezer',
      'web_dav' || 'webdav' => '/api/v1/providers/webdav',
      'smb' => '/api/v1/providers/smb',
      _ => '/api/v1/providers/local',
    };
    final (code, _) = await _requestJson('POST', route, body: config);
    return code == 200;
  }

  @override
  Future<TidalPkceStartInfo?> startTidalPkce() async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/providers/tidal/pkce/start',
      body: const {},
    );
    if (code == 200 && data is Map<String, dynamic>) {
      return TidalPkceStartInfo.fromJson(data);
    }
    return null;
  }

  @override
  Future<bool> completeTidalPkce(String code, String codeVerifier) async {
    final (status, _) = await _requestJson(
      'POST',
      '/api/v1/providers/tidal/pkce/exchange',
      body: {'code': code, 'code_verifier': codeVerifier},
    );
    return status == 200;
  }

  @override
  Future<Map<String, dynamic>> syncProvider(String kind) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/providers/${Uri.encodeComponent(kind)}/sync',
    );
    if (code == 200 && data is Map<String, dynamic>) return data;
    return const {};
  }

  @override
  Future<List<UserProfileInfo>> listProfiles() async {
    final (code, data) = await _requestJson('GET', '/api/v1/profiles');
    if (code == 200 && data is Map<String, dynamic>) {
      final list = data['profiles'] as List<dynamic>? ?? const [];
      return list
          .whereType<Map<String, dynamic>>()
          .map(UserProfileInfo.fromJson)
          .toList();
    }
    return const [];
  }

  @override
  Future<UserProfileInfo> createProfile(
    String name, {
    String avatarColor = '#007AFF',
  }) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/profiles',
      body: {'name': name, 'avatar_color': avatarColor},
    );
    if (code == 200 && data is Map<String, dynamic>) {
      return UserProfileInfo.fromJson(data);
    }
    return UserProfileInfo(id: 'local', name: name, avatarColor: avatarColor);
  }

  @override
  Future<bool> updateProfile(
    String profileId, {
    String? name,
    String? avatarColor,
    bool? isDefault,
  }) async {
    final (code, _) = await _requestJson(
      'PUT',
      '/api/v1/profiles/${Uri.encodeComponent(profileId)}',
      body: {
        'name': ?name,
        'avatar_color': ?avatarColor,
        'is_default': ?isDefault,
      },
    );
    return code == 200;
  }

  @override
  Future<void> switchProfile(String profileId) async {
    await _requestJson(
      'POST',
      '/api/v1/profiles/${Uri.encodeComponent(profileId)}/activate',
    );
  }

  @override
  Future<bool> deleteProfile(String profileId) async {
    final (code, _) = await _requestJson(
      'DELETE',
      '/api/v1/profiles/${Uri.encodeComponent(profileId)}',
    );
    return code == 200;
  }

  @override
  Future<PairingInitiateInfo?> initiateHostPairing() async {
    final uri = Uri.tryParse(_baseUrl);
    final host = (uri != null && uri.host.isNotEmpty) ? uri.host : '127.0.0.1';
    final port = (uri != null && uri.hasPort) ? uri.port : 9888;
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/pair/initiate',
      body: {
        'device_name': 'Lumina-Host',
        'host': host,
        'port': port,
      },
      authenticated: false,
    );
    if (code == 200 && data is Map<String, dynamic>) {
      return PairingInitiateInfo.fromJson(data);
    }
    return null;
  }

  @override
  Future<List<DiscoveredServerInfo>> discoverLanServers({
    String multicastHost = '224.0.0.251',
    int port = 5353,
    Duration timeout = const Duration(milliseconds: 500),
  }) {
    return MdnsDiscoveryClient.discover(
      targetHost: multicastHost,
      port: port,
      timeout: timeout,
    );
  }

  @override
  Future<String?> pairAndConnectRemote({
    required String baseUrl,
    required String pin,
    String deviceName = 'Lumina Mobile',
    bool allowSelfSignedTls = false,
  }) async {
    _baseUrl = _normalizeBaseUrl(baseUrl);
    _allowSelfSignedTls = allowSelfSignedTls;
    _mode = _baseUrl.startsWith('https://')
        ? ConnectionMode.wanRemote
        : ConnectionMode.lanRemote;

    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/pair/verify',
      body: {
        'pin': pin,
        'client_id': 'flutter-${DateTime.now().millisecondsSinceEpoch}',
        'device_name': deviceName,
        'platform': Platform.operatingSystem,
      },
      authenticated: false,
    );
    if (code == 200 && data is Map<String, dynamic>) {
      final token = data['token']?.toString();
      if (token != null && token.isNotEmpty) {
        _bearerToken = token;
        await connectWebSocket();
        await syncInitialState();
        return token;
      }
    }
    return null;
  }

  @override
  Future<bool> connectWanDirect({
    required String httpsBaseUrl,
    String? bearerToken,
    String? pin,
    bool allowSelfSignedTls = false,
  }) async {
    _baseUrl = _normalizeBaseUrl(httpsBaseUrl);
    _allowSelfSignedTls = allowSelfSignedTls;
    _mode = ConnectionMode.wanRemote;

    if (bearerToken != null && bearerToken.trim().isNotEmpty) {
      _bearerToken = bearerToken.trim();
      final healthy = await checkHealth();
      if (!healthy) return false;
      await connectWebSocket();
      await syncInitialState();
      return true;
    }
    if (pin != null && pin.trim().length == 6) {
      final tok = await pairAndConnectRemote(
        baseUrl: httpsBaseUrl,
        pin: pin.trim(),
        allowSelfSignedTls: allowSelfSignedTls,
      );
      return tok != null;
    }
    return checkHealth();
  }

  @override
  bool get isSystemOutputActive => false;

  @override
  String? get lastError => _lastError ?? _state.lastError;

  @override
  int get preferredBufferFrames => 512;

  @override
  Future<bool> setBufferFrames(int frames) async => false;

  @override
  bool get isStrictBitPerfect => false;

  @override
  DsdOutputModeOption get dsdOutputMode => DsdOutputModeOption.auto;

  @override
  Future<void> setStrictBitPerfect(bool enabled) async {}

  @override
  Future<void> setDsdOutputMode(DsdOutputModeOption mode) async {}

  @override
  Future<List<AudioDeviceCapabilitiesModel>> listDeviceCapabilities() async => const [];

  @override
  Future<AudioEngineOutputInfoModel> getOutputInfo() async =>
      const AudioEngineOutputInfoModel();

  @override
  Future<void> switchToLocalMode() async {
    await _wsSub?.cancel();
    await _ws?.close();
    _ws = null;
    _mode = ConnectionMode.localOrUsbDac;
  }

  @override
  Stream<ScanProgressEvent> get scanProgressStream =>
      _scanProgressController.stream;

  @override
  Future<String?> startDirectoryScan(String path, {bool force = false}) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/scan/start',
      body: <String, dynamic>{'dir_path': path, 'force': force},
    );
    if (code == 200 && data is Map) {
      return data['scan_id']?.toString();
    }
    return null;
  }

  @override
  Future<List<WatchedRootRecord>> listWatchedRoots() async {
    final (code, data) = await _requestJson('GET', '/api/v1/library/watch');
    if (code == 200 && data is List) {
      return data
          .whereType<Map>()
          .map((e) => WatchedRootRecord.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    }
    return const [];
  }

  @override
  Future<WatchedRootRecord?> addWatchedRoot(
    String rootPath, {
    WatchMode watchMode = WatchMode.nativeOs,
    int pollIntervalSec = 300,
  }) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/watch',
      body: <String, dynamic>{
        'root_path': rootPath,
        'watch_mode': watchMode.toJson(),
        'poll_interval_sec': pollIntervalSec,
      },
    );
    if (code == 200 && data is Map) {
      return WatchedRootRecord.fromJson(Map<String, dynamic>.from(data));
    }
    return null;
  }

  @override
  Future<bool> removeWatchedRoot(String rootPath) async {
    final (code, data) = await _requestJson(
      'DELETE',
      '/api/v1/library/watch?root_path=${Uri.encodeQueryComponent(rootPath)}',
    );
    if (code == 200 || code == 204) {
      if (data is Map) return data['ok'] != false;
      return true;
    }
    return false;
  }

  @override
  Future<List<SkippedFileRecord>> getSkippedFiles({
    bool includeDismissed = false,
  }) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/skipped?include_dismissed=$includeDismissed',
    );
    if (code == 200 && data is List) {
      return data
          .whereType<Map>()
          .map((e) => SkippedFileRecord.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    }
    return const [];
  }

  @override
  Future<bool> dismissSkippedFile(String skippedId) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/skipped/${Uri.encodeComponent(skippedId)}/dismiss',
    );
    if (code == 200) {
      if (data is Map) return data['ok'] != false;
      return true;
    }
    return false;
  }

  @override
  Future<Map<String, dynamic>> retrySkippedFile(String skippedId) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/skipped/${Uri.encodeComponent(skippedId)}/retry',
    );
    if (code == 200 && data is Map) {
      return Map<String, dynamic>.from(data);
    }
    return const <String, dynamic>{
      'status': 'not_found',
      'detail': 'Retry request failed',
    };
  }

  @override
  Future<bool> setMetadataOverride(
    String entityType,
    String entityId,
    String fieldName,
    dynamic value,
  ) async {
    final (code, data) = await _requestJson(
      'PUT',
      '/api/v1/library/overrides/${Uri.encodeComponent(entityType)}/${Uri.encodeComponent(entityId)}',
      body: <String, dynamic>{
        'field_name': fieldName,
        'value_json': jsonEncode(value),
      },
    );
    if (code == 200) {
      if (data is Map) return data['ok'] != false;
      return true;
    }
    return false;
  }

  @override
  Future<bool> clearMetadataOverride(
    String entityType,
    String entityId,
    String fieldName,
  ) async {
    final (code, data) = await _requestJson(
      'DELETE',
      '/api/v1/library/overrides/${Uri.encodeComponent(entityType)}/${Uri.encodeComponent(entityId)}/${Uri.encodeComponent(fieldName)}',
    );
    if (code == 200 || code == 204) {
      if (data is Map) return data['ok'] != false;
      return true;
    }
    return false;
  }

  @override
  Future<List<MetadataOverrideRecord>> getMetadataOverrides(
    String entityType,
    String entityId,
  ) async {
    final (code, data) = await _requestJson(
      'GET',
      '/api/v1/library/overrides/${Uri.encodeComponent(entityType)}/${Uri.encodeComponent(entityId)}',
    );
    if (code == 200 && data is List) {
      return data
          .whereType<Map>()
          .map(
            (e) => MetadataOverrideRecord.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(growable: false);
    }
    return const [];
  }

  @override
  Future<Map<String, int>> ingestExternalCatalog(
    ExternalCatalogIngestBatch batch,
  ) async {
    final (code, data) = await _requestJson(
      'POST',
      '/api/v1/library/ingest',
      body: batch.toJson(),
    );
    if (code == 200 && data is Map) {
      return <String, int>{
        'albums_ingested': (data['albums_ingested'] as num?)?.toInt() ?? 0,
        'tracks_ingested': (data['tracks_ingested'] as num?)?.toInt() ?? 0,
      };
    }
    return const <String, int>{'albums_ingested': 0, 'tracks_ingested': 0};
  }

  @override
  void dispose() {
    _disposed = true;
    _abortActivePlayRequest();
    _wsSub?.cancel();
    _ws?.close();
    _stateController.close();
    _signalPathController.close();
    _positionController.close();
    _scanProgressController.close();
  }
}


