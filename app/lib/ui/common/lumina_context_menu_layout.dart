part of 'lumina_context_menu.dart';

class _LuminaContextMenuOverlay<T> extends StatefulWidget {
  final OverlayState overlayState;
  final BuildContext? anchorContext;
  final Rect initialAnchorRect;
  final bool isPointAnchor;
  final List<LuminaContextMenuEntry<T>> entries;
  final LuminaContextMenuHeaderBuilder<T>? headerBuilder;
  final double? width;
  final double minWidth;
  final double maxWidth;
  final double edgeMargin;
  final double anchorGap;
  final bool preferAnchorRightAlign;
  final bool avoidBottomPlayerBar;
  final ValueListenable<double>? bottomClearanceListenable;
  final double? bottomInsetOverride;
  final Key? menuKey;
  final void Function([T? result]) onClose;

  const _LuminaContextMenuOverlay({
    required this.overlayState,
    required this.anchorContext,
    required this.initialAnchorRect,
    required this.isPointAnchor,
    required this.entries,
    required this.headerBuilder,
    required this.width,
    required this.minWidth,
    required this.maxWidth,
    required this.edgeMargin,
    required this.anchorGap,
    required this.preferAnchorRightAlign,
    required this.avoidBottomPlayerBar,
    required this.bottomClearanceListenable,
    required this.bottomInsetOverride,
    required this.menuKey,
    required this.onClose,
  });

  @override
  State<_LuminaContextMenuOverlay<T>> createState() =>
      _LuminaContextMenuOverlayState<T>();
}

