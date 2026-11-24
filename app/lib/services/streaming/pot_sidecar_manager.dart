import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'ffmpeg_audio_proxy.dart' show YtDlpProcessStarter;

typedef _SidecarAssignJobNative = ffi.Int32 Function(ffi.Uint32);
typedef _SidecarAssignJobDart = int Function(int);

typedef SidecarHealthChecker = Future<bool> Function(Uri baseUri);

/// Platform lifecycle binder attaching a spawned sidecar process to its parent
/// so host crashes never leak orphan sidecar processes.
abstract interface class SidecarLifecycleBinder {
  FutureOr<bool> bindChildProcess(int pid);
}

/// Production lifecycle binder delegating Windows Job Object assignment
/// (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`) to Rust `core_ffi`.
/// On macOS/POSIX, parent-child cleanup is handled by keeping the child's
/// `stdin` anonymous pipe open for the parent's lifetime (EOF on parent exit).
class FfiSidecarLifecycleBinder implements SidecarLifecycleBinder {
  final ffi.DynamicLibrary? Function() _libraryProvider;

  ffi.DynamicLibrary? _boundLib;
  _SidecarAssignJobDart? _assignJobFn;

  FfiSidecarLifecycleBinder({required this._libraryProvider});

  @override
  bool bindChildProcess(int pid) {
    if (pid <= 0) return false;
    if (!Platform.isWindows) {
      // macOS / POSIX rely on anonymous stdin pipe EOF monitoring.
      return true;
    }
    final lib = _libraryProvider();
    if (lib == null) return false;
    if (!identical(lib, _boundLib) || _assignJobFn == null) {
      try {
        _assignJobFn =
            lib.lookupFunction<_SidecarAssignJobNative, _SidecarAssignJobDart>(
          'lumina_sidecar_assign_job',
        );
        _boundLib = lib;
      } catch (_) {
        return false;
      }
    }
    try {
      return _assignJobFn!(pid) == 0;
    } catch (_) {
      return false;
    }
  }
}

