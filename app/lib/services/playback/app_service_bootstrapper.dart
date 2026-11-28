import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../models/playback_state.dart';
import '../../models/streaming_models.dart';
import '../audio_service.dart';
import '../recommendation_settings_controller.dart';
import '../streaming/autoplay_controller.dart';
import '../streaming/cross_platform_track_router.dart';
import '../streaming/external_recommendation_providers.dart';
import '../streaming/recommendation_provider.dart';
import '../streaming/secure_credential_store.dart';
import '../streaming/streaming_manager.dart';
import '../streaming/streaming_playback_coordinator.dart';
import 'playback_controller.dart';

/// Assembled playback/streaming/autoplay runtime session created outside of UI
/// widgets so `app/lib/ui/**` never imports or downcasts concrete backends
/// (`FfiAudioService`, `ServerAudioService`, `CoordinatingAudioService`).
class AppPlaybackSession {
  final AudioService rawAudioService;
  final AudioService effectiveAudioService;
  final StreamingManager streamingManager;
  final bool ownsStreamingManager;
  final RecommendationSettingsController recommendationSettings;
  final bool ownsRecommendationSettings;
  final AutoplayController autoplayController;
  final bool ownsAutoplayController;
  final StreamingPlaybackCoordinator streamingCoordinator;
  final PlaybackController? playbackController;

  bool _disposed = false;

  AppPlaybackSession({
    required this.rawAudioService,
    required this.effectiveAudioService,
    required this.streamingManager,
    required this.ownsStreamingManager,
    required this.recommendationSettings,
    required this.ownsRecommendationSettings,
    required this.autoplayController,
    required this.ownsAutoplayController,
    required this.streamingCoordinator,
    this.playbackController,
  });

  Future<void> playTrack(
    TrackInfo track, {
    List<TrackInfo>? queueContext,
  }) =>
      streamingCoordinator.playTrack(track, queueContext: queueContext);

  void requestHoverPrefetch(TrackInfo track) =>
      streamingCoordinator.requestHoverPrefetch(track);

  Future<void> stopExternalHelpersForExit() async {
    await streamingCoordinator.ytDlpService.stopAll();
  }

  /// Exact clean-exit sequence: disposes coordinator, effective service,
  /// autoplay, stops yt-dlp helpers, detaches native hooks, awaits
  /// `streamingManager.disposeAsync()`, and finally disposes `rawAudioService`.
  Future<void> disposeForCleanExit({
    VoidCallback? beforeStreamingManagerDispose,
  }) async {
    if (_disposed) return;
    _disposed = true;
    streamingCoordinator.dispose();
    effectiveAudioService.dispose();
    if (ownsAutoplayController) {
      autoplayController.dispose();
    }
    await streamingCoordinator.ytDlpService.stopAll();
    rawAudioService.detachStreamingHooks();
    beforeStreamingManagerDispose?.call();
    await streamingManager.disposeAsync();
    if (ownsRecommendationSettings) {
      recommendationSettings.dispose();
    }
    rawAudioService.dispose();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    streamingCoordinator.dispose();
    effectiveAudioService.dispose();
    if (ownsAutoplayController) {
      autoplayController.dispose();
    }
    if (ownsRecommendationSettings) {
      recommendationSettings.dispose();
    }
    rawAudioService.detachStreamingHooks();
    if (ownsStreamingManager) {
      streamingManager.dispose();
    }
  }
}

/// Composition helper living strictly in `app/lib/services/playback/` that wires
/// [AudioService], [StreamingManager], [AutoplayController], and
/// [StreamingPlaybackCoordinator] via capability methods on [AudioService].
class AppServiceBootstrapper {
  const AppServiceBootstrapper._();

