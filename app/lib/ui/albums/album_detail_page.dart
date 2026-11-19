import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/audio_format.dart';
import '../../models/playback_state.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../artwork/album_artwork_view.dart';
import '../theme/lumina_tokens.dart';

// ─── Standalone Album Detail Page ─────────────────────────────────────────────

class AlbumDetailPage extends StatefulWidget {
  final String albumId;
  final AudioService audioService;
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

@immutable
class _ActivePlaybackSnapshot {
  final String? trackId;
  final String? trackTitle;
  final String? albumTitle;
  final PlaybackStatus status;

  const _ActivePlaybackSnapshot({
    required this.trackId,
    required this.trackTitle,
    required this.albumTitle,
    required this.status,
  });

  factory _ActivePlaybackSnapshot.fromState(PlaybackState state) {
    return _ActivePlaybackSnapshot(
      trackId: state.track?.id,
      trackTitle: state.track?.title,
      albumTitle: state.track?.album,
      status: state.status,
    );
  }

  bool get isActivelyPlaying =>
      status == PlaybackStatus.playing ||
      status == PlaybackStatus.seeking ||
      status == PlaybackStatus.buffering;

  bool matchesTrack(AlbumVersionTrackInfo track, String albumName) {
    if (trackId != null && trackId!.isNotEmpty && trackId == track.id) {
      return true;
    }
    if (trackTitle != null &&
        trackTitle == track.title &&
        albumTitle != null &&
        (albumTitle == albumName ||
            albumTitle!.toLowerCase().startsWith(albumName.toLowerCase()))) {
      return true;
    }
    return false;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ActivePlaybackSnapshot &&
          other.trackId == trackId &&
          other.trackTitle == trackTitle &&
          other.albumTitle == albumTitle &&
          other.status == status;

  @override
  int get hashCode => Object.hash(trackId, trackTitle, albumTitle, status);
}

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  static const _cardBg = LuminaTokens.cardBg;
  static const _dividerColor = LuminaTokens.borderSubtle;
  static const _accentBlue = LuminaTokens.accentBlue;

  late final ScrollController _scrollController;
  late final ValueNotifier<_ActivePlaybackSnapshot> _playbackNotifier;
  StreamSubscription<PlaybackState>? _playbackSub;

  CanonicalAlbumDetail? _detail;
  CanonicalAlbumSummary? _summaryFallback;
  int _selectedVersionIndex = 0;
  int _coverRevision = 0;
  bool _loading = true;
  String? _error;
  int _loadEpoch = 0;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(
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
    if (oldWidget.albumId != widget.albumId) {
      _selectedVersionIndex = 0;
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
    _playbackSub?.cancel();
    _playbackNotifier.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
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

  Future<void> _load() async {
    final epoch = ++_loadEpoch;
    try {
      final cache = widget.libraryCache;
      final detail = cache != null
          ? await cache.loadAlbumDetail(widget.audioService, widget.albumId)
          : await widget.audioService.getAlbumDetail(widget.albumId);
      if (!mounted || epoch != _loadEpoch) return;
      if (detail != null && cache != null) {
        cache.putAlbumDetailSync(detail);
      }
      setState(() {
        if (detail != null || _detail == null) {
          _detail = detail;
        }
        _loading = false;
      });
      _notifyTitleChanged();
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

  Future<void> _promptSetExternalCover() async {
    final txt = TextEditingController();
    final path = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: LuminaTokens.cardElevatedBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
          side: const BorderSide(color: LuminaTokens.borderControl),
        ),
        title: const Text(
          '設定專輯外部封面',
          style: TextStyle(color: LuminaTokens.textPrimary, fontSize: 15),
        ),
        content: TextField(
          controller: txt,
          key: const Key('input_album_cover_path'),
          style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 13),
          decoration: const InputDecoration(
            hintText: 'C:\\Music\\cover.jpg',
            hintStyle: TextStyle(color: LuminaTokens.textMuted),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: LuminaTokens.borderControl),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(txt.text.trim()),
            child: const Text('設定'),
          ),
        ],
      ),
    );
    if (path != null && path.isNotEmpty) {
      final cleaned = path.replaceAll(RegExp(r'''^["']|["']$'''), '').trim();
      if (cleaned.isNotEmpty) {
        await widget.audioService.setUserCover(widget.albumId, cleaned);
        widget.libraryCache?.invalidateArtwork(widget.albumId);
        if (mounted) {
          setState(() => _coverRevision++);
        }
      }
    }
  }

