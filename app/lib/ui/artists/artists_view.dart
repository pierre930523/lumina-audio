import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../common/preference_toggle_button.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';
import 'artist_detail_page.dart';

part 'artist_tile.dart';

// ─── Artists View ─────────────────────────────────────────────────────────────

class ArtistsView extends StatefulWidget {
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final void Function(String artistName)? onOpenArtist;
  final VoidCallback? onOpenCredits;
  final void Function(String albumId)? onOpenAlbumDetail;

  const ArtistsView({
    super.key,
    required this.audioService,
    this.libraryCache,
    this.onOpenArtist,
    this.onOpenCredits,
    this.onOpenAlbumDetail,
  });

  @override
  State<ArtistsView> createState() => _ArtistsViewState();
}

class _ArtistsViewState extends State<ArtistsView> {
  final GlideScrollController _scrollController = GlideScrollController();
  List<ArtistIndexEntry> _artists = const [];
  bool _loading = true;
  String _search = '';
  String? _selectedArtistName;

  @override
  void initState() {
    super.initState();
    widget.libraryCache?.addListener(_onLibraryCacheChanged);
    _primeSyncAndLoad();
  }

  @override
  void didUpdateWidget(covariant ArtistsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.libraryCache != widget.libraryCache) {
      oldWidget.libraryCache?.removeListener(_onLibraryCacheChanged);
      widget.libraryCache?.addListener(_onLibraryCacheChanged);
    }
    if (oldWidget.audioService != widget.audioService ||
        oldWidget.libraryCache != widget.libraryCache) {
      _primeSyncAndLoad();
    }
  }

  @override
  void dispose() {
    widget.libraryCache?.removeListener(_onLibraryCacheChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _onLibraryCacheChanged() {
    if (!mounted) return;
    final cache = widget.libraryCache;
    if (cache != null && (cache.isPrimed || cache.artists.isNotEmpty)) {
      if (identical(_artists, cache.artists) && !_loading) return;
      setState(() {
        _artists = cache.artists;
        _loading = false;
      });
    }
  }

  void _primeSyncAndLoad() {
    final cache = widget.libraryCache;
    if (cache != null && cache.artists.isNotEmpty) {
      _artists = cache.artists;
      _loading = false;
      if (!cache.isPrimed) {
        cache.prime(widget.audioService);
      }
      return;
    }

    final queueTracks = widget.audioService.queue;
    if (queueTracks.isNotEmpty) {
      _artists = _aggregateEntries(tracks: queueTracks, albums: const []);
      _loading = false;
    } else {
      _loading = true;
    }

    _loadArtistsAsync();
  }

  Future<void> _loadArtistsAsync() async {
    final cache = widget.libraryCache;
    if (cache != null) {
      await cache.prime(widget.audioService);
      if (!mounted) return;
      if (identical(_artists, cache.artists) && !_loading) return;
      setState(() {
        _artists = cache.artists;
        _loading = false;
      });
      return;
    }

    final tracks = widget.audioService.queue;
    final albums = await widget.audioService.getAlbums(limit: 500);
    final entries = _aggregateEntries(tracks: tracks, albums: albums);

    if (!mounted) return;
    setState(() {
      _artists = entries;
      _loading = false;
    });
  }

  List<ArtistIndexEntry> _aggregateEntries({
    required List<TrackInfo> tracks,
    required List<CanonicalAlbumSummary> albums,
  }) {
    final displayNames = <String, String>{};
    final tracksByArtist = <String, List<TrackInfo>>{};
    final albumsByArtist = <String, Map<String, CanonicalAlbumSummary>>{};

    for (final t in tracks) {
      final raw = t.artist.trim();
      final key = LibraryIndexCache.normalizeArtistKey(raw);
      if (key.isEmpty) continue;
      displayNames.putIfAbsent(key, () => raw);
      tracksByArtist.putIfAbsent(key, () => []).add(t);
    }

    for (final a in albums) {
      final raw = a.artist.trim();
      final key = LibraryIndexCache.normalizeArtistKey(raw);
      if (key.isNotEmpty) {
        displayNames.putIfAbsent(key, () => raw);
        albumsByArtist.putIfAbsent(key, () => {})[a.id] = a;
      }
      final aaRaw = (a.albumArtist ?? '').trim();
      final aaKey = LibraryIndexCache.normalizeArtistKey(aaRaw);
      if (aaKey.isNotEmpty && aaKey != key) {
        displayNames.putIfAbsent(aaKey, () => aaRaw);
        albumsByArtist.putIfAbsent(aaKey, () => {})[a.id] = a;
      }
    }

    final keys = <String>{
      ...tracksByArtist.keys,
      ...albumsByArtist.keys,
    };

    final entries = <ArtistIndexEntry>[];
    for (final key in keys) {
      final artistAlbums =
          (albumsByArtist[key]?.values.toList() ?? <CanonicalAlbumSummary>[])
            ..sort(LibraryIndexCache.compareAlbumsNewestFirst);
      final artistTracks = List<TrackInfo>.unmodifiable(
        tracksByArtist[key] ?? const [],
      );
      final resolvedId = artistTracks
          .map((t) => t.artistId)
          .whereType<String>()
          .firstWhere((id) => id.isNotEmpty, orElse: () => '');
      entries.add(
        ArtistIndexEntry(
          key: key,
          displayName: displayNames[key] ?? key,
          artistId: resolvedId.isNotEmpty ? resolvedId : null,
          albums: List<CanonicalAlbumSummary>.unmodifiable(artistAlbums),
          tracks: artistTracks,
          representativeAlbum: artistAlbums.firstOrNull,
          representativeTrack: artistTracks.firstOrNull,
        ),
      );
    }

    entries.sort(
      (a, b) => a.displayName.toLowerCase().compareTo(
        b.displayName.toLowerCase(),
      ),
    );
    return entries;
  }

  List<ArtistIndexEntry> get _filtered {
    if (_search.isEmpty) return _artists;
    final q = _search.toLowerCase();
    return _artists
        .where((a) => a.displayName.toLowerCase().contains(q))
        .toList();
  }

  void _handleSelectArtist(ArtistIndexEntry artist) {
    if (widget.onOpenArtist != null) {
      widget.onOpenArtist!(artist.displayName);
      return;
    }
    setState(() {
      _selectedArtistName = artist.displayName;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_selectedArtistName != null && widget.onOpenArtist == null) {
      return ArtistDetailPage(
        key: ValueKey('artist_detail_$_selectedArtistName'),
        artistName: _selectedArtistName!,
        audioService: widget.audioService,
        libraryCache: widget.libraryCache,
        onBack: () => setState(() => _selectedArtistName = null),
        onOpenCredits: widget.onOpenCredits,
        onOpenAlbumDetail: widget.onOpenAlbumDetail,
      );
    }

    final filtered = _filtered;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 10),
          child: TextField(
            key: const Key('artists_search_input'),
            decoration: InputDecoration(
              hintText: '搜尋藝術家…',
              hintStyle: const TextStyle(
                color: LuminaTokens.textMuted,
                fontSize: 13,
              ),
              prefixIcon: const Icon(
                Icons.search_rounded,
                size: 18,
                color: LuminaTokens.textMuted,
              ),
              filled: true,
              fillColor: LuminaTokens.glassPillBg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                borderSide: const BorderSide(
                  color: LuminaTokens.glassPillBorder,
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                borderSide: const BorderSide(
                  color: LuminaTokens.glassPillBorder,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                borderSide: const BorderSide(
                  color: LuminaTokens.focusRing,
                  width: 1.5,
                ),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: LuminaTokens.spaceSm,
                vertical: LuminaTokens.spaceSm,
              ),
            ),
            style: const TextStyle(
              color: LuminaTokens.textPrimary,
              fontSize: 13,
            ),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        Expanded(
          child: _loading && _artists.isEmpty
              ? const Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: LuminaTokens.glassTextPrimary,
                  ),
                )
              : filtered.isEmpty
              ? Center(
                  child: Text(
                    _search.isEmpty ? '音樂庫中尚無藝術家資料' : '找不到符合「$_search」的藝術家',
                    style: const TextStyle(
                      color: LuminaTokens.textMuted,
                      fontSize: 14,
                    ),
                  ),
                )
              : SmoothScrollWrapper(
                  controller: _scrollController,
                  child: CustomScrollView(
                    key: const Key('artists_list_view'),
                    controller: _scrollController,
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.only(
                          bottom: LuminaTokens.bottomScrollClearance,
                        ),
                        sliver: SliverList.builder(
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final artist = filtered[index];
                            final isSelected =
                                _selectedArtistName == artist.displayName;
                            return RepaintBoundary(
                              child: _ArtistTile(
                                key: Key('artist_tile_${artist.displayName}'),
                                artist: artist,
                                audioService: widget.audioService,
                                libraryCache: widget.libraryCache,
                                isSelected: isSelected,
                                onTap: () => _handleSelectArtist(artist),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}
