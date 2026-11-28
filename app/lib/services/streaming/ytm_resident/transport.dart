part of '../ytm_resident_resolver.dart';

extension _YtmTransportExt on YtmResidentResolver {
  Future<YtmPlayerHttpResponse> _postJson({
    required Uri uri,
    required Map<String, String> headers,
    required Map<String, dynamic> body,
    CancellationToken? cancelToken,
  }) async {
    cancelToken?.throwIfCancelled();

    if (requestHandler != null) {
      return _awaitWithCancel(
        () => requestHandler!(
          uri: uri,
          headers: headers,
          body: body,
          cancelToken: cancelToken,
        ),
        cancelToken: cancelToken,
      );
    }

    final encoded = utf8.encode(jsonEncode(body));
    HttpClientRequest? activeReq;
    StreamSubscription<String>? bodySub;
    final completer = Completer<YtmPlayerHttpResponse>();
    var aborted = false;

    void onCancel() {
      aborted = true;
      try {
        activeReq?.abort();
      } catch (_) {}
      unawaited(bodySub?.cancel().catchError((_) {}));
      if (!completer.isCompleted) {
        completer.completeError(
          const StreamingException('操作已取消', isCancelled: true),
        );
      }
    }

    cancelToken?.addListener(onCancel);
    try {
      () async {
        try {
          final req = await _httpClient.openUrl('POST', uri).timeout(
            requestTimeout,
          );
          if (aborted || _disposed) {
            try {
              req.abort();
            } catch (_) {}
            return;
          }
          activeReq = req;
          headers.forEach((k, v) => req.headers.set(k, v));
          req.contentLength = encoded.length;
          req.add(encoded);

          final resp = await req.close().timeout(requestTimeout);
          if (aborted || _disposed) {
            unawaited(resp.drain<void>().catchError((_) {}));
            return;
          }
          final buf = StringBuffer();
          final bodyDone = Completer<String>();
          bodySub = utf8.decoder.bind(resp).listen(
            buf.write,
            onDone: () {
              if (!bodyDone.isCompleted) bodyDone.complete(buf.toString());
            },
            onError: (Object err, StackTrace st) {
              if (!bodyDone.isCompleted) bodyDone.completeError(err, st);
            },
            cancelOnError: true,
          );
          final respBody = await bodyDone.future.timeout(requestTimeout);
          if (!aborted && !_disposed && !completer.isCompleted) {
            completer.complete(
              YtmPlayerHttpResponse(statusCode: resp.statusCode, body: respBody),
            );
          }
        } on TimeoutException {
          if (!completer.isCompleted) {
            completer.completeError(
              StreamingException('連線逾時（${uri.host}）'),
            );
          }
        } on SocketException catch (e) {
          if (!completer.isCompleted) {
            completer.completeError(
              aborted
                  ? const StreamingException('操作已取消', isCancelled: true)
                  : StreamingException('網路連線失敗：${e.message}'),
            );
          }
        } on HttpException catch (e) {
          if (!completer.isCompleted) {
            completer.completeError(
              aborted
                  ? const StreamingException('操作已取消', isCancelled: true)
                  : StreamingException('HTTP 通訊協定錯誤：${e.message}'),
            );
          }
        } catch (e) {
          if (!completer.isCompleted) {
            completer.completeError(
              aborted
                  ? const StreamingException('操作已取消', isCancelled: true)
                  : StreamingException('網路請求失敗：$e'),
            );
          }
        }
      }();

      return await completer.future;
    } finally {
      cancelToken?.removeListener(onCancel);
      if (aborted) {
        unawaited(bodySub?.cancel().catchError((_) {}));
      }
    }
  }

  Future<T> _awaitWithCancel<T>(
    Future<T> Function() invoke, {
    CancellationToken? cancelToken,
  }) {
    cancelToken?.throwIfCancelled();
    final completer = Completer<T>();

    void onCancel() {
      if (!completer.isCompleted) {
        completer.completeError(
          const StreamingException('操作已取消', isCancelled: true),
        );
      }
    }

    cancelToken?.addListener(onCancel);
    Future<T>.sync(invoke).then(
      (v) {
        if (!completer.isCompleted) completer.complete(v);
      },
      onError: (Object err, StackTrace st) {
        if (!completer.isCompleted) completer.completeError(err, st);
      },
    );
    return completer.future.timeout(requestTimeout).whenComplete(() {
      cancelToken?.removeListener(onCancel);
    });
  }

