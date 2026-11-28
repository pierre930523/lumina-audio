import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../models/ingestion_models.dart';
import '../../models/playback_state.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_tokens.dart';

part 'track_info_editor_tab_options.dart';
part 'track_info_editor_tab_policy.dart';
part 'track_info_editor_tab_edit.dart';

/// Opens the 3-tab single-track settings modal ("單曲設定"):
/// 1. 曲目選項 (Visibility + Rescan / Re-identify / Re-analyze / Delete)
/// 2. 詮釋資料偏好設定 (Per-track `meta_policy` with live resolved diff)
/// 3. 編輯曲目 (Non-destructive `user_edits_json` editor + Restore file tags)
Future<void> showTrackInfoEditorDialog({
  required BuildContext context,
  required AudioService audioService,
  required TrackInfo track,
  LibraryIndexCache? libraryCache,
  int initialTabIndex = 0,
  void Function(TrackInfo updatedTrack)? onTrackUpdated,
  VoidCallback? onTrackDeleted,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: LuminaTokens.scrimBg,
    builder: (_) => _TrackInfoEditorDialog(
      audioService: audioService,
      track: track,
      libraryCache: libraryCache,
      initialTabIndex: initialTabIndex.clamp(0, 2),
      onTrackUpdated: onTrackUpdated,
      onTrackDeleted: onTrackDeleted,
    ),
  );
}

class _TrackInfoEditorDialog extends StatefulWidget {
  final AudioService audioService;
  final TrackInfo track;
  final LibraryIndexCache? libraryCache;
  final int initialTabIndex;
  final void Function(TrackInfo updatedTrack)? onTrackUpdated;
  final VoidCallback? onTrackDeleted;

  const _TrackInfoEditorDialog({
    required this.audioService,
    required this.track,
    this.libraryCache,
    this.initialTabIndex = 0,
    this.onTrackUpdated,
    this.onTrackDeleted,
  });

  @override
  State<_TrackInfoEditorDialog> createState() => _TrackInfoEditorDialogState();
}

