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

  final ScrollController _scrollController = ScrollController();
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

  Widget _buildFrostedToolbar({required double availW}) {
    final isWideSingleRow = availW >= 860;
    final isConnected = _isConnected;

    return FrostedGlassContainer(
      key: const Key('podcasts_compact_toolbar'),
      blurSigma: LuminaTokens.glassPillBlur,
      color: LuminaTokens.glassSidebarBg,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: LuminaTokens.glassSidebarBorder),
      padding: EdgeInsets.symmetric(
        horizontal: availW < 540 ? 10 : 14,
        vertical: isWideSingleRow ? 9 : 10,
      ),
      child: isWideSingleRow
          ? Row(
              children: [
                _buildToolbarTitleBadge(isConnected: isConnected),
                const SizedBox(width: 12),
                _buildSegmentedTabs(availW: availW),
                const SizedBox(width: 12),
                Expanded(child: _buildSearchField()),
                const SizedBox(width: 8),
                _buildQuickSearchAddButton(compact: availW < 1040),
                const SizedBox(width: 6),
                _buildRefreshButton(),
              ],
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _buildToolbarTitleBadge(
                        isConnected: isConnected,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: _buildSegmentedTabs(availW: availW),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _buildRefreshButton(),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _buildSearchField()),
                    const SizedBox(width: 8),
                    _buildQuickSearchAddButton(compact: availW < 520),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _buildToolbarTitleBadge({required bool isConnected}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: LuminaTokens.glassPillBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: LuminaTokens.glassPillBorder),
          ),
          child: const Icon(
            Icons.podcasts_rounded,
            size: 18,
            color: LuminaTokens.glassTextPrimary,
          ),
        ),
        const SizedBox(width: 9),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Flexible(
                    child: Text(
                      'Podcast',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: LuminaTokens.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: isConnected
                          ? LuminaTokens.statusSuccess
                          : LuminaTokens.glassTextSecondary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 1),
              Text(
                isConnected
                    ? 'YouTube Music 已連線 · 同步訂閱與單集'
                    : 'YouTube Music 免登入探索與即時播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 11,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSegmentedTabs({required double availW}) {
    final showIcons = availW >= 720;
    final horizontalPad = availW >= 840 ? 12.0 : 9.0;

    return Container(
      height: 34,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: LuminaTokens.glassSegmentTrackBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        border: Border.all(color: LuminaTokens.glassSegmentTrackBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final tab in _tabs)
            Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: Key(tab.keyName),
                borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
                onTap: () {
                  setState(() {
                    _userSelectedTab = true;
                    _selectedTab = tab.idx;
                    if (_searchQuery.isNotEmpty) {
                      _clearSearch();
                    }
                  });
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  height: 28,
                  padding: EdgeInsets.symmetric(horizontal: horizontalPad),
                  decoration: BoxDecoration(
                    borderRadius:
                        BorderRadius.circular(LuminaTokens.radiusPill),
                    color: (_selectedTab == tab.idx && _searchQuery.isEmpty)
                        ? LuminaTokens.glassSegmentSelectedBg
                        : Colors.transparent,
                    border: (_selectedTab == tab.idx && _searchQuery.isEmpty)
                        ? Border.all(
                            color: LuminaTokens.glassSegmentSelectedBorder,
                          )
                        : null,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (showIcons) ...[
                        Icon(
                          tab.icon,
                          size: 13.5,
                          color:
                              (_selectedTab == tab.idx && _searchQuery.isEmpty)
                                  ? Colors.white
                                  : LuminaTokens.glassTextSecondary,
                        ),
                        const SizedBox(width: 5),
                      ],
                      Text(
                        tab.label,
                        style: TextStyle(
                          color:
                              (_selectedTab == tab.idx && _searchQuery.isEmpty)
                                  ? Colors.white
                                  : LuminaTokens.glassTextSecondary,
                          fontSize: 12,
                          fontWeight:
                              (_selectedTab == tab.idx && _searchQuery.isEmpty)
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    final hasFocus = _searchFocusNode.hasFocus;
    final hasText = _searchCtrl.text.isNotEmpty;

    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: LuminaTokens.glassPillBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        border: Border.all(
          color: hasFocus ? LuminaTokens.focusRing : LuminaTokens.glassPillBorder,
          width: hasFocus ? 1.4 : 1.0,
        ),
      ),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 10, right: 6),
            child: Icon(
              Icons.search_rounded,
              size: 15,
              color: LuminaTokens.textSecondary,
            ),
          ),
          Expanded(
            child: TextField(
              key: const Key('podcast_search_input'),
              controller: _searchCtrl,
              focusNode: _searchFocusNode,
              onChanged: _onSearchChanged,
              onSubmitted: _performSearch,
              maxLines: 1,
              textAlignVertical: TextAlignVertical.center,
              style: const TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 12.5,
                height: 1.2,
              ),
              cursorColor: LuminaTokens.glassTextPrimary,
              decoration: const InputDecoration(
                isDense: true,
                isCollapsed: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: '搜尋 YouTube Music Podcast 節目或單集...',
                hintStyle: TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 12,
                ),
                contentPadding: EdgeInsets.symmetric(vertical: 4),
              ),
            ),
          ),
          if (hasText)
            IconButton(
              key: const Key('btn_podcast_search_clear'),
              tooltip: '清除搜尋',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              icon: const Icon(
                Icons.close_rounded,
                size: 15,
                color: LuminaTokens.textSecondary,
              ),
              onPressed: _clearSearch,
            ),
        ],
      ),
    );
  }

  Widget _buildQuickSearchAddButton({required bool compact}) {
    if (compact) {
      return IconButton(
        key: const Key('btn_podcast_focus_search'),
        tooltip: '搜尋／新增 Podcast',
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        padding: EdgeInsets.zero,
        icon: const Icon(
          Icons.add_circle_outline_rounded,
          size: 18,
          color: LuminaTokens.glassTextPrimary,
        ),
        onPressed: _focusSearch,
      );
    }
    return OutlinedButton.icon(
      key: const Key('btn_podcast_focus_search'),
      onPressed: _focusSearch,
      icon: const Icon(Icons.add_rounded, size: 15),
      label: const Text(
        '搜尋／新增 Podcast',
        style: TextStyle(fontSize: 12),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: LuminaTokens.glassTextPrimary,
        backgroundColor: LuminaTokens.glassPillBg,
        side: const BorderSide(color: LuminaTokens.glassPillBorder),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
    );
  }

  Widget _buildRefreshButton() {
    final isLoading = _loadingExplore || _loadingMyPodcasts || _searching;
    return IconButton(
      key: const Key('btn_podcast_refresh'),
      tooltip: '重新整理 Podcast',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      icon: isLoading
          ? const SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: LuminaTokens.glassTextPrimary,
              ),
            )
          : const Icon(
              Icons.refresh_rounded,
              size: 18,
              color: LuminaTokens.textSecondary,
            ),
      onPressed: isLoading
          ? null
          : () {
              if (_searchQuery.isNotEmpty) {
                _performSearch(_searchQuery);
              } else {
                _refreshFeeds();
              }
            },
    );
  }

  Widget _buildMainScrollView({
    required double availW,
    required PlaybackState playbackState,
  }) {
    final slivers = <Widget>[];

    if (_searchQuery.isNotEmpty) {
      slivers.addAll(
        _buildSearchSlivers(
          availW: availW,
          playbackState: playbackState,
        ),
      );
    } else if (_selectedTab == 0) {
      slivers.addAll(
        _buildMyShowsSlivers(
          availW: availW,
          playbackState: playbackState,
        ),
      );
    } else if (_selectedTab == 1) {
      slivers.addAll(
        _buildExploreSlivers(
          availW: availW,
          playbackState: playbackState,
        ),
      );
    } else {
      slivers.addAll(
        _buildLatestEpisodesSlivers(
          availW: availW,
          playbackState: playbackState,
        ),
      );
    }

    slivers.add(
      const SliverToBoxAdapter(
        child: SizedBox(height: LuminaTokens.bottomScrollClearance),
      ),
    );

    return CustomScrollView(
      key: const Key('podcasts_list_view'),
      controller: _scrollController,
      slivers: slivers,
    );
  }

  List<Widget> _buildMyShowsSlivers({
    required double availW,
    required PlaybackState playbackState,
  }) {
    final slivers = <Widget>[];
    final isConnected = _isConnected;
    final mergedShows = _store.mergeWithRemoteShows(_remoteMyShows);

    if (!isConnected) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: _buildGuestLoginPromptCard(),
          ),
        ),
      );
    }

    if (_loadingMyPodcasts && mergedShows.isEmpty) {
      slivers.add(
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: LuminaTokens.glassTextPrimary,
            ),
          ),
        ),
      );
      return slivers;
    }

    if (mergedShows.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildSectionHeader(
            icon: Icons.bookmarks_rounded,
            title: isConnected
                ? '已訂閱與收藏節目（${mergedShows.length}）'
                : '已收藏節目（${mergedShows.length}）',
          ),
        ),
      );
      slivers.add(
        _buildShowsGridSliver(shows: mergedShows, availW: availW),
      );
    } else {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildEmptyMyShowsCard(),
        ),
      );
    }

    if (_remoteMyEpisodes.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 18),
            child: _buildSectionHeader(
              icon: Icons.headphones_rounded,
              title: '訂閱節目最新單集',
            ),
          ),
        ),
      );
      slivers.add(
        SliverList.builder(
          itemCount: _remoteMyEpisodes.length,
          itemBuilder: (context, index) => _buildEpisodeTile(
            episode: _remoteMyEpisodes[index],
            contextEpisodes: _remoteMyEpisodes,
            playbackState: playbackState,
            isCompact: availW < 520,
          ),
        ),
      );
    }

    return slivers;
  }

  List<Widget> _buildExploreSlivers({
    required double availW,
    required PlaybackState playbackState,
  }) {
    final slivers = <Widget>[];

    if (_loadingExplore &&
        _exploreShows.isEmpty &&
        _exploreEpisodes.isEmpty) {
      slivers.add(
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: CircularProgressIndicator(
              key: Key('podcast_explore_loading'),
              strokeWidth: 2.2,
              color: LuminaTokens.glassTextPrimary,
            ),
          ),
        ),
      );
      return slivers;
    }

    if (_feedError != null &&
        _exploreShows.isEmpty &&
        _exploreEpisodes.isEmpty) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _feedError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: LuminaTokens.statusError,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  key: const Key('btn_podcast_explore_retry'),
                  onPressed: _refreshFeeds,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: LuminaTokens.glassTextPrimary,
                    backgroundColor: LuminaTokens.glassPillBg,
                    side: const BorderSide(
                      color: LuminaTokens.glassPillBorder,
                    ),
                  ),
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: const Text('重試'),
                ),
              ],
            ),
          ),
        ),
      );
      return slivers;
    }

    if (_exploreShows.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildSectionHeader(
            icon: Icons.explore_rounded,
            title: '熱門與精選 Podcast 節目',
          ),
        ),
      );
      slivers.add(
        _buildShowsGridSliver(shows: _exploreShows, availW: availW),
      );
    }

    if (_exploreEpisodes.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: _exploreShows.isNotEmpty ? 18 : 0),
            child: _buildSectionHeader(
              icon: Icons.bolt_rounded,
              title: '精選單集即時聽',
            ),
          ),
        ),
      );
      slivers.add(
        SliverList.builder(
          itemCount: _exploreEpisodes.length,
          itemBuilder: (context, index) => _buildEpisodeTile(
            episode: _exploreEpisodes[index],
            contextEpisodes: _exploreEpisodes,
            playbackState: playbackState,
            isCompact: availW < 520,
          ),
        ),
      );
    }

    if (_exploreShows.isEmpty && _exploreEpisodes.isEmpty) {
      slivers.add(
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text(
              '目前尚無推薦 Podcast，請點擊上方重新整理或直接搜尋節目',
              style: TextStyle(
                color: LuminaTokens.textMuted,
                fontSize: 13,
              ),
            ),
          ),
        ),
      );
    } else if (_exploreContinuation != null &&
        _exploreContinuation!.trim().isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: OutlinedButton.icon(
                key: const Key('btn_podcast_explore_load_more'),
                onPressed: _loadingMoreExplore ? null : _loadMoreExplore,
                icon: const Icon(Icons.expand_more_rounded, size: 18),
                label: Text(_loadingMoreExplore ? '載入更多中...' : '載入更多推薦'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: LuminaTokens.glassTextPrimary,
                  backgroundColor: LuminaTokens.glassPillBg,
                  side: const BorderSide(color: LuminaTokens.glassPillBorder),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return slivers;
  }

  List<Widget> _buildLatestEpisodesSlivers({
    required double availW,
    required PlaybackState playbackState,
  }) {
    final episodes = _combinedLatestEpisodes;
    if ((_loadingExplore || _loadingMyPodcasts) && episodes.isEmpty) {
      return <Widget>[
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: LuminaTokens.glassTextPrimary,
            ),
          ),
        ),
      ];
    }

    if (episodes.isEmpty) {
      return <Widget>[
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text(
              '目前尚無最新單集，請使用上方搜尋探索節目',
              style: TextStyle(
                color: LuminaTokens.textMuted,
                fontSize: 13,
              ),
            ),
          ),
        ),
      ];
    }

    return <Widget>[
      SliverToBoxAdapter(
        child: _buildSectionHeader(
          icon: Icons.new_releases_rounded,
          title: '最新單集（${episodes.length}）',
        ),
      ),
      SliverList.builder(
        itemCount: episodes.length,
        itemBuilder: (context, index) => _buildEpisodeTile(
          episode: episodes[index],
          contextEpisodes: episodes,
          playbackState: playbackState,
          isCompact: availW < 520,
        ),
      ),
    ];
  }

  List<Widget> _buildSearchSlivers({
    required double availW,
    required PlaybackState playbackState,
  }) {
    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              const Icon(
                Icons.search_rounded,
                size: 17,
                color: LuminaTokens.glassTextSecondary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '「$_searchQuery」的 Podcast 搜尋結果',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton.icon(
                key: const Key('btn_podcast_exit_search'),
                onPressed: _clearSearch,
                style: TextButton.styleFrom(
                  foregroundColor: LuminaTokens.glassTextPrimary,
                ),
                icon: const Icon(Icons.arrow_back_rounded, size: 15),
                label: const Text('返回列表', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
        ),
      ),
    ];

    if (_searching && _searchShows.isEmpty && _searchEpisodes.isEmpty) {
      slivers.add(
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: CircularProgressIndicator(
              key: Key('podcast_search_loading'),
              strokeWidth: 2.2,
              color: LuminaTokens.glassTextPrimary,
            ),
          ),
        ),
      );
      return slivers;
    }

    if (_searchError != null &&
        _searchShows.isEmpty &&
        _searchEpisodes.isEmpty) {
      slivers.add(
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text(
              _searchError!,
              style: const TextStyle(
                color: LuminaTokens.statusError,
                fontSize: 13,
              ),
            ),
          ),
        ),
      );
      return slivers;
    }

    if (_searchShows.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildSectionHeader(
            icon: Icons.podcasts_rounded,
            title: 'Podcast 節目（${_searchShows.length}）',
          ),
        ),
      );
      slivers.add(
        _buildShowsGridSliver(shows: _searchShows, availW: availW),
      );
    }

    if (_searchEpisodes.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(top: _searchShows.isNotEmpty ? 18 : 0),
            child: _buildSectionHeader(
              icon: Icons.headphones_rounded,
              title: '單集節目（${_searchEpisodes.length}）',
            ),
          ),
        ),
      );
      slivers.add(
        SliverList.builder(
          itemCount: _searchEpisodes.length,
          itemBuilder: (context, index) => _buildEpisodeTile(
            episode: _searchEpisodes[index],
            contextEpisodes: _searchEpisodes,
            playbackState: playbackState,
            isCompact: availW < 520,
          ),
        ),
      );
    }

    if (_searchShows.isEmpty && _searchEpisodes.isEmpty) {
      slivers.add(
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Text(
              '找不到符合的 Podcast 節目或單集',
              style: TextStyle(
                color: LuminaTokens.textMuted,
                fontSize: 13,
              ),
            ),
          ),
        ),
      );
    }

    return slivers;
  }

  Widget _buildGuestLoginPromptCard() {
    return Container(
      key: const Key('podcast_guest_login_card'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(
        color: LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        border: Border.all(color: LuminaTokens.glassCardBorder),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 10,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cloud_sync_outlined,
                size: 20,
                color: LuminaTokens.glassTextPrimary,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Text(
                      '登入 YouTube Music 同步訂閱節目與最新單集',
                      style: TextStyle(
                        color: LuminaTokens.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '未登入時仍可直接於「探索推薦」或搜尋收藏節目並即時播放所有單集。',
                      style: TextStyle(
                        color: LuminaTokens.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.onOpenLogin != null)
                FilledButton.icon(
                  key: const Key('btn_podcast_open_login'),
                  onPressed: widget.onOpenLogin,
                  icon: const Icon(Icons.login_rounded, size: 16),
                  label: const Text(
                    '登入 YouTube Music',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: LuminaTokens.glassSwitchOnTrack,
                    foregroundColor: LuminaTokens.onAccentDark,
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 8,
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                key: const Key('btn_podcast_switch_to_explore'),
                onPressed: () => setState(() {
                  _userSelectedTab = true;
                  _selectedTab = 1;
                }),
                icon: const Icon(Icons.explore_outlined, size: 16),
                label: const Text(
                  '探索推薦',
                  style: TextStyle(fontSize: 12.5),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: LuminaTokens.glassTextPrimary,
                  backgroundColor: LuminaTokens.glassPillBg,
                  side: const BorderSide(color: LuminaTokens.glassPillBorder),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyMyShowsCard() {
    return Container(
      key: const Key('podcast_empty_my_shows_card'),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        border: Border.all(color: LuminaTokens.glassCardBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.podcasts_rounded,
            size: 36,
            color: LuminaTokens.textMuted,
          ),
          const SizedBox(height: 10),
          const Text(
            '尚無收藏或訂閱的 Podcast 節目',
            style: TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '前往「探索推薦」或使用上方搜尋框發掘感興趣的 YouTube Music Podcast 節目並加入收藏。',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: LuminaTokens.textSecondary,
              fontSize: 12.5,
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            key: const Key('btn_empty_go_explore'),
            onPressed: () => setState(() {
              _userSelectedTab = true;
              _selectedTab = 1;
            }),
            icon: const Icon(Icons.explore_rounded, size: 16),
            label: const Text('瀏覽探索推薦'),
            style: OutlinedButton.styleFrom(
              foregroundColor: LuminaTokens.glassTextPrimary,
              backgroundColor: LuminaTokens.glassPillBg,
              side: const BorderSide(color: LuminaTokens.glassPillBorder),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader({
    required IconData icon,
    required String title,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, size: 17, color: LuminaTokens.glassTextSecondary),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShowsGridSliver({
    required List<PodcastShow> shows,
    required double availW,
  }) {
    return SliverList.builder(
      itemCount: shows.length,
      itemBuilder: (context, index) {
        final show = shows[index];
        return _buildShowCard(show: show, isCompact: availW < 520);
      },
    );
  }

  Widget _buildShowCard({
    required PodcastShow show,
    required bool isCompact,
  }) {
    final isBookmarked = _store.isBookmarked(show.id);
    final subParts = <String>[
      if (show.author.trim().isNotEmpty) show.author.trim(),
      if (show.episodeCountLabel != null &&
          show.episodeCountLabel!.trim().isNotEmpty)
        show.episodeCountLabel!.trim(),
    ];

    return Container(
      key: Key('podcast_show_card_${show.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        border: Border.all(color: LuminaTokens.glassCardBorder),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        hoverColor: LuminaTokens.glassRowHoverBg,
        onTap: () => _openShow(show),
        child: Padding(
          padding: const EdgeInsets.all(11),
          child: Row(
            children: [
              _buildNetworkArtwork(
                url: show.artworkUrl,
                size: isCompact ? 56 : 64,
                borderRadius: 8,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      show.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subParts.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subParts.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                    if (show.latestEpisodeTitle != null &&
                        show.latestEpisodeTitle!.trim().isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        '最新：${show.latestEpisodeTitle!.trim()}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.textMuted,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: Key('btn_bookmark_show_${show.id}'),
                tooltip: isBookmarked ? '取消收藏節目' : '收藏節目',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                padding: EdgeInsets.zero,
                icon: Icon(
                  isBookmarked
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  size: 20,
                  color: isBookmarked
                      ? LuminaTokens.glassTextPrimary
                      : LuminaTokens.textSecondary,
                ),
                onPressed: () => _store.toggleBookmark(show),
              ),
              IconButton(
                key: Key('btn_open_show_${show.id}'),
                tooltip: '檢視節目單集',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                padding: EdgeInsets.zero,
                icon: const Icon(
                  Icons.chevron_right_rounded,
                  size: 22,
                  color: LuminaTokens.textSecondary,
                ),
                onPressed: () => _openShow(show),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEpisodeTile({
    required PodcastEpisode episode,
    required List<PodcastEpisode> contextEpisodes,
    required PlaybackState playbackState,
    required bool isCompact,
  }) {
    final trackId = episode.toTrack().id;
    final isCurrentTrack = playbackState.track?.id == trackId;
    final isPlaying =
        isCurrentTrack && playbackState.status == PlaybackStatus.playing;
    final isLoading = isCurrentTrack &&
        (playbackState.status == PlaybackStatus.loading ||
            playbackState.status == PlaybackStatus.buffering);
    final progress = _store.progressFor(trackId);
    final durStr = episode.duration > Duration.zero
        ? PodcastEpisodeProgress.formatSeconds(episode.duration.inSeconds)
        : '';

    final metaParts = <String>[
      if (episode.showTitle.trim().isNotEmpty) episode.showTitle.trim(),
      if (episode.publishedLabel != null &&
          episode.publishedLabel!.trim().isNotEmpty)
        episode.publishedLabel!.trim(),
      if (durStr.isNotEmpty) durStr,
    ];

    return TrackHoverPrefetch(
      trackIdentity: episode.externalAudioUrl ?? episode.videoId,
      trackBuilder: episode.toTrack,
      child: Container(
        key: Key('podcast_episode_tile_${episode.videoId}'),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: isCurrentTrack
              ? LuminaTokens.glassCardActiveBg
              : LuminaTokens.glassCardBg,
          borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
          border: Border.all(
            color: isCurrentTrack
                ? LuminaTokens.glassCoverRim
                : LuminaTokens.glassCardBorder,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
          hoverColor: LuminaTokens.glassRowHoverBg,
          onTap: () {
            if (isCurrentTrack) {
              widget.audioService.togglePlayPause();
            } else {
              _playEpisode(episode, contextEpisodes);
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildNetworkArtwork(
                  url: episode.artworkUrl,
                  size: isCompact ? 52 : 60,
                  borderRadius: 8,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        episode.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isCurrentTrack
                              ? Colors.white
                              : LuminaTokens.glassTextPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                      if (metaParts.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              metaParts.join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: LuminaTokens.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                            if (progress != null &&
                                (progress.positionSeconds > 0 ||
                                    progress.completed))
                              Container(
                                key: Key(
                                  'podcast_episode_progress_${episode.videoId}',
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: progress.completed
                                      ? LuminaTokens.statusSuccess
                                          .withValues(alpha: 0.14)
                                      : LuminaTokens.glassPillBg,
                                  borderRadius: BorderRadius.circular(
                                    LuminaTokens.radiusPill,
                                  ),
                                  border: progress.completed
                                      ? null
                                      : Border.all(
                                          color: LuminaTokens.glassPillBorder,
                                        ),
                                ),
                                child: Text(
                                  progress.completed
                                      ? '已播完'
                                      : '已播 ${progress.formattedPosition}',
                                  style: TextStyle(
                                    color: progress.completed
                                        ? LuminaTokens.statusSuccess
                                        : LuminaTokens.glassTextSecondary,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                      if (episode.description != null &&
                          episode.description!.trim().isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          episode.description!.trim(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: LuminaTokens.textMuted,
                            fontSize: 11.5,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isCurrentTrack) ...[
                      IconButton(
                        key: Key('btn_episode_skip_back_${episode.videoId}'),
                        tooltip: '倒退 15 秒',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        padding: EdgeInsets.zero,
                        icon: const Icon(
                          Icons.replay_10_rounded,
                          size: 19,
                          color: LuminaTokens.textSecondary,
                        ),
                        onPressed: () => PodcastPlaybackTracker.seekRelative(
                          widget.audioService,
                          PodcastPlaybackTracker.skipBackwardDelta,
                          store: _store,
                        ),
                      ),
                      IconButton(
                        key: Key('btn_episode_skip_forward_${episode.videoId}'),
                        tooltip: '快轉 30 秒',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        padding: EdgeInsets.zero,
                        icon: const Icon(
                          Icons.forward_30_rounded,
                          size: 19,
                          color: LuminaTokens.textSecondary,
                        ),
                        onPressed: () => PodcastPlaybackTracker.seekRelative(
                          widget.audioService,
                          PodcastPlaybackTracker.skipForwardDelta,
                          store: _store,
                        ),
                      ),
                    ],
                    if (episode.showId.trim().isNotEmpty &&
                        widget.onOpenPodcastShow != null)
                      IconButton(
                        key: Key('btn_episode_open_show_${episode.videoId}'),
                        tooltip: '開啟所屬 Podcast 節目',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        padding: EdgeInsets.zero,
                        icon: const Icon(
                          Icons.podcasts_rounded,
                          size: 18,
                          color: LuminaTokens.textSecondary,
                        ),
                        onPressed: () => widget.onOpenPodcastShow!(
                          episode.showId,
                          show: PodcastShow(
                            id: episode.showId,
                            title: episode.showTitle.isNotEmpty
                                ? episode.showTitle
                                : episode.title,
                            author: episode.author,
                            artworkUrl: episode.artworkUrl,
                          ),
                        ),
                      ),
                    IconButton(
                      key: Key('btn_play_episode_${episode.videoId}'),
                      tooltip: isPlaying ? '暫停單集' : '播放單集',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      padding: EdgeInsets.zero,
                      icon: isLoading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: LuminaTokens.glassTextPrimary,
                              ),
                            )
                          : Icon(
                              isPlaying
                                  ? Icons.pause_circle_filled_rounded
                                  : Icons.play_circle_fill_rounded,
                              size: 26,
                              color: LuminaTokens.glassTextPrimary,
                            ),
                      onPressed: () {
                        if (isCurrentTrack) {
                          widget.audioService.togglePlayPause();
                        } else {
                          _playEpisode(episode, contextEpisodes);
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNetworkArtwork({
    required String? url,
    required double size,
    required double borderRadius,
  }) {
    Widget placeholder() => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: LuminaTokens.glassPillBg,
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(color: LuminaTokens.glassSidebarBorder),
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.podcasts_rounded,
            size: 24,
            color: LuminaTokens.textMuted,
          ),
        );

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: StreamingCoverImage(
        url: url,
        targetSize: size >= 100 ? 600 : 300,
        width: size,
        height: size,
        fallbackBuilder: (_) => placeholder(),
      ),
    );
  }
}
