import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../common/frosted_glass_container.dart';
import '../settings/settings_styles.dart';
import '../theme/lumina_tokens.dart';

/// Floating frosted-glass bottom toolbar shown when one or more album versions
/// are selected in multi-select mode.
class AlbumSelectionBar extends StatelessWidget {
  final List<CanonicalAlbumSummary> selectedAlbums;
  final bool busy;
  final VoidCallback onMerge;
  final VoidCallback onGroupAsAlternate;
  final VoidCallback onToggleHide;
  final VoidCallback? onManageTags;
  final VoidCallback? onBulkEdit;
  final VoidCallback? onExport;
  final VoidCallback onClearSelection;

  const AlbumSelectionBar({
    super.key,
    required this.selectedAlbums,
    this.busy = false,
    required this.onMerge,
    required this.onGroupAsAlternate,
    required this.onToggleHide,
    this.onManageTags,
    this.onBulkEdit,
    this.onExport,
    required this.onClearSelection,
  });

  bool get _allHidden =>
      selectedAlbums.isNotEmpty && selectedAlbums.every((a) => a.isHidden);

  @override
  Widget build(BuildContext context) {
    final count = selectedAlbums.length;
    final canMultiOp = count >= 2 && !busy;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LuminaTokens.spaceLg,
        0,
        LuminaTokens.spaceLg,
        LuminaTokens.spaceMd,
      ),
      child: FrostedGlassContainer(
        key: const Key('album_selection_bar'),
        blurSigma: LuminaTokens.glassDialogBlur,
        color: LuminaTokens.glassDialogBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
        border: Border.all(color: LuminaTokens.glassCoverRim),
        boxShadow: const [
          BoxShadow(
            color: Color(0x99000000),
            blurRadius: 28,
            offset: Offset(0, 10),
          ),
        ],
        padding: const EdgeInsets.symmetric(
          horizontal: LuminaTokens.spaceMd,
          vertical: LuminaTokens.spaceSm,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Wrap(
            spacing: LuminaTokens.spaceXs,
            runSpacing: LuminaTokens.spaceXs,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: LuminaTokens.accentBlue.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(
                        LuminaTokens.radiusPill,
                      ),
                      border: Border.all(
                        color: LuminaTokens.accentBlue.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Text(
                      '已選取 $count 項',
                      key: const Key('text_selection_count'),
                      style: const TextStyle(
                        color: LuminaTokens.accentBlue,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: LuminaTokens.spaceXs,
                runSpacing: LuminaTokens.spaceXs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    key: const Key('btn_selection_merge'),
                    onPressed: canMultiOp ? onMerge : null,
                    style: LuminaSettingsStyles.filledButtonStyle(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    icon: const Icon(Icons.merge_type_rounded, size: 16),
                    label: const Text(
                      '合併為同一張專輯',
                      style: TextStyle(fontSize: 12.5),
                    ),
                  ),
                  OutlinedButton.icon(
                    key: const Key('btn_selection_group'),
                    onPressed: canMultiOp ? onGroupAsAlternate : null,
                    style: LuminaSettingsStyles.outlinedButtonStyle(),
                    icon: const Icon(Icons.layers_rounded, size: 16),
                    label: const Text(
                      '歸類為同一專輯的版本',
                      style: TextStyle(fontSize: 12.5),
                    ),
                  ),
                  OutlinedButton.icon(
                    key: const Key('btn_selection_toggle_hide'),
                    onPressed: (count >= 1 && !busy) ? onToggleHide : null,
                    style: LuminaSettingsStyles.outlinedButtonStyle(),
                    icon: Icon(
                      _allHidden
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded,
                      size: 16,
                    ),
                    label: Text(
                      _allHidden ? '取消隱藏' : '隱藏',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
                  if (onManageTags != null)
                    OutlinedButton.icon(
                      key: const Key('btn_selection_manage_tags'),
                      onPressed: (count >= 1 && !busy) ? onManageTags : null,
                      style: LuminaSettingsStyles.outlinedButtonStyle(),
                      icon: const Icon(Icons.label_outlined, size: 16),
                      label: const Text(
                        '管理標籤',
                        style: TextStyle(fontSize: 12.5),
                      ),
                    ),
                  if (onBulkEdit != null)
                    OutlinedButton.icon(
                      key: const Key('btn_selection_bulk_edit'),
                      onPressed: (count >= 1 && !busy) ? onBulkEdit : null,
                      style: LuminaSettingsStyles.outlinedButtonStyle(),
                      icon: const Icon(Icons.edit_note_rounded, size: 16),
                      label: const Text(
                        '批量編輯',
                        style: TextStyle(fontSize: 12.5),
                      ),
                    ),
                  if (onExport != null)
                    OutlinedButton.icon(
                      key: const Key('btn_selection_export'),
                      onPressed: (count >= 1 && !busy) ? onExport : null,
                      style: LuminaSettingsStyles.outlinedButtonStyle(),
                      icon: const Icon(Icons.ios_share_rounded, size: 16),
                      label: const Text('匯出', style: TextStyle(fontSize: 12.5)),
                    ),
                  TextButton.icon(
                    key: const Key('btn_selection_clear'),
                    onPressed: busy ? null : onClearSelection,
                    style: TextButton.styleFrom(
                      foregroundColor: LuminaTokens.glassTextSecondary,
                    ),
                    icon: const Icon(Icons.close_rounded, size: 16),
                    label: const Text(
                      '取消選取',
                      style: TextStyle(fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
