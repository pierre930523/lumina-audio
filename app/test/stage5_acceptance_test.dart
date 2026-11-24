import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/podcast_models.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/podcast_store.dart';
import 'package:lumina_app/services/streaming/providers/youtube_music_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';
import 'package:lumina_app/services/streaming/streaming_provider.dart';
import 'package:lumina_app/services/streaming/yt_dlp_service.dart';

String? _locateVendorBinDir() {
  final sep = Platform.pathSeparator;
  final cwd = Directory.current.path;
  final candidates = <String>[
    '$cwd${sep}windows${sep}vendor${sep}bin',
    '$cwd${sep}app${sep}windows${sep}vendor${sep}bin',
    '$cwd${sep}build${sep}windows${sep}x64${sep}runner${sep}Release${sep}bin',
    '$cwd${sep}app${sep}build${sep}windows${sep}x64${sep}runner${sep}Release${sep}bin',
  ];
  for (final dir in candidates) {
    if (File('$dir${sep}yt-dlp.exe').existsSync() &&
        File('$dir${sep}deno.exe').existsSync() &&
        File('$dir${sep}ffmpeg.exe').existsSync()) {
      return dir;
    }
  }
  return null;
}

String? _locateLicenseFile() {
  final sep = Platform.pathSeparator;
  final cwd = Directory.current.path;
  final candidates = <String>[
    '$cwd${sep}windows${sep}vendor${sep}bin${sep}THIRD_PARTY_LICENSES.txt',
    '$cwd${sep}app${sep}windows${sep}vendor${sep}bin${sep}THIRD_PARTY_LICENSES.txt',
    '$cwd${sep}build${sep}windows${sep}x64${sep}runner${sep}Release${sep}THIRD_PARTY_LICENSES.txt',
    '$cwd${sep}app${sep}build${sep}windows${sep}x64${sep}runner${sep}Release${sep}THIRD_PARTY_LICENSES.txt',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

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

TrackInfo _ytmTrack(String videoId, {String providerName = 'YouTube Music'}) {
  return TrackInfo(
    id: 'ytm:$videoId',
    title: 'Track $videoId',
    artist: 'Test Artist',
    album: 'Test Album',
    duration: const Duration(minutes: 3, seconds: 32),
    format: const AudioFormat(
      codec: AudioCodec.aac,
      sampleRateHz: 44100,
      bitDepth: 16,
      channels: 2,
    ),
    providerName: providerName,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  HttpOverrides? prevHttpOverrides;
  setUpAll(() {
    prevHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
  });
  tearDownAll(() {
    HttpOverrides.global = prevHttpOverrides;
  });

  group('Stage 5.1: Clean-PATH Isolated Environment & Bundled Binary Discovery', () {
    test(
      'isolated Release bundle resolves yt-dlp, deno, and ffmpeg as 內建版 with stripped PATH and reads THIRD_PARTY_LICENSES.txt',
      () async {
        final vendorDir = _locateVendorBinDir();
        final licenseSrc = _locateLicenseFile();
        if (vendorDir == null || licenseSrc == null) {
          markTestSkipped('Vendored binaries not staged; run scripts/prepare_release_deps.ps1');
          return;
        }

        final isoRoot = await Directory.systemTemp.createTemp('lumina_stage5_iso_');
        addTearDown(() async {
          if (isoRoot.existsSync()) {
            await isoRoot.delete(recursive: true);
          }
        });

        final isoBundleDir = await Directory('${isoRoot.path}\\Release').create();
        final isoBinDir = await Directory('${isoBundleDir.path}\\bin').create();
        final emptyUserBinDir = await Directory('${isoRoot.path}\\EmptyUserBin').create();

        for (final name in const <String>['yt-dlp.exe', 'deno.exe', 'ffmpeg.exe']) {
          await File('$vendorDir\\$name').copy('${isoBinDir.path}\\$name');
        }
        final isoLicenseFile =
            await File(licenseSrc).copy('${isoBundleDir.path}\\THIRD_PARTY_LICENSES.txt');

        const strippedPath = r'C:\Windows\System32;C:\Windows';
        final service = YtDlpService(
          userBinDir: emptyUserBinDir.path,
          bundledBinDir: isoBinDir.path,
          pathEnv: strippedPath,
          licenseFilePath: isoLicenseFile.path,
        );
        addTearDown(() async {
          await service.stopAll();
          service.dispose();
        });

        final status = await service.initialize();

        expect(status.isYtDlpAvailable, isTrue);
        expect(status.ytDlpSource, equals(YtDlpBinarySource.bundled));
        expect(status.ytDlpSource.label, equals('內建版'));
        expect(status.ytDlpVersion, isNotNull);
        expect(status.ytDlpVersion, isNotEmpty);

        expect(status.isDenoAvailable, isTrue);
        expect(status.denoSource, equals(YtDlpBinarySource.bundled));
        expect(status.denoVersion, isNotNull);
        expect(status.denoVersion, isNotEmpty);

        expect(status.isFfmpegAvailable, isTrue);
        expect(status.ffmpegSource, equals(YtDlpBinarySource.bundled));
        expect(status.ffmpegVersion, isNotNull);
        expect(status.ffmpegVersion, isNotEmpty);
        expect(status.ffmpegDir, equals(isoBinDir.path));

        final licenseText = await service.readThirdPartyLicenses();
        expect(licenseText, contains('yt-dlp'));
        expect(licenseText, contains('Unlicense'));
        expect(licenseText, contains('Deno'));
        expect(licenseText, contains('MIT License'));
        expect(licenseText, contains('FFmpeg'));
        expect(licenseText, contains('GNU LESSER GENERAL PUBLIC LICENSE'));
      },
    );
  });

  group('Stage 5.2: Read-Only Install Directory Update & Restart Version Comparison', () {
    test(
      'read-only bundledBinDir (attrib +R) updates atomically to userBinDir and restart selects newer version without regression',
      () async {
        final tempRoot = await Directory.systemTemp.createTemp('lumina_stage5_ro_');
        final bundledDir = await Directory('${tempRoot.path}\\ProgramFiles_Lumina_bin').create();
        final userDir = await Directory('${tempRoot.path}\\LocalAppData_Lumina_bin').create();
        final bundledExe = File('${bundledDir.path}\\yt-dlp.exe')
          ..writeAsStringSync('BUNDLED-READONLY-2026.10.26');

        // Mark bundled yt-dlp.exe strictly read-only via Windows attrib +R
        final attribOn = await Process.run(
          'attrib.exe',
          <String>['+R', bundledExe.path],
          runInShell: false,
        );
        expect(attribOn.exitCode, equals(0));

        addTearDown(() async {
          await Process.run(
            'attrib.exe',
            <String>['-R', bundledExe.path],
            runInShell: false,
          );
          if (tempRoot.existsSync()) {
            await tempRoot.delete(recursive: true);
          }
        });

        // Prove overwriting bundledExe fails with FileSystemException (simulating Program Files ACL)
        expect(
          () => bundledExe.writeAsStringSync('OVERWRITE-ATTEMPT'),
          throwsA(isA<FileSystemException>()),
        );

        final payload2099 = utf8.encode('USER-UPDATED-BINARY-2099.01.01');
        final sha2099 = sha256.convert(payload2099).toString();
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));

        server.listen((req) async {
          if (req.uri.path == '/releases/latest') {
            req.response.headers.contentType = ContentType.json;
            req.response.write(
              jsonEncode(<String, dynamic>{
                'tag_name': '2099.01.01',
                'assets': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'name': 'yt-dlp.exe',
                    'browser_download_url':
                        'http://127.0.0.1:${server.port}/yt-dlp.exe',
                  },
                  <String, dynamic>{
                    'name': 'SHA2-256SUMS',
                    'browser_download_url':
                        'http://127.0.0.1:${server.port}/SHA2-256SUMS',
                  },
                ],
              }),
            );
            await req.response.close();
            return;
          }
          if (req.uri.path == '/yt-dlp.exe') {
            req.response.add(payload2099);
            await req.response.close();
            return;
          }
          if (req.uri.path == '/SHA2-256SUMS') {
            req.response.write('$sha2099  yt-dlp.exe\n');
            await req.response.close();
            return;
          }
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
        });

        Future<Process> fakeProcessStarter(
          String exe,
          List<String> args, {
          String? workingDirectory,
          Map<String, String>? environment,
          bool includeParentEnvironment = true,
          bool runInShell = false,
          ProcessStartMode mode = ProcessStartMode.normal,
        }) async {
          expect(runInShell, isFalse);
          final text = File(exe).readAsStringSync();
          String ver = '2026.10.26';
          if (text.contains('2100.01.01')) {
            ver = '2100.01.01';
          } else if (text.contains('2099.01.01')) {
            ver = '2099.01.01';
          }
          return Process.start(
            'cmd.exe',
            <String>['/c', 'echo $ver'],
            runInShell: false,
          );
        }

        // 1. Initial launch & in-app update with read-only bundledBinDir
        final service1 = YtDlpService(
          userBinDir: userDir.path,
          bundledBinDir: bundledDir.path,
          pathEnv: '',
          latestReleaseApiUri: Uri.parse(
            'http://127.0.0.1:${server.port}/releases/latest',
          ),
          processStarter: fakeProcessStarter,
        );
        addTearDown(service1.dispose);

        await service1.initialize();
        expect(service1.status.ytDlpSource, equals(YtDlpBinarySource.bundled));
        expect(service1.status.ytDlpVersion, equals('2026.10.26'));

        final upd = await service1.checkAndUpdateYtDlp();
        expect(upd.isUpdated, isTrue);
        expect(upd.latestVersion, equals('2099.01.01'));
        expect(bundledExe.readAsStringSync(), equals('BUNDLED-READONLY-2026.10.26'));
        expect(File('${userDir.path}\\yt-dlp.exe').existsSync(), isTrue);
        expect(File('${userDir.path}\\yt-dlp.exe.tmp').existsSync(), isFalse);

        // 2. Simulate app restart: picks userUpdated (2099.01.01 > 2026.10.26)
        final service2 = YtDlpService(
          userBinDir: userDir.path,
          bundledBinDir: bundledDir.path,
          pathEnv: '',
          processStarter: fakeProcessStarter,
        );
        addTearDown(service2.dispose);
        final statusAfterRestart = await service2.initialize();
        expect(statusAfterRestart.ytDlpSource, equals(YtDlpBinarySource.userUpdated));
        expect(statusAfterRestart.ytDlpVersion, equals('2099.01.01'));

        // 3. Simulate installer upgrade where bundled (2100.01.01) > userUpdated (2099.01.01)
        await Process.run('attrib.exe', <String>['-R', bundledExe.path], runInShell: false);
        bundledExe.writeAsStringSync('BUNDLED-UPGRADED-2100.01.01');
        await Process.run('attrib.exe', <String>['+R', bundledExe.path], runInShell: false);

        final service3 = YtDlpService(
          userBinDir: userDir.path,
          bundledBinDir: bundledDir.path,
          pathEnv: '',
          processStarter: fakeProcessStarter,
        );
        addTearDown(service3.dispose);
        final statusAfterUpgrade = await service3.initialize();
        expect(statusAfterUpgrade.ytDlpSource, equals(YtDlpBinarySource.bundled));
        expect(statusAfterUpgrade.ytDlpVersion, equals('2100.01.01'));
      },
    );
  });

  group('Stage 5.3 & 5.4: Live Dual-Track Playback, Podcast Resolution & Rapid 5-Track Switch', () {
    test(
      'Guest Mode live YouTube Music search, track resolve, Podcast explore/detail/episode resolve, and rapid 5-track switch with 0 zombie processes',
      () async {
        final vendorDir = _locateVendorBinDir();
        if (vendorDir == null) {
          markTestSkipped('Vendored binaries not staged');
          return;
        }

        final tempRoot = await Directory.systemTemp.createTemp('lumina_stage5_live_');
        addTearDown(() async {
          if (tempRoot.existsSync()) {
            await tempRoot.delete(recursive: true);
          }
        });

        final ytDlpService = YtDlpService(
          userBinDir: '${tempRoot.path}\\empty_user_bin',
          bundledBinDir: vendorDir,
          pathEnv: r'C:\Windows\System32;C:\Windows',
          resolveTimeout: const Duration(seconds: 25),
        );
        addTearDown(() async {
          await ytDlpService.stopAll();
          ytDlpService.dispose();
        });
        await ytDlpService.initialize();

        final store = MemorySecureCredentialStore();
        final ytm = YouTubeMusicProvider(
          credentialStore: store,
          ytDlpService: ytDlpService,
        );
        final manager = StreamingManager(
          credentialStore: store,
          ytDlpService: ytDlpService,
          providers: <String, StreamingProvider>{'youtube_music': ytm},
        );
        addTearDown(manager.dispose);

        // 1. Live Guest Mode YouTube Music search (no login)
        final searchCatalog = await ytm.search('Rick Astley Never Gonna Give You Up');
        expect(searchCatalog.tracks, isNotEmpty);

        // 2. Live Guest Mode YouTube Music track stream resolution via bundled yt-dlp + deno
        final resolvedTrack = await ytm.resolveStream(
          _ytmTrack('dQw4w9WgXcQ'),
          playRequestId: 501,
          timeout: const Duration(seconds: 25),
        );
        expect(resolvedTrack.url, contains('googlevideo.com'));
        expect(resolvedTrack.headers['User-Agent'], isNotNull);
        expect(resolvedTrack.headers['User-Agent'], isNotEmpty);
        expect(resolvedTrack.format.codec, equals(AudioCodec.aac));
        expect(resolvedTrack.hintExtension, equals('m4a'));
        expect(resolvedTrack.format.sampleRateHz, greaterThan(0));

        // 3. Live YouTube Music Podcast explore -> show detail -> episode stream resolution
        final explorePodcasts = await ytm.fetchExplorePodcasts();
        expect(explorePodcasts.shows, isNotEmpty);
        final firstShow = explorePodcasts.shows.first;
        expect(firstShow.id, startsWith('MPSP'));
        expect(firstShow.artworkUrl, isNotNull);
        expect(firstShow.artworkUrl, startsWith('https://'));

        final showDetail = await ytm.fetchPodcastShowDetail(firstShow.id);
        expect(showDetail.episodes, isNotEmpty);
        final firstEpisode = showDetail.episodes.first;
        expect(firstEpisode.videoId.length, equals(11));

        final episodeStream = await manager.resolveStreamForTrack(
          firstEpisode.toTrack(),
          playRequestId: 502,
          timeout: const Duration(seconds: 25),
        );
        expect(episodeStream.url, isNotEmpty);
        expect(episodeStream.format.sampleRateHz, greaterThan(0));

        // 4. Rapid 5-track switching while real yt-dlp.exe processes are spawned
        //    Clear cache first so real yt-dlp.exe child processes are actually launched and killed!
        ytDlpService.clearCache();
        final audio = MockAudioService();
        addTearDown(audio.dispose);
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          ytDlpService: ytDlpService,
          resolveTimeout: const Duration(seconds: 25),
          debounceDelay: Duration.zero,
        );
        addTearDown(coordinator.dispose);

        final rapidTracks = <TrackInfo>[
          _ytmTrack('dQw4w9WgXcQ'),
          _ytmTrack('DYptgVvkVLQ'),
          _ytmTrack('YhiQDARUJ7Y'),
          _ytmTrack('9bZkp7q19f0'),
          _ytmTrack('kJQP7kiw5Fk'),
        ];

        for (var i = 0; i < 4; i++) {
          unawaited(coordinator.playTrack(rapidTracks[i], queueContext: rapidTracks));
          await Future<void>.delayed(const Duration(milliseconds: 60));
        }
        await coordinator.playTrack(rapidTracks[4], queueContext: rapidTracks);

        expect(audio.currentState.status, equals(PlaybackStatus.playing));
        expect(audio.currentState.track?.id, equals('ytm:kJQP7kiw5Fk'));

        await ytDlpService.stopAll();
        expect(ytDlpService.ffmpegProxy.activeProcessCount, equals(0));
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );

    test(
      'FFmpeg fallback proxy transcodes Opus to 48 kHz 24-bit WAV and stopFfmpegProxy kills ffmpeg.exe immediately',
      () async {
        final vendorDir = _locateVendorBinDir();
        if (vendorDir == null) {
          markTestSkipped('Vendored binaries not staged');
          return;
        }

        final tempDir = await Directory.systemTemp.createTemp('lumina_stage5_ff_');
        addTearDown(() async {
          if (tempDir.existsSync()) {
            await tempDir.delete(recursive: true);
          }
        });

        final ffmpegExe = '$vendorDir\\ffmpeg.exe';
        final opusFile = '${tempDir.path}\\stage5_opus_48k.webm';
        final gen = await Process.run(
          ffmpegExe,
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
            opusFile,
          ],
          runInShell: false,
        );
        expect(gen.exitCode, equals(0));

        final ytDlpService = YtDlpService(
          userBinDir: '${tempDir.path}\\user',
          bundledBinDir: vendorDir,
          pathEnv: r'C:\Windows\System32;C:\Windows',
        );
        addTearDown(() async {
          await ytDlpService.stopAll();
          ytDlpService.dispose();
        });
        await ytDlpService.initialize();

        final wavUrl = await ytDlpService.openTranscodedWavUrl(
          sourceUrl: opusFile,
          playRequestId: 601,
        );
        final client = HttpClient();
        addTearDown(() => client.close(force: true));

        final req = await client.getUrl(Uri.parse(wavUrl));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
        final resp = await req.close();
        expect(resp.statusCode, equals(HttpStatus.ok));

        final builder = BytesBuilder(copy: false);
        await for (final chunk in resp) {
          builder.add(chunk);
        }
        final fmt = _parseWavFmt(builder.toBytes());
        expect(fmt.sampleRate, equals(48000));
        expect(fmt.bitsPerSample, equals(24));
        expect(fmt.channels, equals(2));

        ytDlpService.stopFfmpegProxy();
        await ytDlpService.stopAll();
        expect(ytDlpService.ffmpegProxy.activeProcessCount, equals(0));
      },
    );

    test(
      'Podcast zero-mock source verification, progress persistence, and -15s / +30s seek clamping',
      () async {
        final podcastsSource =
            File('lib/ui/podcasts/podcasts_view.dart').readAsStringSync();
        expect(podcastsSource.contains('法客電台'), isFalse);
        expect(podcastsSource.contains('The Vergecast'), isFalse);

        final tempDir = await Directory.systemTemp.createTemp('lumina_stage5_pod_');
        addTearDown(() async {
          if (tempDir.existsSync()) {
            await tempDir.delete(recursive: true);
          }
        });
        final stateFile = File('${tempDir.path}\\podcast_state.json');
        final store = PodcastStore(storageFile: stateFile);
        addTearDown(store.dispose);

        await store.addBookmark(
          const PodcastShow(
            id: 'MPSPPL_stage5_show',
            title: 'Stage 5 Audio Show',
            author: 'Lumina Engineering',
          ),
        );
        store.updateProgress(
          videoId: 'dQw4w9WgXcQ',
          position: const Duration(seconds: 95),
          duration: const Duration(seconds: 600),
          immediate: true,
        );

        final reloaded = PodcastStore(storageFile: stateFile)..loadSync();
        addTearDown(reloaded.dispose);
        expect(reloaded.isBookmarked('MPSPPL_stage5_show'), isTrue);
        expect(reloaded.progressFor('dQw4w9WgXcQ')?.positionSeconds, equals(95));

        expect(
          PodcastPlaybackTracker.computeClampedSeek(
            currentPosition: const Duration(seconds: 8),
            trackDuration: const Duration(seconds: 100),
            delta: PodcastPlaybackTracker.skipBackwardDelta,
          ),
          equals(Duration.zero),
        );
        expect(
          PodcastPlaybackTracker.computeClampedSeek(
            currentPosition: const Duration(seconds: 85),
            trackDuration: const Duration(seconds: 100),
            delta: PodcastPlaybackTracker.skipForwardDelta,
          ),
          equals(const Duration(seconds: 100)),
        );
      },
    );
  });
}
