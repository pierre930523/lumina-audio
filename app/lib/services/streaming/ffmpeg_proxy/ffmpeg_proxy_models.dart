part of '../ffmpeg_audio_proxy.dart';

/// Signature matching [Process.start] for injectable deterministic testing.
typedef YtDlpProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      bool includeParentEnvironment,
      bool runInShell,
      ProcessStartMode mode,
    });

class _ProxySession {
  final String token;
  final String sourceUrl;
  final Map<String, String> headers;
  final int playRequestId;
  final bool isDashMpd;
  final bool copyFlac;
  final String outputExtension;
  final String contentType;
  final String? tempFilePath;

  const _ProxySession({
    required this.token,
    required this.sourceUrl,
    required this.headers,
    required this.playRequestId,
    this.isDashMpd = false,
    this.copyFlac = false,
    this.outputExtension = 'wav',
    this.contentType = 'audio/wav',
    this.tempFilePath,
  });
}

class _ActiveFfmpegStream {
  final Process process;
  final int playRequestId;
  final String token;
  final Completer<void> _doneCompleter = Completer<void>();

  StreamSubscription<List<int>>? _stdoutSub;
  bool _aborted = false;

  _ActiveFfmpegStream({
    required this.process,
    required this.playRequestId,
    required this.token,
  });

  bool get aborted => _aborted;
  Future<void> get done => _doneCompleter.future;

  void attachStdoutSubscription(StreamSubscription<List<int>> sub) {
    _stdoutSub = sub;
    if (_aborted) {
      unawaited(sub.cancel().catchError((_) {}));
    }
  }

  void markDone() {
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }

  void abort() {
    if (_aborted) return;
    _aborted = true;
    try {
      process.kill();
    } catch (_) {}
    final sub = _stdoutSub;
    _stdoutSub = null;
    if (sub != null) {
      unawaited(sub.cancel().catchError((_) {}));
    }
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
  }
}
