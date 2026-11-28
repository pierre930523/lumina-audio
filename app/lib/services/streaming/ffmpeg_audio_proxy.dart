import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

part 'ffmpeg_proxy/ffmpeg_proxy_models.dart';
part 'ffmpeg_proxy/ffmpeg_stream_handler.dart';

/// Local loopback HTTP proxy that lazily transcodes unsupported audio formats
/// (e.g. Opus/WebM, HLS/m3u8, DASH, AC3/EAC3) into lossless 24-bit PCM WAV
/// streams (`pcm_s24le`) while preserving the source sample rate bit-for-bit.
///
/// Designed to be 100% compatible with Rust's `HttpRangeMediaSource`
/// (`crates/core-audio/src/stream.rs`) without modifying native code:
/// - `HEAD /stream/<token>.wav` replies `200 OK` + `Accept-Ranges: none` and
///   closes immediately WITHOUT spawning `ffmpeg.exe`.
/// - `GET /stream/<token>.wav` ignores `Range: bytes=0-0` and replies `200 OK`
///   with `Content-Type: audio/wav`, causing Rust's probe to enter
///   `ProbeResult::Sequential` and read the live PCM WAV stream directly.
class FfmpegAudioProxy {
  final String? Function() _ffmpegPathProvider;
  final YtDlpProcessStarter _processStarter;
  final Future<HttpServer> Function() _serverFactory;
  final Random _random;

  HttpServer? _server;
  Future<HttpServer>? _bindFuture;
  bool _disposed = false;

  _ProxySession? _activeSession;
  _ActiveFfmpegStream? _activeStream;
  final Set<Process> _runningProcesses = <Process>{};
  final Map<Process, int> _runningProcessRequestIds = <Process, int>{};
  final Set<String> _trackedTempFiles = <String>{};
  int _spawnCount = 0;
  int _cancelGeneration = 0;
  int? _pendingOpenRequestId;

  FfmpegAudioProxy({
    required this._ffmpegPathProvider,
    YtDlpProcessStarter? processStarter,
    Future<HttpServer> Function()? serverFactory,
    Random? random,
  }) : _processStarter = processStarter ?? Process.start,
       _serverFactory = serverFactory ?? _defaultBindLoopback,
       _random = random ?? Random.secure();

  static Future<HttpServer> _defaultBindLoopback() =>
      HttpServer.bind(InternetAddress.loopbackIPv4, 0);

  /// Bound local TCP port once lazily started, or `null` if not yet bound.
  int? get port => _server?.port;

  /// Whether the loopback HTTP server is currently bound and listening.
  bool get isBound => _server != null;

  /// Number of `ffmpeg.exe` processes still running (not yet exited).
  int get activeProcessCount => _runningProcesses.length;

  /// Total number of `ffmpeg.exe` processes spawned by this proxy (for diagnostics/tests).
  @visibleForTesting
  int get spawnCount => _spawnCount;

  /// Number of temporary `.mpd` manifest files still tracked on disk (for tests).
  @visibleForTesting
  int get trackedTempFileCount => _trackedTempFiles.length;

  /// Builds FFmpeg CLI arguments for streaming a local DASH `.mpd` manifest to stdout.
  ///
  /// When [copyFlac] is `true`, remuxes FLAC losslessly (`-c:a copy -f flac pipe:1`);
  /// otherwise decodes to lossless 24-bit WAV (`-c:a pcm_s24le -f wav pipe:1`)
  /// without passing `-ar` so the original sample rate is preserved.
  static List<String> buildDashMpdFfmpegArgs({
    required String mpdFilePath,
    bool copyFlac = true,
  }) {
    return <String>[
      '-hide_banner',
      '-loglevel',
      'error',
      '-nostdin',
      '-protocol_whitelist',
      'file,http,https,tcp,tls,crypto,data',
      '-allowed_extensions',
      'ALL',
      '-f',
      'dash',
      '-i',
      mpdFilePath,
      '-vn',
      '-sn',
      '-dn',
      if (copyFlac) ...const <String>[
        '-c:a',
        'copy',
        '-f',
        'flac',
        'pipe:1',
      ] else ...const <String>[
        '-c:a',
        'pcm_s24le',
        '-f',
        'wav',
        'pipe:1',
      ],
    ];
  }

