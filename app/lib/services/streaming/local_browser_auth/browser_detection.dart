part of '../local_browser_auth_service.dart';

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

/// Queries the Windows Registry for the user's configured default HTTPS browser.
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
