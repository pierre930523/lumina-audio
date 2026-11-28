import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/ingestion_models.dart';
import '../../models/playback_state.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../../services/library_settings_controller.dart';
import '../../services/smart_playlist_service.dart';
import '../common/bulk_edit_dialog.dart';
import '../common/library_export_dialog.dart';
import '../focus/focus_controller.dart';
import '../focus/focus_filter_drawer.dart';
import '../focus/focus_toolbar.dart';
import '../playlists/smart_playlists_view.dart';
import '../tags/tag_picker_dialog.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';
import 'library_track_row.dart';
import 'track_selection_bar.dart';

part 'library_browser_actions.dart';

class LibraryBrowserView extends StatefulWidget {
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final String? activeTrackId;
  final LibrarySettingsController? librarySettings;
  final SmartPlaylistService? playlistService;
  final FocusQuery? initialFocusQuery;
  final String? initialViewStateJson;
  final String? editingSmartPlaylistId;
  final ValueChanged<FocusQuery>? onFocusQueryChanged;
  final ValueChanged<String?>? onViewStateChanged;
  final VoidCallback? onCancelEditSmartPlaylist;
  final ValueChanged<SmartPlaylistItem>? onSavedSmartPlaylist;
  final VoidCallback? onOpenLibrarySettings;
  final void Function(String albumId)? onOpenAlbumDetail;
  final void Function(String artistName)? onOpenArtist;

  const LibraryBrowserView({
    super.key,
    required this.audioService,
    this.libraryCache,
    this.activeTrackId,
    this.librarySettings,
    this.playlistService,
    this.initialFocusQuery,
    this.initialViewStateJson,
    this.editingSmartPlaylistId,
    this.onFocusQueryChanged,
    this.onViewStateChanged,
    this.onCancelEditSmartPlaylist,
    this.onSavedSmartPlaylist,
    this.onOpenLibrarySettings,
    this.onOpenAlbumDetail,
    this.onOpenArtist,
  });

  @override
  State<LibraryBrowserView> createState() => _LibraryBrowserViewState();
}

class _LibraryBrowserViewState extends State<LibraryBrowserView> {
  static const Duration _searchDebounceDuration = Duration(milliseconds: 200);

  final TextEditingController _searchController = TextEditingController();
  final GlideScrollController _scrollController = GlideScrollController();
  final GlideScrollController _compactHeaderScrollController =
      GlideScrollController();
  late final FocusController _focusController;
  late List<TrackInfo> _visibleTracks;
  StreamSubscription<ScanProgressEvent>? _scanProgressSub;
  StreamSubscription<List<TrackInfo>>? _queueUpdatedSub;
  StreamSubscription<void>? _libraryReloadedSub;
  Timer? _searchDebounceTimer;
  int _searchSeq = 0;
  int _loadSeq = 0;
  bool _lastIncludeHidden = false;
  bool _multiSelectMode = false;
  final Set<String> _selectedTrackIds = <String>{};
  int? _lastSelectedIndex;

  @override
  void initState() {
    super.initState();
    _restoreViewState(widget.initialViewStateJson);
    _visibleTracks = List<TrackInfo>.from(widget.audioService.libraryTracks);
    _lastIncludeHidden = widget.libraryCache?.includeHidden ?? false;
    _focusController = FocusController(
      audioService: widget.audioService,
      entity: FocusEntity.tracks,
      initialQuery: widget.initialFocusQuery,
      includeHidden: _lastIncludeHidden,
    )..addListener(_onFocusChanged);
    _focusController.initialize();
    widget.libraryCache?.addListener(_onLibraryCacheChanged);
    _subscribeToAudioService();
    if (_searchController.text.trim().isNotEmpty) {
      unawaited(_executeSearch(_searchController.text.trim(), ++_searchSeq));
    } else {
      unawaited(_loadLibraryTracks());
    }
  }