  Future<void> _handleClearCover() async {
    await widget.audioService.clearUserCover(widget.albumId);
    widget.libraryCache?.invalidateArtwork(widget.albumId);
    if (mounted) {
      setState(() => _coverRevision++);
    }
  }

  TrackInfo _toTrackInfo(
    CanonicalAlbumDetail d,
    AlbumVersionInfo ver,
    AlbumVersionTrackInfo vTrack,
  ) {
    final ext = vTrack.externalTrackId;
    final hasUri = ext.contains('/') ||
        ext.contains('\\') ||
        ext.startsWith('http://') ||
        ext.startsWith('https://');
    return TrackInfo(
      id: vTrack.id,
      title: vTrack.title,
      artist: d.artistName,
      album: d.title,
      duration: Duration(milliseconds: vTrack.durationMs),
      format: AudioFormat(
        codec: AudioCodec.fromString(vTrack.codec),
        sampleRateHz: vTrack.sampleRateHz,
        bitDepth: vTrack.bitDepth,
        channels: 2,
        isDsd: ver.isDsd || vTrack.isDsd,
      ),
      providerName: ver.provider,
      trackNumber: vTrack.trackNumber,
      discNumber: vTrack.discNumber,
      coverUrl: d.coverUrl,
      filePath: hasUri ? ext : null,
    );
  }

  TrackInfo? _findTrack(
    CanonicalAlbumDetail d, {
    String? title,
    AlbumVersionTrackInfo? versionTrack,
  }) {
    final q = widget.audioService.queue;
    if (versionTrack != null) {
      final byId = q.where((t) => t.id == versionTrack.id).firstOrNull;
      if (byId != null) return byId;
    }
    final inAlbum = q
        .where(
          (t) =>
              t.album == d.title ||
              t.album.toLowerCase().startsWith(d.title.toLowerCase()),
        )
        .toList();
    final targetTitle = versionTrack?.title ?? title;
    if (targetTitle != null) {
      final hit = inAlbum.where((t) => t.title == targetTitle).firstOrNull ??
          q.where((t) => t.title == targetTitle).firstOrNull;
      if (hit != null) return hit;
    } else if (inAlbum.isNotEmpty && d.versions.isEmpty) {
      return inAlbum.first;
    }

    final ver = d.versions.isNotEmpty
        ? d.versions[_selectedVersionIndex.clamp(0, d.versions.length - 1)]
        : null;
    if (ver == null || ver.tracks.isEmpty) {
      return inAlbum.firstOrNull;
    }
    final ordered = ver.orderedTrackEntries;
    final vTrack = versionTrack ??
        (targetTitle != null
            ? (ver.tracks.where((t) => t.title == targetTitle).firstOrNull ??
                ordered.first.track)
            : ordered.first.track);
    return _toTrackInfo(d, ver, vTrack);
  }

