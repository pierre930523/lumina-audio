import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/streaming_models.dart';
import '../../models/streaming_provider_meta.dart';
import '../../services/audio_service.dart';
import '../../services/streaming/streaming_manager.dart';
import '../../services/streaming/streaming_provider.dart';
import '../theme/lumina_tokens.dart';

class StreamingServiceView extends StatefulWidget {
  final AudioService audioService;
  final StreamingProviderMeta provider;
  final StreamingManager? streamingManager;
  final Future<void> Function(TrackInfo track)? onPlayStreamingTrack;
  final Future<void> Function(TrackInfo track, List<TrackInfo> queueContext)?
      onPlayStreamingTrackWithContext;
  final void Function(StreamingAlbum album)? onOpenStreamingAlbum;
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
    this.activeTrackId,
    required this.onOpenProviderSettings,
    this.onLibraryUpdated,
  });

  @override
  State<StreamingServiceView> createState() => _StreamingServiceViewState();
}

class _StreamingServiceViewState extends State<StreamingServiceView> {
  final TextEditingController _filterCtrl = TextEditingController();
  final TextEditingController _remoteSearchCtrl = TextEditingController();

  int _selectedTab = 0; // 0: 收藏曲目, 1: 歌單, 2: 專輯, 3: 線上搜尋
  bool _syncing = false;
  String? _syncNotice;
  String? _errorMessage;

  // Playlist drill-down state
  StreamingPlaylist? _activePlaylist;
  List<TrackInfo> _playlistTracks = const [];
  bool _loadingPlaylist = false;
  String? _playlistError;

  // Remote search state
  bool _searchingRemote = false;
  String? _remoteSearchError;
  StreamingCatalog? _remoteSearchResult;

  @override
  void initState() {
    super.initState();
    widget.streamingManager?.addListener(_onManagerChanged);
  }

