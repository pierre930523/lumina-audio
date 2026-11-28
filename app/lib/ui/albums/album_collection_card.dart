import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../../services/listen_later_controller.dart';
import '../artwork/album_artwork_view.dart';
import '../common/lumina_context_menu.dart';
import '../common/preference_toggle_button.dart';
import '../tags/tag_picker_dialog.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';
import 'album_status_badges.dart';

part 'album_collection_card_parts.dart';
part 'album_collection_card_glow.dart';
part 'album_collection_list_tile.dart';

Future<void> _showAlbumContextMenu({
  required BuildContext buttonContext,
  Offset? globalPosition,
  required VoidCallback onPlayAlbum,
  VoidCallback? onAddToQueue,
  VoidCallback? onAddToListenLater,
  Future<void> Function(int pref)? onSetPreference,
  required VoidCallback onOpenAlbumDetail,
  VoidCallback? onOpenArtist,
  VoidCallback? onManageTags,
}) async {
  final action = await showLuminaContextMenu<String>(
    context: buttonContext,
    globalPosition: globalPosition,
    anchorContext: globalPosition == null ? buttonContext : null,
    menuKey: const Key('album_context_menu'),
    entries: [
      const LuminaContextMenuAction<String>(
        value: 'play',
        icon: Icons.play_arrow_rounded,
        label: '播放專輯',
      ),
      const LuminaContextMenuAction<String>(
        value: 'queue',
        icon: Icons.playlist_add_rounded,
        label: '加入播放佇列',
      ),
      if (onAddToListenLater != null)
        const LuminaContextMenuAction<String>(
          value: 'listen_later',
          icon: Icons.watch_later_outlined,
          label: '加入稍後收聽',
        ),
      if (onSetPreference != null) ...[
        const LuminaContextMenuDivider<String>(),
        const LuminaContextMenuAction<String>(
          value: 'pref_1',
          icon: Icons.favorite_rounded,
          label: '標記為喜愛',
        ),
        const LuminaContextMenuAction<String>(
          value: 'pref_0',
          icon: Icons.favorite_border_rounded,
          label: '設為普通',
        ),
        const LuminaContextMenuAction<String>(
          value: 'pref_-1',
          icon: Icons.block_rounded,
          label: '封鎖此專輯',
        ),
      ],
      const LuminaContextMenuDivider<String>(),
      const LuminaContextMenuAction<String>(
        value: 'detail',
        icon: Icons.album_rounded,
        label: '檢視專輯詳情',
      ),
      const LuminaContextMenuAction<String>(
        value: 'artist',
        icon: Icons.person_rounded,
        label: '前往藝術家',
      ),
      if (onManageTags != null)
        const LuminaContextMenuAction<String>(
          value: 'tags',
          icon: Icons.label_outlined,
          label: '管理標籤...',
        ),
    ],
  );
  switch (action) {
    case 'play':
      onPlayAlbum();
    case 'queue':
      onAddToQueue?.call();
    case 'listen_later':
      onAddToListenLater?.call();
    case 'pref_1':
      await onSetPreference?.call(1);
    case 'pref_0':
      await onSetPreference?.call(0);
    case 'pref_-1':
      await onSetPreference?.call(-1);
    case 'detail':
      onOpenAlbumDetail();
    case 'artist':
      onOpenArtist?.call();
    case 'tags':
      onManageTags?.call();
  }
}

String _albumSubtitle(CanonicalAlbumSummary album) {
  return album.year != null ? '${album.artist} (${album.year})' : album.artist;
}

/// Apple Music-inspired album grid card with frameless minimalist default,
/// lazy-mounted GPU-composited cover hover FX, and isolated per-card state.
class AlbumCollectionCard extends StatefulWidget {
  final CanonicalAlbumSummary album;
  final int coverRevision;
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final ListenLaterController? listenLaterController;
  final bool showCardContainer;
  final bool showHiddenMode;
  final bool multiSelectMode;
  final bool isSelected;
  final VoidCallback onOpenAlbumDetail;
  final VoidCallback? onTapCard;
  final VoidCallback? onToggleSelect;
  final VoidCallback onPlayAlbum;
  final VoidCallback? onAddToQueue;
  final VoidCallback? onOpenArtist;

  const AlbumCollectionCard({
    super.key,
    required this.album,
    required this.audioService,
    this.libraryCache,
    this.listenLaterController,
    this.coverRevision = 0,
    this.showCardContainer = false,
    this.showHiddenMode = false,
    this.multiSelectMode = false,
    this.isSelected = false,
    required this.onOpenAlbumDetail,
    this.onTapCard,
    this.onToggleSelect,
    required this.onPlayAlbum,
    this.onAddToQueue,
    this.onOpenArtist,
  });

  @override
  State<AlbumCollectionCard> createState() => _AlbumCollectionCardState();
}

