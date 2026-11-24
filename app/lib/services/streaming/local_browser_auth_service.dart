import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'oauth_helper.dart';
import 'webview_auth_service.dart';

typedef BrowserProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments,
);

typedef TaskkillRunner = Future<ProcessResult> Function(int pid);

typedef RegistryValueReader = String? Function(
  String keyPath,
  String? valueName,
);

/// Masks sensitive credentials (tokens/cookies) before writing diagnostic logs.
String maskSecretForLog(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty || trimmed.length <= 2) return '***';
  if (trimmed.length <= 4) return '${trimmed[0]}***';
  return '${trimmed.substring(0, 4)}***';
}

/// Metadata describing the user's detected Windows default (or fallback) browser.
class DetectedDefaultBrowser {
  final String? progId;
  final String executablePath;
  final String executableName;
  final bool isChromium;
  final bool fromRegistry;

  const DetectedDefaultBrowser({
    this.progId,
    required this.executablePath,
    required this.executableName,
    required this.isChromium,
    required this.fromRegistry,
  });

  String get displayName => friendlyBrowserName(
        executableName: executableName,
        progId: progId,
      );
}

/// Returns a clean user-facing browser name from its executable or ProgId.
String friendlyBrowserName({
  required String executableName,
  String? progId,
}) {
  final exe = executableName.trim().toLowerCase();
  switch (exe) {
    case 'brave.exe':
    case 'brave':
      return 'Brave';
    case 'chrome.exe':
    case 'chrome':
      return 'Google Chrome';
    case 'msedge.exe':
    case 'msedge':
      return 'Microsoft Edge';
    case 'vivaldi.exe':
    case 'vivaldi':
      return 'Vivaldi';
    case 'opera.exe':
    case 'opera':
      return 'Opera';
    case 'arc.exe':
    case 'arc':
      return 'Arc';
    case 'chromium.exe':
    case 'chromium':
      return 'Chromium';
    case 'thorium.exe':
    case 'thorium':
      return 'Thorium';
    case 'firefox.exe':
    case 'firefox':
      return 'Firefox';
    case 'zen.exe':
    case 'zen':
      return 'Zen Browser';
    case 'librewolf.exe':
    case 'librewolf':
      return 'LibreWolf';
    case 'waterfox.exe':
    case 'waterfox':
      return 'Waterfox';
    case 'floorp.exe':
    case 'floorp':
      return 'Floorp';
  }
  final pid = progId?.trim().toLowerCase() ?? '';
  if (pid.contains('brave')) return 'Brave';
  if (pid.contains('chrome')) return 'Google Chrome';
  if (pid.contains('msedge')) return 'Microsoft Edge';
  if (pid.contains('firefox')) return 'Firefox';
  if (pid.contains('zen')) return 'Zen Browser';
  final stripped = executableName.replaceFirst(
    RegExp(r'\.exe$', caseSensitive: false),
    '',
  );
  return stripped.isNotEmpty ? stripped : 'Browser';
}

