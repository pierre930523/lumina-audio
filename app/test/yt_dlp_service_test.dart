import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/yt_dlp_service.dart';
import 'package:lumina_app/ui/settings/general_settings_panel.dart';
import 'package:lumina_app/ui/settings/providers_and_remote_panel.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 20));
    if (predicate()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
  }
  await tester.pump();
}

class _SpawnedCall {
  final String executable;
  final List<String> arguments;
  final bool runInShell;
  final _FakeProcess process;

  const _SpawnedCall({
    required this.executable,
    required this.arguments,
    required this.runInShell,
    required this.process,
  });
}

class _FakeProcess implements Process {
  @override
  final int pid;

  final StreamController<List<int>> _stdoutCtrl =
      StreamController<List<int>>();
  final StreamController<List<int>> _stderrCtrl =
      StreamController<List<int>>();
  final Completer<int> _exitCompleter = Completer<int>();

  bool killed = false;
  int killCalls = 0;

  _FakeProcess({this.pid = 1000});

  factory _FakeProcess.immediate({
    int pid = 1000,
    int exitCode = 0,
    String stdoutText = '',
    String stderrText = '',
  }) {
    final p = _FakeProcess(pid: pid);
    scheduleMicrotask(() {
      if (stdoutText.isNotEmpty && !p._stdoutCtrl.isClosed) {
        p._stdoutCtrl.add(utf8.encode(stdoutText));
      }
      if (stderrText.isNotEmpty && !p._stderrCtrl.isClosed) {
        p._stderrCtrl.add(utf8.encode(stderrText));
      }
      p.finish(exitCode);
    });
    return p;
  }

  void finish(int code) {
    if (!_stdoutCtrl.isClosed) unawaited(_stdoutCtrl.close());
    if (!_stderrCtrl.isClosed) unawaited(_stderrCtrl.close());
    if (!_exitCompleter.isCompleted) {
      _exitCompleter.complete(code);
    }
  }

  @override
  Future<int> get exitCode => _exitCompleter.future;

  @override
  Stream<List<int>> get stdout => _stdoutCtrl.stream;

  @override
  Stream<List<int>> get stderr => _stderrCtrl.stream;

  @override
  IOSink get stdin => throw UnimplementedError('stdin not needed in tests');

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killCalls++;
    if (killed) return false;
    killed = true;
    finish(-1);
    return true;
  }
}

/// Parses RIFF/WAVE header & `fmt ` chunk from raw WAV bytes.
({int sampleRate, int channels, int bitsPerSample}) _parseWavFmt(
  Uint8List bytes,
) {
  if (bytes.length < 44) {
    throw StateError('WAV stream too short (${bytes.length} bytes)');
  }
  final riff = ascii.decode(bytes.sublist(0, 4));
  final wave = ascii.decode(bytes.sublist(8, 12));
  if (riff != 'RIFF' || wave != 'WAVE') {
    throw StateError('Invalid WAV header: $riff / $wave');
  }

  final bd = ByteData.sublistView(bytes);
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final chunkId = ascii.decode(bytes.sublist(offset, offset + 4));
    final chunkSize = bd.getUint32(offset + 4, Endian.little);
    final dataStart = offset + 8;
    if (chunkId == 'fmt ' && dataStart + 16 <= bytes.length) {
      final channels = bd.getUint16(dataStart + 2, Endian.little);
      final sampleRate = bd.getUint32(dataStart + 4, Endian.little);
      final bitsPerSample = bd.getUint16(dataStart + 14, Endian.little);
      return (
        sampleRate: sampleRate,
        channels: channels,
        bitsPerSample: bitsPerSample,
      );
    }
    final next = dataStart + chunkSize + (chunkSize.isOdd ? 1 : 0);
    if (next <= offset) break;
    offset = next;
  }
  throw StateError('WAV fmt chunk not found within ${bytes.length} bytes');
}

