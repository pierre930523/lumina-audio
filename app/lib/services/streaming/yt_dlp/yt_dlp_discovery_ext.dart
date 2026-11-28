part of '../yt_dlp_service.dart';

const String _fallbackLicenseSummary = '''
Lumina Audio — 第三方開源元件授權資訊

本應用程式於 Windows 發行版本中搭配以下開源命令列工具以提供串流解析與無損轉碼功能：

1. yt-dlp
   授權條款：The Unlicense（公眾領域）及 PyInstaller 內嵌第三方授權
   專案網址：https://github.com/yt-dlp/yt-dlp

2. Deno
   授權條款：MIT License
   專案網址：https://github.com/denoland/deno

3. FFmpeg (Windows x64 LGPL Build)
   授權條款：GNU Lesser General Public License (LGPL)
   專案網址：https://ffmpeg.org/

提示：尚未在本機安裝目錄找到完整的 THIRD_PARTY_LICENSES.txt。
於開發環境中可執行 scripts/prepare_release_deps.ps1 下載完整相依執行檔與授權全文。
''';

extension _YtDlpDiscoveryExt on YtDlpService {
  Future<YtDlpEnvironmentStatus> _refreshEnvironmentImpl() async {
    final ytDlpFuture = _locateAndProbeYtDlp();
    final denoFuture = _locateAndProbeAuxiliary(
      YtDlpService.denoBinaryName,
      versionArg: '--version',
      parser: YtDlpService.parseDenoVersionOutput,
    );
    final ffmpegFuture = _locateAndProbeAuxiliary(
      YtDlpService.ffmpegBinaryName,
      versionArg: '-version',
      parser: YtDlpService.parseFfmpegVersionOutput,
    );

    final ytDlpResult = await ytDlpFuture;
    final denoResult = await denoFuture;
    final ffmpegResult = await ffmpegFuture;

    final ffmpegPath = ffmpegResult.path;
    if (ffmpegPath != null && ffmpegPath.isNotEmpty) {
      debugPrint(
        '[YtDlpService] Located ffmpeg.exe: path=$ffmpegPath source=${ffmpegResult.source.name} version=${ffmpegResult.version ?? 'unknown'}',
      );
    } else {
      debugPrint(
        r'[YtDlpService] ffmpeg.exe not found (searched %LOCALAPPDATA%\LuminaAudio\bin, <exeDir>\bin, PATH)',
      );
    }
    final ffmpegDir = ffmpegPath != null ? File(ffmpegPath).parent.path : null;
    final licensePath = _resolveLicenseFilePath();

    _initialized = true;
    _status = _status.copyWith(
      ytDlpPath: ytDlpResult.path,
      clearYtDlpPath: ytDlpResult.path == null,
      ytDlpSource: ytDlpResult.source,
      ytDlpVersion: ytDlpResult.version,
      clearYtDlpVersion: ytDlpResult.version == null,
      denoPath: denoResult.path,
      clearDenoPath: denoResult.path == null,
      denoSource: denoResult.source,
      denoVersion: denoResult.version,
      clearDenoVersion: denoResult.version == null,
      ffmpegPath: ffmpegPath,
      clearFfmpegPath: ffmpegPath == null,
      ffmpegSource: ffmpegResult.source,
      ffmpegVersion: ffmpegResult.version,
      clearFfmpegVersion: ffmpegResult.version == null,
      ffmpegDir: ffmpegDir,
      clearFfmpegDir: ffmpegDir == null,
      licenseFilePath: licensePath,
      clearLicenseFilePath: licensePath == null,
    );

    _safeNotifyListeners();
    return _status;
  }

