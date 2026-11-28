part of '../yt_dlp_service.dart';

class _DetectedBinary {
  final String? path;
  final YtDlpBinarySource source;
  final String? version;

  const _DetectedBinary({
    required this.path,
    required this.source,
    required this.version,
  });
}

class _ReleaseInfo {
  final String tagName;
  final Uri binaryDownloadUrl;
  final Uri? sha256SumsUrl;
  final String? assetSha256Digest;

  const _ReleaseInfo({
    required this.tagName,
    required this.binaryDownloadUrl,
    this.sha256SumsUrl,
    this.assetSha256Digest,
  });
}

class _ProcessCapture {
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool cancelled;
  final bool timedOut;

  const _ProcessCapture({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.cancelled,
    required this.timedOut,
  });
}

class _ManagedProcessHandle {
  final Process process;
  final int? requestId;
  final bool killProcessTreeOnWindows;
  final Completer<void> _abortCompleter = Completer<void>();

  bool _cancelled = false;
  bool _timedOut = false;

  _ManagedProcessHandle(
    this.process, {
    this.requestId,
    this.killProcessTreeOnWindows = false,
  });

  bool get cancelled => _cancelled;
  bool get timedOut => _timedOut;
  Future<void> get abortFuture => _abortCompleter.future;

  void cancel() {
    if (_cancelled || _timedOut) return;
    _cancelled = true;
    _kill();
    if (!_abortCompleter.isCompleted) {
      _abortCompleter.complete();
    }
  }

  void markTimedOut() {
    if (_cancelled || _timedOut) return;
    _timedOut = true;
    _kill();
    if (!_abortCompleter.isCompleted) {
      _abortCompleter.complete();
    }
  }

  void _kill() {
    if (killProcessTreeOnWindows && Platform.isWindows) {
      final pid = process.pid;
      if (pid > 0) {
        try {
          unawaited(
            Process.run(
              'taskkill',
              <String>['/PID', '$pid', '/T', '/F'],
              runInShell: false,
            ).catchError((_) => ProcessResult(0, -1, '', '')),
          );
        } catch (_) {}
      }
    }
    try {
      process.kill();
    } catch (_) {}
  }
}

class _AvailabilityWaitHandle {
  final int requestId;
  final Completer<void> _abortCompleter = Completer<void>();
  bool _cancelled = false;

  _AvailabilityWaitHandle({required this.requestId});

  bool get cancelled => _cancelled;
  Future<void> get abortFuture => _abortCompleter.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_abortCompleter.isCompleted) {
      _abortCompleter.complete();
    }
  }
}
