import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../theme/lumina_tokens.dart';
import 'focus_controller.dart';

/// Liquid Glass Focus trigger bar, sort controls, pagination, and interactive
/// `+ 包含` / `- 排除` predicate capsules.
class FocusToolbar extends StatelessWidget {
  final FocusController controller;
  final List<Widget> leadingWidgets;
  final List<Widget> trailingWidgets;

  const FocusToolbar({
    super.key,
    required this.controller,
    this.leadingWidgets = const <Widget>[],
    this.trailingWidgets = const <Widget>[],
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final activeCount = controller.activePredicateCount;
        final isOpen = controller.drawerOpen;
        final sort = controller.query.sort;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: LuminaTokens.spaceXs,
              runSpacing: LuminaTokens.spaceXs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ...leadingWidgets,
                _buildFocusTriggerButton(
                  isOpen: isOpen,
                  activeCount: activeCount,
                ),
                _buildSortSelector(sort),
                if (sort != null && sort.field != FocusSortField.random)
                  _buildSortDirectionButton(sort),
                if (sort?.field == FocusSortField.random)
                  _buildReshuffleButton(),
                if (controller.isLoading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: LuminaTokens.accentBlue,
                    ),
                  ),
                if (controller.isActive && !controller.isLoading)
                  _buildResultCountAndPager(),
                ...trailingWidgets,
              ],
            ),
            if (controller.hasPredicates) ...[
              const SizedBox(height: LuminaTokens.spaceXs),
              _buildActiveCapsulesRow(),
            ],
            if (controller.error != null) ...[
              const SizedBox(height: 4),
              Text(
                'Focus 篩選失敗：${controller.error}',
                style: const TextStyle(
                  color: LuminaTokens.statusError,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildFocusTriggerButton({
    required bool isOpen,
    required int activeCount,
  }) {
    final highlighted = isOpen || activeCount > 0;
    return OutlinedButton.icon(
      key: const Key('btn_focus_toggle'),
      onPressed: () => controller.toggleDrawer(),
      style: OutlinedButton.styleFrom(
        backgroundColor: highlighted
            ? LuminaTokens.glassSegmentSelectedBg
            : LuminaTokens.glassPillBg,
        foregroundColor: highlighted
            ? Colors.white
            : LuminaTokens.glassTextPrimary,
        side: BorderSide(
          color: highlighted
              ? LuminaTokens.accentBlue
              : LuminaTokens.glassPillBorder,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      icon: Icon(
        isOpen ? Icons.filter_alt_rounded : Icons.filter_alt_outlined,
        size: 16,
        color: highlighted ? LuminaTokens.accentBlue : null,
      ),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Focus', style: TextStyle(fontSize: 12.5)),
          if (activeCount > 0) ...[
            const SizedBox(width: 6),
            Container(
              key: const Key('focus_active_badge'),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: LuminaTokens.accentBlue.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
                border: Border.all(
                  color: LuminaTokens.accentBlue.withValues(alpha: 0.6),
                ),
              ),
              child: Text(
                '$activeCount',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSortSelector(FocusSort? sort) {
    final label = sort != null ? '排序：${sort.field.displayLabel}' : '排序：預設';
    return PopupMenuButton<String>(
      key: const Key('focus_sort_dropdown'),
      tooltip: '選擇排序欄位',
      color: LuminaTokens.glassMenuBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
        side: const BorderSide(color: LuminaTokens.glassCardBorder),
      ),
      onSelected: (value) {
        if (value == '__default__') {
          controller.setSort(null);
          return;
        }
        final field = FocusSortField.fromJson(value);
        final dir = sort?.field == field
            ? sort!.direction
            : (field == FocusSortField.releaseYear ||
                      field == FocusSortField.addedAt ||
                      field == FocusSortField.sampleRate
                  ? FocusSortDirection.desc
                  : FocusSortDirection.asc);
        controller.setSort(FocusSort(field: field, direction: dir));
      },
      itemBuilder: (context) => [
        const PopupMenuItem<String>(
          value: '__default__',
          height: 36,
          child: Text(
            '預設排序',
            style: TextStyle(color: LuminaTokens.glassTextPrimary, fontSize: 13),
          ),
        ),
        const PopupMenuDivider(height: 8),
        for (final field in FocusSortField.values)
          PopupMenuItem<String>(
            value: field.wireName,
            height: 36,
            child: Row(
              children: [
                Icon(
                  sort?.field == field
                      ? Icons.check_rounded
                      : Icons.sort_rounded,
                  size: 15,
                  color: sort?.field == field
                      ? LuminaTokens.accentBlue
                      : LuminaTokens.textMuted,
                ),
                const SizedBox(width: 8),
                Text(
                  field.displayLabel,
                  style: const TextStyle(
                    color: LuminaTokens.glassTextPrimary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: sort != null
              ? LuminaTokens.glassSegmentSelectedBg
              : LuminaTokens.glassPillBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
          border: Border.all(
            color: sort != null
                ? LuminaTokens.glassSegmentSelectedBorder
                : LuminaTokens.glassPillBorder,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.swap_vert_rounded,
              size: 15,
              color: LuminaTokens.glassTextSecondary,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                color: LuminaTokens.glassTextPrimary,
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 2),
            const Icon(
              Icons.arrow_drop_down_rounded,
              size: 17,
              color: LuminaTokens.glassTextSecondary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSortDirectionButton(FocusSort sort) {
    final isDesc = sort.direction == FocusSortDirection.desc;
    return IconButton.outlined(
      key: const Key('btn_focus_sort_dir'),
      tooltip: isDesc ? '降冪排序（點擊切換升冪）' : '升冪排序（點擊切換降冪）',
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      style: OutlinedButton.styleFrom(
        backgroundColor: LuminaTokens.glassPillBg,
        foregroundColor: LuminaTokens.glassTextPrimary,
        side: const BorderSide(color: LuminaTokens.glassPillBorder),
      ),
      icon: Icon(
        isDesc ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded,
        size: 16,
      ),
      onPressed: controller.toggleSortDirection,
    );
  }

  Widget _buildReshuffleButton() {
    return OutlinedButton.icon(
      key: const Key('btn_focus_reshuffle'),
      onPressed: controller.reshuffleRandom,
      style: OutlinedButton.styleFrom(
        backgroundColor: LuminaTokens.glassPillBg,
        foregroundColor: LuminaTokens.glassTextPrimary,
        side: const BorderSide(color: LuminaTokens.glassPillBorder),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
      icon: const Icon(Icons.shuffle_rounded, size: 15),
      label: const Text('重新隨機', style: TextStyle(fontSize: 12)),
    );
  }

  Widget _buildResultCountAndPager() {
    final total = controller.totalCount;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '符合 $total 項',
          key: const Key('focus_result_count'),
          style: const TextStyle(
            color: LuminaTokens.glassTextSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (controller.hasPrevPage || controller.hasNextPage) ...[
          const SizedBox(width: 6),
          IconButton(
            key: const Key('btn_focus_prev_page'),
            tooltip: '上一頁',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            padding: EdgeInsets.zero,
            onPressed: controller.hasPrevPage
                ? () => controller.loadPage(
                    controller.offset - controller.pageSize,
                  )
                : null,
            icon: const Icon(Icons.chevron_left_rounded, size: 18),
          ),
          IconButton(
            key: const Key('btn_focus_next_page'),
            tooltip: '下一頁',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
            padding: EdgeInsets.zero,
            onPressed: controller.hasNextPage
                ? () => controller.loadPage(
                    controller.offset + controller.pageSize,
                  )
                : null,
            icon: const Icon(Icons.chevron_right_rounded, size: 18),
          ),
        ],
      ],
    );
  }

  Widget _buildActiveCapsulesRow() {
    final preds = controller.query.predicates;
    return Wrap(
      key: const Key('focus_active_capsules'),
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < preds.length; i++) _buildPredicateCapsule(i, preds[i]),
        TextButton.icon(
          key: const Key('btn_focus_clear_all'),
          onPressed: controller.clearAllPredicates,
          style: TextButton.styleFrom(
            foregroundColor: LuminaTokens.glassTextSecondary,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          ),
          icon: const Icon(Icons.clear_all_rounded, size: 15),
          label: const Text('全部清除', style: TextStyle(fontSize: 12)),
        ),
      ],
    );
  }

  Widget _buildPredicateCapsule(int index, FocusPredicate predicate) {
    final isExclude = predicate.mode == FocusPredicateMode.exclude;
    final bgColor = isExclude
        ? LuminaTokens.statusError.withValues(alpha: 0.18)
        : LuminaTokens.accentBlue.withValues(alpha: 0.22);
    final borderColor = isExclude
        ? LuminaTokens.statusError.withValues(alpha: 0.65)
        : LuminaTokens.accentBlue.withValues(alpha: 0.65);
    final fgColor = isExclude ? LuminaTokens.statusError : Colors.white;
    final label = controller.labelForPredicate(predicate);

    return Tooltip(
      message: isExclude ? '排除條件（點擊切換為包含）' : '包含條件（點擊切換為排除）',
      child: Container(
        key: Key('focus_capsule_$index'),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              key: Key('focus_capsule_toggle_$index'),
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(LuminaTokens.radiusPill),
              ),
              onTap: () => controller.togglePredicateMode(index),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(9, 5, 6, 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isExclude
                          ? Icons.remove_circle_outline_rounded
                          : Icons.add_circle_outline_rounded,
                      size: 14,
                      color: fgColor,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      isExclude ? '- $label' : '+ $label',
                      style: TextStyle(
                        color: fgColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            InkWell(
              key: Key('focus_capsule_remove_$index'),
              borderRadius: const BorderRadius.horizontal(
                right: Radius.circular(LuminaTokens.radiusPill),
              ),
              onTap: () => controller.removePredicate(index),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 5, 8, 5),
                child: Icon(Icons.close_rounded, size: 14, color: fgColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
