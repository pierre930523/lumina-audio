part of '../ytm_resident_resolver.dart';

extension _YtmWarmupExt on YtmResidentResolver {
  Future<void> _doWarmup() async {
    if (_disposed) return;
    _warmupCount++;

    // Trigger non-blocking Rust reqwest HTTP/2 TLS pool warmup when available.
    try {
      _onHttp2Warmup?.call();
    } catch (_) {}

    var anyNetworkSucceeded = false;

    if (requestHandler == null) {
      final results = await Future.wait<bool>(<Future<bool>>[
        _probeTlsEndpoint(_cleanOrigin(webBaseUrl), '/generate_204'),
        _probeVisitorDataFromMusicOrigin(),
      ]);
      anyNetworkSucceeded = results.any((ok) => ok);
    } else {
      anyNetworkSucceeded = true;
    }

    if (_disposed) return;

    final auth = authProvider?.call();
    final sessionBinding = _resolveSessionBinding(auth);
    if (_potProvider != null) {
      try {
        final gvs = await _potProvider
            .getGvsToken(sessionBinding: sessionBinding)
            .timeout(warmupTimeout, onTimeout: () => null);
        if (gvs != null) {
          anyNetworkSucceeded = true;
        }
      } catch (_) {}
    }

    if (!_disposed && anyNetworkSucceeded) {
      _warmedUp = true;
    }
  }

  Future<bool> _probeTlsEndpoint(String origin, String path) async {
    try {
      final uri = Uri.parse('$origin$path');
      final req = await _httpClient.openUrl('GET', uri).timeout(warmupTimeout);
      req.headers.set('User-Agent', YtmResidentResolver._desktopChromeUserAgent);
      final resp = await req.close().timeout(warmupTimeout);
      await resp.drain<void>().timeout(warmupTimeout);
      return resp.statusCode >= 200 && resp.statusCode < 400;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _probeVisitorDataFromMusicOrigin({
    CancellationToken? cancelToken,
  }) async {
    if (_disposed || cancelToken?.isCancelled == true) return false;
    final authVisitor = authProvider?.call()?.visitorData?.trim();
    if (authVisitor != null && authVisitor.isNotEmpty) {
      _cachedVisitorData = authVisitor;
    }
    HttpClientRequest? activeReq;
    StreamSubscription<String>? bodySub;
    var aborted = false;
    final completer = Completer<bool>();

    void onCancel() {
      aborted = true;
      try {
        activeReq?.abort();
      } catch (_) {}
      unawaited(bodySub?.cancel().catchError((_) {}));
      if (!completer.isCompleted) {
        completer.complete(false);
      }
    }

    cancelToken?.addListener(onCancel);
    try {
      () async {
        try {
          final uri = Uri.parse('${_cleanOrigin(musicBaseUrl)}/sw.js_data');
          final req =
              await _httpClient.openUrl('GET', uri).timeout(warmupTimeout);
          if (aborted || _disposed) {
            try {
              req.abort();
            } catch (_) {}
            if (!completer.isCompleted) completer.complete(false);
            return;
          }
          activeReq = req;
          req.headers
              .set('User-Agent', YtmResidentResolver._desktopChromeUserAgent);
          final resp = await req.close().timeout(warmupTimeout);
          if (aborted || _disposed) {
            unawaited(resp.drain<void>().catchError((_) {}));
            if (!completer.isCompleted) completer.complete(false);
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
          final body = await bodyDone.future.timeout(warmupTimeout);
          if (aborted || _disposed) {
            if (!completer.isCompleted) completer.complete(false);
            return;
          }
          if (resp.statusCode >= 200 && resp.statusCode < 300) {
            final extracted = _extractVisitorDataFromSwJsData(body);
            if (extracted != null && extracted.isNotEmpty) {
              _cachedVisitorData = extracted;
            }
            if (!completer.isCompleted) completer.complete(true);
            return;
          }
          if (!completer.isCompleted) completer.complete(false);
        } catch (_) {
          if (!completer.isCompleted) completer.complete(false);
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

  String _resolveSessionBinding(YtmAuthCredentials? auth) {
    final authBinding = auth?.sessionBindingKey;
    if (authBinding != null && authBinding.isNotEmpty) {
      return authBinding;
    }
    final vd = _cachedVisitorData?.trim();
    if (vd != null && vd.isNotEmpty) {
      return vd;
    }
    return 'ytm_guest_session';
  }

  Future<void> _awaitSharedWarmupWithCancel(
    Future<void> sharedWarmup,
    CancellationToken? cancelToken,
  ) {
    if (cancelToken == null) return sharedWarmup;
    cancelToken.throwIfCancelled();

    final completer = Completer<void>();
    void onCancel() {
      if (!completer.isCompleted) {
        completer.completeError(
          const StreamingException('操作已取消', isCancelled: true),
        );
      }
    }

    cancelToken.addListener(onCancel);
    sharedWarmup.then(
      (_) {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (_, _) {
        // Warmup failure is non-fatal for playback resolution.
        if (!completer.isCompleted) completer.complete();
      },
    );
    return completer.future.whenComplete(() {
      cancelToken.removeListener(onCancel);
    });
  }
}

String _cleanOrigin(String raw) =>
    raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;

String? _extractVisitorDataFromSwJsData(String rawBody) {
  var trimmed = rawBody.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith(")]}'")) {
    final newlineIdx = trimmed.indexOf('\n');
    trimmed = newlineIdx >= 0
        ? trimmed.substring(newlineIdx + 1).trim()
        : trimmed.substring(4).trim();
  }
  if (trimmed.isEmpty) return null;
  try {
    final decoded = jsonDecode(trimmed);
    return _findVisitorDataInDynamic(decoded);
  } catch (_) {
    return null;
  }
}

String? _findVisitorDataInDynamic(dynamic node) {
  if (node is String) {
    final trimmed = node.trim();
    if (YtmResidentResolver._visitorDataPattern.hasMatch(trimmed)) {
      return trimmed;
    }
    return null;
  }
  if (node is List) {
    for (final item in node) {
      final found = _findVisitorDataInDynamic(item);
      if (found != null) return found;
    }
  } else if (node is Map) {
    final direct = node['visitorData'];
    if (direct is String && direct.trim().isNotEmpty) return direct.trim();
    for (final val in node.values) {
      final found = _findVisitorDataInDynamic(val);
      if (found != null) return found;
    }
  }
  return null;
}
