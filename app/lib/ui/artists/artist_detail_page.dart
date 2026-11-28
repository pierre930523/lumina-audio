import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/audio_format.dart';
import '../../models/playback_state.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../artwork/album_artwork_view.dart';
import '../common/preference_toggle_button.dart';
import '../common/track_context_menu.dart';
import '../common/track_hover_prefetch.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';

part 'artist_detail_loader.dart';
part 'artist_detail_hero.dart';
part 'artist_detail_items.dart';

/// Standalone Artist Detail Page using a single virtualized [CustomScrollView]
/// and Sliver protocol throughout for 60fps+ desktop scrolling.
class ArtistDetailPage extends StatefulWidget {
  final String artistName;
  final String? artistKey;
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final VoidCallback? onBack;
  final bool showInlineBackButton;
  final bool useAlbumArtworkAsAvatar;
  final void Function(String albumId)? onOpenAlbumDetail;
  final VoidCallback? onOpenCredits;
  final double initialScrollOffset;
  final ValueChanged<double>? onScrollOffsetChanged;
  final ValueChanged<String>? onTitleChanged;

  /// Scroll offset threshold past which the compact sticky header should appear in the top bar.
  static const double stickyTitleScrollThreshold = 200.0;

  const ArtistDetailPage({
    super.key,
    required this.artistName,
    this.artistKey,
    required this.audioService,
    this.libraryCache,
    this.onBack,
    this.showInlineBackButton = true,
    this.useAlbumArtworkAsAvatar = false,
    this.onOpenAlbumDetail,
    this.onOpenCredits,
    this.initialScrollOffset = 0.0,
    this.onScrollOffsetChanged,
    this.onTitleChanged,
  });

  @override
  State<ArtistDetailPage> createState() => _ArtistDetailPageState();
}

class _ArtistDetailPageState extends State<ArtistDetailPage> {
  static const int previewTrackLimit = 6;

  late final GlideScrollController _scrollController;
  String _displayName = '';
  String? _artistId;
  int _artistPreference = 0;
  List<CanonicalAlbumSummary> _albums = const [];
  List<TrackInfo> _tracks = const [];
  CanonicalAlbumSummary? _representativeAlbum;
  TrackInfo? _representativeTrack;
  bool _preferTrackForAvatar = false;
  bool _loading = true;
  bool _showAllTracks = false;
  int _loadToken = 0;

  void _setState(VoidCallback fn) => setState(fn);

  String get _lookupKey {
    final k = widget.artistKey?.trim() ?? '';
    if (k.isNotEmpty) return LibraryIndexCache.normalizeArtistKey(k);
    return LibraryIndexCache.normalizeArtistKey(widget.artistName);
  }

