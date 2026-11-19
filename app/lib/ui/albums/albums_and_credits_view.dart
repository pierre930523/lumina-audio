import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../models/audio_format.dart';
import '../../models/playback_state.dart';
import '../../models/studio_models.dart';
import '../../services/album_layout_settings_controller.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../theme/lumina_tokens.dart';
import 'album_collection_card.dart';
import 'album_detail_page.dart';
import 'album_layout_popover.dart';

class AlbumsAndCreditsView extends StatefulWidget {
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final AlbumLayoutSettingsController? layoutController;
  final bool startInCreditsMode;
  final void Function(String albumId)? onOpenAlbumDetail;
  final void Function(String artistName)? onOpenArtist;
  final String? initialArtistId;
  final double initialScrollOffset;
  final ValueChanged<double>? onScrollOffsetChanged;

  const AlbumsAndCreditsView({
    super.key,
    this.onOpenAlbumDetail,
    this.onOpenArtist,
    this.initialArtistId,
    required this.audioService,
    this.libraryCache,
    this.layoutController,
    this.startInCreditsMode = false,
    this.initialScrollOffset = 0.0,
    this.onScrollOffsetChanged,
  });

  @override
  State<AlbumsAndCreditsView> createState() => _AlbumsAndCreditsViewState();
}

class _AlbumsAndCreditsViewState extends State<AlbumsAndCreditsView> {
  List<CanonicalAlbumSummary> _albums = const [];
  List<AlbumCreditInfo> _defaultCredits = const [];
  String? _defaultArtistName;
  ArtistDetailInfo? _selectedArtist;
  late bool _showCreditsGraph;
  String? _statusMessage;
  bool _loading = true;
  int _coverRevision = 0;
  late final ScrollController _scrollController;
  late AlbumLayoutSettingsController _effectiveLayoutController;
  late bool _ownsLayoutController;

  @override
  void initState() {
    super.initState();
    _ownsLayoutController = widget.layoutController == null;
    _effectiveLayoutController =
        widget.layoutController ?? (AlbumLayoutSettingsController()..load());
    _showCreditsGraph = widget.startInCreditsMode;
    _scrollController = ScrollController(
      initialScrollOffset: widget.initialScrollOffset,
    )..addListener(_handleScroll);
    if (!widget.startInCreditsMode &&
        widget.libraryCache != null &&
        widget.libraryCache!.albums.isNotEmpty) {
      _albums = widget.libraryCache!.albums;
      _loading = false;
    }
    _loadData();
  }

  @override
  void dispose() {
    if (_ownsLayoutController) {
      _effectiveLayoutController.dispose();
    }
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (_scrollController.hasClients) {
      widget.onScrollOffsetChanged?.call(_scrollController.offset);
    }
  }

