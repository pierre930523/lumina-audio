part of '../local_browser_auth_service.dart';

extension _LocalBrowserLauncherExt on LocalBrowserAuthService {
  Future<WebViewAuthResult> _openAuthWindowImpl(
    WebViewAuthRequest request,
    Zone callerZone,
  ) async {
    final detected = callerZone.run(resolveDetectedBrowser);
    if (detected == null) {
      _log('[BrowserAuth] Default browser detection returned null; no supported browser found');
      return const WebViewAuthResult(
        captured: false,
        cancelled: false,
        error: '未偵測到可用的本地瀏覽器（Brave / Google Chrome / Microsoft Edge）',
      );
    }

    _log(
      '[BrowserAuth] Default browser detected: ${detected.displayName} '
      '(exe=${detected.executablePath}, progId=${detected.progId ?? 'none'}, '
      'isChromium=${detected.isChromium}, fromRegistry=${detected.fromRegistry})',
    );

    if (_activeSession != null || _activeNonChromiumSession != null) {
      await closeAuthWindow();
    }

    if (!detected.isChromium) {
      return _openNonChromiumAssistedAuth(request, detected, callerZone);
    }

    final browserPath = detected.executablePath;
    final probeSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probeSocket.port;
    await probeSocket.close();

    final sanitizedKind =
        request.providerKind.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final ts = DateTime.now().millisecondsSinceEpoch;
    final profilePrefix = 'lumina_auth_${sanitizedKind}_${ts}_';
    final profileDir = await callerZone.run(
      () =>
          tempDirCreator?.call(profilePrefix) ??
          Directory.systemTemp.createTemp(profilePrefix),
    );

    final effectiveTaskkill =
        taskkillRunner ?? LocalBrowserAuthService._defaultTaskkill;
    final session = _BrowserAuthSession(
      request: request,
      detectedBrowser: detected,
      port: port,
      profileDir: profileDir,
      httpClient: callerZone.run(() => (httpClientFactory ?? HttpClient.new)()),
      killWaitTimeout: killWaitTimeout,
      taskkillRunner: (pid) => callerZone.run(() => effectiveTaskkill(pid)),
      logSink: _log,
    );
    _activeSession = session;

    try {
      final args = LocalBrowserAuthService.buildLaunchArguments(
        port: port,
        profileDirPath: profileDir.path,
        initialUrl: request.initialUrl,
      );
      final starter = processStarter ??
          (String exe, List<String> a) => Process.start(exe, a);

      _log(
        '[BrowserAuth] Launching ${detected.displayName} ($browserPath) '
        'for ${request.providerKind} with CDP port=$port, profile=${profileDir.path}',
      );

      Process process;
      try {
        process = await callerZone.run(() => starter(browserPath, args));
      } catch (e) {
        _log('[BrowserAuth] Failed to launch ${detected.displayName}: $e');
        return WebViewAuthResult(
          captured: false,
          cancelled: session.cancelRequested,
          detectedBrowserName: detected.displayName,
          detectedBrowserPath: browserPath,
          error: '無法啟動本地瀏覽器（${detected.displayName}）：$e',
        );
      }

      session.attachProcess(process);

      if (session.cancelRequested) {
        return WebViewAuthResult(
          captured: false,
          cancelled: true,
          detectedBrowserName: detected.displayName,
          detectedBrowserPath: browserPath,
        );
      }

      session.startTimeoutTimer(timeout);

      final initialTargets = await _discoverInitialPageTargets(session);
      session.cdpDiscoveryFinished = true;
      if (session.completer.isCompleted) {
        return await session.completer.future;
      }
      if (session.cancelRequested) {
        return WebViewAuthResult(
          captured: false,
          cancelled: true,
          detectedBrowserName: detected.displayName,
          detectedBrowserPath: browserPath,
        );
      }
      if (session.processExited) {
        if (session.processExitCode == 0) {
          return WebViewAuthResult(
            captured: false,
            cancelled: true,
            detectedBrowserName: detected.displayName,
            detectedBrowserPath: browserPath,
          );
        }
        return WebViewAuthResult(
          captured: false,
          cancelled: false,
          detectedBrowserName: detected.displayName,
          detectedBrowserPath: browserPath,
          error:
              '本地瀏覽器（${detected.displayName}）在 CDP 偵錯介面就緒前已結束（exitCode=${session.processExitCode}）',
        );
      }
      if (initialTargets == null || initialTargets.isEmpty) {
        return WebViewAuthResult(
          captured: false,
          cancelled: session.cancelRequested,
          detectedBrowserName: detected.displayName,
          detectedBrowserPath: browserPath,
          error: '等待本地瀏覽器（${detected.displayName}）CDP 偵錯介面逾時，請改用系統瀏覽器 OAuth 或手動 Token',
        );
      }

      for (final target in initialTargets) {
        await _attachTarget(session, target);
      }

      if (session.attachedTargets.isEmpty && !session.completer.isCompleted) {
        return WebViewAuthResult(
          captured: false,
          cancelled: session.cancelRequested,
          detectedBrowserName: detected.displayName,
          detectedBrowserPath: browserPath,
          error: '無法連線至本地瀏覽器 CDP WebSocket 除錯通道',
        );
      }

      // Immediately evaluate initial targets (for pages/cookies already ready).
      unawaited(_runPollCycle(session));
      session.startPollTimer(pollInterval, () => _runPollCycle(session));

      return await session.completer.future;
    } finally {
      await session.cleanup();
      if (identical(_activeSession, session)) {
        _activeSession = null;
      }
    }
  }

  Future<WebViewAuthResult> _openNonChromiumAssistedAuth(
    WebViewAuthRequest request,
    DetectedDefaultBrowser detected,
    Zone callerZone,
  ) async {
    _log(
      '[BrowserAuth] Non-Chromium default browser ${detected.displayName} '
      '(${detected.executablePath}); opening ${request.initialUrl} in real default browser without Edge/Chrome fallback',
    );

    if (!enableNonChromiumLoopbackHelper) {
      try {
        await callerZone.run(
          () => openSystemBrowser(
            request.initialUrl,
            urlOpener: systemUrlOpener,
          ),
        );
      } catch (e) {
        _log('[BrowserAuth] openSystemBrowser error for ${detected.displayName}: $e');
      }
      return WebViewAuthResult(
        captured: false,
        cancelled: false,
        isNonChromiumDefault: true,
        detectedBrowserName: detected.displayName,
        detectedBrowserPath: detected.executablePath,
        error:
            '已於系統預設瀏覽器（${detected.displayName}）開啟 ${request.title}。'
            '因 ${detected.displayName} 非 Chromium 核心，不支援自動 CDP 擷取；'
            '請於瀏覽器完成登入後，依下方指引貼上憑證完成驗證。',
      );
    }

    final assist = _NonChromiumAssistSession(
      request: request,
      detectedBrowser: detected,
      logSink: _log,
    );
    _activeNonChromiumSession = assist;
    try {
      await assist.start();
      onNonChromiumLoopbackReady?.call(assist.helperUrl);
      try {
        await callerZone.run(
          () => openSystemBrowser(
            request.initialUrl,
            urlOpener: systemUrlOpener,
          ),
        );
      } catch (e) {
        _log('[BrowserAuth] openSystemBrowser error for ${detected.displayName}: $e');
      }
      assist.startTimeoutTimer(timeout);
      return await assist.completer.future;
    } finally {
      await assist.close();
      if (identical(_activeNonChromiumSession, assist)) {
        _activeNonChromiumSession = null;
      }
    }
  }
}