class _LuminaContextMenuOverlayState<T>
    extends State<_LuminaContextMenuOverlay<T>> with WidgetsBindingObserver {
  late final bool Function() _escapeHandler = _handleEscape;
  final FocusScopeNode _focusScopeNode = FocusScopeNode(
    debugLabel: 'lumina_context_menu_focus',
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    EscapeDismissRegistry.instance.register(_escapeHandler);
  }

  @override
  void didChangeMetrics() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    EscapeDismissRegistry.instance.unregister(_escapeHandler);
    WidgetsBinding.instance.removeObserver(this);
    _focusScopeNode.dispose();
    super.dispose();
  }

  bool _handleEscape() {
    widget.onClose();
    return true;
  }

  Rect _currentAnchorRect() {
    if (widget.isPointAnchor || widget.anchorContext == null) {
      return widget.initialAnchorRect;
    }
    final overlayRender = widget.overlayState.context.findRenderObject();
    if (overlayRender is! RenderBox ||
        !overlayRender.attached ||
        !overlayRender.hasSize) {
      return widget.initialAnchorRect;
    }
    return _resolveAnchorRect(widget.anchorContext!, overlayRender) ??
        widget.initialAnchorRect;
  }

  Widget _buildMenuPanel(
    BuildContext context, {
    required double resolvedMinWidth,
    required double resolvedMaxWidth,
  }) {
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.headerBuilder != null) ...[
          widget.headerBuilder!(context, widget.onClose),
          if (widget.entries.isNotEmpty)
            const Divider(
              color: LuminaTokens.glassCardDivider,
              height: 8.0,
              thickness: 1.0,
            ),
        ],
        for (final entry in widget.entries) _buildEntry(entry),
      ],
    );

    final Widget body = SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: widget.width != null
          ? column
          : IntrinsicWidth(child: column),
    );

    final Widget sizedBody = widget.width != null
        ? SizedBox(
            width: math.min(widget.width!, resolvedMaxWidth),
            child: body,
          )
        : ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: resolvedMinWidth,
              maxWidth: resolvedMaxWidth,
            ),
            child: body,
          );

    return FocusScope(
      node: _focusScopeNode,
      autofocus: true,
      child: FrostedGlassContainer(
        key: widget.menuKey ?? const Key('lumina_context_menu'),
        blurSigma: LuminaTokens.glassDialogBlur,
        color: LuminaTokens.glassMenuBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
        border: Border.all(color: LuminaTokens.glassCardBorder),
        boxShadow: const [
          BoxShadow(
            color: Color(0xAA000000),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
        child: Material(
          type: MaterialType.transparency,
          clipBehavior: Clip.antiAlias,
          child: sizedBody,
        ),
      ),
    );
  }

  Widget _buildEntry(LuminaContextMenuEntry<T> entry) {
    switch (entry) {
      case LuminaContextMenuDivider<T>():
        return Divider(
          color: LuminaTokens.glassCardDivider,
          height: entry.height,
          thickness: 1.0,
        );
      case LuminaContextMenuSectionLabel<T>():
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 3),
          child: Text(
            entry.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: LuminaTokens.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
        );
      case LuminaContextMenuAction<T>():
        return _LuminaMenuActionTile<T>(
          entry: entry,
          onTap: () => widget.onClose(entry.value),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final anchorRect = _currentAnchorRect();
    final topInset = MediaQuery.paddingOf(context).top;

    Widget buildPositionedLayout(double bottomInset) {
      final overlaySize = MediaQuery.sizeOf(context);
      final availWidth = math.max(120.0, overlaySize.width - widget.edgeMargin * 2);
      final resolvedMaxWidth = math.min(widget.maxWidth, availWidth);
      final resolvedMinWidth = math.min(widget.minWidth, resolvedMaxWidth);

      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              key: const Key('lumina_context_menu_barrier'),
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onClose(),
              onSecondaryTapDown: (_) => widget.onClose(),
            ),
          ),
          Positioned.fill(
            child: CustomSingleChildLayout(
              delegate: _LuminaContextMenuLayoutDelegate(
                anchorRect: anchorRect,
                isPointAnchor: widget.isPointAnchor,
                edgeMargin: widget.edgeMargin,
                anchorGap: widget.anchorGap,
                topInset: topInset,
                bottomInset: bottomInset,
                preferAnchorRightAlign: widget.preferAnchorRightAlign,
              ),
              child: _buildMenuPanel(
                context,
                resolvedMinWidth: resolvedMinWidth,
                resolvedMaxWidth: resolvedMaxWidth,
              ),
            ),
          ),
        ],
      );
    }

    if (widget.bottomInsetOverride != null) {
      return buildPositionedLayout(widget.bottomInsetOverride!);
    }
    if (!widget.avoidBottomPlayerBar ||
        widget.bottomClearanceListenable == null) {
      return buildPositionedLayout(0.0);
    }
    return ValueListenableBuilder<double>(
      valueListenable: widget.bottomClearanceListenable!,
      builder: (context, clearance, _) => buildPositionedLayout(clearance),
    );
  }
}

class _LuminaMenuActionTile<T> extends StatelessWidget {
  final LuminaContextMenuAction<T> entry;
  final VoidCallback onTap;