class _TrackInfoEditorDialogState extends State<_TrackInfoEditorDialog>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  TrackFileInfo? _fileInfo;
  bool _loading = true;
  bool _busy = false;
  String? _statusMessage;
  bool _statusIsError = false;

  late final TextEditingController _titleCtrl;
  late final TextEditingController _artistCtrl;
  late final TextEditingController _albumArtistCtrl;
  late final TextEditingController _composerCtrl;
  late final TextEditingController _trackNumberCtrl;
  late final TextEditingController _discNumberCtrl;
  late final TextEditingController _yearCtrl;
  late final TextEditingController _genreCtrl;
  late final TextEditingController _lyricsCtrl;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTabIndex,
    );
    final t = widget.track;
    _titleCtrl = TextEditingController(text: t.title);
    _artistCtrl = TextEditingController(text: t.artist);
    _albumArtistCtrl = TextEditingController(text: t.albumArtist ?? '');
    _composerCtrl = TextEditingController(text: t.composer ?? '');
    _trackNumberCtrl = TextEditingController(
      text: t.trackNumber != null && t.trackNumber! > 0
          ? '${t.trackNumber}'
          : '',
    );
    _discNumberCtrl = TextEditingController(
      text: t.discNumber != null && t.discNumber! > 0 ? '${t.discNumber}' : '',
    );
    _yearCtrl = TextEditingController(text: t.year != null ? '${t.year}' : '');
    _genreCtrl = TextEditingController(text: t.genre ?? '');
    _lyricsCtrl = TextEditingController();
    _loadInfo(syncForm: true);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    _albumArtistCtrl.dispose();
    _composerCtrl.dispose();
    _trackNumberCtrl.dispose();
    _discNumberCtrl.dispose();
    _yearCtrl.dispose();
    _genreCtrl.dispose();
    _lyricsCtrl.dispose();
    super.dispose();
  }

  void _syncEditControllersFromInfo(TrackFileInfo info) {
    final eff = info.effectiveLayer;
    _titleCtrl.text = eff.title ?? widget.track.title;
    _artistCtrl.text = eff.artistName ?? widget.track.artist;
    _albumArtistCtrl.text = eff.albumArtist ?? widget.track.albumArtist ?? '';
    _composerCtrl.text = eff.composer ?? widget.track.composer ?? '';
    _trackNumberCtrl.text = eff.trackNumber != null && eff.trackNumber! > 0
        ? '${eff.trackNumber}'
        : '';
    _discNumberCtrl.text = eff.discNumber != null && eff.discNumber! > 0
        ? '${eff.discNumber}'
        : '';
    _yearCtrl.text = eff.releaseYear != null ? '${eff.releaseYear}' : '';
    _genreCtrl.text = eff.genre ?? widget.track.genre ?? '';
    _lyricsCtrl.text = eff.lyrics ?? '';
  }

  Future<void> _loadInfo({bool syncForm = false}) async {
    try {
      final info = await widget.audioService.getTrackFileInfo(widget.track.id);
      if (!mounted) return;
      setState(() {
        _fileInfo = info;
        _loading = false;
        if (syncForm && info != null) {
          _syncEditControllersFromInfo(info);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _statusMessage = '載入曲目設定失敗：$e';
        _statusIsError = true;
      });
    }
  }

  void _emitTrackUpdated(TrackFileInfo? info) {
    if (widget.libraryCache != null) {
      unawaited(widget.libraryCache!.refresh(widget.audioService));
    }
    if (info != null) {
      final eff = info.effectiveLayer;
      widget.onTrackUpdated?.call(
        widget.track.copyWith(
          title: eff.title ?? widget.track.title,
          artist: eff.artistName ?? widget.track.artist,
          album: eff.albumTitle ?? widget.track.album,
          albumArtist: eff.albumArtist ?? widget.track.albumArtist,
          genre: eff.genre ?? widget.track.genre,
          year: eff.releaseYear ?? widget.track.year,
          trackNumber: eff.trackNumber ?? widget.track.trackNumber,
          discNumber: eff.discNumber ?? widget.track.discNumber,
          composer: eff.composer ?? widget.track.composer,
          hasLyrics:
              (eff.lyrics != null && eff.lyrics!.trim().isNotEmpty) ||
              widget.track.hasLyrics,
        ),
      );
    }
  }

  Future<void> _applyTrackMetaPolicy(MetadataPolicy policy) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _statusMessage = null;
      _statusIsError = false;
    });
    try {
      final res = await widget.audioService.applyBulkEdit(
        BulkEditEntityType.track,
        <String>[widget.track.id],
        BulkEditPatch(metaPolicy: FieldPatchOp<String>.set(policy.toJson())),
      );
      final updated = await widget.audioService.getTrackFileInfo(
        widget.track.id,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (updated != null) {
          _fileInfo = updated;
          _syncEditControllersFromInfo(updated);
        }
        _statusMessage = res != null ? '已更新詮釋資料偏好並即時重算顯示欄位' : '更新詮釋資料偏好失敗';
        _statusIsError = res == null;
      });
      if (res != null) {
        _emitTrackUpdated(updated);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _statusMessage = '更新詮釋資料偏好失敗：$e';
        _statusIsError = true;
      });
    }
  }

  void _setBusyAndStatus({
    bool? busy,
    String? status,
    bool isError = false,
    TrackFileInfo? fileInfo,
    bool syncForm = false,
  }) {
    if (!mounted) return;
    setState(() {
      if (busy != null) _busy = busy;
      _statusMessage = status;
      _statusIsError = isError;
      if (fileInfo != null) {
        _fileInfo = fileInfo;
        if (syncForm) {
          _syncEditControllersFromInfo(fileInfo);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final effTitle = _fileInfo?.effectiveLayer.title ?? widget.track.title;
    final effArtist =
        _fileInfo?.effectiveLayer.artistName ?? widget.track.artist;

    return Dialog(
      key: const Key('track_info_editor_dialog'),
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 680),
        child: FrostedGlassContainer(
          color: LuminaTokens.cardBg.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: LuminaTokens.borderControl),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.tune_rounded,
                    color: LuminaTokens.accentBlue,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '單曲設定',
                          style: TextStyle(
                            color: LuminaTokens.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '$effTitle · $effArtist',
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
                  IconButton(
                    key: const Key('btn_close_track_editor'),
                    icon: const Icon(
                      Icons.close_rounded,
                      color: LuminaTokens.textSecondary,
                      size: 18,
                    ),
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TabBar(
                controller: _tabController,
                labelColor: LuminaTokens.accentBlue,
                unselectedLabelColor: LuminaTokens.textMuted,
                indicatorColor: LuminaTokens.accentBlue,
                dividerColor: LuminaTokens.borderSubtle,
                tabs: const [
                  Tab(key: Key('tab_track_options'), text: '曲目選項'),
                  Tab(key: Key('tab_track_policy'), text: '詮釋資料偏好設定'),
                  Tab(key: Key('tab_track_edit'), text: '編輯曲目'),
                ],
              ),
              if (_statusMessage != null) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: _statusIsError
                        ? LuminaTokens.statusErrorBg
                        : LuminaTokens.accentBlue.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: _statusIsError
                          ? LuminaTokens.statusError.withValues(alpha: 0.45)
                          : LuminaTokens.accentBlue.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Text(
                    _statusMessage!,
                    style: TextStyle(
                      color: _statusIsError
                          ? LuminaTokens.statusError
                          : LuminaTokens.textPrimary,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TabBarView(
                        controller: _tabController,
                        children: [
                          _buildOptionsTab(),
                          _buildMetadataPolicyTab(),
                          _buildEditTrackTab(),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
