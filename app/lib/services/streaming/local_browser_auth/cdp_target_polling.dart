part of '../local_browser_auth_service.dart';

extension _LocalBrowserCdpPollingExt on LocalBrowserAuthService {
  Future<List<Map<String, dynamic>>?> _discoverInitialPageTargets(
    _BrowserAuthSession session,
  ) async {
    final startedAt = DateTime.now();
    final deadline = startedAt.add(cdpDiscoveryTimeout);
    var warned = false;
    while (!session.isDone &&
        !session.cancelRequested &&
        !session.processExited) {
      final targets = await _fetchPageTargets(session);
      if (targets != null && targets.isNotEmpty) {
        return targets;
      }
      final elapsed = DateTime.now().difference(startedAt);
      if (!warned && elapsed >= cdpWarningThreshold) {
        warned = true;
        final waitLabel = cdpWarningThreshold.inSeconds >= 1
            ? '${cdpWarningThreshold.inSeconds}s'
            : '${cdpWarningThreshold.inMilliseconds}ms';
        _log(
          '[BrowserAuth] WARNING: CDP port ${session.port} did not respond within $waitLabel '
          '(browser=${session.detectedBrowser.displayName}); continuing up to ${cdpDiscoveryTimeout.inSeconds}s...',
        );
      }
      if (DateTime.now().isAfter(deadline)) {
        return null;
      }
      await Future.any<void>(<Future<void>>[
        Future<void>.delayed(cdpDiscoveryInterval),
        session.cancelSignal.future,
        session.exitSignal.future,
      ]);
    }
    return null;
  }

  Future<List<Map<String, dynamic>>?> _fetchPageTargets(
    _BrowserAuthSession session,
  ) async {
    if (session.isDone || session.cleaningUp) return null;
    try {
      final uri = Uri.parse('http://127.0.0.1:${session.port}/json/list');
      final req = await session.httpClient
          .getUrl(uri)
          .timeout(const Duration(seconds: 2));
      final resp = await req.close().timeout(const Duration(seconds: 2));
      final body = await utf8.decoder
          .bind(resp)
          .join()
          .timeout(const Duration(seconds: 2));
      if (resp.statusCode != HttpStatus.ok) {
        return null;
      }
      final decoded = jsonDecode(body);
      if (decoded is! List) return null;
      final pages = <Map<String, dynamic>>[];
      for (final item in decoded) {
        if (item is Map) {
          final map = Map<String, dynamic>.from(item);
          final type = map['type']?.toString();
          final wsUrl = map['webSocketDebuggerUrl']?.toString().trim() ?? '';
          if (type == 'page' && wsUrl.isNotEmpty) {
            pages.add(map);
          }
        }
      }
      return pages;
    } catch (_) {
      return null;
    }
  }

  Future<void> _attachTarget(
    _BrowserAuthSession session,
    Map<String, dynamic> target,
  ) async {
    if (session.isDone || session.cleaningUp) return;
    final targetId = target['id']?.toString().trim() ?? '';
    final wsUrl = target['webSocketDebuggerUrl']?.toString().trim() ?? '';
    if (targetId.isEmpty || wsUrl.isEmpty) return;
    if (session.attachedTargets.containsKey(targetId)) return;

    try {
      final socket = await WebSocket.connect(wsUrl)
          .timeout(const Duration(seconds: 3));
      if (session.isDone || session.cleaningUp) {
        await socket.close();
        return;
      }

      final targetSession = _CdpTargetSession(
        targetId: targetId,
        socket: socket,
        initialUrl: target['url']?.toString() ?? '',
      );
      unawaited(socket.done.catchError((_) {}));
      session.attachedTargets[targetId] = targetSession;
      session.hadAttachedPage = true;

      targetSession.subscription = socket.listen(
        (dynamic raw) => _handleCdpMessage(session, targetSession, raw),
        onError: (_) => _handleTargetClosed(session, targetSession),
        onDone: () => _handleTargetClosed(session, targetSession),
        cancelOnError: true,
      );

      // Enable required CDP domains concurrently (best effort, short timeout).
      await Future.wait(<Future<void>>[
        targetSession.sendCommandSafe('Network.enable'),
        targetSession.sendCommandSafe('Page.enable'),
        targetSession.sendCommandSafe('Runtime.enable'),
      ]);

      _log(
        '[BrowserAuth] CDP connected to target $targetId on port ${session.port} '
        '(url=${targetSession.currentUrl})',
      );

      await _checkNavigationAndAntiBlock(session, targetSession);
    } catch (_) {
      // Target may have closed while connecting; poll cycle handles remaining tabs.
    }
  }

