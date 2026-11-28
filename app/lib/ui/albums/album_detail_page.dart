import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/audio_format.dart';
import '../../models/ingestion_models.dart';
import '../../models/playback_state.dart';
import '../../models/streaming_models.dart';
import '../../models/streaming_provider_meta.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../../services/listen_later_controller.dart';
import '../../services/streaming/streaming_manager.dart';
import '../artwork/album_artwork_view.dart';
import '../common/frosted_glass_container.dart';
import '../common/lumina_context_menu.dart';
import '../common/preference_toggle_button.dart';
import '../common/track_context_menu.dart';
import '../common/track_hover_prefetch.dart';
import '../settings/settings_styles.dart';
import '../tags/tag_picker_dialog.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';
import 'album_asset_gallery_lightbox.dart';
import 'album_split_dialog.dart';
import 'album_versions_section.dart';

part 'album_detail_actions.dart';
part 'album_detail_grouping_actions.dart';
part 'album_detail_hero.dart';
part 'album_detail_more_menu.dart';
part 'album_detail_sections.dart';
part 'album_detail_track_row.dart';
part 'album_detail_widgets.dart';

// ─── Standalone Album Detail Page ─────────────────────────────────────────────

class AlbumDetailPage extends StatefulWidget {
  final String albumId;
  final AudioService audioService;
  final StreamingManager? streamingManager;
  final ListenLaterController? listenLaterController;
  final void Function(TrackInfo track, {List<TrackInfo>? queueContext})?
      onPlayStreamingTrack;
  final VoidCallback? onBack;
  final bool showInlineBackButton;
  final void Function(String artistId)? onOpenArtistCredits;
  final LibraryIndexCache? libraryCache;
  final void Function(String artistName)? onOpenArtist;
  final double initialScrollOffset;
  final ValueChanged<double>? onScrollOffsetChanged;
  final ValueChanged<String>? onTitleChanged;

  /// Scroll offset threshold past which the compact sticky header should appear in the top bar.
  static const double stickyTitleScrollThreshold = 200.0;

  const AlbumDetailPage({
    super.key,
    required this.albumId,
    required this.audioService,
    this.streamingManager,
    this.listenLaterController,
    this.onPlayStreamingTrack,
    this.onBack,
    this.showInlineBackButton = true,
    this.onOpenArtistCredits,
    this.libraryCache,
    this.onOpenArtist,
    this.initialScrollOffset = 0.0,
    this.onScrollOffsetChanged,
    this.onTitleChanged,
  });

  /// Formats single-line unified album metadata as:
  /// `'總時長 · 音檔格式 · 取樣率 · 位元深度 · 曲目數'`
  /// e.g. `'1小時 50分 · FLAC · 48 kHz · 24-bit · 27 首'`
  /// or `'42分 15秒 · FLAC · 44.1 kHz · 16-bit · 10 首'`.
  static String formatUnifiedMetadata(
    AlbumVersionInfo? version, {
    int? fallbackTrackCount,
  }) {
    final tracks = version?.tracks ?? const <AlbumVersionTrackInfo>[];
    var totalMs = 0;
    for (final t in tracks) {
      if (t.durationMs > 0) {
        totalMs += t.durationMs;
      }
    }
    final durationLabel = formatTotalDuration(totalMs);
    final codecLabel = version != null
        ? AudioCodec.displayNameFor(version.codec)
        : 'FLAC';
    final sampleRateLabel = version != null
        ? AudioFormat.formatSampleRateKhz(version.sampleRateHz)
        : '44.1 kHz';
    final bitDepth = version?.bitDepth ?? 16;
    final bitDepthLabel = '${bitDepth > 0 ? bitDepth : 16}-bit';
    final trackCount = version != null
        ? tracks.length
        : (fallbackTrackCount ?? 0);
    return '$durationLabel · $codecLabel · $sampleRateLabel · $bitDepthLabel · $trackCount 首';
  }