  @override
  void didUpdateWidget(covariant AlbumsAndCreditsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layoutController != widget.layoutController) {
      if (_ownsLayoutController) {
        _effectiveLayoutController.dispose();
      }
      _ownsLayoutController = widget.layoutController == null;
      _effectiveLayoutController =
          widget.layoutController ?? (AlbumLayoutSettingsController()..load());
    }
    if (oldWidget.startInCreditsMode != widget.startInCreditsMode) {
      setState(() {
        _showCreditsGraph = widget.startInCreditsMode;
      });
    }
  }

  Future<void> _loadData() async {
    final albums = await widget.audioService.getAlbums(limit: 500);
    CanonicalAlbumDetail? detail;
    ArtistDetailInfo? artist;
    if (widget.initialArtistId != null) {
      artist = await widget.audioService.getArtistDetail(widget.initialArtistId!);
    }
    if (albums.isNotEmpty) {
      detail = await widget.audioService.getAlbumDetail(albums.first.id);
      if (artist == null && detail != null && detail.credits.isNotEmpty) {
        artist = await widget.audioService.getArtistDetail(
          detail.credits.first.artistId,
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _albums = albums;
      _defaultCredits = detail?.credits ?? const [];
      _defaultArtistName = detail?.artistName;
      _selectedArtist ??= artist;
      _loading = false;
    });
  }

  Future<void> _openAlbum(String albumId) async {
    if (widget.onOpenAlbumDetail != null) {
      widget.onOpenAlbumDetail!(albumId);
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (ctx) => Scaffold(
          backgroundColor: const Color(0xFF141519),
          body: SafeArea(
            child: AlbumDetailPage(
              albumId: albumId,
              audioService: widget.audioService,
              onBack: () => Navigator.of(ctx).pop(),
              onOpenArtist: widget.onOpenArtist,
              onOpenArtistCredits: (artistId) {
                Navigator.of(ctx).pop();
                _openArtistGraph(artistId);
              },
            ),
          ),
        ),
      ),
    );
    if (mounted) {
      setState(() => _coverRevision++);
    }
  }

  Future<void> _openArtistGraph(String artistId) async {
    final detail = await widget.audioService.getArtistDetail(artistId);
    if (!mounted || detail == null) return;
    setState(() {
      _selectedArtist = detail;
      _showCreditsGraph = true;
    });
  }

  Future<void> _openArtistForAlbum(CanonicalAlbumSummary album) async {
    if (widget.onOpenArtist != null) {
      widget.onOpenArtist!(album.artist);
      return;
    }
    final detail =
        widget.libraryCache?.albumDetailsById[album.id] ??
        await widget.audioService.getAlbumDetail(album.id);
    if (!mounted) return;
    final firstArtistId = detail?.credits.firstOrNull?.artistId;
    if (firstArtistId != null && firstArtistId.isNotEmpty) {
      await _openArtistGraph(firstArtistId);
    }
  }

  TrackInfo _toTrackInfo(
    CanonicalAlbumDetail detail,
    AlbumVersionInfo version,
    AlbumVersionTrackInfo vTrack,
  ) {
    final ext = vTrack.externalTrackId;
    final hasUri =
        ext.contains('/') ||
        ext.contains('\\') ||
        ext.startsWith('http://') ||
        ext.startsWith('https://');
    return TrackInfo(
      id: vTrack.id,
      title: vTrack.title,
      artist: detail.artistName,
      album: detail.title,
      duration: Duration(milliseconds: vTrack.durationMs),
      format: AudioFormat(
        codec: AudioCodec.fromString(vTrack.codec),
        sampleRateHz: vTrack.sampleRateHz,
        bitDepth: vTrack.bitDepth,
        channels: 2,
        isDsd: version.isDsd || vTrack.isDsd,
      ),
      providerName: version.provider,
      trackNumber: vTrack.trackNumber,
      discNumber: vTrack.discNumber,
      coverUrl: detail.coverUrl,
      filePath: hasUri ? ext : null,
    );
  }

  Future<List<TrackInfo>> _resolveAlbumTracks(
    CanonicalAlbumSummary album,
  ) async {
    final q = widget.audioService.queue;
    final detail =
        widget.libraryCache?.albumDetailsById[album.id] ??
        await widget.audioService.getAlbumDetail(album.id);
    if (detail != null && detail.versions.isNotEmpty) {
      final ver = detail.versions.first;
      final ordered = ver.orderedTrackEntries;
      if (ordered.isNotEmpty) {
        return ordered.map((entry) {
          final vTrack = entry.track;
          final existing = q.where((t) => t.id == vTrack.id).firstOrNull;
          return existing ?? _toTrackInfo(detail, ver, vTrack);
        }).toList();
      }
    }
    final lowerTitle = album.title.toLowerCase();
    return q
        .where(
          (t) =>
              t.album == album.title ||
              t.album.toLowerCase().startsWith(lowerTitle),
        )
        .toList();
  }

  Future<void> _playAlbum(CanonicalAlbumSummary album) async {
    final tracks = await _resolveAlbumTracks(album);
    if (!mounted) return;
    if (tracks.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('音樂庫中找不到此專輯的可播放曲目')),
      );
      return;
    }
    try {
      final q = widget.audioService.queue;
      for (final track in tracks) {
        if (!q.any((existing) => existing.id == track.id)) {
          q.add(track);
        }
      }
    } on UnsupportedError catch (_) {
      // Unmodifiable mock queues do not support in-place append.
    } catch (_) {}
    await widget.audioService.play(track: tracks.first);
  }

  Future<void> _addAlbumToQueue(CanonicalAlbumSummary album) async {
    final tracks = await _resolveAlbumTracks(album);
    if (!mounted) return;
    var added = 0;
    try {
      final q = widget.audioService.queue;
      for (final track in tracks) {
        if (!q.any((existing) => existing.id == track.id)) {
          q.add(track);
          added++;
        }
      }
    } on UnsupportedError catch (_) {
      // Unmodifiable mock queues do not support in-place append.
    } catch (_) {}
    final count = added > 0 ? added : tracks.length;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(count > 0 ? '已將 $count 首曲目加入播放佇列' : '已將專輯加入播放佇列'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _deduplicate() async {
    final merged = await widget.audioService.deduplicateLibrary();
    await _loadData();
    if (!mounted) return;
    setState(() {
      _statusMessage = '已合併 $merged 張重複專輯';
    });
  }

  Future<void> _enrichCredits() async {
    final report = await widget.audioService.enrichLibraryCredits();
    await _loadData();
    if (!mounted) return;
    setState(() {
      _statusMessage =
          '已補全 ${report['albums_enriched'] ?? 0} 張專輯，新增 ${report['credits_added'] ?? 0} 筆製作人員紀錄';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return LayoutBuilder(
      builder: (context, outerConstraints) {
        final availW = math
            .max(120.0, outerConstraints.maxWidth - LuminaTokens.spaceLg * 2)
            .toDouble();

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LuminaTokens.spaceLg,
                vertical: LuminaTokens.spaceXs,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: LuminaTokens.spaceXs,
                      runSpacing: LuminaTokens.spaceXs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ChoiceChip(
                          label: const Text('專輯與發行版本'),
                          selected: !_showCreditsGraph,
                          side: BorderSide(
                            color: !_showCreditsGraph
                                ? LuminaTokens.accentBlue
                                : LuminaTokens.borderControl,
                          ),
                          onSelected: (_) =>
                              setState(() => _showCreditsGraph = false),
                        ),
                        ChoiceChip(
                          label: const Text('製作人員關係圖'),
                          selected: _showCreditsGraph,
                          side: BorderSide(
                            color: _showCreditsGraph
                                ? LuminaTokens.accentBlue
                                : LuminaTokens.borderControl,
                          ),
                          onSelected: (_) =>
                              setState(() => _showCreditsGraph = true),
                        ),
                        OutlinedButton.icon(
                          key: const Key('btn_deduplicate_albums'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: LuminaTokens.textPrimary,
                            side: const BorderSide(
                              color: LuminaTokens.borderControl,
                            ),
                          ),
                          onPressed: _deduplicate,
                          icon: const Icon(Icons.merge_type_rounded, size: 16),
                          label: const Text('合併重複專輯'),
                        ),
                        OutlinedButton.icon(
                          key: const Key('btn_enrich_credits'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: LuminaTokens.textPrimary,
                            side: const BorderSide(
                              color: LuminaTokens.borderControl,
                            ),
                          ),
                          onPressed: _enrichCredits,
                          icon: const Icon(
                            Icons.auto_awesome_rounded,
                            size: 16,
                          ),
                          label: const Text('補全製作人員'),
                        ),
                        if (_statusMessage != null)
                          Text(
                            _statusMessage!,
                            style: const TextStyle(
                              color: LuminaTokens.statusSuccess,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (!_showCreditsGraph) ...[
                    const SizedBox(width: LuminaTokens.spaceXs),
                    AlbumLayoutSettingsButton(
                      controller: _effectiveLayoutController,
                      availableWidth: availW,
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: _showCreditsGraph
                  ? _buildCreditsGraph()
                  : _buildAlbumsCollection(),
            ),
          ],
        );
      },
    );
  }

  Widget _buildAlbumsCollection() {
    if (_albums.isEmpty) {
      return const Center(
        child: Text(
          '尚未掃描任何音樂專輯，請至設定掃描音樂資料夾。',
          style: TextStyle(color: LuminaTokens.textSecondary, fontSize: 13.5),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final availW = math
            .max(120.0, constraints.maxWidth - LuminaTokens.spaceLg * 2)
            .toDouble();

        return ListenableBuilder(
          listenable: _effectiveLayoutController,
          builder: (context, _) {
            final viewMode = _effectiveLayoutController.viewMode;
            final showCardContainer =
                _effectiveLayoutController.showCardContainer;

            if (viewMode == AlbumViewMode.list) {
              return ListView.separated(
                key: const Key('album_list_view'),
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(
                  LuminaTokens.spaceLg,
                  LuminaTokens.spaceMd,
                  LuminaTokens.spaceLg,
                  LuminaTokens.bottomScrollClearance,
                ),
                itemCount: _albums.length,
                separatorBuilder: (context, index) => showCardContainer
                    ? const SizedBox(height: 8)
                    : Divider(
                        height: 1,
                        thickness: 1,
                        color: LuminaTokens.borderSubtle.withValues(alpha: 0.45),
                      ),
                itemBuilder: (context, index) {
                  final album = _albums[index];
                  return AlbumCollectionListTile(
                    key: Key('album_card_${album.id}'),
                    album: album,
                    coverRevision: _coverRevision,
                    audioService: widget.audioService,
                    libraryCache: widget.libraryCache,
                    showCardContainer: showCardContainer,
                    onOpenAlbumDetail: () => _openAlbum(album.id),
                    onPlayAlbum: () => _playAlbum(album),
                    onAddToQueue: () => _addAlbumToQueue(album),
                    onOpenArtist: () => _openArtistForAlbum(album),
                  );
                },
              );
            }

            final crossCount =
                _effectiveLayoutController.computeCrossAxisCount(availW);
            final spacing = _effectiveLayoutController.spacing;
            final itemWidth = math.max(
              80.0,
              (availW - spacing * (crossCount - 1)) / crossCount,
            );
            final mainExtent = itemWidth + (showCardContainer ? 76.0 : 58.0);

            return GridView.builder(
              key: const Key('album_grid_view'),
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(
                LuminaTokens.spaceLg,
                LuminaTokens.spaceLg,
                LuminaTokens.spaceLg,
                LuminaTokens.bottomScrollClearance,
              ),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossCount,
                crossAxisSpacing: spacing,
                mainAxisSpacing: spacing,
                mainAxisExtent: mainExtent,
              ),
              itemCount: _albums.length,
              itemBuilder: (context, index) {
                final album = _albums[index];
                return AlbumCollectionCard(
                  key: Key('album_card_${album.id}'),
                  album: album,
                  coverRevision: _coverRevision,
                  audioService: widget.audioService,
                  libraryCache: widget.libraryCache,
                  showCardContainer: showCardContainer,
                  onOpenAlbumDetail: () => _openAlbum(album.id),
                  onPlayAlbum: () => _playAlbum(album),
                  onAddToQueue: () => _addAlbumToQueue(album),
                  onOpenArtist: () => _openArtistForAlbum(album),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildCreditsGraph() {
    final artist = _selectedArtist;
    final credits = artist?.credits.isNotEmpty == true
        ? artist!.credits
        : _defaultCredits;
    final groupedByRole = <String, List<AlbumCreditInfo>>{};
    for (final c in credits) {
      groupedByRole.putIfAbsent(c.role, () => []).add(c);
    }

    return ListView(
      key: const Key('credits_graph_view'),
      padding: const EdgeInsets.fromLTRB(
        LuminaTokens.spaceLg,
        LuminaTokens.spaceSm,
        LuminaTokens.spaceLg,
        LuminaTokens.bottomScrollClearance,
      ),
      children: [
        Container(
          padding: const EdgeInsets.all(LuminaTokens.spaceMd),
          decoration: BoxDecoration(
            color: LuminaTokens.accentPurple.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
            border: Border.all(
              color: LuminaTokens.accentPurple.withValues(alpha: 0.5),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                artist?.name ?? _defaultArtistName ?? '藝術家與製作人員關係圖',
                style: const TextStyle(
                  color: LuminaTokens.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (artist?.biography != null) ...[
                const SizedBox(height: LuminaTokens.space2xs),
                Text(
                  artist!.biography!,
                  style: const TextStyle(
                    color: LuminaTokens.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: LuminaTokens.spaceSm),
        if (groupedByRole.isEmpty)
          const Text(
            '尚無創作者與製作人員紀錄，請先至「專輯與發行版本」執行「補全製作人員」。',
            style: TextStyle(color: LuminaTokens.textMuted),
          )
        else
          ...groupedByRole.entries.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: LuminaTokens.spaceSm),
              child: Container(
                padding: const EdgeInsets.all(LuminaTokens.spaceSm),
                decoration: BoxDecoration(
                  color: LuminaTokens.cardBg,
                  borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
                  border: Border.all(color: LuminaTokens.borderSubtle),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.key,
                      style: const TextStyle(
                        color: LuminaTokens.accentPurpleText,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: LuminaTokens.spaceXs),
                    Wrap(
                      spacing: LuminaTokens.spaceXs,
                      runSpacing: LuminaTokens.spaceXs,
                      children: entry.value.map((credit) {
                        return ActionChip(
                          avatar: const Icon(Icons.hub_rounded, size: 16),
                          side: const BorderSide(
                            color: LuminaTokens.borderControl,
                          ),
                          label: Text(
                            credit.albumTitle != null
                                ? '${credit.artistName} → ${credit.albumTitle}'
                                : credit.artistName,
                          ),
                          onPressed: () {
                            if (credit.albumId != null) {
                              if (widget.onOpenAlbumDetail != null) {
                                widget.onOpenAlbumDetail!(credit.albumId!);
                              } else {
                                _openAlbum(credit.albumId!);
                              }
                            } else {
                              _openArtistGraph(credit.artistId);
                            }
                          },
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
