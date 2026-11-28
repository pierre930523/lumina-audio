import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/podcast_models.dart';
import '../../models/streaming_models.dart';
import '../../services/audio_service.dart';
import '../../services/podcast_store.dart';
import '../../services/streaming/streaming_manager.dart';
import '../artwork/streaming_cover_image.dart';
import '../common/frosted_glass_container.dart';
import '../common/track_hover_prefetch.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';

part 'podcasts_toolbar.dart';
part 'podcasts_tabs.dart';
part 'podcasts_sections.dart';
part 'podcasts_show_card.dart';
part 'podcasts_episode_tile.dart';

// ─── Stage 4: Real YouTube Music Podcasts View ───────────────────────────────

class PodcastsView extends StatefulWidget {
  final AudioService audioService;
  final StreamingManager? streamingManager;
  final Future<void> Function(
    TrackInfo track, {
    List<TrackInfo>? queueContext,
  })? onPlayStreamingTrack;
  final void Function(String showId, {PodcastShow? show})? onOpenPodcastShow;
  final VoidCallback? onOpenLogin;
  final PodcastStore? podcastStore;

  const PodcastsView({
    super.key,
    required this.audioService,
    this.streamingManager,
    this.onPlayStreamingTrack,
    this.onOpenPodcastShow,
    this.onOpenLogin,
    this.podcastStore,
  });

  @override
  State<PodcastsView> createState() => _PodcastsViewState();
}

class _PodcastsViewState extends State<PodcastsView> {
  static const List<({int idx, String keyName, String label, IconData icon})>
      _tabs = <({int idx, String keyName, String label, IconData icon})>[
    (
      idx: 0,
      keyName: 'podcast_tab_my_shows',
      label: '我的節目',
      icon: Icons.bookmarks_outlined,
    ),
    (
      idx: 1,
      keyName: 'podcast_tab_explore',
      label: '探索推薦',
      icon: Icons.explore_outlined,
    ),
    (
      idx: 2,
      keyName: 'podcast_tab_latest_episodes',
      label: '最新單集',
      icon: Icons.new_releases_outlined,
    ),
  ];

  final GlideScrollController _scrollController = GlideScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  late PodcastStore _store;
  int _selectedTab = 1;
  bool _userSelectedTab = false;

  List<PodcastShow> _remoteMyShows = const <PodcastShow>[];
  List<PodcastEpisode> _remoteMyEpisodes = const <PodcastEpisode>[];
  List<PodcastShow> _exploreShows = const <PodcastShow>[];
  List<PodcastEpisode> _exploreEpisodes = const <PodcastEpisode>[];
  String? _exploreContinuation;

  bool _loadingExplore = false;
  bool _loadingMyPodcasts = false;
  bool _loadingMoreExplore = false;
  String? _feedError;

  String _searchQuery = '';
  bool _searching = false;
  String? _searchError;
  List<PodcastShow> _searchShows = const <PodcastShow>[];
  List<PodcastEpisode> _searchEpisodes = const <PodcastEpisode>[];
  Timer? _searchDebounce;
  CancellationToken? _feedCancel;
  CancellationToken? _searchCancel;

  bool get _isConnected =>
      widget.streamingManager?.isYouTubeMusicConnected ?? false;

  @override
  void initState() {
    super.initState();
    _store = widget.podcastStore ?? PodcastStore.instance;
    _store.ensureLoadedSync();
    _selectedTab =
        (_isConnected || _store.bookmarkedShows.isNotEmpty) ? 0 : 1;
    widget.streamingManager?.addListener(_onStreamingManagerChanged);
    _searchFocusNode.addListener(_onSearchFocusChanged);
    _scheduleInitialFetch();
  }

