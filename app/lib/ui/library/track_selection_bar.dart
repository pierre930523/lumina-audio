import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';
import '../common/frosted_glass_container.dart';
import '../settings/settings_styles.dart';
import '../theme/lumina_tokens.dart';

/// Floating frosted-glass bottom toolbar shown when one or more tracks are
/// selected in multi-select mode in the Tracks library view.
class TrackSelectionBar extends StatelessWidget {
  final List<TrackInfo> selectedTracks;
  final bool busy;
  final VoidCallback onPlaySelected;
  final VoidCallback onAddToQueue;
  final VoidCallback? onManageTags;
  final VoidCallback? onBulkEdit;
  final VoidCallback? onExport;
  final VoidCallback onClearSelection;

  const TrackSelectionBar({
    super.key,
    required this.selectedTracks,
    this.busy = false,
    required this.onPlaySelected,
    required this.onAddToQueue,
    this.onManageTags,
    this.onBulkEdit,
    this.onExport,
    required this.onClearSelection,
  });

  @override
  Widget build(BuildContext context) {
    final count = selectedTracks.length;
    final canAct = count >= 1 && !busy;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LuminaTokens.spaceLg,
        0,
        LuminaTokens.spaceLg,
        LuminaTokens.spaceMd,
      ),
      child: FrostedGlassContainer(
        key: const Key('track_selection_bar'),
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
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: LuminaTokens.accentBlue.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
                  border: Border.all(
                    color: LuminaTokens.accentBlue.withValues(alpha: 0.5),
                  ),
                ),
                child: Text(
                  '已選取 $count 首',
                  key: const Key('text_track_selection_count'),
                  style: const TextStyle(
                    color: LuminaTokens.accentBlue,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Wrap(
                spacing: LuminaTokens.spaceXs,
                runSpacing: LuminaTokens.spaceXs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    key: const Key('btn_track_selection_play'),
                    onPressed: canAct ? onPlaySelected : null,
                    style: LuminaSettingsStyles.filledButtonStyle(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    icon: const Icon(Icons.play_arrow_rounded, size: 16),
                    label: const Text('播放選取', style: TextStyle(fontSize: 12.5)),
                  ),
                  OutlinedButton.icon(
                    key: const Key('btn_track_selection_queue'),
                    onPressed: canAct ? onAddToQueue : null,
                    style: LuminaSettingsStyles.outlinedButtonStyle(),
                    icon: const Icon(Icons.playlist_add_rounded, size: 16),
                    label: const Text('加入佇列', style: TextStyle(fontSize: 12.5)),
                  ),
                  if (onManageTags != null)
                    OutlinedButton.icon(
                      key: const Key('btn_track_selection_tags'),
                      onPressed: canAct ? onManageTags : null,
                      style: LuminaSettingsStyles.outlinedButtonStyle(),
                      icon: const Icon(Icons.label_outline_rounded, size: 16),
                      label: const Text(
                        '管理標籤',
                        style: TextStyle(fontSize: 12.5),
                      ),
                    ),
                  if (onBulkEdit != null)
                    OutlinedButton.icon(
                      key: const Key('btn_track_selection_bulk_edit'),
                      onPressed: canAct ? onBulkEdit : null,
                      style: LuminaSettingsStyles.outlinedButtonStyle(),
                      icon: const Icon(Icons.edit_note_rounded, size: 16),
                      label: const Text(
                        '批量編輯',
                        style: TextStyle(fontSize: 12.5),
                      ),
                    ),
                  if (onExport != null)
                    OutlinedButton.icon(
                      key: const Key('btn_track_selection_export'),
                      onPressed: canAct ? onExport : null,
                      style: LuminaSettingsStyles.outlinedButtonStyle(),
                      icon: const Icon(Icons.ios_share_rounded, size: 16),
                      label: const Text('匯出', style: TextStyle(fontSize: 12.5)),
                    ),
                  TextButton.icon(
                    key: const Key('btn_track_selection_clear'),
                    onPressed: busy ? null : onClearSelection,
                    style: TextButton.styleFrom(
                      foregroundColor: LuminaTokens.glassTextSecondary,
                    ),
                    icon: const Icon(Icons.close_rounded, size: 16),
                    label: const Text('取消選取', style: TextStyle(fontSize: 12.5)),
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
