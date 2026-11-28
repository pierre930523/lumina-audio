import 'package:material_ui/material_ui.dart';

import '../../models/studio/step4_models.dart';
import '../../services/bookmarks_controller.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';

/// Top toolbar Dynamic Bookmarks button and interactive Liquid Glass popover
/// supporting save, update-active, click-to-restore, rename, reorder, and delete.
class BookmarksMenuButton extends StatelessWidget {
  final BookmarksController controller;
  final String? activeBookmarkId;
  final String Function() defaultSaveNameBuilder;
  final Future<void> Function(String name) onSaveNew;
  final Future<void> Function(BookmarkItem active) onUpdateActive;
  final void Function(BookmarkItem bookmark) onSelectBookmark;

  const BookmarksMenuButton({
    super.key,
    required this.controller,
    required this.activeBookmarkId,
    required this.defaultSaveNameBuilder,
    required this.onSaveNew,
    required this.onUpdateActive,
    required this.onSelectBookmark,
  });

  Future<void> _openDialog(BuildContext context) async {
    await controller.load();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierColor: LuminaTokens.scrimBg,
      builder: (ctx) => _BookmarksDialog(
        controller: controller,
        activeBookmarkId: activeBookmarkId,
        defaultSaveNameBuilder: defaultSaveNameBuilder,
        onSaveNew: onSaveNew,
        onUpdateActive: onUpdateActive,
        onSelectBookmark: (bm) {
          Navigator.of(ctx).pop();
          onSelectBookmark(bm);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final hasActive = activeBookmarkId != null;
        return FrostedGlassContainer(
          blurSigma: LuminaTokens.glassPillBlur,
          color: hasActive
              ? LuminaTokens.glassNavActiveBg
              : LuminaTokens.glassPillBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
          border: Border.all(
            color: hasActive
                ? LuminaTokens.glassCoverRim
                : LuminaTokens.glassPillBorder,
          ),
          child: IconButton(
            key: const Key('btn_topbar_bookmarks'),
            tooltip: '動態書籤',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            hoverColor: LuminaTokens.glassPillHoverBg,
            icon: Icon(
              hasActive ? Icons.bookmarks_rounded : Icons.bookmarks_outlined,
              size: 17,
              color: hasActive
                  ? LuminaTokens.glassTextPrimary
                  : LuminaTokens.glassTextSecondary,
            ),
            onPressed: () => _openDialog(context),
          ),
        );
      },
    );
  }
}

class _BookmarksDialog extends StatefulWidget {
  final BookmarksController controller;
  final String? activeBookmarkId;
  final String Function() defaultSaveNameBuilder;
  final Future<void> Function(String name) onSaveNew;
  final Future<void> Function(BookmarkItem active) onUpdateActive;
  final void Function(BookmarkItem bookmark) onSelectBookmark;

  const _BookmarksDialog({
    required this.controller,
    required this.activeBookmarkId,
    required this.defaultSaveNameBuilder,
    required this.onSaveNew,
    required this.onUpdateActive,
    required this.onSelectBookmark,
  });

  @override
  State<_BookmarksDialog> createState() => _BookmarksDialogState();
}

class _BookmarksDialogState extends State<_BookmarksDialog> {
  final TextEditingController _newNameCtrl = TextEditingController();
  final GlideScrollController _listScrollController = GlideScrollController();
  bool _adding = false;
  String? _renamingId;
  final TextEditingController _renameCtrl = TextEditingController();

