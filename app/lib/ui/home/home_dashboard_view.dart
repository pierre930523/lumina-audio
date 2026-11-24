import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../artwork/album_artwork_view.dart';
import '../common/track_hover_prefetch.dart';
import '../theme/lumina_tokens.dart';

class HomeDashboardView extends StatefulWidget {
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final VoidCallback onOpenAlbums;
  final VoidCallback onOpenLibrary;
  final VoidCallback onOpenCredits;
  final VoidCallback onOpenDsp;
  final VoidCallback onOpenZones;
  final VoidCallback? onOpenAppearance;
  final VoidCallback? onOpenLibrarySettings;
  final VoidCallback? onOpenProviderSettings;
  final void Function(String albumId)? onOpenAlbumDetail;
  final double initialScrollOffset;
  final ValueChanged<double>? onScrollOffsetChanged;

  const HomeDashboardView({
    super.key,
    required this.audioService,
    this.libraryCache,
    required this.onOpenAlbums,
    required this.onOpenLibrary,
    required this.onOpenCredits,
    required this.onOpenDsp,
    required this.onOpenZones,
    this.onOpenAppearance,
    this.onOpenLibrarySettings,
    this.onOpenProviderSettings,
    this.onOpenAlbumDetail,
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
    [Color(0xFF1D4ED8), Color(0xFF0EA5E9)],
    [Color(0xFF6D28D9), Color(0xFFEC4899)],
    [Color(0xFF0F766E), Color(0xFF34D399)],
    [Color(0xFFB45309), Color(0xFFF59E0B)],
    [Color(0xFF4338CA), Color(0xFF8B5CF6)],
  ];

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
        final hPad = (availW * 0.032).clamp(14.0, 42.0).toDouble();
        final vPad = availW >= 900 ? 18.0 : 12.0;
        final greetingSize = availW >= 1400
            ? 34.0
            : (availW >= 680 ? 29.0 : 23.0);

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
                // Adaptive Greeting Header
                Padding(
                  padding: const EdgeInsets.only(bottom: LuminaTokens.spaceMd),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Text(
                          '哈囉！$_profileName',
                          key: const Key('home_greeting_title'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: LuminaTokens.textPrimary,
                            fontSize: greetingSize,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                      const SizedBox(width: LuminaTokens.spaceSm),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: LuminaTokens.spaceSm,
                          vertical: LuminaTokens.space2xs,
                        ),
                        decoration: BoxDecoration(
                          color: LuminaTokens.cardElevatedBg,
                          borderRadius: BorderRadius.circular(
                            LuminaTokens.radiusPill,
                          ),
                          border: Border.all(
                            color: LuminaTokens.borderControl,
                          ),
                        ),
                        child: Text(
                          widget.audioService.connectionMode.label,
                          style: const TextStyle(
                            color: LuminaTokens.textMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Adaptive 2/4-Column Stat Summary Cards
                LayoutBuilder(
                  builder: (context, constraints) {
                    final cols = constraints.maxWidth >= 680 ? 4 : 2;
                    const gap = LuminaTokens.spaceSm;
                    final cardWidth =
                        (constraints.maxWidth - gap * (cols - 1)) / cols;
                    final stats = [
                      (
                        key: 'stat_card_artists',
                        icon: Icons.person_outline_rounded,
                        count: '${uniqueArtists.length}',
                        label: '藝術家',
                        onTap: widget.onOpenCredits,
                      ),
                      (
                        key: 'stat_card_albums',
                        icon: Icons.album_outlined,
                        count: '$albumCount',
                        label: '專輯',
                        onTap: widget.onOpenAlbums,
                      ),
                      (
                        key: 'stat_card_tracks',
                        icon: Icons.music_note_rounded,
                        count: '$trackCount',
                        label: '曲目',
                        onTap: widget.onOpenLibrary,
                      ),
                      (
                        key: 'stat_card_zones',
                        icon: Icons.speaker_group_outlined,
                        count: '$zoneCount',
                        label: '輸出音區',
                        onTap: widget.onOpenZones,
                      ),
                    ];

                    return Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: stats.map((s) {
                        return SizedBox(
                          width: cardWidth,
                          child: Material(
                            color: LuminaTokens.cardBg,
                            borderRadius: BorderRadius.circular(
                              LuminaTokens.radiusSm,
                            ),
                            child: InkWell(
                              key: Key(s.key),
                              onTap: s.onTap,
                              hoverColor: LuminaTokens.cardHoverBg.withValues(
                                alpha: 0.7,
                              ),
                              borderRadius: BorderRadius.circular(
                                LuminaTokens.radiusSm,
                              ),
                              child: Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal:
                                      constraints.maxWidth >= 520 ? 18 : 12,
                                  vertical: LuminaTokens.spaceMd,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(
                                    LuminaTokens.radiusSm,
                                  ),
                                  border: Border.all(
                                    color: LuminaTokens.borderSubtle,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      s.icon,
                                      size: 26,
                                      color: LuminaTokens.textSecondary,
                                    ),
                                    const SizedBox(width: LuminaTokens.spaceSm),
                                    Flexible(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            s.count,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: LuminaTokens.textPrimary,
                                              fontSize: 22,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          Text(
                                            s.label,
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
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
                const SizedBox(height: LuminaTokens.spaceMd),

                // Adaptive Indigo-Slate Gradient Recent Activity Section
                Container(
                  key: const Key('home_recent_activity_card'),
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFF353E6E),
                        Color(0xFF252C52),
                      ],
                    ),
                  ),
                  child: LayoutBuilder(
                    builder: (context, panelConstraints) {
                      final innerW = panelConstraints.maxWidth;
                      final maxCols = innerW >= 1420
                          ? 6
                          : (innerW >= 1060
                              ? 5
                              : (innerW >= 760
                                  ? 4
                                  : (innerW >= 480 ? 3 : 2)));
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
                      const spacing = 14.0;
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
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
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
                                          ? LuminaTokens.textPrimary
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
                                          ? LuminaTokens.textPrimary
                                          : LuminaTokens.textDisabled,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  TextButton(
                                    onPressed: widget.onOpenAlbums,
                                    style: TextButton.styleFrom(
                                      backgroundColor:
                                          Colors.white.withValues(alpha: 0.14),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 4,
                                      ),
                                      minimumSize: const Size(0, 28),
                                    ),
                                    child: const Text(
                                      '更多',
                                      style: TextStyle(fontSize: 12),
                                    ),
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
                                  style: TextStyle(color: Colors.white70),
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
                ),
                const SizedBox(height: 16),

                // Adaptive Bottom Studio Workspace: Single Column (< 920) or Balanced Two Columns (>= 920)
                if (availW >= 920)
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 7, child: _buildStudioBanner()),
                        const SizedBox(width: 16),
                        Expanded(
                          flex: 5,
                          child: _buildQuickQueueCard(tracks),
                        ),
                      ],
                    ),
                  )
                else ...[
                  _buildStudioBanner(),
                  const SizedBox(height: 12),
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
      borderRadius: BorderRadius.circular(8),
      onTap: widget.onOpenLibrary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: Colors.white.withValues(alpha: 0.06),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.14),
                ),
              ),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.create_new_folder_outlined,
                    size: 40,
                    color: Colors.white70,
                  ),
                  SizedBox(height: 10),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      '掃描新增音樂資料夾',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '擴充無損曲庫',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Color(0xFFB8C2EB), fontSize: 10.5),
          ),
          const SizedBox(height: 2),
          const Text(
            '匯入本機無損專輯',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Text(
            'FLAC / WAV / DSD / ALAC',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Color(0xFFD1D9F0), fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildStudioBanner() {
    return Container(
      key: const Key('home_explore_banner'),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Color(0xFF343066),
            Color(0xFF562524),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '高解析音響工作室',
                style: TextStyle(
                  color: LuminaTokens.textSecondary,
                  fontSize: 11,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 4),
              Text(
                '64-bit DSP 與多房間音區',
                style: TextStyle(
                  color: LuminaTokens.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              SizedBox(height: 4),
              Text(
                '調整 10 段 PEQ / AutoEQ 曲線，或透過 DLNA / AirPlay 同步輸出至多台設備',
                style: TextStyle(color: LuminaTokens.textSecondary, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: LuminaTokens.spaceMd),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: LuminaTokens.accentBlue,
                  foregroundColor: LuminaTokens.onAccentDark,
                ),
                onPressed: widget.onOpenDsp,
                icon: const Icon(Icons.graphic_eq_rounded, size: 18),
                label: const Text('開啟 DSP 引擎'),
              ),
              OutlinedButton.icon(
                onPressed: widget.onOpenLibrarySettings ?? widget.onOpenLibrary,
                style: OutlinedButton.styleFrom(
                  foregroundColor: LuminaTokens.textPrimary,
                  side: const BorderSide(color: LuminaTokens.textMuted),
                ),
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: const Text('掃描音樂資料夾'),
              ),
              if (widget.onOpenAppearance != null)
                OutlinedButton.icon(
                  onPressed: widget.onOpenAppearance,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: LuminaTokens.textPrimary,
                    side: const BorderSide(color: LuminaTokens.textMuted),
                  ),
                  icon: const Icon(Icons.aspect_ratio_rounded, size: 17),
                  label: const Text('介面縮放設定'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQuickQueueCard(List<TrackInfo> tracks) {
    return Container(
      key: const Key('home_quick_queue_card'),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
      decoration: BoxDecoration(
        color: LuminaTokens.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: LuminaTokens.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  '待播佇列（${tracks.length} 首）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton(
                onPressed: widget.onOpenLibrary,
                style: TextButton.styleFrom(
                  foregroundColor: LuminaTokens.accentBlue,
                  minimumSize: const Size(0, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('管理曲目庫 >', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final t in tracks.take(3))
            TrackHoverPrefetch(
              track: t,
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  hoverColor: LuminaTokens.cardHoverBg.withValues(alpha: 0.7),
                  onTap: () => widget.audioService.play(track: t),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 7,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.play_circle_outline_rounded,
                          color: LuminaTokens.textSecondary,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                t.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: LuminaTokens.textPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                '${t.artist} • ${t.format.label}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: LuminaTokens.textMuted,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
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
            badgeLabel: '正在播放 • ${active.format.label}',
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
            badgeLabel: '${t.album} • ${t.format.label}',
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
          badgeLabel: a.year != null ? '發行年份 ${a.year}' : '已收錄專輯',
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
            badgeLabel: t.format.label,
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
  final String badgeLabel;
  final TrackInfo? track;
  final CanonicalAlbumSummary? album;

  const _RecentItem({
    required this.title,
    required this.subtitle,
    required this.badgeLabel,
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
              color: selected ? Colors.white : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected
                ? LuminaTokens.textPrimary
                : LuminaTokens.textSecondary,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
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

    return RepaintBoundary(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Semantics(
          button: true,
          label: '${item.title} ${item.subtitle}',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onOpenAlbum,
            child: AnimatedContainer(
              duration: LuminaTokens.focusDuration,
              curve: LuminaTokens.motionCurve,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: _hovered
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.transparent,
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
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: _hovered
                                    ? const Color(0x77000000)
                                    : const Color(0x44000000),
                                blurRadius: _hovered ? 18 : 12,
                                offset: const Offset(0, 6),
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
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: _hovered
                                      ? Colors.white.withValues(alpha: 0.24)
                                      : Colors.white.withValues(alpha: 0.08),
                                ),
                                boxShadow: const [],
                                placeholder: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
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
                                      color: Colors.white.withValues(alpha: 0.38),
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
                                        child: Container(
                                          width: 28,
                                          height: 28,
                                          decoration: BoxDecoration(
                                            color: _hovered
                                                ? LuminaTokens.accentBlue
                                                : Colors.black.withValues(
                                                    alpha: 0.55,
                                                  ),
                                            shape: BoxShape.circle,
                                          ),
                                          child: Icon(
                                            Icons.play_arrow_rounded,
                                            size: 18,
                                            color: _hovered
                                                ? LuminaTokens.onAccentDark
                                                : LuminaTokens.textPrimary,
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
                const SizedBox(height: 8),
                Text(
                  item.badgeLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFB8C2EB),
                    fontSize: 10.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  item.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFD1D9F0),
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