class _AlbumCollectionCardState extends State<AlbumCollectionCard>
    with TickerProviderStateMixin {
  static const Duration _hoverDuration = Duration(milliseconds: 220);
  static const Duration _playHoverDuration = Duration(milliseconds: 180);
  static const Curve _appleCurve = Cubic(0.2, 0.8, 0.2, 1.0);
  static const BorderRadius _coverRadius = BorderRadius.all(
    Radius.circular(LuminaTokens.radiusSm),
  );

  late final AnimationController _hoverController;
  late final CurvedAnimation _hoverCurve;
  late final Animation<double> _coverScaleAnimation;
  late final Animation<double> _glowOpacityAnimation;
  late final Animation<double> _buttonSlideAnimation;

  late final AnimationController _playHoverController;
  late final CurvedAnimation _playHoverCurve;
  late final Animation<double> _playScaleAnimation;

  bool _coverHovered = false;
  bool _playHovered = false;
  bool _moreHovered = false;
  bool _menuOpen = false;
  bool _overlayMounted = false;

  String? _resolvedCachePath;
  String? _resolvedCoverUrl;

  @override
  void initState() {
    super.initState();
    _hoverController = AnimationController(
      vsync: this,
      duration: _hoverDuration,
    )..addStatusListener(_handleHoverStatusChanged);
    _hoverCurve = CurvedAnimation(
      parent: _hoverController,
      curve: _appleCurve,
    );
    _coverScaleAnimation = Tween<double>(
      begin: 1.0,
      end: 1.02,
    ).animate(_hoverCurve);
    _glowOpacityAnimation = Tween<double>(
      begin: 0.0,
      end: 0.58,
    ).animate(_hoverCurve);
    _buttonSlideAnimation = Tween<double>(
      begin: 5.0,
      end: 0.0,
    ).animate(_hoverCurve);

    _playHoverController = AnimationController(
      vsync: this,
      duration: _playHoverDuration,
    );
    _playHoverCurve = CurvedAnimation(
      parent: _playHoverController,
      curve: _appleCurve,
    );
    _playScaleAnimation = Tween<double>(
      begin: 1.0,
      end: 1.08,
    ).animate(_playHoverCurve);
  }

  @override
  void didUpdateWidget(covariant AlbumCollectionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.album.id != widget.album.id ||
        oldWidget.album.coverUrl != widget.album.coverUrl ||
        oldWidget.coverRevision != widget.coverRevision) {
      _resolvedCachePath = null;
      _resolvedCoverUrl = null;
    }
  }

  @override
  void dispose() {
    _hoverController.removeStatusListener(_handleHoverStatusChanged);
    _hoverCurve.dispose();
    _hoverController.dispose();
    _playHoverCurve.dispose();
    _playHoverController.dispose();
    super.dispose();
  }

  void _handleHoverStatusChanged(AnimationStatus status) {
    if (status == AnimationStatus.dismissed &&
        !_coverHovered &&
        !_menuOpen &&
        _overlayMounted) {
      if (!mounted) return;
      setState(() {
        _overlayMounted = false;
        _playHovered = false;
        _moreHovered = false;
      });
      _playHoverController.reset();
    }
  }

  void _handleArtworkResolved(String? cachePath, String? coverUrl) {
    if (_resolvedCachePath == cachePath && _resolvedCoverUrl == coverUrl) {
      return;
    }
    _resolvedCachePath = cachePath;
    _resolvedCoverUrl = coverUrl;
    if (_overlayMounted && mounted) {
      setState(() {});
    }
  }

  void _onCoverHoverEnter() {
    if (_coverHovered && _overlayMounted) return;
    setState(() {
      _coverHovered = true;
      _overlayMounted = true;
    });
    _hoverController.forward();
  }

  void _onCoverHoverExit() {
    if (!_coverHovered) return;
    _coverHovered = false;
    if (_playHovered) {
      _playHovered = false;
      _playHoverController.reverse();
    }
    if (_moreHovered) {
      setState(() => _moreHovered = false);
    }
    if (!_menuOpen) {
      _hoverController.reverse();
    }
  }

  void _setPlayHovered(bool hovered) {
    if (_playHovered == hovered) return;
    _playHovered = hovered;
    if (hovered) {
      _playHoverController.forward();
    } else {
      _playHoverController.reverse();
    }
  }

  Future<void> _addToListenLater() async {
    final ll = widget.listenLaterController;
    if (ll == null) return;
    await ll.addLocalAlbum(widget.album);
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text('已將「${widget.album.title}」加入稍後收聽'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _setAlbumPreference(int pref) async {
    final groupId = widget.album.effectiveGroupId;
    widget.libraryCache?.updateEntityPreferenceSync(
      'album_group',
      groupId,
      pref,
    );
    await widget.audioService.setEntityPreference('album_group', groupId, pref);
  }

  Future<void> _openMoreMenu(
    BuildContext btnCtx, {
    Offset? globalPosition,
  }) async {
    _menuOpen = true;
    await _showAlbumContextMenu(
      buttonContext: btnCtx,
      globalPosition: globalPosition,
      onPlayAlbum: widget.onPlayAlbum,
      onAddToQueue: widget.onAddToQueue,
      onAddToListenLater:
          widget.listenLaterController != null ? _addToListenLater : null,
      onSetPreference: _setAlbumPreference,
      onOpenAlbumDetail: widget.onOpenAlbumDetail,
      onOpenArtist: widget.onOpenArtist,
      onManageTags: () => showTagPickerDialog(
        context: context,
        audioService: widget.audioService,
        entityType: TagEntityType.albumGroup,
        entityIds: <String>[widget.album.effectiveGroupId],
        title: '管理專輯標籤：${widget.album.title}',
      ),
    );
    _menuOpen = false;
    if (!mounted) return;
    if (!_coverHovered) {
      _hoverController.reverse();
    }
  }

  void _setState(VoidCallback fn) => setState(fn);

  @override
  Widget build(BuildContext context) => _buildCard(context);
}
