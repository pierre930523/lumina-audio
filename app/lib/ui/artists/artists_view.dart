import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../theme/lumina_tokens.dart';
import 'artist_detail_page.dart';

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
  static const _cardBg = LuminaTokens.cardBg;
  static const _dividerColor = LuminaTokens.borderControl;
  static const _accentBlue = LuminaTokens.accentBlue;

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

    // Immediate frame-0 fallback from queue tracks if available.
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
      entries.add(
        ArtistIndexEntry(
          key: key,
          displayName: displayNames[key] ?? key,
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
    // Local fallback to standalone ArtistDetailPage when onOpenArtist is not wired
    // (e.g. standalone widget tests instantiating ArtistsView directly).
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
              fillColor: _cardBg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                borderSide: const BorderSide(color: _dividerColor),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                borderSide: const BorderSide(color: _dividerColor),
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
                    color: _accentBlue,
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
              : CustomScrollView(
                  key: const Key('artists_list_view'),
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
      ],
    );
  }
}

// ─── Hover-Isolated Artist List Tile ──────────────────────────────────────────

class _ArtistTile extends StatefulWidget {
  final ArtistIndexEntry artist;
  final bool isSelected;
  final VoidCallback onTap;

  const _ArtistTile({
    super.key,
    required this.artist,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_ArtistTile> createState() => _ArtistTileState();
}

class _ArtistTileState extends State<_ArtistTile> {
  static const _accentBlue = LuminaTokens.accentBlue;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final artist = widget.artist;
    final isSelected = widget.isSelected;
    final bgColor = isSelected
        ? _accentBlue.withValues(alpha: 0.14)
        : (_hovered
              ? LuminaTokens.cardHoverBg.withValues(alpha: 0.75)
              : Colors.transparent);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: Semantics(
        button: true,
        selected: isSelected,
        label: artist.displayName,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: LuminaTokens.focusDuration,
            curve: LuminaTokens.motionCurve,
            margin: const EdgeInsets.symmetric(vertical: 2),
            padding: const EdgeInsets.symmetric(
              horizontal: LuminaTokens.spaceSm,
              vertical: LuminaTokens.spaceSm,
            ),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isSelected
                    ? _accentBlue.withValues(alpha: 0.55)
                    : (_hovered
                          ? LuminaTokens.borderControl
                          : Colors.transparent),
              ),
            ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: isSelected || _hovered
                        ? [const Color(0xFF3730A3), _accentBlue]
                        : [const Color(0xFF282B34), const Color(0xFF1E2028)],
                  ),
                ),
                child: Center(
                  child: Text(
                    artist.displayName.isNotEmpty
                        ? artist.displayName[0].toUpperCase()
                        : '?',
                    style: TextStyle(
                      color: isSelected || _hovered
                          ? Colors.white
                          : Colors.white70,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      artist.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isSelected || _hovered
                            ? _accentBlue
                            : Colors.white,
                        fontSize: 13.5,
                        fontWeight: isSelected || _hovered
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _subtitle(artist),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.textMuted,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: isSelected || _hovered
                    ? _accentBlue
                    : LuminaTokens.textMuted,
              ),
            ],
          ),
        ),
      ),
    ),
  );
  }

  String _subtitle(ArtistIndexEntry a) {
    final parts = <String>[];
    if (a.albumCount > 0) parts.add('${a.albumCount} 張專輯');
    if (a.trackCount > 0) parts.add('${a.trackCount} 首曲目');
    return parts.isEmpty ? '暫無資料' : parts.join(' · ');
  }
}
