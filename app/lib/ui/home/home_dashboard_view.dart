import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/smart_playlist.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../artwork/album_artwork_view.dart';
import '../common/frosted_glass_container.dart';
import '../common/track_hover_prefetch.dart';
import '../theme/lumina_tokens.dart';

class HomeDashboardView extends StatefulWidget {
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final List<SmartPlaylist> smartPlaylists;
  final VoidCallback onOpenAlbums;
  final VoidCallback onOpenLibrary;
  final VoidCallback onOpenCredits;
  final VoidCallback onOpenDsp;
  final VoidCallback onOpenZones;
  final VoidCallback? onOpenAppearance;
  final VoidCallback? onOpenLibrarySettings;
  final VoidCallback? onOpenProviderSettings;
  final void Function(String albumId)? onOpenAlbumDetail;
  final void Function(String playlistId)? onOpenSmartPlaylist;
  final VoidCallback? onOpenSmartPlaylists;
  final double initialScrollOffset;
  final ValueChanged<double>? onScrollOffsetChanged;

  const HomeDashboardView({
    super.key,
    required this.audioService,
    this.libraryCache,
    this.smartPlaylists = const [],
    required this.onOpenAlbums,
    required this.onOpenLibrary,
    required this.onOpenCredits,
    required this.onOpenDsp,
    required this.onOpenZones,
    this.onOpenAppearance,
    this.onOpenLibrarySettings,
    this.onOpenProviderSettings,
    this.onOpenAlbumDetail,
    this.onOpenSmartPlaylist,
    this.onOpenSmartPlaylists,
    this.initialScrollOffset = 0.0,
    this.onScrollOffsetChanged,
  });

  @override
  State<HomeDashboardView> createState() => _HomeDashboardViewState();
}