/// Manages a local persistent PO Token HTTP sidecar (e.g. `bgutil-pot`).
///
/// Security & reliability guarantees:
/// - Bind address strictly locked to `127.0.0.1` (non-loopback hosts rejected).
/// - Strict parent-child lifecycle binding:
///   - Windows: Win32 Job Object (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`) via Rust FFI.
///   - macOS: holds child `stdin` anonymous pipe write-end open until shutdown so
///     parent exit/crash immediately delivers `EOF` to child `stdin`.
/// - Exponential backoff watchdog (`1s -> 3s -> 10s`) on unexpected exits,
///   resetting after sustained healthy uptime and cancelling cleanly on dispose.
class PotSidecarManager {
  static const String loopbackHost = '127.0.0.1';
  static const List<Duration> defaultBackoffDelays = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 3),
    Duration(seconds: 10),
  ];

  final String bindHost;
  final String? _explicitExecutablePath;
  final String? Function()? _executableResolver;
  final int? _fixedPort;
  final List<String> extraArgs;
  final List<Duration> backoffDelays;
  final Duration healthyResetDuration;
  final Duration startupHealthTimeout;
  final YtDlpProcessStarter _processStarter;
  final SidecarLifecycleBinder? _lifecycleBinder;
  final SidecarHealthChecker? _healthChecker;
  final Future<int> Function() _portAllocator;
  final DateTime Function() _clock;

  Process? _process;
  IOSink? _heldStdin;
  Uri? _baseUri;
  Future<Uri?>? _startFuture;
  Timer? _watchdogTimer;
  DateTime? _lastStartedAt;
  int _consecutiveFailures = 0;
  int _restartCount = 0;
  bool _stopping = false;
  bool _disposed = false;

  PotSidecarManager({
    this.bindHost = loopbackHost,
    String? executablePath,
    this._executableResolver,
    this._fixedPort,
    this.extraArgs = const <String>[],
    this.backoffDelays = defaultBackoffDelays,
    this.healthyResetDuration = const Duration(seconds: 30),
    this.startupHealthTimeout = const Duration(seconds: 3),
    YtDlpProcessStarter? processStarter,
    this._lifecycleBinder,
    this._healthChecker,
    Future<int> Function()? portAllocator,
    DateTime Function()? clock,
  }) : _explicitExecutablePath = executablePath,
       _processStarter = processStarter ?? Process.start,
       _portAllocator = portAllocator ?? _allocateLoopbackPort,
       _clock = clock ?? DateTime.now {
    assertLoopbackOnly(bindHost);
  }

  /// Enforces that sidecar bind host is strictly `127.0.0.1`.
  static void assertLoopbackOnly(String host) {
    if (host.trim() != loopbackHost) {
      throw ArgumentError.value(
        host,
        'bindHost',
        'PO Token sidecar bind address is strictly locked to 127.0.0.1',
      );
    }
  }

  /// Validates that an HTTP endpoint URI targets strictly `127.0.0.1`.
  static void assertLoopbackUri(Uri uri) {
    if ((uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host != loopbackHost) {
      throw ArgumentError.value(
        uri.toString(),
        'uri',
        'PO Token service endpoint must strictly target 127.0.0.1',
      );
    }
  }

  static Future<int> _allocateLoopbackPort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  Uri? get baseUri => _baseUri;
  bool get isRunning => _process != null && _baseUri != null && !_disposed;
  int get restartCount => _restartCount;
  int get consecutiveFailures => _consecutiveFailures;

  @visibleForTesting
  bool get hasOpenStdinPipe => _heldStdin != null;

  /// Builds strictly loopback-bound CLI arguments for launching the sidecar.
  List<String> buildLaunchArgs(int port) {
    assertLoopbackOnly(bindHost);
    return <String>[
      '--host',
      loopbackHost,
      '--port',
      '$port',
      ...extraArgs,
    ];
  }

  /// Locates a sidecar binary across user-updated, bundled, and PATH tiers.
  String? resolveExecutablePath() {
    if (_explicitExecutablePath != null &&
        _explicitExecutablePath.trim().isNotEmpty) {
      return _explicitExecutablePath.trim();
    }
    if (_executableResolver != null) {
      final resolved = _executableResolver();
      return (resolved != null && resolved.trim().isNotEmpty)
          ? resolved.trim()
          : null;
    }
    return _discoverDefaultSidecarBinary();
  }

  static String? _discoverDefaultSidecarBinary() {
    final names = Platform.isWindows
        ? const <String>['bgutil-pot.exe', 'bgutil-pot-server.exe']
        : const <String>['bgutil-pot', 'bgutil-pot-server'];

    final dirs = <String>[];
    final localAppData = Platform.environment['LOCALAPPDATA']?.trim();
    if (localAppData != null && localAppData.isNotEmpty) {
      dirs.add(
        '$localAppData${Platform.pathSeparator}LuminaAudio${Platform.pathSeparator}bin',
      );
    }
    final exeDir = File(Platform.resolvedExecutable).parent;
    dirs.add('${exeDir.path}${Platform.pathSeparator}bin');
    var ancestor = exeDir;
    for (var i = 0; i < 6; i++) {
      dirs.add(
        '${ancestor.path}${Platform.pathSeparator}windows${Platform.pathSeparator}vendor${Platform.pathSeparator}bin',
      );
      final parent = ancestor.parent;
      if (parent.path == ancestor.path) break;
      ancestor = parent;
    }

    for (final dir in dirs) {
      for (final name in names) {
        final path = '$dir${Platform.pathSeparator}$name';
        if (File(path).existsSync()) return path;
      }
    }
    return null;
  }

  /// Ensures the local sidecar process is running, deduplicating concurrent
  /// startups. Returns `null` cleanly if no sidecar binary is installed.
  Future<Uri?> ensureRunning() {
    if (_disposed) return Future<Uri?>.value(null);
    final runningUri = _baseUri;
    if (_process != null && runningUri != null) {
      return Future<Uri?>.value(runningUri);
    }
    final inFlight = _startFuture;
    if (inFlight != null) return inFlight;

    final future = _startInternal();
    _startFuture = future;
    return future.whenComplete(() {
      if (identical(_startFuture, future)) {
        _startFuture = null;
      }
    });
  }

  Future<Uri?> _startInternal() async {
    if (_disposed) return null;
    final exe = resolveExecutablePath();
    if (exe == null) return null;

    _stopping = false;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;

    try {
      final port = _fixedPort ?? await _portAllocator();
      final uri = Uri(scheme: 'http', host: loopbackHost, port: port);
      assertLoopbackUri(uri);

      final args = buildLaunchArgs(port);
      final proc = await _processStarter(
        exe,
        args,
        mode: ProcessStartMode.normal,
        runInShell: false,
      );

      if (_disposed || _stopping) {
        _terminateProcess(proc);
        return null;
      }

      // Windows: assign to KILL_ON_JOB_CLOSE Job Object immediately.
      try {
        await _lifecycleBinder?.bindChildProcess(proc.pid);
      } catch (_) {}

      // macOS / POSIX: retain stdin anonymous pipe write-end open for parent lifetime.
      IOSink? heldStdin;
      try {
        heldStdin = proc.stdin;
      } catch (_) {}

      // Always drain stdout/stderr so child pipes never block.
      unawaited(proc.stdout.drain<void>().catchError((_) {}));
      unawaited(proc.stderr.drain<void>().catchError((_) {}));

      _process = proc;
      _heldStdin = heldStdin;
      _baseUri = uri;
      _lastStartedAt = _clock();

      unawaited(
        proc.exitCode.then(
          (code) => _handleProcessExit(proc, code),
          onError: (_) => _handleProcessExit(proc, -1),
        ),
      );

      if (_healthChecker != null) {
        final healthy = await _waitForHealthy(uri);
        if (!healthy || _disposed || _stopping || !identical(_process, proc)) {
          return _disposed || _stopping ? null : _baseUri;
        }
      }

      return _baseUri;
    } catch (e) {
      debugPrint('[PotSidecarManager] Failed to start PO Token sidecar: $e');
      _scheduleWatchdogRestart();
      return null;
    }
  }

  Future<bool> _waitForHealthy(Uri uri) async {
    final checker = _healthChecker;
    if (checker == null) return true;
    final deadline = _clock().add(startupHealthTimeout);
    while (!_disposed && !_stopping) {
      try {
        if (await checker(uri)) return true;
      } catch (_) {}
      if (!_clock().isBefore(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return false;
  }

  void _handleProcessExit(Process proc, int exitCode) {
    if (!identical(_process, proc)) return;
    _process = null;
    _heldStdin = null;
    _baseUri = null;

    if (_disposed || _stopping) return;

    final startedAt = _lastStartedAt;
    if (startedAt != null &&
        _clock().difference(startedAt) >= healthyResetDuration) {
      _consecutiveFailures = 0;
    }
    _scheduleWatchdogRestart();
  }

  void _scheduleWatchdogRestart() {
    if (_disposed || _stopping) return;
    _watchdogTimer?.cancel();
    _consecutiveFailures++;
    final idx = (_consecutiveFailures - 1).clamp(0, backoffDelays.length - 1);
    final delay = backoffDelays[idx];
    _watchdogTimer = Timer(delay, () {
      _watchdogTimer = null;
      if (_disposed || _stopping) return;
      _restartCount++;
      unawaited(ensureRunning());
    });
  }

  /// Gracefully stops the sidecar (closes `stdin` EOF pipe, sends `SIGTERM`,
  /// escalates to `SIGKILL` after grace period) and cancels watchdog timers.
  Future<void> stop({
    Duration graceTimeout = const Duration(seconds: 1),
  }) async {
    _stopping = true;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;

    final proc = _process;
    final stdinSink = _heldStdin;
    _process = null;
    _heldStdin = null;
    _baseUri = null;

    if (stdinSink != null) {
      try {
        await stdinSink.close();
      } catch (_) {}
    }

    if (proc != null) {
      try {
        proc.kill(ProcessSignal.sigterm);
      } catch (_) {}
      try {
        await proc.exitCode.timeout(graceTimeout);
      } on TimeoutException {
        try {
          proc.kill(ProcessSignal.sigkill);
        } catch (_) {}
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
  }

  static void _terminateProcess(Process proc) {
    try {
      proc.kill(ProcessSignal.sigkill);
    } catch (_) {}
  }
}
