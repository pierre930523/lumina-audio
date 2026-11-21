import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../models/audio_format.dart';
import '../../../models/playback_state.dart';
import '../../../models/streaming_models.dart';
import '../../../models/studio_models.dart';
import '../oauth_helper.dart';
import '../streaming_provider.dart';

/// Real YouTube Music InnerTube + Google OAuth 2.0 Device Flow provider.
class YouTubeMusicProvider extends BaseStreamingProvider {
  static const String _ytMusicOrigin = 'https://music.youtube.com';
  static const String _youtubeScope =
      'https://www.googleapis.com/auth/youtube.readonly';

  static const Map<String, dynamic> _webRemixContext = <String, dynamic>{
    'client': <String, dynamic>{
      'clientName': 'WEB_REMIX',
      'clientVersion': '1.20241120.01.00',
      'hl': 'zh-TW',
      'gl': 'TW',
    },
  };

  static const Map<String, dynamic> _androidMusicContext = <String, dynamic>{
    'client': <String, dynamic>{
      'clientName': 'ANDROID_MUSIC',
      'clientVersion': '7.21.50',
      'androidSdkVersion': 34,
      'hl': 'zh-TW',
      'gl': 'TW',
    },
  };

  static const Map<String, dynamic> _iosMusicContext = <String, dynamic>{
    'client': <String, dynamic>{
      'clientName': 'IOS_MUSIC',
      'clientVersion': '7.21',
      'deviceMake': 'Apple',
      'deviceModel': 'iPhone16,2',
      'osVersion': '17.5.1.21F90',
      'hl': 'zh-TW',
      'gl': 'TW',
    },
  };

  final String baseUrl;
  final String oauthBaseUrl;
  final Future<bool> Function(String url)? urlOpener;

  String _authMode = 'cookie';
  String? _cookie;
  String? _clientId;
  String? _clientSecret;
  String? _accessToken;
  String? _refreshToken;
  DateTime? _expiresAt;

  YouTubeMusicProvider({
    required super.credentialStore,
    super.httpClientFactory,
    super.requestTimeout,
    super.clock,
    this.baseUrl = _ytMusicOrigin,
    this.oauthBaseUrl = 'https://oauth2.googleapis.com',
    this.urlOpener,
  });

  @override
  String get kind => 'youtube_music';

  /// Parses `SAPISID` / `__Secure-3PAPISID` / `__Secure-1PAPISID` from a browser
  /// Cookie header and computes the Google `SAPISIDHASH` Authorization value.
  static String? extractSapisidFromCookie(String cookieHeader) {
    final map = <String, String>{};
    for (final part in cookieHeader.split(';')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      final name = part.substring(0, idx).trim();
      var value = part.substring(idx + 1).trim();
      if (value.length >= 2 &&
          value.startsWith('"') &&
          value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      if (name.isNotEmpty && value.isNotEmpty) {
        map[name] = value;
      }
    }
    return map['SAPISID'] ??
        map['__Secure-3PAPISID'] ??
        map['__Secure-1PAPISID'];
  }

  static String computeSapisidHash(
    String sapisid, {
    required int timestampSeconds,
    String origin = _ytMusicOrigin,
  }) {
    final digest = sha1
        .convert(utf8.encode('$timestampSeconds $sapisid $origin'))
        .toString();
    return 'SAPISIDHASH ${timestampSeconds}_$digest';
  }

  Map<String, String> _buildInnerTubeHeaders() {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'X-Origin': _ytMusicOrigin,
      'Origin': _ytMusicOrigin,
      'Referer': '$_ytMusicOrigin/',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    };

    if (_authMode == 'cookie' && _cookie != null && _cookie!.isNotEmpty) {
      final sapisid = extractSapisidFromCookie(_cookie!);
      if (sapisid == null || sapisid.isEmpty) {
        throw const StreamingException(
          'Cookie 缺少 SAPISID 或 __Secure-3PAPISID，無法產生授權簽章',
          statusCode: 401,
        );
      }
      final ts = clock().millisecondsSinceEpoch ~/ 1000;
      headers['Cookie'] = _cookie!;
      headers['Authorization'] = computeSapisidHash(sapisid, timestampSeconds: ts);
    } else if (_accessToken != null && _accessToken!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $_accessToken';
    }
    return headers;
  }

  @override
  Future<void> restoreFromStorage() async {
    try {
      final stored = await readCredentialsJson();
      if (stored == null) {
        resetState();
        return;
      }

      _authMode = stored['mode']?.toString() ?? 'cookie';
      _cookie = stored['cookie']?.toString();
      _clientId = stored['client_id']?.toString();
      _clientSecret = stored['client_secret']?.toString();
      _accessToken = stored['access_token']?.toString();
      _refreshToken = stored['refresh_token']?.toString();
      final expRaw = stored['expires_at']?.toString();
      _expiresAt = expRaw != null ? DateTime.tryParse(expRaw) : null;

      await refreshSessionIfNeeded();
      final account = await _verifyAccountLive();
      setConnected(account);
      await _persistCredentials(account);
    } catch (e) {
      throw failWithError(e);
    }
  }