  @override
  void dispose() {
    _newNameCtrl.dispose();
    _listScrollController.dispose();
    _renameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submitNew() async {
    final name = _newNameCtrl.text.trim();
    if (name.isEmpty) return;
    await widget.onSaveNew(name);
    if (!mounted) return;
    setState(() {
      _adding = false;
      _newNameCtrl.clear();
    });
  }

  Future<void> _submitRename(BookmarkItem item) async {
    final name = _renameCtrl.text.trim();
    if (name.isEmpty) return;
    await widget.controller.update(item.id, name: name);
    if (!mounted) return;
    setState(() => _renamingId = null);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final items = widget.controller.bookmarks;
        final effectiveActiveId =
            widget.controller.activeBookmarkId ?? widget.activeBookmarkId;
        final active = widget.controller.findById(effectiveActiveId);

        return Dialog(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460, maxHeight: 540),
            child: FrostedGlassContainer(
              key: const Key('bookmarks_popover_dialog'),
              blurSigma: LuminaTokens.glassDialogBlur,
              color: LuminaTokens.glassDialogBg,
              borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
              border: Border.all(color: LuminaTokens.glassCardBorder),
              padding: const EdgeInsets.all(LuminaTokens.spaceMd),
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.bookmarks_rounded,
                          size: 18,
                          color: LuminaTokens.accentBlue,
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            '動態書籤',
                            style: TextStyle(
                              color: LuminaTokens.glassTextPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '關閉書籤視窗',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(
                            Icons.close_rounded,
                            size: 18,
                            color: LuminaTokens.glassTextSecondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: LuminaTokens.spaceSm),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          key: const Key('btn_save_current_bookmark'),
                          onPressed: () {
                            setState(() {
                              _adding = true;
                              _newNameCtrl.text =
                                  widget.defaultSaveNameBuilder();
                            });
                          },
                          style: FilledButton.styleFrom(
                            backgroundColor: LuminaTokens.glassSwitchOnTrack,
                            foregroundColor: LuminaTokens.onAccentDark,
                          ),
                          icon: const Icon(Icons.bookmark_add_rounded, size: 16),
                          label: const Text('將目前檢視存為書籤'),
                        ),
                        if (active != null)
                          OutlinedButton.icon(
                            key: const Key('btn_update_current_bookmark'),
                            onPressed: () async {
                              await widget.onUpdateActive(active);
                              if (context.mounted) {
                                Navigator.of(context).pop();
                              }
                            },
                            style: OutlinedButton.styleFrom(
                              backgroundColor: LuminaTokens.glassPillBg,
                              foregroundColor: LuminaTokens.glassTextPrimary,
                              side: const BorderSide(
                                color: LuminaTokens.glassPillBorder,
                              ),
                            ),
                            icon: const Icon(Icons.sync_rounded, size: 16),
                            label: Text('更新「${active.name}」'),
                          ),
                      ],
                    ),
                    if (_adding) ...[
                      const SizedBox(height: LuminaTokens.spaceSm),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              key: const Key('input_new_bookmark_name'),
                              controller: _newNameCtrl,
                              autofocus: true,
                              onSubmitted: (_) => _submitNew(),
                              style: const TextStyle(
                                color: LuminaTokens.glassTextPrimary,
                                fontSize: 13,
                              ),
                              decoration: InputDecoration(
                                hintText: '輸入書籤名稱...',
                                hintStyle: const TextStyle(
                                  color: LuminaTokens.textMuted,
                                ),
                                isDense: true,
                                filled: true,
                                fillColor: LuminaTokens.glassPillBg,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(
                                    LuminaTokens.radiusSm,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            key: const Key('btn_confirm_new_bookmark'),
                            onPressed: _submitNew,
                            style: FilledButton.styleFrom(
                              backgroundColor: LuminaTokens.glassSwitchOnTrack,
                              foregroundColor: LuminaTokens.onAccentDark,
                            ),
                            child: const Text('儲存'),
                          ),
                        ],
                      ),
                    ],
                    const Divider(
                      color: LuminaTokens.glassCardDivider,
                      height: 20,
                    ),
                    Flexible(
                      child: items.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.symmetric(vertical: 28),
                              child: Center(
                                child: Text(
                                  '尚未儲存任何動態書籤',
                                  style: TextStyle(
                                    color: LuminaTokens.textMuted,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            )
                          : SmoothScrollWrapper(
                              controller: _listScrollController,
                              child: ListView.builder(
                                key: const Key('bookmarks_list'),
                                controller: _listScrollController,
                                itemCount: items.length,
                              itemBuilder: (context, idx) {
                                final bm = items[idx];
                                final isRenaming = _renamingId == bm.id;
                                final isCurrent =
                                    effectiveActiveId == bm.id;
                                return ListTile(
                                  key: Key('bookmark_item_${bm.id}'),
                                  dense: true,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  tileColor: isCurrent
                                      ? LuminaTokens.glassNavActiveBg
                                      : Colors.transparent,
                                  leading: Icon(
                                    Icons.bookmark_rounded,
                                    size: 17,
                                    color: isCurrent
                                        ? LuminaTokens.accentBlue
                                        : LuminaTokens.glassTextSecondary,
                                  ),
                                  title: isRenaming
                                      ? TextField(
                                          key: Key(
                                            'input_rename_bookmark_${bm.id}',
                                          ),
                                          controller: _renameCtrl,
                                          autofocus: true,
                                          onSubmitted: (_) => _submitRename(bm),
                                          style: const TextStyle(
                                            color:
                                                LuminaTokens.glassTextPrimary,
                                            fontSize: 13,
                                          ),
                                        )
                                      : Text(
                                          bm.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color:
                                                LuminaTokens.glassTextPrimary,
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                  subtitle: isRenaming
                                      ? null
                                      : Text(
                                          bm.targetRoute,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: LuminaTokens.textMuted,
                                            fontSize: 11,
                                          ),
                                        ),
                                  onTap: isRenaming
                                      ? null
                                      : () => widget.onSelectBookmark(bm),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (isRenaming)
                                        IconButton(
                                          tooltip: '確認重新命名',
                                          onPressed: () => _submitRename(bm),
                                          icon: const Icon(
                                            Icons.check_rounded,
                                            size: 16,
                                            color: LuminaTokens.statusSuccess,
                                          ),
                                        )
                                      else
                                        IconButton(
                                          key: Key(
                                            'btn_rename_bookmark_${bm.id}',
                                          ),
                                          tooltip: '重新命名書籤',
                                          onPressed: () {
                                            setState(() {
                                              _renamingId = bm.id;
                                              _renameCtrl.text = bm.name;
                                            });
                                          },
                                          icon: const Icon(
                                            Icons.edit_outlined,
                                            size: 16,
                                            color:
                                                LuminaTokens.glassTextSecondary,
                                          ),
                                        ),
                                      IconButton(
                                        key: Key('btn_up_bookmark_${bm.id}'),
                                        tooltip: '上移書籤',
                                        onPressed: idx > 0
                                            ? () => widget.controller
                                                  .moveBookmark(bm.id, -1)
                                            : null,
                                        icon: const Icon(
                                          Icons.arrow_upward_rounded,
                                          size: 15,
                                        ),
                                      ),
                                      IconButton(
                                        key: Key('btn_down_bookmark_${bm.id}'),
                                        tooltip: '下移書籤',
                                        onPressed: idx < items.length - 1
                                            ? () => widget.controller
                                                  .moveBookmark(bm.id, 1)
                                            : null,
                                        icon: const Icon(
                                          Icons.arrow_downward_rounded,
                                          size: 15,
                                        ),
                                      ),
                                      IconButton(
                                        key: Key(
                                          'btn_delete_bookmark_${bm.id}',
                                        ),
                                        tooltip: '刪除書籤',
                                        onPressed: () =>
                                            widget.controller.delete(bm.id),
                                        icon: const Icon(
                                          Icons.delete_outline_rounded,
                                          size: 16,
                                          color: LuminaTokens.textMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