  @override
  void didUpdateWidget(covariant PodcastsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.podcastStore != widget.podcastStore) {
      _store = widget.podcastStore ?? PodcastStore.instance;
      _store.ensureLoadedSync();
    }
    if (oldWidget.streamingManager != widget.streamingManager) {
      oldWidget.streamingManager?.removeListener(_onStreamingManagerChanged);
      widget.streamingManager?.addListener(_onStreamingManagerChanged);
      if (!_userSelectedTab) {
        _selectedTab =
            (_isConnected || _store.bookmarkedShows.isNotEmpty) ? 0 : 1;
      }
      _scheduleInitialFetch();
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _feedCancel?.cancel();
    _searchCancel?.cancel();
    widget.streamingManager?.removeListener(_onStreamingManagerChanged);
    _searchFocusNode.removeListener(_onSearchFocusChanged);
    _searchFocusNode.dispose();
    _searchCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _setState(VoidCallback fn) => setState(fn);

  void _onSearchFocusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _onStreamingManagerChanged() {
    if (!mounted) return;
    if (!_userSelectedTab &&
        (_isConnected || _store.bookmarkedShows.isNotEmpty) &&
        _selectedTab == 1 &&
        _exploreShows.isEmpty) {
      _selectedTab = 0;
    }
    setState(() {});
  }

  void _scheduleInitialFetch() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refreshFeeds();
    });
  }

  Future<void> _refreshFeeds() async {
    final sm = widget.streamingManager;
    if (sm == null) return;

    _feedCancel?.cancel();
    final cancel = CancellationToken();
    _feedCancel = cancel;

    setState(() {
      _loadingExplore = true;
      _loadingMyPodcasts = _isConnected;
      _feedError = null;
    });

    try {
      final results = await Future.wait<Object>(<Future<Object>>[
        sm.fetchExplorePodcasts(cancel: cancel),
        if (_isConnected)
          sm.fetchMyPodcasts(cancel: cancel)
        else
          Future<PodcastLibraryResult>.value(const PodcastLibraryResult()),
      ]);
      if (!mounted || cancel.isCancelled) return;
      final exploreRes = results[0] as PodcastExploreResult;
      final myRes = results[1] as PodcastLibraryResult;

      setState(() {
        _exploreShows = exploreRes.shows;
        _exploreEpisodes = exploreRes.episodes;
        _exploreContinuation = exploreRes.continuationToken;
        _remoteMyShows = myRes.shows;
        _remoteMyEpisodes = myRes.episodes;
        _loadingExplore = false;
        _loadingMyPodcasts = false;
      });
    } on StreamingException catch (e) {
      if (!mounted || e.isCancelled || cancel.isCancelled) return;
      setState(() {
        _feedError = e.message;
        _loadingExplore = false;
        _loadingMyPodcasts = false;
      });
    } catch (e) {
      if (!mounted || cancel.isCancelled) return;
      setState(() {
        _feedError = '載入 Podcast 失敗：$e';
        _loadingExplore = false;
        _loadingMyPodcasts = false;
      });
    }
  }

  Future<void> _loadMoreExplore() async {
    final sm = widget.streamingManager;
    final cont = _exploreContinuation?.trim();
    if (sm == null ||
        cont == null ||
        cont.isEmpty ||
        _loadingMoreExplore ||
        _loadingExplore) {
      return;
    }

    setState(() => _loadingMoreExplore = true);
    try {
      final next = await sm.fetchExplorePodcasts(
        continuation: cont,
        cancel: _feedCancel,
      );
      if (!mounted) return;
      final seenShows = _exploreShows.map((s) => s.id).toSet();
      final seenEps = _exploreEpisodes.map((e) => e.videoId).toSet();
      final mergedShows = <PodcastShow>[
        ..._exploreShows,
        for (final s in next.shows)
          if (seenShows.add(s.id)) s,
      ];
      final mergedEps = <PodcastEpisode>[
        ..._exploreEpisodes,
        for (final ep in next.episodes)
          if (seenEps.add(ep.videoId)) ep,
      ];
      setState(() {
        _exploreShows = mergedShows;
        _exploreEpisodes = mergedEps;
        _exploreContinuation =
            (next.continuationToken != null && next.continuationToken != cont)
                ? next.continuationToken
                : null;
        _loadingMoreExplore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMoreExplore = false);
    }
  }

  void _onSearchChanged(String raw) {
    final trimmed = raw.trim();
    _searchDebounce?.cancel();
    if (trimmed.isEmpty) {
      _searchCancel?.cancel();
      setState(() {
        _searchQuery = '';
        _searching = false;
        _searchError = null;
        _searchShows = const <PodcastShow>[];
        _searchEpisodes = const <PodcastEpisode>[];
      });
      return;
    }

    setState(() {
      _searchQuery = trimmed;
      _searching = true;
      _searchError = null;
    });

    _searchDebounce = Timer(const Duration(milliseconds: 220), () {
      _performSearch(trimmed);
    });
  }

  Future<void> _performSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final sm = widget.streamingManager;
    if (sm == null) {
      setState(() => _searching = false);
      return;
    }

    _searchCancel?.cancel();
    final cancel = CancellationToken();
    _searchCancel = cancel;

    setState(() {
      _searchQuery = trimmed;
      _searching = true;
      _searchError = null;
    });

    try {
      final res = await sm.searchPodcasts(trimmed, cancel: cancel);
      if (!mounted || cancel.isCancelled) return;
      setState(() {
        _searchShows = res.shows;
        _searchEpisodes = res.episodes;
        _searching = false;
      });
    } on StreamingException catch (e) {
      if (!mounted || e.isCancelled || cancel.isCancelled) return;
      setState(() {
        _searchError = e.message;
        _searching = false;
      });
    } catch (e) {
      if (!mounted || cancel.isCancelled) return;
      setState(() {
        _searchError = '搜尋 Podcast 失敗：$e';
        _searching = false;
      });
    }
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchCancel?.cancel();
    _searchCtrl.clear();
    setState(() {
      _searchQuery = '';
      _searching = false;
      _searchError = null;
      _searchShows = const <PodcastShow>[];
      _searchEpisodes = const <PodcastEpisode>[];
    });
  }

  void _focusSearch() {
    _searchFocusNode.requestFocus();
  }

  void _openShow(PodcastShow show) {
    widget.onOpenPodcastShow?.call(show.id, show: show);
  }

  Future<void> _playEpisode(
    PodcastEpisode episode,
    List<PodcastEpisode> contextEpisodes,
  ) async {
    final track = episode.toTrack();
    final queue = contextEpisodes.isNotEmpty
        ? contextEpisodes.map((e) => e.toTrack()).toList()
        : <TrackInfo>[track];
    if (widget.onPlayStreamingTrack != null) {
      await widget.onPlayStreamingTrack!(track, queueContext: queue);
      return;
    }
    await widget.audioService.play(track: track);
  }

  List<PodcastEpisode> get _combinedLatestEpisodes {
    final merged = <PodcastEpisode>[];
    final seen = <String>{};
    for (final ep in _remoteMyEpisodes) {
      if (seen.add(ep.videoId)) merged.add(ep);
    }
    for (final ep in _exploreEpisodes) {
      if (seen.add(ep.videoId)) merged.add(ep);
    }
    return merged;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: widget.audioService.stateStream,
      initialData: widget.audioService.currentState,
      builder: (context, stateSnap) {
        final playbackState =
            stateSnap.data ?? widget.audioService.currentState;
        return ListenableBuilder(
          listenable: _store,
          builder: (context, _) {
            return LayoutBuilder(
              builder: (context, constraints) {
                final availW = constraints.maxWidth;
                return Column(
                  key: const Key('podcasts_view_root'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildFrostedToolbar(availW: availW),
                    const SizedBox(height: LuminaTokens.spaceSm),
                    Expanded(
                      child: _buildMainScrollView(
                        availW: availW,
                        playbackState: playbackState,
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}