  @override
  Future<void> authenticate(
    Map<String, dynamic> params, {
    CancellationToken? cancel,
    void Function(String statusMsg)? onProgress,
  }) async {
    setAuthenticating();
    try {
      cancel?.throwIfCancelled();

      final requestedMode = params['mode']?.toString().trim();
      final cookieVal =
          (params['cookie'] ?? params['auth_cookie'])?.toString().trim();

      final mode = (requestedMode != null && requestedMode.isNotEmpty)
          ? requestedMode
          : (cookieVal != null && cookieVal.isNotEmpty
                ? 'cookie'
                : 'oauth_device');

      if (mode == 'cookie') {
        if (cookieVal == null || cookieVal.isEmpty) {
          throw const StreamingException('請輸入包含 SAPISID 的 YouTube Music Cookie');
        }
        final sapisid = extractSapisidFromCookie(cookieVal);
        if (sapisid == null || sapisid.isEmpty) {
          throw const StreamingException(
            'Cookie 缺少 SAPISID 或 __Secure-3PAPISID，無法驗證 YouTube Music 身分',
            statusCode: 401,
          );
        }

        _authMode = 'cookie';
        _cookie = cookieVal;
        _accessToken = null;
        _refreshToken = null;
        _expiresAt = null;

        onProgress?.call('正在向 YouTube Music 驗證 Cookie 工作階段...');
        final account = await _verifyAccountLive(cancel: cancel);
        setConnected(account);
        await _persistCredentials(account);
        return;
      }

      if (mode == 'oauth_device') {
        final clientId = params['client_id']?.toString().trim() ?? '';
        final clientSecret = params['client_secret']?.toString().trim() ?? '';
        if (clientId.isEmpty) {
          throw const StreamingException(
            'Google OAuth 裝置授權需要提供 client_id',
          );
        }

        _authMode = 'oauth_device';
        _clientId = clientId;
        _clientSecret = clientSecret;
        _cookie = null;

        onProgress?.call('正在向 Google OAuth 請求裝置授權碼...');
        final deviceUri =
            BaseStreamingProvider.buildUri(oauthBaseUrl, '/device/code');
        final deviceResp = await http.requestJson(
          method: 'POST',
          uri: deviceUri,
          formBody: BaseStreamingProvider.encodeForm(<String, String>{
            'client_id': clientId,
            'scope': _youtubeScope,
          }),
          cancel: cancel,
        );

        final deviceCode = deviceResp['device_code']?.toString() ?? '';
        final userCode = deviceResp['user_code']?.toString() ?? '';
        final verificationUrl =
            (deviceResp['verification_url'] ?? deviceResp['verification_uri'])
                ?.toString() ??
            'https://www.google.com/device';
        final expiresIn = (deviceResp['expires_in'] as num?)?.toInt() ?? 1800;
        final intervalSec = (deviceResp['interval'] as num?)?.toInt() ?? 5;

        if (deviceCode.isEmpty || userCode.isEmpty) {
          throw const StreamingException(
            'Google OAuth 未回傳有效的 device_code 或 user_code',
          );
        }

        onProgress?.call('請開啟 $verificationUrl 並輸入代碼：$userCode');
        try {
          await openSystemBrowser(verificationUrl, urlOpener: urlOpener);
        } catch (_) {
          // Non-fatal: user already received verification URL and code in progress callback.
        }

        final deadline = clock().add(Duration(seconds: expiresIn));
        var pollDelay = intervalSec <= 0
            ? const Duration(milliseconds: 25)
            : Duration(seconds: intervalSec);
        final tokenUri =
            BaseStreamingProvider.buildUri(oauthBaseUrl, '/token');

        while (true) {
          cancel?.throwIfCancelled();
          if (clock().isAfter(deadline)) {
            throw const StreamingException(
              'Google 裝置授權碼已過期，請重新登入',
              isTokenExpired: true,
            );
          }

          await BaseStreamingProvider.cancellableDelay(pollDelay, cancel);

          final tokenForm = <String, String>{
            'client_id': clientId,
            if (clientSecret.isNotEmpty) 'client_secret': clientSecret,
            'device_code': deviceCode,
            'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          };
          final res = await http.sendJsonRaw(
            method: 'POST',
            uri: tokenUri,
            formBody: BaseStreamingProvider.encodeForm(tokenForm),
            cancel: cancel,
          );

          if (res.statusCode >= 200 && res.statusCode < 300) {
            final access = res.json['access_token']?.toString().trim() ?? '';
            if (access.isEmpty) {
              throw const StreamingException('Google OAuth 未回傳 access_token');
            }
            _accessToken = access;
            final refresh = res.json['refresh_token']?.toString().trim();
            if (refresh != null && refresh.isNotEmpty) {
              _refreshToken = refresh;
            }
            final expSec = (res.json['expires_in'] as num?)?.toInt() ?? 3600;
            _expiresAt = clock().add(Duration(seconds: expSec));
            break;
          }

          final errCode = res.json['error']?.toString() ?? '';
          if (errCode == 'authorization_pending') {
            continue;
          }
          if (errCode == 'slow_down') {
            pollDelay += intervalSec <= 0
                ? const Duration(milliseconds: 25)
                : const Duration(seconds: 5);
            continue;
          }

          throw StreamingException(
            StreamingHttpClient.extractApiErrorMessage(
              res.json,
              res.rawBody,
              res.statusCode,
            ),
            statusCode: res.statusCode,
            isTokenExpired: errCode == 'expired_token' || res.statusCode == 401,
          );
        }

        onProgress?.call('正在驗證 YouTube Music 帳號資訊...');
        final account = await _verifyAccountLive(cancel: cancel);
        setConnected(account);
        await _persistCredentials(account);
        return;
      }

      throw StreamingException('不支援的 YouTube Music 驗證模式：$mode');
    } catch (e) {
      throw failWithError(e);
    }
  }

  @override
  Future<void> refreshSessionIfNeeded() async {
    if (_authMode != 'oauth_device') return;
    final exp = _expiresAt;
    if (exp == null) return;
    if (clock().isBefore(exp.subtract(const Duration(seconds: 60)))) {
      return;
    }

    final refresh = _refreshToken;
    final clientId = _clientId;
    if (refresh == null ||
        refresh.isEmpty ||
        clientId == null ||
        clientId.isEmpty) {
      throw failWithError(
        const StreamingException(
          'YouTube Music OAuth 權杖已過期且無法自動續期',
          statusCode: 401,
          isTokenExpired: true,
        ),
      );
    }

    try {
      final tokenUri = BaseStreamingProvider.buildUri(oauthBaseUrl, '/token');
      final res = await http.requestJson(
        method: 'POST',
        uri: tokenUri,
        formBody: BaseStreamingProvider.encodeForm(<String, String>{
          'client_id': clientId,
          if (_clientSecret != null && _clientSecret!.isNotEmpty)
            'client_secret': _clientSecret!,
          'refresh_token': refresh,
          'grant_type': 'refresh_token',
        }),
      );

      final nextAccess = res['access_token']?.toString().trim() ?? '';
      if (nextAccess.isEmpty) {
        throw const StreamingException(
          'Google OAuth 權杖更新失敗：未回傳新的 access_token',
          statusCode: 401,
          isTokenExpired: true,
        );
      }
      _accessToken = nextAccess;
      final nextRefresh = res['refresh_token']?.toString().trim();
      if (nextRefresh != null && nextRefresh.isNotEmpty) {
        _refreshToken = nextRefresh;
      }
      final expSec = (res['expires_in'] as num?)?.toInt() ?? 3600;
      _expiresAt = clock().add(Duration(seconds: expSec));

      if (accountInfo != null) {
        final updated = accountInfo!.copyWith(expiresAt: _expiresAt);
        setConnected(updated);
        await _persistCredentials(updated);
      }
    } catch (e) {
      throw failWithError(
        e is StreamingException
            ? e
            : StreamingException(
                'YouTube Music OAuth 權杖更新失敗：$e',
                statusCode: 401,
                isTokenExpired: true,
              ),
      );
    }
  }

  @override
  Future<void> logout() async {
    _cookie = null;
    _accessToken = null;
    _refreshToken = null;
    _clientId = null;
    _clientSecret = null;
    _expiresAt = null;
    await clearCredentials();
    resetState();
  }

  Future<StreamingAccountInfo> _verifyAccountLive({
    CancellationToken? cancel,
  }) async {
    final uri = BaseStreamingProvider.buildUri(
      baseUrl,
      '/youtubei/v1/account/account_menu',
      const <String, String>{'prettyPrint': 'false'},
    );
    final json = await http.requestJson(
      method: 'POST',
      uri: uri,
      headers: _buildInnerTubeHeaders(),
      jsonBody: const <String, dynamic>{'context': _webRemixContext},
      cancel: cancel,
    );

    final header = _findFirstMapByKey(json, 'activeAccountHeaderRenderer');
    if (header == null) {
      throw const StreamingException(
        'YouTube Music 未回傳登入帳號資訊，Cookie 或授權權杖可能已失效',
        statusCode: 401,
        isTokenExpired: true,
      );
    }

    final displayName = _extractInnerTubeText(header['accountName']);
    if (displayName == null || displayName.trim().isEmpty) {
      throw const StreamingException(
        'YouTube Music 回傳帳號名稱為空，拒絕假性登入狀態',
        statusCode: 401,
        isTokenExpired: true,
      );
    }

    final email = _extractInnerTubeText(header['email']) ??
        _extractInnerTubeText(header['channelHandle']);

    return StreamingAccountInfo(
      displayName: displayName.trim(),
      email: email?.trim(),
      planTier: _detectPlanTier(json),
      expiresAt: _expiresAt,
    );
  }

  String? _detectPlanTier(Map<String, dynamic> accountMenuJson) {
    final raw = jsonEncode(accountMenuJson).toLowerCase();
    if (raw.contains('youtube music premium') || raw.contains('premium')) {
      return 'YouTube Music Premium';
    }
    return null;
  }

  Future<void> _persistCredentials(StreamingAccountInfo account) {
    return saveCredentialsJson(<String, dynamic>{
      'mode': _authMode,
      if (_cookie != null) 'cookie': _cookie,
      if (_clientId != null) 'client_id': _clientId,
      if (_clientSecret != null && _clientSecret!.isNotEmpty)
        'client_secret': _clientSecret,
      if (_accessToken != null) 'access_token': _accessToken,
      if (_refreshToken != null) 'refresh_token': _refreshToken,
      if (_expiresAt != null) 'expires_at': _expiresAt!.toUtc().toIso8601String(),
      'account': account.toJson(),
    });
  }

  @override
  Future<StreamingCatalog> syncLibrary({CancellationToken? cancel}) async {
    ensureAuthenticated();
    await refreshSessionIfNeeded();

    final tracksJson = await _browse('FEmusic_liked_videos', cancel: cancel);
    final playlistsJson =
        await _browse('FEmusic_liked_playlists', cancel: cancel);
    final albumsJson = await _browse('FEmusic_liked_albums', cancel: cancel);

    final tracks = _parseTracksFromJson(tracksJson);
    final playlists = _parsePlaylistsFromJson(playlistsJson);
    final albums = _parseAlbumsFromJson(albumsJson);

    final nextCatalog = StreamingCatalog(
      tracks: tracks,
      playlists: playlists,
      albums: albums,
      syncedAt: clock(),
    );
    setCatalog(nextCatalog);
    return nextCatalog;
  }

  @override
  Future<StreamingRecommendations> fetchRecommendations({
    CancellationToken? cancel,
  }) async {
    ensureAuthenticated();
    await refreshSessionIfNeeded();

    final homeJson = await _browse('FEmusic_home', cancel: cancel);
    var albums = _parseAlbumsFromJson(homeJson);
    var tracks = _parseTracksFromJson(homeJson);

    if (albums.isEmpty && tracks.isEmpty) {
      final exploreJson = await _browse('FEmusic_explore', cancel: cancel);
      albums = _parseAlbumsFromJson(exploreJson);
      tracks = _parseTracksFromJson(exploreJson);
    }

    return StreamingRecommendations(
      providerKind: kind,
      albums: albums,
      tracks: tracks,
      fetchedAt: clock(),
    );
  }

  @override
  Future<CanonicalAlbumDetail?> fetchAlbumDetail(
    String albumId, {
    CancellationToken? cancel,
  }) async {
    ensureAuthenticated();
    await refreshSessionIfNeeded();

    var cleanId = BaseStreamingProvider.stripTrackPrefix(
      albumId,
      'streaming:$kind',
    );
    cleanId = BaseStreamingProvider.stripTrackPrefix(cleanId, kind);
    cleanId = BaseStreamingProvider.stripTrackPrefix(cleanId, 'ytm');
    if (cleanId.isEmpty) return null;

    final json = await _browse(cleanId, cancel: cancel);
    final header = _findFirstMapByKey(json, 'musicResponsiveHeaderRenderer') ??
        _findFirstMapByKey(json, 'musicDetailHeaderRenderer') ??
        (json['header'] is Map
            ? Map<String, dynamic>.from(json['header'] as Map)
            : <String, dynamic>{});

    final title = _extractInnerTubeText(header['title']) ??
        _extractInnerTubeText(json['title']) ??
        'YouTube Music Album';
    final artist = _extractInnerTubeText(header['straplineTextOne']) ??
        _extractInnerTubeText(header['subtitle']) ??
        _extractInnerTubeText(json['artist']) ??
        '未知藝術家';
    final bio = _extractInnerTubeText(header['description']) ??
        _extractInnerTubeText(json['description']);
    final coverUrl = _extractThumbnailUrl(header['thumbnail']) ??
        _extractThumbnailUrl(json['thumbnail']) ??
        json['cover_url']?.toString();

    int? releaseYear = (json['year'] as num?)?.toInt();
    final subText = _extractInnerTubeText(header['subtitle']) ?? '';
    if (releaseYear == null && subText.isNotEmpty) {
      final match = RegExp(r'\b(19\d{2}|20\d{2})\b').firstMatch(subText);
      if (match != null) {
        releaseYear = int.tryParse(match.group(1)!);
      }
    }

    final parsedTracks = _parseTracksFromJson(json);
    final versionTracks = <AlbumVersionTrackInfo>[];
    for (var i = 0; i < parsedTracks.length; i++) {
      final t = parsedTracks[i];
      versionTracks.add(
        AlbumVersionTrackInfo(
          id: t.id,
          title: t.title,
          discNumber: t.discNumber ?? 1,
          trackNumber: t.trackNumber ?? (i + 1),
          durationMs: t.duration.inMilliseconds,
          codec: t.format.codec.name,
          sampleRateHz: t.format.sampleRateHz,
          bitDepth: t.format.bitDepth,
          externalTrackId: t.id,
        ),
      );
    }

    return CanonicalAlbumDetail(
      id: 'streaming:$kind:$cleanId',
      title: title,
      artistName: artist.split(RegExp(r'\s*[•·]\s*')).first.trim(),
      releaseYear: releaseYear,
      editorialBio: bio,
      coverUrl: coverUrl,
      versions: <AlbumVersionInfo>[
        AlbumVersionInfo(
          id: 'ver_ytm_$cleanId',
          provider: kind,
          externalAlbumId: cleanId,
          editionLabel: 'YouTube Music',
          codec: 'opus',
          sampleRateHz: 48000,
          bitDepth: 16,
          tracks: versionTracks,
        ),
      ],
    );
  }

  @override
  Future<List<TrackInfo>> fetchPlaylistTracks(String playlistId) async {
    ensureAuthenticated();
    await refreshSessionIfNeeded();

    final cleanId = BaseStreamingProvider.stripTrackPrefix(playlistId, 'ytm');
    final json = await _browse(cleanId);
    return _parseTracksFromJson(json);
  }

  @override
  Future<StreamingCatalog> search(String query) async {
    ensureAuthenticated();
    await refreshSessionIfNeeded();

    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return StreamingCatalog(syncedAt: clock());
    }

    final uri = BaseStreamingProvider.buildUri(
      baseUrl,
      '/youtubei/v1/search',
      const <String, String>{'prettyPrint': 'false'},
    );
    final json = await http.requestJson(
      method: 'POST',
      uri: uri,
      headers: _buildInnerTubeHeaders(),
      jsonBody: <String, dynamic>{
        'context': _webRemixContext,
        'query': trimmed,
      },
    );

    final tracks = _parseTracksFromJson(json);
    final albums = _parseAlbumsFromJson(json);
    final playlists = _parsePlaylistsFromJson(json);

    return StreamingCatalog(
      tracks: tracks,
      playlists: playlists,
      albums: albums,
      syncedAt: clock(),
    );
  }

