import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/audio_format.dart';
import '../../models/ingestion_models.dart';
import '../../models/playback_state.dart';
import '../../models/studio_models.dart';
import '../../services/album_layout_settings_controller.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../../services/listen_later_controller.dart';
import '../common/bulk_edit_dialog.dart';
import '../common/library_export_dialog.dart';
import '../focus/focus_controller.dart';
import '../focus/focus_filter_drawer.dart';
import '../focus/focus_toolbar.dart';
import '../tags/tag_picker_dialog.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';
import 'album_collection_card.dart';
import 'album_detail_page.dart';
import 'album_layout_popover.dart';
import 'album_merge_dialog.dart';
import 'album_selection_bar.dart';

part 'albums_and_credits_credits_section.dart';
part 'albums_and_credits_grouping_actions.dart';
part 'albums_and_credits_sections.dart';

class AlbumsAndCreditsView extends StatefulWidget {
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final AlbumLayoutSettingsController? layoutController;
  final ListenLaterController? listenLaterController;
  final bool startInCreditsMode;
  final void Function(String albumId)? onOpenAlbumDetail;
  final void Function(String artistName)? onOpenArtist;
  final String? initialArtistId;
  final FocusQuery? initialFocusQuery;
  final String? initialViewStateJson;
  final ValueChanged<FocusQuery>? onFocusQueryChanged;
  final ValueChanged<String?>? onViewStateChanged;
  final double initialScrollOffset;
  final ValueChanged<double>? onScrollOffsetChanged;

