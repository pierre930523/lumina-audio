import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/streaming_models.dart';
import '../../models/streaming_provider_meta.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../../services/listen_later_controller.dart';
import '../../services/streaming/streaming_manager.dart';
import '../../services/unified_search_controller.dart';
import '../artwork/album_artwork_view.dart';
import '../common/track_context_menu.dart';
import '../common/track_hover_prefetch.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';

part 'unified_search_filter_bar.dart';
part 'unified_search_result_cards.dart';

/// Unified search results workspace displaying instant local library matches
/// alongside non-blocking parallel results from all connected streaming
/// services across Songs, Albums, and Artists.
class UnifiedSearchResultsView extends StatefulWidget {
  final UnifiedSearchController controller;
  final AudioService audioService;
  final LibraryIndexCache libraryCache;
  final StreamingManager streamingManager;
  final ListenLaterController? listenLaterController;
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
    this.listenLaterController,
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
  final GlideScrollController _scrollController = GlideScrollController();
  final GlideScrollController _filterScrollController = GlideScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    _filterScrollController.dispose();
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