  /// Formats total album duration in milliseconds into a clean Traditional
  /// Chinese duration string (`'1小時 50分'`, `'42分 15秒'`, `'42分'`, etc.).
  static String formatTotalDuration(int totalDurationMs) {
    if (totalDurationMs <= 0) return '0分';
    final totalSeconds = (totalDurationMs / 1000).round();
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    if (hours >= 1) {
      return '$hours小時 $minutes分';
    }
    if (minutes > 0 && seconds > 0) {
      return '$minutes分 $seconds秒';
    }
    if (minutes > 0) {
      return '$minutes分';
    }
    return '$seconds秒';
  }

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  late final GlideScrollController _scrollController;
  late final ValueNotifier<_ActivePlaybackSnapshot> _playbackNotifier;
  StreamSubscription<PlaybackState>? _playbackSub;
  StreamSubscription<ScanProgressEvent>? _scanProgressSub;

  CanonicalAlbumDetail? _detail;
  CanonicalAlbumSummary? _summaryFallback;
  List<MetadataOverrideRecord> _overrides = const <MetadataOverrideRecord>[];
  List<TagSummary> _albumTags = const <TagSummary>[];
  AlbumAssetsResponse? _albumAssets;
  int _assetsLoadEpoch = 0;
  int _selectedVersionIndex = 0;
  int _coverRevision = 0;
  int _lastCacheRefreshGen = 0;
  bool _loading = true;
  String? _error;
  int _loadEpoch = 0;
  CancellationToken? _streamingLoadCancel;

