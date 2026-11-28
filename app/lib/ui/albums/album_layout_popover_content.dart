part of 'album_layout_popover.dart';

extension _AlbumLayoutPopoverContent on _AlbumLayoutSettingsButtonState {
  Widget _buildPopoverContent(BuildContext context) {
    final controller = widget.controller;
    final availWidth = widget.availableWidth;
    final activeCoverPreset = controller.activeCoverPreset;
    final columnCount = availWidth != null
        ? controller.computeCrossAxisCount(availWidth)
        : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '布局設定',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: LuminaTokens.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              key: const Key('btn_album_layout_close'),
              tooltip: '關閉布局設定',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                foregroundColor: LuminaTokens.glassTextSecondary,
                hoverColor: LuminaTokens.glassRowHoverBg,
                focusColor: LuminaTokens.focusRing.withValues(alpha: 0.25),
              ).copyWith(
                mouseCursor: const WidgetStatePropertyAll(
                  SystemMouseCursors.click,
                ),
              ),
              icon: const Icon(Icons.close_rounded, size: 16),
              onPressed: _closePopover,
            ),
          ],
        ),
        const Divider(
          color: LuminaTokens.glassCardDivider,
          height: LuminaTokens.spaceMd,
        ),

        // 1. 封面大小 / 每行欄數
        Row(
          children: [
            const Text(
              '封面大小',
              style: TextStyle(
                color: LuminaTokens.textSecondary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            if (columnCount != null)
              Text(
                '每行 $columnCount 欄',
                key: const Key('text_album_layout_columns'),
                style: const TextStyle(
                  color: LuminaTokens.glassTextPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
        const SizedBox(height: LuminaTokens.spaceXs),
        Row(
          children: [
            Expanded(
              child: _PopoverPillButton(
                key: const Key('preset_cover_compact'),
                label: AlbumCoverSizePreset.compact.label,
                selected: activeCoverPreset == AlbumCoverSizePreset.compact,
                onTap: () => controller.setCoverSizePreset(
                  AlbumCoverSizePreset.compact,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _PopoverPillButton(
                key: const Key('preset_cover_standard'),
                label: AlbumCoverSizePreset.standard.label,
                selected: activeCoverPreset == AlbumCoverSizePreset.standard,
                onTap: () => controller.setCoverSizePreset(
                  AlbumCoverSizePreset.standard,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _PopoverPillButton(
                key: const Key('preset_cover_large'),
                label: AlbumCoverSizePreset.large.label,
                selected: activeCoverPreset == AlbumCoverSizePreset.large,
                onTap: () => controller.setCoverSizePreset(
                  AlbumCoverSizePreset.large,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: LuminaTokens.space2xs),
        Row(
          children: [
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: LuminaTokens.glassTextPrimary,
                  inactiveTrackColor: LuminaTokens.glassTrackUnplayed,
                  thumbColor: Colors.white,
                  overlayColor: LuminaTokens.focusRing.withValues(alpha: 0.22),
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                ),
                child: Semantics(
                  label: '封面大小滑桿',
                  slider: true,
                  value: '${controller.coverTargetExtent.round()} px',
                  child: Slider(
                    key: const Key('slider_album_cover_size'),
                    min: AlbumLayoutSettingsController.minCoverExtent,
                    max: AlbumLayoutSettingsController.maxCoverExtent,
                    value: controller.coverTargetExtent.clamp(
                      AlbumLayoutSettingsController.minCoverExtent,
                      AlbumLayoutSettingsController.maxCoverExtent,
                    ),
                    onChanged: controller.setCoverTargetExtent,
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                '${controller.coverTargetExtent.round()}px',
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: LuminaTokens.spaceSm),

        // 2. 網格間距
        const Text(
          '網格間距',
          style: TextStyle(
            color: LuminaTokens.textSecondary,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: LuminaTokens.spaceXs),
        Row(
          children: [
            Expanded(
              child: _PopoverPillButton(
                key: const Key('preset_spacing_narrow'),
                label: AlbumGridSpacingPreset.narrow.label,
                selected:
                    controller.spacingPreset == AlbumGridSpacingPreset.narrow,
                onTap: () => controller.setSpacingPreset(
                  AlbumGridSpacingPreset.narrow,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _PopoverPillButton(
                key: const Key('preset_spacing_medium'),
                label: AlbumGridSpacingPreset.medium.label,
                selected:
                    controller.spacingPreset == AlbumGridSpacingPreset.medium,
                onTap: () => controller.setSpacingPreset(
                  AlbumGridSpacingPreset.medium,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _PopoverPillButton(
                key: const Key('preset_spacing_wide'),
                label: AlbumGridSpacingPreset.wide.label,
                selected:
                    controller.spacingPreset == AlbumGridSpacingPreset.wide,
                onTap: () => controller.setSpacingPreset(
                  AlbumGridSpacingPreset.wide,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: LuminaTokens.spaceMd),

        // 3. 檢視模式
        const Text(
          '檢視模式',
          style: TextStyle(
            color: LuminaTokens.textSecondary,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: LuminaTokens.spaceXs),
        Row(
          children: [
            Expanded(
              child: _PopoverPillButton(
                key: const Key('view_mode_grid'),
                icon: Icons.grid_view_rounded,
                label: '網格視圖',
                selected: controller.viewMode == AlbumViewMode.grid,
                onTap: () => controller.setViewMode(AlbumViewMode.grid),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _PopoverPillButton(
                key: const Key('view_mode_list'),
                icon: Icons.view_list_rounded,
                label: '列表視圖',
                selected: controller.viewMode == AlbumViewMode.list,
                onTap: () => controller.setViewMode(AlbumViewMode.list),
              ),
            ),
          ],
        ),
        const Divider(
          color: LuminaTokens.glassCardDivider,
          height: LuminaTokens.spaceLg,
        ),

        // 4. 卡片風格與隱藏版本開關
        Row(
          children: [
            const Expanded(
              child: Text(
                '顯示卡片底色與邊框',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: LuminaTokens.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: LuminaTokens.spaceXs),
            Switch(
              key: const Key('switch_album_card_container'),
              value: controller.showCardContainer,
              mouseCursor: SystemMouseCursors.click,
              onChanged: controller.setShowCardContainer,
            ),
          ],
        ),
        const SizedBox(height: LuminaTokens.spaceXs),
        Row(
          children: [
            const Expanded(
              child: Text(
                '顯示隱藏與重複版本',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: LuminaTokens.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(width: LuminaTokens.spaceXs),
            Switch(
              key: const Key('switch_popover_show_hidden_albums'),
              value: controller.showHiddenAlbums,
              mouseCursor: SystemMouseCursors.click,
              onChanged: controller.setShowHiddenAlbums,
            ),
          ],
        ),
        const SizedBox(height: LuminaTokens.spaceSm),

        // 5. 恢復預設
        OutlinedButton.icon(
          key: const Key('btn_album_layout_reset'),
          style: OutlinedButton.styleFrom(
            backgroundColor: LuminaTokens.glassPillBg,
            foregroundColor: LuminaTokens.glassTextPrimary,
            side: const BorderSide(color: LuminaTokens.glassPillBorder),
            padding: const EdgeInsets.symmetric(
              horizontal: LuminaTokens.spaceSm,
              vertical: LuminaTokens.spaceXs,
            ),
          ).copyWith(
            mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.click),
          ),
          onPressed: controller.resetToDefaults,
          icon: const Icon(Icons.restart_alt_rounded, size: 16),
          label: const Text('恢復預設'),
        ),
      ],
    );
  }
}

class _PopoverPillButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  const _PopoverPillButton({
    super.key,
    required this.label,
    this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_PopoverPillButton> createState() => _PopoverPillButtonState();
}

class _PopoverPillButtonState extends State<_PopoverPillButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          onHover: (v) {
            if (_hovered != v) setState(() => _hovered = v);
          },
          onFocusChange: (v) {
            if (_focused != v) setState(() => _focused = v);
          },
          mouseCursor: SystemMouseCursors.click,
          hoverColor: Colors.transparent,
          focusColor: Colors.transparent,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
          child: AnimatedContainer(
            duration: LuminaTokens.focusDuration,
            curve: LuminaTokens.motionCurve,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            decoration: BoxDecoration(
              color: widget.selected
                  ? LuminaTokens.glassSegmentSelectedBg
                  : (_hovered
                        ? LuminaTokens.glassPillHoverBg
                        : LuminaTokens.glassSegmentTrackBg),
              borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
              border: Border.all(
                color: _focused
                    ? LuminaTokens.focusRing
                    : (widget.selected
                          ? LuminaTokens.glassSegmentSelectedBorder
                          : LuminaTokens.glassSegmentTrackBorder),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.icon != null) ...[
                  Icon(
                    widget.icon,
                    size: 14,
                    color: widget.selected
                        ? Colors.white
                        : LuminaTokens.glassTextSecondary,
                  ),
                  const SizedBox(width: 5),
                ],
                Flexible(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: widget.selected
                          ? Colors.white
                          : LuminaTokens.glassTextSecondary,
                      fontSize: 12,
                      fontWeight: widget.selected
                          ? FontWeight.w600
                          : FontWeight.w500,
                    ),
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