  const AlbumsAndCreditsView({
    super.key,
    this.onOpenAlbumDetail,
    this.onOpenArtist,
    this.initialArtistId,
    this.initialFocusQuery,
    this.initialViewStateJson,
    this.onFocusQueryChanged,
    this.onViewStateChanged,
    required this.audioService,
    this.libraryCache,
    this.layoutController,
    this.listenLaterController,
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
  bool _multiSelectMode = false;
  bool _groupingBusy = false;
  bool _lastShowHiddenAlbums = false;
  final Set<String> _selectedKeys = <String>{};
  int? _lastSelectedIndex;
  late final GlideScrollController _scrollController;
  late final GlideScrollController _creditsScrollController;
  late final GlideScrollController _compactHeaderScrollController;
  late final FocusController _focusController;
  late AlbumLayoutSettingsController _effectiveLayoutController;
  late bool _ownsLayoutController;
  StreamSubscription<ScanProgressEvent>? _scanProgressSub;
  final Set<String> _handledCompletedScanIds = <String>{};

  static bool _isValidAlbum(CanonicalAlbumSummary album) =>
      album.id.isNotEmpty && (album.trackCount == null || album.trackCount! > 0);

  @override
  void initState() {
    super.initState();
    _ownsLayoutController = widget.layoutController == null;
    _effectiveLayoutController =
        widget.layoutController ?? (AlbumLayoutSettingsController()..load());
    _applyInitialViewState(widget.initialViewStateJson);
    _lastShowHiddenAlbums = _effectiveLayoutController.showHiddenAlbums;
    _effectiveLayoutController.addListener(_onLayoutControllerChanged);
    _showCreditsGraph = widget.startInCreditsMode;
    _scrollController = GlideScrollController(
      initialScrollOffset: widget.startInCreditsMode
          ? 0.0
          : widget.initialScrollOffset,
    )..addListener(_handleScroll);
    _creditsScrollController = GlideScrollController(
      initialScrollOffset: widget.startInCreditsMode
          ? widget.initialScrollOffset
          : 0.0,
    )..addListener(_handleCreditsScroll);
    _compactHeaderScrollController = GlideScrollController();
    _focusController = FocusController(
      audioService: widget.audioService,
      entity: FocusEntity.albums,
      initialQuery: widget.initialFocusQuery,
      includeHidden: _lastShowHiddenAlbums,
    )..addListener(_onFocusChanged);
    _focusController.initialize();
    widget.libraryCache?.addListener(_onLibraryCacheChanged);
    _scanProgressSub = widget.audioService.scanProgressStream.listen(
      _onScanProgressEvent,
    );
    if (!widget.startInCreditsMode &&
        widget.libraryCache != null &&
        widget.libraryCache!.albums.isNotEmpty &&
        widget.libraryCache!.includeHidden == _lastShowHiddenAlbums) {
      _albums = widget.libraryCache!.albums.where(_isValidAlbum).toList();
      _loading = false;
    }
    _loadData();
  }

  @override
  void dispose() {
    _scanProgressSub?.cancel();
    _scanProgressSub = null;
    widget.libraryCache?.removeListener(_onLibraryCacheChanged);
    _effectiveLayoutController.removeListener(_onLayoutControllerChanged);
    if (_ownsLayoutController) {
      _effectiveLayoutController.dispose();
    }
    _scrollController
      ..removeListener(_handleScroll)
      ..dispose();
    _creditsScrollController
      ..removeListener(_handleCreditsScroll)
      ..dispose();
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

  List<CanonicalAlbumSummary> get _displayedAlbums => _focusController.isActive
      ? (_focusController.response?.albums ?? const <CanonicalAlbumSummary>[])
      : _albums;

  void _onLibraryCacheChanged() {
    if (!mounted) return;
    final cache = widget.libraryCache;
    if (cache == null) return;
    setState(() {
      _albums = cache.albums.where(_isValidAlbum).toList();
      _coverRevision++;
      _loading = false;
    });
  }

  void _onScanProgressEvent(ScanProgressEvent event) {
    if (!mounted || event.state != ScanLifecycleState.completed) return;
    final sid = event.scanId.trim();
    if (sid.isNotEmpty) {
      if (!_handledCompletedScanIds.add(sid)) return;
      if (_handledCompletedScanIds.length > 64) {
        _handledCompletedScanIds.remove(_handledCompletedScanIds.first);
      }
    }
    final cache = widget.libraryCache;
    if (cache != null) {
      unawaited(cache.refresh(widget.audioService));
    } else {
      unawaited(_loadData());
    }
  }

  void _handleScroll() {
    if (!_showCreditsGraph && _scrollController.positions.length == 1) {
      widget.onScrollOffsetChanged?.call(_scrollController.offset);
    }
  }

  void _handleCreditsScroll() {
    if (_showCreditsGraph && _creditsScrollController.positions.length == 1) {
      widget.onScrollOffsetChanged?.call(_creditsScrollController.offset);
    }
  }

  @override
  void didUpdateWidget(covariant AlbumsAndCreditsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.libraryCache != widget.libraryCache) {
      oldWidget.libraryCache?.removeListener(_onLibraryCacheChanged);
      widget.libraryCache?.addListener(_onLibraryCacheChanged);
    }
    if (oldWidget.audioService != widget.audioService) {
      _scanProgressSub?.cancel();
      _scanProgressSub = widget.audioService.scanProgressStream.listen(
        _onScanProgressEvent,
      );
    }
    if (oldWidget.layoutController != widget.layoutController) {
      _effectiveLayoutController.removeListener(_onLayoutControllerChanged);
      if (_ownsLayoutController) {
        _effectiveLayoutController.dispose();
      }
      _ownsLayoutController = widget.layoutController == null;
      _effectiveLayoutController =
          widget.layoutController ?? (AlbumLayoutSettingsController()..load());
      _lastShowHiddenAlbums = _effectiveLayoutController.showHiddenAlbums;
      _effectiveLayoutController.addListener(_onLayoutControllerChanged);
    }
    if (oldWidget.startInCreditsMode != widget.startInCreditsMode) {
      setState(() {
        _showCreditsGraph = widget.startInCreditsMode;
      });
    }
    if (widget.initialFocusQuery != null &&
        widget.initialFocusQuery != oldWidget.initialFocusQuery) {
      _focusController.applyInitialQuery(widget.initialFocusQuery!);
    }
    if (widget.initialViewStateJson != oldWidget.initialViewStateJson) {
      _applyInitialViewState(widget.initialViewStateJson);
    }
  }

  Future<void> _loadData() async {
    final showHidden = _effectiveLayoutController.showHiddenAlbums;
    widget.libraryCache?.setIncludeHiddenSync(showHidden);
    final albums = (await widget.audioService.getAlbums(
      limit: 500,
      includeHidden: showHidden,
    )).where(_isValidAlbum).toList();
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
          backgroundColor: LuminaTokens.canvasBg,
          body: SafeArea(
            child: AlbumDetailPage(
              albumId: albumId,
              audioService: widget.audioService,
              listenLaterController: widget.listenLaterController,
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

  void _setState(VoidCallback fn) => setState(fn);

  @override
  Widget build(BuildContext context) => _buildView(context);
}
