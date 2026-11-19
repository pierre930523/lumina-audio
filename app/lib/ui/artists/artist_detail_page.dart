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
import '../theme/lumina_tokens.dart';

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
  static const _accentBlue = LuminaTokens.accentBlue;

  late final ScrollController _scrollController;
  String _displayName = '';
  List<CanonicalAlbumSummary> _albums = const [];
  List<TrackInfo> _tracks = const [];
  CanonicalAlbumSummary? _representativeAlbum;
  TrackInfo? _representativeTrack;
  bool _preferTrackForAvatar = false;
  bool _loading = true;
  bool _showAllTracks = false;
  int _loadToken = 0;

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
    _scrollController = ScrollController(
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
    _albums = entry.albums;
    _tracks = entry.tracks;
    _representativeAlbum = entry.representativeAlbum;
    _representativeTrack = entry.representativeTrack;
    _notifyTitleChanged();
  }

  void _primeFromSyncAndRefresh() {
    final token = ++_loadToken;
    final cache = widget.libraryCache;
    final normKey = _lookupKey;

    // 1. Synchronous lookup from LibraryIndexCache for frame-0 zero-flash render.
    final cachedEntry = cache?.getArtistSync(normKey);
    if (cachedEntry != null) {
      _applyEntry(cachedEntry);
      _loading = false;
      if (widget.useAlbumArtworkAsAvatar) {
        _probeAvatarArtworkPreference(token);
      }
      if (cache != null && cache.isPrimed) {
        return;
      }
    } else {
      // Fallback frame-0 seed from in-memory audioService.queue tracks.
      final queueMatches = widget.audioService.queue.where((t) {
        final tk = LibraryIndexCache.normalizeArtistKey(t.artist);
        final aak = LibraryIndexCache.normalizeArtistKey(
          t.effectiveAlbumArtist,
        );
        return tk == normKey || aak == normKey;
      }).toList();

      if (queueMatches.isNotEmpty) {
        _tracks = List<TrackInfo>.unmodifiable(queueMatches);
        _representativeTrack = _pickRepTrack(queueMatches);
        _loading = false;
      } else {
        _loading = true;
      }

      if (widget.useAlbumArtworkAsAvatar) {
        _probeAvatarArtworkPreference(token);
      }
    }

    // 2. Silent asynchronous refresh when cache is cold or unprimed.
    _refreshSilently(token, normKey);
  }

  Future<void> _refreshSilently(int token, String normKey) async {
    final cache = widget.libraryCache;
    if (cache != null) {
      try {
        final entry = await cache.ensureArtistLoaded(
          widget.audioService,
          normKey,
        );
        if (!mounted || token != _loadToken) return;
        if (entry != null) {
          if (!_isEntryUnchanged(entry)) {
            setState(() {
              _applyEntry(entry);
              _loading = false;
            });
          }
        } else if (_loading) {
          setState(() {
            _loading = false;
          });
        }
        if (widget.useAlbumArtworkAsAvatar) {
          _probeAvatarArtworkPreference(token);
        }
        return;
      } catch (_) {
        // Fall through to direct service load.
      }
    }

    try {
      final allTracks = widget.audioService.queue;
      final filteredTracks = allTracks.where((t) {
        final tk = LibraryIndexCache.normalizeArtistKey(t.artist);
        final aak = LibraryIndexCache.normalizeArtistKey(
          t.effectiveAlbumArtist,
        );
        return tk == normKey || aak == normKey;
      }).toList();

      final allAlbums = await widget.audioService.getAlbums(limit: 500);
      final filteredAlbums = allAlbums.where((a) {
        final ak = LibraryIndexCache.normalizeArtistKey(a.artist);
        final aak = LibraryIndexCache.normalizeArtistKey(a.albumArtist ?? '');
        return ak == normKey || aak == normKey;
      }).toList()
        ..sort(LibraryIndexCache.compareAlbumsNewestFirst);

      if (!mounted || token != _loadToken) return;
      final nextTracks = List<TrackInfo>.unmodifiable(filteredTracks);
      final nextAlbums = List<CanonicalAlbumSummary>.unmodifiable(filteredAlbums);
      final unchanged = !_loading &&
          listEquals(nextTracks, _tracks) &&
          listEquals(nextAlbums, _albums);
      if (!unchanged) {
        setState(() {
          _tracks = nextTracks;
          _albums = nextAlbums;
          _representativeAlbum = _pickRepAlbum(filteredAlbums);
          _representativeTrack = _pickRepTrack(filteredTracks);
          _loading = false;
        });
      }
      if (widget.useAlbumArtworkAsAvatar) {
        _probeAvatarArtworkPreference(token);
      }
    } catch (_) {
      if (!mounted || token != _loadToken) return;
      if (_loading) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _probeAvatarArtworkPreference(int token) {
    if (!widget.useAlbumArtworkAsAvatar) return;
    final alb = _representativeAlbum;
    final trk = _representativeTrack;
    if (alb == null && trk == null) return;

    final cache = widget.libraryCache;
    if (alb != null &&
        ((alb.coverUrl != null && alb.coverUrl!.isNotEmpty) ||
            cache?.getArtworkPathSync(alb.id) != null)) {
      _preferTrackForAvatar = false;
      return;
    }
    if (trk != null &&
        ((trk.coverUrl != null && trk.coverUrl!.isNotEmpty) ||
            (trk.albumArtUrl != null && trk.albumArtUrl!.isNotEmpty) ||
            cache?.getArtworkPathSync(trk.id) != null)) {
      _preferTrackForAvatar = true;
      return;
    }

    // If neither has synchronous metadata URL, check if track has artwork when album does not.
    if (alb != null && trk != null) {
      () async {
        if (cache != null) {
          final albPath = await cache.resolveArtworkPath(
            widget.audioService,
            alb.id,
            maxDim: 0,
          );
          if (!mounted || token != _loadToken || albPath != null) return;
          final trkPath = await cache.resolveArtworkPath(
            widget.audioService,
            trk.id,
            path: trk.filePath,
            maxDim: 0,
          );
          if (!mounted || token != _loadToken) return;
          if (trkPath != null && trkPath.isNotEmpty && !_preferTrackForAvatar) {
            setState(() {
              _preferTrackForAvatar = true;
            });
          }
          return;
        }

        await Future<void>.microtask(() {});
        if (widget.audioService.isNativeBound) {
          await Future<void>.delayed(const Duration(milliseconds: 8));
        }
        if (!mounted || token != _loadToken) return;
        final albRes = await widget.audioService.getArtwork(alb.id, maxDim: 0);
        if (!mounted || token != _loadToken) return;
        final albFound =
            albRes != null &&
            albRes['found'] == true &&
            (albRes['cache_path']?.toString().isNotEmpty ?? false);
        if (albFound) return;

        final trkRes = await widget.audioService.getArtwork(
          trk.id,
          path: trk.filePath,
          maxDim: 0,
        );
        if (!mounted || token != _loadToken) return;
        final trkFound =
            trkRes != null &&
            trkRes['found'] == true &&
            (trkRes['cache_path']?.toString().isNotEmpty ?? false);
        if (trkFound && !_preferTrackForAvatar) {
          setState(() {
            _preferTrackForAvatar = true;
          });
        }
      }().catchError((_) {});
    }
  }

  CanonicalAlbumSummary? _pickRepAlbum(List<CanonicalAlbumSummary> albums) {
    if (albums.isEmpty) return null;
    for (final a in albums) {
      if ((a.coverUrl != null && a.coverUrl!.isNotEmpty) ||
          widget.libraryCache?.getArtworkPathSync(a.id) != null) {
        return a;
      }
    }
    return albums.first;
  }

  TrackInfo? _pickRepTrack(List<TrackInfo> tracks) {
    if (tracks.isEmpty) return null;
    for (final t in tracks) {
      if ((t.coverUrl != null && t.coverUrl!.isNotEmpty) ||
          (t.albumArtUrl != null && t.albumArtUrl!.isNotEmpty) ||
          widget.libraryCache?.getArtworkPathSync(t.id) != null) {
        return t;
      }
    }
    return tracks.first;
  }

  CanonicalAlbumSummary? _resolveAlbumForTrack(TrackInfo track) {
    final fromCache = widget.libraryCache?.resolveAlbumForTrack(track);
    if (fromCache != null) return fromCache;

    final trackAlbumTitle = track.album.trim().toLowerCase();
    if (trackAlbumTitle.isEmpty) return null;

    for (final album in _albums) {
      if (album.title.trim().toLowerCase() == trackAlbumTitle) {
        return album;
      }
    }
    for (final album in _albums) {
      final albTitle = album.title.trim().toLowerCase();
      if (albTitle.isNotEmpty &&
          (trackAlbumTitle.startsWith(albTitle) ||
              albTitle.startsWith(trackAlbumTitle))) {
        return album;
      }
    }
    return null;
  }

  Future<void> _playAll() async {
    if (_tracks.isNotEmpty) {
      await widget.audioService.play(track: _tracks.first);
      return;
    }
    if (_albums.isNotEmpty) {
      final firstAlbum = _albums.first;
      final detail = widget.libraryCache != null
          ? await widget.libraryCache!.loadAlbumDetail(
              widget.audioService,
              firstAlbum.id,
            )
          : await widget.audioService.getAlbumDetail(firstAlbum.id);
      if (detail != null &&
          detail.versions.isNotEmpty &&
          detail.versions.first.tracks.isNotEmpty) {
        final ver = detail.versions.first;
        final vt = ver.tracks.first;
        await widget.audioService.play(
          track: TrackInfo(
            id: vt.id,
            title: vt.title,
            artist: detail.artistName,
            album: detail.title,
            duration: Duration(milliseconds: vt.durationMs),
            format: AudioFormat(
              codec: AudioCodec.fromString(vt.codec),
              sampleRateHz: vt.sampleRateHz,
              bitDepth: vt.bitDepth,
              channels: 2,
              isDsd: ver.isDsd,
            ),
            providerName: ver.provider,
            coverUrl: detail.coverUrl,
          ),
        );
      }
    }
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
                          color: _accentBlue,
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
            ));
          },
        );
      },
    );
  }

  Widget _buildHeroSection({required bool isWide, required double maxWidth}) {
    final avatarSize = isWide ? 156.0 : 116.0;
    final avatarWidget = _buildCircularAvatar(size: avatarSize);
    final infoColumn = _buildHeroInfo(isWide: isWide);

    return Container(
      padding: EdgeInsets.all(isWide ? 24 : 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF1F222D),
            Color(0xFF171920),
          ],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.07),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.onBack != null && widget.showInlineBackButton)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: InkWell(
                key: const Key('artist_detail_back_btn'),
                onTap: widget.onBack,
                borderRadius: BorderRadius.circular(8),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.arrow_back_rounded,
                        size: 16,
                        color: Colors.white70,
                      ),
                      SizedBox(width: 6),
                      Text(
                        '返回',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (isWide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                avatarWidget,
                const SizedBox(width: 28),
                Expanded(child: infoColumn),
              ],
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                avatarWidget,
                const SizedBox(width: 16),
                Expanded(child: infoColumn),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildCircularAvatar({required double size}) {
    if (!widget.useAlbumArtworkAsAvatar) {
      return SizedBox(
        key: const Key('artist_hero_avatar'),
        width: size,
        height: size,
        child: _ArtistGradientAvatar(
          key: const Key('artist_hero_gradient_fallback'),
          artistName: _displayName,
          size: size,
        ),
      );
    }

    final useTrack = _preferTrackForAvatar || _representativeAlbum == null;
    final avatarTrack = useTrack ? _representativeTrack : null;
    final avatarAlbum = useTrack ? null : _representativeAlbum;

    return SizedBox(
      key: const Key('artist_hero_avatar'),
      width: size,
      height: size,
      child: AlbumArtworkView(
        track: avatarTrack,
        album: avatarAlbum,
        size: size,
        circular: true,
        fullResolution: true,
        audioService: widget.audioService,
        libraryCache: widget.libraryCache,
        placeholder: _ArtistGradientAvatar(
          key: const Key('artist_hero_gradient_fallback'),
          artistName: _displayName,
          size: size,
        ),
      ),
    );
  }

  Widget _buildHeroInfo({required bool isWide}) {
    final canPlayAll = _tracks.isNotEmpty || _albums.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: _accentBlue.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: _accentBlue.withValues(alpha: 0.3)),
          ),
          child: const Text(
            '藝術家',
            style: TextStyle(
              color: _accentBlue,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ),
        const SizedBox(height: 10),
        KeyedSubtree(
          key: const Key('artist_hero_name'),
          child: Text(
            _displayName,
            key: const Key('artist_hero_title'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: isWide ? 32 : 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              height: 1.15,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '全部曲目 ${_tracks.length} 首',
              key: const Key('artist_hero_track_stats'),
              style: const TextStyle(
                color: LuminaTokens.textSecondary,
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (_albums.isNotEmpty)
              Text(
                '· 主專輯 ${_albums.length} 張',
                style: const TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 13,
                ),
              ),
          ],
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              key: const Key('btn_artist_play_all'),
              onPressed: canPlayAll ? _playAll : null,
              icon: const Icon(Icons.play_arrow_rounded, size: 20),
              label: const Text(
                '播放全部',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: _accentBlue,
                foregroundColor: LuminaTokens.onAccentDark,
                disabledBackgroundColor: Colors.white12,
                disabledForegroundColor: LuminaTokens.textDisabled,
                shape: const StadiumBorder(),
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 12,
                ),
              ),
            ),
            if (widget.onOpenCredits != null)
              OutlinedButton.icon(
                key: const Key('btn_artist_open_credits'),
                onPressed: widget.onOpenCredits,
                icon: const Icon(Icons.account_tree_rounded, size: 17),
                label: const Text(
                  '製作人員關係圖',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: LuminaTokens.textPrimary,
                  side: const BorderSide(color: LuminaTokens.borderControl),
                  shape: const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 12,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildTracksHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text(
          '曲目',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        InkWell(
          key: const Key('btn_artist_toggle_all_tracks'),
          borderRadius: BorderRadius.circular(999),
          onTap: () {
            setState(() {
              _showAllTracks = !_showAllTracks;
            });
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _showAllTracks
                  ? _accentBlue.withValues(alpha: 0.16)
                  : Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: _showAllTracks
                    ? _accentBlue.withValues(alpha: 0.55)
                    : LuminaTokens.borderControl,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '全部 ${_tracks.length} 首',
                  style: TextStyle(
                    color: _showAllTracks
                        ? _accentBlue
                        : LuminaTokens.textSecondary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  _showAllTracks
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 16,
                  color: _showAllTracks
                      ? _accentBlue
                      : LuminaTokens.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAlbumsHeader() {
    return Row(
      children: [
        Expanded(
          child: Text(
            '主專輯 (${_albums.length})',
            key: const Key('artist_albums_section_header'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Refined Circular Gradient Avatar Fallback ────────────────────────────────

class _ArtistGradientAvatar extends StatelessWidget {
  final String artistName;
  final double size;

  const _ArtistGradientAvatar({
    super.key,
    required this.artistName,
    required this.size,
  });

  static const List<List<Color>> _palettes = [
    [Color(0xFF312E81), Color(0xFF4F46E5), Color(0xFF0F172A)],
    [Color(0xFF1E3A8A), Color(0xFF2563EB), Color(0xFF0F172A)],
    [Color(0xFF4C1D95), Color(0xFF7C3AED), Color(0xFF111827)],
    [Color(0xFF134E4A), Color(0xFF0D9488), Color(0xFF0F172A)],
  ];

  @override
  Widget build(BuildContext context) {
    final trimmed = artistName.trim().isNotEmpty ? artistName.trim() : '?';
    final hash = trimmed.codeUnits.fold<int>(0, (acc, c) => acc + c);
    final palette = _palettes[hash % _palettes.length];
    final fontSize = (size * 0.16).clamp(13.0, 24.0).toDouble();

    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.symmetric(horizontal: size * 0.12),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: palette,
        ),
      ),
      child: Center(
        child: Text(
          trimmed,
          key: const Key('artist_hero_avatar_text'),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.94),
            fontSize: fontSize,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.3,
            height: 1.2,
          ),
        ),
      ),
    );
  }
}

// ─── Hover-Isolated Artist Track Row ──────────────────────────────────────────

class _ArtistTrackRow extends StatefulWidget {
  final int index;
  final TrackInfo track;
  final CanonicalAlbumSummary? resolvedAlbum;
  final bool isPlaying;
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final VoidCallback onPlay;
  final VoidCallback? onOpenAlbumDetail;

  const _ArtistTrackRow({
    super.key,
    required this.index,
    required this.track,
    required this.resolvedAlbum,
    required this.isPlaying,
    required this.audioService,
    required this.libraryCache,
    required this.onPlay,
    this.onOpenAlbumDetail,
  });

  @override
  State<_ArtistTrackRow> createState() => _ArtistTrackRowState();
}

class _ArtistTrackRowState extends State<_ArtistTrackRow> {
  static const _accentBlue = LuminaTokens.accentBlue;

  bool _rowHovered = false;
  bool _albumHovered = false;

  @override
  Widget build(BuildContext context) {
    final isPlaying = widget.isPlaying;
    final canOpenAlbum = widget.onOpenAlbumDetail != null;
    final albumTitle = widget.track.album.trim().isNotEmpty
        ? widget.track.album.trim()
        : (widget.resolvedAlbum?.title ?? '');

    final bgColor = isPlaying
        ? _accentBlue.withValues(alpha: 0.14)
        : (_rowHovered
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.transparent);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_rowHovered) setState(() => _rowHovered = true);
      },
      onExit: (_) {
        if (_rowHovered || _albumHovered) {
          setState(() {
            _rowHovered = false;
            _albumHovered = false;
          });
        }
      },
      child: Semantics(
        button: true,
        label: widget.track.title,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPlay,
          child: AnimatedContainer(
            duration: LuminaTokens.focusDuration,
            curve: LuminaTokens.motionCurve,
            margin: const EdgeInsets.symmetric(vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isPlaying
                    ? _accentBlue.withValues(alpha: 0.42)
                    : Colors.transparent,
              ),
            ),
            child: LayoutBuilder(
              builder: (context, rowConstraints) {
                final showAlbumColumn =
                    rowConstraints.maxWidth >= 340 && albumTitle.isNotEmpty;

                return Row(
                  children: [
                    // Leading index / playing indicator (turns into play button on hover with smooth 30ms transition)
                    SizedBox(
                      width: 24,
                      child: Center(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 30),
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                            opacity: animation,
                            child: child,
                          ),
                          child: isPlaying
                              ? const Icon(
                                  Icons.equalizer_rounded,
                                  key: Key('artist_track_playing_indicator'),
                                  size: 16,
                                  color: _accentBlue,
                                )
                              : (_rowHovered
                                  ? const Icon(
                                      Icons.play_arrow_rounded,
                                      key: Key('artist_track_hover_play'),
                                      size: 16,
                                      color: _accentBlue,
                                    )
                                  : Text(
                                      '${widget.index + 1}',
                                      key: Key('artist_track_num_${widget.index}'),
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: _rowHovered
                                            ? LuminaTokens.textSecondary
                                            : LuminaTokens.textMuted,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    )),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Small square album thumbnail
                    AlbumArtworkView(
                      track: widget.track,
                      album: widget.resolvedAlbum,
                      size: 40,
                      fullResolution: false,
                      audioService: widget.audioService,
                      libraryCache: widget.libraryCache,
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: const [],
                    ),
                    const SizedBox(width: 12),

                    // Track title + small artist subtitle
                    Expanded(
                      flex: 5,
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
                                  : FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.track.artist,
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

                    // Middle column: Clickable Album Name
                    if (showAlbumColumn) ...[
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 4,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: MouseRegion(
                            cursor: canOpenAlbum
                                ? SystemMouseCursors.click
                                : SystemMouseCursors.basic,
                            onEnter: (_) {
                              if (canOpenAlbum && !_albumHovered) {
                                setState(() => _albumHovered = true);
                              }
                            },
                            onExit: (_) {
                              if (_albumHovered) {
                                setState(() => _albumHovered = false);
                              }
                            },
                            child: GestureDetector(
                              key: Key('artist_track_album_${widget.index}'),
                              behavior: HitTestBehavior.opaque,
                              onTap: canOpenAlbum
                                  ? widget.onOpenAlbumDetail
                                  : null,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                                child: Text(
                                  albumTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _albumHovered
                                        ? _accentBlue
                                        : LuminaTokens.textSecondary,
                                    fontSize: 12.5,
                                    fontWeight: _albumHovered
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                    decoration: _albumHovered
                                        ? TextDecoration.underline
                                        : TextDecoration.none,
                                    decorationColor: _accentBlue,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],

                    const SizedBox(width: 12),

                    // Right side: Track duration + action icon
                    Text(
                      _formatDuration(widget.track.duration),
                      style: const TextStyle(
                        color: LuminaTokens.textMuted,
                        fontSize: 12,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      key: Key('artist_track_play_${widget.index}'),
                      onPressed: widget.onPlay,
                      tooltip: '播放曲目',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      icon: Icon(
                        isPlaying
                            ? Icons.volume_up_rounded
                            : Icons.play_arrow_rounded,
                        size: 17,
                        color: isPlaying || _rowHovered
                            ? _accentBlue
                            : LuminaTokens.textMuted,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

// ─── Hover-Isolated Artist Album Card ─────────────────────────────────────────

class _ArtistAlbumCard extends StatefulWidget {
  final CanonicalAlbumSummary album;
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final VoidCallback? onTap;

  const _ArtistAlbumCard({
    super.key,
    required this.album,
    required this.audioService,
    required this.libraryCache,
    this.onTap,
  });

  @override
  State<_ArtistAlbumCard> createState() => _ArtistAlbumCardState();
}

class _ArtistAlbumCardState extends State<_ArtistAlbumCard> {
  static const _accentBlue = LuminaTokens.accentBlue;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final album = widget.album;

    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: Semantics(
        button: widget.onTap != null,
        label: album.title,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: LuminaTokens.focusDuration,
            curve: LuminaTokens.motionCurve,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _hovered ? LuminaTokens.cardHoverBg : LuminaTokens.cardBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _hovered
                    ? _accentBlue.withValues(alpha: 0.65)
                    : LuminaTokens.borderSubtle,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 1.0,
                      child: LayoutBuilder(
                        builder: (context, box) {
                          final side = math.min(box.maxWidth, box.maxHeight);
                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              AlbumArtworkView(
                                album: album,
                                size: side.isFinite && side > 0 ? side : 160,
                                fullResolution: false,
                                audioService: widget.audioService,
                                libraryCache: widget.libraryCache,
                                borderRadius: BorderRadius.circular(8),
                                boxShadow: const [],
                              ),
                              if (_hovered)
                                Positioned(
                                  right: 8,
                                  bottom: 8,
                                  child: Container(
                                    width: 34,
                                    height: 34,
                                    decoration: const BoxDecoration(
                                      color: _accentBlue,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Color(0x66000000),
                                          blurRadius: 10,
                                          offset: Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.play_arrow_rounded,
                                      size: 20,
                                      color: LuminaTokens.onAccentDark,
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (album.year != null) ...[
                  Text(
                    '${album.year}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: LuminaTokens.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 2),
                ],
                Text(
                  album.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _hovered ? _accentBlue : LuminaTokens.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  album.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.textMuted,
                    fontSize: 11.5,
                    height: 1.15,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
