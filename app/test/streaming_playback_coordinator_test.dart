import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/models/streaming_provider_meta.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/ffi_audio_service.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/streaming/providers/youtube_music_provider.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_playback_coordinator.dart';
import 'package:lumina_app/services/streaming/streaming_provider.dart';
import 'package:lumina_app/services/streaming/yt_dlp_service.dart';
import 'package:lumina_app/ui/mini_player/playback_controls.dart';
import 'package:material_ui/material_ui.dart';

class _FakeStreamingProvider implements StreamingProvider {
  @override
  final String kind;

  @override
  final StreamingProviderMeta meta;

  @override
  StreamingAuthState authState = StreamingAuthState.connected;

  @override
  StreamingAccountInfo? accountInfo;

  @override
  String? lastError;

  @override
  StreamingCatalog catalog = StreamingCatalog.empty();

  @override
  bool get supportsGuestMode => false;

  final List<String> resolvedIds = [];
  final List<CancellationToken?> seenTokens = [];
  int? lastPlayRequestId;
  Future<ResolvedStreamResult> Function(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
  })? onResolve;

  _FakeStreamingProvider(this.kind)
      : meta = StreamingProviderMeta.byKind(kind)!;

  @override
  Future<void> restoreFromStorage() async {}

  @override
  Future<void> authenticate(
    Map<String, dynamic> params, {
    CancellationToken? cancel,
    void Function(String statusMsg)? onProgress,
  }) async {}

  @override
  Future<void> refreshSessionIfNeeded() async {}

  @override
  Future<void> logout() async {}

  @override
  Future<StreamingCatalog> syncLibrary({CancellationToken? cancel}) async =>
      catalog;

  @override
  Future<StreamingRecommendations> fetchRecommendations({
    CancellationToken? cancel,
    bool forceRefresh = false,
    int batchIndex = 0,
    Set<String> excludeAlbumIds = const <String>{},
    Set<String> excludeTrackIds = const <String>{},
  }) async =>
      StreamingRecommendations.empty(kind);

  @override
  Future<CanonicalAlbumDetail?> fetchAlbumDetail(
    String albumId, {
    CancellationToken? cancel,
  }) async =>
      null;

  @override
  Future<List<TrackInfo>> fetchPlaylistTracks(String playlistId) async =>
      const [];

  @override
  Future<StreamingCatalog> search(
    String query, {
    CancellationToken? cancel,
  }) async =>
      catalog;

  @override
  Future<ResolvedStreamResult> resolveStream(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
  }) async {
    resolvedIds.add(track.id);
    seenTokens.add(cancel);
    lastPlayRequestId = playRequestId;
    if (onResolve != null) {
      return onResolve!(track, cancel: cancel, timeout: timeout);
    }
    return ResolvedStreamResult(
      url: 'https://cdn.example.com/${track.id}.flac',
      hintExtension: 'flac',
      format: const AudioFormat(
        codec: AudioCodec.flac,
        sampleRateHz: 96000,
        bitDepth: 24,
        channels: 2,
      ),
    );
  }
}

class _RecordedStreamPlay {
  final TrackInfo track;
  final String streamUrl;
  final Map<String, String> headers;
  final String? hintExtension;
  final int requestId;

  const _RecordedStreamPlay({
    required this.track,
    required this.streamUrl,
    required this.headers,
    required this.hintExtension,
    required this.requestId,
  });
}

class _SpyAudioService extends MockAudioService {
  final List<(String trackId, int requestId)> asyncPlayCalls = [];
  final List<_RecordedStreamPlay> recordedPlays = [];
  final StreamController<PlaybackState> _extraStateController =
      StreamController<PlaybackState>.broadcast();
  StreamSubscription<PlaybackState>? _forwardSub;
  bool _forwardingInit = false;

  Future<void> Function(
    TrackInfo track,
    String streamUrl,
    Map<String, String> headers,
    String? hintExtension,
    int requestId,
  )? onPlayStreamUrlAsync;
  int cancelPendingCalls = 0;

  @override
  Stream<PlaybackState> get stateStream {
    if (!_forwardingInit) {
      _forwardingInit = true;
      _forwardSub = super.stateStream.listen((s) {
        if (!_extraStateController.isClosed) {
          _extraStateController.add(s);
        }
      });
    }
    return _extraStateController.stream;
  }

  void emitRawStateForTest(PlaybackState state) {
    if (!_extraStateController.isClosed) {
      _extraStateController.add(state);
    }
  }

  @override
  void dispose() {
    unawaited(_forwardSub?.cancel());
    unawaited(_extraStateController.close());
    super.dispose();
  }

  @override
  Future<void> cancelPendingPlayback() async {
    cancelPendingCalls++;
    await super.cancelPendingPlayback();
  }

  @override
  Future<void> playStreamUrlAsync({
    required TrackInfo track,
    required String streamUrl,
    Map<String, String> headers = const {},
    String? hintExtension,
    required int requestId,
  }) async {
    asyncPlayCalls.add((track.id, requestId));
    recordedPlays.add(
      _RecordedStreamPlay(
        track: track,
        streamUrl: streamUrl,
        headers: Map<String, String>.from(headers),
        hintExtension: hintExtension,
        requestId: requestId,
      ),
    );
    await super.playStreamUrlAsync(
      track: track,
      streamUrl: streamUrl,
      headers: headers,
      hintExtension: hintExtension,
      requestId: requestId,
    );
    if (onPlayStreamUrlAsync != null) {
      await onPlayStreamUrlAsync!(
        track,
        streamUrl,
        headers,
        hintExtension,
        requestId,
      );
    }
  }
}

class _FakeFfmpegProcess implements Process {
  @override
  final int pid;
  final StreamController<List<int>> _stdoutCtrl =
      StreamController<List<int>>();
  final StreamController<List<int>> _stderrCtrl =
      StreamController<List<int>>();
  final Completer<int> _exitCompleter = Completer<int>();
  bool killed = false;

  _FakeFfmpegProcess({this.pid = 7001}) {
    scheduleMicrotask(() {
      if (!killed && !_stdoutCtrl.isClosed) {
        // Emit a minimal RIFF prefix so HttpServer flushes 200 OK headers while
        // keeping the fake ffmpeg stream alive until kill() is called.
        _stdoutCtrl.add(const <int>[0x52, 0x49, 0x46, 0x46]);
      }
    });
  }

  @override
  Future<int> get exitCode => _exitCompleter.future;

  @override
  Stream<List<int>> get stdout => _stdoutCtrl.stream;

  @override
  Stream<List<int>> get stderr => _stderrCtrl.stream;

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (killed) return false;
    killed = true;
    if (!_stdoutCtrl.isClosed) unawaited(_stdoutCtrl.close());
    if (!_stderrCtrl.isClosed) unawaited(_stderrCtrl.close());
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(-1);
    return true;
  }
}

class _FailingFfmpegProcess implements Process {
  @override
  final int pid = 7999;
  final StreamController<List<int>> _stdoutCtrl =
      StreamController<List<int>>();
  final StreamController<List<int>> _stderrCtrl =
      StreamController<List<int>>();
  final Completer<int> _exitCompleter = Completer<int>();

  _FailingFfmpegProcess({required String stderrText}) {
    scheduleMicrotask(() {
      if (!_stderrCtrl.isClosed) {
        _stderrCtrl.add(utf8.encode(stderrText));
        unawaited(_stderrCtrl.close());
      }
      if (!_stdoutCtrl.isClosed) unawaited(_stdoutCtrl.close());
      if (!_exitCompleter.isCompleted) _exitCompleter.complete(1);
    });
  }

  @override
  Future<int> get exitCode => _exitCompleter.future;