  void _handleTargetClosed(
    _BrowserAuthSession session,
    _CdpTargetSession target,
  ) {
    target.failAllPending();
    session.attachedTargets.remove(target.targetId);
    if (!session.isDone && !session.cleaningUp && session.attachedTargets.isEmpty) {
      unawaited(_verifyBrowserStillOpen(session));
    }
  }

  Future<void> _verifyBrowserStillOpen(_BrowserAuthSession session) async {
    if (session.isDone || session.cleaningUp) return;
    if (session.processExited) {
      session.completeCancelled();
      return;
    }
    final pages = await _fetchPageTargets(session);
    if (session.isDone || session.cleaningUp) return;
    if (session.processExited) {
      session.completeCancelled();
      return;
    }
    if (pages != null && pages.isEmpty && session.hadAttachedPage) {
      session.completeCancelled();
    }
  }

  void _handleCdpMessage(
    _BrowserAuthSession session,
    _CdpTargetSession target,
    dynamic raw,
  ) {
    if (session.isDone || session.cleaningUp) return;
    if (raw is! String) return;

    final Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      msg = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return;
    }

    final idVal = msg['id'];
    if (idVal is int) {
      target.completeCommand(idVal, msg);
      return;
    }

    final method = msg['method']?.toString();
    final paramsRaw = msg['params'];
    if (method == null || paramsRaw is! Map) return;
    final params = Map<String, dynamic>.from(paramsRaw);