  static AppPlaybackSession createSession({
    required AudioService audioService,
    StreamingManager? streamingManager,
    RecommendationSettingsController? recommendationSettings,
    AutoplayController? autoplayController,
    void Function(TrackInfo track, ResolvedStreamResult result)?
        onStreamingNotice,
    void Function(TrackInfo track, String message, bool retryable)?
        onStreamingError,
  }) {
    final isTestEnv = Platform.environment.containsKey('FLUTTER_TEST');
    final ownsStreamingManager = streamingManager == null;
    final resolvedStreamingManager = streamingManager ??
        StreamingManager(
          credentialStore: isTestEnv ? MemorySecureCredentialStore() : null,
          l1CachePersistence:
              isTestEnv ? null : audioService.createL1CachePersistence(),
          waitDbReady:
              isTestEnv ? null : (() => audioService.dbReadyFuture),
          sidecarLifecycleBinder:
              isTestEnv ? null : audioService.createSidecarLifecycleBinder(),
          onHttp2Warmup:
              isTestEnv ? null : audioService.streamingHttp2WarmupCallback,
        );

    audioService.attachStreamingHooks(resolvedStreamingManager);

    final ownsRecommendationSettings = recommendationSettings == null;
    final resolvedRecommendationSettings = recommendationSettings ??
        RecommendationSettingsController(
          credentialStore: resolvedStreamingManager.credentialStore,
        );
    if (ownsRecommendationSettings) {
      unawaited(resolvedRecommendationSettings.load());
    }

    final ownsAutoplayController = autoplayController == null;
    final AutoplayController resolvedAutoplay;
    if (ownsAutoplayController) {
      final lastFm = LastFmRecommendationProvider(
        apiKeyProvider: () => resolvedRecommendationSettings.lastFmApiKey,
      );
      final listenBrainz = ListenBrainzRecommendationProvider(
        enabledProvider: () =>
            resolvedRecommendationSettings.listenBrainzEnabled,
      );
      final localMatcher = LocalLibraryTrackMatcher(
        searchLibrary: audioService.searchLibrary,
      );
      final trackRouter = CrossPlatformTrackRouter(
        providerLookup: resolvedStreamingManager.recommendationProviderFor,
        authStateLookup: (pid) =>
            resolvedStreamingManager.providerFor(pid)?.authState ??
            StreamingAuthState.disconnected,
        isAuthRequiredLookup: resolvedStreamingManager.authManager.isAuthRequired,
        isPlaybackAuthBlockedLookup:
            resolvedStreamingManager.authManager.isPlaybackAuthBlocked,
        isGuestCapableLookup:
            resolvedStreamingManager.authManager.isGuestPlaybackCapable,
        localMatcher: localMatcher.matchTrack,
        priorityOrderProvider: () =>
            resolvedRecommendationSettings.platformPriority,
      );
      resolvedAutoplay = AutoplayController(
        providerLookup: resolvedStreamingManager.recommendationProviderFor,
        externalProviders: <RecommendationProvider>[lastFm, listenBrainz],
        trackRouter: trackRouter,
        settings: resolvedRecommendationSettings,
        isAuthRequiredLookup: resolvedStreamingManager.authManager.isAuthRequired,
        isGuestCapableLookup:
            resolvedStreamingManager.authManager.isGuestPlaybackCapable,
        authStateLookup: (pid) =>
            resolvedStreamingManager.providerFor(pid)?.authState ??
            StreamingAuthState.disconnected,
        allowBackgroundRefill: !isTestEnv || streamingManager != null,
      );
    } else {
      resolvedAutoplay = autoplayController;
    }

    final coordinator = StreamingPlaybackCoordinator(
      audioService: audioService,
      streamingManager: resolvedStreamingManager,
      autoplayController: resolvedAutoplay,
      onNotice: onStreamingNotice,
      onError: onStreamingError,
    );

    final effectiveService = CoordinatingAudioService(
      inner: audioService,
      coordinator: coordinator,
      disposeInner: false,
    );

    return AppPlaybackSession(
      rawAudioService: audioService,
      effectiveAudioService: effectiveService,
      streamingManager: resolvedStreamingManager,
      ownsStreamingManager: ownsStreamingManager,
      recommendationSettings: resolvedRecommendationSettings,
      ownsRecommendationSettings: ownsRecommendationSettings,
      autoplayController: resolvedAutoplay,
      ownsAutoplayController: ownsAutoplayController,
      streamingCoordinator: coordinator,
      playbackController: audioService.playbackController,
    );
  }
}
