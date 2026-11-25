import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/streaming_models.dart';
import '../../models/streaming_provider_meta.dart';
import '../../services/audio_service.dart';
import '../../services/streaming/streaming_manager.dart';
import '../../services/streaming/streaming_provider.dart';
import '../artwork/streaming_cover_image.dart';
import '../common/frosted_glass_container.dart';
import '../common/track_hover_prefetch.dart';
import '../settings/streaming_login_dialog.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';

class StreamingServiceView extends StatefulWidget {
  final AudioService audioService;
  final StreamingProviderMeta provider;
  final StreamingManager? streamingManager;
  final Future<void> Function(TrackInfo track)? onPlayStreamingTrack;
  final Future<void> Function(TrackInfo track, List<TrackInfo> queueContext)?
      onPlayStreamingTrackWithContext;
  final void Function(StreamingAlbum album)? onOpenStreamingAlbum;
  final void Function(String providerKind)? onSwitchStreamingProvider;
  final String? activeTrackId;
  final VoidCallback onOpenProviderSettings;
  final VoidCallback? onLibraryUpdated;

  const StreamingServiceView({
    super.key,
    required this.audioService,
    required this.provider,
    this.streamingManager,
    this.onPlayStreamingTrack,
    this.onPlayStreamingTrackWithContext,
    this.onOpenStreamingAlbum,
    this.onSwitchStreamingProvider,
    this.activeTrackId,
    required this.onOpenProviderSettings,
    this.onLibraryUpdated,
  });

  @override
  State<StreamingServiceView> createState() => _StreamingServiceViewState();
}

class _StreamingServiceViewState extends State<StreamingServiceView> {
  static const double _toolbarHeight = 54.0;

  static const List<({int idx, String keyName, String label, IconData icon})>
      _tabs = <({int idx, String keyName, String label, IconData icon})>[
    (
      idx: 0,
      keyName: 'streaming_tab_explore',
      label: '探索推薦',
      icon: Icons.explore_outlined,
    ),
    (
      idx: 1,
      keyName: 'streaming_tab_tracks',
      label: '收藏曲目',
      icon: Icons.music_note_rounded,
    ),
    (
      idx: 2,
      keyName: 'streaming_tab_playlists',
      label: '歌單',
      icon: Icons.queue_music_rounded,
    ),
    (
      idx: 3,
      keyName: 'streaming_tab_albums',
      label: '專輯',
      icon: Icons.album_rounded,
    ),
  ];

  final ScrollController _scrollController = ScrollController();
  final TextEditingController _filterCtrl = TextEditingController();
  final FocusNode _filterFocusNode = FocusNode();

  // Default to 收藏曲目 (index 1) when connected, or 探索推薦 (index 0) in guest mode.
  int _selectedTab = 1;
  bool _userSelectedTab = false;
  bool _filterExpanded = false;
  bool _syncing = false;
  String? _syncNotice;
  String? _errorMessage;

  // Playlist drill-down state
  StreamingPlaylist? _activePlaylist;
  List<TrackInfo> _playlistTracks = const [];
  bool _loadingPlaylist = false;
  String? _playlistError;

  @override
  void initState() {
    super.initState();
    _selectedTab = _defaultTabForCurrentProvider();
    widget.streamingManager?.addListener(_onManagerChanged);
    _filterFocusNode.addListener(_onFilterFocusChanged);
    _scheduleAutoFetchRecommendations();
  }

  @override
  void didUpdateWidget(covariant StreamingServiceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final managerChanged = oldWidget.streamingManager != widget.streamingManager;
    final providerChanged = oldWidget.provider.kind != widget.provider.kind;
    if (managerChanged) {
      oldWidget.streamingManager?.removeListener(_onManagerChanged);
      widget.streamingManager?.addListener(_onManagerChanged);
    }
    if (providerChanged) {
      _activePlaylist = null;
      _playlistTracks = const [];
      _playlistError = null;
      _syncNotice = null;
      _errorMessage = null;
      _filterExpanded = false;
      _filterCtrl.clear();
      _userSelectedTab = false;
      _selectedTab = _defaultTabForCurrentProvider();
    } else if (!_userSelectedTab &&
        widget.provider.kind == 'tidal' &&
        _selectedTab == 1 &&
        _resolveCatalogTracks(_liveProvider).isEmpty) {
      _selectedTab = 0;
    }
    if (managerChanged || providerChanged) {
      _scheduleAutoFetchRecommendations();
    }
  }

