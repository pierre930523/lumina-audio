import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_tokens.dart';
import 'tag_picker_dialog.dart';

typedef TagEditorResult = ({String name, String? color, bool clearColor});

/// Opens a Liquid Glass dialog to create a new tag or edit an existing tag.
Future<TagEditorResult?> showTagEditorDialog({
  required BuildContext context,
  TagSummary? existingTag,
}) {
  return showDialog<TagEditorResult>(
    context: context,
    barrierColor: LuminaTokens.scrimBg,
    builder: (_) => _TagEditorDialog(existingTag: existingTag),
  );
}

/// Opens a Liquid Glass dialog to choose a parent tag to link to [childTag].
Future<String?> showLinkParentTagDialog({
  required BuildContext context,
  required TagSummary childTag,
  required List<TagSummary> allTags,
}) {
  final candidates = allTags
      .where(
        (t) => t.id != childTag.id && !childTag.parentIds.contains(t.id),
      )
      .toList(growable: false);

  return showDialog<String>(
    context: context,
    barrierColor: LuminaTokens.scrimBg,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 460),
        child: FrostedGlassContainer(
          key: const Key('link_parent_tag_dialog'),
          blurSigma: LuminaTokens.glassDialogBlur,
          color: LuminaTokens.glassDialogBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
          border: Border.all(color: LuminaTokens.glassCardBorder),
          padding: const EdgeInsets.all(LuminaTokens.spaceLg),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '為「${childTag.name}」設定父標籤',
                  style: const TextStyle(
                    color: LuminaTokens.glassTextPrimary,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceSm),
                if (candidates.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Text(
                      '沒有可連結的其他父標籤',
                      style: TextStyle(
                        color: LuminaTokens.textMuted,
                        fontSize: 13,
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: candidates.length,
                      itemBuilder: (context, index) {
                        final parent = candidates[index];
                        return ListTile(
                          key: Key('link_parent_option_${parent.id}'),
                          dense: true,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              LuminaTokens.radiusSm,
                            ),
                          ),
                          hoverColor: LuminaTokens.glassRowHoverBg,
                          leading: Container(
                            width: 11,
                            height: 11,
                            decoration: BoxDecoration(
                              color: parseLuminaTagColor(parent.color),
                              shape: BoxShape.circle,
                            ),
                          ),
                          title: Text(
                            parent.name,
                            style: const TextStyle(
                              color: LuminaTokens.glassTextPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          onTap: () => Navigator.of(ctx).pop(parent.id),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: LuminaTokens.spaceSm),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    style: TextButton.styleFrom(
                      foregroundColor: LuminaTokens.glassTextSecondary,
                    ),
                    child: const Text('取消'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Opens a Liquid Glass confirmation dialog before deleting [tag].
Future<bool> showConfirmDeleteTagDialog({
  required BuildContext context,
  required TagSummary tag,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    barrierColor: LuminaTokens.scrimBg,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 390),
        child: FrostedGlassContainer(
          key: const Key('confirm_delete_tag_dialog'),
          blurSigma: LuminaTokens.glassDialogBlur,
          color: LuminaTokens.glassDialogBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
          border: Border.all(color: LuminaTokens.glassCardBorder),
          padding: const EdgeInsets.all(LuminaTokens.spaceLg),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '刪除標籤「${tag.name}」？',
                  style: const TextStyle(
                    color: LuminaTokens.glassTextPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceXs),
                const Text(
                  '此操作會移除該標籤與其所有項目關聯，不會刪除音樂檔案。',
                  style: TextStyle(
                    color: LuminaTokens.glassTextSecondary,
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceLg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      style: TextButton.styleFrom(
                        foregroundColor: LuminaTokens.glassTextSecondary,
                      ),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: LuminaTokens.spaceXs),
                    FilledButton(
                      key: const Key('btn_confirm_delete_tag'),
                      onPressed: () => Navigator.of(ctx).pop(true),
                      style: FilledButton.styleFrom(
                        backgroundColor: LuminaTokens.statusError,
                        foregroundColor: LuminaTokens.onAccentDark,
                      ),
                      child: const Text('確認刪除'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  return confirmed == true;
}

class _TagEditorDialog extends StatefulWidget {
  final TagSummary? existingTag;

  const _TagEditorDialog({this.existingTag});

  @override
  State<_TagEditorDialog> createState() => _TagEditorDialogState();
}

class _TagEditorDialogState extends State<_TagEditorDialog> {
  late final TextEditingController _nameController;
  String? _color;
  bool _clearColor = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existingTag?.name ?? '');
    _color = widget.existingTag?.color ?? kLuminaTagColorSwatches.first;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop((
      name: name,
      color: _clearColor ? null : _color,
      clearColor: _clearColor,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existingTag != null;
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: FrostedGlassContainer(
          key: const Key('tag_editor_dialog'),
          blurSigma: LuminaTokens.glassDialogBlur,
          color: LuminaTokens.glassDialogBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
          border: Border.all(color: LuminaTokens.glassCardBorder),
          padding: const EdgeInsets.all(LuminaTokens.spaceLg),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  isEdit ? '編輯標籤' : '新增標籤',
                  style: const TextStyle(
                    color: LuminaTokens.glassTextPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceMd),
                TextField(
                  key: const Key('tag_editor_name_input'),
                  controller: _nameController,
                  autofocus: true,
                  onSubmitted: (_) => _submit(),
                  style: const TextStyle(
                    color: LuminaTokens.glassTextPrimary,
                    fontSize: 13.5,
                  ),
                  decoration: InputDecoration(
                    hintText: '輸入標籤名稱（例如：深夜聆聽）',
                    hintStyle: const TextStyle(color: LuminaTokens.textMuted),
                    filled: true,
                    fillColor: LuminaTokens.glassPillBg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                      borderSide: const BorderSide(
                        color: LuminaTokens.glassPillBorder,
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                      borderSide: const BorderSide(
                        color: LuminaTokens.glassPillBorder,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                      borderSide: const BorderSide(
                        color: LuminaTokens.focusRing,
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceMd),
                const Text(
                  '標籤顏色',
                  style: TextStyle(
                    color: LuminaTokens.glassTextSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: LuminaTokens.spaceXs),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    for (final hex in kLuminaTagColorSwatches)
                      InkWell(
                        key: Key('tag_editor_swatch_$hex'),
                        borderRadius: BorderRadius.circular(999),
                        onTap: () => setState(() {
                          _color = hex;
                          _clearColor = false;
                        }),
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: parseLuminaTagColor(hex),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: (!_clearColor && _color == hex)
                                  ? Colors.white
                                  : Colors.transparent,
                              width: 2.2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: LuminaTokens.spaceLg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        foregroundColor: LuminaTokens.glassTextSecondary,
                      ),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: LuminaTokens.spaceXs),
                    FilledButton(
                      key: const Key('btn_tag_editor_save'),
                      onPressed: _submit,
                      style: FilledButton.styleFrom(
                        backgroundColor: LuminaTokens.glassSwitchOnTrack,
                        foregroundColor: LuminaTokens.onAccentDark,
                      ),
                      child: Text(isEdit ? '儲存' : '建立'),
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