  /// Builds exact FFmpeg CLI arguments for lossless 24-bit WAV pipe output.
  ///
  /// Passes `-user_agent` and `-headers` for HTTP(S) inputs and NEVER passes
  /// `-ar` so the original audio sample rate is preserved intact.
  static List<String> buildFfmpegArgs({
    required String sourceUrl,
    Map<String, String> headers = const {},
  }) {
    final args = <String>[
      '-hide_banner',
      '-loglevel',
      'error',
      '-nostdin',
    ];

    final uri = Uri.tryParse(sourceUrl.trim());
    final scheme = uri?.scheme.toLowerCase();
    final isHttp = scheme == 'http' || scheme == 'https';

    if (isHttp) {
      args.addAll(const <String>[
        '-reconnect',
        '1',
        '-reconnect_streamed',
        '1',
        '-reconnect_delay_max',
        '2',
      ]);

      final userAgent = extractUserAgent(headers);
      if (userAgent != null && userAgent.isNotEmpty) {
        args.addAll(<String>['-user_agent', userAgent]);
      }

      final formattedHeaders = formatFfmpegHeaders(headers);
      if (formattedHeaders.isNotEmpty) {
        args.addAll(<String>['-headers', formattedHeaders]);
      }
    }

    args.addAll(<String>[
      '-i',
      sourceUrl,
      '-vn',
      '-sn',
      '-dn',
      '-c:a',
      'pcm_s24le',
      '-f',
      'wav',
      'pipe:1',
    ]);

    return args;
  }

  /// Extracts the sanitized `User-Agent` header value (case-insensitive).
  static String? extractUserAgent(Map<String, String> headers) {
    for (final entry in headers.entries) {
      final key = entry.key.replaceAll(RegExp(r'[\r\n]'), '').trim();
      if (key.toLowerCase() == 'user-agent') {
        final value = entry.value.replaceAll(RegExp(r'[\r\n]'), '').trim();
        if (value.isNotEmpty) return value;
      }
    }
    return null;
  }

  /// Formats HTTP headers as CRLF-delimited lines for FFmpeg `-headers`.
  /// Strips embedded CR/LF characters from keys and values to prevent injection.
  static String formatFfmpegHeaders(Map<String, String> headers) {
    if (headers.isEmpty) return '';
    final buffer = StringBuffer();
    for (final entry in headers.entries) {
      final key = entry.key.replaceAll(RegExp(r'[\r\n]'), '').trim();
      final value = entry.value.replaceAll(RegExp(r'[\r\n]'), '').trim();
      if (key.isEmpty || value.isEmpty) continue;
      buffer.write('$key: $value\r\n');
    }
    return buffer.toString();
  }

  Future<HttpServer> _ensureServerStarted() async {
    if (_disposed) {
      throw StateError('FfmpegAudioProxy has already been disposed');
    }
    final existing = _server;
    if (existing != null) return existing;

    final inFlight = _bindFuture;
    if (inFlight != null) return inFlight;

    final future = _serverFactory();
    _bindFuture = future;
    try {
      final server = await future;
      if (_disposed) {
        await server.close(force: true);
        throw StateError('FfmpegAudioProxy was disposed while binding');
      }
      _server = server;
      server.listen(
        (request) => unawaited(_handleRequest(request)),
        onError: (Object error, StackTrace stack) {
          debugPrint('[FfmpegAudioProxy] Server error: $error');
        },
      );
      return server;
    } finally {
      if (identical(_bindFuture, future)) {
        _bindFuture = null;
      }
    }
  }

  Future<HttpServer> _prepareSessionServer({
    required int playRequestId,
    required String missingFfmpegMessage,
  }) async {
    if (_disposed) {
      throw StateError('FfmpegAudioProxy has already been disposed');
    }

    final ffmpegPath = _ffmpegPathProvider();
    if (ffmpegPath == null || ffmpegPath.trim().isEmpty) {
      throw StateError(missingFfmpegMessage);
    }

    // Immediately terminate any prior ffmpeg process before setting up the new session.
    cancel();

    _pendingOpenRequestId = playRequestId;
    final myCancelGen = _cancelGeneration;
    final server = await _ensureServerStarted();
    if (_pendingOpenRequestId == playRequestId) {
      _pendingOpenRequestId = null;
    }
    if (_disposed || myCancelGen != _cancelGeneration) {
      throw StateError('FfmpegAudioProxy session cancelled');
    }
    return server;
  }

  /// Registers a fresh transcoded WAV session for [sourceUrl], immediately
  /// killing any prior active `ffmpeg.exe` process, and returns a loopback URL
  /// (`http://127.0.0.1:<port>/stream/<token>.wav`).
  Future<String> openTranscodedWavUrl({
    required String sourceUrl,
    Map<String, String> headers = const {},
    required int playRequestId,
  }) async {
    final server = await _prepareSessionServer(
      playRequestId: playRequestId,
      missingFfmpegMessage: 'FFmpeg binary is not available for WAV transcoding',
    );
    final token = _generateToken();
    _activeSession = _ProxySession(
      token: token,
      sourceUrl: sourceUrl,
      headers: Map<String, String>.unmodifiable(headers),
      playRequestId: playRequestId,
    );

    return 'http://127.0.0.1:${server.port}/stream/$token.wav';
  }

