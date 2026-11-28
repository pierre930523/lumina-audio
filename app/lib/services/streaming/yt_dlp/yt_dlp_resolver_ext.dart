part of '../yt_dlp_service.dart';

extension _YtDlpResolverExt on YtDlpService {
  Future<YtDlpResolvedStream> _resolveVideoImpl(
    String videoId, {
    required int playRequestId,
    String? cookiesFilePath,
    bool bypassCache = false,
    String? formatSelector,
    String? extractorArgs,
    String? remoteComponents,
  }) async {
    final trimmedId = videoId.trim();
    if (trimmedId.isEmpty) {
      throw const YtDlpException('無效的 YouTube 影片 ID');
    }

    // Immediately terminate any stale foreground process belonging to another request.
    _killForegroundProcess(exceptRequestId: playRequestId);
    final myEpoch = ++_foregroundEpoch;
    _activeForegroundRequestId = playRequestId;

    if (bypassCache) {
      _streamCache.remove(trimmedId);
    } else {
      final cached = getCachedStream(trimmedId);
      if (cached != null) {
        await _waitIfNotYetAvailable(
          cached,
          myEpoch: myEpoch,
          requestId: playRequestId,
        );
        return cached;
      }
    }

    final ytDlpPath = await ensureAvailable();
    if (_disposed || myEpoch != _foregroundEpoch) {
      throw const YtDlpException('串流解析已取消', isCancelled: true);
    }

    final args = YtDlpService.buildResolveArgs(
      videoId: trimmedId,
      denoPath: _status.denoPath,
      ffmpegDir: _status.ffmpegDir,
      cookiesFilePath: cookiesFilePath,
      formatSelector: formatSelector,
      extractorArgs: extractorArgs,
      remoteComponents: remoteComponents,
    );

    final capture = await _runProcessCapture(
      executable: ytDlpPath,
      arguments: args,
      timeout: resolveTimeout,
      requestId: playRequestId,
      onHandleCreated: (handle) {
        if (_disposed || myEpoch != _foregroundEpoch) {
          handle.cancel();
          return;
        }
        _foregroundHandle?.cancel();
        _foregroundHandle = handle;
      },
      onHandleFinished: (handle) {
        if (identical(_foregroundHandle, handle)) {
          _foregroundHandle = null;
        }
      },
    );

    if (capture.cancelled || _disposed || myEpoch != _foregroundEpoch) {
      throw const YtDlpException('串流解析已取消', isCancelled: true);
    }

    if (capture.timedOut) {
      throw YtDlpException(
        'yt-dlp 串流解析逾時（超過 ${resolveTimeout.inSeconds} 秒）',
        isTimeout: true,
      );
    }

    if (capture.exitCode != 0) {
      final detail = _firstNonEmptyLine(capture.stderr) ?? '未知錯誤';
      throw YtDlpException(
        'yt-dlp 解析失敗（exit ${capture.exitCode}）：$detail',
        exitCode: capture.exitCode,
      );
    }

    final resolved = YtDlpService.parseResolvedStreamJson(
      videoId: trimmedId,
      rawStdout: capture.stdout,
      now: _clock(),
    );
    await _waitIfNotYetAvailable(
      resolved,
      myEpoch: myEpoch,
      requestId: playRequestId,
    );
    _storeCache(resolved);
    return resolved;
  }

  Future<void> _waitIfNotYetAvailable(
    YtDlpResolvedStream stream, {
    required int myEpoch,
    required int requestId,
  }) async {
    final availableAt = stream.availableAt;
    if (availableAt == null) return;
    final delay = availableAt.toUtc().difference(_clock().toUtc());
    if (delay <= Duration.zero) return;
    final clamped = delay > YtDlpService.maxAvailableAtWait
        ? YtDlpService.maxAvailableAtWait
        : delay;
    await _waitForAvailability(
      clamped,
      myEpoch: myEpoch,
      requestId: requestId,
    );
  }