  const _LuminaMenuActionTile({
    required this.entry,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveTextColor = !entry.enabled
        ? LuminaTokens.textDisabled
        : (entry.textColor ??
            (entry.destructive
                ? LuminaTokens.statusError
                : LuminaTokens.textPrimary));
    final effectiveIconColor = !entry.enabled
        ? LuminaTokens.textDisabled
        : (entry.iconColor ??
            (entry.destructive
                ? LuminaTokens.statusError
                : (entry.selected
                    ? LuminaTokens.accentBlue
                    : LuminaTokens.textSecondary)));

    return InkWell(
      key: entry.key,
      onTap: entry.enabled ? onTap : null,
      mouseCursor: entry.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      hoverColor: LuminaTokens.glassRowHoverBg,
      focusColor: LuminaTokens.focusRing.withValues(alpha: 0.22),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 36.0),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (entry.icon != null) ...[
                Icon(entry.icon, size: 17, color: effectiveIconColor),
                const SizedBox(width: 10),
              ],
              Flexible(
                child: Text(
                  entry.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: effectiveTextColor,
                    fontSize: 13,
                    fontWeight:
                        entry.selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              if (entry.trailing != null) ...[
                const SizedBox(width: 10),
                entry.trailing!,
              ] else if (entry.selected) ...[
                const SizedBox(width: 10),
                const Icon(
                  Icons.check_rounded,
                  size: 15,
                  color: LuminaTokens.accentBlue,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LuminaContextMenuLayoutDelegate extends SingleChildLayoutDelegate {
  final Rect anchorRect;
  final bool isPointAnchor;
  final double edgeMargin;
  final double anchorGap;
  final double topInset;
  final double bottomInset;
  final bool preferAnchorRightAlign;

  const _LuminaContextMenuLayoutDelegate({
    required this.anchorRect,
    required this.isPointAnchor,
    required this.edgeMargin,
    required this.anchorGap,
    required this.topInset,
    required this.bottomInset,
    required this.preferAnchorRightAlign,
  });

  double _safeLeft(Size size) => math.min(edgeMargin, size.width / 2);
  double _safeRight(Size size) =>
      math.max(_safeLeft(size), size.width - edgeMargin);
  double _safeTop(Size size) =>
      math.min(topInset + edgeMargin, size.height / 2);
  double _safeBottom(Size size) =>
      math.max(_safeTop(size), size.height - bottomInset - edgeMargin);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final size = constraints.biggest;
    final availWidth = math.max(120.0, _safeRight(size) - _safeLeft(size));
    final availHeight = math.max(96.0, _safeBottom(size) - _safeTop(size));
    return BoxConstraints(maxWidth: availWidth, maxHeight: availHeight);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final sLeft = _safeLeft(size);
    final sRight = _safeRight(size);
    final sTop = _safeTop(size);
    final sBottom = _safeBottom(size);
    final maxX = math.max(sLeft, sRight - childSize.width);
    final maxY = math.max(sTop, sBottom - childSize.height);

    double x;
    if (isPointAnchor) {
      if (anchorRect.left + childSize.width <= sRight) {
        x = anchorRect.left;
      } else if (anchorRect.left - childSize.width >= sLeft) {
        x = anchorRect.left - childSize.width;
      } else {
        x = anchorRect.left;
      }
    } else if (preferAnchorRightAlign) {
      final rightAligned = anchorRect.right - childSize.width;
      if (rightAligned >= sLeft && anchorRect.right <= sRight) {
        x = rightAligned;
      } else if (anchorRect.left + childSize.width <= sRight) {
        x = anchorRect.left;
      } else {
        x = rightAligned;
      }
    } else {
      if (anchorRect.left + childSize.width <= sRight) {
        x = anchorRect.left;
      } else if (anchorRect.right - childSize.width >= sLeft) {
        x = anchorRect.right - childSize.width;
      } else {
        x = anchorRect.left;
      }
    }
    x = x.clamp(sLeft, maxX).toDouble();

    final belowTop = isPointAnchor ? anchorRect.bottom : anchorRect.bottom + anchorGap;
    final aboveBottom = isPointAnchor ? anchorRect.top : anchorRect.top - anchorGap;
    final spaceBelow = sBottom - belowTop;
    final spaceAbove = aboveBottom - sTop;

    double y;
    if (childSize.height <= spaceBelow) {
      y = belowTop;
    } else if (childSize.height <= spaceAbove || spaceAbove > spaceBelow) {
      y = aboveBottom - childSize.height;
    } else {
      y = belowTop;
    }
    y = y.clamp(sTop, maxY).toDouble();

    return Offset(x, y);
  }

  @override
  bool shouldRelayout(covariant _LuminaContextMenuLayoutDelegate oldDelegate) {
    return anchorRect != oldDelegate.anchorRect ||
        isPointAnchor != oldDelegate.isPointAnchor ||
        edgeMargin != oldDelegate.edgeMargin ||
        anchorGap != oldDelegate.anchorGap ||
        topInset != oldDelegate.topInset ||
        bottomInset != oldDelegate.bottomInset ||
        preferAnchorRightAlign != oldDelegate.preferAnchorRightAlign;
  }
}
