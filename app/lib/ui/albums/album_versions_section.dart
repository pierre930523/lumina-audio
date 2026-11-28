import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../theme/lumina_tokens.dart';
import 'album_status_badges.dart';

enum AlbumVersionMenuAction {
  setPrimary,
  resetPrimary,
  ungroup,
  split,
  toggleHidden,
  resetGrouping,
}

/// Interactive frosted-glass version list for [AlbumDetailPage], replacing the
/// flat version chip wrap with full Step 2 management (Primary locking, Hide,
/// Ungroup, Split, Reset manual grouping).
class AlbumVersionsSection extends StatelessWidget {
  final List<AlbumVersionInfo> versions;
  final int selectedIndex;
  final bool isPrimaryLocked;
  final int hiddenVersionCount;
  final bool isStreamingAlbum;
  final ValueChanged<int> onSelectVersion;
  final void Function(AlbumVersionInfo version, AlbumVersionMenuAction action)
      onVersionAction;

  const AlbumVersionsSection({
    super.key,
    required this.versions,
    required this.selectedIndex,
    required this.isPrimaryLocked,
    required this.hiddenVersionCount,
    this.isStreamingAlbum = false,
    required this.onSelectVersion,
    required this.onVersionAction,
  });

  static String _versionChipKey(String provider) => switch (provider) {
    'local' => 'version_chip_local',
    'smb' => 'version_chip_smb',
    'web_dav' || 'webdav' => 'version_chip_web_dav',
    'tidal' => 'version_chip_tidal',
    'qobuz' => 'version_chip_qobuz',
    'apple_music' => 'version_chip_apple_music',
    'youtube_music' => 'version_chip_youtube_music',
    'deezer' => 'version_chip_deezer',
    _ => 'version_chip_$provider',
  };

  static String _providerLabel(String provider) => switch (provider) {
    'local' => '本機',
    'smb' => 'NAS (SMB)',
    'web_dav' || 'webdav' => 'WebDAV',
    'tidal' => 'Tidal',
    'qobuz' => 'Qobuz',
    'apple_music' => 'Apple Music',
    'youtube_music' => 'YTM',
    'deezer' => 'Deezer',
    _ => provider,
  };

