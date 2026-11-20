import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// Wraps any ScrollView to provide butter-smooth damped mouse wheel scrolling
/// on desktop platforms (Windows), preventing abrupt stepped jumps.
class SmoothScrollWrapper extends StatefulWidget {
  final ScrollController controller;
  final Widget child;
  final double scrollSpeed;
  final Duration animationDuration;
  final Curve curve;

  const SmoothScrollWrapper({
    super.key,
    required this.controller,
    required this.child,
    this.scrollSpeed = 1.0,
    this.animationDuration = const Duration(milliseconds: 200),
    this.curve = Curves.easeOutCubic,
  });

  @override
  State<SmoothScrollWrapper> createState() => _SmoothScrollWrapperState();
}

class _SmoothScrollWrapperState extends State<SmoothScrollWrapper>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late Animation<double> _animation;
  double _targetOffset = 0.0;
  double _startOffset = 0.0;

  bool get _isDesktop {
    if (kIsWeb) return false;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return false;
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: widget.animationDuration,
    );
    _animation = Tween<double>(begin: 0, end: 0).animate(
      CurvedAnimation(parent: _animController, curve: widget.curve),
    )..addListener(() {
        if (widget.controller.hasClients) {
          widget.controller.jumpTo(
            _animation.value.clamp(
              0.0,
              widget.controller.position.maxScrollExtent,
            ),
          );
        }
      });
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (!_isDesktop) return;
    if (event is PointerScrollEvent && widget.controller.hasClients) {
      final delta = event.scrollDelta.dy * widget.scrollSpeed;
      if (delta == 0) return;

      final current = widget.controller.offset;
      final maxExtent = widget.controller.position.maxScrollExtent;

      if (!_animController.isAnimating) {
        _startOffset = current;
        _targetOffset = (current + delta).clamp(0.0, maxExtent);
      } else {
        _startOffset = widget.controller.offset;
        _targetOffset = (_targetOffset + delta).clamp(0.0, maxExtent);
      }

      _animation = Tween<double>(
        begin: _startOffset,
        end: _targetOffset,
      ).animate(
        CurvedAnimation(parent: _animController, curve: widget.curve),
      );

      _animController.forward(from: 0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isDesktop) {
      return widget.child;
    }
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: widget.child,
    );
  }
}