    switch (method) {
      case 'Page.frameNavigated':
        final frame = params['frame'];
        if (frame is Map) {
          final parentId = frame['parentId']?.toString().trim() ?? '';
          if (parentId.isEmpty) {
            final frameId = frame['id']?.toString();
            if (frameId != null && frameId.isNotEmpty) {
              target.mainFrameId = frameId;
            }
            final nextUrl = frame['url']?.toString().trim() ?? '';
            if (nextUrl.isNotEmpty) {
              target.currentUrl = nextUrl;
              target.hasNavigatedEvent = true;
              unawaited(_onTopUrlUpdated(session, target));
            }
          }
        }
        break;
      case 'Page.navigatedWithinDocument':
        final frameId = params['frameId']?.toString();
        if (target.mainFrameId == null || frameId == target.mainFrameId) {
          final nextUrl = params['url']?.toString().trim() ?? '';
          if (nextUrl.isNotEmpty) {
            target.currentUrl = nextUrl;
            target.hasNavigatedEvent = true;
            unawaited(_onTopUrlUpdated(session, target));
          }
        }
        break;
      case 'Network.requestWillBeSent':
        final req = params['request'];
        if (req is Map) {
          final reqUrl = req['url']?.toString() ?? '';
          final matchesHeaders = _matchesAnySubstring(
            reqUrl,
            session.request.headerUrlSubstrings,
          );
          final matchesResponse = _matchesAnySubstring(
            reqUrl,
            session.request.responseBodyUrlSubstrings,
          );
          if (matchesHeaders || matchesResponse) {
            final requestId = params['requestId']?.toString();
            if (requestId != null && requestId.isNotEmpty) {
              if (matchesHeaders) {
                target.matchedRequestIds.add(requestId);
              }
              if (matchesResponse) {
                target.matchedResponseRequestIds.add(requestId);
              }
            }
            _captureHeadersFromMap(session, req['headers']);
            _captureQueryParamsFromUrl(session, reqUrl);
            _capturePostDataParams(session, req['postData']);
            _evaluateAllTargets(session);
          }
        }
        break;
      case 'Network.requestWillBeSentExtraInfo':
        final requestId = params['requestId']?.toString();
        if (requestId != null && target.matchedRequestIds.contains(requestId)) {
          _captureHeadersFromMap(session, params['headers']);
          _evaluateAllTargets(session);
        }
        break;
      case 'Network.responseReceived':
        final requestId = params['requestId']?.toString() ?? '';
        final resp = params['response'];
        if (requestId.isNotEmpty && resp is Map) {
          final respUrl = resp['url']?.toString() ?? '';
          final status = (resp['status'] as num?)?.toInt();
          final matchesResponse =
              _matchesAnySubstring(
                respUrl,
                session.request.responseBodyUrlSubstrings,
              ) ||
              target.matchedResponseRequestIds.contains(requestId);
          if (matchesResponse &&
              (status == null || (status >= 200 && status < 300))) {
            target.pendingResponseBodyUrls[requestId] = respUrl;
            unawaited(
              _fetchAndParseResponseBody(session, target, requestId, respUrl),
            );
          }
        }
        break;
      case 'Network.loadingFinished':
        final requestId = params['requestId']?.toString() ?? '';
        final respUrl = target.pendingResponseBodyUrls.remove(requestId);
        if (requestId.isNotEmpty &&
            respUrl != null &&
            !target.fetchedResponseRequestIds.contains(requestId)) {
          unawaited(
            _fetchAndParseResponseBody(session, target, requestId, respUrl),
          );
        }
        break;
      case 'Inspector.detached':
        _handleTargetClosed(session, target);
        break;
    }
  }

  Future<void> _fetchAndParseResponseBody(
    _BrowserAuthSession session,
    _CdpTargetSession target,
    String requestId,
    String respUrl,
  ) async {
    if (session.isDone ||
        session.cleaningUp ||
        target.fetchedResponseRequestIds.contains(requestId)) {
      return;
    }
    final resp = await target.sendCommandSafe(
      'Network.getResponseBody',
      params: <String, dynamic>{'requestId': requestId},
      timeout: const Duration(milliseconds: 900),
    );
    if (resp == null || session.isDone || session.cleaningUp) return;
    final result = resp['result'];
    if (result is! Map) return;
    final rawBody = result['body']?.toString() ?? '';
    if (rawBody.trim().isEmpty) return;

    target.fetchedResponseRequestIds.add(requestId);
    target.pendingResponseBodyUrls.remove(requestId);

    String decodedBody = rawBody;
    if (result['base64Encoded'] == true) {
      try {
        decodedBody = utf8.decode(base64Decode(rawBody));
      } catch (_) {
        return;
      }
    }

    try {
      final parsed = jsonDecode(decodedBody);
      if (parsed is Map) {
        final beforeCount = session.capturedResponseValues.length;
        _extractAuthFieldsIntoMap(
          parsed,
          session.capturedResponseValues,
          includeRawScalarKeys: true,
        );
        if (session.capturedResponseValues.length > beforeCount ||
            session.capturedResponseValues.isNotEmpty) {
          final maskedParts = session.capturedResponseValues.entries
              .map((e) => '${e.key}=${maskSecretForLog(e.value)}')
              .join(', ');
          if (maskedParts.isNotEmpty) {
            _log(
              '[BrowserAuth] Response body extracted from $respUrl ($maskedParts)',
            );
          }
        }
        _evaluateAllTargets(session);
      }
    } catch (_) {
      // Non-JSON response body; ignore.
    }
  }

  Future<void> _onTopUrlUpdated(
    _BrowserAuthSession session,
    _CdpTargetSession target,
  ) async {
    await _checkNavigationAndAntiBlock(session, target);
    if (session.isDone || session.cleaningUp) return;
    if (LocalBrowserAuthService.matchesUrlGuard(
      target.currentUrl,
      session.request,
    )) {
      await _pollCookiesForTarget(session, target);
      if (session.isDone || session.cleaningUp) return;
      if (session.request.inspectWebStorage) {
        await _pollWebStorageForTarget(session, target);
      }
    }
    _evaluateAllTargets(session);
  }

  Future<void> _runPollCycle(_BrowserAuthSession session) async {
    if (session.isDone || session.cleaningUp || session.pollInFlight) return;
    session.pollInFlight = true;
    try {
      if (session.cancelRequested || session.processExited) {
        session.completeCancelled();
        return;
      }

      final pages = await _fetchPageTargets(session);
      if (session.isDone || session.cleaningUp) return;

      if (session.cancelRequested || session.processExited) {
        session.completeCancelled();
        return;
      }

      if (pages != null) {
        if (pages.isEmpty && session.hadAttachedPage) {
          session.completeCancelled();
          return;
        }
        for (final page in pages) {
          final id = page['id']?.toString().trim() ?? '';
          if (id.isEmpty) continue;
          final existing = session.attachedTargets[id];
          if (existing == null) {
            await _attachTarget(session, page);
          } else if (!existing.hasNavigatedEvent) {
            final targetUrl = page['url']?.toString().trim() ?? '';
            if (targetUrl.isNotEmpty) {
              existing.currentUrl = targetUrl;
            }
          }
        }
      }

      final snapshot = List<_CdpTargetSession>.from(
        session.attachedTargets.values,
      );
      for (final target in snapshot) {
        if (session.isDone || session.cleaningUp) return;
        await _checkNavigationAndAntiBlock(session, target);
        if (session.isDone || session.cleaningUp) return;
        if (LocalBrowserAuthService.matchesUrlGuard(
          target.currentUrl,
          session.request,
        )) {
          await _pollCookiesForTarget(session, target);
          if (session.isDone || session.cleaningUp) return;
          if (session.request.inspectWebStorage) {
            await _pollWebStorageForTarget(session, target);
            if (session.isDone || session.cleaningUp) return;
          }
        }
      }
      _evaluateAllTargets(session);
    } catch (_) {
      // Best-effort poll loop; next tick retries.
    } finally {
      session.pollInFlight = false;
    }
  }

  Future<void> _checkNavigationAndAntiBlock(
    _BrowserAuthSession session,
    _CdpTargetSession target,
  ) async {
    if (session.isDone || session.cleaningUp) return;
    if (session.request.providerKind != 'youtube_music') return;

    final url = target.currentUrl;
    if (LocalBrowserAuthService.isGoogleBlockedUrl(url)) {
      session.completeBlocked(
        capturedUrl: url,
        error: 'Google 安全性機制阻擋了本地除錯瀏覽器登入（$url）',
      );
      return;
    }

    if (url.toLowerCase().contains('accounts.google.com')) {
      final resp = await target.sendCommandSafe(
        'Runtime.evaluate',
        params: <String, dynamic>{
          'expression':
              'document.body ? document.body.innerText : ""',
          'returnByValue': true,
        },
        timeout: const Duration(milliseconds: 600),
      );
      if (session.isDone || session.cleaningUp || resp == null) return;
      final result = resp['result'];
      if (result is Map) {
        final inner = result['result'];
        final text = inner is Map ? (inner['value']?.toString() ?? '') : '';
        if (LocalBrowserAuthService.isGoogleBlockedPageText(text)) {
          session.completeBlocked(
            capturedUrl: url,
            error: 'Google 安全性機制拒絕此除錯瀏覽器登入（此瀏覽器或應用程式可能不安全）',
          );
        }
      }
    }
  }
}