  Future<_DetectedBinary> _locateAndProbeYtDlp() async {
    final userPath = _joinPath(userBinDir, YtDlpService.ytDlpBinaryName);
    final bundledPath = _joinPath(bundledBinDir, YtDlpService.ytDlpBinaryName);

    final hasUser = File(userPath).existsSync();
    final hasBundled = File(bundledPath).existsSync();

    if (hasUser && hasBundled) {
      // Anti-regression comparison: probe BOTH in parallel and always pick the newer version.
      // When equal, prefer `bundled` so an upgraded installer isn't shadowed.
      final versions = await Future.wait<String?>(<Future<String?>>[
        _probeBinaryVersion(
          userPath,
          args: const <String>['--version'],
          parser: YtDlpService.parseYtDlpVersionOutput,
        ),
        _probeBinaryVersion(
          bundledPath,
          args: const <String>['--version'],
          parser: YtDlpService.parseYtDlpVersionOutput,
        ),
      ]);

      final userVersion = versions[0];
      final bundledVersion = versions[1];

      if (userVersion != null && bundledVersion != null) {
        if (YtDlpService.compareVersionStrings(userVersion, bundledVersion) > 0) {
          return _DetectedBinary(
            path: userPath,
            source: YtDlpBinarySource.userUpdated,
            version: userVersion,
          );
        }
        return _DetectedBinary(
          path: bundledPath,
          source: YtDlpBinarySource.bundled,
          version: bundledVersion,
        );
      }

      if (bundledVersion != null) {
        return _DetectedBinary(
          path: bundledPath,
          source: YtDlpBinarySource.bundled,
          version: bundledVersion,
        );
      }
      if (userVersion != null) {
        return _DetectedBinary(
          path: userPath,
          source: YtDlpBinarySource.userUpdated,
          version: userVersion,
        );
      }
      return _DetectedBinary(
        path: bundledPath,
        source: YtDlpBinarySource.bundled,
        version: null,
      );
    }

    if (hasUser) {
      final version = await _probeBinaryVersion(
        userPath,
        args: const <String>['--version'],
        parser: YtDlpService.parseYtDlpVersionOutput,
      );
      return _DetectedBinary(
        path: userPath,
        source: YtDlpBinarySource.userUpdated,
        version: version,
      );
    }

    if (hasBundled) {
      final version = await _probeBinaryVersion(
        bundledPath,
        args: const <String>['--version'],
        parser: YtDlpService.parseYtDlpVersionOutput,
      );
      return _DetectedBinary(
        path: bundledPath,
        source: YtDlpBinarySource.bundled,
        version: version,
      );
    }

    final sysPath = _findInSystemPath(YtDlpService.ytDlpBinaryName);
    if (sysPath != null) {
      final version = await _probeBinaryVersion(
        sysPath,
        args: const <String>['--version'],
        parser: YtDlpService.parseYtDlpVersionOutput,
      );
      return _DetectedBinary(
        path: sysPath,
        source: YtDlpBinarySource.systemPath,
        version: version,
      );
    }

    return const _DetectedBinary(
      path: null,
      source: YtDlpBinarySource.missing,
      version: null,
    );
  }

  Future<_DetectedBinary> _locateAndProbeAuxiliary(
    String binaryName, {
    required String versionArg,
    required String? Function(String) parser,
  }) async {
    final userPath = _joinPath(userBinDir, binaryName);
    if (File(userPath).existsSync()) {
      final version = await _probeBinaryVersion(
        userPath,
        args: <String>[versionArg],
        parser: parser,
      );
      return _DetectedBinary(
        path: userPath,
        source: YtDlpBinarySource.userUpdated,
        version: version,
      );
    }

    final bundledPath = _joinPath(bundledBinDir, binaryName);
    if (File(bundledPath).existsSync()) {
      final version = await _probeBinaryVersion(
        bundledPath,
        args: <String>[versionArg],
        parser: parser,
      );
      return _DetectedBinary(
        path: bundledPath,
        source: YtDlpBinarySource.bundled,
        version: version,
      );
    }

    final sysPath = _findInSystemPath(binaryName);
    if (sysPath != null) {
      final version = await _probeBinaryVersion(
        sysPath,
        args: <String>[versionArg],
        parser: parser,
      );
      return _DetectedBinary(
        path: sysPath,
        source: YtDlpBinarySource.systemPath,
        version: version,
      );
    }

    return const _DetectedBinary(
      path: null,
      source: YtDlpBinarySource.missing,
      version: null,
    );
  }

