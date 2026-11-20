import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../services/desktop_window_controller.dart';
import '../theme/lumina_tokens.dart';

/// Modern frameless window caption control buttons (Minimize, Maximize/Restore, Close).
/// Features Windows 11-style hover states, red close button highlight, and tooltips.
class DesktopWindowCaptionButtons extends StatefulWidget {
  final DesktopWindowController? controller;
  final Color? color;
  final double height;

  const DesktopWindowCaptionButtons({
    super.key,
    this.controller,
    this.color,
    this.height = 36.0,
  });

  @override
  State<DesktopWindowCaptionButtons> createState() =>
      _DesktopWindowCaptionButtonsState();
}

class _DesktopWindowCaptionButtonsState
    extends State<DesktopWindowCaptionButtons> {
  late final DesktopWindowController _controller;
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? DesktopWindowController.instance;
    _checkMaximizedState();
  }

  Future<void> _checkMaximizedState() async {
    final max = await _controller.isMaximized();
    if (mounted && max != _isMaximized) {
      setState(() => _isMaximized = max);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const SizedBox.shrink();
    if (!Platform.isWindows &&
        !Platform.environment.containsKey('FLUTTER_TEST')) {
      return const SizedBox.shrink();
    }

    final defaultColor = widget.color ?? LuminaTokens.textSecondary;

    return SizedBox(
      height: widget.height,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _CaptionButton(
            key: const Key('btn_window_minimize'),
          tooltip: '最小化',
          icon: Icons.remove_rounded,
          iconSize: 15,
          defaultColor: defaultColor,
          hoverColor: Colors.white.withValues(alpha: 0.12),
          onTap: () => _controller.minimize(),
        ),
        _CaptionButton(
          key: const Key('btn_window_maximize'),
          tooltip: _isMaximized ? '向下還原' : '最大化',
          icon: _isMaximized
              ? Icons.filter_none_rounded
              : Icons.crop_square_rounded,
          iconSize: 13,
          defaultColor: defaultColor,
          hoverColor: Colors.white.withValues(alpha: 0.12),
          onTap: () async {
            await _controller.toggleMaximize();
            await _checkMaximizedState();
          },
        ),
        _CaptionButton(
          key: const Key('btn_window_close'),
          tooltip: '關閉',
          icon: Icons.close_rounded,
          iconSize: 16,
          defaultColor: defaultColor,
          hoverColor: const Color(0xFFE81123),
          hoverIconColor: Colors.white,
          onTap: () => _controller.close(),
        ),
      ],
    ),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  final String tooltip;
  final IconData icon;
  final double iconSize;
  final Color defaultColor;
  final Color hoverColor;
  final Color? hoverIconColor;
  final VoidCallback onTap;

  const _CaptionButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.iconSize,
    required this.defaultColor,
    required this.hoverColor,
    this.hoverIconColor,
    required this.onTap,
  });

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final iconColor = _hovered
        ? (widget.hoverIconColor ?? LuminaTokens.textPrimary)
        : widget.defaultColor;

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            width: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hovered ? widget.hoverColor : Colors.transparent,
            ),
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: iconColor,
            ),
          ),
        ),
      ),
    );
  }
}