  void _scheduleAutoFetchRecommendations() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sm = widget.streamingManager;
      final kind = widget.provider.kind;
      final provider = sm?.providerFor(kind);
      final canBrowse = provider != null &&
          (provider.authState == StreamingAuthState.connected ||
              provider.supportsGuestMode);
      if (sm == null || !canBrowse) {
        return;
      }
      final existing = sm.recommendationsFor(kind);
      if (existing == null &&
          !sm.isLoadingRecommendations(kind) &&
          sm.recommendationErrorFor(kind) == null) {
        unawaited(sm.refreshRecommendationsFor(kind, force: false));
      }
    });
  }

  Future<void> _handleRefreshRecommendations({
    bool showToastOnError = true,
  }) async {
    final sm = widget.streamingManager;
    if (sm == null) return;
    final kind = widget.provider.kind;
    final rec = await sm.refreshRecommendationsFor(kind, force: true);
    if (!mounted) return;
    final err = sm.recommendationErrorFor(kind) ?? rec.errorMessage;
    if (showToastOnError && err != null && err.trim().isNotEmpty) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(
        SnackBar(
          key: Key('streaming_rec_toast_error_$kind'),
          backgroundColor: LuminaTokens.glassDialogBg,
          content: Text(
            '${widget.provider.name} 重新整理推薦失敗：${err.trim()}',
            style: const TextStyle(color: LuminaTokens.textPrimary),
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    widget.streamingManager?.removeListener(_onManagerChanged);
    _filterFocusNode.removeListener(_onFilterFocusChanged);
    _filterFocusNode.dispose();
    _filterCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onManagerChanged() {
    if (!mounted) return;
    setState(() {
      if (!_userSelectedTab &&
          widget.provider.kind == 'tidal' &&
          _selectedTab == 1 &&
          _resolveCatalogTracks(_liveProvider).isEmpty) {
        _selectedTab = 0;
      }
    });
  }

  void _onFilterFocusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  StreamingProvider? get _liveProvider =>
      widget.streamingManager?.providerFor(widget.provider.kind);

  bool get _isGuestMode {
    final provider = _liveProvider;
    return provider != null &&
        provider.authState != StreamingAuthState.connected &&
        provider.authState != StreamingAuthState.authRequired &&
        !(widget.streamingManager?.isAuthRequired(widget.provider.kind) ??
            false) &&
        provider.supportsGuestMode;
  }

  int _defaultTabForCurrentProvider() {
    if (_isGuestMode) return 0;
    if (widget.provider.kind == 'tidal' &&
        _resolveCatalogTracks(_liveProvider).isEmpty) {
      return 0;
    }
    return 1;
  }

  Future<void> _syncCatalog() async {
    if (_isGuestMode) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(
        SnackBar(
          key: const Key('streaming_guest_sync_snackbar'),
          content: Text(
            '登入 ${widget.provider.name} 帳號即可同步個人收藏曲目與歌單。',
          ),
          action: SnackBarAction(
            label: '前往登入',
            textColor: LuminaTokens.glassTextPrimary,
            onPressed: widget.onOpenProviderSettings,
          ),
        ),
      );
      return;
    }
    setState(() {
      _syncing = true;
      _errorMessage = null;
      _syncNotice = null;
    });
    try {
      final mgr = widget.streamingManager;
      if (mgr != null && mgr.providerFor(widget.provider.kind) != null) {
        final catalog = await mgr.syncProvider(widget.provider.kind);
        widget.onLibraryUpdated?.call();
        if (!mounted) return;
        setState(() {
          _syncNotice =
              '已完成 ${widget.provider.name} 曲庫同步（${catalog.tracks.length} 首曲目、${catalog.playlists.length} 個歌單、${catalog.albums.length} 張專輯）';
        });
      } else {
        final result = await widget.audioService.syncProvider(
          widget.provider.kind,
        );
        widget.onLibraryUpdated?.call();
        if (!mounted) return;
        final count = (result['tracks_count'] as num?)?.toInt();
        setState(() {
          _syncNotice = count != null
              ? '已完成 ${widget.provider.name} 曲庫同步（目前共有 $count 首曲目）'
              : '已完成 ${widget.provider.name} 曲庫同步';
        });
      }
    } on StreamingException catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '同步曲庫失敗：$e';
      });
    } finally {
      if (mounted) {
        setState(() => _syncing = false);
      }
    }
  }

  Future<void> _openPlaylist(StreamingPlaylist playlist) async {
    final provider = _liveProvider;
    setState(() {
      _activePlaylist = playlist;
      _loadingPlaylist = true;
      _playlistError = null;
      _playlistTracks = playlist.tracks;
    });

    if (provider == null) {
      setState(() => _loadingPlaylist = false);
      return;
    }

    try {
      final tracks = await widget.streamingManager!.fetchPlaylistTracks(
        widget.provider.kind,
        playlist.id,
      );
      if (!mounted) return;
      setState(() {
        _playlistTracks = tracks;
        _loadingPlaylist = false;
      });
    } on StreamingException catch (e) {
      if (!mounted) return;
      setState(() {
        _playlistError = e.message;
        _loadingPlaylist = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _playlistError = '載入歌單曲目失敗：$e';
        _loadingPlaylist = false;
      });
    }
  }

  Future<void> _playTrack(
    TrackInfo track, {
    List<TrackInfo>? queueContext,
  }) async {
    if (widget.onPlayStreamingTrackWithContext != null) {
      await widget.onPlayStreamingTrackWithContext!(
        track,
        queueContext ?? const <TrackInfo>[],
      );
      return;
    }
    if (widget.onPlayStreamingTrack != null) {
      await widget.onPlayStreamingTrack!(track);
      return;
    }
    await widget.audioService.play(track: track);
  }

  List<TrackInfo> _resolveCatalogTracks(StreamingProvider? provider) {
    final catalogTracks = provider?.catalog.tracks ?? const <TrackInfo>[];
    if (catalogTracks.isNotEmpty) {
      return catalogTracks;
    }
    if (provider == null) {
      return widget.audioService.queue
          .where((t) => widget.provider.matchesTrackProvider(t.providerName))
          .toList(growable: false);
    }
    return const <TrackInfo>[];
  }

  List<TrackInfo> _filterTracks(List<TrackInfo> tracks, String query) {
    if (query.isEmpty) return tracks;
    return tracks.where((t) {
      return t.title.toLowerCase().contains(query) ||
          t.artist.toLowerCase().contains(query) ||
          t.album.toLowerCase().contains(query);
    }).toList(growable: false);
  }

  List<StreamingAlbum> _filterAlbums(
    List<StreamingAlbum> albums,
    String query,
  ) {
    if (query.isEmpty) return albums;
    return albums.where((a) {
      return a.title.toLowerCase().contains(query) ||
          a.artist.toLowerCase().contains(query);
    }).toList(growable: false);
  }

  String _formatDuration(Duration duration) {
    if (duration <= Duration.zero) return '--:--';
    final totalSec = duration.inSeconds;
    final hrs = totalSec ~/ 3600;
    final mins = (totalSec % 3600) ~/ 60;
    final secs = totalSec % 60;
    if (hrs > 0) {
      return '$hrs:${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  String? _formatAlbumQualityBadge(String? rawQuality) {
    final raw = rawQuality?.trim();
    if (raw == null || raw.isEmpty) return null;
    if (raw == 'HI_RES_LOSSLESS' || raw.contains('24-bit')) {
      return '24-bit Hi-Res';
    }
    if (raw == 'LOSSLESS') {
      return '16-bit Lossless';
    }
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    final liveProvider = _liveProvider;
    final accountInfo = liveProvider?.accountInfo;
    final isGuest = _isGuestMode;
    final isAuthRequired =
        (widget.streamingManager?.isAuthRequired(widget.provider.kind) ??
            false) ||
        liveProvider?.authState == StreamingAuthState.authRequired;
    final statusDotColor = isAuthRequired
        ? LuminaTokens.statusError
        : (isGuest
              ? LuminaTokens.glassTextSecondary
              : switch (liveProvider?.authState) {
                  null || StreamingAuthState.connected =>
                    LuminaTokens.statusSuccess,
                  StreamingAuthState.authenticating =>
                    LuminaTokens.statusWarning,
                  StreamingAuthState.error ||
                  StreamingAuthState.authRequired => LuminaTokens.statusError,
                  StreamingAuthState.disconnected => LuminaTokens.textMuted,
                });

    final subtitleLine = accountInfo != null
        ? ((accountInfo.planTier != null &&
                  accountInfo.planTier!.trim().isNotEmpty)
              ? '${accountInfo.displayName} · ${accountInfo.planTier}'
              : accountInfo.displayName)
        : (isGuest ? '免登入探索模式 · 登入以同步個人收藏' : widget.provider.subtitle);

    return LayoutBuilder(
      builder: (context, constraints) {
        final availW = constraints.maxWidth;
        return Column(
          key: Key('streaming_service_view_${widget.provider.kind}'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildCompactToolbar(
              availW: availW,
              subtitleLine: subtitleLine,
              statusDotColor: statusDotColor,
            ),
            const SizedBox(height: LuminaTokens.spaceSm),
            Expanded(
              child: _buildScrollableBody(
                availW: availW,
                liveProvider: liveProvider,
                accountInfo: accountInfo,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCompactToolbar({
    required double availW,
    required String subtitleLine,
    required Color statusDotColor,
  }) {
    final isWideInlineFilter = availW >= 900;
    final isExpandedCompactSearch = !isWideInlineFilter && _filterExpanded;
    final isCompactSync = availW < 620;
    final horizontalPad = availW < 620 ? 10.0 : 12.0;

    return FrostedGlassContainer(
      key: const Key('streaming_compact_toolbar'),
      height: _toolbarHeight,
      blurSigma: LuminaTokens.glassPillBlur,
      color: LuminaTokens.glassSidebarBg,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: LuminaTokens.glassSidebarBorder),
      padding: EdgeInsets.symmetric(horizontal: horizontalPad),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.28),
          blurRadius: 16,
          offset: const Offset(0, 6),
        ),
      ],
      child: Row(
        children: [
          if (isExpandedCompactSearch) ...[
            _buildToolbarLeft(
              subtitleLine: subtitleLine,
              statusDotColor: statusDotColor,
              maxWidth: availW < 540 ? 128.0 : 170.0,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                height: 34,
                child: _buildCompactFilterField(),
              ),
            ),
            const SizedBox(width: 6),
            _buildFilterToggleButton(expanded: true),
            const SizedBox(width: 6),
            _buildSyncPillButton(iconOnly: true),
            const SizedBox(width: 6),
            _buildSettingsIconButton(),
          ] else if (availW < 540) ...[
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _buildToolbarLeft(
                  subtitleLine: subtitleLine,
                  statusDotColor: statusDotColor,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: _buildSegmentedTabPill(availW: availW),
              ),
            ),
            const SizedBox(width: 6),
            _buildToolbarRight(
              availW: availW,
              showInlineFilter: false,
              iconOnlySync: isCompactSync,
            ),
          ] else ...[
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _buildToolbarLeft(
                  subtitleLine: subtitleLine,
                  statusDotColor: statusDotColor,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _buildSegmentedTabPill(availW: availW),
            const SizedBox(width: 8),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: _buildToolbarRight(
                  availW: availW,
                  showInlineFilter: isWideInlineFilter,
                  iconOnlySync: isCompactSync,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildToolbarLeft({
    required String subtitleLine,
    required Color statusDotColor,
    double? maxWidth,
  }) {
    final browsable =
        widget.streamingManager?.browsableProviders ?? const <StreamingProvider>[];
    final canSwitch =
        browsable.length >= 2 && widget.onSwitchStreamingProvider != null;

    Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        widget.provider.buildBadge(boxSize: 32, borderRadius: 8),
        const SizedBox(width: 9),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      widget.provider.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    key: const Key('streaming_status_dot'),
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: statusDotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  if (canSwitch) ...[
                    const SizedBox(width: 3),
                    const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 15,
                      color: LuminaTokens.textMuted,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 1),
              Text(
                subtitleLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 11,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    if (maxWidth != null) {
      content = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: content,
      );
    }

    if (!canSwitch) {
      return content;
    }

    return PopupMenuButton<String>(
      key: const Key('streaming_provider_switcher'),
      tooltip: '切換串流服務',
      padding: EdgeInsets.zero,
      offset: const Offset(0, 44),
      color: LuminaTokens.glassMenuBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: LuminaTokens.glassPillBorder),
      ),
      onSelected: (kind) {
        if (kind != widget.provider.kind) {
          widget.onSwitchStreamingProvider?.call(kind);
        }
      },
      itemBuilder: (context) => [
        for (final p in browsable)
          PopupMenuItem<String>(
            key: Key('streaming_switch_item_${p.kind}'),
            value: p.kind,
            child: Row(
              children: [
                p.meta.buildBadge(boxSize: 20, borderRadius: 5),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    p.meta.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.kind == widget.provider.kind
                          ? Colors.white
                          : LuminaTokens.glassTextSecondary,
                      fontSize: 13,
                      fontWeight: p.kind == widget.provider.kind
                          ? FontWeight.w600
                          : FontWeight.w500,
                    ),
                  ),
                ),
                if (p.kind == widget.provider.kind)
                  const Icon(
                    Icons.check_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
              ],
            ),
          ),
      ],
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: content,
        ),
      ),
    );
  }

  Widget _buildSegmentedTabPill({required double availW}) {
    final showIcons = availW >= 780;
    final horizontalPad = availW >= 840
        ? 12.0
        : (availW >= 620 ? 9.0 : 7.0);
    final fontSize = availW < 560 ? 11.5 : 12.5;

    return Container(
      height: 36,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: LuminaTokens.glassSegmentTrackBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        border: Border.all(color: LuminaTokens.glassSegmentTrackBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final t in _tabs)
            _buildSegmentedTabItem(
              tab: t,
              selected: _selectedTab == t.idx,
              showIcon: showIcons,
              horizontalPad: horizontalPad,
              fontSize: fontSize,
            ),
        ],
      ),
    );
  }

  Widget _buildSegmentedTabItem({
    required ({int idx, String keyName, String label, IconData icon}) tab,
    required bool selected,
    required bool showIcon,
    required double horizontalPad,
    required double fontSize,
  }) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: Key(tab.keyName),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        onTap: () => setState(() {
          _userSelectedTab = true;
          _selectedTab = tab.idx;
          if (tab.idx != 2) {
            _activePlaylist = null;
          }
        }),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          height: 30,
          padding: EdgeInsets.symmetric(horizontal: horizontalPad),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
            color: selected
                ? LuminaTokens.glassSegmentSelectedBg
                : Colors.transparent,
            border: selected
                ? Border.all(color: LuminaTokens.glassSegmentSelectedBorder)
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (showIcon) ...[
                Icon(
                  tab.icon,
                  size: 14,
                  color: selected
                      ? Colors.white
                      : LuminaTokens.glassTextSecondary,
                ),
                const SizedBox(width: 5),
              ],
              Text(
                tab.label,
                style: TextStyle(
                  color: selected
                      ? Colors.white
                      : LuminaTokens.glassTextSecondary,
                  fontSize: fontSize,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToolbarRight({
    required double availW,
    required bool showInlineFilter,
    required bool iconOnlySync,
  }) {
    final filterWidth = availW >= 1080 ? 176.0 : 144.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showInlineFilter)
          SizedBox(
            width: filterWidth,
            height: 34,
            child: _buildCompactFilterField(),
          )
        else
          _buildFilterToggleButton(expanded: false),
        const SizedBox(width: 6),
        _buildSyncPillButton(iconOnly: iconOnlySync),
        const SizedBox(width: 6),
        _buildSettingsIconButton(),
      ],
    );
  }

  Widget _buildCompactFilterField() {
    final hasFocus = _filterFocusNode.hasFocus;
    final hasQuery = _filterCtrl.text.isNotEmpty;
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: LuminaTokens.glassPillBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        border: Border.all(
          color: hasFocus ? LuminaTokens.focusRing : LuminaTokens.glassPillBorder,
          width: hasFocus ? 1.3 : 1.0,
        ),
      ),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 10, right: 6),
            child: Icon(
              Icons.search_rounded,
              color: LuminaTokens.textMuted,
              size: 15,
            ),
          ),
          Expanded(
            child: TextField(
              key: const Key('streaming_search_input'),
              controller: _filterCtrl,
              focusNode: _filterFocusNode,
              onChanged: (_) => setState(() {}),
              maxLines: 1,
              textAlignVertical: TextAlignVertical.center,
              cursorColor: LuminaTokens.glassTextPrimary,
              style: const TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 12.5,
                height: 1.2,
              ),
              decoration: const InputDecoration(
                isDense: true,
                isCollapsed: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: '篩選曲目...',
                hintStyle: TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 12,
                ),
                contentPadding: EdgeInsets.symmetric(vertical: 4),
              ),
            ),
          ),
          if (hasQuery)
            IconButton(
              key: const Key('btn_streaming_filter_clear'),
              tooltip: '清除篩選',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 26, height: 26),
              visualDensity: VisualDensity.compact,
              icon: const Icon(
                Icons.close_rounded,
                size: 14,
                color: LuminaTokens.textSecondary,
              ),
              onPressed: () {
                _filterCtrl.clear();
                setState(() {});
              },
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildFilterToggleButton({required bool expanded}) {
    final hasQuery = _filterCtrl.text.isNotEmpty;
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: expanded || hasQuery
            ? LuminaTokens.glassNavActiveBg
            : LuminaTokens.glassPillBg,
        border: Border.all(
          color: expanded || hasQuery
              ? LuminaTokens.glassCoverRim
              : LuminaTokens.glassPillBorder,
        ),
      ),
      child: IconButton(
        key: const Key('btn_streaming_filter_toggle'),
        tooltip: expanded ? '收合篩選' : '篩選曲目',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 34, height: 34),
        visualDensity: VisualDensity.compact,
        icon: Icon(
          expanded
              ? Icons.close_rounded
              : (hasQuery ? Icons.filter_alt_rounded : Icons.search_rounded),
          size: 16,
          color: expanded || hasQuery
              ? Colors.white
              : LuminaTokens.glassTextSecondary,
        ),
        onPressed: () {
          setState(() {
            _filterExpanded = !expanded;
          });
          if (!expanded) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _filterFocusNode.requestFocus();
            });
          }
        },
      ),
    );
  }

  Widget _buildSyncPillButton({required bool iconOnly}) {
    final pill = Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: const Key('btn_sync_streaming_provider'),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        hoverColor: LuminaTokens.glassPillHoverBg,
        onTap: _syncing ? null : _syncCatalog,
        child: Ink(
          height: 34,
          padding: EdgeInsets.symmetric(horizontal: iconOnly ? 10 : 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
            color: _syncing
                ? LuminaTokens.glassNavActiveBg
                : LuminaTokens.glassPillBg,
            border: Border.all(
              color: _syncing
                  ? LuminaTokens.glassCoverRim
                  : LuminaTokens.glassPillBorder,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_syncing)
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              else
                const Icon(
                  Icons.sync_rounded,
                  size: 15,
                  color: Colors.white,
                ),
              if (!iconOnly) ...[
                const SizedBox(width: 5),
                const Text(
                  '同步',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    if (iconOnly) {
      return Tooltip(message: '同步曲庫', child: pill);
    }
    return pill;
  }

  Widget _buildSettingsIconButton() {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: LuminaTokens.glassPillBg,
        border: Border.all(color: LuminaTokens.glassPillBorder),
      ),
      child: IconButton(
        key: const Key('btn_streaming_open_settings'),
        tooltip: '帳號設定',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 34, height: 34),
        visualDensity: VisualDensity.compact,
        icon: const Icon(
          Icons.settings_outlined,
          size: 17,
          color: LuminaTokens.glassTextSecondary,
        ),
        onPressed: widget.onOpenProviderSettings,
      ),
    );
  }

  Widget _buildScrollableBody({
    required double availW,
    required StreamingProvider? liveProvider,
    required StreamingAccountInfo? accountInfo,
  }) {
    final slivers = <Widget>[
      ..._buildTopNoticeSlivers(accountInfo),
      ...switch (_selectedTab) {
        0 => _buildExploreSlivers(availW: availW),
        1 => _buildTracksSlivers(availW: availW, liveProvider: liveProvider),
        2 => _buildPlaylistsSlivers(availW: availW, liveProvider: liveProvider),
        _ => _buildAlbumsSlivers(availW: availW, liveProvider: liveProvider),
      },
      const SliverToBoxAdapter(
        child: SizedBox(height: LuminaTokens.floatingPlayerClearance),
      ),
    ];

    return SmoothScrollWrapper(
      controller: _scrollController,
      child: CustomScrollView(
        controller: _scrollController,
        slivers: slivers,
      ),
    );
  }

  List<Widget> _buildTopNoticeSlivers(StreamingAccountInfo? accountInfo) {
    final notices = <Widget>[];
    final sm = widget.streamingManager;
    final kind = widget.provider.kind;
    final liveProvider = _liveProvider;
    final isAuthRequired =
        (sm?.isAuthRequired(kind) ?? false) ||
        liveProvider?.authState == StreamingAuthState.authRequired;
    if (isAuthRequired) {
      final reason =
          sm?.authErrorFor(kind) ??
          liveProvider?.lastError ??
          '${widget.provider.name} 授權已失效，請重新登入以繼續播放';
      notices.add(_buildAuthRequiredBanner(reason, liveProvider: liveProvider));
    }
    final drm = accountInfo?.drmNotice?.trim();
    if (drm != null && drm.isNotEmpty) {
      notices.add(_buildDrmNoticeBanner(drm));
    }
    if (_syncNotice != null) {
      notices.add(_buildSyncNoticeBanner(_syncNotice!));
    }
    if (_errorMessage != null) {
      notices.add(_buildErrorBanner(_errorMessage!));
    }
    if (notices.isEmpty) return const <Widget>[];
    return <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(bottom: LuminaTokens.spaceSm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < notices.length; i++) ...[
                if (i > 0) const SizedBox(height: 6),
                notices[i],
              ],
            ],
          ),
        ),
      ),
    ];
  }

  Widget _buildAuthRequiredBanner(
    String message, {
    required StreamingProvider? liveProvider,
  }) {
    final kind = widget.provider.kind;
    final sm = widget.streamingManager;
    return Container(
      key: Key('streaming_auth_required_banner_$kind'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: LuminaTokens.statusError.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(
          color: LuminaTokens.statusError.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.lock_reset_rounded,
            size: 16,
            color: LuminaTokens.statusError,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFFECACA),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: Key('btn_streaming_relogin_$kind'),
            onPressed: () async {
              if (sm != null && liveProvider != null) {
                final ok = await StreamingLoginDialog.show(
                  context,
                  liveProvider,
                  sm,
                );
                if (ok == true && mounted) {
                  setState(() {});
                }
              } else {
                widget.onOpenProviderSettings();
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: LuminaTokens.statusError,
              foregroundColor: LuminaTokens.onAccentDark,
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: const Text('重新登入'),
          ),
        ],
      ),
    );
  }

  Widget _buildDrmNoticeBanner(String notice) {
    return Container(
      key: const Key('streaming_drm_notice_banner'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: LuminaTokens.statusWarning.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(
          color: LuminaTokens.statusWarning.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: LuminaTokens.statusWarning,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              notice,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFFDE68A),
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSyncNoticeBanner(String message) {
    return Container(
      key: const Key('streaming_sync_notice_banner'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: LuminaTokens.statusSuccess.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(
          color: LuminaTokens.statusSuccess.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.check_circle_outline_rounded,
            size: 15,
            color: LuminaTokens.statusSuccess,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: LuminaTokens.statusSuccess,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          IconButton(
            tooltip: '關閉同步通知',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
            visualDensity: VisualDensity.compact,
            icon: const Icon(
              Icons.close_rounded,
              size: 14,
              color: LuminaTokens.textSecondary,
            ),
            onPressed: () => setState(() => _syncNotice = null),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(String message) {
    return Container(
      key: const Key('streaming_error_banner'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: LuminaTokens.statusError.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(
          color: LuminaTokens.statusError.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 16,
            color: LuminaTokens.statusError,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFFECACA),
                fontSize: 12,
              ),
            ),
          ),
          IconButton(
            tooltip: '關閉錯誤訊息',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
            visualDensity: VisualDensity.compact,
            icon: const Icon(
              Icons.close_rounded,
              size: 14,
              color: LuminaTokens.textSecondary,
            ),
            onPressed: () => setState(() => _errorMessage = null),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildExploreSlivers({required double availW}) {
    final sm = widget.streamingManager;
    final kind = widget.provider.kind;
    final rec = sm?.recommendationsFor(kind);
    final isLoading = sm?.isLoadingRecommendations(kind) ?? false;
    final recError = sm?.recommendationErrorFor(kind);
    final query = _filterCtrl.text.trim().toLowerCase();

    final recAlbums = _filterAlbums(
      rec?.albums ?? const <StreamingAlbum>[],
      query,
    );
    final recTracks = _filterTracks(
      rec?.tracks ?? const <TrackInfo>[],
      query,
    );

    final slivers = <Widget>[
      SliverToBoxAdapter(
        child: _buildSectionHeader(
          title: '為你推薦的專輯',
          trailing: _buildRefreshRecButton(
            buttonKey: const Key('btn_streaming_refresh_recommendations'),
            isLoading: isLoading,
          ),
        ),
      ),
    ];

    if (recError != null && recError.trim().isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: LuminaTokens.spaceSm),
            child: _buildRecErrorBanner(kind, recError),
          ),
        ),
      );
    }

    if (isLoading && recAlbums.isEmpty && recTracks.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildRecommendedAlbumsSkeleton(availW),
        ),
      );
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 18)));
      slivers.add(
        SliverToBoxAdapter(
          child: _buildSectionHeader(title: '推薦歌曲'),
        ),
      );
      slivers.add(
        SliverToBoxAdapter(
          child: _buildRecommendedTracksSkeleton(),
        ),
      );
      return slivers;
    }

    if (recAlbums.isEmpty &&
        recTracks.isEmpty &&
        (recError == null || recError.trim().isEmpty)) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildCompactBanner(
            bannerKey: const Key('streaming_explore_empty_banner'),
            icon: Icons.explore_outlined,
            iconColor: LuminaTokens.glassTextSecondary,
            title: query.isNotEmpty
                ? '找不到符合「${_filterCtrl.text.trim()}」的推薦內容'
                : '尚無 ${widget.provider.name} 個人化推薦項目',
            subtitle: query.isNotEmpty
                ? '請清除篩選條件或嘗試其他關鍵字。'
                : '點擊右側「換一批」向 ${widget.provider.name} 取得最新推薦專輯與曲目。',
            actionLabel: query.isNotEmpty
                ? '清除篩選'
                : (sm != null ? '重新取得推薦' : null),
            onAction: query.isNotEmpty
                ? () {
                    _filterCtrl.clear();
                    setState(() {});
                  }
                : (sm != null ? _handleRefreshRecommendations : null),
          ),
        ),
      );
      return slivers;
    }

    if (isLoading && recAlbums.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildRecommendedAlbumsSkeleton(availW),
        ),
      );
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 18)));
    } else if (recAlbums.isNotEmpty) {
      slivers.add(_buildAlbumsSliverGrid(recAlbums));
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 18)));
    }

    if (isLoading && recTracks.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildSectionHeader(title: '推薦歌曲'),
        ),
      );
      slivers.add(
        SliverToBoxAdapter(
          child: _buildRecommendedTracksSkeleton(),
        ),
      );
    } else if (recTracks.isNotEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildSectionHeader(
            title: '推薦歌曲',
            count: recTracks.length,
          ),
        ),
      );
      slivers.add(
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) => _buildTrackRow(
              recTracks[index],
              availW: availW,
              queueContext: recTracks,
            ),
            childCount: recTracks.length,
          ),
        ),
      );
    }

    return slivers;
  }

  List<Widget> _buildTracksSlivers({
    required double availW,
    required StreamingProvider? liveProvider,
  }) {
    final query = _filterCtrl.text.trim().toLowerCase();
    final allTracks = _resolveCatalogTracks(liveProvider);
    final filtered = _filterTracks(allTracks, query);
    final sm = widget.streamingManager;
    final kind = widget.provider.kind;
    final rec = sm?.recommendationsFor(kind);
    final recAlbums = rec?.albums ?? const <StreamingAlbum>[];
    final recTracks = rec?.tracks ?? const <TrackInfo>[];
    final isRecLoading = sm?.isLoadingRecommendations(kind) ?? false;
    final hasManualRecRefresh =
        sm?.hasManualRecommendationRefresh(kind) ?? false;
    final recError = sm?.recommendationErrorFor(kind);
    final hasRecError = recError != null && recError.trim().isNotEmpty;

    final slivers = <Widget>[];

    // Show top recommended albums strip on 收藏曲目 when albums exist, an error occurred, or manual 換一批 is loading.
    if (query.isEmpty &&
        (recAlbums.isNotEmpty ||
            hasRecError ||
            (isRecLoading && hasManualRecRefresh))) {
      slivers.add(
        SliverToBoxAdapter(
          key: const Key('streaming_recommended_albums_strip'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildSectionHeader(
                title: '為你推薦的專輯',
                trailing: _buildRefreshRecButton(
                  buttonKey: const Key('btn_streaming_strip_refresh'),
                  isLoading: isRecLoading,
                ),
              ),
              if (hasRecError) ...[
                _buildRecErrorBanner(kind, recError),
                if (recAlbums.isNotEmpty || isRecLoading)
                  const SizedBox(height: 12),
              ],
              if (recAlbums.isEmpty && isRecLoading)
                _buildRecommendedAlbumsSkeleton(availW)
              else if (recAlbums.isNotEmpty)
                _buildSingleRowAlbumStrip(recAlbums, availW: availW),
              const SizedBox(height: 18),
            ],
          ),
        ),
      );
    }

    if (allTracks.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: _isGuestMode
              ? _buildCompactBanner(
                  bannerKey: const Key('streaming_guest_login_banner'),
                  icon: Icons.person_outline_rounded,
                  iconColor: LuminaTokens.glassTextSecondary,
                  title: '目前為 ${widget.provider.name} 免登入瀏覽模式',
                  subtitle: '您可自由使用「探索推薦」、搜尋與播放；登入帳號後即可同步個人收藏曲目。',
                  actionLabel: '前往登入',
                  onAction: widget.onOpenProviderSettings,
                )
              : _buildCompactBanner(
                  bannerKey: const Key('streaming_empty_sync_banner'),
                  icon: Icons.library_music_outlined,
                  iconColor: LuminaTokens.glassTextSecondary,
                  title: '目前尚無已同步的 ${widget.provider.name} 收藏曲目',
                  subtitle: '點擊右側「立即同步」即可匯入您的串流收藏與高解析曲目。',
                  actionLabel: '立即同步',
                  onAction: _syncing ? null : _syncCatalog,
                ),
        ),
      );

      // Keep the page browsable even before first sync when recommendations exist.
      if (recAlbums.isNotEmpty && query.isNotEmpty) {
        final matchedRecAlbums = _filterAlbums(recAlbums, query);
        if (matchedRecAlbums.isNotEmpty) {
          slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 14)));
          slivers.add(
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.only(bottom: 10),
                child: Text(
                  '為你推薦的專輯',
                  style: TextStyle(
                    color: LuminaTokens.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          );
          slivers.add(_buildAlbumsSliverGrid(matchedRecAlbums));
        }
      }

      if (recTracks.isNotEmpty) {
        final visibleRecTracks = _filterTracks(recTracks, query);
        if (visibleRecTracks.isNotEmpty) {
          slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 14)));
          slivers.add(
            SliverToBoxAdapter(
              child: _buildSectionHeader(
                title: '推薦歌曲',
                count: visibleRecTracks.length,
              ),
            ),
          );
          slivers.add(
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildTrackRow(
                  visibleRecTracks[index],
                  availW: availW,
                  queueContext: visibleRecTracks,
                ),
                childCount: visibleRecTracks.length,
              ),
            ),
          );
        }
      }

      return slivers;
    }

    slivers.add(
      SliverToBoxAdapter(
        child: _buildSectionHeader(
          title: '收藏曲目',
          count: filtered.length,
        ),
      ),
    );

    if (filtered.isEmpty) {
      slivers.add(
        SliverToBoxAdapter(
          child: _buildCompactBanner(
            bannerKey: const Key('streaming_filter_empty_banner'),
            icon: Icons.search_off_rounded,
            iconColor: LuminaTokens.textMuted,
            title: '找不到符合「${_filterCtrl.text.trim()}」的曲目',
            subtitle: '請嘗試調整關鍵字或清除篩選條件。',
            actionLabel: '清除篩選',
            onAction: () {
              _filterCtrl.clear();
              setState(() {});
            },
          ),
        ),
      );
      return slivers;
    }

    slivers.add(
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _buildTrackRow(
            filtered[index],
            availW: availW,
            queueContext: filtered,
          ),
          childCount: filtered.length,
        ),
      ),
    );

    return slivers;
  }

  Widget? _buildRefreshRecButton({
    required Key buttonKey,
    required bool isLoading,
  }) {
    if (widget.streamingManager == null) return null;
    return TextButton.icon(
      key: buttonKey,
      onPressed: isLoading ? null : _handleRefreshRecommendations,
      style: TextButton.styleFrom(
        foregroundColor: LuminaTokens.textSecondary,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: const Size(0, 28),
      ),
      icon: isLoading
          ? const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: LuminaTokens.glassTextPrimary,
              ),
            )
          : const Icon(Icons.refresh_rounded, size: 15),
      label: const Text(
        '換一批',
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      ),
    );
  }

  Widget _buildRecErrorBanner(String kind, String recError) {
    final sm = widget.streamingManager;
    final msg = recError.trim();
    final isExpired =
        (sm?.isRecommendationTokenExpired(kind) ?? false) ||
        msg.contains('401') ||
        msg.contains('過期') ||
        msg.contains('失效');
    return Container(
      key: Key('rec_error_banner_$kind'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: LuminaTokens.statusError.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(
          color: LuminaTokens.statusError.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 17,
            color: LuminaTokens.statusError,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              '${widget.provider.name}：'
              '${isExpired ? "授權權杖已過期或失效（$msg），請重新登入或重試。" : msg}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFFECDD3),
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: Key('btn_retry_rec_$kind'),
            onPressed: sm != null ? _handleRefreshRecommendations : null,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              minimumSize: const Size(0, 28),
            ),
            child: const Text(
              '重試',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (isExpired)
            TextButton(
              key: Key('btn_rec_open_settings_$kind'),
              onPressed: widget.onOpenProviderSettings,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                minimumSize: const Size(0, 28),
              ),
              child: const Text(
                '帳號設定',
                style: TextStyle(
                  color: LuminaTokens.glassTextPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRecommendedAlbumsSkeleton(double availW) {
    final cols = _stripColumnCount(availW);
    return Row(
      key: const Key('rec_albums_skeleton'),
      children: [
        for (var i = 0; i < cols; i++) ...[
          if (i > 0) const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: 1,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 7),
                Container(
                  height: 12,
                  width: 90,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 5),
                Container(
                  height: 10,
                  width: 60,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildRecommendedTracksSkeleton() {
    return Column(
      key: const Key('rec_tracks_skeleton'),
      children: [
        for (var i = 0; i < 4; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        height: 12,
                        width: 160,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        height: 10,
                        width: 110,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  List<Widget> _buildPlaylistsSlivers({
    required double availW,
    required StreamingProvider? liveProvider,
  }) {
    final query = _filterCtrl.text.trim().toLowerCase();
    final activePlaylist = _activePlaylist;
    if (activePlaylist != null) {
      final visibleTracks = _filterTracks(_playlistTracks, query);
      final slivers = <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: LuminaTokens.spaceSm),
            child: Row(
              children: [
                OutlinedButton.icon(
                  key: const Key('btn_back_to_playlists'),
                  onPressed: () => setState(() {
                    _activePlaylist = null;
                    _playlistError = null;
                  }),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: LuminaTokens.glassTextPrimary,
                    backgroundColor: LuminaTokens.glassPillBg,
                    side: const BorderSide(color: LuminaTokens.glassPillBorder),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  icon: const Icon(Icons.arrow_back_rounded, size: 16),
                  label: const Text('返回歌單'),
                ),
                const SizedBox(width: LuminaTokens.spaceSm),
                Expanded(
                  child: Text(
                    activePlaylist.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: LuminaTokens.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ];

      if (_playlistError != null) {
        slivers.add(
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: LuminaTokens.spaceSm),
              child: _buildErrorBanner(_playlistError!),
            ),
          ),
        );
      }

      if (_loadingPlaylist) {
        slivers.add(
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 36),
              child: Center(
                child: CircularProgressIndicator(
                  color: LuminaTokens.glassTextPrimary,
                ),
              ),
            ),
          ),
        );
      } else if (visibleTracks.isEmpty) {
        slivers.add(
          SliverToBoxAdapter(
            child: _buildCompactBanner(
              bannerKey: const Key('streaming_playlist_empty_banner'),
              icon: Icons.queue_music_rounded,
              iconColor: LuminaTokens.textMuted,
              title: query.isNotEmpty
                  ? '歌單中找不到符合「${_filterCtrl.text.trim()}」的曲目'
                  : '此歌單目前沒有可顯示的曲目',
              subtitle: '您可以回到歌單列表或重新同步曲庫。',
              actionLabel: query.isNotEmpty ? '清除篩選' : null,
              onAction: query.isNotEmpty
                  ? () {
                      _filterCtrl.clear();
                      setState(() {});
                    }
                  : null,
            ),
          ),
        );
      } else {
        slivers.add(
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) => _buildTrackRow(
                visibleTracks[index],
                availW: availW,
                queueContext: visibleTracks,
              ),
              childCount: visibleTracks.length,
            ),
          ),
        );
      }

      return slivers;
    }

    final allPlaylists =
        liveProvider?.catalog.playlists ?? const <StreamingPlaylist>[];
    final playlists = query.isEmpty
        ? allPlaylists
        : allPlaylists.where((pl) {
            return pl.title.toLowerCase().contains(query) ||
                (pl.description?.toLowerCase().contains(query) ?? false);
          }).toList(growable: false);

    if (allPlaylists.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: _isGuestMode
              ? _buildCompactBanner(
                  bannerKey: const Key('streaming_guest_login_banner'),
                  icon: Icons.person_outline_rounded,
                  iconColor: LuminaTokens.glassTextSecondary,
                  title: '登入 ${widget.provider.name} 以存取個人歌單',
                  subtitle: '免登入模式仍可於「探索推薦」與搜尋直接播放曲目。',
                  actionLabel: '前往登入',
                  onAction: widget.onOpenProviderSettings,
                )
              : _buildCompactBanner(
                  bannerKey: const Key('streaming_playlists_empty_banner'),
                  icon: Icons.queue_music_rounded,
                  iconColor: LuminaTokens.glassTextSecondary,
                  title: '目前尚無已同步的 ${widget.provider.name} 歌單',
                  subtitle: '點擊右側「立即同步」以載入您的線上歌單。',
                  actionLabel: '立即同步',
                  onAction: _syncing ? null : _syncCatalog,
                ),
        ),
      ];
    }

    if (playlists.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: _buildCompactBanner(
            bannerKey: const Key('streaming_playlists_filter_empty'),
            icon: Icons.search_off_rounded,
            iconColor: LuminaTokens.textMuted,
            title: '找不到符合「${_filterCtrl.text.trim()}」的歌單',
            subtitle: '請嘗試調整關鍵字或清除篩選。',
            actionLabel: '清除篩選',
            onAction: () {
              _filterCtrl.clear();
              setState(() {});
            },
          ),
        ),
      ];
    }

    return <Widget>[
      SliverToBoxAdapter(
        child: _buildSectionHeader(title: '歌單', count: playlists.length),
      ),
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final pl = playlists[index];
            final subtitle =
                pl.description != null && pl.description!.trim().isNotEmpty
                    ? pl.description!
                    : '${pl.trackCount} 首曲目';
            return Material(
              type: MaterialType.transparency,
              child: InkWell(
                key: Key('streaming_playlist_${pl.id}'),
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                hoverColor: LuminaTokens.glassRowHoverBg,
                onTap: () => _openPlaylist(pl),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  child: Row(
                    children: [
                      _buildThumbnail(
                        pl.coverUrl,
                        size: 40,
                        fallbackIcon: Icons.queue_music_rounded,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              pl.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: LuminaTokens.textPrimary,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitle,
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
                      const Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: LuminaTokens.textSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
          childCount: playlists.length,
        ),
      ),
    ];
  }

  List<Widget> _buildAlbumsSlivers({
    required double availW,
    required StreamingProvider? liveProvider,
  }) {
    final query = _filterCtrl.text.trim().toLowerCase();
    final allAlbums =
        liveProvider?.catalog.albums ?? const <StreamingAlbum>[];
    final albums = _filterAlbums(allAlbums, query);

    if (allAlbums.isEmpty) {
      final recAlbums = _filterAlbums(
        widget.streamingManager
                ?.recommendationsFor(widget.provider.kind)
                ?.albums ??
            const <StreamingAlbum>[],
        query,
      );
      return <Widget>[
        SliverToBoxAdapter(
          child: _isGuestMode
              ? _buildCompactBanner(
                  bannerKey: const Key('streaming_guest_login_banner'),
                  icon: Icons.person_outline_rounded,
                  iconColor: LuminaTokens.glassTextSecondary,
                  title: '登入 ${widget.provider.name} 以同步收藏專輯',
                  subtitle: '免登入模式仍可自由瀏覽並播放下方推薦專輯。',
                  actionLabel: '前往登入',
                  onAction: widget.onOpenProviderSettings,
                )
              : _buildCompactBanner(
                  bannerKey: const Key('streaming_albums_empty_banner'),
                  icon: Icons.album_outlined,
                  iconColor: LuminaTokens.glassTextSecondary,
                  title: '目前尚無已同步的 ${widget.provider.name} 專輯',
                  subtitle: '點擊右側「立即同步」以載入您收藏的串流專輯。',
                  actionLabel: '立即同步',
                  onAction: _syncing ? null : _syncCatalog,
                ),
        ),
        if (recAlbums.isNotEmpty) ...[
          const SliverToBoxAdapter(child: SizedBox(height: 14)),
          SliverToBoxAdapter(
            child: _buildSectionHeader(
              title: '為你推薦的專輯',
              count: recAlbums.length,
            ),
          ),
          _buildAlbumsSliverGrid(recAlbums),
        ],
      ];
    }

    if (albums.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: _buildCompactBanner(
            bannerKey: const Key('streaming_albums_filter_empty'),
            icon: Icons.search_off_rounded,
            iconColor: LuminaTokens.textMuted,
            title: '找不到符合「${_filterCtrl.text.trim()}」的專輯',
            subtitle: '請嘗試調整關鍵字或清除篩選。',
            actionLabel: '清除篩選',
            onAction: () {
              _filterCtrl.clear();
              setState(() {});
            },
          ),
        ),
      ];
    }

    return <Widget>[
      SliverToBoxAdapter(
        child: _buildSectionHeader(title: '專輯', count: albums.length),
      ),
      _buildAlbumsSliverGrid(
        albums,
        keyPrefix: 'streaming_album_',
      ),
    ];
  }

  Widget _buildSectionHeader({
    required String title,
    int? count,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
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
          if (count != null) ...[
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
                  color: LuminaTokens.glassTextSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          const Spacer(),
          ?trailing,
        ],
      ),
    );
  }

  int _stripColumnCount(double availW) => availW >= 1320
      ? 7
      : (availW >= 1100
            ? 6
            : (availW >= 880
                  ? 5
                  : (availW >= 660 ? 4 : (availW >= 460 ? 3 : 2))));

  Widget _buildSingleRowAlbumStrip(
    List<StreamingAlbum> albums, {
    required double availW,
  }) {
    final maxCols = _stripColumnCount(availW);
    const spacing = 14.0;
    final visible = albums.take(maxCols).toList(growable: false);
    final cardWidth = (availW - spacing * (maxCols - 1)) / maxCols;
    final cardHeight = cardWidth + 46.0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < visible.length; i++) ...[
          if (i > 0) const SizedBox(width: spacing),
          SizedBox(
            width: cardWidth,
            height: cardHeight,
            child: _buildAlbumCard(
              visible[i],
              cardKey: Key('streaming_rec_strip_album_${visible[i].id}'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAlbumsSliverGrid(
    List<StreamingAlbum> albums, {
    String keyPrefix = 'streaming_rec_album_',
  }) {
    return SliverGrid(
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 190,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: 0.74,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final alb = albums[index];
          return _buildAlbumCard(
            alb,
            cardKey: Key('$keyPrefix${alb.id}'),
          );
        },
        childCount: albums.length,
      ),
    );
  }

  Widget _buildAlbumCard(
    StreamingAlbum album, {
    required Key cardKey,
  }) {
    final qualityBadge = _formatAlbumQualityBadge(album.qualityLabel);
    final subtitle = album.year != null
        ? '${album.artist} · ${album.year}'
        : album.artist;

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: cardKey,
        borderRadius: BorderRadius.circular(10),
        hoverColor: LuminaTokens.glassRowHoverBg,
        onTap: widget.onOpenStreamingAlbum != null
            ? () => widget.onOpenStreamingAlbum!(album)
            : null,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: StreamingCoverImage(
                            url: album.coverUrl,
                            targetSize: 600,
                            fallbackBuilder: (_) => _buildAlbumCoverFallback(),
                          ),
                        ),
                        if (qualityBadge != null)
                          Positioned(
                            right: 6,
                            bottom: 6,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 132),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: LuminaTokens.glassDialogBg,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: LuminaTokens.glassPillBorder,
                                  ),
                                ),
                                child: Text(
                                  qualityBadge,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: LuminaTokens.textPrimary,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    height: 1.1,
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
              const SizedBox(height: 7),
              Text(
                album.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: LuminaTokens.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 11.5,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAlbumCoverFallback() {
    return Container(
      decoration: BoxDecoration(
        color: LuminaTokens.glassPillBg,
        border: Border.all(color: LuminaTokens.glassSidebarBorder),
      ),
      child: const Center(
        child: Icon(
          Icons.album_rounded,
          size: 34,
          color: LuminaTokens.textMuted,
        ),
      ),
    );
  }

  Widget _buildTrackRow(
    TrackInfo item, {
    required double availW,
    List<TrackInfo>? queueContext,
  }) {
    final isSelected = widget.activeTrackId == item.id;
    final isWideRow = availW >= 700;
    final showQuality = availW >= 460;
    final durationLabel = _formatDuration(item.duration);
    final albumSub = item.album.trim();

    return TrackHoverPrefetch(
      track: item,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: Key('streaming_track_${item.id}'),
          borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
          hoverColor: LuminaTokens.glassRowHoverBg,
          onTap: () => _playTrack(item, queueContext: queueContext),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: isSelected
                  ? LuminaTokens.glassNavActiveBg
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  height: 40,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildThumbnail(
                        item.coverUrl ?? item.albumArtUrl,
                        size: 40,
                        fallbackIcon: Icons.music_note_rounded,
                      ),
                      if (isSelected)
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.52),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Center(
                            child: Icon(
                              Icons.equalizer_rounded,
                              color: Colors.white,
                              size: 19,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (isWideRow) ...[
                  Expanded(
                    flex: 5,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          item.title,
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
                        if (albumSub.isNotEmpty && albumSub != item.title) ...[
                          const SizedBox(height: 1),
                          Text(
                            albumSub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: LuminaTokens.textMuted,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: Text(
                      item.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.textMuted,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ] else
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isSelected
                                ? Colors.white
                                : LuminaTokens.glassTextPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          albumSub.isNotEmpty
                              ? '${item.artist} · $albumSub'
                              : item.artist,
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
                if (showQuality) ...[
                  const SizedBox(width: 10),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: isWideRow ? 170 : 128,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 3.5,
                      ),
                      decoration: BoxDecoration(
                        color: LuminaTokens.glassPillBg,
                        borderRadius: BorderRadius.circular(
                          LuminaTokens.radiusPill,
                        ),
                        border: Border.all(color: LuminaTokens.glassPillBorder),
                      ),
                      child: Text(
                        item.format.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.glassTextSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 12),
                SizedBox(
                  width: 44,
                  child: Text(
                    durationLabel,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: LuminaTokens.textMuted,
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail(
    String? url, {
    double size = 40,
    required IconData fallbackIcon,
  }) {
    Widget buildFallback() => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: LuminaTokens.glassPillBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: LuminaTokens.glassSidebarBorder),
      ),
      child: Icon(
        fallbackIcon,
        color: LuminaTokens.glassTextSecondary,
        size: size * 0.52,
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: StreamingCoverImage(
        url: url,
        targetSize: size >= 100 ? 600 : 300,
        width: size,
        height: size,
        fallbackBuilder: (_) => buildFallback(),
      ),
    );
  }

  Widget _buildCompactBanner({
    required Key bannerKey,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Container(
      key: bannerKey,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
        border: Border.all(color: LuminaTokens.glassCardBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: LuminaTokens.glassPillBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: LuminaTokens.glassPillBorder),
            ),
            child: Icon(icon, size: 18, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
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
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.textMuted,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          if (actionLabel != null) ...[
            const SizedBox(width: 12),
            FilledButton(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                backgroundColor: LuminaTokens.glassSwitchOnTrack,
                foregroundColor: LuminaTokens.onAccentDark,
                disabledBackgroundColor: LuminaTokens.glassPillBg,
                disabledForegroundColor: LuminaTokens.textDisabled,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                minimumSize: const Size(0, 32),
              ),
              child: Text(
                actionLabel,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