  @override
  void initState() {
    super.initState();
    _scrollController = GlideScrollController(
      initialScrollOffset: widget.initialScrollOffset,
    )..addListener(_onScroll);

    _playbackNotifier = ValueNotifier<_ActivePlaybackSnapshot>(
      _ActivePlaybackSnapshot.fromState(widget.audioService.currentState),
    );
    _playbackSub = widget.audioService.stateStream.listen((state) {
      final snap = _ActivePlaybackSnapshot.fromState(state);
      if (_playbackNotifier.value != snap) {
        _playbackNotifier.value = snap;
      }
    });
    _lastCacheRefreshGen = widget.libraryCache?.refreshGeneration ?? 0;
    widget.libraryCache?.addListener(_onLibraryCacheChanged);
    _scanProgressSub = widget.audioService.scanProgressStream.listen(
      _onScanProgress,
    );

    _hydrateFromCacheSync();
    _load();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _notifyTitleChanged();
      if (widget.initialScrollOffset > 0 && _scrollController.hasClients) {
        widget.onScrollOffsetChanged?.call(_scrollController.offset);
      }
    });
  }

  @override
  void didUpdateWidget(covariant AlbumDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.libraryCache != widget.libraryCache) {
      oldWidget.libraryCache?.removeListener(_onLibraryCacheChanged);
      _lastCacheRefreshGen = widget.libraryCache?.refreshGeneration ?? 0;
      widget.libraryCache?.addListener(_onLibraryCacheChanged);
    }
    if (oldWidget.audioService != widget.audioService) {
      _playbackSub?.cancel();
      _playbackSub = widget.audioService.stateStream.listen((state) {
        final snap = _ActivePlaybackSnapshot.fromState(state);
        if (_playbackNotifier.value != snap) {
          _playbackNotifier.value = snap;
        }
      });
      _scanProgressSub?.cancel();
      _scanProgressSub = widget.audioService.scanProgressStream.listen(
        _onScanProgress,
      );
    }
    if (oldWidget.albumId != widget.albumId) {
      _selectedVersionIndex = 0;
      _albumAssets = null;
      _error = null;
      _hydrateFromCacheSync();
      _load();
      _notifyTitleChanged();
      if (_scrollController.hasClients) {
        final target = widget.initialScrollOffset.clamp(
          0.0,
          _scrollController.position.maxScrollExtent,
        );
        _scrollController.jumpTo(target);
      }
    }
  }

  @override
  void dispose() {
    widget.libraryCache?.removeListener(_onLibraryCacheChanged);
    _scanProgressSub?.cancel();
    _scanProgressSub = null;
    _streamingLoadCancel?.cancel();
    _streamingLoadCancel = null;
    _playbackSub?.cancel();
    _playbackNotifier.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onLibraryCacheChanged() {
    if (!mounted) return;
    final cache = widget.libraryCache;
    if (cache == null) return;
    if (cache.refreshGeneration != _lastCacheRefreshGen) {
      _lastCacheRefreshGen = cache.refreshGeneration;
      _summaryFallback = cache.getAlbumSummarySync(widget.albumId);
      setState(() => _coverRevision++);
      unawaited(_load(forceRefresh: true));
      return;
    }
    final cachedDetail = cache.getAlbumDetailSync(widget.albumId);
    if (cachedDetail != null && !identical(cachedDetail, _detail)) {
      final current = _detail;
      final changed = current == null ||
          current.title != cachedDetail.title ||
          current.artistName != cachedDetail.artistName ||
          current.releaseYear != cachedDetail.releaseYear ||
          current.coverUrl != cachedDetail.coverUrl ||
          current.versions.length != cachedDetail.versions.length ||
          current.metaPolicy != cachedDetail.metaPolicy ||
          current.hasUserEdits != cachedDetail.hasUserEdits;
      if (changed) {
        setState(() {
          _detail = cachedDetail;
          _loading = false;
        });
        _notifyTitleChanged();
      }
    }
  }

  void _onScanProgress(ScanProgressEvent event) {
    if (!mounted || event.state != ScanLifecycleState.completed) return;
    final cache = widget.libraryCache;
    if (cache != null) {
      unawaited(cache.refresh(widget.audioService));
      return;
    }
    setState(() => _coverRevision++);
    unawaited(_load(forceRefresh: true));
  }

  String? get _activeVersionId {
    final detail = _detail;
    if (detail == null) return null;
    final visible = detail.versions.where((v) => v.tracks.isNotEmpty).toList();
    if (visible.isEmpty) return detail.primaryVersionId;
    return visible[_selectedVersionIndex.clamp(0, visible.length - 1)].id;
  }

  void _setState(VoidCallback fn) {
    final prevVersionId = _activeVersionId;
    setState(fn);
    final nextVersionId = _activeVersionId;
    if (nextVersionId != prevVersionId) {
      unawaited(_loadAlbumAssets(nextVersionId ?? widget.albumId));
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    widget.onScrollOffsetChanged?.call(_scrollController.offset);
  }

  void _notifyTitleChanged() {
    final title = _detail?.title ?? _summaryFallback?.title;
    if (title != null && title.isNotEmpty) {
      widget.onTitleChanged?.call(title);
    }
  }

  void _hydrateFromCacheSync() {
    final cache = widget.libraryCache;
    if (cache == null) return;
    final cachedDetail = cache.getAlbumDetailSync(widget.albumId);
    final cachedSummary = cache.getAlbumSummarySync(widget.albumId);
    _summaryFallback = cachedSummary;
    if (cachedDetail != null) {
      _detail = cachedDetail;
      _loading = false;
      _notifyTitleChanged();
    } else if (cachedSummary != null) {
      _detail = CanonicalAlbumDetail(
        id: cachedSummary.id,
        title: cachedSummary.title,
        artistName: cachedSummary.artist,
        releaseYear: cachedSummary.year,
        coverUrl: cachedSummary.coverUrl,
      );
      _loading = false;
      _notifyTitleChanged();
    }
  }

  ({String kind, String rawId})? _parseStreamingAlbumId(String albumId) {
    if (!albumId.startsWith('streaming:')) return null;
    final rest = albumId.substring('streaming:'.length);
    final sep = rest.indexOf(':');
    if (sep <= 0 || sep >= rest.length - 1) return null;
    return (
      kind: rest.substring(0, sep),
      rawId: rest.substring(sep + 1),
    );
  }

  Future<void> _load({bool forceRefresh = false}) async {
    final epoch = ++_loadEpoch;
    _streamingLoadCancel?.cancel();
    _streamingLoadCancel = null;
    try {
      final cache = widget.libraryCache;
      final streamingTarget = _parseStreamingAlbumId(widget.albumId);
      final CanonicalAlbumDetail? detail;
      if (streamingTarget != null && widget.streamingManager != null) {
        final cached = cache?.getAlbumDetailSync(widget.albumId);
        if (!forceRefresh && cached != null && cached.versions.isNotEmpty) {
          return;
        }
        final cancelToken = CancellationToken();
        _streamingLoadCancel = cancelToken;
        detail = await widget.streamingManager!.fetchAlbumDetail(
          streamingTarget.kind,
          streamingTarget.rawId,
          cancel: cancelToken,
        );
      } else {
        detail = cache != null
            ? await cache.loadAlbumDetail(
                widget.audioService,
                widget.albumId,
                forceRefresh: forceRefresh,
              )
            : await widget.audioService.getAlbumDetailFiltered(
                widget.albumId,
                includeHidden: widget.libraryCache?.includeHidden ?? false,
              );
      }
      if (!mounted || epoch != _loadEpoch) return;
      List<MetadataOverrideRecord> overrides = const <MetadataOverrideRecord>[];
      List<TagSummary> albumTags = const <TagSummary>[];
      try {
        overrides = await widget.audioService.getMetadataOverrides(
          'album',
          widget.albumId,
        );
      } catch (_) {}
      try {
        if (!widget.albumId.startsWith('streaming:')) {
          albumTags = await widget.audioService.getEntityTags(
            TagEntityType.albumGroup,
            widget.albumId,
          );
        }
      } catch (_) {}
      if (!mounted || epoch != _loadEpoch) return;
      if (detail != null &&
          cache != null &&
          !identical(cache.getAlbumDetailSync(widget.albumId), detail)) {
        cache.putAlbumDetailSync(detail);
      }
      setState(() {
        if (detail != null || _detail == null || forceRefresh) {
          final isFirstDetail = _detail == null || _detail!.versions.isEmpty;
          _detail = detail;
          if (detail != null && isFirstDetail) {
            _selectedVersionIndex = _preferredVersionIndexFor(detail);
          }
        }
        _overrides = overrides;
        _albumTags = albumTags;
        _loading = false;
      });
      _notifyTitleChanged();
      unawaited(_loadAlbumAssets(_activeVersionId ?? widget.albumId));
    } catch (e) {
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        if (_detail == null) {
          _error = e.toString();
        }
        _loading = false;
      });
    }
  }

  void _handleOpenArtist(String artistName, CanonicalAlbumDetail detail) {
    final trimmed = artistName.trim();
    if (trimmed.isEmpty) return;
    if (widget.onOpenArtist != null) {
      widget.onOpenArtist!(trimmed);
      return;
    }
    if (widget.onOpenArtistCredits != null && detail.credits.isNotEmpty) {
      final match = detail.credits
              .where(
                (c) => c.artistName.toLowerCase() == trimmed.toLowerCase(),
              )
              .firstOrNull ??
          detail.credits.first;
      widget.onOpenArtistCredits!(match.artistId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = _loading && _detail == null
        ? const Center(
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: LuminaTokens.glassTextPrimary,
            ),
          )
        : _error != null && _detail == null
        ? Center(
            child: Text(
              '載入失敗：$_error',
              style: const TextStyle(
                color: LuminaTokens.statusError,
                fontSize: 13,
              ),
            ),
          )
        : _detail == null
        ? const Center(
            child: Text(
              '找不到此專輯',
              style: TextStyle(color: LuminaTokens.textMuted),
            ),
          )
        : _buildDetail(_detail!);

    if (widget.onBack == null || !widget.showInlineBackButton) {
      return body;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: IconButton(
            key: const Key('album_detail_back_btn'),
            onPressed: widget.onBack,
            icon: const Icon(
              Icons.arrow_back_rounded,
              size: 20,
              color: LuminaTokens.textSecondary,
            ),
            tooltip: '返回專輯列表',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
        ),
        Expanded(child: body),
      ],
    );
  }
}