class _HomeDashboardViewState extends State<HomeDashboardView> {
  String _profileName = 'Lumina';
  List<CanonicalAlbumSummary> _albums = const [];
  List<AudioZoneInfo> _zones = const [];
  bool _showPlayedTab = false;
  int _carouselOffset = 0;
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(
      initialScrollOffset: widget.initialScrollOffset,
    )..addListener(_handleScroll);
    if (widget.libraryCache != null && widget.libraryCache!.albums.isNotEmpty) {
      _albums = widget.libraryCache!.albums;
    }
    _loadDashboardData();
  }

  @override
  void dispose() {
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

  Future<void> _loadDashboardData() async {
    final profiles = await widget.audioService.listProfiles();
    final albums = await widget.audioService.getAlbums(limit: 50);
    final zones = await widget.audioService.listZones();
    if (!mounted) return;
    final activeProfile =
        profiles.where((p) => p.isDefault).firstOrNull ?? profiles.firstOrNull;
    setState(() {
      if (activeProfile != null && activeProfile.name.isNotEmpty) {
        _profileName = activeProfile.name == 'Default Listener'
            ? '預設聆聽者'
            : activeProfile.name;
      }
      _albums = albums;
      _zones = zones;
    });
  }

  static const _coverPalettes = <List<Color>>[
    [Color(0xFF1E293B), Color(0xFF0F172A)],
    [Color(0xFF2E1F47), Color(0xFF171329)],
    [Color(0xFF132A2E), Color(0xFF0D1B1E)],
    [Color(0xFF2D211A), Color(0xFF16110E)],
    [Color(0xFF1F243D), Color(0xFF111322)],
  ];

  static const _curatedSets = <({
    String title,
    String subtitle,
    List<Color> colors,
    IconData icon,
    List<String> keywords,
  })>[
    (
      title: '深夜舒緩旋律',
      subtitle: '沉靜空間感與細膩夜曲精選',
      colors: [Color(0xFF1B243B), Color(0xFF0F1322)],
      icon: Icons.nightlight_round,
      keywords: ['moon', 'night', 'blue', 'kind', 'jazz', 'piano', 'chill'],
    ),
    (
      title: 'J-Pop 流行速遞',
      subtitle: '日系都會律動與高解析人聲',
      colors: [Color(0xFF331D3E), Color(0xFF181124)],
      icon: Icons.graphic_eq_rounded,
      keywords: ['j-pop', 'pop', 'tokyo', 'yoasobi', 'kenshi', 'ado'],
    ),
    (
      title: '動漫原聲特輯',
      subtitle: '經典配樂與劇伴無損母帶',
      colors: [Color(0xFF142E2E), Color(0xFF0E181B)],
      icon: Icons.movie_filter_rounded,
      keywords: ['ost', 'anime', 'castle', 'ghibli', 'hisaishi', 'soundtrack'],
    ),
  ];

  IconData _connectionIcon(ConnectionMode mode) => switch (mode) {
    ConnectionMode.localOrUsbDac => Icons.usb_rounded,
    ConnectionMode.lanRemote => Icons.wifi_rounded,
    ConnectionMode.wanRemote => Icons.public_rounded,
  };

  String _formatDuration(Duration duration) {
    final totalSeconds = math.max(0, duration.inSeconds);
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final tracks = widget.audioService.queue;
    final uniqueArtists = <String>{
      ...tracks.map((t) => t.artist).where((a) => a.trim().isNotEmpty),
      ..._albums.map((a) => a.artist).where((a) => a.trim().isNotEmpty),
    };
    final albumCount = _albums.isNotEmpty
        ? _albums.length
        : tracks
            .map((t) => t.album)
            .where((a) => a.trim().isNotEmpty)
            .toSet()
            .length;
    final trackCount = tracks.length;
    final zoneCount = _zones.isNotEmpty ? _zones.length : 1;

    final recentCards = _buildRecentItems(tracks);

    return LayoutBuilder(
      builder: (context, outerConstraints) {
        final availW = outerConstraints.maxWidth;
        final hPad = (availW * 0.032).clamp(16.0, 42.0).toDouble();
        final vPad = availW >= 900 ? 20.0 : 14.0;
        final greetingSize = availW >= 1200
            ? 32.0
            : (availW >= 680 ? 28.0 : 24.0);

        return SingleChildScrollView(
          key: const Key('home_dashboard_view'),
          controller: _scrollController,
          padding: EdgeInsets.fromLTRB(
            hPad,
            vPad,
            hPad,
            vPad + LuminaTokens.bottomScrollClearance,
          ),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 2200),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Minimalist Greeting Header
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      '哈囉！$_profileName',
                      key: const Key('home_greeting_title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: LuminaTokens.glassTextPrimary,
                        fontSize: greetingSize,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ),

                  // Single-Row 5-Column Frosted Glass Stat Pills (responsive wrap on narrow widths)
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final cols = constraints.maxWidth >= 780
                          ? 5
                          : (constraints.maxWidth >= 520 ? 3 : 2);
                      const gap = 10.0;
                      final pillWidth =
                          (constraints.maxWidth - gap * (cols - 1)) / cols;
                      final stats = [
                        (
                          key: 'stat_card_artists',
                          icon: Icons.person_outline_rounded,
                          label: '${uniqueArtists.length} 藝術家',
                          onTap: widget.onOpenCredits,
                        ),
                        (
                          key: 'stat_card_albums',
                          icon: Icons.album_outlined,
                          label: '$albumCount 專輯',
                          onTap: widget.onOpenAlbums,
                        ),
                        (
                          key: 'stat_card_tracks',
                          icon: Icons.music_note_rounded,
                          label: '$trackCount 曲目',
                          onTap: widget.onOpenLibrary,
                        ),
                        (
                          key: 'stat_card_zones',
                          icon: Icons.speaker_group_outlined,
                          label: '$zoneCount 輸出設備',
                          onTap: widget.onOpenZones,
                        ),
                        (
                          key: 'stat_card_connection',
                          icon: _connectionIcon(
                            widget.audioService.connectionMode,
                          ),
                          label: widget.audioService.connectionMode.label,
                          onTap:
                              widget.onOpenProviderSettings ?? widget.onOpenZones,
                        ),
                      ];

                      return Wrap(
                        spacing: gap,
                        runSpacing: gap,
                        children: [
                          for (final s in stats)
                            _StatPillButton(
                              key: Key(s.key),
                              width: pillWidth,
                              icon: s.icon,
                              label: s.label,
                              onTap: s.onTap,
                            ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 28),

                  // Frameless Recent Activity 5-Column Grid
                  LayoutBuilder(
                    key: const Key('home_recent_activity_card'),
                    builder: (context, panelConstraints) {
                      final innerW = panelConstraints.maxWidth;
                      final maxCols = innerW >= 1020
                          ? 5
                          : (innerW >= 740
                              ? 4
                              : (innerW >= 480 ? 3 : 2));
                      final maxOffset = math.max(0, recentCards.length - maxCols);
                      final safeOffset = _carouselOffset.clamp(0, maxOffset);
                      if (safeOffset != _carouselOffset) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted && _carouselOffset != safeOffset) {
                            setState(() => _carouselOffset = safeOffset);
                          }
                        });
                      }
                      final slice = recentCards
                          .skip(safeOffset)
                          .take(maxCols)
                          .toList();
                      final showAddSlot =
                          safeOffset == 0 && slice.length < maxCols;
                      final displayedTotal =
                          slice.length + (showAddSlot ? 1 : 0);
                      final effectiveCols = math.max(
                        1,
                        math.min(maxCols, displayedTotal),
                      );
                      const spacing = 16.0;
                      final itemWidth =
                          (innerW - spacing * (effectiveCols - 1)) /
                              effectiveCols;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                    '近期活動',
                                    style: TextStyle(
                                      color: LuminaTokens.glassTextPrimary,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -0.2,
                                    ),
                                  ),
                                  const SizedBox(width: 20),
                                  _ActivityTabButton(
                                    label: '已播放',
                                    selected: _showPlayedTab,
                                    onTap: () => setState(() {
                                      _showPlayedTab = true;
                                      _carouselOffset = 0;
                                    }),
                                  ),
                                  const SizedBox(width: 14),
                                  _ActivityTabButton(
                                    label: '已新增',
                                    selected: !_showPlayedTab,
                                    onTap: () => setState(() {
                                      _showPlayedTab = false;
                                      _carouselOffset = 0;
                                    }),
                                  ),
                                ],
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: '上一頁活動',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: safeOffset > 0
                                        ? () => setState(
                                            () => _carouselOffset =
                                                math.max(0, safeOffset - 1),
                                          )
                                        : null,
                                    icon: Icon(
                                      Icons.chevron_left_rounded,
                                      color: safeOffset > 0
                                          ? LuminaTokens.glassTextPrimary
                                          : LuminaTokens.textDisabled,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: '下一頁活動',
                                    visualDensity: VisualDensity.compact,
                                    onPressed: safeOffset + maxCols <
                                            recentCards.length
                                        ? () => setState(
                                            () => _carouselOffset =
                                                safeOffset + 1,
                                          )
                                        : null,
                                    icon: Icon(
                                      Icons.chevron_right_rounded,
                                      color: safeOffset + maxCols <
                                              recentCards.length
                                          ? LuminaTokens.glassTextPrimary
                                          : LuminaTokens.textDisabled,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  _GlassSectionActionLink(
                                    label: '更多',
                                    onTap: widget.onOpenAlbums,
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          if (slice.isEmpty)
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 28),
                              child: Center(
                                child: Text(
                                  '尚未掃描任何音樂專輯，點擊「曲目庫」或「專輯」開始建立曲庫。',
                                  style: TextStyle(
                                    color: LuminaTokens.glassTextSecondary,
                                  ),
                                ),
                              ),
                            )
                          else
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (var idx = 0; idx < slice.length; idx++)
                                  Padding(
                                    padding: EdgeInsets.only(
                                      right: (!showAddSlot &&
                                              idx == slice.length - 1)
                                          ? 0
                                          : spacing,
                                    ),
                                    child: SizedBox(
                                      width: itemWidth,
                                      child: _buildRecentAlbumCard(
                                        slice[idx],
                                        _coverPalettes[(idx + safeOffset) %
                                            _coverPalettes.length],
                                      ),
                                    ),
                                  ),
                                if (showAddSlot)
                                  SizedBox(
                                    width: itemWidth,
                                    child: _buildImportGuideCard(),
                                  ),
                              ],
                            ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 30),

                  // Lower Asymmetric Dual-Column (62% : 38% >= 900px, stacked below)
                  if (availW >= 900)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 62,
                          child: _buildRecommendedSection(tracks),
                        ),
                        const SizedBox(width: 28),
                        Expanded(
                          flex: 38,
                          child: _buildQuickQueueCard(tracks),
                        ),
                      ],
                    )
                  else ...[
                    _buildRecommendedSection(tracks),
                    const SizedBox(height: 24),
                    _buildQuickQueueCard(tracks),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildRecentAlbumCard(_RecentItem item, List<Color> palette) {
    final resolvedAlbum = item.album ??
        (item.track != null
            ? widget.libraryCache?.resolveAlbumForTrack(item.track!)
            : null);

    final card = _RecentAlbumCard(
      key: resolvedAlbum != null
          ? Key('home_recent_album_${resolvedAlbum.id}')
          : null,
      item: item,
      album: resolvedAlbum,
      palette: palette,
      audioService: widget.audioService,
      libraryCache: widget.libraryCache,
      showTrackArtwork: _showPlayedTab || resolvedAlbum == null,
      onOpenAlbum: resolvedAlbum != null && widget.onOpenAlbumDetail != null
          ? () => widget.onOpenAlbumDetail!(resolvedAlbum.id)
          : () {
              if (item.track != null) {
                widget.audioService.play(track: item.track);
              } else {
                widget.onOpenAlbums();
              }
            },
      onPlayTrack: item.track != null
          ? () => widget.audioService.play(track: item.track)
          : null,
    );
    return TrackHoverPrefetch(
      track: item.track,
      enabled: _showPlayedTab && item.track != null,
      child: card,
    );
  }

  Widget _buildImportGuideCard() {
    return InkWell(
      key: const Key('home_import_guide_card'),
      borderRadius: BorderRadius.circular(12),
      onTap: widget.onOpenLibrary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: FrostedGlassContainer(
              blurSigma: LuminaTokens.glassPillBlur,
              enableBackdropBlur: false,
              borderRadius: BorderRadius.circular(12),
              color: LuminaTokens.glassPillBg,
              border: Border.all(
                color: LuminaTokens.glassPillBorder,
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.create_new_folder_outlined,
                    size: 38,
                    color: LuminaTokens.glassTextSecondary,
                  ),
                  SizedBox(height: 10),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      '掃描新增音樂資料夾',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: LuminaTokens.glassTextPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '匯入本機無損專輯',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: LuminaTokens.glassTextPrimary,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'FLAC / WAV / DSD / ALAC',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: LuminaTokens.glassTextSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecommendedSection(List<TrackInfo> tracks) {
    final playlists = widget.smartPlaylists;
    final items = <({
      String? playlistId,
      String title,
      String subtitle,
      List<Color> colors,
      IconData icon,
      TrackInfo? coverTrack,
      TrackInfo? playTrack,
    })>[];

    if (playlists.isNotEmpty) {
      for (var i = 0; i < math.min(3, playlists.length); i++) {
        final sp = playlists[i];
        final matched = sp.evaluate(tracks);
        final curated = _curatedSets[i % _curatedSets.length];
        items.add((
          playlistId: sp.id,
          title: sp.name,
          subtitle: sp.description.isNotEmpty
              ? sp.description
              : '${matched.length} 首收錄曲目',
          colors: curated.colors,
          icon: curated.icon,
          coverTrack: matched.firstOrNull,
          playTrack: matched.firstOrNull,
        ));
      }
    } else {
      for (var i = 0; i < _curatedSets.length; i++) {
        final preset = _curatedSets[i];
        TrackInfo? matched;
        for (final t in tracks) {
          final hay = '${t.title} ${t.artist} ${t.album} ${t.genre ?? ''}'
              .toLowerCase();
          if (preset.keywords.any(hay.contains)) {
            matched = t;
            break;
          }
        }
        matched ??= tracks.isNotEmpty ? tracks[i % tracks.length] : null;
        items.add((
          playlistId: null,
          title: preset.title,
          subtitle: preset.subtitle,
          colors: preset.colors,
          icon: preset.icon,
          coverTrack: matched,
          playTrack: matched,
        ));
      }
    }

    return Column(
      key: const Key('home_recommended_section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              '為你推薦',
              style: TextStyle(
                color: LuminaTokens.glassTextPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
            _GlassSectionActionLink(
              label: '探索更多 >',
              onTap: widget.onOpenSmartPlaylists ?? widget.onOpenAlbums,
            ),
          ],
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final cols = w >= 460 ? 3 : (w >= 280 ? 2 : 1);
            const gap = 14.0;
            final cardWidth = (w - gap * (cols - 1)) / cols;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (var i = 0; i < items.length; i++)
                  SizedBox(
                    width: cardWidth,
                    child: _RecommendedPlaylistCard(
                      key: Key('home_recommended_card_$i'),
                      title: items[i].title,
                      subtitle: items[i].subtitle,
                      colors: items[i].colors,
                      icon: items[i].icon,
                      coverTrack: items[i].coverTrack,
                      audioService: widget.audioService,
                      libraryCache: widget.libraryCache,
                      onOpen: () {
                        final pid = items[i].playlistId;
                        if (pid != null && widget.onOpenSmartPlaylist != null) {
                          widget.onOpenSmartPlaylist!(pid);
                        } else if (items[i].playTrack != null) {
                          widget.audioService.play(track: items[i].playTrack);
                        } else {
                          (widget.onOpenSmartPlaylists ?? widget.onOpenAlbums)();
                        }
                      },
                      onPlay: () {
                        if (items[i].playTrack != null) {
                          widget.audioService.play(track: items[i].playTrack);
                        } else {
                          final pid = items[i].playlistId;
                          if (pid != null &&
                              widget.onOpenSmartPlaylist != null) {
                            widget.onOpenSmartPlaylist!(pid);
                          } else {
                            (widget.onOpenSmartPlaylists ??
                                widget.onOpenAlbums)();
                          }
                        }
                      },
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildQuickQueueCard(List<TrackInfo> tracks) {
    final recentTracks = tracks.take(5).toList(growable: false);
    return Column(
      key: const Key('home_quick_queue_card'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Expanded(
              child: Text(
                '最近播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: LuminaTokens.glassTextPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            _GlassSectionActionLink(
              label: '查看全部 >',
              onTap: widget.onOpenLibrary,
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (recentTracks.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text(
              '尚無最近播放曲目',
              style: TextStyle(
                color: LuminaTokens.glassTextSecondary,
                fontSize: 13,
              ),
            ),
          )
        else
          for (var i = 0; i < recentTracks.length; i++)
            _buildRecentTrackRow(
              index: i + 1,
              track: recentTracks[i],
            ),
      ],
    );
  }

  Widget _buildRecentTrackRow({
    required int index,
    required TrackInfo track,
  }) {
    return TrackHoverPrefetch(
      track: track,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: Key('home_recent_track_${track.id}'),
          borderRadius: BorderRadius.circular(8),
          hoverColor: LuminaTokens.glassRowHoverBg,
          onTap: () => widget.audioService.play(track: track),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            child: Row(
              children: [
                SizedBox(
                  width: 22,
                  child: Text(
                    '$index',
                    style: const TextStyle(
                      color: LuminaTokens.glassTextTertiary,
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                AlbumArtworkView(
                  track: track,
                  size: 40,
                  fullResolution: false,
                  audioService: widget.audioService,
                  libraryCache: widget.libraryCache,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: LuminaTokens.glassPillBorder,
                    width: 0.8,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.glassTextPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.glassTextSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _formatDuration(track.duration),
                  style: const TextStyle(
                    color: LuminaTokens.glassTextTertiary,
                    fontSize: 12,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  CanonicalAlbumSummary? _findAlbumForTrack(TrackInfo track) {
    return _albums
            .where((a) =>
                a.title == track.album &&
                (a.artist == track.artist || a.artist == track.effectiveAlbumArtist))
            .firstOrNull ??
        _albums.where((a) => a.title == track.album).firstOrNull;
  }

  List<_RecentItem> _buildRecentItems(List<TrackInfo> tracks) {
    final items = <_RecentItem>[];
    if (_showPlayedTab) {
      final active = widget.audioService.currentState.track;
      if (active != null) {
        items.add(
          _RecentItem(
            title: active.album,
            subtitle: active.artist,
            track: active,
            album: _findAlbumForTrack(active),
          ),
        );
      }
      for (final t in tracks) {
        if (active != null && t.id == active.id) continue;
        items.add(
          _RecentItem(
            title: t.title,
            subtitle: t.artist,
            track: t,
            album: _findAlbumForTrack(t),
          ),
        );
      }
      return items;
    }

    for (final a in _albums) {
      final matchTrack = tracks
              .where((t) =>
                  t.album == a.title &&
                  (t.effectiveAlbumArtist == a.artist || t.artist == a.artist))
              .firstOrNull ??
          tracks.where((t) => t.album == a.title).firstOrNull;
      items.add(
        _RecentItem(
          title: a.title,
          subtitle: a.artist,
          track: matchTrack,
          album: a,
        ),
      );
    }
    if (items.isEmpty) {
      for (final t in tracks) {
        items.add(
          _RecentItem(
            title: t.album,
            subtitle: t.artist,
            track: t,
          ),
        );
      }
    }
    return items;
  }
}

class _RecentItem {
  final String title;
  final String subtitle;
  final TrackInfo? track;
  final CanonicalAlbumSummary? album;

  const _RecentItem({
    required this.title,
    required this.subtitle,
    required this.track,
    this.album,
  });
}

class _ActivityTabButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ActivityTabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? LuminaTokens.glassTextPrimary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected
                ? LuminaTokens.glassTextPrimary
                : LuminaTokens.glassTextSecondary,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _StatPillButton extends StatefulWidget {
  final double width;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _StatPillButton({
    super.key,
    required this.width,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  State<_StatPillButton> createState() => _StatPillButtonState();
}

class _StatPillButtonState extends State<_StatPillButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(12);
    return SizedBox(
      width: widget.width,
      height: 44,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) {
          if (!_hovered) setState(() => _hovered = true);
        },
        onExit: (_) {
          if (_hovered) setState(() => _hovered = false);
        },
        child: FrostedGlassContainer(
          height: 44,
          blurSigma: LuminaTokens.glassPillBlur,
          enableBackdropBlur: false,
          color: _hovered
              ? LuminaTokens.glassPillHoverBg
              : LuminaTokens.glassPillBg,
          borderRadius: radius,
          border: Border.all(
            color: _hovered
                ? LuminaTokens.glassCoverRim
                : LuminaTokens.glassPillBorder,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: widget.onTap,
              hoverColor: LuminaTokens.glassPillHoverBg,
              borderRadius: radius,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    Icon(
                      widget.icon,
                      size: 17,
                      color: LuminaTokens.glassTextSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.glassTextPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassSectionActionLink extends StatefulWidget {
  final String label;
  final VoidCallback onTap;

  const _GlassSectionActionLink({
    required this.label,
    required this.onTap,
  });

  @override
  State<_GlassSectionActionLink> createState() =>
      _GlassSectionActionLinkState();
}

class _GlassSectionActionLinkState extends State<_GlassSectionActionLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        hoverColor: LuminaTokens.glassPillBg,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Text(
            widget.label,
            style: TextStyle(
              color: _hovered
                  ? LuminaTokens.glassTextPrimary
                  : LuminaTokens.glassTextSecondary,
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _RecommendedPlaylistCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final List<Color> colors;
  final IconData icon;
  final TrackInfo? coverTrack;
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final VoidCallback onOpen;
  final VoidCallback onPlay;

  const _RecommendedPlaylistCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.colors,
    required this.icon,
    required this.coverTrack,
    required this.audioService,
    required this.libraryCache,
    required this.onOpen,
    required this.onPlay,
  });

  @override
  State<_RecommendedPlaylistCard> createState() =>
      _RecommendedPlaylistCardState();
}

class _RecommendedPlaylistCardState extends State<_RecommendedPlaylistCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(12);
    return RepaintBoundary(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) {
          if (!_hovered) setState(() => _hovered = true);
        },
        onExit: (_) {
          if (_hovered) setState(() => _hovered = false);
        },
        child: Semantics(
          button: true,
          label: '${widget.title} ${widget.subtitle}',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onOpen,
            child: AnimatedContainer(
              duration: LuminaTokens.hoverDuration,
              curve: LuminaTokens.motionCurve,
              transform: Matrix4.translationValues(
                0.0,
                _hovered ? -3.0 : 0.0,
                0.0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 10,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: radius,
                        boxShadow: [
                          BoxShadow(
                            color: _hovered
                                ? const Color(0x73000000)
                                : const Color(0x59000000),
                            blurRadius: _hovered ? 24 : 18,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: radius,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            AlbumArtworkView(
                              track: widget.coverTrack,
                              size: 240,
                              fullResolution: false,
                              audioService: widget.audioService,
                              libraryCache: widget.libraryCache,
                              borderRadius: radius,
                              border: Border.all(
                                color: _hovered
                                    ? LuminaTokens.glassCoverRim
                                    : LuminaTokens.glassPillBorder,
                              ),
                              boxShadow: const [],
                              placeholder: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: radius,
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: widget.colors,
                                  ),
                                ),
                                child: Center(
                                  child: Icon(
                                    widget.icon,
                                    size: 36,
                                    color: Colors.white.withValues(alpha: 0.36),
                                  ),
                                ),
                              ),
                            ),
                            IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.transparent,
                                      Colors.black.withValues(alpha: 0.45),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              right: 8,
                              bottom: 8,
                              child: Tooltip(
                                message: '播放 ${widget.title}',
                                child: Semantics(
                                  button: true,
                                  label: '播放 ${widget.title}',
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: widget.onPlay,
                                    child: AnimatedContainer(
                                      duration: LuminaTokens.focusDuration,
                                      width: 32,
                                      height: 32,
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(
                                          alpha: _hovered ? 0.68 : 0.48,
                                        ),
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: _hovered
                                              ? LuminaTokens.glassCoverRim
                                              : LuminaTokens.glassPillBorder,
                                        ),
                                      ),
                                      child: const Icon(
                                        Icons.play_arrow_rounded,
                                        size: 19,
                                        color: LuminaTokens.glassTextPrimary,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: LuminaTokens.glassTextPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: LuminaTokens.glassTextSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecentAlbumCard extends StatefulWidget {
  final _RecentItem item;
  final CanonicalAlbumSummary? album;
  final List<Color> palette;
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final bool showTrackArtwork;
  final VoidCallback onOpenAlbum;
  final VoidCallback? onPlayTrack;

  const _RecentAlbumCard({
    super.key,
    required this.item,
    required this.album,
    required this.palette,
    required this.audioService,
    required this.libraryCache,
    required this.showTrackArtwork,
    required this.onOpenAlbum,
    this.onPlayTrack,
  });

  @override
  State<_RecentAlbumCard> createState() => _RecentAlbumCardState();
}

class _RecentAlbumCardState extends State<_RecentAlbumCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final album = widget.album;
    final coverRadius = BorderRadius.circular(12);

    return RepaintBoundary(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) {
          if (!_hovered) setState(() => _hovered = true);
        },
        onExit: (_) {
          if (_hovered) setState(() => _hovered = false);
        },
        child: Semantics(
          button: true,
          label: '${item.title} ${item.subtitle}',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onOpenAlbum,
            child: AnimatedContainer(
              duration: LuminaTokens.hoverDuration,
              curve: LuminaTokens.motionCurve,
              transform: Matrix4.translationValues(
                0.0,
                _hovered ? -4.0 : 0.0,
                0.0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AspectRatio(
                    aspectRatio: 1,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 280),
                      child: LayoutBuilder(
                        builder: (context, artConstraints) {
                          final side = math.min(
                            artConstraints.maxWidth,
                            artConstraints.maxHeight,
                          );
                          final artSize =
                              (side.isFinite && side > 0) ? side : 180.0;
                          return Container(
                            decoration: BoxDecoration(
                              borderRadius: coverRadius,
                              boxShadow: [
                                BoxShadow(
                                  color: _hovered
                                      ? const Color(0x73000000)
                                      : const Color(0x59000000),
                                  blurRadius: _hovered ? 28 : 24,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                AlbumArtworkView(
                                  track: widget.showTrackArtwork
                                      ? item.track
                                      : null,
                                  album: album,
                                  size: artSize,
                                  audioService: widget.audioService,
                                  libraryCache: widget.libraryCache,
                                  fullResolution: false,
                                  borderRadius: coverRadius,
                                  border: Border.all(
                                    color: _hovered
                                        ? LuminaTokens.glassCoverRim
                                        : LuminaTokens.glassPillBorder,
                                  ),
                                  boxShadow: const [],
                                  placeholder: Container(
                                    decoration: BoxDecoration(
                                      borderRadius: coverRadius,
                                      gradient: LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: widget.palette,
                                      ),
                                    ),
                                    child: Center(
                                      child: Icon(
                                        Icons.album_rounded,
                                        size: 56,
                                        color: Colors.white.withValues(
                                          alpha: 0.34,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  right: 8,
                                  bottom: 8,
                                  child: Tooltip(
                                    message: '播放 ${item.title}',
                                    child: Semantics(
                                      button: true,
                                      label: '播放 ${item.title}',
                                      child: MouseRegion(
                                        cursor: SystemMouseCursors.click,
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: widget.onPlayTrack ??
                                              widget.onOpenAlbum,
                                          child: AnimatedOpacity(
                                            duration:
                                                LuminaTokens.focusDuration,
                                            opacity: _hovered ? 1.0 : 0.78,
                                            child: Container(
                                              width: 32,
                                              height: 32,
                                              decoration: BoxDecoration(
                                                color: Colors.black.withValues(
                                                  alpha: _hovered ? 0.68 : 0.48,
                                                ),
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color: _hovered
                                                      ? LuminaTokens
                                                          .glassCoverRim
                                                      : LuminaTokens
                                                          .glassPillBorder,
                                                ),
                                              ),
                                              child: const Icon(
                                                Icons.play_arrow_rounded,
                                                size: 19,
                                                color: LuminaTokens
                                                    .glassTextPrimary,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: LuminaTokens.glassTextPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: LuminaTokens.glassTextSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
