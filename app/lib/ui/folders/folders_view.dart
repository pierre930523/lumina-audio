import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../common/frosted_glass_container.dart';
import '../common/track_context_menu.dart';
import '../tags/tag_picker_dialog.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';

part 'folders_view_widgets.dart';

/// Physical directory tree browser over indexed local library folders.
class FoldersView extends StatefulWidget {
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final String? initialFolderId;
  final ValueChanged<String?>? onFolderChanged;
  final void Function(String albumId)? onOpenAlbumDetail;
  final void Function(String artistName)? onOpenArtist;
  final VoidCallback? onOpenLibrarySettings;

  const FoldersView({
    super.key,
    required this.audioService,
    this.libraryCache,
    this.initialFolderId,
    this.onFolderChanged,
    this.onOpenAlbumDetail,
    this.onOpenArtist,
    this.onOpenLibrarySettings,
  });

  @override
  State<FoldersView> createState() => _FoldersViewState();
}

class _FoldersViewState extends State<FoldersView> {
  final GlideScrollController _rootsScrollController = GlideScrollController();
  final GlideScrollController _contentsScrollController =
      GlideScrollController();
  final GlideScrollController _breadcrumbScrollController =
      GlideScrollController();
  List<FolderNode> _roots = const <FolderNode>[];
  String? _currentFolderId;
  FolderContentsResponse? _contents;
  bool _loading = true;
  bool _playingFolder = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initLoad();
  }

  @override
  void dispose() {
    _rootsScrollController.dispose();
    _contentsScrollController.dispose();
    _breadcrumbScrollController.dispose();
    super.dispose();
  }

  Future<void> _initLoad() async {
    await _loadRoots();
    final initial = widget.initialFolderId;
    if (mounted && initial != null && initial.isNotEmpty) {
      await _openFolder(initial);
    }
  }

  Future<void> _loadRoots() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      final roots = await widget.audioService.getFolderRoots();
      if (!mounted) return;
      setState(() {
        _roots = roots;
        _currentFolderId = null;
        _contents = null;
        _loading = false;
      });
      widget.onFolderChanged?.call(null);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '載入資料夾根目錄失敗：$e';
        _loading = false;
      });
    }
  }

  Future<void> _openFolder(String folderId) async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      final res = await widget.audioService.getFolderContents(folderId);
      if (!mounted) return;
      setState(() {
        _currentFolderId = folderId;
        _contents = res;
        _loading = false;
      });
      widget.onFolderChanged?.call(folderId);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = '載入資料夾內容失敗：$e';
        _loading = false;
      });
    }
  }

  Future<void> _playFolder(String folderId) async {
    if (_playingFolder) return;
    setState(() => _playingFolder = true);
    try {
      final trackIds = await widget.audioService.getFolderRecursiveTrackIds(
        folderId,
      );
      if (!mounted) return;
      if (trackIds.isEmpty) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('此資料夾內找不到可播放曲目')),
        );
        return;
      }

      final byId = <String, TrackInfo>{};
      for (final t in _contents?.tracks ?? const <TrackInfo>[]) {
        byId[t.id] = t;
      }
      for (final t in widget.audioService.queue) {
        byId.putIfAbsent(t.id, () => t);
      }
      if (trackIds.any((id) => !byId.containsKey(id))) {
        final libraryTracks = await widget.audioService.getLibraryTracksFiltered(
          limit: 10000,
          includeHidden: widget.libraryCache?.includeHidden ?? false,
        );
        for (final t in libraryTracks) {
          byId.putIfAbsent(t.id, () => t);
        }
      }

      final resolved = trackIds
          .map((id) => byId[id])
          .whereType<TrackInfo>()
          .toList(growable: false);
      if (!mounted) return;
      if (resolved.isEmpty) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('找不到此資料夾對應的曲目資料')),
        );
        return;
      }

      final playable = resolved
          .where((t) => t.preference != -1)
          .toList(growable: false);
      if (playable.isEmpty) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('此資料夾內所有曲目皆已封鎖')),
        );
        return;
      }

      await widget.audioService.playQueue(resolved, excludeBanned: true);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text('開始播放資料夾（共 ${playable.length} 首曲目）'),
          duration: const Duration(seconds: 2),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _playingFolder = false);
      }
    }
  }

  Future<void> _jumpToAlbumForTrack(TrackInfo track) async {
    if (widget.onOpenAlbumDetail == null) return;
    var albumId = widget.libraryCache?.resolveAlbumIdForTrack(track);
    if (albumId == null || albumId.isEmpty) {
      final albums = await widget.audioService.getAlbums(limit: 500);
      final targetTitle = track.album.trim().toLowerCase();
      final match = albums
          .where((a) {
            final t = a.title.trim().toLowerCase();
            return t == targetTitle ||
                targetTitle.startsWith(t) ||
                t.startsWith(targetTitle);
          })
          .firstOrNull;
      albumId = match?.effectiveGroupId;
    }
    if (!mounted) return;
    if (albumId != null && albumId.isNotEmpty) {
      widget.onOpenAlbumDetail!(albumId);
    } else {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('找不到此曲目所屬的專輯頁面')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeFolder = _contents?.folder;
    final breadcrumbs = _contents?.breadcrumbs ?? const <FolderBreadcrumb>[];

    return Column(
      key: const Key('folders_view'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            LuminaTokens.spaceLg,
            LuminaTokens.spaceXs,
            LuminaTokens.spaceLg,
            LuminaTokens.spaceSm,
          ),
          child: Row(
            children: [
              const Icon(
                Icons.folder_rounded,
                size: 20,
                color: LuminaTokens.accentBlue,
              ),
              const SizedBox(width: 8),
              const Text(
                '實體資料夾',
                style: TextStyle(
                  color: LuminaTokens.glassTextPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (_currentFolderId != null)
                FilledButton.icon(
                  key: const Key('btn_play_current_folder'),
                  onPressed: _playingFolder
                      ? null
                      : () => _playFolder(_currentFolderId!),
                  style: FilledButton.styleFrom(
                    backgroundColor: LuminaTokens.glassSwitchOnTrack,
                    foregroundColor: LuminaTokens.onAccentDark,
                  ),
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('播放此資料夾', style: TextStyle(fontSize: 12.5)),
                ),
            ],
          ),
        ),
        _buildBreadcrumbBar(breadcrumbs),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LuminaTokens.spaceLg,
              LuminaTokens.spaceXs,
              LuminaTokens.spaceLg,
              0,
            ),
            child: Text(
              _errorMessage!,
              style: const TextStyle(
                color: LuminaTokens.statusError,
                fontSize: 12.5,
              ),
            ),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : _currentFolderId == null
              ? _buildRootsList()
              : _buildFolderContents(activeFolder),
        ),
      ],
    );
  }
}
