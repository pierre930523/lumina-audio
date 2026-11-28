part of '../yt_dlp_service.dart';

extension _YtDlpUpdaterExt on YtDlpService {
  Future<YtDlpUpdateResult> _performCheckAndUpdate() async {
    if (!_initialized) {
      await initialize();
    }

    final previousVersion = _status.ytDlpVersion;
    _setUpdateState(
      isUpdating: true,
      message: '正在檢查 yt-dlp 最新版本...',
    );

    final client = _httpClientFactory();
    client.connectionTimeout = const Duration(seconds: 15);
    final tmpPath = _joinPath(userBinDir, '${YtDlpService.ytDlpBinaryName}.tmp');

    try {
      final release = await _fetchLatestReleaseInfo(client);
      final latestTag = release.tagName;

      if (_status.isYtDlpAvailable &&
          previousVersion != null &&
          previousVersion.isNotEmpty &&
          YtDlpService.compareVersionStrings(latestTag, previousVersion) <= 0) {
        final msg = '已是最新版本 ($previousVersion)';
        _setUpdateState(isUpdating: false, message: msg);
        return YtDlpUpdateResult.upToDate(
          currentVersion: previousVersion,
          latestVersion: latestTag,
          message: msg,
        );
      }

      _setUpdateState(
        isUpdating: true,
        message: '正在下載 yt-dlp $latestTag...',
      );

      final targetDir = Directory(userBinDir);
      if (!targetDir.existsSync()) {
        await targetDir.create(recursive: true);
      }

      // Remove any leftover stale temp file before downloading.
      await _safeDeleteFile(tmpPath);

      // Stream download to yt-dlp.exe.tmp.
      await _downloadFile(
        client,
        release.binaryDownloadUrl,
        tmpPath,
      );

      final tmpFile = File(tmpPath);
      if (!tmpFile.existsSync() || await tmpFile.length() <= 0) {
        throw const YtDlpException('下載的 yt-dlp.exe 檔案為空');
      }

      // Verify SHA256 if SHA2-256SUMS or asset digest is provided.
      String? expectedSha256;
      if (release.sha256SumsUrl != null) {
        _setUpdateState(
          isUpdating: true,
          message: '正在驗證 SHA256 校驗碼...',
        );
        final sumsBody = await _fetchText(client, release.sha256SumsUrl!);
        expectedSha256 = YtDlpService.parseSha256ForAsset(
          sumsBody,
          YtDlpService.ytDlpBinaryName,
        );
      }
      expectedSha256 ??= release.assetSha256Digest;

      if (expectedSha256 != null) {
        final actualDigest = await sha256.bind(tmpFile.openRead()).first;
        final actualHex = actualDigest.toString().toLowerCase();
        if (actualHex != expectedSha256.toLowerCase()) {
          throw YtDlpException(
            'SHA256 校驗失敗（預期 ${expectedSha256.substring(0, 12)}...，實際 ${actualHex.substring(0, 12)}...）',
          );
        }
      }

      // Verify downloaded executable runs `--version` cleanly before activating.
      _setUpdateState(
        isUpdating: true,
        message: '正在驗證下載檔案可執行性...',
      );
      final verifyCapture = await _runProcessCapture(
        executable: tmpPath,
        arguments: const <String>['--version'],
        timeout: updateVerifyTimeout,
      );
      final verifiedVersion = YtDlpService.parseYtDlpVersionOutput(
        verifyCapture.stdout,
      );
      if (verifyCapture.timedOut ||
          verifyCapture.cancelled ||
          verifyCapture.exitCode != 0 ||
          verifiedVersion == null ||
          verifiedVersion.isEmpty) {
        throw YtDlpException(
          '下載的 yt-dlp.exe 驗證執行失敗（exit ${verifyCapture.exitCode}）',
          exitCode: verifyCapture.exitCode,
        );
      }

      // Atomically swap yt-dlp.exe.tmp -> yt-dlp.exe inside userBinDir with rollback.
      final targetPath = _joinPath(userBinDir, YtDlpService.ytDlpBinaryName);
      await _atomicReplaceWindowsSafe(tmpPath: tmpPath, targetPath: targetPath);
      _cachedVersions.remove(targetPath);

      await refreshEnvironment();
      final activatedVersion = _status.ytDlpVersion ?? verifiedVersion;
      final successMsg = '已更新至 yt-dlp $activatedVersion';
      _setUpdateState(isUpdating: false, message: successMsg);
      return YtDlpUpdateResult.updated(
        previousVersion: previousVersion,
        newVersion: activatedVersion,
        message: successMsg,
      );
    } catch (e) {
      await _safeDeleteFile(tmpPath);
      final reason = e is YtDlpException ? e.message : '$e';
      final failMsg = '更新失敗：$reason';
      _setUpdateState(isUpdating: false, message: failMsg);
      return YtDlpUpdateResult.failed(
        currentVersion: previousVersion,
        message: failMsg,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<_ReleaseInfo> _fetchLatestReleaseInfo(HttpClient client) async {
    final text = await _fetchText(
      client,
      _latestReleaseApiUri,
      accept: 'application/vnd.github+json',
    );
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const YtDlpException('GitHub Release 回應格式不正確');
    }

    final tagName = (decoded['tag_name'] as String?)?.trim() ?? '';
    if (tagName.isEmpty) {
      throw const YtDlpException('GitHub Release 缺少 tag_name 欄位');
    }

    final assets = decoded['assets'];
    if (assets is! List) {
      throw const YtDlpException('GitHub Release 缺少 assets 清單');
    }

    Uri? binaryUrl;
    String? assetDigest;
    Uri? sumsUrl;

    for (final item in assets) {
      if (item is! Map) continue;
      final name = (item['name'] as String?)?.trim();
      final downloadRaw = (item['browser_download_url'] as String?)?.trim();
      if (name == null || downloadRaw == null || downloadRaw.isEmpty) continue;
      final uri = Uri.tryParse(downloadRaw);
      if (uri == null) continue;

      if (name == YtDlpService.ytDlpBinaryName) {
        binaryUrl = uri;
        final rawDigest = (item['digest'] as String?)?.trim();
        if (rawDigest != null && rawDigest.toLowerCase().startsWith('sha256:')) {
          final hex = rawDigest.substring('sha256:'.length).trim();
          if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hex)) {
            assetDigest = hex.toLowerCase();
          }
        }
      } else if (name == 'SHA2-256SUMS') {
        sumsUrl = uri;
      }
    }

    if (binaryUrl == null) {
      throw const YtDlpException('最新 Release 中找不到 yt-dlp.exe 檔案');
    }

    return _ReleaseInfo(
      tagName: tagName,
      binaryDownloadUrl: binaryUrl,
      sha256SumsUrl: sumsUrl,
      assetSha256Digest: assetDigest,
    );
  }

