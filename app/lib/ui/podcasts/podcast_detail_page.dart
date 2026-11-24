import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/podcast_models.dart';
import '../../models/streaming_models.dart';
import '../../services/audio_service.dart';
import '../../services/podcast_store.dart';
import '../../services/streaming/streaming_manager.dart';
import '../artwork/streaming_cover_image.dart';
import '../common/track_hover_prefetch.dart';
import '../theme/lumina_tokens.dart';

/// Standalone Podcast Show Detail Page with high-res cover art, show metadata,
/// bookmark toggle, "播放最新一集", real episode rows with persisted listening
/// progress badges, active `-15s` / `+30s` skip buttons, and InnerTube
/// continuation pagination ("載入更多單集").
class PodcastDetailPage extends StatefulWidget {
  final String showId;
  final PodcastShow? initialShow;
  final AudioService audioService;
  final StreamingManager? streamingManager;
  final Future<void> Function(
    TrackInfo track, {
    List<TrackInfo>? queueContext,
  })? onPlayStreamingTrack;
  final VoidCallback? onBack;
  final PodcastStore? podcastStore;
  final double initialScrollOffset;
  final ValueChanged<double>? onScrollOffsetChanged;
  final ValueChanged<String>? onTitleChanged;

  const PodcastDetailPage({
    super.key,
    required this.showId,
    this.initialShow,
    required this.audioService,
    this.streamingManager,
    this.onPlayStreamingTrack,
    this.onBack,
    this.podcastStore,
    this.initialScrollOffset = 0.0,
    this.onScrollOffsetChanged,
    this.onTitleChanged,
  });

  @override
  State<PodcastDetailPage> createState() => _PodcastDetailPageState();
}

class _PodcastDetailPageState extends State<PodcastDetailPage> {
  static const _accentBlue = LuminaTokens.accentBlue;

  late final ScrollController _scrollController;
  late PodcastStore _store;

  PodcastShow? _show;
  List<PodcastEpisode> _episodes = const <PodcastEpisode>[];
  String? _continuationToken;
  bool _loading = true;
  bool _loadingMore = false;
  bool _descriptionExpanded = false;
  String? _error;
  int _loadEpoch = 0;
  CancellationToken? _cancelToken;

