import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../common/frosted_glass_container.dart';
import '../settings/settings_styles.dart';
import '../theme/lumina_tokens.dart';

class AlbumMergeDialogResult {
  final String targetVersionId;
  final List<String> sourceVersionIds;
  final String? newEditionLabel;
  final List<DiscMappingEntry> discMapping;

  const AlbumMergeDialogResult({
    required this.targetVersionId,
    required this.sourceVersionIds,
    this.newEditionLabel,
    required this.discMapping,
  });
}

/// Frosted-glass dialog for merging 2+ selected album versions into a single
/// multi-disc album version with customizable disc order and target selection.
class AlbumMergeDialog extends StatefulWidget {
  final List<CanonicalAlbumSummary> selectedVersions;

  const AlbumMergeDialog({
    super.key,
    required this.selectedVersions,
  });

  @override
  State<AlbumMergeDialog> createState() => _AlbumMergeDialogState();
}

class _AlbumMergeDialogState extends State<AlbumMergeDialog> {
  late List<CanonicalAlbumSummary> _ordered;
  late String _targetVersionId;
  late final TextEditingController _editionCtrl;

  @override
  void initState() {
    super.initState();
    _ordered = List<CanonicalAlbumSummary>.from(widget.selectedVersions);
    _targetVersionId = _ordered.first.selectionKey;
    _editionCtrl = TextEditingController(
      text: _ordered.first.editionLabel ?? '',
    );
  }

  @override
  void dispose() {
    _editionCtrl.dispose();
    super.dispose();
  }

  void _moveItem(int index, int delta) {
    final next = index + delta;
    if (next < 0 || next >= _ordered.length) return;
    setState(() {
      final item = _ordered.removeAt(index);
      _ordered.insert(next, item);
    });
  }

  List<(CanonicalAlbumSummary item, int discStart)> _computeDiscStarts() {
    final result = <(CanonicalAlbumSummary, int)>[];
    var cursor = 1;
    for (final item in _ordered) {
      result.add((item, cursor));
      cursor += item.discCount > 0 ? item.discCount : 1;
    }
    return result;
  }

  void _confirm() {
    final starts = _computeDiscStarts();
    final mappings = <DiscMappingEntry>[
      for (final (item, discStart) in starts)
        DiscMappingEntry(versionId: item.selectionKey, discStart: discStart),
    ];
    final sources = _ordered
        .map((e) => e.selectionKey)
        .where((id) => id != _targetVersionId)
        .toList(growable: false);
    final label = _editionCtrl.text.trim();
    Navigator.of(context).pop(
      AlbumMergeDialogResult(
        targetVersionId: _targetVersionId,
        sourceVersionIds: sources,
        newEditionLabel: label.isNotEmpty ? label : null,
        discMapping: mappings,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final discStarts = _computeDiscStarts();
    return Dialog(
      key: const Key('dialog_merge_albums'),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540, maxHeight: 620),
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
                const Text(
                  '合併為同一張專輯',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '調整各專輯的碟號順序並選擇保留為目標的版本。合併後會保留手動鎖定，重新掃描時不會重新拆散。',
                  style: TextStyle(
                    color: LuminaTokens.textMuted,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceMd),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: discStarts.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final (item, discStart) = discStarts[index];
                      final keyId = item.selectionKey;
                      final isTarget = keyId == _targetVersionId;
                      final discSpan = item.discCount > 1
                          ? 'Disc $discStart–${discStart + item.discCount - 1}'
                          : 'Disc $discStart';
                      return Container(
                        key: Key('merge_item_$keyId'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: isTarget
                              ? LuminaTokens.glassNavActiveBg
                              : LuminaTokens.glassCardBg,
                          borderRadius: BorderRadius.circular(
                            LuminaTokens.radiusMd,
                          ),
                          border: Border.all(
                            color: isTarget
                                ? LuminaTokens.accentBlue
                                : LuminaTokens.glassCardBorder,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: LuminaTokens.glassPillBg,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: LuminaTokens.glassPillBorder,
                                ),
                              ),
                              child: Text(
                                discSpan,
                                key: Key('merge_disc_label_$index'),
                                style: const TextStyle(
                                  color: LuminaTokens.glassTextPrimary,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    [
                                      item.artist,
                                      if (item.editionLabel != null &&
                                          item.editionLabel!.isNotEmpty)
                                        item.editionLabel!,
                                      if (item.trackCount != null)
                                        '${item.trackCount} 首',
                                    ].join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: LuminaTokens.textSecondary,
                                      fontSize: 11.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            ChoiceChip(
                              key: Key('btn_merge_target_$keyId'),
                              label: Text(
                                isTarget ? '目標' : '設為目標',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: isTarget
                                      ? Colors.white
                                      : LuminaTokens.glassTextSecondary,
                                ),
                              ),
                              selected: isTarget,
                              showCheckmark: false,
                              visualDensity: VisualDensity.compact,
                              backgroundColor: LuminaTokens.glassPillBg,
                              selectedColor: LuminaTokens.accentBlue
                                  .withValues(alpha: 0.3),
                              side: BorderSide(
                                color: isTarget
                                    ? LuminaTokens.accentBlue
                                    : LuminaTokens.glassPillBorder,
                              ),
                              onSelected: (_) =>
                                  setState(() => _targetVersionId = keyId),
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              key: Key('btn_merge_move_up_$index'),
                              tooltip: '上移碟號',
                              visualDensity: VisualDensity.compact,
                              onPressed: index > 0
                                  ? () => _moveItem(index, -1)
                                  : null,
                              icon: const Icon(
                                Icons.arrow_upward_rounded,
                                size: 16,
                              ),
                            ),
                            IconButton(
                              key: Key('btn_merge_move_down_$index'),
                              tooltip: '下移碟號',
                              visualDensity: VisualDensity.compact,
                              onPressed: index < _ordered.length - 1
                                  ? () => _moveItem(index, 1)
                                  : null,
                              icon: const Icon(
                                Icons.arrow_downward_rounded,
                                size: 16,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceMd),
                TextField(
                  key: const Key('input_merge_edition_label'),
                  controller: _editionCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: LuminaSettingsStyles.inputDecoration(
                    labelText: '合併後版本標籤（選填）',
                    hintText: '例如：2CD Deluxe Edition',
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceLg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      key: const Key('btn_cancel_merge_albums'),
                      style: TextButton.styleFrom(
                        foregroundColor: LuminaTokens.glassTextSecondary,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: LuminaTokens.spaceXs),
                    FilledButton(
                      key: const Key('btn_confirm_merge_albums'),
                      style: LuminaSettingsStyles.filledButtonStyle(),
                      onPressed: _ordered.length >= 2 ? _confirm : null,
                      child: const Text('確認合併'),
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
}
