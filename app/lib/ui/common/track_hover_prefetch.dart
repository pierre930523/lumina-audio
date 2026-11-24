import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';

/// Callback invoked after hovering a desktop streaming track row past the
/// debounce threshold to trigger background pre-resolution.
typedef TrackPrefetchCallback = void Function(TrackInfo track);

/// Propagates the shared streaming hover-prefetch callback and debounce delay
/// down the widget tree without prop-drilling through every track list view.
class TrackPrefetchScope extends InheritedWidget {
  final TrackPrefetchCallback? onPrefetchTrack;
  final Duration hoverDelay;

  const TrackPrefetchScope({
    super.key,
    required this.onPrefetchTrack,
    this.hoverDelay = TrackHoverPrefetch.defaultDelay,
    required super.child,
  });

  /// Non-listening O(1) lookup suitable for event handlers in virtualized lists.
  static TrackPrefetchScope? maybeScopeOf(BuildContext context) {
    final element = context
        .getElementForInheritedWidgetOfExactType<TrackPrefetchScope>();
    final widget = element?.widget;
    return widget is TrackPrefetchScope ? widget : null;
  }

  /// Non-listening O(1) callback lookup.
  static TrackPrefetchCallback? maybeOf(BuildContext context) =>
      maybeScopeOf(context)?.onPrefetchTrack;

  @override
  bool updateShouldNotify(covariant TrackPrefetchScope oldWidget) =>
      oldWidget.onPrefetchTrack != onPrefetchTrack ||
      oldWidget.hoverDelay != hoverDelay;
}

/// Shared desktop hover-debounce wrapper for track list rows.
///
/// Arms a 300 ms debounce timer on mouse pointer enter and cancels it on
/// pointer exit, recycled-item identity change, or widget disposal. Moving off
/// the row before the delay elapses triggers zero pre-resolution work.
class TrackHoverPrefetch extends StatefulWidget {
  static const Duration defaultDelay = Duration(milliseconds: 300);

  final TrackInfo? track;
  final TrackInfo? Function()? trackBuilder;
  final String? trackIdentity;
  final TrackPrefetchCallback? onPrefetch;
  final Duration? delay;
  final bool enabled;
  final Widget child;

  const TrackHoverPrefetch({
    super.key,
    this.track,
    this.trackBuilder,
    this.trackIdentity,
    this.onPrefetch,
    this.delay,
    this.enabled = true,
    required this.child,
  });

  @override
  State<TrackHoverPrefetch> createState() => _TrackHoverPrefetchState();
}

class _TrackHoverPrefetchState extends State<TrackHoverPrefetch> {
  Timer? _hoverTimer;

  String? _effectiveIdentity(TrackHoverPrefetch w) =>
      w.trackIdentity ?? w.track?.id;

  bool _isLocalFile(TrackInfo? track) =>
      track != null &&
      track.filePath != null &&
      track.filePath!.trim().isNotEmpty;

  void _cancelTimer() {
    _hoverTimer?.cancel();
    _hoverTimer = null;
  }

  void _handleEnter(PointerEnterEvent event) {
    if (!widget.enabled) return;
    if (event.kind != PointerDeviceKind.mouse) return;
    if (widget.track == null && widget.trackBuilder == null) return;
    if (_isLocalFile(widget.track)) return;

    final scope = TrackPrefetchScope.maybeScopeOf(context);
    final callback = widget.onPrefetch ?? scope?.onPrefetchTrack;
    if (callback == null) return;

    final effectiveDelay =
        widget.delay ?? scope?.hoverDelay ?? TrackHoverPrefetch.defaultDelay;

    _cancelTimer();
    if (effectiveDelay <= Duration.zero) {
      _firePrefetch(callback);
      return;
    }
    _hoverTimer = Timer(effectiveDelay, () => _firePrefetch(callback));
  }

  void _handleExit(PointerExitEvent event) {
    _cancelTimer();
  }

  void _firePrefetch(TrackPrefetchCallback callback) {
    _hoverTimer = null;
    if (!mounted || !widget.enabled) return;
    final resolved = widget.track ?? widget.trackBuilder?.call();
    if (resolved == null || _isLocalFile(resolved)) return;
    callback(resolved);
  }

  @override
  void didUpdateWidget(covariant TrackHoverPrefetch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled ||
        _effectiveIdentity(oldWidget) != _effectiveIdentity(widget)) {
      _cancelTimer();
    }
  }

  @override
  void dispose() {
    _cancelTimer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      opaque: false,
      onEnter: widget.enabled ? _handleEnter : null,
      onExit: widget.enabled ? _handleExit : null,
      child: widget.child,
    );
  }
}
