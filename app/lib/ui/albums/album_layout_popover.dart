import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../services/album_layout_settings_controller.dart';
import '../../services/escape_dismiss_registry.dart';
import '../common/bottom_player_bar_scope.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_tokens.dart';
import '../theme/responsive_layout.dart';

part 'album_layout_popover_content.dart';

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
  ValueListenable<double>? _bottomClearanceListenable;
  bool _metricsUpdateScheduled = false;
  late final bool Function() _escapeDismissHandler = _handleEscapeDismiss;

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
    EscapeDismissRegistry.instance.unregister(_escapeDismissHandler);
    final entry = _overlayEntry;
    if (entry != null) {
      entry.remove();
      entry.dispose();
      _overlayEntry = null;
    }
  }

  bool _handleEscapeDismiss() {
    if (_overlayEntry == null) {
      EscapeDismissRegistry.instance.unregister(_escapeDismissHandler);
      return false;
    }
    _closePopover();
    return true;
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
    _bottomClearanceListenable = BottomPlayerBarScope.listenableOf(context);
    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = OverlayEntry(builder: _buildOverlay);
    overlay.insert(entry);
    setState(() => _overlayEntry = entry);
    EscapeDismissRegistry.instance.register(_escapeDismissHandler);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _overlayEntry != null) {
        _popoverFocusNode.requestFocus();
      }
    });
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final listenable = _bottomClearanceListenable;
    if (listenable == null) {
      return _buildClampedOverlay(overlayContext, 0.0);
    }
    return ValueListenableBuilder<double>(
      valueListenable: listenable,
      builder: (ctx, clearance, _) => _buildClampedOverlay(ctx, clearance),
    );
  }

  Widget _buildClampedOverlay(
    BuildContext overlayContext,
    double bottomClearance,
  ) {
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
      topInset: MediaQuery.paddingOf(overlayContext).top,
      bottomInset: bottomClearance,
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
                    child: FrostedGlassContainer(
                      blurSigma: LuminaTokens.glassDialogBlur,
                      color: LuminaTokens.glassDialogBg,
                      borderRadius: BorderRadius.circular(
                        LuminaTokens.radiusLg,
                      ),
                      border: Border.all(color: LuminaTokens.glassCardBorder),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x99000000),
                          blurRadius: 28,
                          offset: Offset(0, 12),
                        ),
                      ],
                      child: Material(
                        key: const Key('album_layout_popover'),
                        type: MaterialType.transparency,
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

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _isOpen
              ? LuminaTokens.glassNavActiveBg
              : LuminaTokens.glassPillBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
          border: Border.all(
            color: _isOpen
                ? LuminaTokens.glassCoverRim
                : LuminaTokens.glassPillBorder,
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
                ? Colors.white
                : LuminaTokens.glassTextPrimary,
            hoverColor: LuminaTokens.glassPillHoverBg,
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
