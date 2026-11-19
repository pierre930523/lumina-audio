import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../services/album_layout_settings_controller.dart';
import '../theme/lumina_tokens.dart';
import '../theme/responsive_layout.dart';

class AlbumLayoutSettingsButton extends StatefulWidget {
  final AlbumLayoutSettingsController controller;
  final double? availableWidth;

  const AlbumLayoutSettingsButton({
    super.key,
    required this.controller,
    this.availableWidth,
  });

  @override
  State<AlbumLayoutSettingsButton> createState() =>
      _AlbumLayoutSettingsButtonState();
}

class _AlbumLayoutSettingsButtonState extends State<AlbumLayoutSettingsButton>
    with WidgetsBindingObserver {
  final LayerLink _layerLink = LayerLink();
  final FocusNode _popoverFocusNode = FocusNode(
    debugLabel: 'album_layout_popover_focus',
  );
  OverlayEntry? _overlayEntry;
  bool _metricsUpdateScheduled = false;

  bool get _isOpen => _overlayEntry != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() {
    if (_overlayEntry == null || _metricsUpdateScheduled) return;
    _metricsUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _metricsUpdateScheduled = false;
      if (mounted) {
        _overlayEntry?.markNeedsBuild();
      }
    });
  }

  @override
  void didUpdateWidget(covariant AlbumLayoutSettingsButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_overlayEntry != null &&
        (oldWidget.availableWidth != widget.availableWidth ||
            oldWidget.controller != widget.controller)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _overlayEntry?.markNeedsBuild();
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _removeOverlayOnly();
    _popoverFocusNode.dispose();
    super.dispose();
  }

  void _removeOverlayOnly() {
    final entry = _overlayEntry;
    if (entry != null) {
      entry.remove();
      entry.dispose();
      _overlayEntry = null;
    }
  }

  void _closePopover() {
    if (_overlayEntry == null) return;
    _removeOverlayOnly();
    if (mounted) {
      setState(() {});
    }
  }

  void _togglePopover() {
    if (_overlayEntry != null) {
      _closePopover();
      return;
    }
    _openPopover();
  }

  void _openPopover() {
    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = OverlayEntry(builder: _buildOverlay);
    overlay.insert(entry);
    setState(() => _overlayEntry = entry);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _overlayEntry != null) {
        _popoverFocusNode.requestFocus();
      }
    });
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final targetRender = context.mounted ? context.findRenderObject() : null;
    final overlayRender =
        Overlay.of(context, rootOverlay: true).context.findRenderObject();

    final targetBox = targetRender is RenderBox &&
            targetRender.attached &&
            targetRender.hasSize
        ? targetRender
        : null;
    final overlayBox = overlayRender is RenderBox &&
            overlayRender.attached &&
            overlayRender.hasSize
        ? overlayRender
        : null;

    final overlaySize = overlayBox?.size ?? MediaQuery.sizeOf(overlayContext);
    Offset? targetTopLeft;
    Size? targetSize;
    if (targetBox != null && overlayBox != null) {
      targetTopLeft = targetBox.localToGlobal(
        Offset.zero,
        ancestor: overlayBox,
      );
      targetSize = targetBox.size;
    }

    final clamp = LuminaResponsive.computeClampedPopover(
      overlaySize: overlaySize,
      targetTopLeft: targetTopLeft,
      targetSize: targetSize,
      preferredWidth: 316.0,
      preferredMaxHeight: 520.0,
    );

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            key: const Key('album_layout_popover_barrier'),
            behavior: HitTestBehavior.opaque,
            onTap: _closePopover,
          ),
        ),
        CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          targetAnchor: clamp.targetAnchor,
          followerAnchor: clamp.followerAnchor,
          offset: clamp.offset,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _closePopover,
            },
            child: FocusScope(
              autofocus: true,
              child: Focus(
                focusNode: _popoverFocusNode,
                autofocus: true,
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: clamp.width,
                      maxHeight: clamp.maxHeight,
                    ),
                    child: SizedBox(
                      width: clamp.width,
                      child: Material(
                        key: const Key('album_layout_popover'),
                        color: LuminaTokens.cardElevatedBg,
                        elevation: 16,
                        shadowColor: const Color(0xAA000000),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            LuminaTokens.radiusMd,
                          ),
                          side: BorderSide(
                            color: LuminaTokens.borderControl.withValues(
                              alpha: 0.8,
                            ),
                          ),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: ListenableBuilder(
                          listenable: widget.controller,
                          builder: (context, _) {
                            return SingleChildScrollView(
                              padding: const EdgeInsets.all(
                                LuminaTokens.spaceMd,
                              ),
                              child: _buildPopoverContent(context),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

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
                foregroundColor: LuminaTokens.textSecondary,
                hoverColor: LuminaTokens.cardHoverBg,
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
          color: LuminaTokens.borderSubtle,
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
                  color: LuminaTokens.accentBlue,
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
                  activeTrackColor: LuminaTokens.accentBlue,
                  inactiveTrackColor: LuminaTokens.borderControl,
                  thumbColor: LuminaTokens.textPrimary,
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
          color: LuminaTokens.borderSubtle,
          height: LuminaTokens.spaceLg,
        ),

        // 4. 卡片風格開關
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
              activeTrackColor: LuminaTokens.accentBlueStrong,
              activeThumbColor: LuminaTokens.textPrimary,
              inactiveThumbColor: LuminaTokens.textSecondary,
              inactiveTrackColor: LuminaTokens.canvasBg,
              trackOutlineColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.focused)
                    ? LuminaTokens.focusRing
                    : LuminaTokens.borderControl,
              ),
              mouseCursor: SystemMouseCursors.click,
              onChanged: controller.setShowCardContainer,
            ),
          ],
        ),
        const SizedBox(height: LuminaTokens.spaceSm),

        // 5. 恢復預設
        OutlinedButton.icon(
          key: const Key('btn_album_layout_reset'),
          style: OutlinedButton.styleFrom(
            foregroundColor: LuminaTokens.textPrimary,
            side: const BorderSide(color: LuminaTokens.borderControl),
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

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _isOpen
              ? LuminaTokens.accentBlue.withValues(alpha: 0.16)
              : LuminaTokens.cardElevatedBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
          border: Border.all(
            color: _isOpen
                ? LuminaTokens.accentBlue
                : LuminaTokens.borderControl,
          ),
        ),
        child: IconButton(
          key: const Key('btn_album_layout_settings'),
          tooltip: '布局設定',
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 34),
          padding: EdgeInsets.zero,
          style: IconButton.styleFrom(
            foregroundColor: _isOpen
                ? LuminaTokens.accentBlue
                : LuminaTokens.textPrimary,
            hoverColor: LuminaTokens.cardHoverBg,
            focusColor: LuminaTokens.focusRing.withValues(alpha: 0.25),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
            ),
          ).copyWith(
            mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.click),
          ),
          icon: const Icon(Icons.tune_rounded, size: 18),
          onPressed: _togglePopover,
        ),
      ),
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
                  ? LuminaTokens.accentBlueStrong.withValues(alpha: 0.24)
                  : (_hovered
                        ? LuminaTokens.cardHoverBg
                        : LuminaTokens.canvasBg),
              borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
              border: Border.all(
                color: _focused
                    ? LuminaTokens.focusRing
                    : (widget.selected
                          ? LuminaTokens.accentBlue
                          : LuminaTokens.borderControl),
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
                        ? LuminaTokens.accentBlue
                        : LuminaTokens.textSecondary,
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
                          ? LuminaTokens.textPrimary
                          : LuminaTokens.textSecondary,
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