  @override
  Stream<List<int>> get stdout => _stdoutCtrl.stream;

  @override
  Stream<List<int>> get stderr => _stderrCtrl.stream;

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_stdoutCtrl.isClosed) unawaited(_stdoutCtrl.close());
    if (!_stderrCtrl.isClosed) unawaited(_stderrCtrl.close());
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(-1);
    return true;
  }
}

class _ControllableYtDlpService extends YtDlpService {
  final List<({String videoId, bool bypassCache, int playRequestId})>
      resolveCalls = [];
  final List<({String executable, List<String> args, bool runInShell})>
      ffmpegSpawns = [];
  final List<_FakeFfmpegProcess> spawnedFfmpegProcesses = [];
  final List<int?> stopFfmpegExceptRequestIds = [];
  int stopFfmpegCalls = 0;

  Future<YtDlpResolvedStream> Function(
    String videoId, {
    required int playRequestId,
    bool bypassCache,
  })? onResolveVideo;

  final DateTime Function() _testClock;

  _ControllableYtDlpService({
    required super.userBinDir,
    required super.bundledBinDir,
    super.clock,
  }) : _testClock = clock ?? DateTime.now;

  @override
  FfmpegAudioProxy get ffmpegProxy => _proxy ??= FfmpegAudioProxy(
        ffmpegPathProvider: () => '${Directory.current.path}\\ffmpeg.exe',
        processStarter: (
          executable,
          arguments, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
          runInShell = false,
          mode = ProcessStartMode.normal,
        }) async {
          ffmpegSpawns.add((
            executable: executable,
            args: List<String>.from(arguments),
            runInShell: runInShell,
          ));
          final proc = _FakeFfmpegProcess(pid: 7000 + ffmpegSpawns.length);
          spawnedFfmpegProcesses.add(proc);
          return proc;
        },
      );

  FfmpegAudioProxy? _proxy;

  @override
  Future<String> openTranscodedWavUrl({
    required String sourceUrl,
    Map<String, String> headers = const {},
    required int playRequestId,
  }) {
    return ffmpegProxy.openTranscodedWavUrl(
      sourceUrl: sourceUrl,
      headers: headers,
      playRequestId: playRequestId,
    );
  }

  @override
  Future<String> openDashMpdUrl({
    required String mpdXml,
    required int playRequestId,
    bool copyFlac = true,
  }) {
    return ffmpegProxy.openDashMpdUrl(
      mpdXml: mpdXml,
      playRequestId: playRequestId,
      copyFlac: copyFlac,
    );
  }

  @override
  void cancelPlaybackProcesses({int? exceptRequestId}) {
    super.cancelPlaybackProcesses(exceptRequestId: exceptRequestId);
    _proxy?.cancel(exceptRequestId: exceptRequestId);
  }

  @override
  void stopFfmpegProxy({int? exceptRequestId}) {
    stopFfmpegCalls++;
    stopFfmpegExceptRequestIds.add(exceptRequestId);
    super.stopFfmpegProxy(exceptRequestId: exceptRequestId);
    _proxy?.cancel(exceptRequestId: exceptRequestId);
  }

  @override
  Future<void> stopAll({
    Duration waitTimeout = const Duration(seconds: 2),
  }) async {
    await (_proxy?.stopAll(waitTimeout: waitTimeout) ?? Future<void>.value());
    await super.stopAll(waitTimeout: waitTimeout);
  }

  @override
  void dispose() {
    unawaited(_proxy?.dispose());
    super.dispose();
  }

  @override
  Future<YtDlpResolvedStream> resolveVideo(
    String videoId, {
    required int playRequestId,
    String? cookiesFilePath,
    bool bypassCache = false,
    String? formatSelector,
    String? extractorArgs,
    String? remoteComponents,
  }) async {
    if (bypassCache) {
      clearCache(videoId);
    } else {
      final cached = getCachedStream(videoId);
      if (cached != null) {
        return cached;
      }
    }
    resolveCalls.add((
      videoId: videoId,
      bypassCache: bypassCache,
      playRequestId: playRequestId,
    ));
    final result = await onResolveVideo!(
      videoId,
      playRequestId: playRequestId,
      bypassCache: bypassCache,
    );
    if (!result.isExpiredAt(_testClock())) {
      _seededCache[videoId] = result;
    }
    return result;
  }

  final Map<String, YtDlpResolvedStream> _seededCache = {};

  void seedCache(YtDlpResolvedStream stream) {
    _seededCache[stream.videoId] = stream;
  }

  @override
  YtDlpResolvedStream? getCachedStream(String videoId) {
    final key = videoId.trim();
    final entry = _seededCache[key];
    if (entry == null) return null;
    if (entry.isExpiredAt(_testClock())) {
      _seededCache.remove(key);
      return null;
    }
    return entry;
  }

  @override
  void clearCache([String? videoId]) {
    if (videoId == null) {
      _seededCache.clear();
    } else {
      _seededCache.remove(videoId.trim());
    }
    super.clearCache(videoId);
  }
}