  Future<void> _waitForAvailability(
    Duration delay, {
    required int myEpoch,
    required int requestId,
  }) async {
    if (delay <= Duration.zero) return;
    if (_disposed || myEpoch != _foregroundEpoch) {
      throw const YtDlpException('串流解析已取消', isCancelled: true);
    }

    final handle = _AvailabilityWaitHandle(requestId: requestId);
    _foregroundWaitHandle?.cancel();
    _foregroundWaitHandle = handle;

    final timerCompleter = Completer<void>();
    final timer = Timer(delay, () {
      if (!timerCompleter.isCompleted) {
        timerCompleter.complete();
      }
    });

    try {
      await Future.any<void>(<Future<void>>[
        timerCompleter.future,
        handle.abortFuture,
      ]);
    } finally {
      timer.cancel();
      if (identical(_foregroundWaitHandle, handle)) {
        _foregroundWaitHandle = null;
      }
    }

    if (handle.cancelled || _disposed || myEpoch != _foregroundEpoch) {
      throw const YtDlpException('串流解析已取消', isCancelled: true);
    }
  }

  Future<YtDlpResolvedStream?> _preloadVideoImpl(
    String videoId, {
    String? cookiesFilePath,
  }) async {
    final trimmedId = videoId.trim();
    if (trimmedId.isEmpty || _disposed) return null;

    final cached = getCachedStream(trimmedId);
    if (cached != null) return cached;

    if (_preloadingVideoId == trimmedId && _preloadFuture != null) {
      return _preloadFuture;
    }

    // Cancel any older preload process without touching foreground playback.
    _killPreloadProcess();
    final myPreloadEpoch = ++_preloadEpoch;
    _preloadingVideoId = trimmedId;

    final future = () async {
      try {
        if (!_initialized) {
          await initialize();
        }
        if (_disposed || myPreloadEpoch != _preloadEpoch) return null;
        final ytDlpPath = _status.ytDlpPath;
        if (ytDlpPath == null || !File(ytDlpPath).existsSync()) {
          return null;
        }

        final args = YtDlpService.buildResolveArgs(
          videoId: trimmedId,
          denoPath: _status.denoPath,
          ffmpegDir: _status.ffmpegDir,
          cookiesFilePath: cookiesFilePath,
        );

        final capture = await _runProcessCapture(
          executable: ytDlpPath,
          arguments: args,
          timeout: resolveTimeout,
          onHandleCreated: (handle) {
            if (_disposed || myPreloadEpoch != _preloadEpoch) {
              handle.cancel();
              return;
            }
            _preloadHandle?.cancel();
            _preloadHandle = handle;
          },
          onHandleFinished: (handle) {
            if (identical(_preloadHandle, handle)) {
              _preloadHandle = null;
            }
          },
        );

        if (_disposed ||
            myPreloadEpoch != _preloadEpoch ||
            capture.cancelled ||
            capture.timedOut ||
            capture.exitCode != 0) {
          return null;
        }

        final resolved = YtDlpService.parseResolvedStreamJson(
          videoId: trimmedId,
          rawStdout: capture.stdout,
          now: _clock(),
        );
        _storeCache(resolved);
        return resolved;
      } catch (e) {
        debugPrint('[YtDlpService] Preload skipped for $trimmedId: $e');
        return null;
      } finally {
        if (myPreloadEpoch == _preloadEpoch) {
          _preloadingVideoId = null;
          _preloadFuture = null;
        }
      }
    }();

    _preloadFuture = future;
    return future;
  }