  @override
  Future<ResolvedStreamResult> resolveStream(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
  }) async {
    cancel?.throwIfCancelled();
    ensureAuthenticated();
    await refreshSessionIfNeeded();
    cancel?.throwIfCancelled();

    final videoId = _extractVideoId(track);
    if (videoId.isEmpty) {
      throw const StreamingException('曲目缺少有效的 YouTube videoId');
    }

    final playerUri = BaseStreamingProvider.buildUri(
      baseUrl,
      '/youtubei/v1/player',
      const <String, String>{'prettyPrint': 'false'},
    );

    Map<String, dynamic> playerJson = await http.requestJson(
      method: 'POST',
      uri: playerUri,
      headers: _buildInnerTubeHeaders(),
      jsonBody: <String, dynamic>{
        'context': _androidMusicContext,
        'videoId': videoId,
        'contentCheckOk': true,
        'racyCheckOk': true,
      },
      cancel: cancel,
      timeout: timeout,
    );

    var resolved = _tryExtractBestAudioStream(playerJson);
    if (resolved == null) {
      final playability = playerJson['playabilityStatus'];
      final status = playability is Map ? playability['status']?.toString() : null;
      if (status != null && status != 'OK') {
        final reason = playability is Map
            ? playability['reason']?.toString()
            : null;
        throw StreamingException(
          'YouTube Music 無法播放此曲目：${reason ?? status}',
          statusCode: status == 'LOGIN_REQUIRED' ? 401 : 403,
          isTokenExpired: status == 'LOGIN_REQUIRED',
        );
      }

      // Retry with IOS_MUSIC client context if ANDROID_MUSIC yielded ciphered/no formats.
      playerJson = await http.requestJson(
        method: 'POST',
        uri: playerUri,
        headers: _buildInnerTubeHeaders(),
        jsonBody: <String, dynamic>{
          'context': _iosMusicContext,
          'videoId': videoId,
          'contentCheckOk': true,
          'racyCheckOk': true,
        },
        cancel: cancel,
        timeout: timeout,
      );
      resolved = _tryExtractBestAudioStream(playerJson);
    }

    if (resolved == null) {
      throw const StreamingException(
        'YouTube Music 未回傳可直接播放的音訊串流 URL（可能受簽章加密或地區限制）',
      );
    }
    return resolved;
  }

  ResolvedStreamResult? _tryExtractBestAudioStream(Map<String, dynamic> json) {
    final playability = json['playabilityStatus'];
    if (playability is Map) {
      final status = playability['status']?.toString();
      if (status != null && status != 'OK') {
        return null;
      }
    }

    final streamingData = json['streamingData'];
    if (streamingData is! Map) return null;

    final candidates = <Map<String, dynamic>>[];
    for (final listKey in const ['adaptiveFormats', 'formats']) {
      final raw = streamingData[listKey];
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            final map = Map<String, dynamic>.from(item);
            final mime = map['mimeType']?.toString().toLowerCase() ?? '';
            final url = map['url']?.toString().trim() ?? '';
            if (mime.startsWith('audio/') && url.isNotEmpty) {
              candidates.add(map);
            }
          }
        }
      }
    }

    if (candidates.isEmpty) return null;

    candidates.sort((a, b) {
      final ba = (a['bitrate'] as num?)?.toInt() ?? 0;
      final bb = (b['bitrate'] as num?)?.toInt() ?? 0;
      return bb.compareTo(ba);
    });

    final best = candidates.first;
    final url = best['url']!.toString();
    final mime = best['mimeType']?.toString().toLowerCase() ?? '';

    final AudioCodec codec;
    final String hintExt;
    if (mime.contains('opus') || mime.contains('webm')) {
      codec = AudioCodec.opus;
      hintExt = 'webm';
    } else if (mime.contains('flac')) {
      codec = AudioCodec.flac;
      hintExt = 'flac';
    } else {
      codec = AudioCodec.aac;
      hintExt = 'm4a';
    }

    final sampleRateRaw = best['audioSampleRate'];
    final sampleRate = sampleRateRaw is num
        ? sampleRateRaw.toInt()
        : int.tryParse(sampleRateRaw?.toString() ?? '') ??
            (codec == AudioCodec.opus ? 48000 : 44100);
    final channels = (best['audioChannels'] as num?)?.toInt() ?? 2;

    return ResolvedStreamResult(
      url: url,
      hintExtension: hintExt,
      format: AudioFormat(
        codec: codec,
        sampleRateHz: sampleRate,
        bitDepth: 16,
        channels: channels,
      ),
    );
  }

  Future<Map<String, dynamic>> _browse(
    String browseId, {
    CancellationToken? cancel,
  }) async {
    final uri = BaseStreamingProvider.buildUri(
      baseUrl,
      '/youtubei/v1/browse',
      const <String, String>{'prettyPrint': 'false'},
    );
    return http.requestJson(
      method: 'POST',
      uri: uri,
      headers: _buildInnerTubeHeaders(),
      jsonBody: <String, dynamic>{
        'context': _webRemixContext,
        'browseId': browseId,
      },
      cancel: cancel,
    );
  }

  String _extractVideoId(TrackInfo track) {
    final cleanId = BaseStreamingProvider.stripTrackPrefix(track.id, 'ytm');
    if (cleanId.isNotEmpty) return cleanId;
    final fp = track.filePath;
    if (fp != null && fp.isNotEmpty) {
      final parsed = Uri.tryParse(fp);
      final v = parsed?.queryParameters['v'];
      if (v != null && v.isNotEmpty) return v;
    }
    return '';
  }

  List<TrackInfo> _parseTracksFromJson(Map<String, dynamic> root) {
    final items = _collectMapsByKey(root, 'musicResponsiveListItemRenderer');
    final tracks = <TrackInfo>[];
    final seenIds = <String>{};

    for (final item in items) {
      final videoId = _extractVideoIdFromRenderer(item);
      if (videoId == null || videoId.isEmpty) continue;
      final trackId = 'ytm:$videoId';
      if (!seenIds.add(trackId)) continue;

      final flexCols = item['flexColumns'];
      final title = _extractFlexColumnText(flexCols, 0) ?? '未命名曲目';
      final subRuns = _extractFlexColumnRuns(flexCols, 1);

      var artist = '未知藝術家';
      var album = 'YouTube Music';
      Duration duration = Duration.zero;

      final textParts = <String>[];
      for (final run in subRuns) {
        final text = run['text']?.toString().trim() ?? '';
        if (text.isEmpty || text == '•' || text == '·' || text == '• ') {
          continue;
        }
        final pageType = _extractPageType(run);
        if (pageType == 'MUSIC_PAGE_TYPE_ARTIST') {
          artist = text;
        } else if (pageType == 'MUSIC_PAGE_TYPE_ALBUM') {
          album = text;
        } else if (_looksLikeDuration(text)) {
          duration = _parseDuration(text);
        } else {
          textParts.add(text);
        }
      }

      if (artist == '未知藝術家' && textParts.isNotEmpty) {
        artist = textParts.first;
      }
      if (album == 'YouTube Music' && textParts.length >= 2) {
        album = textParts[1];
      }

      final fixedCols = item['fixedColumns'];
      final fixedDurText = _extractFixedColumnText(fixedCols, 0);
      if (duration == Duration.zero &&
          fixedDurText != null &&
          _looksLikeDuration(fixedDurText)) {
        duration = _parseDuration(fixedDurText);
      }

      final coverUrl = _extractThumbnailUrl(item['thumbnail']);

      tracks.add(
        TrackInfo(
          id: trackId,
          title: title,
          artist: artist,
          album: album,
          duration: duration,
          albumArtUrl: coverUrl,
          coverUrl: coverUrl,
          format: const AudioFormat(
            codec: AudioCodec.opus,
            sampleRateHz: 48000,
            bitDepth: 16,
            channels: 2,
          ),
          providerName: 'YouTube Music',
        ),
      );
    }

    return tracks;
  }

  List<StreamingPlaylist> _parsePlaylistsFromJson(Map<String, dynamic> root) {
    final playlists = <StreamingPlaylist>[];
    final seen = <String>{};

    for (final item in _collectMapsByKey(root, 'musicTwoRowItemRenderer')) {
      final browseId = _extractBrowseId(item['navigationEndpoint']);
      final pageType = _extractPageType(item['navigationEndpoint']);
      if (browseId == null || browseId.isEmpty) continue;
      if (pageType != null && pageType != 'MUSIC_PAGE_TYPE_PLAYLIST') continue;
      if (!browseId.startsWith('VL') &&
          !browseId.startsWith('PL') &&
          !browseId.startsWith('RD') &&
          pageType != 'MUSIC_PAGE_TYPE_PLAYLIST') {
        continue;
      }
      if (!seen.add(browseId)) continue;

      final title = _extractInnerTubeText(item['title']) ?? '未命名歌單';
      final subtitle = _extractInnerTubeText(item['subtitle']);
      final coverUrl = _extractThumbnailUrl(item['thumbnailRenderer']);
      playlists.add(
        StreamingPlaylist(
          id: browseId,
          title: title,
          description: subtitle,
          coverUrl: coverUrl,
          providerKind: kind,
        ),
      );
    }

    for (final item
        in _collectMapsByKey(root, 'musicResponsiveListItemRenderer')) {
      final browseId = _extractBrowseId(item['navigationEndpoint']);
      final pageType = _extractPageType(item['navigationEndpoint']);
      if (browseId == null || browseId.isEmpty) continue;
      if (pageType != 'MUSIC_PAGE_TYPE_PLAYLIST' && !browseId.startsWith('VL')) {
        continue;
      }
      if (!seen.add(browseId)) continue;

      final title =
          _extractFlexColumnText(item['flexColumns'], 0) ?? '未命名歌單';
      final coverUrl = _extractThumbnailUrl(item['thumbnail']);
      playlists.add(
        StreamingPlaylist(
          id: browseId,
          title: title,
          coverUrl: coverUrl,
          providerKind: kind,
        ),
      );
    }

    return playlists;
  }

  List<StreamingAlbum> _parseAlbumsFromJson(Map<String, dynamic> root) {
    final albums = <StreamingAlbum>[];
    final seen = <String>{};

    for (final item in _collectMapsByKey(root, 'musicTwoRowItemRenderer')) {
      final browseId = _extractBrowseId(item['navigationEndpoint']);
      final pageType = _extractPageType(item['navigationEndpoint']);
      if (browseId == null || browseId.isEmpty) continue;
      if (pageType != 'MUSIC_PAGE_TYPE_ALBUM' && !browseId.startsWith('MPRE')) {
        continue;
      }
      if (!seen.add(browseId)) continue;

      final title = _extractInnerTubeText(item['title']) ?? '未命名專輯';
      final subtitle = _extractInnerTubeText(item['subtitle']) ?? '';
      final parts = subtitle
          .split(RegExp(r'\s*[•·]\s*'))
          .where((s) => s.isNotEmpty)
          .toList();
      final artist = parts.isNotEmpty ? parts.first : '未知藝術家';
      int? year;
      for (final p in parts) {
        final parsed = int.tryParse(p);
        if (parsed != null && parsed >= 1900 && parsed <= 2100) {
          year = parsed;
        }
      }
      final coverUrl = _extractThumbnailUrl(item['thumbnailRenderer']);
      albums.add(
        StreamingAlbum(
          id: browseId,
          title: title,
          artist: artist,
          year: year,
          coverUrl: coverUrl,
          providerKind: kind,
        ),
      );
    }

    for (final item
        in _collectMapsByKey(root, 'musicResponsiveListItemRenderer')) {
      final browseId = _extractBrowseId(item['navigationEndpoint']);
      final pageType = _extractPageType(item['navigationEndpoint']);
      if (browseId == null || browseId.isEmpty) continue;
      if (pageType != 'MUSIC_PAGE_TYPE_ALBUM' && !browseId.startsWith('MPRE')) {
        continue;
      }
      if (!seen.add(browseId)) continue;

      final title =
          _extractFlexColumnText(item['flexColumns'], 0) ?? '未命名專輯';
      final subRuns = _extractFlexColumnRuns(item['flexColumns'], 1);
      var artist = '未知藝術家';
      int? year;
      for (final run in subRuns) {
        final text = run['text']?.toString().trim() ?? '';
        if (text.isEmpty || text == '•' || text == '·') continue;
        final rt = _extractPageType(run);
        if (rt == 'MUSIC_PAGE_TYPE_ARTIST') {
          artist = text;
        } else {
          final y = int.tryParse(text);
          if (y != null && y >= 1900 && y <= 2100) {
            year = y;
          } else if (artist == '未知藝術家' && text.toLowerCase() != 'album') {
            artist = text;
          }
        }
      }
      albums.add(
        StreamingAlbum(
          id: browseId,
          title: title,
          artist: artist,
          year: year,
          coverUrl: _extractThumbnailUrl(item['thumbnail']),
          providerKind: kind,
        ),
      );
    }

    return albums;
  }

  static Map<String, dynamic>? _findFirstMapByKey(dynamic node, String key) {
    if (node is Map) {
      if (node.containsKey(key) && node[key] is Map) {
        return Map<String, dynamic>.from(node[key] as Map);
      }
      for (final value in node.values) {
        final found = _findFirstMapByKey(value, key);
        if (found != null) return found;
      }
    } else if (node is List) {
      for (final item in node) {
        final found = _findFirstMapByKey(item, key);
        if (found != null) return found;
      }
    }
    return null;
  }

  static List<Map<String, dynamic>> _collectMapsByKey(
    dynamic node,
    String key,
  ) {
    final results = <Map<String, dynamic>>[];
    void walk(dynamic current) {
      if (current is Map) {
        if (current.containsKey(key) && current[key] is Map) {
          results.add(Map<String, dynamic>.from(current[key] as Map));
        }
        for (final val in current.values) {
          walk(val);
        }
      } else if (current is List) {
        for (final item in current) {
          walk(item);
        }
      }
    }

    walk(node);
    return results;
  }

  static String? _extractInnerTubeText(dynamic obj) {
    if (obj == null) return null;
    if (obj is String) return obj;
    if (obj is Map) {
      final simple = obj['simpleText']?.toString();
      if (simple != null && simple.isNotEmpty) return simple;
      final runs = obj['runs'];
      if (runs is List) {
        final buf = StringBuffer();
        for (final r in runs) {
          if (r is Map && r['text'] != null) {
            buf.write(r['text'].toString());
          }
        }
        final text = buf.toString();
        if (text.isNotEmpty) return text;
      }
    }
    return null;
  }

  static String? _extractVideoIdFromRenderer(Map<String, dynamic> item) {
    final playlistData = item['playlistItemData'];
    if (playlistData is Map && playlistData['videoId'] != null) {
      return playlistData['videoId'].toString();
    }
    final watch = _findFirstMapByKey(item, 'watchEndpoint');
    if (watch != null && watch['videoId'] != null) {
      return watch['videoId'].toString();
    }
    return null;
  }

  static String? _extractBrowseId(dynamic navEndpoint) {
    if (navEndpoint is! Map) return null;
    final browse = navEndpoint['browseEndpoint'];
    if (browse is Map) {
      return browse['browseId']?.toString();
    }
    return null;
  }

  static String? _extractPageType(dynamic node) {
    final cfg = _findFirstMapByKey(
      node,
      'browseEndpointContextMusicConfig',
    );
    return cfg?['pageType']?.toString();
  }

  static String? _extractFlexColumnText(dynamic flexCols, int index) {
    if (flexCols is! List || index >= flexCols.length) return null;
    final col = flexCols[index];
    if (col is! Map) return null;
    final renderer = col['musicResponsiveListItemFlexColumnRenderer'];
    if (renderer is! Map) return null;
    return _extractInnerTubeText(renderer['text']);
  }

  static List<Map<String, dynamic>> _extractFlexColumnRuns(
    dynamic flexCols,
    int index,
  ) {
    if (flexCols is! List || index >= flexCols.length) return const [];
    final col = flexCols[index];
    if (col is! Map) return const [];
    final renderer = col['musicResponsiveListItemFlexColumnRenderer'];
    if (renderer is! Map) return const [];
    final text = renderer['text'];
    if (text is! Map) return const [];
    final runs = text['runs'];
    if (runs is! List) return const [];
    return runs
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  static String? _extractFixedColumnText(dynamic fixedCols, int index) {
    if (fixedCols is! List || index >= fixedCols.length) return null;
    final col = fixedCols[index];
    if (col is! Map) return null;
    final renderer = col['musicResponsiveListItemFixedColumnRenderer'];
    if (renderer is! Map) return null;
    return _extractInnerTubeText(renderer['text']);
  }

  static String? _extractThumbnailUrl(dynamic node) {
    final thumb = _findFirstMapByKey(node, 'musicThumbnailRenderer') ??
        (node is Map && node['thumbnails'] is List
            ? Map<String, dynamic>.from(node)
            : null);
    if (thumb == null) return null;
    final list = thumb['thumbnails'] ??
        (thumb['thumbnail'] is Map ? thumb['thumbnail']['thumbnails'] : null);
    if (list is List && list.isNotEmpty) {
      final last = list.last;
      if (last is Map) {
        return last['url']?.toString();
      }
    }
    return null;
  }

  static bool _looksLikeDuration(String text) =>
      RegExp(r'^\d{1,2}(:\d{2}){1,2}$').hasMatch(text.trim());

  static Duration _parseDuration(String raw) {
    final parts = raw.trim().split(':').map(int.tryParse).toList();
    if (parts.any((e) => e == null)) return Duration.zero;
    if (parts.length == 2) {
      return Duration(minutes: parts[0]!, seconds: parts[1]!);
    }
    if (parts.length == 3) {
      return Duration(
        hours: parts[0]!,
        minutes: parts[1]!,
        seconds: parts[2]!,
      );
    }
    return Duration.zero;
  }
}