  @override
  void didUpdateWidget(covariant LibraryBrowserView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.libraryCache != widget.libraryCache) {
      oldWidget.libraryCache?.removeListener(_onLibraryCacheChanged);
      _lastIncludeHidden = widget.libraryCache?.includeHidden ?? false;
      _focusController.setIncludeHidden(_lastIncludeHidden);
      widget.libraryCache?.addListener(_onLibraryCacheChanged);
    }
    if (oldWidget.audioService != widget.audioService) {
      _subscribeToAudioService();
      if (_searchController.text.trim().isEmpty) {
        _visibleTracks = List<TrackInfo>.from(
          widget.audioService.libraryTracks,
        );
        unawaited(_loadLibraryTracks());
      }
    } else if (_searchController.text.trim().isEmpty) {
      _visibleTracks = List<TrackInfo>.from(widget.audioService.libraryTracks);
    }
    if (widget.initialFocusQuery != null &&
        widget.initialFocusQuery != oldWidget.initialFocusQuery) {
      _focusController.applyInitialQuery(widget.initialFocusQuery!);
    }
    if (widget.initialViewStateJson != oldWidget.initialViewStateJson) {
      _restoreViewState(widget.initialViewStateJson);
    }
  }

  @override
  void dispose() {
    widget.libraryCache?.removeListener(_onLibraryCacheChanged);
    _scanProgressSub?.cancel();
    _scanProgressSub = null;
    _queueUpdatedSub?.cancel();
    _queueUpdatedSub = null;
    _libraryReloadedSub?.cancel();
    _libraryReloadedSub = null;
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = null;
    _searchController.dispose();
    _scrollController.dispose();
    _compactHeaderScrollController.dispose();
    _focusController
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    if (!mounted) return;
    widget.onFocusQueryChanged?.call(_focusController.query);
    setState(() {});
  }

  void _subscribeToAudioService() {
    _scanProgressSub?.cancel();
    _scanProgressSub = widget.audioService.scanProgressStream.listen(
      _onScanProgress,
    );
    _queueUpdatedSub?.cancel();
    _queueUpdatedSub = widget.audioService.queueUpdatedStream.listen((_) {
      if (!mounted || _searchController.text.trim().isNotEmpty) return;
      unawaited(_loadLibraryTracks());
    });
    _libraryReloadedSub?.cancel();
    _libraryReloadedSub = widget.audioService.libraryReloadedStream.listen((_) {
      unawaited(_refreshLibraryTracksView());
    });
  }

  void _onScanProgress(ScanProgressEvent event) {
    if (!mounted || event.state != ScanLifecycleState.completed) return;
    if (_focusController.isActive || _focusController.drawerOpen) {
      unawaited(_focusController.refresh(immediate: true));
    }
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      unawaited(_loadLibraryTracks());
    } else {
      unawaited(_executeSearch(query, ++_searchSeq));
    }
  }

  Future<void> _loadLibraryTracks() async {
    final seq = ++_loadSeq;
    final tracks = await widget.audioService.getLibraryTracksFiltered(
      limit: 10000,
      includeHidden: widget.libraryCache?.includeHidden ?? false,
    );
    if (!mounted || seq != _loadSeq) return;
    if (_searchController.text.trim().isNotEmpty) return;
    setState(() {
      _visibleTracks = tracks;
    });
  }

  void _onSearchChanged(String query) {
    widget.onViewStateChanged?.call(_encodeViewState());
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = null;
    final seq = ++_searchSeq;
    if (query.trim().isEmpty) {
      unawaited(_executeSearch('', seq));
      return;
    }
    _searchDebounceTimer = Timer(_searchDebounceDuration, () {
      _searchDebounceTimer = null;
      if (!mounted || seq != _searchSeq) return;
      unawaited(_executeSearch(query, seq));
    });
  }

  Future<void> _executeSearch(String query, int seq) async {
    final trimmed = query.trim();
    final results = trimmed.isEmpty
        ? await widget.audioService.getLibraryTracksFiltered(
            limit: 10000,
            includeHidden: widget.libraryCache?.includeHidden ?? false,
          )
        : await widget.audioService.searchLibrary(query);
    if (!mounted || seq != _searchSeq) return;
    setState(() {
      _visibleTracks = results;
    });
  }

  void _clearSearch() {
    _searchController.clear();
    _onSearchChanged('');
  }

  List<TrackInfo> _filteredTracks() {
    List<TrackInfo> source;
    if (_focusController.isActive) {
      source = _focusController.response?.tracks ?? const <TrackInfo>[];
      final kw = _searchController.text.trim().toLowerCase();
      if (kw.isNotEmpty) {
        source = source
            .where(
              (t) =>
                  t.title.toLowerCase().contains(kw) ||
                  t.artist.toLowerCase().contains(kw) ||
                  t.album.toLowerCase().contains(kw),
            )
            .toList(growable: false);
      }
    } else {
      source = _visibleTracks;
    }
    final settings = widget.librarySettings;
    if (settings == null || settings.excludedExtensions.isEmpty) {
      return source;
    }
    return source
        .where((t) => !settings.isTrackExcluded(t.filePath, t.format.codec.name))
        .toList(growable: false);
  }

  void _setState(VoidCallback fn) => setState(fn);

  @override
  Widget build(BuildContext context) {
    Widget buildBody(List<TrackInfo> tracks) {
      final selectedTracks = tracks
          .where((t) => _selectedTrackIds.contains(t.id))
          .toList(growable: false);
      final bottomPad = selectedTracks.isNotEmpty
          ? LuminaTokens.bottomScrollClearance + 80.0
          : LuminaTokens.bottomScrollClearance;

      final showSaveSmartBtn =
          _focusController.isActive &&
          widget.playlistService != null &&
          widget.editingSmartPlaylistId == null;

      final headerColumn = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LuminaTokens.spaceLg,
              vertical: LuminaTokens.spaceXs,
            ),
            child: Row(
              children: [
                Expanded(child: _buildSearchField()),
                const SizedBox(width: LuminaTokens.spaceXs),
                OutlinedButton.icon(
                  key: const Key('btn_track_multi_select'),
                  onPressed: _toggleMultiSelectMode,
                  style: OutlinedButton.styleFrom(
                    backgroundColor: _multiSelectMode
                        ? LuminaTokens.glassSegmentSelectedBg
                        : LuminaTokens.glassPillBg,
                    foregroundColor: _multiSelectMode
                        ? Colors.white
                        : LuminaTokens.glassTextPrimary,
                    side: BorderSide(
                      color: _multiSelectMode
                          ? LuminaTokens.accentBlue
                          : LuminaTokens.glassPillBorder,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  icon: Icon(
                    _multiSelectMode
                        ? Icons.check_box_rounded
                        : Icons.checklist_rounded,
                    size: 16,
                  ),
                  label: Text(_multiSelectMode ? '完成多選' : '多選'),
                ),
                if (widget.onOpenLibrarySettings != null) ...[
                  const SizedBox(width: LuminaTokens.spaceXs),
                  IconButton.outlined(
                    key: const Key('btn_open_library_settings'),
                    tooltip: '資料夾與掃描設定',
                    onPressed: widget.onOpenLibrarySettings,
                    icon: const Icon(Icons.folder_open_rounded, size: 18),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: LuminaTokens.glassPillBg,
                      foregroundColor: LuminaTokens.glassTextPrimary,
                      side: const BorderSide(
                        color: LuminaTokens.glassPillBorder,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LuminaTokens.spaceLg,
              0,
              LuminaTokens.spaceLg,
              LuminaTokens.spaceXs,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.editingSmartPlaylistId != null)
                  _buildEditingSmartPlaylistBanner(),
                FocusToolbar(
                  controller: _focusController,
                  trailingWidgets: _buildFocusTrailingWidgets(showSaveSmartBtn),
                ),
                FocusFilterDrawer(controller: _focusController),
              ],
            ),
          ),
        ],
      );

      return LayoutBuilder(
        builder: (context, constraints) {
          final compactHeader =
              constraints.maxHeight.isFinite && constraints.maxHeight < 460;
          final headerWidget = compactHeader
              ? ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: math.max(0.0, constraints.maxHeight * 0.55),
                  ),
                  child: SmoothScrollWrapper(
                    controller: _compactHeaderScrollController,
                    child: SingleChildScrollView(
                      controller: _compactHeaderScrollController,
                      child: headerColumn,
                    ),
                  ),
                )
              : headerColumn;

          return Column(
            children: [
              headerWidget,
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: tracks.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(
                                  LuminaTokens.spaceLg,
                                ),
                                child: Text(
                                  _focusController.isActive
                                      ? '目前 Focus 篩選條件下找不到符合的曲目'
                                      : '找不到符合條件的曲目，您可在「設定 → 音樂庫」掃描更多資料夾',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: LuminaTokens.textMuted,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            )
                          : _buildTracksListView(tracks, bottomPad),
                    ),
                    if (selectedTracks.isNotEmpty)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: TrackSelectionBar(
                          selectedTracks: selectedTracks,
                          onPlaySelected: () =>
                              unawaited(_playSelectedTracks(selectedTracks)),
                          onAddToQueue: () =>
                              unawaited(_addTracksToQueue(selectedTracks)),
                          onManageTags: () =>
                              unawaited(_manageTrackTags(selectedTracks)),
                          onBulkEdit: () =>
                              unawaited(_bulkEditTracks(selectedTracks)),
                          onExport: () =>
                              unawaited(_exportTracks(selectedTracks)),
                          onClearSelection: _clearSelection,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      );
    }

    if (widget.librarySettings == null) {
      return buildBody(_filteredTracks());
    }

    return ListenableBuilder(
      listenable: widget.librarySettings!,
      builder: (context, _) => buildBody(_filteredTracks()),
    );
  }
}
