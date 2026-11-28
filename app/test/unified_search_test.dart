import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumina_app/models/audio_format.dart';
import 'package:lumina_app/models/nav_entry.dart';
import 'package:lumina_app/models/playback_state.dart';
import 'package:lumina_app/models/streaming_models.dart';
import 'package:lumina_app/models/streaming_provider_meta.dart';
import 'package:lumina_app/models/studio_models.dart';
import 'package:lumina_app/services/library_index_cache.dart';
import 'package:lumina_app/services/mock_audio_service.dart';
import 'package:lumina_app/services/streaming/secure_credential_store.dart';
import 'package:lumina_app/services/streaming/streaming_manager.dart';
import 'package:lumina_app/services/streaming/streaming_provider.dart';
import 'package:lumina_app/services/unified_search_controller.dart';
import 'package:lumina_app/ui/albums/album_detail_page.dart';
import 'package:lumina_app/ui/artists/artist_detail_page.dart';
import 'package:lumina_app/ui/home_screen.dart';
import 'package:lumina_app/ui/search/unified_search_results_view.dart';
import 'package:lumina_app/ui/theme/lumina_tokens.dart';
import 'package:material_ui/material_ui.dart';

class _ControlledSearchProvider implements StreamingProvider {
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

  final List<(String query, CancellationToken? cancel)> searchCalls = [];
  final List<String> resolvedIds = [];

  Future<StreamingCatalog> Function(String query, CancellationToken? cancel)?
      onSearch;
  Future<CanonicalAlbumDetail?> Function(String albumId)? onFetchAlbumDetail;

