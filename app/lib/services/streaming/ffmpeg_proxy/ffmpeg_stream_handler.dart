part of '../ffmpeg_audio_proxy.dart';

extension _FfmpegStreamHandler on FfmpegAudioProxy {
  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    try {
      await request.drain<void>().catchError((_) {});
      final path = request.uri.path;
      final target = _extractStreamTargetFromPath(path);
      final session = _activeSession;

      if (target == null ||
          session == null ||
          session.token != target.token ||
          session.outputExtension != target.extension) {
        response.statusCode = HttpStatus.notFound;
        response.contentLength = 0;
        await response.close();
        return;
      }

      if (request.method == 'HEAD') {
        // Respond cleanly without spawning ffmpeg.exe.
        response.statusCode = HttpStatus.ok;
        response.contentLength = 0;
        response.headers.set(HttpHeaders.contentTypeHeader, session.contentType);
        response.headers.set('Accept-Ranges', 'none');
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        await response.close();
        return;
      }

      if (request.method != 'GET') {
        response.statusCode = HttpStatus.methodNotAllowed;
        response.contentLength = 0;
        response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        await response.close();
        return;
      }

      await _handleGetStream(session, response);
    } catch (e) {
      debugPrint('[FfmpegAudioProxy] Request error: $e');
      try {
        await response.close();
      } catch (_) {}
    }
  }

  ({String token, String extension})? _extractStreamTargetFromPath(String path) {
    const prefix = '/stream/';
    if (!path.startsWith(prefix)) return null;
    final rest = path.substring(prefix.length);
    if (rest.isEmpty || rest.contains('/')) return null;

    final String ext;
    if (rest.endsWith('.wav')) {
      ext = 'wav';
    } else if (rest.endsWith('.flac')) {
      ext = 'flac';
    } else {
      return null;
    }

    final token = rest.substring(0, rest.length - ext.length - 1);
    if (token.isEmpty) return null;
    return (token: token, extension: ext);
  }

  Future<void> _handleGetStream(
    _ProxySession session,
    HttpResponse response,
  ) async {
    final ffmpegPath = _ffmpegPathProvider();
    if (_disposed || ffmpegPath == null || ffmpegPath.trim().isEmpty) {
      _safeDeleteFile(session.tempFilePath);
      response.statusCode = HttpStatus.serviceUnavailable;
      response.contentLength = 0;
      await response.close();
      return;
    }

    // Ensure no older ffmpeg stream remains running.
    _activeStream?.abort();
    _activeStream = null;

    final args = session.isDashMpd
        ? FfmpegAudioProxy.buildDashMpdFfmpegArgs(
            mpdFilePath: session.sourceUrl,
            copyFlac: session.copyFlac,
          )
        : FfmpegAudioProxy.buildFfmpegArgs(
            sourceUrl: session.sourceUrl,
            headers: session.headers,
          );

    if (session.isDashMpd) {
      debugPrint(
        '[FfmpegAudioProxy] Spawning ffmpeg for DASH (${session.copyFlac ? 'FLAC copy' : 'PCM WAV'}): $ffmpegPath',
      );
    }

    final Process process;
    try {
      process = await _processStarter(
        ffmpegPath,
        args,
        runInShell: false,
      );
    } catch (e) {
      debugPrint('[FfmpegAudioProxy] Failed to spawn ffmpeg: $e');
      _safeDeleteFile(session.tempFilePath);
      response.statusCode = HttpStatus.internalServerError;
      response.contentLength = 0;
      await response.close();
      return;
    }

    _spawnCount++;
    _runningProcesses.add(process);
    _runningProcessRequestIds[process] = session.playRequestId;
    void onProcessExit() {
      _runningProcesses.remove(process);
      _runningProcessRequestIds.remove(process);
      if (_activeStream?.token != session.token ||
          identical(_activeStream?.process, process)) {
        _safeDeleteFile(session.tempFilePath);
      }
    }

    unawaited(
      process.exitCode.then(
        (_) => onProcessExit(),
        onError: (_) => onProcessExit(),
      ),
    );

    // Guard against cancellation/session replacement while Process.start was awaiting.
    if (_disposed || !identical(_activeSession, session)) {
      FfmpegAudioProxy._safeKill(process);
      _safeDeleteFile(session.tempFilePath);
      response.statusCode = HttpStatus.gone;
      response.contentLength = 0;
      try {
        await response.close();
      } catch (_) {}
      return;
    }

    final active = _ActiveFfmpegStream(
      process: process,
      playRequestId: session.playRequestId,
      token: session.token,
    );
    _activeStream = active;

    // Always drain stderr so the child process can never block on a full pipe.
    final stderrChunks = <int>[];
    final stderrDone = Completer<void>();
    final stderrSub = process.stderr.listen(
      (chunk) {
        if (stderrChunks.length < 4096) {
          final remaining = 4096 - stderrChunks.length;
          stderrChunks.addAll(
            chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
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

    StreamSubscription<List<int>>? stdoutSub;
    var headersSent = false;
    var loggedStderr = false;
    try {
      // Abort immediately if the client disconnects (either cleanly or with error).
      unawaited(
        response.done.then(
          (_) => active.abort(),
          onError: (_) => active.abort(),
        ),
      );

      final firstChunkCompleter = Completer<List<int>?>();
      Future<void> pendingWrite = Future<void>.value();
      stdoutSub = process.stdout.listen(
        (chunk) {
          if (active.aborted || chunk.isEmpty) return;
          if (!firstChunkCompleter.isCompleted) {
            stdoutSub?.pause();
            firstChunkCompleter.complete(chunk);
            return;
          }
          stdoutSub?.pause();
          pendingWrite = pendingWrite.then((_) async {
            if (active.aborted) return;
            try {
              response.add(chunk);
              await response.flush();
            } catch (_) {
              active.abort();
            } finally {
              if (!active.aborted) {
                stdoutSub?.resume();
              }
            }
          });
        },
        onDone: () {
          if (!firstChunkCompleter.isCompleted) {
            firstChunkCompleter.complete(null);
          }
          unawaited(
            pendingWrite.whenComplete(active.markDone),
          );
        },
        onError: (_) {
          if (!firstChunkCompleter.isCompleted) {
            firstChunkCompleter.complete(null);
          }
          active.abort();
        },
        cancelOnError: true,
      );

      active.attachStdoutSubscription(stdoutSub);

      final firstChunk = await Future.any<List<int>?>(<Future<List<int>?>>[
        firstChunkCompleter.future,
        active.done.then<List<int>?>((_) => null),
      ]).timeout(const Duration(seconds: 20), onTimeout: () => null);

      if (firstChunk == null || firstChunk.isEmpty || active.aborted) {
        active.abort();
        FfmpegAudioProxy._safeKill(process);
        await stderrDone.future.timeout(
          const Duration(milliseconds: 200),
          onTimeout: () {},
        );
        final errText = utf8.decode(stderrChunks, allowMalformed: true).trim();
        final int statusCode;
        if (_disposed || !identical(_activeSession, session)) {
          statusCode = HttpStatus.gone;
        } else if (_looksLikeHttp403(errText)) {
          statusCode = HttpStatus.forbidden;
        } else {
          statusCode = HttpStatus.badGateway;
        }
        headersSent = true;
        final redactedErr = _redactStderr(errText);
        debugPrint(
          '[FfmpegAudioProxy] Non-200 ($statusCode) ffmpeg stderr: '
          '${redactedErr.isEmpty ? '<empty>' : redactedErr}',
        );
        loggedStderr = true;
        final bodyBytes = errText.isEmpty ? const <int>[] : utf8.encode(errText);
        response.statusCode = statusCode;
        response.contentLength = bodyBytes.length;
        response.headers.set(
          HttpHeaders.contentTypeHeader,
          'text/plain; charset=utf-8',
        );
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        if (bodyBytes.isNotEmpty) {
          response.add(bodyBytes);
        }
        await response.flush();
        await response.close();
        return;
      }

      // Ignore any incoming Range header (e.g. `Range: bytes=0-0` from Rust probe)
      // and return 200 OK only once FFmpeg emits audio bytes so upstream errors
      // are never masked as empty 200 OK responses.
      headersSent = true;
      response.statusCode = HttpStatus.ok;
      response.headers.set(HttpHeaders.contentTypeHeader, session.contentType);
      response.headers.set('Accept-Ranges', 'none');
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.bufferOutput = false;
      response.add(firstChunk);
      await response.flush();

      if (!active.aborted) {
        stdoutSub.resume();
        await active.done;
      }
    } catch (_) {
      active.abort();
      if (!headersSent) {
        try {
          response.statusCode = HttpStatus.badGateway;
          response.contentLength = 0;
        } catch (_) {}
      }
    } finally {
      active.abort();
      unawaited(stdoutSub?.cancel().catchError((_) {}));
      unawaited(stderrSub.cancel().catchError((_) {}));
      FfmpegAudioProxy._safeKill(process);
      if (identical(_activeStream, active)) {
        _activeStream = null;
      }
      if (_activeStream?.token != session.token) {
        _safeDeleteFile(session.tempFilePath);
      }
      try {
        await response.close();
      } catch (_) {}

      if (!loggedStderr && stderrChunks.isNotEmpty) {
        final errText = utf8.decode(stderrChunks, allowMalformed: true).trim();
        if (errText.isNotEmpty) {
          debugPrint(
            '[FfmpegAudioProxy] ffmpeg stderr: ${_redactStderr(errText)}',
          );
        }
      }
    }
  }

  static String _redactStderr(String errText) =>
      errText.replaceAll(RegExp(r'\?[^\s\x27"]+'), '?[REDACTED]');

  static bool _looksLikeHttp403(String stderrText) {
    return RegExp(
      r'HTTP\s*(?:error\s*)?403\b|returned\s*403\b|status(?:\s*code)?\s*[:=]?\s*403\b|\b403\s+Forbidden\b',
      caseSensitive: false,
    ).hasMatch(stderrText);
  }
}