  @override
  void initState() {
    super.initState();
    _store = widget.podcastStore ?? PodcastStore.instance;
    _store.ensureLoadedSync();
    _show = widget.initialShow;
    _scrollController = ScrollController(
      initialScrollOffset: widget.initialScrollOffset,
    )..addListener(_onScroll);

    _loadShowDetail();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _notifyTitle();
      if (widget.initialScrollOffset > 0 && _scrollController.hasClients) {
        widget.onScrollOffsetChanged?.call(_scrollController.offset);
      }
    });
  }

  @override
  void didUpdateWidget(covariant PodcastDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.podcastStore != widget.podcastStore) {
      _store = widget.podcastStore ?? PodcastStore.instance;
    }
    if (oldWidget.showId != widget.showId) {
      _show = widget.initialShow;
      _episodes = const <PodcastEpisode>[];
      _continuationToken = null;
      _error = null;
      _descriptionExpanded = false;
      _loadShowDetail();
      _notifyTitle();
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0.0);
      }
    }
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    _cancelToken = null;
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final offset = _scrollController.offset;
    widget.onScrollOffsetChanged?.call(offset);
  }

  void _notifyTitle() {
    final t = _show?.title.trim();
    if (t != null && t.isNotEmpty) {
      widget.onTitleChanged?.call(t);
    }
  }

  Future<void> _loadShowDetail() async {
    final sm = widget.streamingManager;
    if (sm == null) {
      setState(() => _loading = false);
      return;
    }
    final epoch = ++_loadEpoch;
    _cancelToken?.cancel();
    final token = CancellationToken();
    _cancelToken = token;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final detail = await sm.fetchPodcastShowDetail(
        widget.showId,
        cancel: token,
      );
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _show = detail.show.copyWith(
          artworkUrl: detail.show.artworkUrl ?? _show?.artworkUrl,
          author: detail.show.author.isNotEmpty
              ? detail.show.author
              : (_show?.author ?? ''),
        );
        _episodes = detail.episodes;
        _continuationToken = detail.continuationToken;
        _loading = false;
      });
      _notifyTitle();
    } on StreamingException catch (e) {
      if (!mounted || epoch != _loadEpoch || e.isCancelled) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _error = '載入節目詳情失敗：$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadMoreEpisodes() async {
    final sm = widget.streamingManager;
    final tokenStr = _continuationToken?.trim();
    if (sm == null ||
        tokenStr == null ||
        tokenStr.isEmpty ||
        _loadingMore ||
        _loading) {
      return;
    }

    final epoch = _loadEpoch;
    final cancel = CancellationToken();
    _cancelToken = cancel;

    setState(() {
      _loadingMore = true;
    });

    try {
      final nextPage = await sm.fetchPodcastShowDetail(
        widget.showId,
        continuation: tokenStr,
        cancel: cancel,
      );
      if (!mounted || epoch != _loadEpoch) return;
      final existingIds = _episodes.map((e) => e.videoId).toSet();
      final merged = List<PodcastEpisode>.of(_episodes);
      for (final ep in nextPage.episodes) {
        if (existingIds.add(ep.videoId)) {
          merged.add(
            ep.copyWith(
              showId: _show?.id ?? widget.showId,
              showTitle: ep.showTitle.isNotEmpty
                  ? ep.showTitle
                  : (_show?.title ?? ''),
              author: ep.author.isNotEmpty
                  ? ep.author
                  : (_show?.author ?? ''),
              artworkUrl: ep.artworkUrl ?? _show?.artworkUrl,
            ),
          );
        }
      }
      final nextCont = nextPage.continuationToken;
      setState(() {
        _episodes = merged;
        _continuationToken =
            (nextCont != null && nextCont != tokenStr) ? nextCont : null;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _loadingMore = false;
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          backgroundColor: LuminaTokens.statusErrorBg,
          content: Text(
            '載入更多單集失敗：$e',
            style: const TextStyle(color: LuminaTokens.textPrimary),
          ),
        ),
      );
    }
  }

  Future<void> _playEpisode(PodcastEpisode episode) async {
    final track = episode.toTrack();
    final queueTracks = _episodes.map((e) => e.toTrack()).toList();
    if (widget.onPlayStreamingTrack != null) {
      await widget.onPlayStreamingTrack!(track, queueContext: queueTracks);
      return;
    }
    await widget.audioService.play(track: track);
  }

  String _formatDuration(Duration d) {
    if (d <= Duration.zero) return '';
    return PodcastEpisodeProgress.formatSeconds(d.inSeconds);
  }

  @override
  Widget build(BuildContext context) {
    final effectiveShow = _show ??
        PodcastShow(
          id: widget.showId,
          title: 'Podcast 節目',
        );

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
                final isWide = availW >= 560;
                final coverSize =
                    availW >= 780 ? 176.0 : (isWide ? 148.0 : 124.0);

                return CustomScrollView(
                  key: const Key('podcast_detail_scroll_view'),
                  controller: _scrollController,
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        isWide ? 16 : 8,
                        12,
                        isWide ? 16 : 8,
                        16,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: _buildHeroSection(
                          show: effectiveShow,
                          coverSize: coverSize,
                          isWide: isWide,
                        ),
                      ),
                    ),
                    if (_loading && _episodes.isEmpty)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          child: CircularProgressIndicator(
                            key: Key('podcast_detail_loading'),
                            strokeWidth: 2.2,
                            color: _accentBlue,
                          ),
                        ),
                      )
                    else if (_error != null && _episodes.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _error!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: LuminaTokens.statusError,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                OutlinedButton.icon(
                                  key: const Key('btn_podcast_detail_retry'),
                                  onPressed: _loadShowDetail,
                                  icon: const Icon(
                                    Icons.refresh_rounded,
                                    size: 16,
                                  ),
                                  label: const Text('重試'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                    else if (_episodes.isEmpty)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(
                          child: Text(
                            '此節目目前尚無可播放的單集',
                            style: TextStyle(
                              color: LuminaTokens.textMuted,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      )
                    else ...[
                      SliverPadding(
                        padding: EdgeInsets.symmetric(
                          horizontal: isWide ? 16 : 8,
                        ),
                        sliver: SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.format_list_bulleted_rounded,
                                  size: 17,
                                  color: _accentBlue,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '所有單集（${_episodes.length}）',
                                  style: const TextStyle(
                                    color: LuminaTokens.textPrimary,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: EdgeInsets.symmetric(
                          horizontal: isWide ? 16 : 8,
                        ),
                        sliver: SliverList.builder(
                          itemCount: _episodes.length,
                          itemBuilder: (context, index) {
                            final ep = _episodes[index];
                            return _buildEpisodeRow(
                              episode: ep,
                              playbackState: playbackState,
                              isCompact: availW < 520,
                            );
                          },
                        ),
                      ),
                      if (_continuationToken != null &&
                          _continuationToken!.trim().isNotEmpty)
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(
                            isWide ? 16 : 8,
                            12,
                            isWide ? 16 : 8,
                            24,
                          ),
                          sliver: SliverToBoxAdapter(
                            child: Center(
                              child: OutlinedButton.icon(
                                key: const Key(
                                  'btn_podcast_load_more_episodes',
                                ),
                                onPressed:
                                    _loadingMore ? null : _loadMoreEpisodes,
                                icon: _loadingMore
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: _accentBlue,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.expand_more_rounded,
                                        size: 18,
                                      ),
                                label: Text(
                                  _loadingMore ? '載入更多單集中...' : '載入更多單集',
                                  style: const TextStyle(fontSize: 13),
                                ),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: _accentBlue,
                                  side: const BorderSide(
                                    color: LuminaTokens.borderControl,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 10,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      const SliverToBoxAdapter(
                        child: SizedBox(
                          height: LuminaTokens.bottomScrollClearance,
                        ),
                      ),
                    ],
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildHeroSection({
    required PodcastShow show,
    required double coverSize,
    required bool isWide,
  }) {
    final isBookmarked = _store.isBookmarked(show.id);
    final desc = show.description?.trim() ?? '';

    final metaColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _accentBlue.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
                border: Border.all(
                  color: _accentBlue.withValues(alpha: 0.45),
                ),
              ),
              child: const Text(
                'YouTube Music Podcast',
                style: TextStyle(
                  color: _accentBlue,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (show.episodeCountLabel != null &&
                show.episodeCountLabel!.trim().isNotEmpty)
              Text(
                show.episodeCountLabel!,
                style: const TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 12,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          show.title,
          key: const Key('podcast_detail_title'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: LuminaTokens.textPrimary,
            fontSize: isWide ? 22 : 18,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
        ),
        if (show.author.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            show.author,
            key: const Key('podcast_detail_author'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: LuminaTokens.textSecondary,
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
        if (desc.isNotEmpty) ...[
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => setState(
              () => _descriptionExpanded = !_descriptionExpanded,
            ),
            child: Text(
              desc,
              key: const Key('podcast_detail_description'),
              maxLines: _descriptionExpanded ? 15 : 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: LuminaTokens.textMuted,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
        ],
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const Key('btn_podcast_play_latest'),
              onPressed: _episodes.isEmpty
                  ? null
                  : () => _playEpisode(_episodes.first),
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text(
                '播放最新一集',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: _accentBlue,
                foregroundColor: LuminaTokens.onAccentDark,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
              ),
            ),
            OutlinedButton.icon(
              key: const Key('btn_podcast_toggle_bookmark'),
              onPressed: () => _store.toggleBookmark(show),
              icon: Icon(
                isBookmarked
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
                size: 17,
                color: isBookmarked ? _accentBlue : LuminaTokens.textSecondary,
              ),
              label: Text(
                isBookmarked ? '已收藏' : '收藏節目',
                style: TextStyle(
                  fontSize: 13,
                  color: isBookmarked ? _accentBlue : LuminaTokens.textPrimary,
                  fontWeight:
                      isBookmarked ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(
                  color: isBookmarked
                      ? _accentBlue
                      : LuminaTokens.borderControl,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
              ),
            ),
          ],
        ),
      ],
    );

    return Container(
      padding: EdgeInsets.all(isWide ? 20 : 14),
      decoration: BoxDecoration(
        color: LuminaTokens.cardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
        border: Border.all(color: LuminaTokens.borderSubtle),
      ),
      child: isWide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildArtworkBox(
                  url: show.artworkUrl,
                  width: coverSize,
                  height: coverSize,
                  borderRadius: 12,
                  iconSize: 44,
                  targetSize: 1200,
                ),
                const SizedBox(width: 22),
                Expanded(child: metaColumn),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: _buildArtworkBox(
                    url: show.artworkUrl,
                    width: coverSize,
                    height: coverSize,
                    borderRadius: 12,
                    iconSize: 40,
                    targetSize: 1200,
                  ),
                ),
                const SizedBox(height: 14),
                metaColumn,
              ],
            ),
    );
  }

  Widget _buildEpisodeRow({
    required PodcastEpisode episode,
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
    final durText = _formatDuration(episode.duration);
    final metaParts = <String>[
      if (episode.publishedLabel != null &&
          episode.publishedLabel!.trim().isNotEmpty)
        episode.publishedLabel!.trim(),
      if (durText.isNotEmpty) durText,
    ];

    return TrackHoverPrefetch(
      trackIdentity: episode.externalAudioUrl ?? episode.videoId,
      trackBuilder: episode.toTrack,
      child: Container(
        key: Key('podcast_episode_tile_${episode.videoId}'),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isCurrentTrack
            ? LuminaTokens.cardElevatedBg
            : LuminaTokens.cardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(
          color: isCurrentTrack
              ? _accentBlue.withValues(alpha: 0.65)
              : LuminaTokens.borderSubtle,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        hoverColor: LuminaTokens.cardHoverBg.withValues(alpha: 0.55),
        onTap: () {
          if (isCurrentTrack) {
            widget.audioService.togglePlayPause();
          } else {
            _playEpisode(episode);
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildArtworkBox(
                url: episode.artworkUrl ?? _show?.artworkUrl,
                width: isCompact ? 52 : 64,
                height: isCompact ? 52 : 64,
                borderRadius: 8,
                iconSize: 24,
                targetSize: 300,
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
                            ? _accentBlue
                            : LuminaTokens.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        height: 1.25,
                      ),
                    ),
                    if (metaParts.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            metaParts.join(' · '),
                            style: const TextStyle(
                              color: LuminaTokens.textMuted,
                              fontSize: 11.5,
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
                                color: (progress.completed
                                        ? LuminaTokens.statusSuccess
                                        : _accentBlue)
                                    .withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(
                                  LuminaTokens.radiusPill,
                                ),
                              ),
                              child: Text(
                                progress.completed
                                    ? '已播完'
                                    : '已播 ${progress.formattedPosition}',
                                style: TextStyle(
                                  color: progress.completed
                                      ? LuminaTokens.statusSuccess
                                      : _accentBlue,
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
                      const SizedBox(height: 5),
                      Text(
                        episode.description!.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.textSecondary,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ],
                    if (progress != null &&
                        progress.positionSeconds > 0 &&
                        progress.durationSeconds > 0) ...[
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: progress.progressFraction,
                          minHeight: 3,
                          backgroundColor: LuminaTokens.borderSubtle,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            progress.completed
                                ? LuminaTokens.statusSuccess
                                : _accentBlue,
                          ),
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
                              color: _accentBlue,
                            ),
                          )
                        : Icon(
                            isPlaying
                                ? Icons.pause_circle_filled_rounded
                                : Icons.play_circle_fill_rounded,
                            size: 28,
                            color: _accentBlue,
                          ),
                    onPressed: () {
                      if (isCurrentTrack) {
                        widget.audioService.togglePlayPause();
                      } else {
                        _playEpisode(episode);
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

  Widget _buildArtworkBox({
    required String? url,
    required double width,
    required double height,
    required double borderRadius,
    required double iconSize,
    int? targetSize,
  }) {
    Widget placeholder() => Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: LuminaTokens.cardElevatedBg,
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(color: LuminaTokens.borderSubtle),
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.podcasts_rounded,
            size: iconSize,
            color: LuminaTokens.textMuted,
          ),
        );

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: StreamingCoverImage(
        url: url,
        targetSize: targetSize ?? (width >= 120 ? 1200 : 300),
        width: width,
        height: height,
        fallbackBuilder: (_) => placeholder(),
      ),
    );
  }
}