  @override
  Widget build(BuildContext context) {
    if (versions.isEmpty) return const SizedBox.shrink();
    final seenProviders = <String>{};
    final selectedVersion =
        versions[selectedIndex.clamp(0, versions.length - 1)];

    return Column(
      key: const Key('album_versions_section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '發行版本',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: LuminaTokens.glassPillBg,
                borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
                border: Border.all(color: LuminaTokens.glassPillBorder),
              ),
              child: Text(
                hiddenVersionCount > 0
                    ? '${versions.length} 個版本 · 含 $hiddenVersionCount 個已隱藏'
                    : '${versions.length} 個版本',
                style: const TextStyle(
                  color: LuminaTokens.glassTextSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Column(
          children: [
            for (final (i, ver) in versions.indexed)
              Padding(
                padding: EdgeInsets.only(
                  bottom: i < versions.length - 1 ? 6 : 0,
                ),
                child: _AlbumVersionRowCard(
                  key: Key('album_version_item_${ver.id}'),
                  tapKey: Key(
                    seenProviders.add(ver.provider)
                        ? _versionChipKey(ver.provider)
                        : '${_versionChipKey(ver.provider)}_${ver.id}',
                  ),
                  version: ver,
                  providerLabel: _providerLabel(ver.provider),
                  isSelected: i == selectedIndex,
                  isPrimaryLocked: isPrimaryLocked,
                  canUngroup: !isStreamingAlbum && versions.length > 1,
                  canSplit: !isStreamingAlbum && ver.tracks.length > 1,
                  showManagementMenu: !isStreamingAlbum,
                  onTap: () => onSelectVersion(i),
                  onAction: (action) => onVersionAction(ver, action),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '目前採用版本：${selectedVersion.editionLabel}',
          style: const TextStyle(
            color: LuminaTokens.glassTextSecondary,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

class _AlbumVersionRowCard extends StatelessWidget {
  final Key tapKey;
  final AlbumVersionInfo version;
  final String providerLabel;
  final bool isSelected;
  final bool isPrimaryLocked;
  final bool canUngroup;
  final bool canSplit;
  final bool showManagementMenu;
  final VoidCallback onTap;
  final ValueChanged<AlbumVersionMenuAction> onAction;

  const _AlbumVersionRowCard({
    super.key,
    required this.tapKey,
    required this.version,
    required this.providerLabel,
    required this.isSelected,
    required this.isPrimaryLocked,
    required this.canUngroup,
    required this.canSplit,
    required this.showManagementMenu,
    required this.onTap,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final trackCount = version.effectiveTrackCount;
    final discCount = version.effectiveDiscCount;
    final metaLine =
        '$providerLabel · ${version.formatSummary} · $trackCount 首'
        '${discCount > 1 ? ' · $discCount 碟' : ''}';

    return Opacity(
      opacity: version.isHidden && !isSelected ? 0.68 : 1.0,
      child: AnimatedContainer(
        duration: LuminaTokens.hoverDuration,
        curve: LuminaTokens.motionCurve,
        decoration: BoxDecoration(
          color: isSelected
              ? LuminaTokens.glassSegmentSelectedBg
              : LuminaTokens.glassCardBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
          border: Border.all(
            color: isSelected
                ? LuminaTokens.glassSegmentSelectedBorder
                : LuminaTokens.glassCardBorder,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Semantics(
                  button: true,
                  selected: isSelected,
                  label: version.editionLabel,
                  child: GestureDetector(
                    key: tapKey,
                    behavior: HitTestBehavior.opaque,
                    onTap: onTap,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                version.editionLabel,
                                style: TextStyle(
                                  color: isSelected
                                      ? Colors.white
                                      : LuminaTokens.glassTextPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (version.isPrimary)
                                AlbumStatusPill.primary(
                                  key: Key('badge_primary_${version.id}'),
                                  locked: isPrimaryLocked,
                                ),
                              if (version.isHidden)
                                AlbumStatusPill.hidden(
                                  key: Key('badge_hidden_${version.id}'),
                                ),
                              if (version.hasManualGrouping)
                                AlbumStatusPill.manualLocked(
                                  key: Key('badge_manual_lock_${version.id}'),
                                ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            metaLine,
                            style: TextStyle(
                              color: isSelected
                                  ? LuminaTokens.glassTextSecondary
                                  : LuminaTokens.textMuted,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (showManagementMenu)
              PopupMenuButton<AlbumVersionMenuAction>(
                key: Key('btn_version_menu_${version.id}'),
                tooltip: '版本管理操作',
                color: LuminaTokens.glassMenuBg,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
                  side: const BorderSide(color: LuminaTokens.glassCardBorder),
                ),
                icon: const Icon(
                  Icons.more_vert_rounded,
                  size: 18,
                  color: LuminaTokens.glassTextSecondary,
                ),
                onSelected: onAction,
                itemBuilder: (context) => [
                  if (!version.isPrimary)
                    const PopupMenuItem(
                      value: AlbumVersionMenuAction.setPrimary,
                      child: _MenuEntry(
                        icon: Icons.star_rounded,
                        label: '設為主版本',
                      ),
                    ),
                  if (version.isPrimary && isPrimaryLocked)
                    const PopupMenuItem(
                      value: AlbumVersionMenuAction.resetPrimary,
                      child: _MenuEntry(
                        icon: Icons.lock_open_rounded,
                        label: '取消主版本鎖定',
                      ),
                    ),
                  if (canUngroup)
                    const PopupMenuItem(
                      value: AlbumVersionMenuAction.ungroup,
                      child: _MenuEntry(
                        icon: Icons.call_split_rounded,
                        label: '移出成為獨立專輯',
                      ),
                    ),
                  if (canSplit)
                    const PopupMenuItem(
                      value: AlbumVersionMenuAction.split,
                      child: _MenuEntry(
                        icon: Icons.content_cut_rounded,
                        label: '拆分此專輯',
                      ),
                    ),
                  PopupMenuItem(
                    value: AlbumVersionMenuAction.toggleHidden,
                    child: _MenuEntry(
                      icon: version.isHidden
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded,
                      label: version.isHidden ? '取消隱藏此版本' : '隱藏此版本',
                    ),
                  ),
                  if (version.hasManualGrouping)
                    const PopupMenuItem(
                      value: AlbumVersionMenuAction.resetGrouping,
                      child: _MenuEntry(
                        icon: Icons.restore_rounded,
                        label: '重置手動分組鎖定',
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _MenuEntry extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MenuEntry({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: LuminaTokens.textSecondary),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
      ],
    );
  }
}