  String? _findInSystemPath(String binaryName) {
    final rawPath = _injectedPathEnv ?? Platform.environment['PATH'] ?? '';
    if (rawPath.trim().isEmpty) return null;

    final separator = Platform.isWindows ? ';' : ':';
    final seen = <String>{};
    for (final segment in rawPath.split(separator)) {
      var dir = segment.trim();
      if (dir.length >= 2 && dir.startsWith('"') && dir.endsWith('"')) {
        dir = dir.substring(1, dir.length - 1).trim();
      }
      if (dir.isEmpty) continue;
      final normalizedKey = Platform.isWindows ? dir.toLowerCase() : dir;
      if (!seen.add(normalizedKey)) continue;

      final candidate = _joinPath(dir, binaryName);
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  Future<String?> _probeBinaryVersion(
    String binaryPath, {
    required List<String> args,
    required String? Function(String) parser,
    Duration? timeout,
  }) async {
    try {
      final capture = await _runProcessCapture(
        executable: binaryPath,
        arguments: args,
        timeout: timeout ?? versionProbeTimeout,
      );
      if (capture.timedOut || capture.cancelled || capture.exitCode != 0) {
        return null;
      }
      final parsed = parser(capture.stdout);
      if (parsed != null && parsed.isNotEmpty) {
        _cachedVersions[binaryPath] = parsed;
      }
      return parsed;
    } catch (e) {
      debugPrint('[YtDlpService] Version probe failed for $binaryPath: $e');
      return null;
    }
  }

  String? _tryLocateBinariesFastSync() {
    final userYtDlp = _joinPath(userBinDir, YtDlpService.ytDlpBinaryName);
    final bundledYtDlp = _joinPath(bundledBinDir, YtDlpService.ytDlpBinaryName);
    final hasUser = File(userYtDlp).existsSync();
    final hasBundled = File(bundledYtDlp).existsSync();

    // When both user and bundled copies exist, fall back to full initialize()
    // so version-based anti-regression comparison picks the newer binary.
    if (hasUser && hasBundled) {
      return null;
    }

    String? ytDlpPath;
    YtDlpBinarySource ytDlpSource = YtDlpBinarySource.missing;
    if (hasUser) {
      ytDlpPath = userYtDlp;
      ytDlpSource = YtDlpBinarySource.userUpdated;
    } else if (hasBundled) {
      ytDlpPath = bundledYtDlp;
      ytDlpSource = YtDlpBinarySource.bundled;
    } else {
      final sysYtDlp = _findInSystemPath(YtDlpService.ytDlpBinaryName);
      if (sysYtDlp != null) {
        ytDlpPath = sysYtDlp;
        ytDlpSource = YtDlpBinarySource.systemPath;
      }
    }

    if (ytDlpPath == null) {
      return null;
    }

    ({String? path, YtDlpBinarySource source}) locateAuxSync(String name) {
      final userPath = _joinPath(userBinDir, name);
      if (File(userPath).existsSync()) {
        return (path: userPath, source: YtDlpBinarySource.userUpdated);
      }
      final bundledPath = _joinPath(bundledBinDir, name);
      if (File(bundledPath).existsSync()) {
        return (path: bundledPath, source: YtDlpBinarySource.bundled);
      }
      final sysPath = _findInSystemPath(name);
      if (sysPath != null) {
        return (path: sysPath, source: YtDlpBinarySource.systemPath);
      }
      return (path: null, source: YtDlpBinarySource.missing);
    }

    final deno = locateAuxSync(YtDlpService.denoBinaryName);
    final ffmpeg = locateAuxSync(YtDlpService.ffmpegBinaryName);
    final ffmpegDir = ffmpeg.path != null ? File(ffmpeg.path!).parent.path : null;
    final licensePath = _resolveLicenseFilePath();

    _status = _status.copyWith(
      ytDlpPath: ytDlpPath,
      ytDlpSource: ytDlpSource,
      denoPath: deno.path,
      clearDenoPath: deno.path == null,
      denoSource: deno.source,
      ffmpegPath: ffmpeg.path,
      clearFfmpegPath: ffmpeg.path == null,
      ffmpegSource: ffmpeg.source,
      ffmpegDir: ffmpegDir,
      clearFfmpegDir: ffmpegDir == null,
      licenseFilePath: licensePath,
      clearLicenseFilePath: licensePath == null,
    );
    _safeNotifyListeners();
    return ytDlpPath;
  }

  Future<String> _ensureAvailableImpl() async {
    final existing = _status.ytDlpPath;
    if (existing != null && File(existing).existsSync()) {
      return existing;
    }
    if (!_initialized) {
      final fastPath = _tryLocateBinariesFastSync();
      if (fastPath != null) {
        return fastPath;
      }
      await initialize();
    }
    final afterInit = _status.ytDlpPath;
    if (afterInit != null && File(afterInit).existsSync()) {
      return afterInit;
    }

    final inFlight = _ensureAvailableFuture;
    if (inFlight != null) return inFlight;

    final future = () async {
      final updateResult = await checkAndUpdateYtDlp();
      final resolved = _status.ytDlpPath;
      if (resolved != null && File(resolved).existsSync()) {
        return resolved;
      }
      throw YtDlpException(
        '無法自動取得 yt-dlp：${updateResult.message}',
      );
    }();

    _ensureAvailableFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_ensureAvailableFuture, future)) {
        _ensureAvailableFuture = null;
      }
    }
  }

  String? _resolveLicenseFilePath() {
    final candidates = <String>[
      if (_injectedLicenseFilePath != null &&
          _injectedLicenseFilePath.trim().isNotEmpty)
        _injectedLicenseFilePath.trim(),
      _joinPath(
        File(Platform.resolvedExecutable).parent.path,
        YtDlpService.licenseFileName,
      ),
      if (_injectedBundledBinDir != null &&
          _injectedBundledBinDir.trim().isNotEmpty) ...<String>[
        _joinPath(
          Directory(_injectedBundledBinDir.trim()).parent.path,
          YtDlpService.licenseFileName,
        ),
        _joinPath(_injectedBundledBinDir.trim(), YtDlpService.licenseFileName),
      ],
    ];

    final cwd = Directory.current.path;
    candidates.addAll(<String>[
      _joinPath(
        cwd,
        'windows${Platform.pathSeparator}vendor${Platform.pathSeparator}bin${Platform.pathSeparator}${YtDlpService.licenseFileName}',
      ),
      _joinPath(
        cwd,
        'app${Platform.pathSeparator}windows${Platform.pathSeparator}vendor${Platform.pathSeparator}bin${Platform.pathSeparator}${YtDlpService.licenseFileName}',
      ),
    ]);

    for (final candidate in candidates) {
      try {
        if (File(candidate).existsSync()) {
          return candidate;
        }
      } catch (_) {}
    }
    return null;
  }

  String _resolveUserBinDir() {
    if (_injectedUserBinDir != null && _injectedUserBinDir.trim().isNotEmpty) {
      return _injectedUserBinDir.trim();
    }
    final localAppData = Platform.environment['LOCALAPPDATA']?.trim();
    if (localAppData != null && localAppData.isNotEmpty) {
      return _joinPath(_joinPath(localAppData, 'LuminaAudio'), 'bin');
    }
    final userProfile = Platform.environment['USERPROFILE']?.trim();
    if (userProfile != null && userProfile.isNotEmpty) {
      return _joinPath(
        _joinPath(
          _joinPath(_joinPath(userProfile, 'AppData'), 'Local'),
          'LuminaAudio',
        ),
        'bin',
      );
    }
    return _joinPath(Directory.systemTemp.path, 'LuminaAudio_bin');
  }

  String _resolveBundledBinDir() {
    if (_injectedBundledBinDir != null &&
        _injectedBundledBinDir.trim().isNotEmpty) {
      return _injectedBundledBinDir.trim();
    }
    // Always anchored to Platform.resolvedExecutable — NEVER CWD.
    var dir = File(Platform.resolvedExecutable).parent;
    final exeBin = _joinPath(dir.path, 'bin');
    if (File(_joinPath(exeBin, YtDlpService.ytDlpBinaryName)).existsSync() ||
        File(_joinPath(exeBin, YtDlpService.ffmpegBinaryName)).existsSync()) {
      return exeBin;
    }
    for (var i = 0; i < 6; i++) {
      final vendorBin = _joinPath(
        dir.path,
        'windows${Platform.pathSeparator}vendor${Platform.pathSeparator}bin',
      );
      if (File(_joinPath(vendorBin, YtDlpService.ytDlpBinaryName))
              .existsSync() ||
          File(_joinPath(vendorBin, YtDlpService.ffmpegBinaryName))
              .existsSync()) {
        return vendorBin;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return exeBin;
  }
}
