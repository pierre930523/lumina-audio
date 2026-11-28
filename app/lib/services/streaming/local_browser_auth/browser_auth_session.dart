part of '../local_browser_auth_service.dart';

class _BrowserAuthSession {
  final WebViewAuthRequest request;
  final DetectedDefaultBrowser detectedBrowser;
  final int port;
  final Directory profileDir;
  final HttpClient httpClient;
  final Duration killWaitTimeout;
  final TaskkillRunner taskkillRunner;
  final void Function(String message) logSink;

  final Completer<WebViewAuthResult> completer = Completer<WebViewAuthResult>();
  final Map<String, _CdpTargetSession> attachedTargets =
      <String, _CdpTargetSession>{};
  final Map<String, String> capturedCookies = <String, String>{};
  final Map<String, String> capturedHeaders = <String, String>{};
  final Map<String, String> capturedQueryParams = <String, String>{};
  final Map<String, String> capturedStorage = <String, String>{};
  final Map<String, String> capturedResponseValues = <String, String>{};

  String cookieHeader = '';
  bool hadAttachedPage = false;
  bool cdpDiscoveryFinished = false;
  bool cancelRequested = false;
  bool cleaningUp = false;
  bool pollInFlight = false;

  final Completer<void> cancelSignal = Completer<void>();
  final Completer<void> exitSignal = Completer<void>();

  Process? process;
  bool processExited = false;
  int? processExitCode;

  Timer? _pollTimer;
  Timer? _timeoutTimer;
  Future<void>? _cleanupFuture;

  _BrowserAuthSession({
    required this.request,
    required this.detectedBrowser,
    required this.port,
    required this.profileDir,
    required this.httpClient,
    required this.killWaitTimeout,
    required this.taskkillRunner,
    required this.logSink,
  });

  bool get isDone => completer.isCompleted;

  void attachProcess(Process proc) {
    process = proc;
    unawaited(proc.stdout.drain<void>().catchError((_) {}));
    unawaited(proc.stderr.drain<void>().catchError((_) {}));
    unawaited(
      proc.exitCode.then((code) {
        processExited = true;
        processExitCode = code;
        if (!exitSignal.isCompleted) {
          exitSignal.complete();
        }
        if (!cleaningUp &&
            !completer.isCompleted &&
            (cdpDiscoveryFinished || code == 0)) {
          completer.complete(
            WebViewAuthResult(
              captured: false,
              cancelled: true,
              detectedBrowserName: detectedBrowser.displayName,
              detectedBrowserPath: detectedBrowser.executablePath,
            ),
          );
        }
      }),
    );
  }

  void startTimeoutTimer(Duration duration) {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(duration, () {
      if (!completer.isCompleted) {
        completer.complete(
          WebViewAuthResult(
            captured: false,
            cancelled: cancelRequested,
            detectedBrowserName: detectedBrowser.displayName,
            detectedBrowserPath: detectedBrowser.executablePath,
            error: '等待本地瀏覽器登入授權逾時',
          ),
        );
      }
    });
  }

