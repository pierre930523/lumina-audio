import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/streaming_models.dart';
import '../../models/streaming_provider_meta.dart';
import '../../services/audio_service.dart';
import '../../services/listen_later_controller.dart';
import '../../services/streaming/streaming_manager.dart';
import '../../services/streaming/streaming_provider.dart';
import '../artwork/streaming_cover_image.dart';
import '../common/frosted_glass_container.dart';
import '../common/track_context_menu.dart';
import '../common/track_hover_prefetch.dart';
import '../settings/streaming_login_dialog.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';

part 'streaming_service_actions.dart';
part 'streaming_toolbar.dart';
part 'streaming_toolbar_controls.dart';
part 'streaming_notices.dart';
part 'streaming_explore_tracks_tabs.dart';
part 'streaming_rec_widgets.dart';
part 'streaming_playlists_albums_tabs.dart';
part 'streaming_album_cards.dart';
part 'streaming_track_banner_widgets.dart';

class StreamingServiceView extends StatefulWidget {
  final AudioService audioService;
  final StreamingProviderMeta provider;
  final StreamingManager? streamingManager;
  final ListenLaterController? listenLaterController;
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
    this.listenLaterController,
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

  final GlideScrollController _scrollController = GlideScrollController();
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

  @override
  void dispose() {
    widget.streamingManager?.removeListener(_onManagerChanged);
    _filterFocusNode.removeListener(_onFilterFocusChanged);
    _filterFocusNode.dispose();
    _filterCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _setState(VoidCallback fn) => setState(fn);

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
}