String? _locateVendoredFfmpeg() {
  final sep = Platform.pathSeparator;
  final cwd = Directory.current.path;
  final candidates = <String>[
    '$cwd${sep}windows${sep}vendor${sep}bin${sep}ffmpeg.exe',
    '$cwd${sep}app${sep}windows${sep}vendor${sep}bin${sep}ffmpeg.exe',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  HttpOverrides? originalHttpOverrides;
  setUpAll(() {
    originalHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
  });
  tearDownAll(() {
    HttpOverrides.global = originalHttpOverrides;
  });

  group('Version Comparison & Output Parsers', () {
    test('compareVersionStrings handles CalVer, numeric segments, prefixes, and suffixes', () {
      expect(
        YtDlpService.compareVersionStrings('2026.11.05', '2026.10.26'),
        greaterThan(0),
      );
      expect(
        YtDlpService.compareVersionStrings('2026.10.26', '2026.11.05'),
        lessThan(0),
      );
      expect(
        YtDlpService.compareVersionStrings('2026.10.26', '2026.10.9'),
        greaterThan(0),
      );
      expect(
        YtDlpService.compareVersionStrings('2026.10.09', '2026.10.9'),
        equals(0),
      );
      expect(
        YtDlpService.compareVersionStrings('v2026.11.05', '2026.11.05'),
        equals(0),
      );
      expect(
        YtDlpService.compareVersionStrings('2026.10.26.1', '2026.10.26'),
        greaterThan(0),
      );
      expect(
        YtDlpService.compareVersionStrings('2026.10.26', '2026.10.26.0'),
        equals(0),
      );
      expect(
        YtDlpService.compareVersionStrings('2026.10.26', '2026.10.26-rc1'),
        greaterThan(0),
      );
      expect(
        YtDlpService.compareVersionStrings('2026.10.26.post1', '2026.10.26'),
        greaterThan(0),
      );
    });

    test('parses single-line versions for yt-dlp, deno, and ffmpeg', () {
      expect(
        YtDlpService.parseYtDlpVersionOutput('2026.10.26\r\n'),
        equals('2026.10.26'),
      );
      expect(
        YtDlpService.parseDenoVersionOutput(
          'deno 2.9.8 (stable, release, x86_64-pc-windows-msvc)\n'
          'v8 15.0.245.2-rusty\n'
          'typescript 6.0.3\n',
        ),
        equals('2.9.8'),
      );
      expect(
        YtDlpService.parseFfmpegVersionOutput(
          'ffmpeg version N-129219-g359c825152-20261122 Copyright (c) 2000-2026 the FFmpeg developers\n'
          'built with gcc 15.2.0\n',
        ),
        equals('N-129219-g359c825152-20261122'),
      );
    });
  });

  group('Three-Tier Binary Locator & Anti-Regression Comparison', () {
    late Directory tempRoot;
    late Directory userDir;
    late Directory bundledDir;
    late Directory pathDir;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('lumina_ytdlp_loc_');
      userDir = await Directory('${tempRoot.path}\\user_bin').create();
      bundledDir = await Directory('${tempRoot.path}\\bundled_bin').create();
      pathDir = await Directory('${tempRoot.path}\\sys_path_bin').create();
    });

    tearDown(() async {
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('bundled newer beats older AppData yt-dlp and caches both versions', () async {
      final userExe = File('${userDir.path}\\yt-dlp.exe')
        ..writeAsStringSync('user');
      final bundledExe = File('${bundledDir.path}\\yt-dlp.exe')
        ..writeAsStringSync('bundled');
      File('${bundledDir.path}\\deno.exe').writeAsStringSync('deno');
      File('${bundledDir.path}\\ffmpeg.exe').writeAsStringSync('ffmpeg');

      final calls = <_SpawnedCall>[];
      final service = YtDlpService(
        userBinDir: userDir.path,
        bundledBinDir: bundledDir.path,
        pathEnv: pathDir.path,
        processStarter: (
          exe,
          args, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          mode = ProcessStartMode.normal,
        }) async {
          expect(runInShell, isFalse);
          String out = '';
          if (exe == userExe.path) {
            out = '2026.10.26\n';
          } else if (exe == bundledExe.path) {
            out = '2026.11.10\n';
          } else if (exe.endsWith('deno.exe')) {
            out = 'deno 2.9.8 (stable, release)\n';
          } else if (exe.endsWith('ffmpeg.exe')) {
            out = 'ffmpeg version N-129219-g359c825152-20261122 Copyright...\n';
          }
          final proc = _FakeProcess.immediate(stdoutText: out);
          calls.add(
            _SpawnedCall(
              executable: exe,
              arguments: args,
              runInShell: runInShell,
              process: proc,
            ),
          );
          return proc;
        },
      );
      addTearDown(service.dispose);

      final status = await service.initialize();

      expect(status.ytDlpSource, equals(YtDlpBinarySource.bundled));
      expect(status.ytDlpSource.label, equals('內建版'));
      expect(status.ytDlpPath, equals(bundledExe.path));
      expect(status.ytDlpVersion, equals('2026.11.10'));
      expect(service.cachedBinaryVersions[userExe.path], equals('2026.10.26'));
      expect(
        service.cachedBinaryVersions[bundledExe.path],
        equals('2026.11.10'),
      );

      expect(status.denoSource, equals(YtDlpBinarySource.bundled));
      expect(status.denoVersion, equals('2.9.8'));
      expect(status.ffmpegSource, equals(YtDlpBinarySource.bundled));
      expect(status.ffmpegVersion, equals('N-129219-g359c825152-20261122'));
      expect(status.ffmpegDir, equals(bundledDir.path));
      expect(calls.every((c) => !c.runInShell), isTrue);
    });

    test('AppData newer beats older bundled yt-dlp', () async {
      final userExe = File('${userDir.path}\\yt-dlp.exe')
        ..writeAsStringSync('user');
      final bundledExe = File('${bundledDir.path}\\yt-dlp.exe')
        ..writeAsStringSync('bundled');

      final service = YtDlpService(
        userBinDir: userDir.path,
        bundledBinDir: bundledDir.path,
        pathEnv: '',
        processStarter: (
          exe,
          args, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          mode = ProcessStartMode.normal,
        }) async {
          expect(runInShell, isFalse);
          final out = exe == userExe.path ? '2026.12.01\n' : '2026.10.26\n';
          return _FakeProcess.immediate(stdoutText: out);
        },
      );
      addTearDown(service.dispose);

      final status = await service.initialize();
      expect(status.ytDlpSource, equals(YtDlpBinarySource.userUpdated));
      expect(status.ytDlpSource.label, equals('使用者更新版'));
      expect(status.ytDlpPath, equals(userExe.path));
      expect(status.ytDlpVersion, equals('2026.12.01'));
      expect(service.cachedBinaryVersions[bundledExe.path], equals('2026.10.26'));
    });

    test('equal versions prefer bundled so installer upgrade is not shadowed', () async {
      File('${userDir.path}\\yt-dlp.exe').writeAsStringSync('user');
      final bundledExe = File('${bundledDir.path}\\yt-dlp.exe')
        ..writeAsStringSync('bundled');

      final service = YtDlpService(
        userBinDir: userDir.path,
        bundledBinDir: bundledDir.path,
        pathEnv: '',
        processStarter: (
          exe,
          args, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          mode = ProcessStartMode.normal,
        }) async {
          return _FakeProcess.immediate(stdoutText: '2026.10.26\n');
        },
      );
      addTearDown(service.dispose);

      final status = await service.initialize();
      expect(status.ytDlpSource, equals(YtDlpBinarySource.bundled));
      expect(status.ytDlpPath, equals(bundledExe.path));
      expect(status.ytDlpVersion, equals('2026.10.26'));
    });

    test('falls back to quoted system PATH entries without where.exe and reports missing cleanly', () async {
      final sysYtDlp = File('${pathDir.path}\\yt-dlp.exe')
        ..writeAsStringSync('sys');

      final spawned = <String>[];
      final service = YtDlpService(
        userBinDir: userDir.path,
        bundledBinDir: bundledDir.path,
        pathEnv: '"${pathDir.path}";C:\\DoesNotExist\\Bin',
        processStarter: (
          exe,
          args, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          mode = ProcessStartMode.normal,
        }) async {
          expect(runInShell, isFalse);
          spawned.add(exe);
          return _FakeProcess.immediate(stdoutText: '2026.09.15\n');
        },
      );
      addTearDown(service.dispose);

      final status = await service.initialize();
      expect(status.ytDlpSource, equals(YtDlpBinarySource.systemPath));
      expect(status.ytDlpSource.label, equals('系統 PATH'));
      expect(status.ytDlpPath, equals(sysYtDlp.path));
      expect(status.denoSource, equals(YtDlpBinarySource.missing));
      expect(status.denoSource.label, equals('未安裝'));
      expect(status.ffmpegSource, equals(YtDlpBinarySource.missing));
      expect(spawned.any((e) => e.toLowerCase().contains('where')), isFalse);
    });
  });

  group('Permission-Safe Atomic In-App Update & Auto-Download Fallback', () {
    late Directory tempRoot;
    late Directory userDir;
    late Directory bundledDir;
    late HttpServer server;

    late String releaseTag;
    late List<int> payloadBytes;
    late String sumsBody;
    late String? lastUserAgent;
    late String? lastAccept;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('lumina_ytdlp_upd_');
      userDir = await Directory('${tempRoot.path}\\user_bin').create();
      bundledDir = await Directory('${tempRoot.path}\\bundled_bin').create();

      releaseTag = '2026.11.05';
      payloadBytes = utf8.encode('FAKE-YTDLP-BINARY-2026.11.05');
      final digest = sha256.convert(payloadBytes).toString();
      sumsBody = '$digest  yt-dlp.exe\n';
      lastUserAgent = null;
      lastAccept = null;

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final resp = req.response;
        if (req.uri.path == '/releases/latest') {
          lastUserAgent = req.headers.value(HttpHeaders.userAgentHeader);
          lastAccept = req.headers.value(HttpHeaders.acceptHeader);
          resp.headers.contentType = ContentType.json;
          resp.write(
            jsonEncode({
              'tag_name': releaseTag,
              'assets': [
                {
                  'name': 'yt-dlp.exe',
                  'browser_download_url':
                      'http://127.0.0.1:${server.port}/download/yt-dlp.exe',
                },
                {
                  'name': 'SHA2-256SUMS',
                  'browser_download_url':
                      'http://127.0.0.1:${server.port}/download/SHA2-256SUMS',
                },
              ],
            }),
          );
          await resp.close();
          return;
        }
        if (req.uri.path == '/download/yt-dlp.exe') {
          resp.add(payloadBytes);
          await resp.close();
          return;
        }
        if (req.uri.path == '/download/SHA2-256SUMS') {
          resp.write(sumsBody);
          await resp.close();
          return;
        }
        resp.statusCode = HttpStatus.notFound;
        await resp.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      if (tempRoot.existsSync()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('valid update writes ONLY to user dir, never mutates bundled dir, and activates new version', () async {
      final bundledExe = File('${bundledDir.path}\\yt-dlp.exe')
        ..writeAsStringSync('BUNDLED-OLD-BINARY');
      final originalBundledContent = bundledExe.readAsStringSync();

      final service = YtDlpService(
        userBinDir: userDir.path,
        bundledBinDir: bundledDir.path,
        pathEnv: '',
        latestReleaseApiUri: Uri.parse(
          'http://127.0.0.1:${server.port}/releases/latest',
        ),
        processStarter: (
          exe,
          args, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          mode = ProcessStartMode.normal,
        }) async {
          expect(runInShell, isFalse);
          if (exe == bundledExe.path) {
            return _FakeProcess.immediate(stdoutText: '2026.10.26\n');
          }
          // Both `.tmp` verification and activated user binary read content.
          final content = File(exe).readAsStringSync();
          if (content.contains('2026.11.05')) {
            return _FakeProcess.immediate(stdoutText: '2026.11.05\n');
          }
          return _FakeProcess.immediate(exitCode: 1, stderrText: 'bad binary');
        },
      );
      addTearDown(service.dispose);

      await service.initialize();
      expect(service.status.ytDlpSource, equals(YtDlpBinarySource.bundled));
      expect(service.status.ytDlpVersion, equals('2026.10.26'));

      final result = await service.checkAndUpdateYtDlp();
      expect(result.isUpdated, isTrue);
      expect(result.latestVersion, equals('2026.11.05'));
      expect(lastUserAgent, equals('LuminaAudio'));
      expect(lastAccept, equals('application/vnd.github+json'));

      // Bundled dir is completely untouched.
      expect(bundledExe.readAsStringSync(), equals(originalBundledContent));
      expect(bundledDir.listSync().length, equals(1));

      // User dir has activated yt-dlp.exe and no leftover .tmp or .bak files.
      final userExe = File('${userDir.path}\\yt-dlp.exe');
      expect(userExe.existsSync(), isTrue);
      expect(userExe.readAsBytesSync(), equals(payloadBytes));
      expect(File('${userDir.path}\\yt-dlp.exe.tmp').existsSync(), isFalse);
      expect(File('${userDir.path}\\yt-dlp.exe.bak').existsSync(), isFalse);

      expect(service.status.ytDlpSource, equals(YtDlpBinarySource.userUpdated));
      expect(service.status.ytDlpVersion, equals('2026.11.05'));
      expect(service.status.isUpdating, isFalse);

      // Re-checking immediately reports upToDate.
      final second = await service.checkAndUpdateYtDlp();
      expect(second.isUpToDate, isTrue);
    });

    test('SHA256 mismatch aborts update, deletes .tmp, and preserves existing binary', () async {
      final bundledExe = File('${bundledDir.path}\\yt-dlp.exe')
        ..writeAsStringSync('BUNDLED-SAFE');
      final existingUser = File('${userDir.path}\\yt-dlp.exe')
        ..writeAsStringSync('USER-OLD-2026.10.28');

      // Corrupt checksum
      sumsBody = '${'0' * 64}  yt-dlp.exe\n';

      final service = YtDlpService(
        userBinDir: userDir.path,
        bundledBinDir: bundledDir.path,
        pathEnv: '',
        latestReleaseApiUri: Uri.parse(
          'http://127.0.0.1:${server.port}/releases/latest',
        ),
        processStarter: (
          exe,
          args, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          mode = ProcessStartMode.normal,
        }) async {
          if (exe == bundledExe.path) {
            return _FakeProcess.immediate(stdoutText: '2026.10.26\n');
          }
          if (exe == existingUser.path) {
            return _FakeProcess.immediate(stdoutText: '2026.10.28\n');
          }
          return _FakeProcess.immediate(stdoutText: '2026.11.05\n');
        },
      );
      addTearDown(service.dispose);

      await service.initialize();
      final result = await service.checkAndUpdateYtDlp();
      expect(result.isFailed, isTrue);
      expect(result.message, contains('SHA256'));

      // Temp file deleted, existing user & bundled binaries completely preserved.
      expect(File('${userDir.path}\\yt-dlp.exe.tmp').existsSync(), isFalse);
      expect(existingUser.readAsStringSync(), equals('USER-OLD-2026.10.28'));
      expect(bundledExe.readAsStringSync(), equals('BUNDLED-SAFE'));
      expect(service.status.ytDlpVersion, equals('2026.10.28'));
      expect(service.status.isUpdating, isFalse);
    });

    test('failed --version check on .tmp aborts update and cleans up .tmp', () async {
      File('${bundledDir.path}\\yt-dlp.exe').writeAsStringSync('BUNDLED');

      final service = YtDlpService(
        userBinDir: userDir.path,
        bundledBinDir: bundledDir.path,
        pathEnv: '',
        latestReleaseApiUri: Uri.parse(
          'http://127.0.0.1:${server.port}/releases/latest',
        ),
        processStarter: (
          exe,
          args, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          mode = ProcessStartMode.normal,
        }) async {
          if (exe.endsWith('.tmp')) {
            return _FakeProcess.immediate(exitCode: 127, stderrText: 'corrupt');
          }
          return _FakeProcess.immediate(stdoutText: '2026.10.26\n');
        },
      );
      addTearDown(service.dispose);

      await service.initialize();
      final result = await service.checkAndUpdateYtDlp();
      expect(result.isFailed, isTrue);
      expect(File('${userDir.path}\\yt-dlp.exe.tmp').existsSync(), isFalse);
      expect(File('${userDir.path}\\yt-dlp.exe').existsSync(), isFalse);
      expect(service.status.ytDlpSource, equals(YtDlpBinarySource.bundled));
    });

    test('ensureAvailable auto-downloads into userBinDir when all three tiers are missing', () async {
      final service = YtDlpService(
        userBinDir: userDir.path,
        bundledBinDir: bundledDir.path,
        pathEnv: '',
        latestReleaseApiUri: Uri.parse(
          'http://127.0.0.1:${server.port}/releases/latest',
        ),
        processStarter: (
          exe,
          args, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          mode = ProcessStartMode.normal,
        }) async {
          return _FakeProcess.immediate(stdoutText: '2026.11.05\n');
        },
      );
      addTearDown(service.dispose);

      final path = await service.ensureAvailable();
      expect(path, equals('${userDir.path}\\yt-dlp.exe'));
      expect(File(path).existsSync(), isTrue);
      expect(service.status.ytDlpSource, equals(YtDlpBinarySource.userUpdated));
      expect(service.status.ytDlpVersion, equals('2026.11.05'));
    });

    test('ensureAvailable fast-path locates single-tier bundled binaries with 0 --version subprocess spawns', () async {
      File('${bundledDir.path}\\yt-dlp.exe').writeAsStringSync('bundled');
      File('${bundledDir.path}\\deno.exe').writeAsStringSync('deno');
      File('${bundledDir.path}\\ffmpeg.exe').writeAsStringSync('ffmpeg');

      var spawnCount = 0;
      final service = YtDlpService(
        userBinDir: userDir.path,
        bundledBinDir: bundledDir.path,
        pathEnv: '',
        processStarter: (
          exe,
          args, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          mode = ProcessStartMode.normal,
        }) async {
          spawnCount++;
          return _FakeProcess.immediate(stdoutText: '2026.11.05\n');
        },
      );
      addTearDown(service.dispose);

      final path = await service.ensureAvailable();
      expect(path, equals('${bundledDir.path}\\yt-dlp.exe'));
      expect(spawnCount, equals(0));
      expect(service.status.ytDlpSource, equals(YtDlpBinarySource.bundled));
      expect(service.status.denoPath, equals('${bundledDir.path}\\deno.exe'));
      expect(service.status.ffmpegDir, equals(bundledDir.path));

      // Explicit initialize() still probes full version metadata cleanly.
      await service.initialize();
      expect(spawnCount, greaterThan(0));
      expect(service.status.ytDlpVersion, equals('2026.11.05'));
    });

    test('parseResolvedStreamJson extracts loudnessDb from yt-dlp loudness field', () {
      final now = DateTime.utc(2026, 11, 24, 6, 0, 0);
      final parsed = YtDlpService.parseResolvedStreamJson(
        videoId: 'dQw4w9WgXcQ',
        rawStdout: jsonEncode(<String, dynamic>{
          'url': 'https://rr1.googlevideo.com/videoplayback?itag=251&expire=1999999999',
          'ext': 'webm',
          'acodec': 'opus',
          'loudness': -4.25,
          'http_headers': <String, String>{'User-Agent': 'Chrome/131'},
        }),
        now: now,
      );
      expect(parsed.loudnessDb, closeTo(-4.25, 1e-6));
    });
  });

  group('Argument Construction, JSON Metadata Parsing, Caching & Transcode Detection', () {
    test('buildResolveArgs emits exact isolated flags', () {
      final args = YtDlpService.buildResolveArgs(
        videoId: 'dQw4w9WgXcQ',
        denoPath: r'C:\Lumina\bin\deno.exe',
        ffmpegDir: r'C:\Lumina\bin',
        cookiesFilePath: r'C:\Temp\cookies.txt',
      );

      expect(
        args,
        equals(<String>[
          '--no-config',
          '--force-ipv4',
          '--js-runtimes',
          r'deno:C:\Lumina\bin\deno.exe',
          '--ffmpeg-location',
          r'C:\Lumina\bin',
          '--extractor-args',
          'youtube:player_client=default,-tv_samsung',
          '--no-playlist',
          '--skip-download',
          '--no-warnings',
          '-f',
          'bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/bestaudio[acodec=aac]/bestaudio',
          '--cookies',
          r'C:\Temp\cookies.txt',
          '-j',
          'https://music.youtube.com/watch?v=dQw4w9WgXcQ',
        ]),
      );
    });

    test('resolveVideo invokes yt-dlp with runInShell: false, --force-ipv4, deno, ffmpeg-location, and preserves all http_headers', () async {
      final tempRoot = await Directory.systemTemp.createTemp('lumina_args_');
      addTearDown(() async {
        if (tempRoot.existsSync()) await tempRoot.delete(recursive: true);
      });
      final bundledDir = await Directory('${tempRoot.path}\\bin').create();
      final ytDlpExe = File('${bundledDir.path}\\yt-dlp.exe')
        ..writeAsStringSync('ytdlp');
      final denoExe = File('${bundledDir.path}\\deno.exe')
        ..writeAsStringSync('deno');
      File('${bundledDir.path}\\ffmpeg.exe').writeAsStringSync('ffmpeg');

      _SpawnedCall? resolveCall;
      final service = YtDlpService(
        userBinDir: '${tempRoot.path}\\user',
        bundledBinDir: bundledDir.path,
        pathEnv: '',
        processStarter: (
          exe,
          args, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          mode = ProcessStartMode.normal,
        }) async {
          if (args.contains('--version') || args.contains('-version')) {
            if (exe.endsWith('deno.exe')) {
              return _FakeProcess.immediate(stdoutText: 'deno 2.9.8 (stable)\n');
            }
            if (exe.endsWith('ffmpeg.exe')) {
              return _FakeProcess.immediate(
                stdoutText: 'ffmpeg version N-129219-g359c825152\n',
              );
            }
            return _FakeProcess.immediate(stdoutText: '2026.10.26\n');
          }
          final proc = _FakeProcess.immediate(
            stdoutText: jsonEncode({
              'url': 'https://rr1.googlevideo.com/videoplayback?itag=140',
              'http_headers': {
                'User-Agent': 'Mozilla/5.0 LuminaYtDlp',
                'Accept': '*/*',
                'Accept-Language': 'en-US,en;q=0.9',
                'Referer': 'https://music.youtube.com/',
              },
              'acodec': 'mp4a.40.2',
              'ext': 'm4a',
              'asr': 44100,
            }),
          );
          resolveCall = _SpawnedCall(
            executable: exe,
            arguments: args,
            runInShell: runInShell,
            process: proc,
          );
          return proc;
        },
      );
      addTearDown(service.dispose);

      final resolved = await service.resolveVideo('dQw4w9WgXcQ', playRequestId: 7);

      expect(resolveCall, isNotNull);
      expect(resolveCall!.executable, equals(ytDlpExe.path));
      expect(resolveCall!.runInShell, isFalse);
      expect(
        resolveCall!.arguments,
        equals(<String>[
          '--no-config',
          '--force-ipv4',
          '--js-runtimes',
          'deno:${denoExe.path}',
          '--ffmpeg-location',
          bundledDir.path,
          '--extractor-args',
          'youtube:player_client=default,-tv_samsung',
          '--no-playlist',
          '--skip-download',
          '--no-warnings',
          '-f',
          'bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/bestaudio[acodec=aac]/bestaudio',
          '-j',
          'https://music.youtube.com/watch?v=dQw4w9WgXcQ',
        ]),
      );
      expect(resolved.httpHeaders, equals(<String, String>{
        'User-Agent': 'Mozilla/5.0 LuminaYtDlp',
        'Accept': '*/*',
        'Accept-Language': 'en-US,en;q=0.9',
        'Referer': 'https://music.youtube.com/',
      }));
    });

    test('parses top-level JSON, expire TTL, fallback 45-min TTL, and requested_formats fallback', () {
      final now = DateTime.utc(2026, 11, 22, 12, 0, 0);
      final expireSec =
          now.add(const Duration(hours: 2)).millisecondsSinceEpoch ~/ 1000;

      final stream = YtDlpService.parseResolvedStreamJson(
        videoId: 'abc123',
        now: now,
        rawStdout: jsonEncode({
          'url':
              'https://rr1---sn.googlevideo.com/videoplayback?itag=140&expire=$expireSec',
          'http_headers': {
            'User-Agent': 'Mozilla/5.0 LuminaTest',
            'Accept': '*/*',
          },
          'acodec': 'mp4a.40.2',
          'ext': 'm4a',
          'asr': 44100,
          'abr': 129.4,
          'duration': 213.5,
          'thumbnail': 'https://i.ytimg.com/vi/abc123/hqdefault.jpg',
        }),
      );

      expect(stream.videoId, equals('abc123'));
      expect(stream.httpHeaders['User-Agent'], equals('Mozilla/5.0 LuminaTest'));
      expect(stream.acodec, equals('mp4a.40.2'));
      expect(stream.ext, equals('m4a'));
      expect(stream.sampleRateHz, equals(44100));
      expect(stream.bitrateKbps, closeTo(129.4, 0.01));
      expect(stream.durationSeconds, closeTo(213.5, 0.01));
      expect(
        stream.thumbnailUrl,
        equals('https://i.ytimg.com/vi/abc123/maxresdefault.jpg'),
      );
      expect(
        stream.expiresAt,
        equals(DateTime.fromMillisecondsSinceEpoch(expireSec * 1000, isUtc: true)),
      );
      expect(stream.qualityLabel, equals('AAC 44.1 kHz'));
      expect(stream.requiresFfmpegTranscode, isFalse);

      // 60s safety margin check
      expect(
        stream.isExpiredAt(stream.expiresAt.subtract(const Duration(seconds: 61))),
        isFalse,
      );
      expect(
        stream.isExpiredAt(stream.expiresAt.subtract(const Duration(seconds: 60))),
        isTrue,
      );

      // Missing top-level url & missing expire falls back to requested_formats + 45m TTL
      final fallback = YtDlpService.parseResolvedStreamJson(
        videoId: 'opus99',
        now: now,
        rawStdout: jsonEncode({
          'duration': 180,
          'thumbnail': 'https://i.ytimg.com/vi/opus99/0.jpg',
          'requested_formats': [
            {
              'url': 'https://rr2---sn.googlevideo.com/videoplayback?itag=251',
              'vcodec': 'none',
              'acodec': 'opus',
              'ext': 'webm',
              'asr': 48000,
              'abr': 160,
              'http_headers': {'User-Agent': 'OpusAgent'},
            },
          ],
        }),
      );

      expect(fallback.acodec, equals('opus'));
      expect(fallback.ext, equals('webm'));
      expect(fallback.httpHeaders['User-Agent'], equals('OpusAgent'));
      expect(fallback.expiresAt, equals(now.add(const Duration(minutes: 45))));
      expect(fallback.qualityLabel, equals('OPUS 48 kHz'));
      expect(fallback.requiresFfmpegTranscode, isTrue);
    });

    test('qualityLabel and requiresFfmpegTranscode matrix across Symphonia vs fallback codecs', () {
      YtDlpResolvedStream make({
        String? acodec,
        String? ext,
        String url = 'https://example.com/audio',
        int? asr,
        double? abr,
      }) {
        return YtDlpResolvedStream(
          videoId: 'v',
          url: url,
          httpHeaders: const {},
          acodec: acodec,
          ext: ext,
          sampleRateHz: asr,
          bitrateKbps: abr,
          expiresAt: DateTime.utc(2030),
        );
      }

      // Symphonia-supported formats -> false
      expect(make(acodec: 'mp4a.40.2', ext: 'm4a').requiresFfmpegTranscode, isFalse);
      expect(make(acodec: 'aac', ext: 'aac').requiresFfmpegTranscode, isFalse);
      expect(make(acodec: 'mp3', ext: 'mp3', asr: 44100).requiresFfmpegTranscode, isFalse);
      expect(make(acodec: 'mp3', ext: 'mp3', asr: 44100).qualityLabel, equals('MP3 44.1 kHz'));
      expect(make(acodec: 'flac', ext: 'flac').requiresFfmpegTranscode, isFalse);
      expect(make(acodec: 'alac', ext: 'm4a').requiresFfmpegTranscode, isFalse);
      expect(make(acodec: 'vorbis', ext: 'ogg').requiresFfmpegTranscode, isFalse);
      expect(make(acodec: 'pcm_s24le', ext: 'wav').requiresFfmpegTranscode, isFalse);
      expect(make(acodec: null, ext: 'aiff').requiresFfmpegTranscode, isFalse);

      // Unsupported formats -> true
      expect(make(acodec: 'opus', ext: 'webm').requiresFfmpegTranscode, isTrue);
      expect(make(acodec: 'opus', ext: 'ogg').requiresFfmpegTranscode, isTrue);
      expect(make(acodec: 'vorbis', ext: 'webm').requiresFfmpegTranscode, isTrue);
      expect(make(acodec: 'mp4a.40.2', ext: 'm3u8').requiresFfmpegTranscode, isTrue);
      expect(
        make(
          acodec: 'mp4a.40.2',
          ext: 'm4a',
          url: 'https://manifest.googlevideo.com/api/manifest/hls_playlist/index.m3u8',
        ).requiresFfmpegTranscode,
        isTrue,
      );
      expect(make(acodec: 'mp4a.40.2', ext: 'dash').requiresFfmpegTranscode, isTrue);
      expect(make(acodec: 'ac-3', ext: 'm4a').requiresFfmpegTranscode, isTrue);
      expect(make(acodec: 'ec-3', ext: 'm4a').requiresFfmpegTranscode, isTrue);

      // Bitrate fallback when sampleRateHz missing
      expect(
        make(acodec: 'mp4a.40.2', ext: 'm4a', abr: 128.4).qualityLabel,
        equals('AAC 128 kbps'),
      );
    });

    test('cache hit, clock-driven expiry, and bypassCache work deterministically', () async {
      final tempRoot = await Directory.systemTemp.createTemp('lumina_cache_');
      addTearDown(() async {
        if (tempRoot.existsSync()) await tempRoot.delete(recursive: true);
      });
      final bundledDir = await Directory('${tempRoot.path}\\bin').create();
      File('${bundledDir.path}\\yt-dlp.exe').writeAsStringSync('bin');

      var now = DateTime.utc(2026, 11, 22, 10, 0, 0);
      var resolveCalls = 0;

      final service = YtDlpService(
        userBinDir: '${tempRoot.path}\\user',
        bundledBinDir: bundledDir.path,
        pathEnv: '',
        clock: () => now,
        processStarter: (
          exe,
          args, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          mode = ProcessStartMode.normal,
        }) async {
          if (args.contains('--version')) {
            return _FakeProcess.immediate(stdoutText: '2026.10.26\n');
          }
          resolveCalls++;
          final exp =
              now.add(const Duration(minutes: 10)).millisecondsSinceEpoch ~/
              1000;
          return _FakeProcess.immediate(
            stdoutText: jsonEncode({
              'url': 'https://cdn.example.com/a$resolveCalls.m4a?expire=$exp',
              'acodec': 'mp4a.40.2',
              'ext': 'm4a',
              'asr': 44100,
            }),
          );
        },
      );
      addTearDown(service.dispose);

      final first = await service.resolveVideo('vid1', playRequestId: 1);
      expect(resolveCalls, equals(1));
      expect(first.url, contains('a1.m4a'));

      // Cache hit 5 minutes later
      now = now.add(const Duration(minutes: 5));
      final second = await service.resolveVideo('vid1', playRequestId: 2);
      expect(resolveCalls, equals(1));
      expect(second.url, equals(first.url));

      // bypassCache forces fresh call
      final third = await service.resolveVideo(
        'vid1',
        playRequestId: 3,
        bypassCache: true,
      );
      expect(resolveCalls, equals(2));
      expect(third.url, contains('a2.m4a'));

      // Advance past expiry (within 60s margin) -> cache evicted, fresh call
      now = now.add(const Duration(minutes: 9, seconds: 5));
      final fourth = await service.resolveVideo('vid1', playRequestId: 4);
      expect(resolveCalls, equals(3));
      expect(fourth.url, contains('a3.m4a'));

      // clearCache supports both raw videoId and ytm:-prefixed track IDs
      service.clearCache('ytm:vid1');
      expect(service.getCachedStream('vid1'), isNull);
    });

    test('resolveVideo handles >4MB Podcast JSON stdout without truncating trailing url/http_headers', () async {
      final tempRoot = await Directory.systemTemp.createTemp('lumina_bigjson_');
      addTearDown(() async {
        if (tempRoot.existsSync()) await tempRoot.delete(recursive: true);
      });
      final bundledDir = await Directory('${tempRoot.path}\\bin').create();
      File('${bundledDir.path}\\yt-dlp.exe').writeAsStringSync('bin');

      final hugeCaptions = 'x' * (5 * 1024 * 1024);
      final payload = jsonEncode(<String, dynamic>{
        'id': '9aQmf7kB0aQ',
        'automatic_captions': hugeCaptions,
        'url': 'https://rr1.googlevideo.com/videoplayback?itag=140&pod=1',
        'http_headers': <String, String>{
          'User-Agent': 'Mozilla/5.0 BigPodTest',
          'Accept': '*/*',
        },
        'acodec': 'mp4a.40.2',
        'ext': 'm4a',
        'asr': 44100,
      });

      final service = YtDlpService(
        userBinDir: '${tempRoot.path}\\user',
        bundledBinDir: bundledDir.path,
        pathEnv: '',
        processStarter: (
          exe,
          args, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          mode = ProcessStartMode.normal,
        }) async {
          if (args.contains('--version')) {
            return _FakeProcess.immediate(stdoutText: '2026.10.26\n');
          }
          return _FakeProcess.immediate(stdoutText: payload);
        },
      );
      addTearDown(service.dispose);

      final resolved = await service.resolveVideo('9aQmf7kB0aQ', playRequestId: 1);
      expect(resolved.url, contains('pod=1'));
      expect(resolved.httpHeaders['User-Agent'], equals('Mozilla/5.0 BigPodTest'));
    });

    test('resolveVideo honors future available_at delay and aborts immediately on cancelRequest', () async {
      final tempRoot = await Directory.systemTemp.createTemp('lumina_avail_');
      addTearDown(() async {
        if (tempRoot.existsSync()) await tempRoot.delete(recursive: true);
      });
      final bundledDir = await Directory('${tempRoot.path}\\bin').create();
      File('${bundledDir.path}\\yt-dlp.exe').writeAsStringSync('bin');

      final baseNow = DateTime.utc(2026, 11, 23, 4, 30, 0);
      var futureOffsetSeconds = 0.15;

      final service = YtDlpService(
        userBinDir: '${tempRoot.path}\\user',
        bundledBinDir: bundledDir.path,
        pathEnv: '',
        clock: () => baseNow,
        processStarter: (
          exe,
          args, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          mode = ProcessStartMode.normal,
        }) async {
          if (args.contains('--version')) {
            return _FakeProcess.immediate(stdoutText: '2026.10.26\n');
          }
          final availSec =
              (baseNow.millisecondsSinceEpoch / 1000.0) + futureOffsetSeconds;
          return _FakeProcess.immediate(
            stdoutText: jsonEncode(<String, dynamic>{
              'url': 'https://rr1.googlevideo.com/videoplayback?itag=140',
              'available_at': availSec,
              'acodec': 'mp4a.40.2',
              'ext': 'm4a',
              'asr': 44100,
            }),
          );
        },
      );
      addTearDown(service.dispose);

      // 1. Waits ~150ms for available_at before returning.
      final sw = Stopwatch()..start();
      final ok = await service.resolveVideo('avail1', playRequestId: 10);
      sw.stop();
      expect(ok.availableAt, isNotNull);
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(110));

      // 2. Cancelling during a 10s available_at wait aborts immediately without waiting 10s.
      futureOffsetSeconds = 10.0;
      final swCancel = Stopwatch()..start();
      final pending = service.resolveVideo('avail2', playRequestId: 11);
      Timer(const Duration(milliseconds: 30), () => service.cancelRequest(11));
      await expectLater(
        pending,
        throwsA(
          isA<YtDlpException>().having((e) => e.isCancelled, 'isCancelled', true),
        ),
      );
      swCancel.stop();
      expect(swCancel.elapsedMilliseconds, lessThan(2000));
      expect(service.getCachedStream('avail2'), isNull);
    });
  });

  group('Instant Kill on Track Switch, Timeout & Preload Isolation', () {
    late Directory tempRoot;
    late Directory bundledDir;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('lumina_kill_');
      bundledDir = await Directory('${tempRoot.path}\\bin').create();
      File('${bundledDir.path}\\yt-dlp.exe').writeAsStringSync('bin');
    });

    tearDown(() async {
      if (tempRoot.existsSync()) await tempRoot.delete(recursive: true);
    });

    test('switching playRequestId immediately kills prior foreground process before starting new one', () async {
      final hangingFirst = _FakeProcess(pid: 101);
      var firstKilledBeforeSecondSpawn = false;
      var resolveCount = 0;

      final service = YtDlpService(
        userBinDir: '${tempRoot.path}\\user',
        bundledBinDir: bundledDir.path,
        pathEnv: '',
        processStarter: (
          exe,
          args, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          mode = ProcessStartMode.normal,
        }) async {
          if (args.contains('--version')) {
            return _FakeProcess.immediate(stdoutText: '2026.10.26\n');
          }
          resolveCount++;
          if (resolveCount == 1) {
            return hangingFirst;
          }
          firstKilledBeforeSecondSpawn = hangingFirst.killed;
          return _FakeProcess.immediate(
            pid: 102,
            stdoutText: jsonEncode({
              'url': 'https://cdn.example.com/track2.m4a',
              'acodec': 'mp4a.40.2',
              'ext': 'm4a',
              'asr': 44100,
            }),
          );
        },
      );
      addTearDown(service.dispose);
      await service.initialize();

      final req1 = service.resolveVideo('track1', playRequestId: 1);
      // Let request 1 spawn its process.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(hangingFirst.killed, isFalse);

      final req2 = service.resolveVideo('track2', playRequestId: 2);

      await expectLater(
        req1,
        throwsA(
          isA<YtDlpException>().having((e) => e.isCancelled, 'isCancelled', true),
        ),
      );
      final stream2 = await req2;
      expect(hangingFirst.killed, isTrue);
      expect(firstKilledBeforeSecondSpawn, isTrue);
      expect(stream2.url, equals('https://cdn.example.com/track2.m4a'));
    });

    test('enforces resolve timeout and immediately kills stalled process', () async {
      final hanging = _FakeProcess(pid: 201);
      final service = YtDlpService(
        userBinDir: '${tempRoot.path}\\user',
        bundledBinDir: bundledDir.path,
        pathEnv: '',
        resolveTimeout: const Duration(milliseconds: 120),
        processStarter: (
          exe,
          args, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          mode = ProcessStartMode.normal,
        }) async {
          if (args.contains('--version')) {
            return _FakeProcess.immediate(stdoutText: '2026.10.26\n');
          }
          return hanging;
        },
      );
      addTearDown(service.dispose);
      await service.initialize();

      await expectLater(
        service.resolveVideo('slow_track', playRequestId: 1),
        throwsA(
          isA<YtDlpException>().having((e) => e.isTimeout, 'isTimeout', true),
        ),
      );
      expect(hanging.killed, isTrue);
    });

    test('preloadVideo populates cache, cancels superseded preload, never kills foreground, and swallows errors', () async {
      final fgProc = _FakeProcess(pid: 301);
      final preload1Proc = _FakeProcess(pid: 302);
      var preload1Calls = 0;

      final service = YtDlpService(
        userBinDir: '${tempRoot.path}\\user',
        bundledBinDir: bundledDir.path,
        pathEnv: '',
        processStarter: (
          exe,
          args, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          mode = ProcessStartMode.normal,
        }) async {
          if (args.contains('--version')) {
            return _FakeProcess.immediate(stdoutText: '2026.10.26\n');
          }
          final urlArg = args.last;
          if (urlArg.endsWith('fg_vid')) return fgProc;
          if (urlArg.endsWith('pre_1')) {
            preload1Calls++;
            return preload1Proc;
          }
          if (urlArg.endsWith('pre_2')) {
            return _FakeProcess.immediate(
              pid: 303,
              stdoutText: jsonEncode({
                'url': 'https://cdn.example.com/pre2.m4a',
                'acodec': 'mp4a.40.2',
                'ext': 'm4a',
                'asr': 44100,
              }),
            );
          }
          return _FakeProcess.immediate(exitCode: 1, stderrText: 'boom');
        },
      );
      addTearDown(service.dispose);
      await service.initialize();

      // Start foreground resolution
      final fgFuture = service.resolveVideo('fg_vid', playRequestId: 10);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // Duplicate preload for pre_1 spawns only once and never kills fgProc
      final p1a = service.preloadVideo('pre_1');
      final p1b = service.preloadVideo('pre_1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(preload1Calls, equals(1));
      expect(fgProc.killed, isFalse);

      // Starting pre_2 supersedes & kills pre_1, still never kills fgProc
      final pre2 = await service.preloadVideo('pre_2');
      expect(preload1Proc.killed, isTrue);
      expect(fgProc.killed, isFalse);
      expect(await p1a, isNull);
      expect(await p1b, isNull);
      expect(pre2?.url, equals('https://cdn.example.com/pre2.m4a'));
      expect(service.getCachedStream('pre_2')?.url, equals(pre2!.url));

      // Failing preload swallows error cleanly
      expect(await service.preloadVideo('bad_vid'), isNull);

      // Clean up foreground
      service.cancelPlaybackProcesses();
      await expectLater(fgFuture, throwsA(isA<YtDlpException>()));
      expect(fgProc.killed, isTrue);
    });
  });

  group('FfmpegAudioProxy', () {
    test('buildFfmpegArgs includes reconnect & CRLF headers for HTTP(S) and NEVER passes -ar', () {
      final httpArgs = FfmpegAudioProxy.buildFfmpegArgs(
        sourceUrl: 'https://rr1.googlevideo.com/videoplayback?itag=251',
        headers: const {
          'User-Agent': 'LuminaTest/1.0',
          'Cookie': 'SID=abc',
        },
      );

      expect(httpArgs, containsAllInOrder(<String>['-hide_banner', '-loglevel', 'error']));
      expect(
        httpArgs,
        containsAllInOrder(<String>[
          '-reconnect',
          '1',
          '-reconnect_streamed',
          '1',
          '-reconnect_delay_max',
          '2',
        ]),
      );
      final headersIdx = httpArgs.indexOf('-headers');
      expect(headersIdx, greaterThan(0));
      expect(
        httpArgs[headersIdx + 1],
        equals('User-Agent: LuminaTest/1.0\r\nCookie: SID=abc\r\n'),
      );
      expect(
        httpArgs,
        containsAllInOrder(<String>[
          '-vn',
          '-sn',
          '-dn',
          '-c:a',
          'pcm_s24le',
          '-f',
          'wav',
          'pipe:1',
        ]),
      );
      expect(httpArgs.contains('-ar'), isFalse);

      // Non-HTTP input omits -reconnect & -headers
      final fileArgs = FfmpegAudioProxy.buildFfmpegArgs(
        sourceUrl: r'C:\temp\sample.opus',
        headers: const {'User-Agent': 'IgnoredForLocal'},
      );
      expect(fileArgs.contains('-reconnect'), isFalse);
      expect(fileArgs.contains('-headers'), isFalse);
      expect(fileArgs.contains('-ar'), isFalse);
    });

    test('real ffmpeg.exe: HEAD spawns 0 processes, GET streams 48kHz 24-bit WAV ignoring Range: 0-0, stopAll leaves 0 processes', () async {
      final ffmpegPath = _locateVendoredFfmpeg();
      if (ffmpegPath == null) {
        markTestSkipped('app/windows/vendor/bin/ffmpeg.exe not present');
        return;
      }

      final tempDir = await Directory.systemTemp.createTemp('lumina_ffmpeg_');
      addTearDown(() async {
        if (tempDir.existsSync()) await tempDir.delete(recursive: true);
      });

      // 1. Generate a real 48 kHz stereo Opus file via ffmpeg lavfi
      final shortOpus = '${tempDir.path}\\tone_48k_2s.webm';
      final genShort = await Process.run(
        ffmpegPath,
        <String>[
          '-y',
          '-hide_banner',
          '-loglevel',
          'error',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=440:sample_rate=48000:duration=2',
          '-ac',
          '2',
          '-c:a',
          'libopus',
          shortOpus,
        ],
        runInShell: false,
      );
      expect(genShort.exitCode, equals(0), reason: 'stderr: ${genShort.stderr}');
      final shortBytes = await File(shortOpus).readAsBytes();
      expect(shortBytes.length, greaterThan(100));

      // Serve the Opus file over local HTTP to verify -reconnect and -headers path too.
      String? observedHeader;
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => upstream.close(force: true));
      upstream.listen((req) async {
        observedHeader = req.headers.value('x-lumina-test');
        req.response.headers.contentType = ContentType('audio', 'webm');
        req.response.add(shortBytes);
        await req.response.close();
      });

      final service = YtDlpService(
        userBinDir: '${tempDir.path}\\user',
        bundledBinDir: File(ffmpegPath).parent.path,
        pathEnv: '',
      );
      addTearDown(() async {
        await service.stopAll();
        service.dispose();
      });
      await service.initialize();
      expect(service.status.isFfmpegAvailable, isTrue);

      final wavUrl = await service.openTranscodedWavUrl(
        sourceUrl: 'http://127.0.0.1:${upstream.port}/tone.webm',
        headers: const {'X-Lumina-Test': 'bit-perfect-48k'},
        playRequestId: 42,
      );
      expect(wavUrl, startsWith('http://127.0.0.1:'));
      expect(wavUrl, endsWith('.wav'));

      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      // 2. HEAD request -> 200 OK, audio/wav, Accept-Ranges: none, ZERO ffmpeg spawns
      final headReq = await client.headUrl(Uri.parse(wavUrl));
      final headResp = await headReq.close();
      await headResp.drain<void>();
      expect(headResp.statusCode, equals(HttpStatus.ok));
      expect(headResp.headers.value(HttpHeaders.contentTypeHeader), equals('audio/wav'));
      expect(headResp.headers.value('accept-ranges'), equals('none'));
      expect(service.ffmpegProxy.spawnCount, equals(0));

      // 3. GET with Range: bytes=0-0 (Rust HttpRangeMediaSource probe) -> 200 OK sequential WAV
      final getReq = await client.getUrl(Uri.parse(wavUrl));
      getReq.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final getResp = await getReq.close();
      expect(getResp.statusCode, equals(HttpStatus.ok));
      expect(getResp.headers.value(HttpHeaders.contentTypeHeader), equals('audio/wav'));

      final wavBuilder = BytesBuilder(copy: false);
      await for (final chunk in getResp) {
        wavBuilder.add(chunk);
      }
      final wavBytes = wavBuilder.toBytes();
      final fmt = _parseWavFmt(wavBytes);
      expect(fmt.sampleRate, equals(48000));
      expect(fmt.channels, equals(2));
      expect(fmt.bitsPerSample, equals(24));
      expect(observedHeader, equals('bit-perfect-48k'));
      expect(service.ffmpegProxy.spawnCount, equals(1));

      // Wait briefly for normal exit cleanup.
      await service.stopAll();
      expect(service.ffmpegProxy.activeProcessCount, equals(0));

      // 4. Verify mid-stream cancellation leaves ZERO lingering ffmpeg processes.
      final longOpus = '${tempDir.path}\\tone_48k_20s.webm';
      final genLong = await Process.run(
        ffmpegPath,
        <String>[
          '-y',
          '-hide_banner',
          '-loglevel',
          'error',
          '-f',
          'lavfi',
          '-i',
          'sine=frequency=220:sample_rate=48000:duration=20',
          '-ac',
          '2',
          '-c:a',
          'libopus',
          longOpus,
        ],
        runInShell: false,
      );
      expect(genLong.exitCode, equals(0));

      final longWavUrl = await service.openTranscodedWavUrl(
        sourceUrl: longOpus,
        playRequestId: 43,
      );
      final reqLong = await client.getUrl(Uri.parse(longWavUrl));
      final respLong = await reqLong.close();
      expect(respLong.statusCode, equals(HttpStatus.ok));

      // Read first WAV chunk, then abruptly cancel playback processes.
      final firstChunkCompleter = Completer<List<int>>();
      final sub = respLong.listen(
        (chunk) {
          if (!firstChunkCompleter.isCompleted && chunk.isNotEmpty) {
            firstChunkCompleter.complete(chunk);
          }
        },
        onError: (_) {},
        cancelOnError: true,
      );
      final firstChunk = await firstChunkCompleter.future.timeout(
        const Duration(seconds: 5),
      );
      expect(ascii.decode(firstChunk.sublist(0, 4)), equals('RIFF'));

      service.cancelPlaybackProcesses();
      await sub.cancel();
      await service.stopAll();
      expect(service.ffmpegProxy.activeProcessCount, equals(0));
    });
  });

  group('Settings UI Integration (ProvidersAndRemotePanel & AboutSettingsPanel)', () {
    late Directory tempRoot;
    late Directory userDir;
    late Directory bundledDir;
    late File licenseFile;
    late HttpServer updateServer;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('lumina_ui_ytdlp_');
      userDir = await Directory('${tempRoot.path}\\user_bin').create();
      bundledDir = await Directory('${tempRoot.path}\\bundled_bin').create();

      File('${bundledDir.path}\\yt-dlp.exe').writeAsStringSync('OLD');
      File('${bundledDir.path}\\deno.exe').writeAsStringSync('DENO');
      File('${bundledDir.path}\\ffmpeg.exe').writeAsStringSync('FFMPEG');
      licenseFile = File('${tempRoot.path}\\THIRD_PARTY_LICENSES.txt')
        ..writeAsStringSync(
          'LUMINA AUDIO TEST LICENSES\n'
          '1. yt-dlp — The Unlicense\n'
          '2. Deno — MIT License\n'
          '3. FFmpeg — GNU LGPL v3\n',
        );

      final newPayload = utf8.encode('NEW-YTDLP-2026.11.05');
      final newSha = sha256.convert(newPayload).toString();
      updateServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      updateServer.listen((req) async {
        if (req.uri.path == '/releases/latest') {
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode({
              'tag_name': '2026.11.05',
              'assets': [
                {
                  'name': 'yt-dlp.exe',
                  'browser_download_url':
                      'http://127.0.0.1:${updateServer.port}/yt-dlp.exe',
                },
                {
                  'name': 'SHA2-256SUMS',
                  'browser_download_url':
                      'http://127.0.0.1:${updateServer.port}/SHA2-256SUMS',
                },
              ],
            }),
          );
          await req.response.close();
          return;
        }
        if (req.uri.path == '/yt-dlp.exe') {
          req.response.add(newPayload);
          await req.response.close();
          return;
        }
        if (req.uri.path == '/SHA2-256SUMS') {
          req.response.write('$newSha  yt-dlp.exe\n');
          await req.response.close();
          return;
        }
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
      });
    });

    tearDown(() async {
      await updateServer.close(force: true);
      if (tempRoot.existsSync()) await tempRoot.delete(recursive: true);
    });

    YtDlpService createTestService() {
      return YtDlpService(
        userBinDir: userDir.path,
        bundledBinDir: bundledDir.path,
        pathEnv: '',
        licenseFilePath: licenseFile.path,
        latestReleaseApiUri: Uri.parse(
          'http://127.0.0.1:${updateServer.port}/releases/latest',
        ),
        processStarter: (
          exe,
          args, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          mode = ProcessStartMode.normal,
        }) async {
          if (exe.endsWith('deno.exe')) {
            return _FakeProcess.immediate(stdoutText: 'deno 2.9.8 (stable)\n');
          }
          if (exe.endsWith('ffmpeg.exe')) {
            return _FakeProcess.immediate(
              stdoutText: 'ffmpeg version N-129219-g359c825152 Copyright\n',
            );
          }
          final content = File(exe).readAsStringSync();
          if (content.contains('2026.11.05')) {
            return _FakeProcess.immediate(stdoutText: '2026.11.05\n');
          }
          return _FakeProcess.immediate(stdoutText: '2026.10.26\n');
        },
      );
    }

    testWidgets('ProvidersAndRemotePanel renders yt-dlp card, updates binary, and opens license dialog', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final audioService = MockAudioService();
      addTearDown(audioService.dispose);
      final streamingManager = StreamingManager(
        credentialStore: MemorySecureCredentialStore(),
      );
      addTearDown(streamingManager.dispose);
      final ytDlpService = createTestService();
      addTearDown(ytDlpService.dispose);
      await tester.runAsync(() => ytDlpService.initialize());

      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaTokens.buildDarkTheme(),
          home: Scaffold(
            body: ProvidersAndRemotePanel(
              audioService: audioService,
              streamingManager: streamingManager,
              ytDlpService: ytDlpService,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify compact SettingsGroupCard displays yt-dlp, Deno, and FFmpeg statuses
      expect(find.byKey(const Key('yt_dlp_engine_card')), findsOneWidget);
      expect(find.text('串流解析引擎 (yt-dlp)'), findsOneWidget);
      expect(find.text('內建版 · 2026.10.26'), findsOneWidget);
      expect(find.text('已就緒 (v2.9.8)'), findsOneWidget);
      expect(find.text('已就緒'), findsOneWidget);

      // Tap update button and wait for the real loopback HTTP update to complete
      final updateBtn = find.byKey(const Key('btn_check_update_yt_dlp'));
      await tester.ensureVisible(updateBtn);
      await tester.tap(updateBtn);
      await _pumpUntil(
        tester,
        () =>
            !ytDlpService.status.isUpdating &&
            ytDlpService.status.ytDlpVersion == '2026.11.05',
      );
      await tester.pumpAndSettle();

      expect(find.text('使用者更新版 · 2026.11.05'), findsOneWidget);
      expect(find.byKey(const Key('yt_dlp_update_feedback')), findsOneWidget);
      expect(find.textContaining('2026.11.05'), findsWidgets);

      // Open license viewer dialog
      final licenseBtn = find.byKey(const Key('btn_view_yt_dlp_licenses'));
      await tester.ensureVisible(licenseBtn);
      await tester.tap(licenseBtn);
      await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('third_party_licenses_list')).evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('third_party_licenses_dialog')), findsOneWidget);
      expect(find.textContaining('LUMINA AUDIO TEST LICENSES'), findsOneWidget);
      expect(find.textContaining('yt-dlp — The Unlicense'), findsOneWidget);

      // Close license dialog
      await tester.tap(find.byKey(const Key('btn_close_licenses_dialog')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('third_party_licenses_dialog')), findsNothing);
    });

    testWidgets('AboutSettingsPanel opens shared third-party open-source license dialog', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final audioService = MockAudioService();
      addTearDown(audioService.dispose);
      final ytDlpService = createTestService();
      addTearDown(ytDlpService.dispose);
      await tester.runAsync(() => ytDlpService.initialize());

      await tester.pumpWidget(
        MaterialApp(
          theme: LuminaTokens.buildDarkTheme(),
          home: Scaffold(
            body: AboutSettingsPanel(
              audioService: audioService,
              ytDlpService: ytDlpService,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('第三方開源授權（yt-dlp / Deno / FFmpeg）'), findsOneWidget);
      final aboutBtn = find.byKey(const Key('btn_about_third_party_licenses'));
      expect(aboutBtn, findsOneWidget);

      await tester.tap(aboutBtn);
      await _pumpUntil(
        tester,
        () =>
            find.byKey(const Key('third_party_licenses_list')).evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('third_party_licenses_dialog')), findsOneWidget);
      expect(find.textContaining('FFmpeg — GNU LGPL v3'), findsOneWidget);

      await tester.tap(find.byKey(const Key('btn_close_licenses_dialog')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('third_party_licenses_dialog')), findsNothing);
    });
  });
}