Uint8List _buildTestWavBytes({int sampleRate = 8000, int durationMs = 200}) {
  final numSamples = (sampleRate * durationMs) ~/ 1000;
  final dataSize = numSamples * 2;
  final totalSize = 44 + dataSize;
  final bd = ByteData(totalSize);
  void writeAscii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      bd.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  writeAscii(0, 'RIFF');
  bd.setUint32(4, totalSize - 8, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little);
  bd.setUint16(22, 1, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, sampleRate * 2, Endian.little);
  bd.setUint16(32, 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  writeAscii(36, 'data');
  bd.setUint32(40, dataSize, Endian.little);
  for (var i = 0; i < numSamples; i++) {
    final v = ((i % 20) < 10) ? 4000 : -4000;
    bd.setInt16(44 + i * 2, v, Endian.little);
  }
  return bd.buffer.asUint8List();
}

class _RealTestHttpOverrides extends HttpOverrides {}

TrackInfo _track(
  String id, {
  String? providerName,
  Duration duration = const Duration(minutes: 3),
}) {
  final inferredProvider = providerName ??
      switch (id.split(':').first) {
        'ytm' => 'YouTube Music',
        'tidal' => 'Tidal',
        'qobuz' => 'Qobuz',
        'deezer' => 'Deezer',
        'apple' => 'Apple Music',
        _ => 'Qobuz',
      };
  return TrackInfo(
    id: id,
    title: 'Title $id',
    artist: 'Artist $id',
    album: 'Album $id',
    duration: duration,
    format: const AudioFormat(
      codec: AudioCodec.flac,
      sampleRateHz: 44100,
      bitDepth: 16,
      channels: 2,
    ),
    providerName: inferredProvider,
  );
}

void main() {
  group('StreamingPlaybackCoordinator', () {
    test(
      'emits optimistic loading state immediately and supersedes hung request cleanly',
      () async {
        final audio = _SpyAudioService();
        final qobuz = _FakeStreamingProvider('qobuz');
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          providers: {'qobuz': qobuz},
        );
        final slowCompleter = Completer<ResolvedStreamResult>();
        qobuz.onResolve = (track, {cancel, timeout}) {
          if (track.id == 'qobuz:slow') {
            return slowCompleter.future;
          }
          return Future.value(
            ResolvedStreamResult(
              url: 'https://cdn.example.com/fast.flac',
              hintExtension: 'flac',
              format: const AudioFormat(
                codec: AudioCodec.flac,
                sampleRateHz: 96000,
                bitDepth: 24,
                channels: 2,
              ),
            ),
          );
        };

        final statuses = <PlaybackStatus>[];
        final sub = audio.stateStream.listen((s) => statuses.add(s.status));

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
        );

        final slowFuture = coordinator.playTrack(_track('qobuz:slow'));
        expect(audio.currentState.status, PlaybackStatus.loading);
        expect(audio.currentState.track?.id, 'qobuz:slow');

        // Immediately switch to fast track while slow is stalled.
        await coordinator.playTrack(_track('qobuz:fast'));
        expect(qobuz.seenTokens.first?.isCancelled, isTrue);
        expect(audio.cancelPendingCalls, greaterThanOrEqualTo(2));
        expect(audio.currentState.status, PlaybackStatus.playing);
        expect(audio.currentState.track?.id, 'qobuz:fast');
        expect(audio.asyncPlayCalls, [('qobuz:fast', 2)]);

        // Late resolution of slow track must be discarded silently.
        slowCompleter.complete(
          ResolvedStreamResult(
            url: 'https://cdn.example.com/slow.flac',
            hintExtension: 'flac',
            format: const AudioFormat(
              codec: AudioCodec.flac,
              sampleRateHz: 44100,
              bitDepth: 16,
              channels: 2,
            ),
          ),
        );
        await slowFuture;
        expect(audio.currentState.track?.id, 'qobuz:fast');
        expect(audio.asyncPlayCalls.length, 1);
        expect(statuses, contains(PlaybackStatus.loading));

        await sub.cancel();
        coordinator.dispose();
        manager.dispose();
        audio.dispose();
      },
    );

    test(
      'debounces rapid next() skipping so only the final track resolves over network',
      () async {
        final audio = _SpyAudioService();
        final tidal = _FakeStreamingProvider('tidal');
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          providers: {'tidal': tidal},
        );
        final queue = [
          _track('tidal:1', providerName: 'Tidal'),
          _track('tidal:2', providerName: 'Tidal'),
          _track('tidal:3', providerName: 'Tidal'),
          _track('tidal:4', providerName: 'Tidal'),
        ];

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          debounceDelay: const Duration(milliseconds: 60),
        );

        await coordinator.playTrack(queue[0], queueContext: queue);
        expect(tidal.resolvedIds, ['tidal:1']);

        // 3 rapid skips within debounce window.
        unawaited(audio.next());
        unawaited(audio.next());
        final lastSkip = audio.next();

        // UI tracks the final track optimistically right away in Loading state.
        expect(audio.currentState.track?.id, 'tidal:4');
        expect(audio.currentState.status, PlaybackStatus.loading);

        await lastSkip;
        expect(tidal.resolvedIds, ['tidal:1', 'tidal:4']);
        expect(audio.currentState.status, PlaybackStatus.playing);
        expect(audio.currentState.track?.id, 'tidal:4');

        coordinator.dispose();
        manager.dispose();
        audio.dispose();
      },
    );

    test(
      'enforces per-provider cache TTL (YTM expire-60s / 45m, Tidal/Qobuz/Deezer 10m, Apple 30m)',
      () async {
        var now = DateTime.utc(2026, 1, 1, 12, 0, 0);
        final ytm = _FakeStreamingProvider('youtube_music');
        final tidal = _FakeStreamingProvider('tidal');
        final apple = _FakeStreamingProvider('apple_music');
        final expireEpoch =
            now.add(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000;

        ytm.onResolve = (track, {cancel, timeout}) async => ResolvedStreamResult(
              url: track.id == 'ytm:exp'
                  ? 'https://rr1.googlevideo.com/videoplayback?expire=$expireEpoch'
                  : 'https://rr1.googlevideo.com/videoplayback?id=noexp',
              hintExtension: 'm4a',
              format: const AudioFormat(
                codec: AudioCodec.aac,
                sampleRateHz: 44100,
                bitDepth: 16,
                channels: 2,
              ),
            );

        final audio = _SpyAudioService();
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          providers: {
            'youtube_music': ytm,
            'tidal': tidal,
            'apple_music': apple,
          },
        );

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          clock: () => now,
        );

        // YTM with expire=5m -> cached for 4m (expire - 60s).
        await coordinator.playTrack(_track('ytm:exp'));
        await coordinator.playTrack(_track('ytm:exp'));
        expect(ytm.resolvedIds, ['ytm:exp']);

        now = now.add(const Duration(minutes: 4, seconds: 1));
        await coordinator.playTrack(_track('ytm:exp'));
        expect(ytm.resolvedIds, ['ytm:exp', 'ytm:exp']);

        // YTM without expire= -> fallback 45m.
        await coordinator.playTrack(_track('ytm:fallback'));
        now = now.add(const Duration(minutes: 44));
        await coordinator.playTrack(_track('ytm:fallback'));
        expect(ytm.resolvedIds.where((id) => id == 'ytm:fallback').length, 1);
        now = now.add(const Duration(minutes: 2));
        await coordinator.playTrack(_track('ytm:fallback'));
        expect(ytm.resolvedIds.where((id) => id == 'ytm:fallback').length, 2);

        // Tidal -> 10m TTL.
        await coordinator.playTrack(_track('tidal:t1'));
        now = now.add(const Duration(minutes: 9));
        await coordinator.playTrack(_track('tidal:t1'));
        expect(tidal.resolvedIds.length, 1);
        now = now.add(const Duration(minutes: 2));
        await coordinator.playTrack(_track('tidal:t1'));
        expect(tidal.resolvedIds.length, 2);

        // Apple -> 30m TTL.
        await coordinator.playTrack(_track('apple:a1'));
        now = now.add(const Duration(minutes: 29));
        await coordinator.playTrack(_track('apple:a1'));
        expect(apple.resolvedIds.length, 1);
        now = now.add(const Duration(minutes: 2));
        await coordinator.playTrack(_track('apple:a1'));
        expect(apple.resolvedIds.length, 2);

        coordinator.dispose();
        manager.dispose();
        audio.dispose();
      },
    );

    test(
      'pre-resolves next queue track silently within 15s of track end without spamming',
      () async {
        final audio = _SpyAudioService();
        final deezer = _FakeStreamingProvider('deezer');
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          providers: {'deezer': deezer},
        );
        final queue = [
          _track(
            'deezer:1',
            providerName: 'Deezer',
            duration: const Duration(seconds: 120),
          ),
          _track(
            'deezer:2',
            providerName: 'Deezer',
            duration: const Duration(seconds: 180),
          ),
        ];

        var errorCalls = 0;
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          onError: (_, _, _) => errorCalls++,
        );

        await coordinator.playTrack(queue[0], queueContext: queue);
        expect(deezer.resolvedIds, ['deezer:1']);

        // Seeking before the 15s threshold does not pre-resolve yet.
        await audio.seek(const Duration(seconds: 90));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(deezer.resolvedIds, ['deezer:1']);

        // Entering last 15s pre-resolves deezer:2 silently once.
        await audio.seek(const Duration(seconds: 106));
        await audio.seek(const Duration(seconds: 110));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(deezer.resolvedIds, ['deezer:1', 'deezer:2']);
        expect(errorCalls, 0);

        // Transitioning to deezer:2 reuses warm pre-resolved cache immediately.
        await coordinator.playTrack(queue[1]);
        expect(deezer.resolvedIds, ['deezer:1', 'deezer:2']);

        coordinator.dispose();
        manager.dispose();
        audio.dispose();
      },
    );

    test(
      'fails optimistically on timeout and clears error on subsequent track load',
      () async {
        final audio = _SpyAudioService();
        final qobuz = _FakeStreamingProvider('qobuz');
        qobuz.onResolve = (track, {cancel, timeout}) async {
          if (track.id == 'qobuz:hang') {
            await Future<void>.delayed(const Duration(seconds: 2));
          }
          return ResolvedStreamResult(
            url: 'https://cdn.example.com/${track.id}.flac',
            hintExtension: 'flac',
            format: const AudioFormat(
              codec: AudioCodec.flac,
              sampleRateHz: 44100,
              bitDepth: 16,
              channels: 2,
            ),
          );
        };
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          providers: {'qobuz': qobuz},
        );
        final errors = <String>[];

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          resolveTimeout: const Duration(milliseconds: 50),
          onError: (_, msg, _) => errors.add(msg),
        );

        await coordinator.playTrack(_track('qobuz:hang'));
        expect(audio.currentState.status, PlaybackStatus.error);
        expect(errors.length, 1);

        await coordinator.playTrack(_track('qobuz:ok'));
        expect(audio.currentState.status, PlaybackStatus.playing);
        expect(audio.currentState.lastError, isNull);

        coordinator.dispose();
        manager.dispose();
        audio.dispose();
      },
    );

    test(
      'evicts cached URL and fires onError once when async native playback emits PlaybackStatus.error',
      () async {
        final audio = _SpyAudioService();
        final qobuz = _FakeStreamingProvider('qobuz');
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          providers: {'qobuz': qobuz},
        );
        final errors = <String>[];
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          onError: (_, msg, _) => errors.add(msg),
        );

        final track = _track('qobuz:badurl');
        await coordinator.playTrack(track);
        expect(qobuz.resolvedIds, ['qobuz:badurl']);
        expect(coordinator.getCachedStream('qobuz:badurl'), isNotNull);

        // Simulate Rust failing asynchronously after accepting the URL.
        audio.failOptimisticTrackLoad(track, 'HTTP 403 Forbidden');
        await Future<void>.delayed(Duration.zero);

        expect(coordinator.getCachedStream('qobuz:badurl'), isNull);
        expect(errors, ['HTTP 403 Forbidden']);

        // Retrying must resolve freshly instead of reusing the evicted URL.
        await coordinator.playTrack(track);
        expect(qobuz.resolvedIds, ['qobuz:badurl', 'qobuz:badurl']);

        coordinator.dispose();
        manager.dispose();
        audio.dispose();
      },
    );

    test(
      'routes play(track: null) and togglePlayPause() to streaming handler after stop or restorePlaybackSession',
      () async {
        final audio = _SpyAudioService();
        final tidal = _FakeStreamingProvider('tidal');
        final manager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          providers: {'tidal': tidal},
        );
        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
        );

        final track = _track('tidal:99', providerName: 'Tidal');
        await audio.restorePlaybackSession(
          track: track,
          position: const Duration(seconds: 42),
          queue: [track],
          queueIndex: 0,
        );

        await audio.togglePlayPause();
        expect(tidal.resolvedIds, ['tidal:99']);
        expect(audio.asyncPlayCalls, [('tidal:99', 1)]);
        expect(audio.currentState.status, PlaybackStatus.playing);

        await audio.stop();
        await audio.play();
        expect(audio.asyncPlayCalls, [('tidal:99', 1), ('tidal:99', 2)]);
        expect(audio.currentState.status, PlaybackStatus.playing);

        coordinator.dispose();
        manager.dispose();
        audio.dispose();
      },
    );

    test(
      'StreamingHttpClient cancels stalled HTTP request via CancellationToken',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final client = StreamingHttpClient(
            timeout: const Duration(seconds: 5),
          );
          final cancel = CancellationToken();

          final sub = server.listen((req) {
            // Hold response open indefinitely without replying.
          });

          final future = client.requestJson(
            method: 'GET',
            uri: Uri.parse('http://127.0.0.1:${server.port}/hung'),
            cancel: cancel,
          );
          Timer(const Duration(milliseconds: 30), cancel.cancel);

          await expectLater(
            future,
            throwsA(
              isA<StreamingException>().having(
                (e) => e.isCancelled,
                'isCancelled',
                isTrue,
              ),
            ),
          );

          await sub.cancel();
          await server.close(force: true);
        }, _RealTestHttpOverrides());
      },
    );

    test(
      '403 -> clears cache & re-resolves fresh -> retries -> 403 -> falls back to ffmpeg with runInShell: false, headers, user-agent, no -ar, and [YTM Play] logs',
      () async {
        final now = DateTime.utc(2026, 11, 22, 12, 0, 0);
        final ytDlp = _ControllableYtDlpService(
          userBinDir: Directory.systemTemp.path,
          bundledBinDir: Directory.systemTemp.path,
          clock: () => now,
        );
        addTearDown(ytDlp.dispose);

        const videoId = 'dQw4w9WgXcQ';
        final track = _track('ytm:$videoId', providerName: 'YouTube Music');

        // Seed stale URL in YtDlpService cache to verify 403 invalidates it.
        ytDlp.seedCache(
          YtDlpResolvedStream(
            videoId: videoId,
            url: 'https://rr1.googlevideo.com/videoplayback?id=$videoId&stale=1',
            httpHeaders: const {
              'User-Agent': 'StaleUA/1.0',
              'Accept': '*/*',
              'Accept-Language': 'en-US,en;q=0.9',
            },
            acodec: 'mp4a.40.2',
            ext: 'm4a',
            sampleRateHz: 44100,
            expiresAt: now.add(const Duration(minutes: 45)),
          ),
        );

        var resolveAttempt = 0;
        ytDlp.onResolveVideo = (
          id, {
          required int playRequestId,
          bool bypassCache = false,
        }) async {
          resolveAttempt++;
          return YtDlpResolvedStream(
            videoId: id,
            url:
                'https://rr2.googlevideo.com/videoplayback?id=$id&fresh=$resolveAttempt',
            httpHeaders: const {
              'User-Agent': 'Mozilla/5.0 FreshYtDlp/2.0',
              'Accept': 'text/html,application/xhtml+xml,*/*;q=0.8',
              'Accept-Language': 'zh-TW,zh;q=0.9,en;q=0.8',
            },
            acodec: 'mp4a.40.2',
            ext: 'm4a',
            sampleRateHz: 44100,
            expiresAt: now.add(const Duration(minutes: 45)),
          );
        };

        final store = MemorySecureCredentialStore();
        final ytm = YouTubeMusicProvider(
          credentialStore: store,
          ytDlpService: ytDlp,
        );
        final manager = StreamingManager(
          credentialStore: store,
          ytDlpService: ytDlp,
          providers: {'youtube_music': ytm},
        );
        addTearDown(manager.dispose);

        final audio = _SpyAudioService();
        addTearDown(audio.dispose);
        final logs = <String>[];
        final errors = <String>[];

        audio.onPlayStreamUrlAsync = (
          t,
          streamUrl,
          headers,
          hintExtension,
          requestId,
        ) async {
          if (streamUrl.contains('googlevideo.com')) {
            audio.failOptimisticTrackLoad(
              t,
              'Failed to open stream (YouTube Music): HTTP 403 fetching $streamUrl',
            );
          }
        };

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          ytDlpService: ytDlp,
          clock: () => now,
          logSink: logs.add,
          onError: (_, msg, _) => errors.add(msg),
        );
        addTearDown(coordinator.dispose);

        await coordinator.playTrack(track);
        // Pump microtasks so 403 recovery (cache clear -> fresh yt-dlp -> 403 -> ffmpeg) completes.
        for (var i = 0; i < 6; i++) {
          await Future<void>.delayed(Duration.zero);
          final pending = coordinator.activeTaskFuture;
          if (pending != null) {
            await pending;
          }
        }

        // Verify 3 playStreamUrlAsync attempts: stale direct -> fresh direct -> localhost ffmpeg WAV.
        expect(audio.recordedPlays.length, 3);
        expect(audio.recordedPlays[0].streamUrl, contains('stale=1'));
        expect(audio.recordedPlays[1].streamUrl, contains('fresh=1'));
        expect(
          audio.recordedPlays[1].headers['User-Agent'],
          'Mozilla/5.0 FreshYtDlp/2.0',
        );
        expect(
          audio.recordedPlays[1].headers['Accept-Language'],
          'zh-TW,zh;q=0.9,en;q=0.8',
        );
        expect(audio.recordedPlays[2].streamUrl, startsWith('http://127.0.0.1:'));
        expect(audio.recordedPlays[2].streamUrl, endsWith('.wav'));
        expect(audio.recordedPlays[2].hintExtension, 'wav');
        expect(audio.currentState.status, PlaybackStatus.playing);
        expect(errors, isEmpty);

        // Verify cache was cleared and fresh resolve explicitly bypassed cache;
        // once direct retry also hit 403, the failing direct URL stays evicted.
        expect(ytDlp.resolveCalls.length, 1);
        expect(ytDlp.resolveCalls.single.videoId, videoId);
        expect(ytDlp.resolveCalls.single.bypassCache, isTrue);
        expect(coordinator.getCachedStream(track.id), isNull);
        expect(ytDlp.getCachedStream(videoId), isNull);

        // Verify FfmpegAudioProxy CLI args: runInShell: false, -user_agent, -headers, NO -ar.
        final ffArgs = FfmpegAudioProxy.buildFfmpegArgs(
          sourceUrl: audio.recordedPlays[1].streamUrl,
          headers: audio.recordedPlays[1].headers,
        );
        expect(ffArgs.contains('-ar'), isFalse);
        final uaIdx = ffArgs.indexOf('-user_agent');
        expect(uaIdx, greaterThan(0));
        expect(ffArgs[uaIdx + 1], 'Mozilla/5.0 FreshYtDlp/2.0');
        final hdrIdx = ffArgs.indexOf('-headers');
        expect(hdrIdx, greaterThan(0));
        expect(ffArgs[hdrIdx + 1], contains('Accept: '));
        expect(ffArgs[hdrIdx + 1], contains('Accept-Language: '));

        // Verify explicit [YTM Play] trace logs for initial direct, 403 retry, and ffmpeg fallback.
        expect(
          logs,
          containsAllInOrder(<String>[
            '[YTM Play] videoId=$videoId -> Engine: bundled yt-dlp (direct M4A)',
            '[YTM Play] videoId=$videoId -> HTTP 403 detected; clearing cache and retrying fresh yt-dlp',
            '[YTM Play] videoId=$videoId -> Engine: bundled yt-dlp (direct M4A)',
            '[YTM Play] videoId=$videoId -> HTTP 403 persisted after fresh retry; switching to bundled ffmpeg fallback',
            '[YTM Play] videoId=$videoId -> Engine: bundled yt-dlp + ffmpeg fallback',
          ]),
        );

        // Trigger actual GET on the loopback URL to confirm process spawn uses runInShell: false.
        await HttpOverrides.runWithHttpOverrides(() async {
          final client = HttpClient();
          addTearDown(() => client.close(force: true));
          final req = await client.getUrl(
            Uri.parse(audio.recordedPlays[2].streamUrl),
          );
          final resp = await req.close();
          expect(resp.statusCode, HttpStatus.ok);
          expect(ytDlp.ffmpegSpawns.length, 1);
          expect(ytDlp.ffmpegSpawns.single.runInShell, isFalse);
          expect(
            ytDlp.ffmpegSpawns.single.args.contains('-user_agent'),
            isTrue,
          );
          expect(ytDlp.ffmpegSpawns.single.args.contains('-headers'), isTrue);
          expect(ytDlp.ffmpegSpawns.single.args.contains('-ar'), isFalse);
          await ytDlp.stopAll();
        }, _RealTestHttpOverrides());
      },
    );

    test(
      '403 -> clears cache & re-resolves fresh -> succeeds directly without spawning ffmpeg when second URL plays',
      () async {
        final now = DateTime.utc(2026, 11, 22, 12, 0, 0);
        final ytDlp = _ControllableYtDlpService(
          userBinDir: Directory.systemTemp.path,
          bundledBinDir: Directory.systemTemp.path,
          clock: () => now,
        );
        addTearDown(ytDlp.dispose);

        const videoId = 'DYptgVvkVLQ';
        final track = _track('ytm:$videoId', providerName: 'YouTube Music');
        ytDlp.seedCache(
          YtDlpResolvedStream(
            videoId: videoId,
            url: 'https://rr1.googlevideo.com/videoplayback?id=$videoId&stale=1',
            httpHeaders: const {'User-Agent': 'StaleUA'},
            acodec: 'mp4a.40.2',
            ext: 'm4a',
            sampleRateHz: 44100,
            expiresAt: now.add(const Duration(minutes: 45)),
          ),
        );

        ytDlp.onResolveVideo = (
          id, {
          required int playRequestId,
          bool bypassCache = false,
        }) async {
          return YtDlpResolvedStream(
            videoId: id,
            url: 'https://rr2.googlevideo.com/videoplayback?id=$id&fresh=ok',
            httpHeaders: const {'User-Agent': 'FreshUA'},
            acodec: 'mp4a.40.2',
            ext: 'm4a',
            sampleRateHz: 44100,
            expiresAt: now.add(const Duration(minutes: 45)),
          );
        };

        final store = MemorySecureCredentialStore();
        final ytm = YouTubeMusicProvider(
          credentialStore: store,
          ytDlpService: ytDlp,
        );
        final manager = StreamingManager(
          credentialStore: store,
          ytDlpService: ytDlp,
          providers: {'youtube_music': ytm},
        );
        addTearDown(manager.dispose);

        final audio = _SpyAudioService();
        addTearDown(audio.dispose);
        final logs = <String>[];
        final errors = <String>[];

        audio.onPlayStreamUrlAsync = (
          t,
          streamUrl,
          headers,
          hintExtension,
          requestId,
        ) async {
          if (streamUrl.contains('stale=1')) {
            audio.failOptimisticTrackLoad(t, 'HTTP 403 Forbidden');
          }
        };

        final coordinator = StreamingPlaybackCoordinator(
          audioService: audio,
          streamingManager: manager,
          ytDlpService: ytDlp,
          clock: () => now,
          logSink: logs.add,
          onError: (_, msg, _) => errors.add(msg),
        );
        addTearDown(coordinator.dispose);

        await coordinator.playTrack(track);
        for (var i = 0; i < 4; i++) {
          await Future<void>.delayed(Duration.zero);
          final pending = coordinator.activeTaskFuture;
          if (pending != null) await pending;
        }

        expect(audio.recordedPlays.length, 2);
        expect(audio.recordedPlays[1].streamUrl, contains('fresh=ok'));
        expect(audio.currentState.status, PlaybackStatus.playing);
        expect(ytDlp.ffmpegSpawns, isEmpty);
        expect(errors, isEmpty);
        expect(
          logs,
          containsAllInOrder(<String>[
            '[YTM Play] videoId=$videoId -> Engine: bundled yt-dlp (direct M4A)',
            '[YTM Play] videoId=$videoId -> HTTP 403 detected; clearing cache and retrying fresh yt-dlp',
            '[YTM Play] videoId=$videoId -> Engine: bundled yt-dlp (direct M4A)',
          ]),
        );
      },
    );

    test(
      'immediately kills ffmpeg.exe process on pause(), stop(), track switch, local track switch, and paused/stopped/ended/error states',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final ytDlp = _ControllableYtDlpService(
            userBinDir: Directory.systemTemp.path,
            bundledBinDir: Directory.systemTemp.path,
          );
          addTearDown(ytDlp.dispose);

          ytDlp.onResolveVideo = (
            id, {
            required int playRequestId,
            bool bypassCache = false,
          }) async {
            return YtDlpResolvedStream(
              videoId: id,
              url: 'https://rr1.googlevideo.com/opus_$id.webm',
              httpHeaders: const {'User-Agent': 'KillTestUA/1.0'},
              acodec: 'opus',
              ext: 'webm',
              sampleRateHz: 48000,
              expiresAt: DateTime.now().add(const Duration(minutes: 45)),
            );
          };

          final store = MemorySecureCredentialStore();
          final ytm = YouTubeMusicProvider(
            credentialStore: store,
            ytDlpService: ytDlp,
          );
          final manager = StreamingManager(
            credentialStore: store,
            ytDlpService: ytDlp,
            providers: {'youtube_music': ytm},
          );
          addTearDown(manager.dispose);

          final audio = _SpyAudioService();
          addTearDown(audio.dispose);
          final coordinator = StreamingPlaybackCoordinator(
            audioService: audio,
            streamingManager: manager,
            ytDlpService: ytDlp,
            debounceDelay: Duration.zero,
          );
          addTearDown(coordinator.dispose);

          final client = HttpClient();
          addTearDown(() => client.close(force: true));

          Future<_FakeFfmpegProcess> startFfmpegStreamFor(TrackInfo t) async {
            final beforeCount = ytDlp.spawnedFfmpegProcesses.length;
            await coordinator.playTrack(t);
            final wavUrl = audio.recordedPlays.last.streamUrl;
            final req = await client.getUrl(Uri.parse(wavUrl));
            final resp = await req.close();
            expect(resp.statusCode, HttpStatus.ok);
            unawaited(resp.drain<void>().catchError((_) {}));
            for (var i = 0;
                i < 20 && ytDlp.spawnedFfmpegProcesses.length <= beforeCount;
                i++) {
              await Future<void>.delayed(const Duration(milliseconds: 5));
            }
            expect(ytDlp.spawnedFfmpegProcesses.length, greaterThan(beforeCount));
            return ytDlp.spawnedFfmpegProcesses.last;
          }

          // 1. Synchronous immediate kill on audio.pause() (before any microtasks!)
          final procPause = await startFfmpegStreamFor(
            _track('ytm:dQw4w9WgXcQ', providerName: 'YouTube Music'),
          );
          expect(procPause.killed, isFalse);
          final pauseFut = audio.pause();
          expect(procPause.killed, isTrue);
          await pauseFut;

          // 2. Synchronous immediate kill on audio.stop()
          final procStop = await startFfmpegStreamFor(
            _track('ytm:DYptgVvkVLQ', providerName: 'YouTube Music'),
          );
          expect(procStop.killed, isFalse);
          final stopFut = audio.stop();
          expect(procStop.killed, isTrue);
          await stopFut;

          // 3. Synchronous immediate kill on track switch playTrack()
          final procSwitch = await startFfmpegStreamFor(
            _track('ytm:YhiQDARUJ7Y', providerName: 'YouTube Music'),
          );
          expect(procSwitch.killed, isFalse);
          final nextFut = coordinator.playTrack(
            _track('ytm:9bZkp7q19f0', providerName: 'YouTube Music'),
          );
          expect(procSwitch.killed, isTrue);
          await nextFut;

          // 4. Synchronous immediate kill when switching to a non-streaming local track
          final procLocal = await startFfmpegStreamFor(
            _track('ytm:kJQP7kiw5Fk', providerName: 'YouTube Music'),
          );
          expect(procLocal.killed, isFalse);
          final localPlayFut = audio.play(track: _track('local-1', providerName: 'Local Library'));
          expect(procLocal.killed, isTrue);
          await localPlayFut;

          // 1b. Synchronous immediate kill on coordinator.pause() and coordinator.stop()
          final procCoordPause = await startFfmpegStreamFor(
            _track('ytm:dQw4w9WgXcQ', providerName: 'YouTube Music'),
          );
          expect(procCoordPause.killed, isFalse);
          final coordPauseFut = coordinator.pause();
          expect(procCoordPause.killed, isTrue);
          await coordPauseFut;

          final procCoordStop = await startFfmpegStreamFor(
            _track('ytm:dQw4w9WgXcQ', providerName: 'YouTube Music'),
          );
          expect(procCoordStop.killed, isFalse);
          final coordStopFut = coordinator.stop();
          expect(procCoordStop.killed, isTrue);
          await coordStopFut;

          // 5. Async stateStream transitions (paused / stopped / ended / error) also kill ffmpeg
          final ytmTrack =
              _track('ytm:dQw4w9WgXcQ', providerName: 'YouTube Music');
          for (final terminalStatus in const [
            PlaybackStatus.paused,
            PlaybackStatus.stopped,
            PlaybackStatus.ended,
            PlaybackStatus.error,
          ]) {
            final procState = await startFfmpegStreamFor(ytmTrack);
            expect(procState.killed, isFalse);
            audio.emitRawStateForTest(
              PlaybackState(
                status: terminalStatus,
                track: ytmTrack,
                lastError: terminalStatus == PlaybackStatus.error
                    ? 'Stream interrupted'
                    : null,
              ),
            );
            await Future<void>.delayed(Duration.zero);
            expect(
              procState.killed,
              isTrue,
              reason: '$terminalStatus should immediately kill ffmpeg process',
            );
          }
        }, _RealTestHttpOverrides());
      },
    );

    test(
      'FfiAudioService propagates mid-playback Range HTTP 403 to StreamingPlaybackCoordinator recovery',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final tempDir =
              await Directory.systemTemp.createTemp('lumina_ffi_range403_');
          addTearDown(() async {
            try {
              if (tempDir.existsSync()) {
                await tempDir.delete(recursive: true);
              }
            } catch (_) {}
          });
          final dbPath =
              '${tempDir.path}${Platform.pathSeparator}ffi_range403.db';
          final ffi = FfiAudioService(headless: true, databasePath: dbPath);
          addTearDown(ffi.dispose);

          if (!ffi.isNativeBound) {
            markTestSkipped('core_ffi.dll not available in test environment');
            return;
          }

          final wavBytes = _buildTestWavBytes(
            sampleRate: 44100,
            durationMs: 3600,
          );
          var range403Returned = false;
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((req) async {
            req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
            req.response.headers.contentType = ContentType('audio', 'wav');
            if (req.method == 'HEAD') {
              req.response.statusCode = HttpStatus.ok;
              req.response.headers.contentLength = wavBytes.length;
              await req.response.close();
              return;
            }
            final rangeHdr = req.headers.value(HttpHeaders.rangeHeader);
            if (rangeHdr != null && rangeHdr.startsWith('bytes=')) {
              final parts = rangeHdr.substring(6).split('-');
              final start = int.tryParse(parts[0]) ?? 0;
              final end = (parts.length > 1 && parts[1].isNotEmpty)
                  ? (int.tryParse(parts[1]) ?? (wavBytes.length - 1))
                  : (wavBytes.length - 1);
              if (req.uri.path == '/range_403.wav' && start >= 131072) {
                range403Returned = true;
                req.response.statusCode = HttpStatus.forbidden;
                await req.response.close();
                return;
              }
              final clampedEnd = end.clamp(start, wavBytes.length - 1);
              final slice = wavBytes.sublist(start, clampedEnd + 1);
              req.response.statusCode = HttpStatus.partialContent;
              req.response.headers.set(
                HttpHeaders.contentRangeHeader,
                'bytes $start-$clampedEnd/${wavBytes.length}',
              );
              req.response.headers.contentLength = slice.length;
              req.response.add(slice);
              await req.response.close();
              return;
            }
            req.response.statusCode = HttpStatus.ok;
            req.response.headers.contentLength = wavBytes.length;
            req.response.add(wavBytes);
            await req.response.close();
          });

          final now = DateTime.utc(2026, 11, 22, 12, 0, 0);
          final ytDlp = _ControllableYtDlpService(
            userBinDir: tempDir.path,
            bundledBinDir: tempDir.path,
            clock: () => now,
          );
          addTearDown(ytDlp.dispose);

          var resolveCount = 0;
          ytDlp.onResolveVideo = (
            id, {
            required int playRequestId,
            bool bypassCache = false,
          }) async {
            resolveCount++;
            final path =
                resolveCount == 1 ? '/range_403.wav' : '/ok_full.wav';
            return YtDlpResolvedStream(
              videoId: id,
              url: 'http://127.0.0.1:${server.port}$path',
              httpHeaders: const {
                'User-Agent': 'LuminaRange403/1.0',
                'Accept': '*/*',
                'Accept-Language': 'zh-TW,zh;q=0.9',
              },
              acodec: 'wav',
              ext: 'wav',
              sampleRateHz: 44100,
              expiresAt: now.add(const Duration(minutes: 45)),
            );
          };

          final store = MemorySecureCredentialStore();
          final ytm = YouTubeMusicProvider(
            credentialStore: store,
            ytDlpService: ytDlp,
          );
          final manager = StreamingManager(
            credentialStore: store,
            ytDlpService: ytDlp,
            providers: {'youtube_music': ytm},
          );
          addTearDown(manager.dispose);

          final logs = <String>[];
          final errors = <String>[];
          final coordinator = StreamingPlaybackCoordinator(
            audioService: ffi,
            streamingManager: manager,
            ytDlpService: ytDlp,
            clock: () => now,
            logSink: logs.add,
            onError: (_, msg, _) => errors.add(msg),
          );
          addTearDown(coordinator.dispose);

          final firstPlaying = Completer<void>();
          final recoveredPlaying = Completer<void>();
          var seen403Retry = false;
          final sub = ffi.stateStream.listen((s) {
            if (s.status == PlaybackStatus.playing) {
              if (!firstPlaying.isCompleted) {
                firstPlaying.complete();
              } else if (seen403Retry && !recoveredPlaying.isCompleted) {
                recoveredPlaying.complete();
              }
            }
            if (s.status == PlaybackStatus.loading && range403Returned) {
              seen403Retry = true;
            }
          });
          addTearDown(sub.cancel);

          await coordinator.playTrack(
            _track('ytm:dQw4w9WgXcQ', providerName: 'YouTube Music'),
          );
          await firstPlaying.future.timeout(const Duration(seconds: 6));

          // Seek past the first 128KB chunk to trigger mid-playback Range HTTP 403.
          await ffi.seek(const Duration(seconds: 2));
          await recoveredPlaying.future.timeout(const Duration(seconds: 8));

          expect(range403Returned, isTrue);
          expect(resolveCount, 2);
          expect(errors, isEmpty);
          expect(
            logs,
            contains(
              '[YTM Play] videoId=dQw4w9WgXcQ -> HTTP 403 detected; clearing cache and retrying fresh yt-dlp',
            ),
          );
          await ffi.stop();
        }, _RealTestHttpOverrides());
      },
    );

    test(
      'FfiAudioService propagates HTTP 403 from Rust async stream open with caller headers to StreamingPlaybackCoordinator recovery',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final tempDir =
              await Directory.systemTemp.createTemp('lumina_ffi_403_');
          addTearDown(() async {
            try {
              if (tempDir.existsSync()) {
                await tempDir.delete(recursive: true);
              }
            } catch (_) {}
          });
          final dbPath = '${tempDir.path}${Platform.pathSeparator}ffi403.db';
          final ffi = FfiAudioService(headless: true, databasePath: dbPath);
          addTearDown(ffi.dispose);

          if (!ffi.isNativeBound) {
            markTestSkipped('core_ffi.dll not available in test environment');
            return;
          }

          final wavBytes = _buildTestWavBytes();
          final seenRequests =
              <({String path, String? ua, String? accept, String? lang})>[];
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((req) async {
            seenRequests.add((
              path: req.uri.path,
              ua: req.headers.value('user-agent'),
              accept: req.headers.value('accept'),
              lang: req.headers.value('accept-language'),
            ));
            if (req.uri.path.startsWith('/blocked')) {
              req.response.statusCode = HttpStatus.forbidden;
              await req.response.close();
              return;
            }
            req.response.statusCode = HttpStatus.ok;
            req.response.headers.contentType = ContentType('audio', 'wav');
            req.response.contentLength = wavBytes.length;
            req.response.add(wavBytes);
            await req.response.close();
          });

          final now = DateTime.utc(2026, 11, 22, 12, 0, 0);
          final ytDlp = _ControllableYtDlpService(
            userBinDir: tempDir.path,
            bundledBinDir: tempDir.path,
            clock: () => now,
          );
          addTearDown(ytDlp.dispose);

          var resolveCount = 0;
          ytDlp.onResolveVideo = (
            id, {
            required int playRequestId,
            bool bypassCache = false,
          }) async {
            resolveCount++;
            final path = resolveCount == 1 ? '/blocked1' : '/ok_audio';
            return YtDlpResolvedStream(
              videoId: id,
              url: 'http://127.0.0.1:${server.port}$path',
              httpHeaders: const {
                'User-Agent': 'LuminaFfiHeaderTest/1.0',
                'Accept': '*/*',
                'Accept-Language': 'zh-TW,zh;q=0.9',
              },
              acodec: 'wav',
              ext: 'wav',
              sampleRateHz: 8000,
              expiresAt: now.add(const Duration(minutes: 45)),
            );
          };

          final store = MemorySecureCredentialStore();
          final ytm = YouTubeMusicProvider(
            credentialStore: store,
            ytDlpService: ytDlp,
          );
          final manager = StreamingManager(
            credentialStore: store,
            ytDlpService: ytDlp,
            providers: {'youtube_music': ytm},
          );
          addTearDown(manager.dispose);

          final logs = <String>[];
          final errors = <String>[];
          final coordinator = StreamingPlaybackCoordinator(
            audioService: ffi,
            streamingManager: manager,
            ytDlpService: ytDlp,
            clock: () => now,
            logSink: logs.add,
            onError: (_, msg, _) => errors.add(msg),
          );
          addTearDown(coordinator.dispose);

          final playingCompleter = Completer<void>();
          final sub = ffi.stateStream.listen((s) {
            if (s.status == PlaybackStatus.playing &&
                !playingCompleter.isCompleted) {
              playingCompleter.complete();
            }
          });
          addTearDown(sub.cancel);

          await coordinator.playTrack(
            _track('ytm:dQw4w9WgXcQ', providerName: 'YouTube Music'),
          );
          await playingCompleter.future.timeout(const Duration(seconds: 8));

          expect(ffi.currentState.status, PlaybackStatus.playing);
          expect(errors, isEmpty);
          expect(resolveCount, 2);
          expect(
            seenRequests.any(
              (r) =>
                  r.path == '/blocked1' &&
                  r.ua == 'LuminaFfiHeaderTest/1.0' &&
                  r.accept == '*/*' &&
                  r.lang == 'zh-TW,zh;q=0.9',
            ),
            isTrue,
          );
          expect(
            seenRequests.any(
              (r) =>
                  r.path == '/ok_audio' &&
                  r.ua == 'LuminaFfiHeaderTest/1.0',
            ),
            isTrue,
          );
          expect(
            logs,
            contains(
              '[YTM Play] videoId=dQw4w9WgXcQ -> HTTP 403 detected; clearing cache and retrying fresh yt-dlp',
            ),
          );
          await ffi.stop();
        }, _RealTestHttpOverrides());
      },
    );

    test(
      'FfmpegAudioProxy returns 403/502 instead of empty 200 OK when ffmpeg exits before emitting audio bytes and redacts query strings in stderr logs',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final printed = <String>[];
          final prevDebugPrint = debugPrint;
          debugPrint = (String? message, {int? wrapWidth}) {
            if (message != null) printed.add(message);
          };
          addTearDown(() => debugPrint = prevDebugPrint);

          var stderrMsg =
              'Error opening https://cdn.example.com/seg.m4s?token=SECRET_TOKEN&Expires=999: Server returned 403 Forbidden (access denied)';
          final proxy = FfmpegAudioProxy(
            ffmpegPathProvider: () => '${Directory.current.path}\\ffmpeg.exe',
            processStarter: (
              executable,
              arguments, {
              workingDirectory,
              environment,
              includeParentEnvironment = true,
              runInShell = false,
              mode = ProcessStartMode.normal,
            }) async {
              return _FailingFfmpegProcess(stderrText: stderrMsg);
            },
          );
          addTearDown(proxy.dispose);

          final client = HttpClient();
          addTearDown(() => client.close(force: true));

          final url403 = await proxy.openTranscodedWavUrl(
            sourceUrl: 'https://rr1.googlevideo.com/videoplayback?id=403',
            playRequestId: 1,
          );
          final req1 = await client.getUrl(Uri.parse(url403));
          final resp1 = await req1.close();
          await resp1.drain<void>();
          expect(resp1.statusCode, HttpStatus.forbidden);
          expect(
            printed.any((m) => m.contains('?[REDACTED]')),
            isTrue,
          );
          expect(
            printed.any((m) => m.contains('SECRET_TOKEN')),
            isFalse,
          );

          stderrMsg = 'Connection timed out opening input';
          final url502 = await proxy.openTranscodedWavUrl(
            sourceUrl: 'https://rr1.googlevideo.com/videoplayback?id=502',
            playRequestId: 2,
          );
          final req2 = await client.getUrl(Uri.parse(url502));
          final resp2 = await req2.close();
          await resp2.drain<void>();
          expect(resp2.statusCode, HttpStatus.badGateway);
        }, _RealTestHttpOverrides());
      },
    );

    test(
      'stale paused/stopped events arriving during Tidal DASH resolve/load do NOT cancel the newly opened DASH proxy session',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final ytDlp = _ControllableYtDlpService(
            userBinDir: Directory.systemTemp.path,
            bundledBinDir: Directory.systemTemp.path,
          );
          addTearDown(ytDlp.dispose);

          final audio = _SpyAudioService();
          addTearDown(audio.dispose);

          final tidal = _FakeStreamingProvider('tidal');
          final manager = StreamingManager(
            credentialStore: MemorySecureCredentialStore(),
            ytDlpService: ytDlp,
            providers: {'tidal': tidal},
          );
          addTearDown(manager.dispose);

          final track = _track('tidal:stale-guard', providerName: 'Tidal');
          tidal.onResolve = (t, {cancel, timeout}) async {
            final reqId = tidal.lastPlayRequestId!;
            final proxyUrl = await ytDlp.openDashMpdUrl(
              mpdXml:
                  '<MPD><Period><AdaptationSet><Representation codecs="flac"><SegmentTemplate initialization="https://audio.tidal.com/init.mp4"/></Representation></AdaptationSet></Period></MPD>',
              playRequestId: reqId,
              copyFlac: true,
            );
            // Emit stale paused/stopped/uninitialized states while resolve is still in flight.
            audio.emitRawStateForTest(
              PlaybackState(status: PlaybackStatus.paused, track: t),
            );
            audio.emitRawStateForTest(
              PlaybackState(status: PlaybackStatus.stopped, track: t),
            );
            audio.emitRawStateForTest(
              const PlaybackState(status: PlaybackStatus.uninitialized),
            );
            await Future<void>.delayed(Duration.zero);
            return ResolvedStreamResult(
              url: proxyUrl,
              hintExtension: 'flac',
              format: const AudioFormat(
                codec: AudioCodec.flac,
                sampleRateHz: 96000,
                bitDepth: 24,
                channels: 2,
              ),
              engineRoute: 'Tidal DASH FLAC (HI_RES_LOSSLESS, ffmpeg remux)',
            );
          };

          audio.onPlayStreamUrlAsync = (
            t,
            streamUrl,
            headers,
            hintExtension,
            requestId,
          ) async {
            // Also emit stale stopped during playStreamUrlAsync handoff.
            audio.emitRawStateForTest(
              PlaybackState(status: PlaybackStatus.stopped, track: t),
            );
            await Future<void>.delayed(Duration.zero);
          };

          final coordinator = StreamingPlaybackCoordinator(
            audioService: audio,
            streamingManager: manager,
            ytDlpService: ytDlp,
            debounceDelay: Duration.zero,
          );
          addTearDown(coordinator.dispose);

          await coordinator.playTrack(track);

          expect(ytDlp.stopFfmpegExceptRequestIds, isNotEmpty);
          expect(
            ytDlp.stopFfmpegExceptRequestIds.every((id) => id == 1),
            isTrue,
          );
          expect(ytDlp.ffmpegProxy.trackedTempFileCount, equals(1));

          // The proxy URL must still be valid and serve 200 OK.
          final client = HttpClient();
          addTearDown(() => client.close(force: true));
          final req = await client.getUrl(
            Uri.parse(audio.recordedPlays.single.streamUrl),
          );
          final resp = await req.close();
          expect(resp.statusCode, equals(HttpStatus.ok));
          unawaited(resp.drain<void>().catchError((_) {}));

          for (var i = 0; i < 20 && ytDlp.spawnedFfmpegProcesses.isEmpty; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
          expect(ytDlp.spawnedFfmpegProcesses, hasLength(1));
          final proc = ytDlp.spawnedFfmpegProcesses.single;
          expect(proc.killed, isFalse);

          // After resolve/load finishes, a real stopped event cancels the session.
          audio.emitRawStateForTest(
            PlaybackState(status: PlaybackStatus.stopped, track: track),
          );
          await Future<void>.delayed(Duration.zero);
          expect(ytDlp.stopFfmpegExceptRequestIds.last, isNull);
          expect(proc.killed, isTrue);
          await ytDlp.stopAll();
        }, _RealTestHttpOverrides());
      },
    );
  });

  group('PlaybackControls loading/buffering spinner', () {
    for (final busyStatus in const [
      PlaybackStatus.loading,
      PlaybackStatus.buffering,
    ]) {
      testWidgets(
        'renders btn_play_pause_loading inside btn_play_pause while keeping skip buttons clickable (${busyStatus.name})',
        (tester) async {
          var prevTaps = 0;
          var nextTaps = 0;

          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Center(
                  child: PlaybackControls(
                    status: busyStatus,
                    onPrevious: () => prevTaps++,
                    onPlayPause: () {},
                    onNext: () => nextTaps++,
                  ),
                ),
              ),
            ),
          );

          expect(find.byKey(const Key('btn_play_pause')), findsOneWidget);
          expect(
            find.descendant(
              of: find.byKey(const Key('btn_play_pause')),
              matching: find.byKey(const Key('btn_play_pause_loading')),
            ),
            findsOneWidget,
          );

          await tester.tap(find.byKey(const Key('btn_previous')));
          await tester.tap(find.byKey(const Key('btn_next')));
          expect(prevTaps, 1);
          expect(nextTaps, 1);
        },
      );
    }
  });
}
