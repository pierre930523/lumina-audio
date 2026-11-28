import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/library_index_cache.dart';
import '../../services/listen_later_controller.dart';
import '../artwork/album_artwork_view.dart';
import '../tags/tag_picker_dialog.dart';
import '../theme/lumina_tokens.dart';
import 'lumina_context_menu.dart';
import 'playlist_picker_dialog.dart';
import 'track_file_info_dialog.dart';
import 'track_info_editor_dialog.dart';

enum _TrackMenuAction {
  playNext,
  addToPlaylist,
  listenLater,
  addTags,
  fileInfo,
  showInFolder,
  editTrack,
  toggleBan,
}

/// Shows the unified single-track right-click / `...` context menu anchored to
/// either [globalPosition] (pointer secondary click) or [anchorContext] (`...`).
Future<void> showTrackContextMenu({
  required BuildContext context,
  required AudioService audioService,
  required TrackInfo track,
  Offset? globalPosition,
  BuildContext? anchorContext,
  LibraryIndexCache? libraryCache,
  ListenLaterController? listenLaterController,
  int? currentPreference,
  ValueChanged<int>? onPreferenceChanged,
  ValueChanged<TrackInfo>? onTrackUpdated,
  VoidCallback? onTrackDeleted,
}) async {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final effectivePref = currentPreference ?? track.preference;
  final isBanned = effectivePref == -1;
  final isStreaming = AudioService.isStreamingTrackId(track.id);

  final entries = <LuminaContextMenuEntry<_TrackMenuAction>>[
    const LuminaContextMenuDivider(height: 8),
    const LuminaContextMenuAction<_TrackMenuAction>(
      key: Key('menu_track_add_tags'),
      value: _TrackMenuAction.addTags,
      label: '新增至標籤',
      icon: Icons.label_outline_rounded,
    ),
    const LuminaContextMenuAction<_TrackMenuAction>(
      key: Key('menu_track_file_info'),
      value: _TrackMenuAction.fileInfo,
      label: '檢視檔案資訊...',
      icon: Icons.info_outline_rounded,
    ),
    LuminaContextMenuAction<_TrackMenuAction>(
      key: const Key('menu_track_show_in_folder'),
      value: _TrackMenuAction.showInFolder,
      label: '前往資料夾',
      icon: Icons.folder_open_rounded,
      enabled: !isStreaming,
    ),
    const LuminaContextMenuAction<_TrackMenuAction>(
      key: Key('menu_track_edit'),
      value: _TrackMenuAction.editTrack,
      label: '編輯...',
      icon: Icons.edit_outlined,
    ),
    const LuminaContextMenuDivider(height: 8),
    LuminaContextMenuAction<_TrackMenuAction>(
      key: const Key('menu_track_ban'),
      value: _TrackMenuAction.toggleBan,
      label: isBanned ? '取消封鎖這首曲目' : '封鎖這首曲目',
      icon: Icons.block_rounded,
      destructive: !isBanned,
      selected: isBanned,
    ),
  ];

  final action = await showLuminaContextMenu<_TrackMenuAction>(
    context: context,
    globalPosition: globalPosition,
    anchorContext: anchorContext,
    menuKey: const Key('track_context_menu'),
    minWidth: 248,
    maxWidth: 300,
    headerBuilder: (menuCtx, closeMenu) => _TrackMenuHeader(
      track: track,
      audioService: audioService,
      libraryCache: libraryCache,
      onActionSelected: (selected) => closeMenu(selected),
    ),
    entries: entries,
  );

  if (action == null || !context.mounted) return;

  switch (action) {
    case _TrackMenuAction.playNext:
      await audioService.enqueueTracks(
        <TrackInfo>[track],
        excludeBanned: false,
        playNext: true,
      );
      messenger?.showSnackBar(
        SnackBar(
          content: Text('已將「${track.title}」加入下一首播放'),
          duration: const Duration(seconds: 2),
        ),
      );
    case _TrackMenuAction.addToPlaylist:
      await showPlaylistPickerDialog(
        context: context,
        audioService: audioService,
        track: track,
      );
    case _TrackMenuAction.listenLater:
      final ll = listenLaterController;
      if (ll != null) {
        if (isStreaming) {
          await ll.addStreamingTrack(track);
        } else {
          await ll.addLocalTrack(track);
        }
      } else {
        await audioService.addToListenLater(
          sourceKind: isStreaming ? 'external' : 'library',
          entityType: 'track',
          entityId: isStreaming ? null : track.id,
          title: track.title,
          artistName: track.artist,
          albumTitle: track.album,
          coverUrl: track.artworkUrl,
        );
      }
      messenger?.showSnackBar(
        SnackBar(
          content: Text('已將「${track.title}」新增至稍後聆聽'),
          duration: const Duration(seconds: 2),
        ),
      );
    case _TrackMenuAction.addTags:
      final changed = await showTagPickerDialog(
        context: context,
        audioService: audioService,
        entityType: TagEntityType.track,
        entityIds: <String>[track.id],
        title: track.title,
      );
      if (changed && libraryCache != null) {
        unawaited(libraryCache.refresh(audioService));
      }
    case _TrackMenuAction.fileInfo:
      await showTrackFileInfoDialog(
        context: context,
        audioService: audioService,
        track: track,
      );
    case _TrackMenuAction.showInFolder:
      var path = track.filePath?.trim() ?? '';
      if (path.isEmpty) {
        final info = await audioService.getTrackFileInfo(track.id);
        path = info?.filePath.trim() ?? '';
      }
      final ok = path.isNotEmpty && await audioService.revealTrackFolder(path);
      if (!ok) {
        messenger?.showSnackBar(
          const SnackBar(
            content: Text('此曲目無可用本地資料夾，或目前為遠端伺服器檔案'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    case _TrackMenuAction.editTrack:
      await showTrackInfoEditorDialog(
        context: context,
        audioService: audioService,
        track: track,
        libraryCache: libraryCache,
        onTrackUpdated: onTrackUpdated,
        onTrackDeleted: onTrackDeleted,
      );
    case _TrackMenuAction.toggleBan:
      final nextPref = isBanned ? 0 : -1;
      onPreferenceChanged?.call(nextPref);
      libraryCache?.updateEntityPreferenceSync('track', track.id, nextPref);
      final res = await audioService.setEntityPreference(
        'track',
        track.id,
        nextPref,
      );
      final applied = res?.preference ?? nextPref;
      onTrackUpdated?.call(track.copyWith(preference: applied));
      if (libraryCache != null) {
        unawaited(libraryCache.refresh(audioService));
      }
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            applied == -1 ? '已封鎖「${track.title}」' : '已取消封鎖「${track.title}」',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
  }
}

class _TrackMenuHeader extends StatelessWidget {
  final TrackInfo track;
  final AudioService audioService;
  final LibraryIndexCache? libraryCache;
  final ValueChanged<_TrackMenuAction> onActionSelected;

  const _TrackMenuHeader({
    required this.track,
    required this.audioService,
    required this.libraryCache,
    required this.onActionSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              AlbumArtworkView(
                track: track,
                size: 40,
                borderRadius: BorderRadius.circular(6),
                audioService: audioService,
                libraryCache: libraryCache,
                fullResolution: false,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      track.artist,
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
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _HeaderQuickButton(
                  buttonKey: const Key('btn_ctx_play_next'),
                  icon: Icons.playlist_play_rounded,
                  tooltip: '下一首播放',
                  label: '下一首',
                  onTap: () => onActionSelected(_TrackMenuAction.playNext),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _HeaderQuickButton(
                  buttonKey: const Key('btn_ctx_add_to_playlist'),
                  icon: Icons.playlist_add_rounded,
                  tooltip: '加入播放清單',
                  label: '歌單',
                  onTap: () => onActionSelected(_TrackMenuAction.addToPlaylist),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _HeaderQuickButton(
                  buttonKey: const Key('btn_ctx_listen_later'),
                  icon: Icons.watch_later_outlined,
                  tooltip: '新增至稍後聆聽',
                  label: '稍後聽',
                  onTap: () => onActionSelected(_TrackMenuAction.listenLater),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeaderQuickButton extends StatelessWidget {
  final Key buttonKey;
  final IconData icon;
  final String tooltip;
  final String label;
  final VoidCallback onTap;

  const _HeaderQuickButton({
    required this.buttonKey,
    required this.icon,
    required this.tooltip,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          key: buttonKey,
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: LuminaTokens.textPrimary, size: 17),
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.textSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
