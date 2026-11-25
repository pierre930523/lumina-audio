import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/streaming_models.dart';
import '../../models/streaming_provider_meta.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../../services/streaming/streaming_manager.dart';
import '../../services/unified_search_controller.dart';
import '../artwork/album_artwork_view.dart';
import '../common/track_hover_prefetch.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';

/// Unified search results workspace displaying instant local library matches
/// alongside non-blocking parallel results from all connected streaming
/// services across Songs, Albums, and Artists.
class UnifiedSearchResultsView extends StatefulWidget {
  final UnifiedSearchController controller;
  final AudioService audioService;
  final LibraryIndexCache libraryCache;
  final StreamingManager streamingManager;
  final String? activeTrackId;
  final void Function(String albumId) onOpenLocalAlbum;
  final void Function(StreamingAlbum album) onOpenStreamingAlbum;
  final void Function(String artistName) onOpenArtist;
  final Future<void> Function(
    TrackInfo track, {
    List<TrackInfo>? queueContext,
  }) onPlayStreamingTrack;

  const UnifiedSearchResultsView({
    super.key,
    required this.controller,
    required this.audioService,
    required this.libraryCache,
    required this.streamingManager,
    this.activeTrackId,
    required this.onOpenLocalAlbum,
    required this.onOpenStreamingAlbum,
    required this.onOpenArtist,
    required this.onPlayStreamingTrack,
  });

  @override
  State<UnifiedSearchResultsView> createState() =>
      _UnifiedSearchResultsViewState();
}