  Future<void> _playTrack(
    CanonicalAlbumDetail d, {
    String? title,
    AlbumVersionTrackInfo? versionTrack,
  }) async {
    final track = _findTrack(d, title: title, versionTrack: versionTrack);
    if (track == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('音樂庫中找不到此專輯的可播放曲目')),
      );
      return;
    }
    await widget.audioService.play(track: track);
  }

  void _addTrackToQueue(
    CanonicalAlbumDetail d,
    AlbumVersionTrackInfo vTrack,
  ) {
    final track = _findTrack(d, title: vTrack.title, versionTrack: vTrack);
    if (track == null) return;
    try {
      final q = widget.audioService.queue;
      if (!q.any((t) => t.id == track.id)) {
        q.add(track);
      }
    } catch (_) {}
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('已將「${track.title}」加入播放佇列'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _addAlbumToQueue(CanonicalAlbumDetail d, AlbumVersionInfo? ver) {
    final entries = ver?.orderedTrackEntries ?? const [];
    var added = 0;
    for (final entry in entries) {
      final track = _findTrack(
        d,
        title: entry.track.title,
        versionTrack: entry.track,
      );
      if (track != null) {
        added++;
        try {
          final q = widget.audioService.queue;
          if (!q.any((t) => t.id == track.id)) {
            q.add(track);
          }
        } catch (_) {}
      }
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          added > 0 ? '已將 $added 首曲目加入播放佇列' : '已將專輯加入播放佇列',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _versionChipKey(String provider) {
    return switch (provider) {
      'local' => 'version_chip_local',
      'tidal' => 'version_chip_tidal',
      'qobuz' => 'version_chip_qobuz',
      'apple_music' => 'version_chip_apple_music',
      'youtube_music' => 'version_chip_youtube_music',
      'deezer' => 'version_chip_deezer',
      _ => 'version_chip_$provider',
    };
  }

  Widget _buildCover({required double size}) {
    final title = _detail?.title ?? _summaryFallback?.title ?? '';
    final artist = _detail?.artistName ?? _summaryFallback?.artist ?? '';
    final coverUrl = _detail?.coverUrl ?? _summaryFallback?.coverUrl;
    return KeyedSubtree(
      key: const Key('album_cover_view'),
      child: AlbumArtworkView(
        key: ValueKey('album_detail_cover_${widget.albumId}_$_coverRevision'),
        album: CanonicalAlbumSummary(
          id: widget.albumId,
          title: title,
          artist: artist,
          coverUrl: coverUrl,
        ),
        size: size,
        revision: _coverRevision,
        audioService: widget.audioService,
        libraryCache: widget.libraryCache,
        fullResolution: true,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [
          BoxShadow(
            color: Color(0x77000000),
            blurRadius: 32,
            offset: Offset(0, 12),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = _loading && _detail == null
        ? const Center(
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: _accentBlue,
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
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
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
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  _detail?.title ?? _summaryFallback?.title ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(child: body),
      ],
    );
  }

  Widget _buildDetail(CanonicalAlbumDetail detail) {
    final selectedVersion = detail.versions.isNotEmpty
        ? detail.versions[
            _selectedVersionIndex.clamp(0, detail.versions.length - 1)
          ]
        : null;
    final trackEntries = selectedVersion?.orderedTrackEntries ?? const [];

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 560;
        final coverSize = constraints.maxWidth >= 780
            ? 200.0
            : (isWide ? 168.0 : 148.0);
        final hPad = isWide ? 28.0 : 16.0;
        final vPad = isWide ? 24.0 : 16.0;

        return CustomScrollView(
          key: PageStorageKey<String>('album_detail_${widget.albumId}'),
          controller: _scrollController,
          slivers: [
            // 1. Hero & Metadata Header Sliver
            SliverPadding(
              padding: EdgeInsets.fromLTRB(hPad, vPad, hPad, 12),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isWide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildCover(size: coverSize),
                          const SizedBox(width: 28),
                          Expanded(
                            child: _buildHeroMeta(
                              detail,
                              selectedVersion,
                              isWide: true,
                            ),
                          ),
                        ],
                      )
                    else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Center(child: _buildCover(size: coverSize)),
                          const SizedBox(height: 16),
                          _buildHeroMeta(
                            detail,
                            selectedVersion,
                            isWide: false,
                          ),
                        ],
                      ),

                    // Version switcher chips
                    if (detail.versions.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      const Text(
                        '發行版本',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          for (final (i, ver) in detail.versions.indexed)
                            _VersionChip(
                              key: Key(_versionChipKey(ver.provider)),
                              version: ver,
                              isSelected: _selectedVersionIndex == i,
                              onTap: () => setState(
                                () => _selectedVersionIndex = i,
                              ),
                            ),
                        ],
                      ),
                      if (selectedVersion != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          '目前採用版本：${selectedVersion.editionLabel}',
                          style: const TextStyle(
                            color: _accentBlue,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],

                    // Contributor chips (kept near Hero so always accessible without cluttering)
                    if (detail.credits.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      const Text(
                        '製作人員',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final c in detail.credits)
                            _CreditChip(
                              credit: c,
                              onTap: widget.onOpenArtistCredits != null
                                  ? () => widget.onOpenArtistCredits!(
                                      c.artistId,
                                    )
                                  : (widget.onOpenArtist != null
                                        ? () => widget.onOpenArtist!(
                                            c.artistName,
                                          )
                                        : null),
                            ),
                        ],
                      ),
                    ],

                    if (trackEntries.isNotEmpty) ...[
                      const SizedBox(height: 22),
                      Container(
                        padding: const EdgeInsets.only(bottom: 8),
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: _dividerColor),
                          ),
                        ),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 42,
                              child: Text(
                                '#',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: LuminaTokens.textMuted,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                '曲目列表',
                                style: TextStyle(
                                  color: LuminaTokens.textSecondary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            Semantics(
                              label: '曲目時長',
                              child: const Icon(
                                Icons.schedule_rounded,
                                size: 15,
                                color: LuminaTokens.textMuted,
                              ),
                            ),
                            const SizedBox(width: 68),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // 2. Virtualized Track List Sliver (SliverList.builder)
            if (trackEntries.isNotEmpty)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: hPad),
                sliver: SliverList.builder(
                  itemCount: trackEntries.length,
                  itemBuilder: (context, i) {
                    final entry = trackEntries[i];
                    final row = RepaintBoundary(
                      child: _AlbumTrackRow(
                        key: Key('album_track_$i'),
                        index: i,
                        track: entry.track,
                        displayNumber: entry.displayNumber,
                        artistName: detail.artistName,
                        albumTitle: detail.title,
                        playbackListenable: _playbackNotifier,
                        onPlay: () => _playTrack(
                          detail,
                          title: entry.track.title,
                          versionTrack: entry.track,
                        ),
                        onAddToQueue: () =>
                            _addTrackToQueue(detail, entry.track),
                        onOpenArtist: () =>
                            _handleOpenArtist(detail.artistName, detail),
                      ),
                    );
                    if (!entry.showDiscHeader) {
                      return row;
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: EdgeInsets.only(
                            top: i == 0 ? 4 : 14,
                            bottom: 6,
                            left: 8,
                          ),
                          child: Text(
                            'Disc ${entry.track.discNumber}',
                            style: const TextStyle(
                              color: LuminaTokens.textMuted,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                        row,
                      ],
                    );
                  },
                ),
              ),

            // 3. Editorial Bio & Bottom Padding Sliver
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                hPad,
                LuminaTokens.spaceMd,
                hPad,
                vPad + LuminaTokens.bottomScrollClearance,
              ),
              sliver: SliverToBoxAdapter(
                child:
                    (detail.editorialBio != null &&
                        detail.editorialBio!.isNotEmpty)
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '簡介',
                            style: TextStyle(
                              color: LuminaTokens.textSecondary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(height: LuminaTokens.spaceXs),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: _cardBg,
                              borderRadius: BorderRadius.circular(
                                LuminaTokens.radiusSm,
                              ),
                              border: Border.all(color: _dividerColor),
                            ),
                            child: Text(
                              detail.editorialBio!,
                              style: const TextStyle(
                                color: LuminaTokens.textSecondary,
                                fontSize: 13,
                                height: 1.6,
                              ),
                            ),
                          ),
                        ],
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeroMeta(
    CanonicalAlbumDetail detail,
    AlbumVersionInfo? ver, {
    required bool isWide,
  }) {
    final unifiedMetadata = AlbumDetailPage.formatUnifiedMetadata(ver);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Album Title (large bold white, wrapping cleanly)
        Text(
          detail.title,
          key: const Key('album_hero_title'),
          style: TextStyle(
            color: Colors.white,
            fontSize: isWide ? 26 : 22,
            fontWeight: FontWeight.w800,
            height: 1.2,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 8),

        // Hoverable & clickable artist name directly below title
        RepaintBoundary(
          child: _ClickableArtistLink(
            key: const Key('album_hero_artist'),
            artistName: detail.artistName,
            fontSize: 15,
            fontWeight: FontWeight.w600,
            defaultColor: const Color(0xFFD5D9E6),
            hoverColor: _accentBlue,
            onTap: () => _handleOpenArtist(detail.artistName, detail),
          ),
        ),

        // Release Year & Audio Format Badge
        if (detail.releaseYear != null || ver != null) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (detail.releaseYear != null)
                Text(
                  '${detail.releaseYear}',
                  style: const TextStyle(
                    color: LuminaTokens.textMuted,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              if (ver != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: _accentBlue.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: _accentBlue.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    ver.formatSummary,
                    style: const TextStyle(
                      color: _accentBlue,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ],

        const SizedBox(height: 10),

        // Single-line unified metadata row: '總時長 · 音檔格式 · 取樣率 · 位元深度 · 曲目數'
        Text(
          unifiedMetadata,
          key: const Key('album_unified_metadata_row'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: LuminaTokens.textSecondary,
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.2,
          ),
        ),

        const SizedBox(height: LuminaTokens.spaceMd),

        // Action Buttons Row (Primary pill '播放專輯' + Secondary buttons)
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              key: const Key('btn_play_album'),
              onPressed: () => _playTrack(detail),
              icon: const Icon(Icons.play_arrow_rounded, size: 19),
              label: const Text(
                '播放專輯',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: _accentBlue,
                foregroundColor: LuminaTokens.onAccentDark,
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 11,
                ),
              ),
            ),
            IconButton.outlined(
              key: const Key('btn_add_album_to_queue'),
              tooltip: '將專輯加入播放佇列',
              onPressed: () => _addAlbumToQueue(detail, ver),
              icon: const Icon(Icons.playlist_add_rounded, size: 19),
              style: OutlinedButton.styleFrom(
                foregroundColor: LuminaTokens.textPrimary,
                side: const BorderSide(color: LuminaTokens.borderControl),
              ),
            ),
            OutlinedButton.icon(
              key: const Key('btn_set_album_cover'),
              onPressed: _promptSetExternalCover,
              icon: const Icon(Icons.image_outlined, size: 16),
              label: const Text('設定外部封面', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                foregroundColor: LuminaTokens.textPrimary,
                side: const BorderSide(color: LuminaTokens.borderControl),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
            ),
            TextButton.icon(
              key: const Key('btn_clear_album_cover'),
              onPressed: _handleClearCover,
              icon: const Icon(Icons.clear_rounded, size: 16),
              label: const Text('清除封面', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                foregroundColor: LuminaTokens.textMuted,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
            ),
            PopupMenuButton<String>(
              key: const Key('btn_album_more_options'),
              tooltip: '更多專輯選項',
              color: LuminaTokens.cardElevatedBg,
              icon: const Icon(
                Icons.more_horiz_rounded,
                size: 19,
                color: LuminaTokens.textSecondary,
              ),
              onSelected: (action) {
                switch (action) {
                  case 'add_queue':
                    _addAlbumToQueue(detail, ver);
                  case 'set_cover':
                    _promptSetExternalCover();
                  case 'clear_cover':
                    _handleClearCover();
                  case 'open_artist':
                    _handleOpenArtist(detail.artistName, detail);
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem<String>(
                  value: 'add_queue',
                  child: Text(
                    '全部加入待播佇列',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'open_artist',
                  child: Text(
                    '檢視藝術家頁面',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem<String>(
                  value: 'set_cover',
                  child: Text(
                    '設定外部封面...',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'clear_cover',
                  child: Text(
                    '清除自訂封面',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

// ─── Hover-Isolated Clickable Artist Link ─────────────────────────────────────

class _ClickableArtistLink extends StatefulWidget {
  final String artistName;
  final double fontSize;
  final FontWeight fontWeight;
  final Color defaultColor;
  final Color hoverColor;
  final VoidCallback onTap;

  const _ClickableArtistLink({
    super.key,
    required this.artistName,
    required this.fontSize,
    required this.fontWeight,
    required this.defaultColor,
    required this.hoverColor,
    required this.onTap,
  });

  @override
  State<_ClickableArtistLink> createState() => _ClickableArtistLinkState();
}

class _ClickableArtistLinkState extends State<_ClickableArtistLink> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final activeColor = _isHovered ? widget.hoverColor : widget.defaultColor;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_isHovered) setState(() => _isHovered = true);
      },
      onExit: (_) {
        if (_isHovered) setState(() => _isHovered = false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Text(
          widget.artistName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: activeColor,
            fontSize: widget.fontSize,
            fontWeight: widget.fontWeight,
            decoration: _isHovered
                ? TextDecoration.underline
                : TextDecoration.none,
            decorationColor: activeColor,
          ),
        ),
      ),
    );
  }
}

// ─── Hover-Isolated Virtualized Track Row ─────────────────────────────────────

class _AlbumTrackRow extends StatefulWidget {
  final int index;
  final AlbumVersionTrackInfo track;
  final String displayNumber;
  final String artistName;
  final String albumTitle;
  final ValueListenable<_ActivePlaybackSnapshot> playbackListenable;
  final VoidCallback onPlay;
  final VoidCallback onAddToQueue;
  final VoidCallback onOpenArtist;

  const _AlbumTrackRow({
    super.key,
    required this.index,
    required this.track,
    required this.displayNumber,
    required this.artistName,
    required this.albumTitle,
    required this.playbackListenable,
    required this.onPlay,
    required this.onAddToQueue,
    required this.onOpenArtist,
  });

  @override
  State<_AlbumTrackRow> createState() => _AlbumTrackRowState();
}

class _AlbumTrackRowState extends State<_AlbumTrackRow> {
  static const _accentBlue = LuminaTokens.accentBlue;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_ActivePlaybackSnapshot>(
      valueListenable: widget.playbackListenable,
      builder: (context, snapshot, _) {
        final isMatched = snapshot.matchesTrack(
          widget.track,
          widget.albumTitle,
        );
        final isPlaying = isMatched && snapshot.isActivelyPlaying;

        final rowBg = isPlaying
            ? _accentBlue.withValues(alpha: _isHovered ? 0.20 : 0.14)
            : (_isHovered
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.transparent);

        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) {
            if (!_isHovered) setState(() => _isHovered = true);
          },
          onExit: (_) {
            if (_isHovered) setState(() => _isHovered = false);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPlay,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 110),
              margin: const EdgeInsets.symmetric(vertical: 2),
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              decoration: BoxDecoration(
                color: rowBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isPlaying
                      ? _accentBlue.withValues(alpha: 0.42)
                      : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  // Track Number or Playing Indicator Icon (smooth 30ms transition on hover to play button)
                  SizedBox(
                    width: 34,
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 30),
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: child,
                        ),
                        child: isPlaying
                            ? Icon(
                                Icons.equalizer_rounded,
                                key: Key(
                                  'track_playing_icon_${widget.track.id}',
                                ),
                                size: 18,
                                color: _accentBlue,
                              )
                            : (_isHovered
                                ? Icon(
                                    Icons.play_arrow_rounded,
                                    key: Key('track_hover_play_${widget.index}'),
                                    size: 18,
                                    color: _accentBlue,
                                  )
                                : Text(
                                    widget.displayNumber,
                                    key: Key('track_number_${widget.index}'),
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: LuminaTokens.textMuted,
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  )),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),

                  // Track Title & Clickable Small Artist Name
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isPlaying
                                ? _accentBlue
                                : LuminaTokens.textPrimary,
                            fontSize: 13.5,
                            fontWeight: isPlaying
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: _ClickableArtistLink(
                                key: Key('album_track_artist_${widget.index}'),
                                artistName: widget.artistName,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w400,
                                defaultColor: LuminaTokens.textSecondary,
                                hoverColor: _accentBlue,
                                onTap: widget.onOpenArtist,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Track Duration
                  Text(
                    _fmtMs(widget.track.durationMs),
                    style: TextStyle(
                      color: isPlaying ? _accentBlue : LuminaTokens.textMuted,
                      fontSize: 12.5,
                      fontWeight: isPlaying
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Right-side Quick Actions (Play / Add to Queue)
                  IconButton(
                    key: Key('album_track_play_${widget.index}'),
                    onPressed: widget.onPlay,
                    tooltip: '播放曲目',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    icon: Icon(
                      Icons.play_arrow_rounded,
                      size: 18,
                      color: isPlaying || _isHovered
                          ? _accentBlue
                          : LuminaTokens.textMuted,
                    ),
                  ),
                  IconButton(
                    key: Key('album_track_queue_${widget.index}'),
                    onPressed: widget.onAddToQueue,
                    tooltip: '加入播放佇列',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    icon: Icon(
                      Icons.playlist_add_rounded,
                      size: 17,
                      color: _isHovered
                          ? LuminaTokens.textPrimary
                          : LuminaTokens.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _fmtMs(int ms) {
    final d = Duration(milliseconds: ms);
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

// ─── Version Chip ─────────────────────────────────────────────────────────────

class _VersionChip extends StatelessWidget {
  final AlbumVersionInfo version;
  final bool isSelected;
  final VoidCallback onTap;

  static const _accentBlue = LuminaTokens.accentBlue;

  const _VersionChip({
    super.key,
    required this.version,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Semantics(
        button: true,
        selected: isSelected,
        label: version.editionLabel,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: LuminaTokens.hoverDuration,
            curve: LuminaTokens.motionCurve,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: isSelected
                  ? _accentBlue.withValues(alpha: 0.15)
                  : LuminaTokens.cardElevatedBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isSelected ? _accentBlue : LuminaTokens.borderControl,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  version.editionLabel,
                  style: TextStyle(
                    color: isSelected ? _accentBlue : LuminaTokens.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${_providerLabel(version.provider)} · ${version.formatSummary}',
                  style: const TextStyle(
                    color: LuminaTokens.textMuted,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _providerLabel(String provider) => switch (provider) {
        'local' => '本機',
        'tidal' => 'Tidal',
        'qobuz' => 'Qobuz',
        'apple_music' => 'Apple Music',
        'youtube_music' => 'YTM',
        'deezer' => 'Deezer',
        _ => provider,
      };
}

// ─── Credit Chip ──────────────────────────────────────────────────────────────

class _CreditChip extends StatelessWidget {
  final AlbumCreditInfo credit;
  final VoidCallback? onTap;

  static const _accentBlue = Color(0xFF7B92F8);

  const _CreditChip({required this.credit, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: Key('detail_credit_${credit.artistId}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: LuminaTokens.cardBg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: LuminaTokens.borderControl),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              credit.artistName,
              style: const TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              credit.role,
              style: const TextStyle(color: _accentBlue, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
