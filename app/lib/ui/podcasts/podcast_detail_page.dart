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
import '../theme/smooth_scroll.dart';

part 'podcast_detail_hero.dart';
part 'podcast_detail_episode_row.dart';

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
  late final GlideScrollController _scrollController;
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
    _scrollController = GlideScrollController(
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

  void _setState(VoidCallback fn) => setState(fn);

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
          backgroundColor: LuminaTokens.glassDialogBg,
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

                return _buildDetailScrollView(
                  effectiveShow: effectiveShow,
                  playbackState: playbackState,
                  availW: availW,
                  coverSize: coverSize,
                  isWide: isWide,
                );
              },
            );
          },
        );
      },
    );
  }
}
