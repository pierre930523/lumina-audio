import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../common/frosted_glass_container.dart';
import '../settings/settings_styles.dart';
import '../theme/lumina_tokens.dart';

enum AlbumSplitMode {
  byDisc('依碟號'),
  byFolder('依資料夾路徑'),
  manual('手動勾選音軌');

  final String label;
  const AlbumSplitMode(this.label);
}

class AlbumSplitDialogResult {
  final List<SplitTrackGroup> trackGroups;
  final SplitTargetMode targetMode;

  const AlbumSplitDialogResult({
    required this.trackGroups,
    required this.targetMode,
  });
}

/// Frosted-glass dialog for splitting an [AlbumVersionInfo] by disc number,
/// folder path, or manually selected tracks into either the same album group
/// or a standalone album group.
class AlbumSplitDialog extends StatefulWidget {
  final String albumTitle;
  final AlbumVersionInfo version;

  const AlbumSplitDialog({
    super.key,
    required this.albumTitle,
    required this.version,
  });

  @override
  State<AlbumSplitDialog> createState() => _AlbumSplitDialogState();
}

class _AlbumSplitDialogState extends State<AlbumSplitDialog> {
  late AlbumSplitMode _mode;
  SplitTargetMode _targetMode = SplitTargetMode.newGroup;
  final Set<String> _manualSelectedTrackIds = <String>{};
  final TextEditingController _manualTitleCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final discGroups = _computeDiscGroups();
    if (discGroups.length >= 2) {
      _mode = AlbumSplitMode.byDisc;
    } else if (_computeFolderGroups().length >= 2) {
      _mode = AlbumSplitMode.byFolder;
    } else {
      _mode = AlbumSplitMode.manual;
    }
  }

  @override
  void dispose() {
    _manualTitleCtrl.dispose();
    super.dispose();
  }

  static String _parentFolderOf(String path) {
    final normalized = path.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    if (idx <= 0) return '預設資料夾';
    final parent = normalized.substring(0, idx);
    final lastSlash = parent.lastIndexOf('/');
    return lastSlash >= 0 ? parent.substring(lastSlash + 1) : parent;
  }

  List<SplitTrackGroup> _computeDiscGroups() {
    final byDisc = <int, List<AlbumVersionTrackInfo>>{};
    for (final t in widget.version.tracks) {
      byDisc.putIfAbsent(t.discNumber, () => []).add(t);
    }
    final keys = byDisc.keys.toList()..sort();
    return [
      for (final d in keys)
        SplitTrackGroup(
          trackIds: byDisc[d]!.map((t) => t.id).toList(growable: false),
          title: '${widget.albumTitle} (Disc $d)',
          editionLabel: 'Disc $d',
        ),
    ];
  }

  List<SplitTrackGroup> _computeFolderGroups() {
    final byFolder = <String, List<AlbumVersionTrackInfo>>{};
    for (final t in widget.version.tracks) {
      final folder = _parentFolderOf(t.externalTrackId);
      byFolder.putIfAbsent(folder, () => []).add(t);
    }
    final keys = byFolder.keys.toList()..sort();
    return [
      for (final f in keys)
        SplitTrackGroup(
          trackIds: byFolder[f]!.map((t) => t.id).toList(growable: false),
          title: '${widget.albumTitle} ($f)',
          editionLabel: f,
        ),
    ];
  }

  List<SplitTrackGroup> _computeManualGroups() {
    final selected = widget.version.tracks
        .where((t) => _manualSelectedTrackIds.contains(t.id))
        .toList();
    final remaining = widget.version.tracks
        .where((t) => !_manualSelectedTrackIds.contains(t.id))
        .toList();
    if (selected.isEmpty || remaining.isEmpty) return const [];
    final customLabel = _manualTitleCtrl.text.trim();
    return [
      SplitTrackGroup(
        trackIds: remaining.map((t) => t.id).toList(growable: false),
        title: widget.albumTitle,
        editionLabel: widget.version.editionLabel,
      ),
      SplitTrackGroup(
        trackIds: selected.map((t) => t.id).toList(growable: false),
        title: customLabel.isNotEmpty
            ? customLabel
            : '${widget.albumTitle} (拆分)',
        editionLabel: customLabel.isNotEmpty ? customLabel : '拆分版本',
      ),
    ];
  }

  List<SplitTrackGroup> _activeGroups() => switch (_mode) {
    AlbumSplitMode.byDisc => _computeDiscGroups(),
    AlbumSplitMode.byFolder => _computeFolderGroups(),
    AlbumSplitMode.manual => _computeManualGroups(),
  };

  @override
  Widget build(BuildContext context) {
    final groups = _activeGroups();
    final canConfirm = groups.length >= 2;

    return Dialog(
      key: const Key('dialog_split_album'),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 650),
        child: FrostedGlassContainer(
          blurSigma: LuminaTokens.glassDialogBlur,
          color: LuminaTokens.glassDialogBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
          border: Border.all(color: LuminaTokens.glassCardBorder),
          boxShadow: const [
            BoxShadow(
              color: Color(0x88000000),
              blurRadius: 32,
              offset: Offset(0, 14),
            ),
          ],
          padding: const EdgeInsets.all(LuminaTokens.spaceLg),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '拆分專輯：${widget.version.editionLabel}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '選擇拆分方式與拆分後的歸屬方式。系統會自動移除空版本並鎖定手動拆分結果。',
                  style: TextStyle(
                    color: LuminaTokens.textMuted,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceMd),
                const Text(
                  '拆分依據',
                  style: TextStyle(
                    color: LuminaTokens.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                DecoratedBox(
                  decoration: LuminaSettingsStyles.segmentedCapsuleDecoration(),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        LuminaSettingsStyles.frostedSegmentChip(
                          key: const Key('chip_split_mode_disc'),
                          label: AlbumSplitMode.byDisc.label,
                          selected: _mode == AlbumSplitMode.byDisc,
                          fontSize: 12,
                          onSelected: (_) =>
                              setState(() => _mode = AlbumSplitMode.byDisc),
                        ),
                        LuminaSettingsStyles.frostedSegmentChip(
                          key: const Key('chip_split_mode_folder'),
                          label: AlbumSplitMode.byFolder.label,
                          selected: _mode == AlbumSplitMode.byFolder,
                          fontSize: 12,
                          onSelected: (_) =>
                              setState(() => _mode = AlbumSplitMode.byFolder),
                        ),
                        LuminaSettingsStyles.frostedSegmentChip(
                          key: const Key('chip_split_mode_manual'),
                          label: AlbumSplitMode.manual.label,
                          selected: _mode == AlbumSplitMode.manual,
                          fontSize: 12,
                          onSelected: (_) =>
                              setState(() => _mode = AlbumSplitMode.manual),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceSm),
                const Text(
                  '拆分後歸屬',
                  style: TextStyle(
                    color: LuminaTokens.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                DecoratedBox(
                  decoration: LuminaSettingsStyles.segmentedCapsuleDecoration(),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        LuminaSettingsStyles.frostedSegmentChip(
                          key: const Key('chip_split_target_same_group'),
                          label: SplitTargetMode.sameGroup.displayLabel,
                          selected: _targetMode == SplitTargetMode.sameGroup,
                          fontSize: 12,
                          onSelected: (_) => setState(
                            () => _targetMode = SplitTargetMode.sameGroup,
                          ),
                        ),
                        LuminaSettingsStyles.frostedSegmentChip(
                          key: const Key('chip_split_target_new_group'),
                          label: SplitTargetMode.newGroup.displayLabel,
                          selected: _targetMode == SplitTargetMode.newGroup,
                          fontSize: 12,
                          onSelected: (_) => setState(
                            () => _targetMode = SplitTargetMode.newGroup,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceMd),
                Flexible(
                  child: _mode == AlbumSplitMode.manual
                      ? _buildManualTrackPicker()
                      : _buildAutoGroupPreview(groups),
                ),
                if (_mode == AlbumSplitMode.manual) ...[
                  const SizedBox(height: LuminaTokens.spaceSm),
                  TextField(
                    key: const Key('input_split_group_title'),
                    controller: _manualTitleCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: LuminaSettingsStyles.inputDecoration(
                      labelText: '拆出群組名稱 / 版本標籤（選填）',
                      hintText: '例如：Bonus Disc',
                    ),
                  ),
                ],
                const SizedBox(height: LuminaTokens.spaceLg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      key: const Key('btn_cancel_split_album'),
                      style: TextButton.styleFrom(
                        foregroundColor: LuminaTokens.glassTextSecondary,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: LuminaTokens.spaceXs),
                    FilledButton(
                      key: const Key('btn_confirm_split_album'),
                      style: LuminaSettingsStyles.filledButtonStyle(),
                      onPressed: canConfirm
                          ? () => Navigator.of(context).pop(
                              AlbumSplitDialogResult(
                                trackGroups: groups,
                                targetMode: _targetMode,
                              ),
                            )
                          : null,
                      child: const Text('確認拆分'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAutoGroupPreview(List<SplitTrackGroup> groups) {
    if (groups.length < 2) {
      return Container(
        padding: const EdgeInsets.all(LuminaTokens.spaceMd),
        decoration: BoxDecoration(
          color: LuminaTokens.glassCardBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
          border: Border.all(color: LuminaTokens.glassCardBorder),
        ),
        child: Text(
          _mode == AlbumSplitMode.byDisc
              ? '此版本僅包含單一碟號，無法依碟號拆分，請改用「手動勾選音軌」。'
              : '此版本所有音軌皆位於同一資料夾，無法依資料夾拆分，請改用「手動勾選音軌」。',
          style: const TextStyle(
            color: LuminaTokens.textSecondary,
            fontSize: 12.5,
          ),
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      itemCount: groups.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, index) {
        final g = groups[index];
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: LuminaTokens.glassCardBg,
            borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
            border: Border.all(color: LuminaTokens.glassCardBorder),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  g.editionLabel ?? g.title ?? '群組 ${index + 1}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '${g.trackIds.length} 首曲目',
                style: const TextStyle(
                  color: LuminaTokens.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildManualTrackPicker() {
    final entries = widget.version.orderedTrackEntries;
    return Container(
      decoration: BoxDecoration(
        color: LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
        border: Border.all(color: LuminaTokens.glassCardBorder),
      ),
      child: Material(
        type: MaterialType.transparency,
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            final track = entry.track;
            final checked = _manualSelectedTrackIds.contains(track.id);
            return CheckboxListTile(
              key: Key('chk_split_track_${track.id}'),
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: checked,
              activeColor: LuminaTokens.glassSwitchOnTrack,
              checkColor: LuminaTokens.onAccentDark,
              title: Text(
                '${entry.displayNumber}. ${track.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12.5),
              ),
              onChanged: (v) {
                setState(() {
                  if (v == true) {
                    _manualSelectedTrackIds.add(track.id);
                  } else {
                    _manualSelectedTrackIds.remove(track.id);
                  }
                });
              },
            );
          },
        ),
      ),
    );
  }
}
