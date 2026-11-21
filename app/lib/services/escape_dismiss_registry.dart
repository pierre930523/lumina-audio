import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Tracks active non-Navigator floating overlays (e.g. OverlayEntry popovers)
/// in LIFO order so the global Esc handler can dismiss only the topmost layer.
class EscapeDismissRegistry {
  EscapeDismissRegistry._();

  static final EscapeDismissRegistry instance = EscapeDismissRegistry._();

  final List<bool Function()> _handlers = <bool Function()>[];
  int _globalHostCount = 0;
  bool _fallbackHandlerInstalled = false;

  bool get hasActive => _handlers.isNotEmpty;

  void register(bool Function() handler) {
    _handlers.remove(handler);
    _handlers.add(handler);
    _syncFallbackHandler();
  }

  void unregister(bool Function() handler) {
    _handlers.remove(handler);
    _syncFallbackHandler();
  }

  /// Invokes the topmost registered handler in LIFO order.
  /// Returns `true` if a floating layer was dismissed.
  bool dismissTopmost() {
    if (_handlers.isEmpty) return false;
    final snapshot = List<bool Function()>.from(_handlers);
    for (var i = snapshot.length - 1; i >= 0; i--) {
      final handler = snapshot[i];
      if (!_handlers.contains(handler)) continue;
      if (handler()) {
        return true;
      }
    }
    return false;
  }

  /// Marks an active global Keyboard host (e.g. HomeScreen) so standalone
  /// fallback handling stays inactive while the unified 5-level handler owns Esc.
  void registerGlobalHost() {
    _globalHostCount++;
    _syncFallbackHandler();
  }

  void unregisterGlobalHost() {
    if (_globalHostCount > 0) {
      _globalHostCount--;
    }
    _syncFallbackHandler();
  }

  @visibleForTesting
  void clear() {
    _handlers.clear();
    _syncFallbackHandler();
  }

  void _syncFallbackHandler() {
    final shouldInstall = _globalHostCount == 0 && _handlers.isNotEmpty;
    if (shouldInstall == _fallbackHandlerInstalled) return;
    try {
      if (shouldInstall) {
        HardwareKeyboard.instance.addHandler(_handleFallbackKey);
        _fallbackHandlerInstalled = true;
      } else {
        HardwareKeyboard.instance.removeHandler(_handleFallbackKey);
        _fallbackHandlerInstalled = false;
      }
    } catch (_) {
      // ServicesBinding may not be initialized in pure Dart unit tests.
      _fallbackHandlerInstalled = false;
    }
  }

  bool _handleFallbackKey(KeyEvent event) {
    if (_globalHostCount > 0 || !hasActive) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;
    if (event is KeyRepeatEvent) return true;
    if (event is! KeyDownEvent) return false;
    return dismissTopmost();
  }
}
