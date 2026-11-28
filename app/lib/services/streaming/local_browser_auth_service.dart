import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'oauth_helper.dart';
import 'webview_auth_service.dart';

part 'local_browser_auth/browser_auth_launcher.dart';
part 'local_browser_auth/browser_auth_session.dart';
part 'local_browser_auth/browser_detection.dart';
part 'local_browser_auth/cdp_credential_capture.dart';
part 'local_browser_auth/cdp_target_polling.dart';
part 'local_browser_auth/non_chromium_assist_session.dart';

/// Launches an isolated local Chromium browser window (Registry default such as
/// Brave/Chrome/Edge, or fallback) with Chrome DevTools Protocol (CDP)
/// WebSocket capture for streaming login cookies, headers, responses, and storage.
/// When the Registry default browser is non-Chromium (e.g. Firefox/Zen), opens
/// the login URL in that real browser instead of falling back to Edge/Chrome.
class LocalBrowserAuthService implements WebViewAuthService {
  final List<String>? candidatePathsOverride;
  final Map<String, String>? environmentOverride;
  final bool Function(String path)? fileExistsOverride;
  final bool? isWindowsOverride;
  final RegistryValueReader? registryReader;
  final BrowserProcessStarter? processStarter;
  final Future<Directory> Function(String prefix)? tempDirCreator;
  final Duration timeout;
  final Duration cdpDiscoveryTimeout;
  final Duration cdpDiscoveryInterval;
  final Duration cdpWarningThreshold;
  final Duration pollInterval;
  final Duration killWaitTimeout;
  final HttpClient Function()? httpClientFactory;
  final TaskkillRunner? taskkillRunner;
  final void Function(String message)? logSink;
  final Future<bool> Function(String url)? systemUrlOpener;
  final bool enableNonChromiumLoopbackHelper;
  final void Function(String helperUrl)? onNonChromiumLoopbackReady;

  _BrowserAuthSession? _activeSession;
  _NonChromiumAssistSession? _activeNonChromiumSession;

  LocalBrowserAuthService({
    this.candidatePathsOverride,
    this.environmentOverride,
    this.fileExistsOverride,
    this.isWindowsOverride,
    this.registryReader,
    this.processStarter,
    this.tempDirCreator,
    this.timeout = const Duration(minutes: 5),
    this.cdpDiscoveryTimeout = const Duration(seconds: 15),
    this.cdpDiscoveryInterval = const Duration(milliseconds: 200),
    this.cdpWarningThreshold = const Duration(seconds: 5),
    this.pollInterval = const Duration(seconds: 1),
    this.killWaitTimeout = const Duration(milliseconds: 800),
    this.httpClientFactory,
    this.taskkillRunner,
    this.logSink,
    this.systemUrlOpener,
    this.enableNonChromiumLoopbackHelper = false,
    this.onNonChromiumLoopbackReady,
  });

  void _log(String message) {
    final sink = logSink;
    if (sink != null) {
      sink(message);
    } else {
      debugPrint(message);
    }
  }

  /// Resolves the browser to use: explicit candidate override -> Windows
  /// Registry default browser (respecting non-Chromium browsers without fallback)
  /// -> installed Chromium fallback paths only if Registry returned null.
  DetectedDefaultBrowser? resolveDetectedBrowser() {
    if (candidatePathsOverride != null) {
      final path = detectLocalBrowserPath(
        candidatePathsOverride: candidatePathsOverride,
        environmentOverride: environmentOverride,
        fileExistsOverride: fileExistsOverride,
        isWindowsOverride: isWindowsOverride,
      );
      if (path == null) return null;
      final exeName = _extractExecutableName(path);
      return DetectedDefaultBrowser(
        progId: null,
        executablePath: path,
        executableName: exeName,
        isChromium: isChromiumBrowserExecutable(path),
        fromRegistry: false,
      );
    }

    final fromRegistry = detectWindowsDefaultBrowser(
      isWindowsOverride: isWindowsOverride,
      registryReader: registryReader,
      fileExistsOverride: fileExistsOverride,
      environmentOverride: environmentOverride,
    );
    if (fromRegistry != null) {
      return fromRegistry;
    }

    final fallbackPath = detectLocalBrowserPath(
      environmentOverride: environmentOverride,
      fileExistsOverride: fileExistsOverride,
      isWindowsOverride: isWindowsOverride,
    );
    if (fallbackPath == null) return null;
    final exeName = _extractExecutableName(fallbackPath);
    return DetectedDefaultBrowser(
      progId: null,
      executablePath: fallbackPath,
      executableName: exeName,
      isChromium: isChromiumBrowserExecutable(fallbackPath),
      fromRegistry: false,
    );
  }

  String? resolveBrowserPath() {
    final detected = resolveDetectedBrowser();
    if (detected == null || !detected.isChromium) {
      return null;
    }
    return detected.executablePath;
  }

