import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../artwork/album_artwork_view.dart';
import '../common/frosted_glass_container.dart';
import '../common/track_context_menu.dart';
import '../common/track_hover_prefetch.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';

part 'home_dashboard_cards.dart';
part 'home_dashboard_queue_and_pills.dart';
part 'home_dashboard_sections.dart';

class HomeDashboardView extends StatefulWidget {
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final List<SmartPlaylistItem> smartPlaylists;
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
  Map<String, SmartPlaylistEvaluation> _smartPlaylistEvals = const {};
  bool _showPlayedTab = false;
  int _carouselOffset = 0;
  late final GlideScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = GlideScrollController(
      initialScrollOffset: widget.initialScrollOffset,
    )..addListener(_handleScroll);
    if (widget.libraryCache != null && widget.libraryCache!.albums.isNotEmpty) {
      _albums = widget.libraryCache!.albums;
    }
    _loadDashboardData();
    unawaited(_loadSmartPlaylistEvals());
  }

  @override
  void didUpdateWidget(covariant HomeDashboardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.smartPlaylists != widget.smartPlaylists) {
      unawaited(_loadSmartPlaylistEvals());
    }
  }

  Future<void> _loadSmartPlaylistEvals() async {
    final top = widget.smartPlaylists.take(3).toList(growable: false);
    if (top.isEmpty) {
      if (mounted && _smartPlaylistEvals.isNotEmpty) {
        setState(() => _smartPlaylistEvals = const {});
      }
      return;
    }
    final next = <String, SmartPlaylistEvaluation>{};
    for (final sp in top) {
      try {
        final ev = await widget.audioService.evaluateSmartPlaylist(sp.id);
        if (ev != null) {
          next[sp.id] = ev;
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _smartPlaylistEvals = next);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  void _refreshState([VoidCallback? fn]) {
    if (!mounted) return;
    setState(fn ?? () {});
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

        return SmoothScrollWrapper(
          controller: _scrollController,
          child: SingleChildScrollView(
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
                    _buildStatPillsRow(
                      uniqueArtistCount: uniqueArtists.length,
                      albumCount: albumCount,
                      trackCount: trackCount,
                      zoneCount: zoneCount,
                    ),
                    const SizedBox(height: 28),
                    _buildRecentActivitySection(recentCards),
                    const SizedBox(height: 30),
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
          ),
        );
      },
    );
  }

  Widget _buildStatPillsRow({
    required int uniqueArtistCount,
    required int albumCount,
    required int trackCount,
    required int zoneCount,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = constraints.maxWidth >= 780
            ? 5
            : (constraints.maxWidth >= 520 ? 3 : 2);
        const gap = 10.0;
        final pillWidth = (constraints.maxWidth - gap * (cols - 1)) / cols;
        final stats = [
          (
            key: 'stat_card_artists',
            icon: Icons.person_outline_rounded,
            label: '$uniqueArtistCount 藝術家',
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
            icon: _connectionIcon(widget.audioService.connectionMode),
            label: widget.audioService.connectionMode.label,
            onTap: widget.onOpenProviderSettings ?? widget.onOpenZones,
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
    );
  }
}
