import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../services/desktop_window_controller.dart';
import '../theme/lumina_tokens.dart';

/// Modern frameless window caption control buttons (Minimize, Maximize/Restore, Close).
/// Features Windows 11-style hover states, red close button highlight, and tooltips.
class DesktopWindowCaptionButtons extends StatefulWidget {
  final DesktopWindowController? controller;
  final dynamic audioService;
  final Color? color;
  final double height;

  const DesktopWindowCaptionButtons({
    super.key,
    this.controller,
    this.audioService,
    this.color,
    this.height = 36.0,
  });

  @override
  State<DesktopWindowCaptionButtons> createState() =>
      _DesktopWindowCaptionButtonsState();
}

class _DesktopWindowCaptionButtonsState
    extends State<DesktopWindowCaptionButtons> with WidgetsBindingObserver {
  late DesktopWindowController _controller;
  bool _isMaximized = false;
  bool _isFullScreen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = widget.controller ?? DesktopWindowController.instance;
    _controller.isFullScreenNotifier.addListener(_onFullScreenChanged);
    _controller.isMaximizedNotifier.addListener(_onMaximizedChanged);
    _isMaximized = _controller.isMaximizedNotifier.value;
    _isFullScreen = _controller.isFullScreenNotifier.value;
    _checkWindowState();
  }

  @override
  void didUpdateWidget(DesktopWindowCaptionButtons oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      _controller.isFullScreenNotifier.removeListener(_onFullScreenChanged);
      _controller.isMaximizedNotifier.removeListener(_onMaximizedChanged);
      _controller = widget.controller ?? DesktopWindowController.instance;
      _controller.isFullScreenNotifier.addListener(_onFullScreenChanged);
      _controller.isMaximizedNotifier.addListener(_onMaximizedChanged);
      _isMaximized = _controller.isMaximizedNotifier.value;
      _isFullScreen = _controller.isFullScreenNotifier.value;
      _checkWindowState();
    }
  }

  @override
  void dispose() {
    _controller.isFullScreenNotifier.removeListener(_onFullScreenChanged);
    _controller.isMaximizedNotifier.removeListener(_onMaximizedChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    _checkWindowState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _checkWindowState();
    }
  }

  void _onFullScreenChanged() {
    if (mounted && _controller.isFullScreenNotifier.value != _isFullScreen) {
      setState(() => _isFullScreen = _controller.isFullScreenNotifier.value);
    }
  }

  void _onMaximizedChanged() {
    if (mounted && _controller.isMaximizedNotifier.value != _isMaximized) {
      setState(() => _isMaximized = _controller.isMaximizedNotifier.value);
    }
  }

  Future<void> _checkWindowState() async {
    final max = await _controller.isMaximized();
    final full = await _controller.isFullScreen();
    if (mounted && (max != _isMaximized || full != _isFullScreen)) {
      setState(() {
        _isMaximized = max;
        _isFullScreen = full;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const SizedBox.shrink();
    if (!Platform.isWindows &&
        !Platform.environment.containsKey('FLUTTER_TEST')) {
      return const SizedBox.shrink();
    }

    final defaultColor = widget.color ?? LuminaTokens.glassTextSecondary;

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
            hoverColor: LuminaTokens.glassPillHoverBg,
            onTap: () {
              widget.audioService?.setWindowMinimized(true);
              _controller.minimize();
            },
          ),
          _CaptionButton(
            key: const Key('btn_window_fullscreen'),
            tooltip: _isFullScreen ? '退出全螢幕 (Esc)' : '全螢幕 (F11)',
            icon: _isFullScreen
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            iconSize: 17,
            defaultColor: defaultColor,
            hoverColor: LuminaTokens.glassPillHoverBg,
            onTap: () async {
              await _controller.toggleFullScreen();
              await _checkWindowState();
            },
          ),
          _CaptionButton(
            key: const Key('btn_window_maximize'),
            tooltip: _isFullScreen
                ? '退出全螢幕 (Esc)'
                : (_isMaximized ? '向下還原' : '最大化'),
            icon: _isFullScreen || _isMaximized
                ? Icons.filter_none_rounded
                : Icons.crop_square_rounded,
            iconSize: 13,
            defaultColor: defaultColor,
            hoverColor: LuminaTokens.glassPillHoverBg,
            onTap: () async {
              if (_isFullScreen) {
                await _controller.setFullScreen(false);
              } else {
                await _controller.toggleMaximize();
              }
              await _checkWindowState();
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
        ? (widget.hoverIconColor ?? LuminaTokens.glassTextPrimary)
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