  Map<String, String> _cleanClientHeaders(
    _ResidentClientProfile profile, {
    String? visitorData,
  }) {
    final vd = visitorData?.trim();
    final headers = <String, String>{
      'User-Agent': profile.userAgent,
      'X-YouTube-Client-Name': profile.clientNameHeader,
      'X-YouTube-Client-Version': profile.clientVersion,
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8',
      if (vd != null && vd.isNotEmpty) 'X-Goog-Visitor-Id': vd,
    };
    _assertNoWebAuthLeakage(headers, clientName: profile.clientName);
    return headers;
  }

  Map<String, String> _guestWebRemixHeaders({String? visitorData}) {
    final vd = visitorData?.trim();
    return <String, String>{
      'User-Agent': YtmResidentResolver._desktopChromeUserAgent,
      'X-YouTube-Client-Name': '67',
      'X-YouTube-Client-Version': YtmResidentResolver._webRemixClientVersion,
      'Origin': YtmResidentResolver.defaultMusicOrigin,
      'Referer': '${YtmResidentResolver.defaultMusicOrigin}/',
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8',
      if (vd != null && vd.isNotEmpty) 'X-Goog-Visitor-Id': vd,
    };
  }

  Map<String, String> _webRemixHeaders(
    YtmAuthCredentials auth, {
    String? visitorDataOverride,
  }) {
    final headers = <String, String>{
      'User-Agent': YtmResidentResolver._desktopChromeUserAgent,
      'X-YouTube-Client-Name': '67',
      'X-YouTube-Client-Version': YtmResidentResolver._webRemixClientVersion,
      'Origin': YtmResidentResolver.defaultMusicOrigin,
      'Referer': '${YtmResidentResolver.defaultMusicOrigin}/',
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8',
    };
    final visitor = (visitorDataOverride ?? auth.visitorData)?.trim();
    if (visitor != null && visitor.isNotEmpty) {
      headers['X-Goog-Visitor-Id'] = visitor;
    }
    if ((auth.authMode == 'oauth' || auth.authMode == 'oauth_device') &&
        auth.accessToken != null &&
        auth.accessToken!.trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ${auth.accessToken!.trim()}';
    } else if (auth.cookie != null && auth.cookie!.trim().isNotEmpty) {
      final cookie = auth.cookie!.trim();
      headers['Cookie'] = cookie;
      final sapisid = YtmResidentResolver.extractSapisidFromCookie(cookie);
      if (sapisid != null) {
        final ts = _clock().millisecondsSinceEpoch ~/ 1000;
        headers['Authorization'] = YtmResidentResolver.computeSapisidHash(
          sapisid,
          timestampSeconds: ts,
          origin: YtmResidentResolver.defaultMusicOrigin,
        );
        headers['X-Origin'] = YtmResidentResolver.defaultMusicOrigin;
      }
    }
    return headers;
  }
}

String? _extractSapisidFromCookie(String cookieHeader) {
  final map = <String, String>{};
  for (final part in cookieHeader.split(';')) {
    final idx = part.indexOf('=');
    if (idx <= 0) continue;
    final name = part.substring(0, idx).trim();
    var value = part.substring(idx + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
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

String _computeSapisidHash(
  String sapisid, {
  required int timestampSeconds,
  String origin = YtmResidentResolver.defaultMusicOrigin,
}) {
  final digest = sha1
      .convert(utf8.encode('$timestampSeconds $sapisid $origin'))
      .toString();
  return 'SAPISIDHASH ${timestampSeconds}_$digest';
}

String _extractCleanVideoId(String rawId) {
  var candidate = rawId.trim();
  for (final prefix in const <String>[
    'streaming:youtube_music:',
    'youtube_music:',
    'ytm:',
    'ytm_',
  ]) {
    if (candidate.startsWith(prefix)) {
      candidate = candidate.substring(prefix.length).trim();
    }
  }
  if (candidate.contains('youtube.com/') ||
      candidate.contains('youtu.be/') ||
      candidate.contains('music.youtube.com/')) {
    final uri = Uri.tryParse(candidate);
    final vParam = uri?.queryParameters['v']?.trim();
    if (vParam != null && vParam.isNotEmpty) {
      candidate = vParam;
    } else if (uri != null &&
        uri.host.toLowerCase().contains('youtu.be') &&
        uri.pathSegments.isNotEmpty) {
      candidate = uri.pathSegments.last.trim();
    }
  }
  if (!YtmResidentResolver._validVideoIdPattern.hasMatch(candidate)) {
    throw StreamingException('無效的 YouTube Music 影片識別碼：$rawId');
  }
  return candidate;
}