  /// Writes [mpdXml] to a tracked temporary `.mpd` file, registers a DASH proxy
  /// session (FLAC copy or 24-bit PCM WAV), and returns a loopback stream URL.
  Future<String> openDashMpdUrl({
    required String mpdXml,
    required int playRequestId,
    bool copyFlac = true,
  }) async {
    final server = await _prepareSessionServer(
      playRequestId: playRequestId,
      missingFfmpegMessage: 'FFmpeg binary is not available for DASH transcoding',
    );
    final token = _generateToken();
    final ext = copyFlac ? 'flac' : 'wav';
    final contentType = copyFlac ? 'audio/flac' : 'audio/wav';
    final mpdPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}lumina_tidal_${playRequestId}_${token.substring(0, 8)}.mpd';
    _trackedTempFiles.add(mpdPath);
    try {
      File(mpdPath).writeAsStringSync(mpdXml, encoding: utf8, flush: true);
    } catch (_) {
      _safeDeleteFile(mpdPath);
      rethrow;
    }

    _activeSession = _ProxySession(
      token: token,
      sourceUrl: mpdPath,
      headers: const <String, String>{},
      playRequestId: playRequestId,
      isDashMpd: true,
      copyFlac: copyFlac,
      outputExtension: ext,
      contentType: contentType,
      tempFilePath: mpdPath,
    );

    return 'http://127.0.0.1:${server.port}/stream/$token.$ext';
  }

  String _generateToken() {
    const chars = '0123456789abcdef';
    final buf = StringBuffer();
    for (var i = 0; i < 32; i++) {
      buf.write(chars[_random.nextInt(chars.length)]);
    }
    return buf.toString();
  }

  /// Synchronously kills any active `ffmpeg.exe` process whose `playRequestId`
  /// differs from [exceptRequestId] (or kills unconditionally when null).
  void cancel({int? exceptRequestId}) {
    if (exceptRequestId == null || exceptRequestId != _pendingOpenRequestId) {
      _cancelGeneration++;
      _pendingOpenRequestId = null;
    }

    final session = _activeSession;
    if (session != null &&
        (exceptRequestId == null || session.playRequestId != exceptRequestId)) {
      _activeSession = null;
      _safeDeleteFile(session.tempFilePath);
    }

    final active = _activeStream;
    if (active != null &&
        (exceptRequestId == null || active.playRequestId != exceptRequestId)) {
      active.abort();
      _activeStream = null;
    }

    for (final proc in List<Process>.from(_runningProcesses)) {
      final procReqId = _runningProcessRequestIds[proc];
      if (exceptRequestId == null || procReqId != exceptRequestId) {
        _safeKill(proc);
      }
    }
  }

  /// Cancels all active sessions/processes and waits briefly for killed
  /// `ffmpeg.exe` processes to exit cleanly.
  Future<void> stopAll({Duration waitTimeout = const Duration(seconds: 2)}) async {
    cancel();
    final remaining = List<Process>.from(_runningProcesses);
    for (final proc in remaining) {
      _safeKill(proc);
    }
    if (remaining.isNotEmpty) {
      try {
        await Future.wait(
          remaining.map((p) => p.exitCode.catchError((_) => -1)),
        ).timeout(waitTimeout);
      } on TimeoutException {
        // Best-effort wait; kill signal was already sent.
      }
    }
    _cleanupTrackedTempFiles();
  }

  /// Permanently stops any active transcoding and closes the loopback server.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stopAll();
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close(force: true);
    }
    _cleanupTrackedTempFiles();
  }

  void _cleanupTrackedTempFiles() {
    for (final path in List<String>.from(_trackedTempFiles)) {
      _safeDeleteFile(path);
    }
  }

  void _safeDeleteFile(String? path) {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (file.existsSync()) {
        file.deleteSync();
      }
      if (!file.existsSync()) {
        _trackedTempFiles.remove(path);
      }
    } catch (_) {
      try {
        if (!File(path).existsSync()) {
          _trackedTempFiles.remove(path);
        }
      } catch (_) {}
    }
  }

  static void _safeKill(Process process) {
    try {
      process.kill();
    } catch (_) {
      // Process may already have exited.
    }
  }
}