  void startPollTimer(Duration interval, Future<void> Function() onTick) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(interval, (_) {
      if (!completer.isCompleted && !cleaningUp) {
        unawaited(onTick());
      }
    });
  }

  void requestCancel() {
    cancelRequested = true;
    if (!cancelSignal.isCompleted) {
      cancelSignal.complete();
    }
    completeCancelled();
  }

  void completeCancelled() {
    if (!completer.isCompleted) {
      completer.complete(
        WebViewAuthResult(
          captured: false,
          cancelled: true,
          detectedBrowserName: detectedBrowser.displayName,
          detectedBrowserPath: detectedBrowser.executablePath,
        ),
      );
    }
  }

  void completeBlocked({required String capturedUrl, required String error}) {
    if (!completer.isCompleted) {
      logSink(
        '[BrowserAuth] Platform security block detected for ${request.providerKind} at $capturedUrl',
      );
      completer.complete(
        WebViewAuthResult(
          captured: false,
          cancelled: false,
          isBlockedByPlatform: true,
          detectedBrowserName: detectedBrowser.displayName,
          detectedBrowserPath: detectedBrowser.executablePath,
          capturedUrl: capturedUrl,
          error: error,
        ),
      );
    }
  }

  void completeCaptured(String capturedUrl) {
    if (!completer.isCompleted) {
      final summary = _buildMaskedCaptureSummary();
      logSink(
        '[BrowserAuth] Captured ${request.providerKind} credentials '
        'from ${detectedBrowser.displayName} ($summary)',
      );
      completer.complete(
        WebViewAuthResult(
          captured: true,
          cancelled: false,
          detectedBrowserName: detectedBrowser.displayName,
          detectedBrowserPath: detectedBrowser.executablePath,
          cookieHeader: cookieHeader,
          cookies: Map<String, String>.unmodifiable(capturedCookies),
          headers: Map<String, String>.unmodifiable(capturedHeaders),
          queryParams: Map<String, String>.unmodifiable(capturedQueryParams),
          storage: Map<String, String>.unmodifiable(capturedStorage),
          responseValues:
              Map<String, String>.unmodifiable(capturedResponseValues),
          capturedUrl: capturedUrl,
        ),
      );
    }
  }

  String _buildMaskedCaptureSummary() {
    final parts = <String>[];
    if (capturedCookies.isNotEmpty) {
      final firstVal = capturedCookies.values.first;
      parts.add('cookies=${capturedCookies.length}:${maskSecretForLog(firstVal)}');
    }
    if (capturedHeaders.isNotEmpty) {
      for (final e in capturedHeaders.entries) {
        final raw = e.value.toLowerCase().startsWith('bearer ')
            ? e.value.substring(7).trim()
            : e.value;
        parts.add('hdr:${e.key}=${maskSecretForLog(raw)}');
      }
    }
    if (capturedQueryParams.isNotEmpty) {
      for (final e in capturedQueryParams.entries) {
        parts.add('qry:${e.key}=${maskSecretForLog(e.value)}');
      }
    }
    if (capturedResponseValues.isNotEmpty) {
      for (final e in capturedResponseValues.entries) {
        parts.add('resp:${e.key}=${maskSecretForLog(e.value)}');
      }
    }
    if (capturedStorage.isNotEmpty) {
      for (final e in capturedStorage.entries.take(3)) {
        parts.add('storage:${e.key}=${maskSecretForLog(e.value)}');
      }
    }
    return parts.isEmpty ? 'empty' : parts.join(', ');
  }

  Future<void> cleanup() {
    return _cleanupFuture ??= _performCleanup();
  }

  Future<void> _performCleanup() async {
    cleaningUp = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;

    final targets = List<_CdpTargetSession>.from(attachedTargets.values);
    attachedTargets.clear();

    if (targets.isNotEmpty) {
      try {
        await targets.first.sendCommandSafe(
          'Browser.close',
          params: const <String, dynamic>{},
          timeout: const Duration(milliseconds: 250),
        );
      } catch (_) {}
    }

    for (final target in targets) {
      await target.close();
    }

    try {
      httpClient.close(force: true);
    } catch (_) {}

    final proc = process;
    if (proc != null && !processExited) {
      try {
        proc.kill();
      } catch (_) {}

      try {
        await proc.exitCode.timeout(killWaitTimeout);
      } catch (_) {}

      if (!processExited && Platform.isWindows && proc.pid > 0) {
        try {
          await taskkillRunner(proc.pid);
        } catch (_) {}
        try {
          await proc.exitCode.timeout(const Duration(milliseconds: 400));
        } catch (_) {}
      }
    }

    await _deleteProfileDirWithRetry(profileDir);
    logSink(
      '[BrowserAuth] Cleanup complete for ${request.providerKind} '
      '(port=$port, pid=${proc?.pid}, tempProfileDeleted=${!profileDir.existsSync()})',
    );
  }

  static Future<void> _deleteProfileDirWithRetry(Directory dir) async {
    const retryDelaysMs = <int>[0, 50, 120, 250, 400];
    for (final delayMs in retryDelaysMs) {
      if (delayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      }
      try {
        if (!dir.existsSync()) return;
        dir.deleteSync(recursive: true);
        return;
      } catch (_) {
        // Retry briefly in case Chromium still holds file locks on Windows.
      }
    }
  }
}

class _CdpTargetSession {
  final String targetId;
  final WebSocket socket;
  final Map<int, Completer<Map<String, dynamic>>> _pending =
      <int, Completer<Map<String, dynamic>>>{};
  final Set<String> matchedRequestIds = <String>{};
  final Set<String> matchedResponseRequestIds = <String>{};
  final Set<String> fetchedResponseRequestIds = <String>{};
  final Map<String, String> pendingResponseBodyUrls = <String, String>{};

  StreamSubscription<dynamic>? subscription;
  String currentUrl;
  String? mainFrameId;
  bool hasNavigatedEvent = false;
  int _nextId = 1;
  bool _closed = false;

  _CdpTargetSession({
    required this.targetId,
    required this.socket,
    required String initialUrl,
  }) : currentUrl = initialUrl;

  Future<Map<String, dynamic>?> sendCommandSafe(
    String method, {
    Map<String, dynamic> params = const <String, dynamic>{},
    Duration timeout = const Duration(milliseconds: 700),
  }) async {
    if (_closed || socket.readyState != WebSocket.open) return null;
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    try {
      socket.add(
        jsonEncode(<String, dynamic>{
          'id': id,
          'method': method,
          'params': params,
        }),
      );
      return await completer.future.timeout(timeout);
    } catch (_) {
      _pending.remove(id);
      return null;
    }
  }

  void completeCommand(int id, Map<String, dynamic> response) {
    final completer = _pending.remove(id);
    if (completer != null && !completer.isCompleted) {
      completer.complete(response);
    }
  }

  void failAllPending() {
    if (_pending.isEmpty) return;
    final pending = List<Completer<Map<String, dynamic>>>.from(_pending.values);
    _pending.clear();
    for (final c in pending) {
      if (!c.isCompleted) {
        c.complete(const <String, dynamic>{});
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    failAllPending();
    try {
      await subscription?.cancel();
    } catch (_) {}
    subscription = null;
    try {
      await socket.close().timeout(const Duration(milliseconds: 250));
    } catch (_) {}
  }
}