/// Extracts the browser executable path from a Windows Registry command string
/// such as `"C:\Program Files\BraveSoftware\...\brave.exe" --single-argument %1`.
String? parseCommandExecutablePath(
  String rawCmd, {
  Map<String, String>? environmentOverride,
}) {
  var trimmed = rawCmd.trim();
  if (trimmed.isEmpty) return null;

  String? extracted;
  if (trimmed.startsWith('"')) {
    final closing = trimmed.indexOf('"', 1);
    if (closing <= 1) return null;
    extracted = trimmed.substring(1, closing).trim();
  } else {
    final exeMatch = RegExp(
      r'^(.+?\.exe)(?=\s|$)',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (exeMatch != null) {
      extracted = exeMatch.group(1)?.trim();
    } else {
      final firstWhitespace = trimmed.indexOf(RegExp(r'\s'));
      extracted = firstWhitespace > 0
          ? trimmed.substring(0, firstWhitespace).trim()
          : trimmed;
    }
  }

  if (extracted == null || extracted.isEmpty) return null;
  final env = environmentOverride ?? Platform.environment;
  final expanded = extracted.replaceAllMapped(RegExp(r'%([^%]+)%'), (match) {
    final key = match.group(1) ?? '';
    return _readEnvCaseInsensitive(env, key) ?? match.group(0)!;
  });
  return expanded.trim().isEmpty ? null : expanded.trim();
}

/// Determines whether [exeOrPath] (or its Windows [progId]) is a Chromium-based
/// browser that supports Chrome DevTools Protocol (`--remote-debugging-port`).
bool isChromiumBrowserExecutable(String exeOrPath, {String? progId}) {
  final exe = _extractExecutableName(exeOrPath).toLowerCase();

  const nonChromiumExes = <String>{
    'firefox.exe',
    'firefox',
    'zen.exe',
    'zen',
    'librewolf.exe',
    'librewolf',
    'waterfox.exe',
    'waterfox',
    'floorp.exe',
    'floorp',
    'palemoon.exe',
    'palemoon',
    'basilisk.exe',
    'seamonkey.exe',
    'tor.exe',
    'mullvadbrowser.exe',
    'safari.exe',
    'iexplore.exe',
  };
  if (nonChromiumExes.contains(exe)) {
    return false;
  }

  const chromiumExes = <String>{
    'msedge.exe',
    'msedge',
    'chrome.exe',
    'chrome',
    'brave.exe',
    'brave',
    'vivaldi.exe',
    'vivaldi',
    'opera.exe',
    'opera',
    'chromium.exe',
    'chromium',
    'arc.exe',
    'arc',
    'thorium.exe',
    'thorium',
    'ungoogled-chromium.exe',
    'sidekick.exe',
    'comet.exe',
  };
  if (chromiumExes.contains(exe)) {
    return true;
  }

  final pid = progId?.trim().toLowerCase() ?? '';
  if (pid.isNotEmpty) {
    if (pid.contains('firefox') ||
        pid.contains('zen') ||
        pid.contains('librewolf') ||
        pid.contains('waterfox') ||
        pid.contains('floorp') ||
        pid.contains('gecko') ||
        pid.contains('safari')) {
      return false;
    }
    if (pid.contains('brave') ||
        pid.contains('chromehtml') ||
        pid.contains('msedgehtm') ||
        pid.contains('vivaldi') ||
        pid.contains('opera') ||
        pid.contains('chromium') ||
        pid.contains('thorium') ||
        pid.contains('arc')) {
      return true;
    }
  }
  return false;
}

String _extractExecutableName(String path) {
  final normalized = path.trim().replaceAll('/', r'\');
  if (normalized.isEmpty) return '';
  final idx = normalized.lastIndexOf(r'\');
  return idx >= 0 ? normalized.substring(idx + 1) : normalized;
}

/// Parses stdout from Windows `reg query` for `REG_SZ` / `REG_EXPAND_SZ` values.
String? parseRegQueryOutput(String stdout, {String? expectedValueName}) {
  if (stdout.trim().isEmpty) return null;
  final expectedLower = expectedValueName?.trim().toLowerCase();
  final linePattern = RegExp(
    r'^\s+(.+?)\s+(REG_SZ|REG_EXPAND_SZ)\s+(.*)$',
    caseSensitive: false,
  );
  for (final line in const LineSplitter().convert(stdout)) {
    final match = linePattern.firstMatch(line);
    if (match == null) continue;
    final name = match.group(1)?.trim() ?? '';
    final data = match.group(3)?.trim() ?? '';
    if (expectedLower != null && name.toLowerCase() != expectedLower) {
      continue;
    }
    if (data.isEmpty ||
        data.toLowerCase() == '(value not set)' ||
        data == '(尚未設定數值)') {
      continue;
    }
    return data;
  }
  return null;
}

String? _defaultRegistryValueReader(String keyPath, String? valueName) {
  if (!Platform.isWindows) return null;
  try {
    final args = <String>[
      'query',
      keyPath,
      if (valueName != null && valueName.isNotEmpty) ...<String>[
        '/v',
        valueName,
      ] else
        '/ve',
    ];
    final result = Process.runSync('reg', args, runInShell: false);
    if (result.exitCode != 0) return null;
    return parseRegQueryOutput(
      result.stdout?.toString() ?? '',
      expectedValueName: valueName,
    );
  } catch (_) {
    return null;
  }
}

/// Queries the Windows Registry for the user's configured default HTTPS browser:
/// 1) `HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice` -> `ProgId`
/// 2) `HKCU\Software\Classes\<ProgId>\shell\open\command` -> `(Default)`
/// 3) Fallback `HKCR\<ProgId>\shell\open\command` -> `(Default)`
///
/// If a valid non-Chromium browser (e.g. Firefox, Zen) is configured, returns
/// `DetectedDefaultBrowser(..., isChromium: false)` and NEVER falls back to Edge/Chrome.
DetectedDefaultBrowser? detectWindowsDefaultBrowser({
  bool? isWindowsOverride,
  RegistryValueReader? registryReader,
  bool Function(String path)? fileExistsOverride,
  Map<String, String>? environmentOverride,
}) {
  final isWindows = isWindowsOverride ?? Platform.isWindows;
  if (!isWindows) {
    return null;
  }

  final readReg = registryReader ?? _defaultRegistryValueReader;
  final existsFn =
      fileExistsOverride ?? (String path) => File(path).existsSync();
  final env = environmentOverride ?? Platform.environment;

  final progId = readReg(
    r'HKCU\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice',
    'ProgId',
  )?.trim();
  if (progId == null || progId.isEmpty) {
    return null;
  }

  var rawCmd = readReg(
    'HKCU\\Software\\Classes\\$progId\\shell\\open\\command',
    null,
  );
  if (rawCmd == null || rawCmd.trim().isEmpty) {
    rawCmd = readReg('HKCR\\$progId\\shell\\open\\command', null);
  }
  if (rawCmd == null || rawCmd.trim().isEmpty) {
    return null;
  }

  final exePath = parseCommandExecutablePath(rawCmd, environmentOverride: env);
  if (exePath == null || exePath.isEmpty || !existsFn(exePath)) {
    return null;
  }

  final exeName = _extractExecutableName(exePath);
  final isChromium = isChromiumBrowserExecutable(exePath, progId: progId);
  return DetectedDefaultBrowser(
    progId: progId,
    executablePath: exePath,
    executableName: exeName,
    isChromium: isChromium,
    fromRegistry: true,
  );
}

/// Detects an installed local Chromium-based Windows browser in priority order:
/// Microsoft Edge -> Google Chrome -> Brave.
String? detectLocalBrowserPath({
  List<String>? candidatePathsOverride,
  Map<String, String>? environmentOverride,
  bool Function(String path)? fileExistsOverride,
  bool? isWindowsOverride,
}) {
  final existsFn = fileExistsOverride ?? (String path) => File(path).existsSync();

  if (candidatePathsOverride != null) {
    for (final raw in candidatePathsOverride) {
      final path = raw.trim();
      if (path.isNotEmpty && existsFn(path)) {
        return path;
      }
    }
    return null;
  }

  final isWindows = isWindowsOverride ?? Platform.isWindows;
  if (!isWindows) {
    return null;
  }

  final env = environmentOverride ?? Platform.environment;
  final candidates = buildLocalBrowserCandidatePaths(env);
  for (final path in candidates) {
    if (existsFn(path)) {
      return path;
    }
  }
  return null;
}

/// Builds the ordered Windows browser candidate executable paths across
/// `ProgramFiles(x86)`, `ProgramFiles`, and `LocalAppData`.
List<String> buildLocalBrowserCandidatePaths(Map<String, String> env) {
  final pf86 = _readEnvCaseInsensitive(env, 'ProgramFiles(x86)');
  final pf = _readEnvCaseInsensitive(env, 'ProgramFiles');
  final localAppData = _readEnvCaseInsensitive(env, 'LocalAppData');

  final seen = <String>{};
  final paths = <String>[];

  void addCandidate(String? root, String relativeExe) {
    if (root == null) return;
    final trimmed = root.trim();
    if (trimmed.isEmpty) return;
    final cleanRoot =
        trimmed.endsWith(r'\') || trimmed.endsWith('/')
            ? trimmed.substring(0, trimmed.length - 1)
            : trimmed;
    final full = '$cleanRoot\\$relativeExe';
    if (seen.add(full.toLowerCase())) {
      paths.add(full);
    }
  }

  // Priority 1: Microsoft Edge
  addCandidate(pf86, r'Microsoft\Edge\Application\msedge.exe');
  addCandidate(pf, r'Microsoft\Edge\Application\msedge.exe');
  addCandidate(localAppData, r'Microsoft\Edge\Application\msedge.exe');

  // Priority 2: Google Chrome
  addCandidate(pf, r'Google\Chrome\Application\chrome.exe');
  addCandidate(pf86, r'Google\Chrome\Application\chrome.exe');
  addCandidate(localAppData, r'Google\Chrome\Application\chrome.exe');

  // Priority 3: Brave
  addCandidate(pf, r'BraveSoftware\Brave-Browser\Application\brave.exe');
  addCandidate(pf86, r'BraveSoftware\Brave-Browser\Application\brave.exe');
  addCandidate(
    localAppData,
    r'BraveSoftware\Brave-Browser\Application\brave.exe',
  );

  return List<String>.unmodifiable(paths);
}

String? _readEnvCaseInsensitive(Map<String, String> env, String key) {
  final direct = env[key];
  if (direct != null && direct.trim().isNotEmpty) {
    return direct;
  }
  final target = key.toLowerCase();
  for (final entry in env.entries) {
    if (entry.key.toLowerCase() == target && entry.value.trim().isNotEmpty) {
      return entry.value;
    }
  }
  return null;
}

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

    final effectiveTaskkill = taskkillRunner ?? _defaultTaskkill;
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
      final args = buildLaunchArguments(
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
          final matchesHeaders =
              _matchesAnySubstring(reqUrl, session.request.headerUrlSubstrings);
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
    if (matchesUrlGuard(target.currentUrl, session.request)) {
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
        if (matchesUrlGuard(target.currentUrl, session.request)) {
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
    if (isGoogleBlockedUrl(url)) {
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
        if (isGoogleBlockedPageText(text)) {
          session.completeBlocked(
            capturedUrl: url,
            error: 'Google 安全性機制拒絕此除錯瀏覽器登入（此瀏覽器或應用程式可能不安全）',
          );
        }
      }
    }
  }

  static List<dynamic>? _extractCookieList(Map<String, dynamic>? resp) {
    if (resp == null) return null;
    if (resp['error'] != null) return null;
    final result = resp['result'];
    if (result is! Map) return null;
    final cookies = result['cookies'];
    return cookies is List ? cookies : null;
  }

  static bool _cookieDomainMatches(String domain, List<String> filters) {
    final rawLower = domain.trim().toLowerCase();
    final normDomain = rawLower.startsWith('.') ? rawLower.substring(1) : rawLower;
    if (normDomain.isEmpty) return false;
    for (final f in filters) {
      final fLower = f.trim().toLowerCase();
      if (fLower.isEmpty) continue;
      final normFilter = fLower.startsWith('.') ? fLower.substring(1) : fLower;
      if (normDomain == normFilter || normDomain.endsWith('.$normFilter')) {
        return true;
      }
    }
    return false;
  }

  Future<void> _pollCookiesForTarget(
    _BrowserAuthSession session,
    _CdpTargetSession target,
  ) async {
    // 1. Primary: Storage.getCookies (full-domain cookies including HttpOnly)
    var rawCookies = _extractCookieList(
      await target.sendCommandSafe(
        'Storage.getCookies',
        params: const <String, dynamic>{},
        timeout: const Duration(milliseconds: 900),
      ),
    );
    if (session.isDone || session.cleaningUp) return;

    // 2. Fallback: Network.getAllCookies
    if (rawCookies == null || rawCookies.isEmpty) {
      rawCookies = _extractCookieList(
        await target.sendCommandSafe(
          'Network.getAllCookies',
          params: const <String, dynamic>{},
          timeout: const Duration(milliseconds: 900),
        ),
      );
      if (session.isDone || session.cleaningUp) return;
    }

    // 3. Fallback: Network.getCookies scoped to targetDomain
    if (rawCookies == null || rawCookies.isEmpty) {
      final targetDomain =
          session.request.cookieDomain ?? session.request.initialUrl;
      rawCookies = _extractCookieList(
        await target.sendCommandSafe(
          'Network.getCookies',
          params: <String, dynamic>{
            'urls': <String>[targetDomain],
          },
          timeout: const Duration(milliseconds: 900),
        ),
      );
      if (session.isDone || session.cleaningUp) return;
    }

    if (rawCookies == null) return;

    final domainFilters = session.request.cookieDomainSubstrings;
    final nextCookies = <String, String>{};
    final cookieParts = <String>[];
    for (final item in rawCookies) {
      if (item is Map) {
        final name = item['name']?.toString().trim() ?? '';
        final value = item['value']?.toString() ?? '';
        if (name.isEmpty || value.isEmpty) continue;
        final domain = item['domain']?.toString().trim() ?? '';
        if (domain.isNotEmpty &&
            domainFilters.isNotEmpty &&
            !_cookieDomainMatches(domain, domainFilters)) {
          continue;
        }
        nextCookies[name] = value;
        cookieParts.add('$name=$value');
      }
    }
    if (nextCookies.isNotEmpty) {
      session.capturedCookies
        ..clear()
        ..addAll(nextCookies);
      session.cookieHeader = cookieParts.join('; ');
    }
  }

  static const String _webStorageExtractJs = '''
(function(){
  try {
    var out = {};
    function readStore(store, prefix) {
      if (!store) return;
      for (var i = 0; i < store.length; i++) {
        var k = store.key(i);
        if (!k) continue;
        var v = store.getItem(k);
        if (v !== null && v !== undefined) {
          var s = String(v);
          if (s.length > 0 && s.length <= 16384) {
            out[prefix + k] = s;
          }
        }
      }
    }
    readStore(window.localStorage, 'local:');
    readStore(window.sessionStorage, 'session:');
    return JSON.stringify(out);
  } catch (e) {
    return '{}';
  }
})()
''';

  Future<void> _pollWebStorageForTarget(
    _BrowserAuthSession session,
    _CdpTargetSession target,
  ) async {
    final resp = await target.sendCommandSafe(
      'Runtime.evaluate',
      params: <String, dynamic>{
        'expression': _webStorageExtractJs,
        'returnByValue': true,
      },
      timeout: const Duration(milliseconds: 900),
    );
    if (resp == null || session.isDone || session.cleaningUp) return;
    final result = resp['result'];
    if (result is! Map) return;
    final inner = result['result'];
    final rawVal = inner is Map ? inner['value']?.toString() : null;
    if (rawVal == null) return;
    final trimmed = rawVal.trim();
    if (!trimmed.startsWith('{')) return;

    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) return;
      for (final entry in decoded.entries) {
        var key = entry.key?.toString().trim() ?? '';
        final val = entry.value?.toString().trim() ?? '';
        if (key.isEmpty || val.isEmpty || val == 'null' || val == 'undefined') {
          continue;
        }
        if (key.startsWith('local:')) {
          key = key.substring(6);
        } else if (key.startsWith('session:')) {
          key = key.substring(8);
        }
        if (key.isEmpty) continue;
        if (val.startsWith('{')) {
          try {
            final nested = jsonDecode(val);
            if (nested is Map) {
              _extractAuthFieldsIntoMap(
                nested,
                session.capturedStorage,
                includeRawScalarKeys: false,
              );
              continue;
            }
          } catch (_) {}
        }
        _storeNormalizedAuthKeyValue(
          key,
          val,
          session.capturedStorage,
          includeRawScalarKey: true,
        );
      }
    } catch (_) {
      // Ignore malformed storage JSON.
    }
  }

  static void _extractAuthFieldsIntoMap(
    Map<dynamic, dynamic> node,
    Map<String, String> out, {
    required bool includeRawScalarKeys,
    int depth = 0,
  }) {
    if (depth > 5) return;
    for (final entry in node.entries) {
      final key = entry.key?.toString().trim() ?? '';
      final val = entry.value;
      if (key.isEmpty || val == null) continue;
      if (val is Map) {
        _extractAuthFieldsIntoMap(
          val,
          out,
          includeRawScalarKeys: false,
          depth: depth + 1,
        );
      } else if (val is String || val is num) {
        final strVal = val.toString().trim();
        if (strVal.isEmpty || strVal == 'null' || strVal == 'undefined') {
          continue;
        }
        _storeNormalizedAuthKeyValue(
          key,
          strVal,
          out,
          includeRawScalarKey: includeRawScalarKeys,
        );
      }
    }
  }

  static void _storeNormalizedAuthKeyValue(
    String rawKey,
    String val,
    Map<String, String> out, {
    required bool includeRawScalarKey,
  }) {
    final lower = rawKey.trim().toLowerCase();
    switch (lower) {
      case 'user_auth_token':
      case 'userauthtoken':
      case 'auth_token':
        out['user_auth_token'] = val;
        break;
      case 'app_id':
      case 'appid':
        out['app_id'] = val;
        break;
      case 'access_token':
      case 'oauthaccesstoken':
      case 'oauth_access_token':
      case 'tidal_access_token':
        out['access_token'] = val;
        break;
      case 'media-user-token':
      case 'media_user_token':
      case 'music-user-token':
      case 'music_user_token':
      case 'musicusertoken':
        out['media-user-token'] = val;
        out['music-user-token'] = val;
        break;
      case 'developer_token':
      case 'developertoken':
        out['developer_token'] = val;
        break;
      case 'authorization':
        out['authorization'] = val;
        break;
      case 'token':
        out['token'] = val;
        break;
      case 'arl':
        out['arl'] = val;
        break;
    }
    if (includeRawScalarKey) {
      out[rawKey] = val;
    }
  }

  void _captureHeadersFromMap(_BrowserAuthSession session, dynamic rawHeaders) {
    if (rawHeaders is! Map || session.request.captureHeaderNames.isEmpty) {
      return;
    }
    final wanted =
        session.request.captureHeaderNames.map((e) => e.toLowerCase()).toSet();
    for (final entry in rawHeaders.entries) {
      final k = entry.key?.toString().trim() ?? '';
      final v = entry.value?.toString().trim() ?? '';
      if (k.isEmpty || v.isEmpty) continue;
      final lower = k.toLowerCase();
      if (wanted.contains(lower)) {
        session.capturedHeaders[lower] = v;
      }
    }
  }

  void _captureQueryParamsFromUrl(_BrowserAuthSession session, String rawUrl) {
    if (session.request.captureQueryParams.isEmpty) return;
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || uri.queryParameters.isEmpty) return;
    final wanted =
        session.request.captureQueryParams.map((e) => e.toLowerCase()).toSet();
    for (final entry in uri.queryParameters.entries) {
      final k = entry.key.trim();
      final v = entry.value.trim();
      if (k.isEmpty || v.isEmpty) continue;
      final lower = k.toLowerCase();
      if (wanted.contains(lower)) {
        session.capturedQueryParams[lower] = v;
      }
    }
  }

  void _capturePostDataParams(_BrowserAuthSession session, dynamic rawPostData) {
    if (session.request.captureQueryParams.isEmpty) return;
    final postData = rawPostData?.toString().trim() ?? '';
    if (postData.isEmpty) return;
    final wanted =
        session.request.captureQueryParams.map((e) => e.toLowerCase()).toSet();
    if (postData.startsWith('{')) {
      try {
        final parsed = jsonDecode(postData);
        if (parsed is Map) {
          for (final entry in parsed.entries) {
            final k = entry.key?.toString().trim() ?? '';
            final v = entry.value?.toString().trim() ?? '';
            final lower = k.toLowerCase();
            if (k.isNotEmpty && v.isNotEmpty && wanted.contains(lower)) {
              session.capturedQueryParams[lower] = v;
            }
          }
        }
      } catch (_) {}
      return;
    }
    try {
      final parsedForm = Uri.splitQueryString(postData);
      for (final entry in parsedForm.entries) {
        final k = entry.key.trim();
        final v = entry.value.trim();
        final lower = k.toLowerCase();
        if (k.isNotEmpty && v.isNotEmpty && wanted.contains(lower)) {
          session.capturedQueryParams[lower] = v;
        }
      }
    } catch (_) {}
  }

  void _evaluateAllTargets(_BrowserAuthSession session) {
    if (session.isDone || session.cleaningUp) return;
    final satisfied = isCaptureSatisfied(
      request: session.request,
      cookies: session.capturedCookies,
      headers: session.capturedHeaders,
      queryParams: session.capturedQueryParams,
      responseValues: session.capturedResponseValues,
      storage: session.capturedStorage,
    );
    if (!satisfied) return;

    for (final target in session.attachedTargets.values) {
      final url = target.currentUrl;
      if (matchesUrlGuard(url, session.request)) {
        session.completeCaptured(url);
        return;
      }
    }

    // If a matched 200 API response (e.g. Qobuz /api.json/0.2/user/login)
    // already delivered complete tokens while the tab is still on the host
    // (before client-side redirect finishes), accept capture cleanly.
    if (session.capturedResponseValues.isNotEmpty) {
      final requiredHost =
          session.request.requiredHostSubstring?.trim().toLowerCase() ?? '';
      for (final target in session.attachedTargets.values) {
        final url = target.currentUrl.trim();
        if (url.isNotEmpty &&
            (requiredHost.isEmpty ||
                url.toLowerCase().contains(requiredHost))) {
          session.completeCaptured(url);
          return;
        }
      }
    }
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

  static bool _matchesAnySubstring(String url, List<String> needles) {
    if (needles.isEmpty) return false;
    final lower = url.toLowerCase();
    for (final needle in needles) {
      final n = needle.trim().toLowerCase();
      if (n.isNotEmpty && lower.contains(n)) {
        return true;
      }
    }
    return false;
  }

  static bool _hasCookie(Map<String, String> cookies, String name) {
    final direct = cookies[name];
    if (direct != null && direct.trim().isNotEmpty) return true;
    final lower = name.toLowerCase();
    for (final entry in cookies.entries) {
      if (entry.key.toLowerCase() == lower && entry.value.trim().isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  static bool _hasValue(Map<String, String> map, String lowerKey) {
    final direct = map[lowerKey];
    if (direct != null && direct.trim().isNotEmpty) return true;
    for (final entry in map.entries) {
      if (entry.key.toLowerCase() == lowerKey && entry.value.trim().isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  static Future<ProcessResult> _defaultTaskkill(int pid) {
    return Process.run('taskkill', <String>['/PID', '$pid', '/T', '/F']);
  }
}

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

class _NonChromiumAssistSession {
  final WebViewAuthRequest request;
  final DetectedDefaultBrowser detectedBrowser;
  final void Function(String message) logSink;

  final Completer<WebViewAuthResult> completer = Completer<WebViewAuthResult>();
  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;
  Timer? _timeoutTimer;

  _NonChromiumAssistSession({
    required this.request,
    required this.detectedBrowser,
    required this.logSink,
  });

  String get helperUrl {
    final srv = _server;
    if (srv == null) return '';
    return 'http://127.0.0.1:${srv.port}/';
  }

  Future<void> start() async {
    final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = srv;
    logSink(
      '[BrowserAuth] Started non-Chromium assisted loopback helper at http://127.0.0.1:${srv.port}/ '
      'for ${detectedBrowser.displayName}',
    );
    _subscription = srv.listen((req) async {
      await _handleHttpRequest(req);
    });
  }

  void startTimeoutTimer(Duration timeout) {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.complete(
          WebViewAuthResult(
            captured: false,
            cancelled: false,
            isNonChromiumDefault: true,
            detectedBrowserName: detectedBrowser.displayName,
            detectedBrowserPath: detectedBrowser.executablePath,
            error: '等待系統預設瀏覽器（${detectedBrowser.displayName}）輔助提交逾時',
          ),
        );
      }
    });
  }

  void requestCancel() {
    if (!completer.isCompleted) {
      completer.complete(
        WebViewAuthResult(
          captured: false,
          cancelled: true,
          isNonChromiumDefault: true,
          detectedBrowserName: detectedBrowser.displayName,
          detectedBrowserPath: detectedBrowser.executablePath,
        ),
      );
    }
  }

  Future<void> _handleHttpRequest(HttpRequest req) async {
    final path = req.uri.path;
    if (req.method == 'GET' && path == '/') {
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.contentType = ContentType.html;
      final safeTitle = const HtmlEscape().convert(request.title);
      final safeBrowser =
          const HtmlEscape().convert(detectedBrowser.displayName);
      req.response.write('''<!DOCTYPE html>
<html lang="zh-Hant">
<head><meta charset="utf-8"><title>Lumina Audio — $safeTitle</title></head>
<body style="font-family:sans-serif;background:#0b0f17;color:#f8fafc;padding:32px;">
  <h2>$safeTitle（$safeBrowser 輔助授權）</h2>
  <p>偵測到您的預設瀏覽器為 $safeBrowser（非 Chromium 核心），請貼上登入憑證送出：</p>
  <form method="POST" action="/submit">
    <input name="token" placeholder="Token / Cookie / ARL" style="width:360px;padding:8px;" />
    <input name="app_id" placeholder="App ID / Developer Token (選填)" style="width:240px;padding:8px;" />
    <button type="submit" style="padding:8px 16px;">完成登入</button>
  </form>
</body>
</html>''');
      await req.response.close();
      return;
    }

    if (req.method == 'POST' && path == '/submit') {
      final rawBody = await utf8.decoder.bind(req).join();
      final fields = <String, String>{};
      if (rawBody.trim().startsWith('{')) {
        try {
          final parsed = jsonDecode(rawBody);
          if (parsed is Map) {
            for (final e in parsed.entries) {
              final k = e.key?.toString().trim() ?? '';
              final v = e.value?.toString().trim() ?? '';
              if (k.isNotEmpty && v.isNotEmpty) fields[k] = v;
            }
          }
        } catch (_) {}
      } else {
        fields.addAll(Uri.splitQueryString(rawBody));
      }

      final token = (fields['token'] ??
              fields['cookie'] ??
              fields['arl'] ??
              fields['access_token'] ??
              fields['user_auth_token'] ??
              fields['music_user_token'] ??
              '')
          .trim();
      final appId = (fields['app_id'] ?? '').trim();
      final devToken = (fields['developer_token'] ?? '').trim();

      if (token.isEmpty) {
        req.response.statusCode = HttpStatus.badRequest;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'ok': false, 'error': 'Missing token'}));
        await req.response.close();
        return;
      }

      req.response.statusCode = HttpStatus.ok;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'ok': true}));
      await req.response.close();

      if (!completer.isCompleted) {
        final cookies = <String, String>{};
        final headers = <String, String>{};
        final queryParams = <String, String>{};
        var cookieHeader = '';
        switch (request.providerKind) {
          case 'youtube_music':
            cookieHeader = token;
            break;
          case 'deezer':
            cookies['arl'] = token;
            break;
          case 'tidal':
            headers['authorization'] =
                token.toLowerCase().startsWith('bearer ')
                    ? token
                    : 'Bearer $token';
            break;
          case 'qobuz':
            headers['x-user-auth-token'] = token;
            if (appId.isNotEmpty) queryParams['app_id'] = appId;
            break;
          case 'apple_music':
            headers['media-user-token'] = token;
            if (devToken.isNotEmpty) {
              headers['authorization'] =
                  devToken.toLowerCase().startsWith('bearer ')
                      ? devToken
                      : 'Bearer $devToken';
            }
            break;
        }
        logSink(
          '[BrowserAuth] Captured ${request.providerKind} assisted token '
          '(${maskSecretForLog(token)}) via ${detectedBrowser.displayName} loopback helper',
        );
        completer.complete(
          WebViewAuthResult(
            captured: true,
            cancelled: false,
            isNonChromiumDefault: true,
            detectedBrowserName: detectedBrowser.displayName,
            detectedBrowserPath: detectedBrowser.executablePath,
            cookieHeader: cookieHeader,
            cookies: Map<String, String>.unmodifiable(cookies),
            headers: Map<String, String>.unmodifiable(headers),
            queryParams: Map<String, String>.unmodifiable(queryParams),
            capturedUrl: request.initialUrl,
          ),
        );
      }
      return;
    }

    if ((req.method == 'POST' || req.method == 'GET') &&
        (path == '/close' || path == '/cancel')) {
      req.response.statusCode = HttpStatus.ok;
      await req.response.close();
      if (!completer.isCompleted) {
        completer.complete(
          WebViewAuthResult(
            captured: false,
            cancelled: false,
            isNonChromiumDefault: true,
            detectedBrowserName: detectedBrowser.displayName,
            detectedBrowserPath: detectedBrowser.executablePath,
            error:
                '已於 ${detectedBrowser.displayName} 開啟登入頁；請於下方貼上憑證完成驗證。',
          ),
        );
      }
      return;
    }

    req.response.statusCode = HttpStatus.notFound;
    await req.response.close();
  }

  Future<void> close() async {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    final sub = _subscription;
    final srv = _server;
    _subscription = null;
    _server = null;
    try {
      await srv?.close(force: true);
    } catch (_) {}
    try {
      await sub?.cancel();
    } catch (_) {}
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