  @override
  void initState() {
    super.initState();
    _displayName = widget.artistName.trim().isNotEmpty
        ? widget.artistName.trim()
        : (widget.artistKey?.trim() ?? '未知藝術家');
    _scrollController = GlideScrollController(
      initialScrollOffset: widget.initialScrollOffset < 0
          ? 0.0
          : widget.initialScrollOffset,
    );
    _scrollController.addListener(_handleScroll);
    widget.libraryCache?.addListener(_onLibraryCacheChanged);
    _primeFromSyncAndRefresh();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _notifyTitleChanged();
      if (widget.initialScrollOffset > 0 && _scrollController.hasClients) {
        widget.onScrollOffsetChanged?.call(_scrollController.offset);
      }
    });
  }

  @override
  void didUpdateWidget(covariant ArtistDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.libraryCache != widget.libraryCache) {
      oldWidget.libraryCache?.removeListener(_onLibraryCacheChanged);
      widget.libraryCache?.addListener(_onLibraryCacheChanged);
    }
    if (oldWidget.artistName != widget.artistName ||
        oldWidget.artistKey != widget.artistKey ||
        oldWidget.audioService != widget.audioService ||
        oldWidget.libraryCache != widget.libraryCache ||
        oldWidget.useAlbumArtworkAsAvatar != widget.useAlbumArtworkAsAvatar) {
      _showAllTracks = false;
      _preferTrackForAvatar = false;
      _displayName = widget.artistName.trim().isNotEmpty
          ? widget.artistName.trim()
          : (widget.artistKey?.trim() ?? '未知藝術家');
      _notifyTitleChanged();
      _primeFromSyncAndRefresh();
    }
  }

  @override
  void dispose() {
    widget.libraryCache?.removeListener(_onLibraryCacheChanged);
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!_scrollController.hasClients) return;
    widget.onScrollOffsetChanged?.call(_scrollController.offset);
  }

  void _notifyTitleChanged() {
    if (_displayName.isNotEmpty) {
      widget.onTitleChanged?.call(_displayName);
    }
  }

  bool _isEntryUnchanged(ArtistIndexEntry entry) {
    final nextName = entry.displayName.trim();
    final nameMatches = nextName.isEmpty || nextName == _displayName;
    return !_loading &&
        nameMatches &&
        identical(entry.tracks, _tracks) &&
        identical(entry.albums, _albums) &&
        identical(entry.representativeAlbum, _representativeAlbum) &&
        identical(entry.representativeTrack, _representativeTrack);
  }

  void _onLibraryCacheChanged() {
    if (!mounted) return;
    final entry = widget.libraryCache?.getArtistSync(_lookupKey);
    if (entry == null || _isEntryUnchanged(entry)) return;
    setState(() {
      _applyEntry(entry);
      _loading = false;
    });
  }

  void _applyEntry(ArtistIndexEntry entry) {
    if (entry.displayName.trim().isNotEmpty) {
      _displayName = entry.displayName.trim();
    }
    if (entry.artistId != null && entry.artistId!.isNotEmpty) {
      _artistId = entry.artistId;
    }
    _artistPreference = entry.preference;
    _albums = entry.albums.any((a) => a.trackCount == 0)
        ? List<CanonicalAlbumSummary>.unmodifiable(
            entry.albums.where((a) => a.trackCount == null || a.trackCount! > 0),
          )
        : entry.albums;
    _tracks = entry.tracks;
    _representativeAlbum = entry.representativeAlbum;
    _representativeTrack = entry.representativeTrack;
    _notifyTitleChanged();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackState>(
      stream: widget.audioService.stateStream,
      initialData: widget.audioService.currentState,
      builder: (context, snapshot) {
        final playbackState = snapshot.data ?? widget.audioService.currentState;
        final activeTrackId = playbackState.track?.id;

        return LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 640;
            final hPad = isWide ? 24.0 : 12.0;
            final visibleTrackCount = _showAllTracks
                ? _tracks.length
                : math.min(_tracks.length, previewTrackLimit);

            return KeyedSubtree(
              key: const Key('artist_detail_scroll_view'),
              child: SmoothScrollWrapper(
                controller: _scrollController,
                child: CustomScrollView(
                  key: PageStorageKey<String>('artist_detail_$_lookupKey'),
                  controller: _scrollController,
                  slivers: [
                  // ─── Section 1: Artist Hero ───
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        hPad,
                        isWide ? 18 : 12,
                        hPad,
                        isWide ? 24 : 18,
                      ),
                      child: _buildHeroSection(
                        isWide: isWide,
                        maxWidth: constraints.maxWidth,
                      ),
                    ),
                  ),

                  if (_loading && _tracks.isEmpty && _albums.isEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 48),
                        child: Center(
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: LuminaTokens.glassTextPrimary,
                          ),
                        ),
                      ),
                    ),

                  // ─── Section 2: '曲目' Preview & Inline Virtualized List ───
                  if (_tracks.isNotEmpty) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(hPad, 4, hPad, 10),
                        child: _buildTracksHeader(),
                      ),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.symmetric(horizontal: hPad),
                      sliver: SliverList.builder(
                        itemCount: visibleTrackCount,
                        itemBuilder: (context, index) {
                          final track = _tracks[index];
                          final resolvedAlbum = _resolveAlbumForTrack(track);
                          final isPlaying =
                              activeTrackId != null && activeTrackId == track.id;

                          return RepaintBoundary(
                            child: TrackHoverPrefetch(
                              track: track,
                              child: _ArtistTrackRow(
                                key: Key('artist_track_$index'),
                                index: index,
                                track: track,
                                resolvedAlbum: resolvedAlbum,
                                isPlaying: isPlaying,
                                audioService: widget.audioService,
                                libraryCache: widget.libraryCache,
                                onPlay: () =>
                                    widget.audioService.play(track: track),
                                onOpenAlbumDetail:
                                    (widget.onOpenAlbumDetail != null &&
                                            resolvedAlbum != null)
                                        ? () => widget.onOpenAlbumDetail!(
                                            resolvedAlbum.id,
                                          )
                                        : null,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SliverToBoxAdapter(
                      child: SizedBox(
                        height: LuminaTokens.bottomScrollClearance,
                      ),
                    ),
                  ],

                  // ─── Section 3: '主專輯' High-Density Responsive Grid ───
                  if (_albums.isNotEmpty) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(hPad, 4, hPad, 14),
                        child: _buildAlbumsHeader(),
                      ),
                    ),
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        hPad,
                        0,
                        hPad,
                        LuminaTokens.bottomScrollClearance,
                      ),
                      sliver: SliverGrid.builder(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 200.0,
                              crossAxisSpacing: 16.0,
                              mainAxisSpacing: 20.0,
                              childAspectRatio: 0.72,
                            ),
                        itemCount: _albums.length,
                        itemBuilder: (context, index) {
                          final album = _albums[index];
                          return RepaintBoundary(
                            child: _ArtistAlbumCard(
                              key: Key('artist_album_card_${album.id}'),
                              album: album,
                              audioService: widget.audioService,
                              libraryCache: widget.libraryCache,
                              onTap: widget.onOpenAlbumDetail != null
                                  ? () => widget.onOpenAlbumDetail!(album.id)
                                  : null,
                            ),
                          );
                        },
                      ),
                    ),
                  ],

                  if (!_loading && _tracks.isEmpty && _albums.isEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 56),
                        child: Center(
                          child: Text(
                            '此藝術家在音樂庫中暫無曲目或專輯',
                            style: TextStyle(
                              color: LuminaTokens.textMuted,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              ),
            );
          },
        );
      },
    );
  }
}