  Future<bool> isLocalBrowserAvailable() async =>
      resolveDetectedBrowser() != null;

  @override
  Future<bool> isWebView2Available() => isLocalBrowserAvailable();

  static List<String> buildLaunchArguments({
    required int port,
    required String profileDirPath,
    required String initialUrl,
  }) {
    return <String>[
      '--remote-debugging-port=$port',
      '--remote-allow-origins=*',
      '--user-data-dir=$profileDirPath',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-default-apps',
      '--new-window',
      '--disable-blink-features=AutomationControlled',
      initialUrl,
    ];
  }

  @override
  Future<WebViewAuthResult> openAuthWindow(WebViewAuthRequest request) {
    final callerZone = Zone.current;
    return Zone.root.run(() => _openAuthWindowImpl(request, callerZone));
  }

  @override
  Future<void> closeAuthWindow() {
    return Zone.root.run(() async {
      final assist = _activeNonChromiumSession;
      if (assist != null) {
        assist.requestCancel();
        await assist.close();
        if (identical(_activeNonChromiumSession, assist)) {
          _activeNonChromiumSession = null;
        }
      }

      final session = _activeSession;
      if (session == null) return;
      session.requestCancel();
      await session.cleanup();
      if (identical(_activeSession, session)) {
        _activeSession = null;
      }
    });
  }

  static bool matchesUrlGuard(String url, WebViewAuthRequest request) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return false;
    final lower = trimmed.toLowerCase();

    final requiredHost = request.requiredHostSubstring?.trim().toLowerCase();
    if (requiredHost != null && requiredHost.isNotEmpty) {
      if (!lower.contains(requiredHost)) {
        return false;
      }
    }
    for (final excluded in request.excludedUrlSubstrings) {
      final needle = excluded.trim().toLowerCase();
      if (needle.isNotEmpty && lower.contains(needle)) {
        return false;
      }
    }
    return true;
  }

  static bool isCaptureSatisfied({
    required WebViewAuthRequest request,
    required Map<String, String> cookies,
    required Map<String, String> headers,
    required Map<String, String> queryParams,
    Map<String, String> responseValues = const {},
    Map<String, String> storage = const {},
  }) {
    var hasAnyRule = false;

    if (request.requiredAnyCookies.isNotEmpty) {
      hasAnyRule = true;
      final matched = request.requiredAnyCookies.any(
        (name) => _hasCookie(cookies, name),
      );
      if (!matched) return false;
    }

    if (request.requiredAllCookies.isNotEmpty) {
      hasAnyRule = true;
      for (final name in request.requiredAllCookies) {
        if (!_hasCookie(cookies, name)) {
          return false;
        }
      }
    }

    if (request.requiredHeaders.isNotEmpty) {
      hasAnyRule = true;
      for (final hdr in request.requiredHeaders) {
        final key = hdr.toLowerCase();
        if (!_hasValue(headers, key) && !_hasValue(queryParams, key)) {
          return false;
        }
      }
    }

    if (request.requiredGroups.isNotEmpty) {
      hasAnyRule = true;
      for (final group in request.requiredGroups) {
        var groupOk = false;
        for (final item in group) {
          if (item.startsWith('cookie:')) {
            if (_hasCookie(cookies, item.substring(7))) {
              groupOk = true;
              break;
            }
          } else if (item.startsWith('header:')) {
            if (_hasValue(headers, item.substring(7).toLowerCase())) {
              groupOk = true;
              break;
            }
          } else if (item.startsWith('query:')) {
            if (_hasValue(queryParams, item.substring(6).toLowerCase())) {
              groupOk = true;
              break;
            }
          } else if (item.startsWith('response:')) {
            if (_hasValue(responseValues, item.substring(9).toLowerCase())) {
              groupOk = true;
              break;
            }
          } else if (item.startsWith('storage:')) {
            if (_hasValue(storage, item.substring(8).toLowerCase())) {
              groupOk = true;
              break;
            }
          }
        }
        if (!groupOk) return false;
      }
    }

    return hasAnyRule;
  }

  static bool isGoogleBlockedUrl(String url) {
    final lower = url.trim().toLowerCase();
    return lower.contains('/signin/rejected') ||
        lower.contains('accounts.google.com/v3/signin/rejected');
  }

  static bool isGoogleBlockedPageText(String text) {
    if (text.trim().isEmpty) return false;
    final normalized = text
        .replaceAll('’', "'")
        .replaceAll('‘', "'")
        .toLowerCase();
    return normalized.contains('this browser or app may not be secure') ||
        normalized.contains("couldn't sign you in") ||
        normalized.contains('could not sign you in') ||
        normalized.contains('這個瀏覽器或應用程式可能不安全') ||
        normalized.contains('此瀏覽器或應用程式可能不安全');
  }

  static Future<ProcessResult> _defaultTaskkill(int pid) {
    return Process.run('taskkill', <String>['/PID', '$pid', '/T', '/F']);
  }
}