  _ControlledSearchProvider(
    this.kind, {
    this.onSearch,
    this.onFetchAlbumDetail,
  }) : meta = StreamingProviderMeta.byKind(kind)! {
    accountInfo = StreamingAccountInfo(displayName: '${meta.name} User');
  }

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
  }) async {
    if (onFetchAlbumDetail != null) {
      return onFetchAlbumDetail!(albumId);
    }
    return null;
  }

  @override
  Future<List<TrackInfo>> fetchPlaylistTracks(String playlistId) async =>
      const [];

  @override
  Future<StreamingCatalog> search(
    String query, {
    CancellationToken? cancel,
  }) async {
    searchCalls.add((query, cancel));
    if (onSearch != null) {
      return onSearch!(query, cancel);
    }
    return catalog;
  }

  @override
  Future<ResolvedStreamResult> resolveStream(
    TrackInfo track, {
    CancellationToken? cancel,
    Duration? timeout,
    int? playRequestId,
  }) async {
    resolvedIds.add(track.id);
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

class _TestStreamingAudioService extends MockAudioService {
  final List<TrackInfo> playedTracks = [];
  final List<TrackInfo> loadedStreamingTracks = [];

  @override
  Future<void> play({TrackInfo? track}) async {
    if (track != null) {
      playedTracks.add(track);
    }
    await super.play(track: track);
  }

  @override
  Future<void> playStreamUrlAsync({
    required TrackInfo track,
    required String streamUrl,
    Map<String, String> headers = const {},
    String? hintExtension,
    required int requestId,
  }) async {
    loadedStreamingTracks.add(track);
    await super.playStreamUrlAsync(
      track: track,
      streamUrl: streamUrl,
      headers: headers,
      hintExtension: hintExtension,
      requestId: requestId,
    );
  }
}

TrackInfo _streamingTrack({
  required String id,
  required String title,
  required String artist,
  required String album,
  required String providerName,
}) {
  return TrackInfo(
    id: id,
    title: title,
    artist: artist,
    album: album,
    duration: const Duration(minutes: 3, seconds: 42),
    format: const AudioFormat(
      codec: AudioCodec.flac,
      sampleRateHz: 96000,
      bitDepth: 24,
      channels: 2,
    ),
    providerName: providerName,
  );
}

void main() {
  group('Stage 4: UnifiedSearchController unit tests', () {
    test(
      '300ms debounce coalesces rapid typing, cancels stale CancellationToken, and discards stale request results',
      () async {
        final audio = MockAudioService();
        final cache = LibraryIndexCache();
        cache.seedSync(tracks: audio.queue);

        final completers = <String, Completer<StreamingCatalog>>{};
        final qobuz = _ControlledSearchProvider(
          'qobuz',
          onSearch: (query, cancel) {
            final c = Completer<StreamingCatalog>();
            completers[query] = c;
            return c.future;
          },
        );

        final streamingManager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          providers: {
            'qobuz': qobuz,
            'youtube_music': _ControlledSearchProvider('youtube_music')
              ..authState = StreamingAuthState.disconnected,
          },
        );
        final controller = UnifiedSearchController(
          audioService: audio,
          libraryCache: cache,
          streamingManager: streamingManager,
        );

        addTearDown(() {
          controller.dispose();
          streamingManager.dispose();
          cache.dispose();
          audio.dispose();
        });

        // Rapid typing within <300ms must coalesce into a single query.
        controller.updateQuery('p');
        await Future<void>.delayed(const Duration(milliseconds: 80));
        controller.updateQuery('pi');
        await Future<void>.delayed(const Duration(milliseconds: 80));
        controller.updateQuery('pin');
        expect(qobuz.searchCalls, isEmpty);

        // Wait past 300ms debounce for 'pin'.
        await Future<void>.delayed(const Duration(milliseconds: 340));
        expect(qobuz.searchCalls.length, 1);
        expect(qobuz.searchCalls.first.$1, 'pin');
        final staleToken = qobuz.searchCalls.first.$2!;
        expect(staleToken.isCancelled, isFalse);

        // Trigger a newer query while 'pin' is still in-flight.
        controller.updateQuery('pink', immediate: true);
        expect(staleToken.isCancelled, isTrue);
        expect(qobuz.searchCalls.length, 2);
        expect(qobuz.searchCalls.last.$1, 'pink');

        // Stale response for 'pin' arrives late -> must be discarded!
        completers['pin']!.complete(
          StreamingCatalog(
            tracks: [
              _streamingTrack(
                id: 'qobuz:stale-1',
                title: 'Stale Pin Track',
                artist: 'Stale Artist',
                album: 'Stale Album',
                providerName: 'Qobuz',
              ),
            ],
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          controller.streamingBuckets['qobuz']?.tracks ?? const [],
          isEmpty,
        );
        expect(controller.streamingBuckets['qobuz']?.isLoading, isTrue);

        // Fresh response for 'pink' arrives -> committed!
        completers['pink']!.complete(
          StreamingCatalog(
            tracks: [
              _streamingTrack(
                id: 'qobuz:fresh-1',
                title: 'Fresh Pink Track',
                artist: 'Pink Floyd',
                album: 'Meddle',
                providerName: 'Qobuz',
              ),
            ],
          ),
        );
        await Future<void>.delayed(Duration.zero);
        final bucket = controller.streamingBuckets['qobuz']!;
        expect(bucket.isLoading, isFalse);
        expect(bucket.tracks.map((t) => t.title), ['Fresh Pink Track']);
      },
    );

    test(
      'One failing and one timing-out streaming provider do NOT block local results or healthy provider',
      () async {
        final audio = MockAudioService();
        final cache = LibraryIndexCache();
        cache.seedSync(
          albums: const [
            CanonicalAlbumSummary(
              id: 'alb-local-pink',
              title: 'Wish You Were Here',
              artist: 'Pink Floyd',
              year: 1975,
            ),
          ],
          tracks: audio.queue,
        );

        final failingTidal = _ControlledSearchProvider(
          'tidal',
          onSearch: (_, _) async {
            throw const StreamingException('Tidal API 503 Unavailable');
          },
        );
        final hangingQobuz = _ControlledSearchProvider(
          'qobuz',
          onSearch: (_, cancel) {
            final c = Completer<StreamingCatalog>();
            return c.future;
          },
        );
        final healthyDeezer = _ControlledSearchProvider(
          'deezer',
          onSearch: (query, _) async {
            return StreamingCatalog(
              tracks: [
                _streamingTrack(
                  id: 'deezer:101',
                  title: 'Shine On You Crazy Diamond',
                  artist: 'Pink Floyd',
                  album: 'Wish You Were Here (Deezer)',
                  providerName: 'Deezer',
                ),
              ],
              albums: const [
                StreamingAlbum(
                  id: 'dz-alb-1',
                  title: 'Wish You Were Here (Deezer)',
                  artist: 'Pink Floyd',
                  year: 1975,
                  providerKind: 'deezer',
                ),
              ],
            );
          },
        );

        final streamingManager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          providers: {
            'tidal': failingTidal,
            'qobuz': hangingQobuz,
            'deezer': healthyDeezer,
            'youtube_music': _ControlledSearchProvider('youtube_music')
              ..authState = StreamingAuthState.disconnected,
          },
        );
        final controller = UnifiedSearchController(
          audioService: audio,
          libraryCache: cache,
          streamingManager: streamingManager,
          streamingTimeout: const Duration(milliseconds: 50),
        );

        addTearDown(() {
          controller.dispose();
          streamingManager.dispose();
          cache.dispose();
          audio.dispose();
        });

        controller.updateQuery('Pink', immediate: true);
        // Immediately on next microtask, local + healthy + failing resolve while hanging times out shortly after.
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(controller.localAlbums.length, 1);
        expect(controller.localArtists.map((a) => a.name), ['Pink Floyd']);
        expect(controller.localTracks, isNotEmpty);
        expect(
          controller.streamingBuckets['deezer']!.tracks.first.title,
          'Shine On You Crazy Diamond',
        );
        expect(controller.streamingBuckets['tidal']!.hasError, isTrue);
        expect(controller.streamingBuckets['qobuz']!.isLoading, isTrue);

        // Wait past 50ms timeout for hangingQobuz.
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(controller.streamingBuckets['qobuz']!.isLoading, isFalse);
        expect(controller.streamingBuckets['qobuz']!.hasError, isTrue);
        expect(controller.streamingBuckets['deezer']!.hasError, isFalse);
        expect(controller.visibleErrors.length, 2);
      },
    );
  });

  group('Stage 4: UnifiedSearchResultsView & HomeScreen integration', () {
    testWidgets(
      'Instant local results render while slow streaming is in flight; failing provider shows non-blocking banner; source tabs filter accurately',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final audio = _TestStreamingAudioService();
        final cache = LibraryIndexCache();
        cache.seedSync(
          albums: const [
            CanonicalAlbumSummary(
              id: 'alb-local-1',
              title: 'The Dark Side of the Moon',
              artist: 'Pink Floyd',
              year: 1973,
            ),
          ],
          tracks: audio.queue,
        );

        final slowQobuzCompleter = Completer<StreamingCatalog>();
        final qobuz = _ControlledSearchProvider(
          'qobuz',
          onSearch: (_, _) => slowQobuzCompleter.future,
        );
        final failingTidal = _ControlledSearchProvider(
          'tidal',
          onSearch: (_, _) async {
            throw const StreamingException('Tidal 權限已過期');
          },
        );
        final streamingManager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          providers: {
            'qobuz': qobuz,
            'tidal': failingTidal,
            'youtube_music': _ControlledSearchProvider('youtube_music')
              ..authState = StreamingAuthState.disconnected,
          },
        );
        final controller = UnifiedSearchController(
          audioService: audio,
          libraryCache: cache,
          streamingManager: streamingManager,
        );

        addTearDown(() {
          controller.dispose();
          streamingManager.dispose();
          cache.dispose();
          audio.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: UnifiedSearchResultsView(
                  controller: controller,
                  audioService: audio,
                  libraryCache: cache,
                  streamingManager: streamingManager,
                  onOpenLocalAlbum: (_) {},
                  onOpenStreamingAlbum: (_) {},
                  onOpenArtist: (_) {},
                  onPlayStreamingTrack: (t, {queueContext}) async {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        controller.updateQuery('Pink', immediate: true);
        await tester.pump();
        await tester.pump();

        // Instant local results appear immediately while Qobuz is still in flight.
        expect(find.byKey(const Key('search_track_local_trk-001')), findsOneWidget);
        expect(
          find.byKey(const Key('search_album_local_alb-local-1')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('search_artist_Pink Floyd')), findsOneWidget);
        expect(find.byKey(const Key('search_error_tidal')), findsOneWidget);
        expect(controller.streamingBuckets['qobuz']!.isLoading, isTrue);

        // Now resolve Qobuz with streaming track, album, and a streaming-only artist.
        slowQobuzCompleter.complete(
          StreamingCatalog(
            tracks: [
              _streamingTrack(
                id: 'qobuz:901',
                title: 'Echoes (Live)',
                artist: 'Pink Floyd',
                album: 'Live at Pompeii',
                providerName: 'Qobuz',
              ),
            ],
            albums: const [
              StreamingAlbum(
                id: 'qb-alb-9',
                title: 'Live at Pompeii',
                artist: 'David Gilmour',
                year: 2017,
                providerKind: 'qobuz',
                qualityLabel: '24-bit / 96 kHz',
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        // All view shows both local & Qobuz tracks/albums/artists.
        expect(find.byKey(const Key('search_track_local_trk-001')), findsOneWidget);
        expect(
          find.byKey(const Key('search_track_qobuz_qobuz:901')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('search_album_local_alb-local-1')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('search_album_qobuz_qb-alb-9')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('search_artist_Pink Floyd')), findsOneWidget);
        expect(
          find.byKey(const Key('search_artist_David Gilmour')),
          findsOneWidget,
        );

        // Filter to Local only -> Qobuz items hidden, local items kept.
        await tester.tap(find.byKey(const Key('search_source_local')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('search_track_local_trk-001')), findsOneWidget);
        expect(find.byKey(const Key('search_track_qobuz_qobuz:901')), findsNothing);
        expect(
          find.byKey(const Key('search_album_qobuz_qb-alb-9')),
          findsNothing,
        );
        expect(find.byKey(const Key('search_artist_David Gilmour')), findsNothing);

        // Filter to Qobuz only -> Local items hidden, Qobuz items shown.
        await tester.tap(find.byKey(const Key('search_source_qobuz')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('search_track_local_trk-001')), findsNothing);
        expect(
          find.byKey(const Key('search_track_qobuz_qobuz:901')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('search_album_local_alb-local-1')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('search_album_qobuz_qb-alb-9')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('search_artist_David Gilmour')),
          findsOneWidget,
        );

        // Filter back to All -> everything visible again.
        await tester.tap(find.byKey(const Key('search_source_all')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('search_track_local_trk-001')), findsOneWidget);
        expect(
          find.byKey(const Key('search_track_qobuz_qobuz:901')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'HomeScreen integration: top search pushes HomeTab.search, plays local/streaming tracks, opens album/artist details, and Esc/< returns cleanly to HomeTab.search',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final audio = _TestStreamingAudioService();
        final cache = LibraryIndexCache();
        cache.putAlbumDetailSync(
          const CanonicalAlbumDetail(
            id: 'alb-local-dsotm',
            title: 'The Dark Side of the Moon',
            artistName: 'Pink Floyd',
            releaseYear: 1973,
            versions: [],
          ),
        );
        cache.seedSync(
          albums: const [
            CanonicalAlbumSummary(
              id: 'alb-local-dsotm',
              title: 'The Dark Side of the Moon',
              artist: 'Pink Floyd',
              year: 1973,
            ),
          ],
          tracks: audio.queue,
        );

        final qobuz = _ControlledSearchProvider(
          'qobuz',
          onSearch: (query, _) async => StreamingCatalog(
            tracks: [
              _streamingTrack(
                id: 'qobuz:str-1',
                title: 'Any Colour You Like (Live)',
                artist: 'Pink Floyd',
                album: 'Delicate Sound of Thunder',
                providerName: 'Qobuz',
              ),
            ],
            albums: const [
              StreamingAlbum(
                id: 'qb-alb-live',
                title: 'Delicate Sound of Thunder',
                artist: 'Pink Floyd',
                year: 1988,
                providerKind: 'qobuz',
              ),
            ],
          ),
          onFetchAlbumDetail: (albumId) async => const CanonicalAlbumDetail(
            id: 'streaming:qobuz:qb-alb-live',
            title: 'Delicate Sound of Thunder',
            artistName: 'Pink Floyd',
            releaseYear: 1988,
            versions: [],
          ),
        );
        final streamingManager = StreamingManager(
          credentialStore: MemorySecureCredentialStore(),
          providers: {
            'qobuz': qobuz,
            'youtube_music': _ControlledSearchProvider('youtube_music')
              ..authState = StreamingAuthState.disconnected,
          },
        );
        final nav = NavHistoryController();

        addTearDown(() {
          nav.dispose();
          streamingManager.dispose();
          cache.dispose();
          audio.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            theme: LuminaTokens.buildDarkTheme(),
            home: HomeScreen(
              audioService: audio,
              libraryCache: cache,
              streamingManager: streamingManager,
              navHistoryController: nav,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('home_layout_aj')), findsOneWidget);

        // Ctrl+F -> expands top search and focuses top_search_input.
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('top_search_input')), findsOneWidget);

        // Typing pushes HomeTab.search once (no duplicate history entries across keystrokes).
        await tester.enterText(
          find.byKey(const Key('top_search_input')),
          'Pi',
        );
        await tester.pump();
        await tester.enterText(
          find.byKey(const Key('top_search_input')),
          'Pink',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        expect(nav.current.tab, HomeTab.search);
        expect(nav.backStack.length, 1);
        expect(nav.backStack.first.tab, HomeTab.home);
        expect(find.byKey(const Key('unified_search_results_view')), findsOneWidget);

        // Tap local track -> plays via AudioService.
        await tester.tap(find.byKey(const Key('search_track_local_trk-001')));
        await tester.pumpAndSettle();
        expect(audio.playedTracks.last.id, 'trk-001');

        // Tap streaming track -> resolves stream & loads via AudioService.
        await tester.tap(
          find.byKey(const Key('search_track_qobuz_qobuz:str-1')),
        );
        await tester.pumpAndSettle();
        expect(qobuz.resolvedIds, contains('qobuz:str-1'));
        expect(audio.loadedStreamingTracks.last.id, 'qobuz:str-1');

        Finder searchScrollable() => find.descendant(
          of: find.descendant(
            of: find.byKey(const Key('unified_search_results_view')),
            matching: find.byType(CustomScrollView),
          ),
          matching: find.byType(Scrollable),
        );

        // Tap local album -> opens AlbumDetailPage, Esc returns cleanly to HomeTab.search
        // WITHOUT being swallowed by top search collapse.
        await tester.scrollUntilVisible(
          find.byKey(const Key('search_album_local_alb-local-dsotm')),
          200,
          scrollable: searchScrollable(),
        );
        await tester.tap(
          find.byKey(const Key('search_album_local_alb-local-dsotm')),
        );
        await tester.pumpAndSettle();
        expect(nav.current.tab, HomeTab.albumDetail);
        expect(find.byType(AlbumDetailPage), findsOneWidget);
        expect(find.byKey(const Key('top_search_input')), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(nav.current.tab, HomeTab.search);
        expect(find.byKey(const Key('unified_search_results_view')), findsOneWidget);
        expect(find.byKey(const Key('top_search_input')), findsOneWidget);

        // Tap streaming album -> opens AlbumDetailPage, `<` returns to HomeTab.search.
        await tester.scrollUntilVisible(
          find.byKey(const Key('search_album_qobuz_qb-alb-live')),
          200,
          scrollable: searchScrollable(),
        );
        await tester.tap(
          find.byKey(const Key('search_album_qobuz_qb-alb-live')),
        );
        await tester.pumpAndSettle();
        expect(nav.current.tab, HomeTab.albumDetail);
        expect(nav.current.albumId, 'streaming:qobuz:qb-alb-live');

        await tester.tap(find.byKey(const Key('btn_nav_back')));
        await tester.pumpAndSettle();
        expect(nav.current.tab, HomeTab.search);
        expect(find.byKey(const Key('unified_search_results_view')), findsOneWidget);

        // Tap artist card -> opens ArtistDetailPage, Esc returns to HomeTab.search.
        await tester.scrollUntilVisible(
          find.byKey(const Key('search_artist_Pink Floyd')),
          200,
          scrollable: searchScrollable(),
        );
        await tester.tap(find.byKey(const Key('search_artist_Pink Floyd')));
        await tester.pumpAndSettle();
        expect(nav.current.tab, HomeTab.artistDetail);
        expect(find.byType(ArtistDetailPage), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(nav.current.tab, HomeTab.search);
        expect(find.byKey(const Key('unified_search_results_view')), findsOneWidget);

        // Clicking X clears top search and navigates back to Home.
        await tester.tap(find.byKey(const Key('btn_top_search_clear')));
        await tester.pumpAndSettle();
        expect(nav.current.tab, HomeTab.home);
        expect(find.byKey(const Key('home_layout_aj')), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byKey(const Key('top_search_input'))).controller!.text,
          isEmpty,
        );
      },
    );

    testWidgets(
      'UnifiedSearchResultsView renders without overflow at 800x600 & 1280x800 with multi-source results and errors',
      (WidgetTester tester) async {
        const sizes = [Size(1280, 800), Size(800, 600), Size(533, 400)];
        for (final size in sizes) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;

          final audio = _TestStreamingAudioService();
          final cache = LibraryIndexCache();
          cache.seedSync(
            albums: const [
              CanonicalAlbumSummary(
                id: 'alb-ov-1',
                title: 'Very Long Album Title That Should Ellipsize Cleanly Without Overflow',
                artist: 'Pink Floyd',
                year: 1973,
              ),
            ],
            tracks: audio.queue,
          );
          final qobuz = _ControlledSearchProvider(
            'qobuz',
            onSearch: (_, _) async => StreamingCatalog(
              tracks: [
                _streamingTrack(
                  id: 'qobuz:ov-1',
                  title: 'Very Long Streaming Track Title For Layout Overflow Verification',
                  artist: 'Pink Floyd',
                  album: 'Very Long Streaming Album Title',
                  providerName: 'Qobuz',
                ),
              ],
              albums: const [
                StreamingAlbum(
                  id: 'qb-ov-1',
                  title: 'Long Streaming Album Name',
                  artist: 'Pink Floyd',
                  year: 2020,
                  providerKind: 'qobuz',
                  qualityLabel: '24-bit / 192 kHz',
                ),
              ],
            ),
          );
          final failingTidal = _ControlledSearchProvider(
            'tidal',
            onSearch: (_, _) async => throw const StreamingException('Timeout'),
          );
          final streamingManager = StreamingManager(
            credentialStore: MemorySecureCredentialStore(),
            providers: {'qobuz': qobuz, 'tidal': failingTidal},
          );
          final controller = UnifiedSearchController(
            audioService: audio,
            libraryCache: cache,
            streamingManager: streamingManager,
          );

          await tester.pumpWidget(
            MaterialApp(
              theme: LuminaTokens.buildDarkTheme(),
              home: Scaffold(
                body: Padding(
                  padding: const EdgeInsets.all(12),
                  child: UnifiedSearchResultsView(
                    controller: controller,
                    audioService: audio,
                    libraryCache: cache,
                    streamingManager: streamingManager,
                    onOpenLocalAlbum: (_) {},
                    onOpenStreamingAlbum: (_) {},
                    onOpenArtist: (_) {},
                    onPlayStreamingTrack: (t, {queueContext}) async {},
                  ),
                ),
              ),
            ),
          );
          controller.updateQuery('Pink', immediate: true);
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: 'Overflow in UnifiedSearchResultsView at $size',
          );

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          controller.dispose();
          streamingManager.dispose();
          cache.dispose();
          audio.dispose();
        }
        tester.view.reset();
      },
    );
  });
}