  Future<void> _stopAllImpl({
    Duration waitTimeout = const Duration(seconds: 2),
  }) async {
    _killForegroundProcess();
    _killPreloadProcess();

    final ffmpegStop = _ffmpegProxy?.stopAll(waitTimeout: waitTimeout);

    final remaining = List<Process>.from(_runningProcesses);
    for (final proc in remaining) {
      try {
        proc.kill();
      } catch (_) {}
    }

    if (remaining.isNotEmpty) {
      try {
        await Future.wait(
          remaining.map((p) => p.exitCode.catchError((_) => -1)),
        ).timeout(waitTimeout);
      } on TimeoutException {
        // Best-effort wait; kill signals already dispatched.
      }
    }

    if (ffmpegStop != null) {
      await ffmpegStop;
    }
  }

  Future<_ProcessCapture> _runProcessCapture({
    required String executable,
    required List<String> arguments,
    required Duration timeout,
    int? requestId,
    void Function(_ManagedProcessHandle handle)? onHandleCreated,
    void Function(_ManagedProcessHandle handle)? onHandleFinished,
  }) async {
    final process = await _processStarter(
      executable,
      arguments,
      runInShell: false,
    );

    _runningProcesses.add(process);
    unawaited(
      process.exitCode.then(
        (_) => _runningProcesses.remove(process),
        onError: (_) => _runningProcesses.remove(process),
      ),
    );

    final handle = _ManagedProcessHandle(
      process,
      requestId: requestId,
      killProcessTreeOnWindows: _useSystemProcessStarter,
    );
    onHandleCreated?.call(handle);

    const maxStdoutBytes = 64 * 1024 * 1024;
    const maxStderrBytes = 64 * 1024;

    final stdoutBytes = <int>[];
    final stderrBytes = <int>[];
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();

    final stdoutSub = process.stdout.listen(
      (chunk) {
        if (stdoutBytes.length < maxStdoutBytes) {
          final room = maxStdoutBytes - stdoutBytes.length;
          stdoutBytes.addAll(
            chunk.length <= room ? chunk : chunk.sublist(0, room),
          );
        }
      },
      onDone: () {
        if (!stdoutDone.isCompleted) stdoutDone.complete();
      },
      onError: (_) {
        if (!stdoutDone.isCompleted) stdoutDone.complete();
      },
      cancelOnError: true,
    );

    final stderrSub = process.stderr.listen(
      (chunk) {
        if (stderrBytes.length < maxStderrBytes) {
          final room = maxStderrBytes - stderrBytes.length;
          stderrBytes.addAll(
            chunk.length <= room ? chunk : chunk.sublist(0, room),
          );
        }
      },
      onDone: () {
        if (!stderrDone.isCompleted) stderrDone.complete();
      },
      onError: (_) {
        if (!stderrDone.isCompleted) stderrDone.complete();
      },
      cancelOnError: true,
    );

    final timer = Timer(timeout, () {
      handle.markTimedOut();
    });

    try {
      if (handle.cancelled || handle.timedOut) {
        return _ProcessCapture(
          exitCode: -1,
          stdout: '',
          stderr: '',
          cancelled: handle.cancelled,
          timedOut: handle.timedOut,
        );
      }

      final exitCode = await Future.any<int>(<Future<int>>[
        process.exitCode.catchError((_) => -1),
        handle.abortFuture.then((_) => -1),
      ]);

      if (!handle.cancelled && !handle.timedOut) {
        try {
          await Future.wait(<Future<void>>[
            stdoutDone.future,
            stderrDone.future,
          ]).timeout(const Duration(seconds: 2));
        } on TimeoutException {
          // Proceed with collected output.
        }
      }

      return _ProcessCapture(
        exitCode: exitCode,
        stdout: utf8.decode(stdoutBytes, allowMalformed: true),
        stderr: utf8.decode(stderrBytes, allowMalformed: true),
        cancelled: handle.cancelled,
        timedOut: handle.timedOut,
      );
    } finally {
      timer.cancel();
      if (handle.cancelled || handle.timedOut) {
        unawaited(stdoutSub.cancel().catchError((_) {}));
        unawaited(stderrSub.cancel().catchError((_) {}));
      }
      onHandleFinished?.call(handle);
    }
  }
}
