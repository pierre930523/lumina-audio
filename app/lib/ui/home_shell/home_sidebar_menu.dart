part of '../home_screen.dart';

extension _HomeSidebarMenu on _HomeScreenState {
  Future<void> _showSmartPlaylistSidebarMenu(
    BuildContext context,
    SmartPlaylistItem sp,
    Offset globalPosition,
  ) async {
    final action = await showLuminaContextMenu<String>(
      context: context,
      globalPosition: globalPosition,
      minWidth: 164.0,
      menuKey: const Key('sidebar_smart_playlist_menu'),
      entries: [
        const LuminaContextMenuAction<String>(
          value: 'edit_rules',
          icon: Icons.tune_rounded,
          label: '編輯規則',
        ),
        const LuminaContextMenuAction<String>(
          value: 'duplicate',
          icon: Icons.copy_rounded,
          label: '複製',
        ),
        LuminaContextMenuAction<String>(
          value: 'pin',
          icon: sp.isPinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
          label: sp.isPinned ? '取消釘選' : '釘選至側欄',
        ),
        const LuminaContextMenuDivider<String>(),
        const LuminaContextMenuAction<String>(
          value: 'delete',
          icon: Icons.delete_outline_rounded,
          label: '刪除',
          destructive: true,
        ),
      ],
    );
    switch (action) {
      case 'edit_rules':
        _editSmartPlaylistRules(sp);
      case 'duplicate':
        final dup = await _playlistService.duplicatePlaylist(sp.id);
        if (dup != null && mounted) _openSmartPlaylist(dup.id);
      case 'pin':
        await _playlistService.togglePin(sp);
      case 'delete':
        await _playlistService.deletePlaylist(sp.id);
    }
  }
}