  Future<String> _fetchText(
    HttpClient client,
    Uri uri, {
    String accept = '*/*',
  }) async {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 20));
    request.headers.set(HttpHeaders.userAgentHeader, 'LuminaAudio');
    request.headers.set(HttpHeaders.acceptHeader, accept);
    final response = await request.close().timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>().catchError((_) {});
      throw YtDlpException(
        'HTTP ${response.statusCode} 讀取失敗（${uri.host}）',
      );
    }
    return utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 20));
  }

  Future<void> _downloadFile(
    HttpClient client,
    Uri uri,
    String destinationPath,
  ) async {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 20));
    request.headers.set(HttpHeaders.userAgentHeader, 'LuminaAudio');
    request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.drain<void>().catchError((_) {});
      throw YtDlpException('下載 yt-dlp.exe 失敗（HTTP ${response.statusCode}）');
    }

    final sink = File(destinationPath).openWrite();
    try {
      await response.pipe(sink).timeout(const Duration(seconds: 120));
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _atomicReplaceWindowsSafe({
    required String tmpPath,
    required String targetPath,
  }) async {
    final bakPath = '$targetPath.bak';
    await _safeDeleteFile(bakPath);

    final targetFile = File(targetPath);
    final tmpFile = File(tmpPath);
    var movedToBackup = false;

    if (targetFile.existsSync()) {
      await targetFile.rename(bakPath);
      movedToBackup = true;
    }

    try {
      await tmpFile.rename(targetPath);
    } catch (_) {
      if (movedToBackup &&
          File(bakPath).existsSync() &&
          !File(targetPath).existsSync()) {
        try {
          await File(bakPath).rename(targetPath);
        } catch (rollbackErr) {
          debugPrint('[YtDlpService] Rollback rename failed: $rollbackErr');
        }
      }
      rethrow;
    }

    await _safeDeleteFile(bakPath);
  }

  Future<void> _safeDeleteFile(String path) async {
    try {
      final file = File(path);
      if (file.existsSync()) {
        await file.delete();
      }
    } catch (_) {}
  }

  void _setUpdateState({required bool isUpdating, String? message}) {
    _status = _status.copyWith(
      isUpdating: isUpdating,
      lastUpdateMessage: message,
      clearLastUpdateMessage: message == null,
    );
    _safeNotifyListeners();
  }
}