  @override
  void didUpdateWidget(covariant StreamingServiceView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.streamingManager != widget.streamingManager) {
      oldWidget.streamingManager?.removeListener(_onManagerChanged);
      widget.streamingManager?.addListener(_onManagerChanged);
    }
    if (oldWidget.provider.kind != widget.provider.kind) {
      _activePlaylist = null;
      _playlistTracks = const [];
      _playlistError = null;
      _remoteSearchResult = null;
      _remoteSearchError = null;
      _syncNotice = null;
      _errorMessage = null;
    }
  }

  @override
  void dispose() {
    widget.streamingManager?.removeListener(_onManagerChanged);
    _filterCtrl.dispose();
    _remoteSearchCtrl.dispose();
    super.dispose();
  }

  void _onManagerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  StreamingProvider? get _liveProvider =>
      widget.streamingManager?.providerFor(widget.provider.kind);

  Future<void> _syncCatalog() async {
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

  Future<void> _runRemoteSearch() async {
    final query = _remoteSearchCtrl.text.trim();
    if (query.isEmpty) {
      setState(() {
        _remoteSearchError = '請輸入搜尋關鍵字';
      });
      return;
    }
    final mgr = widget.streamingManager;
    final provider = _liveProvider;
    if (mgr == null || provider == null) {
      setState(() {
        _remoteSearchError = '尚未連接 ${widget.provider.name} 線上搜尋服務';
      });
      return;
    }

    setState(() {
      _searchingRemote = true;
      _remoteSearchError = null;
    });

    try {
      final result = await mgr.searchProvider(widget.provider.kind, query);
      if (!mounted) return;
      setState(() {
        _remoteSearchResult = result;
        _searchingRemote = false;
      });
    } on StreamingException catch (e) {
      if (!mounted) return;
      setState(() {
        _remoteSearchError = e.message;
        _searchingRemote = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _remoteSearchError = '線上搜尋失敗：$e';
        _searchingRemote = false;
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

  @override
  Widget build(BuildContext context) {
    final liveProvider = _liveProvider;
    final accountInfo = liveProvider?.accountInfo;
    final isConnected = liveProvider == null ||
        liveProvider.authState == StreamingAuthState.connected;
    final statusBadgeText = liveProvider == null
        ? '已登入連線'
        : switch (liveProvider.authState) {
            StreamingAuthState.connected => '已登入連線',
            StreamingAuthState.authenticating => '驗證中',
            StreamingAuthState.error => '授權異常',
            StreamingAuthState.disconnected => '未連線',
          };
    final statusBadgeColor = isConnected
        ? LuminaTokens.statusSuccess
        : (liveProvider.authState == StreamingAuthState.error
              ? LuminaTokens.statusError
              : LuminaTokens.textMuted);

    final subtitleLine = accountInfo != null
        ? ((accountInfo.planTier != null && accountInfo.planTier!.isNotEmpty)
              ? '${accountInfo.displayName} • ${accountInfo.planTier}'
              : accountInfo.displayName)
        : widget.provider.subtitle;

    return Column(
      key: Key('streaming_service_view_${widget.provider.kind}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(
          subtitleLine: subtitleLine,
          statusBadgeText: statusBadgeText,
          statusBadgeColor: statusBadgeColor,
        ),
        if (accountInfo?.drmNotice != null &&
            accountInfo!.drmNotice!.trim().isNotEmpty) ...[
          const SizedBox(height: LuminaTokens.spaceSm),
          _buildDrmNoticeBanner(accountInfo.drmNotice!),
        ],
        if (_syncNotice != null) ...[
          const SizedBox(height: LuminaTokens.spaceXs),
          Text(
            _syncNotice!,
            style: const TextStyle(
              color: LuminaTokens.statusSuccess,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
        if (_errorMessage != null) ...[
          const SizedBox(height: LuminaTokens.spaceXs),
          _buildErrorBanner(_errorMessage!),
        ],
        const SizedBox(height: LuminaTokens.spaceSm),
        _buildTabStrip(),
        const SizedBox(height: LuminaTokens.spaceSm),
        Expanded(
          child: switch (_selectedTab) {
            0 => _buildTracksTab(liveProvider),
            1 => _buildPlaylistsTab(liveProvider),
            2 => _buildAlbumsTab(liveProvider),
            _ => _buildRemoteSearchTab(),
          },
        ),
      ],
    );
  }

  Widget _buildHeader({
    required String subtitleLine,
    required String statusBadgeText,
    required Color statusBadgeColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(LuminaTokens.spaceMd),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            LuminaTokens.compositeOver(
              widget.provider.badgeColor.withValues(alpha: 0.24),
              LuminaTokens.cardBg,
            ),
            LuminaTokens.cardBg,
          ],
        ),
        border: Border.all(
          color: widget.provider.badgeColor.withValues(alpha: 0.55),
        ),
      ),
      child: Wrap(
        spacing: 14,
        runSpacing: 12,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                widget.provider.buildBadge(boxSize: 44, borderRadius: 10),
                const SizedBox(width: 14),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            widget.provider.name,
                            style: const TextStyle(
                              color: LuminaTokens.textPrimary,
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: LuminaTokens.spaceXs,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: statusBadgeColor.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(
                                LuminaTokens.radiusPill,
                              ),
                              border: Border.all(
                                color: statusBadgeColor.withValues(alpha: 0.55),
                              ),
                            ),
                            child: Text(
                              statusBadgeText,
                              style: TextStyle(
                                color: statusBadgeColor,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitleLine,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Wrap(
            spacing: LuminaTokens.spaceXs,
            runSpacing: LuminaTokens.spaceXs,
            children: [
              FilledButton.icon(
                key: const Key('btn_sync_streaming_provider'),
                style: FilledButton.styleFrom(
                  backgroundColor: LuminaTokens.accentBlue,
                  foregroundColor: LuminaTokens.onAccentDark,
                ),
                onPressed: _syncing ? null : _syncCatalog,
                icon: _syncing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: LuminaTokens.onAccentDark,
                        ),
                      )
                    : const Icon(Icons.sync_rounded, size: 17),
                label: const Text('同步曲庫'),
              ),
              OutlinedButton.icon(
                key: const Key('btn_streaming_open_settings'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: LuminaTokens.textPrimary,
                  side: const BorderSide(color: LuminaTokens.borderControl),
                ),
                onPressed: widget.onOpenProviderSettings,
                icon: const Icon(Icons.manage_accounts_outlined, size: 17),
                label: const Text('帳號設定'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDrmNoticeBanner(String notice) {
    return Container(
      key: const Key('streaming_drm_notice_banner'),
      padding: const EdgeInsets.symmetric(
        horizontal: LuminaTokens.spaceMd,
        vertical: LuminaTokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2112),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(
          color: LuminaTokens.statusWarning.withValues(alpha: 0.6),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: LuminaTokens.statusWarning,
          ),
          const SizedBox(width: LuminaTokens.spaceXs),
          Expanded(
            child: Text(
              notice,
              style: const TextStyle(
                color: Color(0xFFFDE68A),
                fontSize: 12,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(String message) {
    return Container(
      key: const Key('streaming_error_banner'),
      padding: const EdgeInsets.symmetric(
        horizontal: LuminaTokens.spaceMd,
        vertical: LuminaTokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: LuminaTokens.statusErrorBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(color: LuminaTokens.statusError),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: LuminaTokens.statusError,
          ),
          const SizedBox(width: LuminaTokens.spaceXs),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Color(0xFFFECACA),
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabStrip() {
    const tabs = <({int idx, String keyName, String label, IconData icon})>[
      (
        idx: 0,
        keyName: 'streaming_tab_tracks',
        label: '收藏曲目',
        icon: Icons.music_note_rounded,
      ),
      (
        idx: 1,
        keyName: 'streaming_tab_playlists',
        label: '歌單',
        icon: Icons.queue_music_rounded,
      ),
      (
        idx: 2,
        keyName: 'streaming_tab_albums',
        label: '專輯',
        icon: Icons.album_rounded,
      ),
      (
        idx: 3,
        keyName: 'streaming_tab_search',
        label: '線上搜尋',
        icon: Icons.travel_explore_rounded,
      ),
    ];

    return Wrap(
      spacing: LuminaTokens.spaceXs,
      runSpacing: LuminaTokens.spaceXs,
      children: [
        for (final t in tabs)
          ChoiceChip(
            key: Key(t.keyName),
            selected: _selectedTab == t.idx,
            onSelected: (_) => setState(() {
              _selectedTab = t.idx;
              if (t.idx != 1) {
                _activePlaylist = null;
              }
            }),
            backgroundColor: LuminaTokens.cardBg,
            selectedColor: LuminaTokens.accentBlue.withValues(alpha: 0.18),
            side: BorderSide(
              color: _selectedTab == t.idx
                  ? LuminaTokens.accentBlue
                  : LuminaTokens.borderControl,
            ),
            avatar: Icon(
              t.icon,
              size: 15,
              color: _selectedTab == t.idx
                  ? LuminaTokens.accentBlue
                  : LuminaTokens.textSecondary,
            ),
            label: Text(
              t.label,
              style: TextStyle(
                color: _selectedTab == t.idx
                    ? LuminaTokens.accentBlue
                    : LuminaTokens.textSecondary,
                fontSize: 12.5,
                fontWeight:
                    _selectedTab == t.idx ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildFilterInput({required String hint}) {
    return TextField(
      key: const Key('streaming_search_input'),
      controller: _filterCtrl,
      onChanged: (_) => setState(() {}),
      style: const TextStyle(color: LuminaTokens.textPrimary, fontSize: 13),
      decoration: InputDecoration(
        prefixIcon: const Icon(
          Icons.search_rounded,
          color: LuminaTokens.textMuted,
          size: 18,
        ),
        hintText: hint,
        hintStyle: const TextStyle(color: LuminaTokens.textMuted),
        filled: true,
        fillColor: LuminaTokens.cardBg,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: LuminaTokens.spaceSm,
          vertical: LuminaTokens.spaceSm,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
          borderSide: const BorderSide(color: LuminaTokens.borderControl),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
          borderSide: const BorderSide(color: LuminaTokens.borderControl),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
          borderSide: const BorderSide(
            color: LuminaTokens.focusRing,
            width: 1.5,
          ),
        ),
      ),
    );
  }

  Widget _buildTracksTab(StreamingProvider? liveProvider) {
    final query = _filterCtrl.text.trim().toLowerCase();
    final allTracks = _resolveCatalogTracks(liveProvider);
    final filtered = allTracks.where((t) {
      if (query.isEmpty) return true;
      return t.title.toLowerCase().contains(query) ||
          t.artist.toLowerCase().contains(query) ||
          t.album.toLowerCase().contains(query);
    }).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildFilterInput(
          hint: '在 ${widget.provider.name} 收藏中篩選曲目、專輯或藝術家...',
        ),
        const SizedBox(height: LuminaTokens.spaceSm),
        Expanded(
          child: filtered.isEmpty
              ? _buildEmptyState(
                  icon: Icons.library_music_outlined,
                  title: '目前尚無已同步的 ${widget.provider.name} 曲目',
                  subtitle: '點擊上方「同步曲庫」即可匯入您的串流收藏與高解析曲目。',
                  actionLabel: '同步 ${widget.provider.name} 曲庫',
                  onAction: _syncing ? null : _syncCatalog,
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(
                    bottom: LuminaTokens.bottomScrollClearance,
                  ),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) => _buildTrackTile(
                    filtered[index],
                    queueContext: filtered,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildPlaylistsTab(StreamingProvider? liveProvider) {
    final activePlaylist = _activePlaylist;
    if (activePlaylist != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              OutlinedButton.icon(
                key: const Key('btn_back_to_playlists'),
                onPressed: () => setState(() {
                  _activePlaylist = null;
                  _playlistError = null;
                }),
                style: OutlinedButton.styleFrom(
                  foregroundColor: LuminaTokens.textPrimary,
                  side: const BorderSide(color: LuminaTokens.borderControl),
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
          if (_playlistError != null) ...[
            const SizedBox(height: LuminaTokens.spaceSm),
            _buildErrorBanner(_playlistError!),
          ],
          const SizedBox(height: LuminaTokens.spaceSm),
          Expanded(
            child: _loadingPlaylist
                ? const Center(
                    child: CircularProgressIndicator(
                      color: LuminaTokens.accentBlue,
                    ),
                  )
                : _playlistTracks.isEmpty
                    ? _buildEmptyState(
                        icon: Icons.queue_music_rounded,
                        title: '此歌單目前沒有可顯示的曲目',
                        subtitle: '您可以回到歌單列表或重新同步曲庫。',
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(
                          bottom: LuminaTokens.bottomScrollClearance,
                        ),
                        itemCount: _playlistTracks.length,
                        itemBuilder: (context, index) => _buildTrackTile(
                          _playlistTracks[index],
                          queueContext: _playlistTracks,
                        ),
                      ),
          ),
        ],
      );
    }

    final playlists =
        liveProvider?.catalog.playlists ?? const <StreamingPlaylist>[];
    if (playlists.isEmpty) {
      return _buildEmptyState(
        icon: Icons.queue_music_rounded,
        title: '目前尚無已同步的 ${widget.provider.name} 歌單',
        subtitle: '點擊上方「同步曲庫」以載入您的線上歌單。',
        actionLabel: '同步 ${widget.provider.name} 曲庫',
        onAction: _syncing ? null : _syncCatalog,
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: LuminaTokens.bottomScrollClearance),
      itemCount: playlists.length,
      itemBuilder: (context, index) {
        final pl = playlists[index];
        return Material(
          type: MaterialType.transparency,
          child: ListTile(
            key: Key('streaming_playlist_${pl.id}'),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
            ),
            hoverColor: LuminaTokens.cardHoverBg.withValues(alpha: 0.6),
            leading: _buildThumbnail(
              pl.coverUrl,
              fallbackIcon: Icons.queue_music_rounded,
            ),
            title: Text(
              pl.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: LuminaTokens.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              pl.description != null && pl.description!.trim().isNotEmpty
                  ? pl.description!
                  : '${pl.trackCount} 首曲目',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: LuminaTokens.textMuted),
            ),
            trailing: const Icon(
              Icons.chevron_right_rounded,
              color: LuminaTokens.textSecondary,
            ),
            onTap: () => _openPlaylist(pl),
          ),
        );
      },
    );
  }

  Widget _buildAlbumsTab(StreamingProvider? liveProvider) {
    final albums = liveProvider?.catalog.albums ?? const <StreamingAlbum>[];
    if (albums.isEmpty) {
      return _buildEmptyState(
        icon: Icons.album_outlined,
        title: '目前尚無已同步的 ${widget.provider.name} 專輯',
        subtitle: '點擊上方「同步曲庫」以載入您收藏的串流專輯。',
        actionLabel: '同步 ${widget.provider.name} 曲庫',
        onAction: _syncing ? null : _syncCatalog,
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: LuminaTokens.bottomScrollClearance),
      itemCount: albums.length,
      itemBuilder: (context, index) {
        final alb = albums[index];
        final metaParts = <String>[
          alb.artist,
          if (alb.year != null) '${alb.year}',
          if (alb.trackCount != null) '${alb.trackCount} 首',
        ];
        return Material(
          type: MaterialType.transparency,
          child: ListTile(
            key: Key('streaming_album_${alb.id}'),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
            ),
            hoverColor: LuminaTokens.cardHoverBg.withValues(alpha: 0.6),
            leading: _buildThumbnail(
              alb.coverUrl,
              fallbackIcon: Icons.album_rounded,
            ),
            title: Text(
              alb.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: LuminaTokens.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              metaParts.join(' • '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: LuminaTokens.textMuted),
            ),
            trailing: alb.qualityLabel != null && alb.qualityLabel!.isNotEmpty
                ? Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: LuminaTokens.cardElevatedBg,
                      borderRadius: BorderRadius.circular(
                        LuminaTokens.radiusPill,
                      ),
                      border: Border.all(color: LuminaTokens.borderControl),
                    ),
                    child: Text(
                      alb.qualityLabel!,
                      style: const TextStyle(
                        color: LuminaTokens.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  )
                : null,
            onTap: widget.onOpenStreamingAlbum != null
                ? () => widget.onOpenStreamingAlbum!(alb)
                : null,
          ),
        );
      },
    );
  }

  Widget _buildRemoteSearchTab() {
    final result = _remoteSearchResult;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final field = TextField(
              key: const Key('streaming_remote_search_input'),
              controller: _remoteSearchCtrl,
              onSubmitted: (_) => _runRemoteSearch(),
              style: const TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 13,
              ),
              decoration: InputDecoration(
                prefixIcon: const Icon(
                  Icons.travel_explore_rounded,
                  color: LuminaTokens.textMuted,
                  size: 18,
                ),
                hintText: '即時搜尋 ${widget.provider.name} 線上曲庫...',
                hintStyle: const TextStyle(color: LuminaTokens.textMuted),
                filled: true,
                fillColor: LuminaTokens.cardBg,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: LuminaTokens.spaceSm,
                  vertical: LuminaTokens.spaceSm,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
                  borderSide: const BorderSide(color: LuminaTokens.borderControl),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
                  borderSide: const BorderSide(color: LuminaTokens.borderControl),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
                  borderSide: const BorderSide(
                    color: LuminaTokens.focusRing,
                    width: 1.5,
                  ),
                ),
              ),
            );
            final btn = FilledButton.icon(
              key: const Key('btn_streaming_remote_search'),
              onPressed: _searchingRemote ? null : _runRemoteSearch,
              style: FilledButton.styleFrom(
                backgroundColor: LuminaTokens.accentBlue,
                foregroundColor: LuminaTokens.onAccentDark,
              ),
              icon: _searchingRemote
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: LuminaTokens.onAccentDark,
                      ),
                    )
                  : const Icon(Icons.search_rounded, size: 17),
              label: const Text('搜尋'),
            );

            if (constraints.maxWidth < 400) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  field,
                  const SizedBox(height: LuminaTokens.spaceXs),
                  Align(alignment: Alignment.centerRight, child: btn),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: field),
                const SizedBox(width: LuminaTokens.spaceSm),
                btn,
              ],
            );
          },
        ),
        if (_remoteSearchError != null) ...[
          const SizedBox(height: LuminaTokens.spaceSm),
          _buildErrorBanner(_remoteSearchError!),
        ],
        const SizedBox(height: LuminaTokens.spaceSm),
        Expanded(
          child: _searchingRemote
              ? const Center(
                  child: CircularProgressIndicator(
                    color: LuminaTokens.accentBlue,
                  ),
                )
              : result == null
                  ? _buildEmptyState(
                      icon: Icons.travel_explore_rounded,
                      title: '輸入關鍵字搜尋 ${widget.provider.name} 線上曲目',
                      subtitle: '支援即時向平台 API 查詢高解析無損音軌與專輯。',
                    )
                  : (result.tracks.isEmpty && result.albums.isEmpty)
                      ? _buildEmptyState(
                          icon: Icons.search_off_rounded,
                          title: '找不到符合的線上結果',
                          subtitle: '請嘗試其他曲名、藝術家或專輯名稱。',
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.only(
                            bottom: LuminaTokens.bottomScrollClearance,
                          ),
                          itemCount:
                              result.tracks.length + result.albums.length,
                          itemBuilder: (context, index) {
                            if (index < result.tracks.length) {
                              return _buildTrackTile(
                                result.tracks[index],
                                queueContext: result.tracks,
                              );
                            }
                            final alb =
                                result.albums[index - result.tracks.length];
                            return Material(
                              type: MaterialType.transparency,
                              child: ListTile(
                                key: Key('streaming_search_album_${alb.id}'),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    LuminaTokens.radiusSm,
                                  ),
                                ),
                                leading: _buildThumbnail(
                                  alb.coverUrl,
                                  fallbackIcon: Icons.album_rounded,
                                ),
                                title: Text(
                                  alb.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: LuminaTokens.textPrimary,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: Text(
                                  '專輯 • ${alb.artist}${alb.qualityLabel != null ? ' • ${alb.qualityLabel}' : ''}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: LuminaTokens.textMuted,
                                  ),
                                ),
                                onTap: widget.onOpenStreamingAlbum != null
                                    ? () => widget.onOpenStreamingAlbum!(alb)
                                    : null,
                              ),
                            );
                          },
                        ),
        ),
      ],
    );
  }

  Widget _buildTrackTile(TrackInfo item, {List<TrackInfo>? queueContext}) {
    final isSelected = widget.activeTrackId == item.id;
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        key: Key('streaming_track_${item.id}'),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        ),
        hoverColor: LuminaTokens.cardHoverBg.withValues(alpha: 0.6),
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            widget.provider.buildBadge(boxSize: 18, borderRadius: 4),
            const SizedBox(width: 8),
            isSelected
                ? Icon(
                    Icons.equalizer_rounded,
                    color: widget.provider.badgeColor,
                    size: 22,
                  )
                : _buildThumbnail(
                    item.coverUrl ?? item.albumArtUrl,
                    size: 36,
                    fallbackIcon: Icons.music_note_rounded,
                  ),
          ],
        ),
        title: Text(
          item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isSelected
                ? LuminaTokens.accentBlue
                : LuminaTokens.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          '${item.artist} • ${item.album} • ${item.format.label}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: LuminaTokens.textMuted),
        ),
        trailing: const Icon(
          Icons.play_arrow_rounded,
          color: LuminaTokens.textSecondary,
        ),
        onTap: () => _playTrack(item, queueContext: queueContext),
      ),
    );
  }

  Widget _buildThumbnail(
    String? url, {
    double size = 40,
    required IconData fallbackIcon,
  }) {
    final trimmed = url?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: LuminaTokens.cardElevatedBg,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(
          fallbackIcon,
          color: LuminaTokens.textSecondary,
          size: size * 0.55,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        trimmed,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          width: size,
          height: size,
          color: LuminaTokens.cardElevatedBg,
          child: Icon(
            fallbackIcon,
            color: LuminaTokens.textSecondary,
            size: size * 0.55,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(LuminaTokens.spaceMd),
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
                fontSize: 14,
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
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: LuminaTokens.spaceMd),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: LuminaTokens.accentBlue,
                  foregroundColor: LuminaTokens.onAccentDark,
                ),
                onPressed: onAction,
                icon: const Icon(Icons.sync_rounded, size: 17),
                label: Text(actionLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