class _UnifiedSearchResultsViewState extends State<UnifiedSearchResultsView> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  List<TrackInfo> _streamingQueueFor(String kind) {
    return widget.controller.streamingBuckets[kind]?.tracks ?? const [];
  }

  String _formatDuration(Duration duration) {
    if (duration <= Duration.zero) return '';
    final totalSec = duration.inSeconds;
    final mins = totalSec ~/ 60;
    final secs = totalSec % 60;
    return '$mins:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.controller, widget.streamingManager]),
      builder: (context, _) {
        final ctrl = widget.controller;
        final query = ctrl.query;
        final tracks = ctrl.visibleTracks;
        final albums = ctrl.visibleAlbums;
        final artists = ctrl.visibleArtists;
        final errors = ctrl.visibleErrors;

        return Column(
          key: const Key('unified_search_results_view'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(ctrl, query),
            const SizedBox(height: LuminaTokens.spaceSm),
            _buildSourceFilterBar(ctrl),
            if (errors.isNotEmpty) ...[
              const SizedBox(height: LuminaTokens.spaceXs),
              for (final err in errors)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: _buildProviderErrorBanner(err),
                ),
            ],
            const SizedBox(height: LuminaTokens.spaceSm),
            Expanded(
              child: _buildResultsBody(
                ctrl: ctrl,
                query: query,
                tracks: tracks,
                albums: albums,
                artists: artists,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeader(UnifiedSearchController ctrl, String query) {
    return Row(
      children: [
        const Icon(
          Icons.manage_search_rounded,
          color: LuminaTokens.glassTextPrimary,
          size: 22,
        ),
        const SizedBox(width: LuminaTokens.spaceXs),
        Expanded(
          child: Text(
            query.isEmpty ? '整合搜尋' : '搜尋「$query」',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (ctrl.isAnyLoading) ...[
          const SizedBox(width: LuminaTokens.spaceXs),
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: LuminaTokens.glassTextPrimary,
            ),
          ),
          const SizedBox(width: 6),
          const Text(
            '搜尋中...',
            style: TextStyle(
              color: LuminaTokens.textMuted,
              fontSize: 12,
            ),
          ),
        ] else if (query.isNotEmpty)
          Text(
            '共 ${ctrl.totalResultCount} 項結果',
            style: const TextStyle(
              color: LuminaTokens.textMuted,
              fontSize: 12,
            ),
          ),
      ],
    );
  }

  Widget _buildSourceFilterBar(UnifiedSearchController ctrl) {
    final buckets = ctrl.streamingBuckets;
    final providerKinds = <String>[
      ...ctrl.orderedStreamingKinds,
      for (final p in widget.streamingManager.browsableProviders)
        if (!buckets.containsKey(p.kind)) p.kind,
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _buildSourceChip(
            chipKey: const Key('search_source_all'),
            selected: ctrl.selectedSource == 'all',
            onTap: () => ctrl.selectSource('all'),
            leading: const Icon(
              Icons.apps_rounded,
              size: 15,
              color: LuminaTokens.glassTextPrimary,
            ),
            label: '全部 (${ctrl.totalResultCount})',
            isLoading: ctrl.isAnyLoading,
            hasError: false,
          ),
          const SizedBox(width: LuminaTokens.spaceXs),
          _buildSourceChip(
            chipKey: const Key('search_source_local'),
            selected: ctrl.selectedSource == 'local',
            onTap: () => ctrl.selectSource('local'),
            leading: const Icon(
              Icons.library_music_rounded,
              size: 15,
              color: LuminaTokens.textSecondary,
            ),
            label: '本機曲庫 (${ctrl.localTotalCount})',
            isLoading: ctrl.isSearchingLocal,
            hasError: false,
          ),
          for (final kind in providerKinds)
            if (StreamingProviderMeta.byKind(kind) case final meta?) ...[
              const SizedBox(width: LuminaTokens.spaceXs),
              _buildProviderFilterChip(
                meta: meta,
                bucket: buckets[kind],
                selected: ctrl.selectedSource == kind,
                onTap: () => ctrl.selectSource(kind),
              ),
            ],
        ],
      ),
    );
  }

  Widget _buildProviderFilterChip({
    required StreamingProviderMeta meta,
    required ProviderSearchBucket? bucket,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final isLoading = bucket?.isLoading ?? false;
    final hasError = bucket?.hasError ?? false;
    final count = bucket?.totalCount ?? 0;
    final label = (isLoading && count == 0)
        ? meta.name
        : '${meta.name} ($count)';

    return _buildSourceChip(
      chipKey: Key('search_source_${meta.kind}'),
      selected: selected,
      onTap: bucket != null ? onTap : null,
      leading: meta.buildBadge(boxSize: 16, borderRadius: 4),
      label: label,
      isLoading: isLoading,
      hasError: hasError,
    );
  }

  Widget _buildSourceChip({
    required Key chipKey,
    required bool selected,
    required VoidCallback? onTap,
    required Widget leading,
    required String label,
    required bool isLoading,
    required bool hasError,
  }) {
    return ChoiceChip(
      key: chipKey,
      selected: selected,
      showCheckmark: false,
      surfaceTintColor: Colors.transparent,
      onSelected: onTap != null ? (_) => onTap() : null,
      backgroundColor: LuminaTokens.glassPillBg,
      selectedColor: LuminaTokens.glassSegmentSelectedBg,
      side: BorderSide(
        color: selected
            ? LuminaTokens.glassSegmentSelectedBorder
            : (hasError
                  ? LuminaTokens.statusWarning
                  : LuminaTokens.glassPillBorder),
      ),
      avatar: leading,
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: selected
                  ? Colors.white
                  : LuminaTokens.glassTextSecondary,
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
          if (isLoading) ...[
            const SizedBox(width: 6),
            const SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: LuminaTokens.glassTextPrimary,
              ),
            ),
          ] else if (hasError) ...[
            const SizedBox(width: 5),
            const Icon(
              Icons.error_outline_rounded,
              size: 14,
              color: LuminaTokens.statusWarning,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProviderErrorBanner(
    ({String kind, String name, String error}) err,
  ) {
    return Container(
      key: Key('search_error_${err.kind}'),
      padding: const EdgeInsets.symmetric(
        horizontal: LuminaTokens.spaceSm,
        vertical: LuminaTokens.spaceXs,
      ),
      decoration: BoxDecoration(
        color: LuminaTokens.statusWarning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(
          color: LuminaTokens.statusWarning.withValues(alpha: 0.55),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 16,
            color: LuminaTokens.statusWarning,
          ),
          const SizedBox(width: LuminaTokens.spaceXs),
          Expanded(
            child: Text(
              '${err.name} 搜尋未完成：${err.error}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsBody({
    required UnifiedSearchController ctrl,
    required String query,
    required List<SearchTrackMatch> tracks,
    required List<SearchAlbumMatch> albums,
    required List<SearchArtistMatch> artists,
  }) {
    if (query.isEmpty) {
      return _buildCenteredMessage(
        icon: Icons.search_rounded,
        title: '輸入關鍵字搜尋曲庫與串流服務',
        subtitle: '支援即時搜尋本機歌曲、專輯、藝術家與已連線串流平台。',
      );
    }

    if (tracks.isEmpty && albums.isEmpty && artists.isEmpty) {
      if (ctrl.isAnyLoading) {
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: LuminaTokens.glassTextPrimary),
              SizedBox(height: LuminaTokens.spaceSm),
              Text(
                '正在查詢本機曲庫與串流服務...',
                style: TextStyle(
                  color: LuminaTokens.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        );
      }
      return _buildCenteredMessage(
        icon: Icons.search_off_rounded,
        title: '找不到符合「$query」的結果',
        subtitle: '請嘗試調整關鍵字或切換上方來源篩選標籤。',
      );
    }

    return SmoothScrollWrapper(
      controller: _scrollController,
      child: CustomScrollView(
        controller: _scrollController,
        slivers: [
          if (tracks.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: _buildSectionTitle('歌曲', tracks.length),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildTrackRow(tracks[index]),
                childCount: tracks.length,
              ),
            ),
            const SliverToBoxAdapter(
              child: SizedBox(height: LuminaTokens.spaceMd),
            ),
          ],
          if (albums.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: _buildSectionTitle('專輯', albums.length),
            ),
            SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 205,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 0.72,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildAlbumCard(albums[index]),
                childCount: albums.length,
              ),
            ),
            const SliverToBoxAdapter(
              child: SizedBox(height: LuminaTokens.spaceMd),
            ),
          ],
          if (artists.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: _buildSectionTitle('藝術家', artists.length),
            ),
            SliverToBoxAdapter(
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final artist in artists) _buildArtistCard(artist),
                ],
              ),
            ),
          ],
          const SliverToBoxAdapter(
            child: SizedBox(height: LuminaTokens.bottomScrollClearance),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title, int count) {
    return Padding(
      padding: const EdgeInsets.only(bottom: LuminaTokens.spaceXs),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: LuminaTokens.glassPillBg,
              borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
              border: Border.all(color: LuminaTokens.glassPillBorder),
            ),
            child: Text(
              '$count',
              style: const TextStyle(
                color: LuminaTokens.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackRow(SearchTrackMatch match) {
    final track = match.track;
    final isSelected = widget.activeTrackId == track.id;
    final durationLabel = _formatDuration(track.duration);

    return TrackHoverPrefetch(
      track: track,
      enabled: !match.isLocal,
      child: Material(
        color: isSelected ? LuminaTokens.glassNavActiveBg : Colors.transparent,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        child: InkWell(
          key: Key('search_track_${match.sourceKind}_${track.id}'),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        hoverColor: LuminaTokens.glassRowHoverBg,
        onTap: () {
          if (match.isLocal) {
            widget.audioService.play(track: track);
          } else {
            widget.onPlayStreamingTrack(
              track,
              queueContext: _streamingQueueFor(match.sourceKind),
            );
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            children: [
              AlbumArtworkView(
                track: track,
                size: 40,
                borderRadius: BorderRadius.circular(6),
                audioService: match.isLocal ? widget.audioService : null,
                libraryCache: match.isLocal ? widget.libraryCache : null,
                fullResolution: false,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isSelected
                            ? Colors.white
                            : LuminaTokens.glassTextPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      track.album.trim().isNotEmpty
                          ? '${track.artist} · ${track.album}'
                          : track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _SourceBadge(sourceKind: match.sourceKind, size: 18),
              if (MediaQuery.sizeOf(context).width >= 540) ...[
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: LuminaTokens.glassPillBg,
                      borderRadius: BorderRadius.circular(
                        LuminaTokens.radiusPill,
                      ),
                      border: Border.all(color: LuminaTokens.glassPillBorder),
                    ),
                    child: Text(
                      track.format.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.textSecondary,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
              if (durationLabel.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  durationLabel,
                  style: const TextStyle(
                    color: LuminaTokens.textMuted,
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildAlbumCard(SearchAlbumMatch match) {
    final artworkAlbum = match.localAlbum ??
        CanonicalAlbumSummary(
          id: 'streaming:${match.sourceKind}:${match.id}',
          title: match.title,
          artist: match.artist,
          year: match.year,
          availableProviders: <String>[match.sourceKind],
          coverUrl: match.coverUrl,
        );
    final metaParts = <String>[
      if (match.year != null) '${match.year}',
      if (match.qualityLabel != null && match.qualityLabel!.trim().isNotEmpty)
        match.qualityLabel!,
    ];

    return Material(
      color: LuminaTokens.glassCardBg,
      borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
      child: InkWell(
        key: Key('search_album_${match.sourceKind}_${match.id}'),
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        hoverColor: LuminaTokens.glassRowHoverBg,
        onTap: () {
          if (match.localAlbum != null) {
            widget.onOpenLocalAlbum(match.localAlbum!.id);
          } else if (match.streamingAlbum != null) {
            widget.onOpenStreamingAlbum(match.streamingAlbum!);
          }
        },
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
            border: Border.all(color: LuminaTokens.glassCardBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(
                        LuminaTokens.radiusSm,
                      ),
                      child: AlbumArtworkView(
                        album: artworkAlbum,
                        size: 160,
                        borderRadius: BorderRadius.circular(
                          LuminaTokens.radiusSm,
                        ),
                        audioService:
                            match.isLocal ? widget.audioService : null,
                        libraryCache:
                            match.isLocal ? widget.libraryCache : null,
                        fullResolution: false,
                      ),
                    ),
                    Positioned(
                      top: 6,
                      right: 6,
                      child: _SourceBadge(sourceKind: match.sourceKind, size: 20),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                match.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: LuminaTokens.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                match.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: LuminaTokens.textSecondary,
                  fontSize: 11.5,
                ),
              ),
              if (metaParts.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  metaParts.join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.textMuted,
                    fontSize: 10.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildArtistCard(SearchArtistMatch artist) {
    final avatarAlbum = artist.representativeAlbum ??
        (artist.coverUrl != null && artist.coverUrl!.trim().isNotEmpty
            ? CanonicalAlbumSummary(
                id: 'artist_art_${artist.name}',
                title: artist.name,
                artist: artist.name,
                coverUrl: artist.coverUrl,
              )
            : null);
    final isLocalArtist = artist.sourceKinds.contains('local');

    return Material(
      color: LuminaTokens.glassCardBg,
      borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
      child: InkWell(
        key: Key('search_artist_${artist.name}'),
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        hoverColor: LuminaTokens.glassRowHoverBg,
        onTap: () => widget.onOpenArtist(artist.name),
        child: Container(
          constraints: const BoxConstraints(minWidth: 160, maxWidth: 260),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
            border: Border.all(color: LuminaTokens.glassCardBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AlbumArtworkView(
                album: avatarAlbum,
                track: artist.representativeTrack,
                size: 36,
                circular: true,
                audioService: isLocalArtist ? widget.audioService : null,
                libraryCache: isLocalArtist ? widget.libraryCache : null,
                fullResolution: false,
                placeholder: Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(
                    color: LuminaTokens.glassPillBg,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.person_rounded,
                    size: 20,
                    color: LuminaTokens.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      artist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final kind in artist.sourceKinds)
                          _SourceBadge(
                            sourceKind: kind,
                            size: 15,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCenteredMessage({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(LuminaTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: LuminaTokens.textMuted),
            const SizedBox(height: LuminaTokens.spaceSm),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: LuminaTokens.spaceXs),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: LuminaTokens.textSecondary,
                fontSize: 12.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  final String sourceKind;
  final double size;

  const _SourceBadge({
    required this.sourceKind,
    this.size = 18,
  });

  @override
  Widget build(BuildContext context) {
    if (sourceKind == 'local') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: LuminaTokens.glassPillBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
          border: Border.all(color: LuminaTokens.glassPillBorder),
        ),
        child: const Text(
          '本機',
          style: TextStyle(
            color: LuminaTokens.textSecondary,
            fontSize: 10,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }

    final meta = StreamingProviderMeta.byKind(sourceKind);
    if (meta != null) {
      return meta.buildBadge(boxSize: size, borderRadius: 4);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: LuminaTokens.glassPillBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        border: Border.all(color: LuminaTokens.glassPillBorder),
      ),
      child: Text(
        sourceKind,
        style: const TextStyle(
          color: LuminaTokens.textSecondary,
          fontSize: 10,
        ),
      ),
    );
  }
}
