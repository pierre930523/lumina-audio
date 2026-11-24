import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Lightweight, zero-dependency desktop window controller for Windows.
/// Communicates with native runner via the `lumina/window` method channel.
class DesktopWindowController {
  static const MethodChannel _defaultChannel = MethodChannel('lumina/window');
  static DesktopWindowController? _instance;

  static DesktopWindowController get instance =>
      _instance ??= DesktopWindowController();

  static set instance(DesktopWindowController? value) => _instance = value;

  static DesktopWindowController get windowManager => instance;

  final MethodChannel channel;
  final bool? isSupportedOverride;

  final ValueNotifier<bool> isFullScreenNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isMinimizedNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isHiddenToTrayNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isMaximizedNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> isFocusedNotifier = ValueNotifier<bool>(true);

  bool wasMaximizedBeforeFullScreen = false;
  Rect? savedBoundsBeforeFullScreen;
  bool _isFullScreenTransitioning = false;

  VoidCallback? _onWindowClose;
  VoidCallback? get onWindowClose => _onWindowClose;
  set onWindowClose(VoidCallback? callback) {
    _onWindowClose = callback;
    if (callback != null) {
      _installMethodHandler();
    }
  }

  VoidCallback? _onTrayClick;
  VoidCallback? get onTrayClick => _onTrayClick;
  set onTrayClick(VoidCallback? callback) {
    _onTrayClick = callback;
    if (callback != null) {
      _installMethodHandler();
    }
  }

  VoidCallback? _onSingleInstanceWakeup;
  VoidCallback? get onSingleInstanceWakeup => _onSingleInstanceWakeup;
  set onSingleInstanceWakeup(VoidCallback? callback) {
    _onSingleInstanceWakeup = callback;
    if (callback != null) {
      _installMethodHandler();
    }
  }

  void Function(String action)? _onTrayMenuAction;
  void Function(String action)? get onTrayMenuAction => _onTrayMenuAction;
  set onTrayMenuAction(void Function(String action)? callback) {
    _onTrayMenuAction = callback;
    if (callback != null) {
      _installMethodHandler();
    }
  }

  VoidCallback? _onWindowMinimize;
  VoidCallback? get onWindowMinimize => _onWindowMinimize;
  set onWindowMinimize(VoidCallback? callback) {
    _onWindowMinimize = callback;
    if (callback != null) {
      _installMethodHandler();
    }
  }

  VoidCallback? _onWindowRestore;
  VoidCallback? get onWindowRestore => _onWindowRestore;
  set onWindowRestore(VoidCallback? callback) {
    _onWindowRestore = callback;
    if (callback != null) {
      _installMethodHandler();
    }
  }

  VoidCallback? _onWindowMaximize;
  VoidCallback? get onWindowMaximize => _onWindowMaximize;
  set onWindowMaximize(VoidCallback? callback) {
    _onWindowMaximize = callback;
    if (callback != null) {
      _installMethodHandler();
    }
  }

  VoidCallback? _onWindowUnmaximize;
  VoidCallback? get onWindowUnmaximize => _onWindowUnmaximize;
  set onWindowUnmaximize(VoidCallback? callback) {
    _onWindowUnmaximize = callback;
    if (callback != null) {
      _installMethodHandler();
    }
  }

  VoidCallback? _onWindowFocus;
  VoidCallback? get onWindowFocus => _onWindowFocus;
  set onWindowFocus(VoidCallback? callback) {
    _onWindowFocus = callback;
    if (callback != null) {
      _installMethodHandler();
    }
  }

  VoidCallback? _onWindowBlur;
  VoidCallback? get onWindowBlur => _onWindowBlur;
  set onWindowBlur(VoidCallback? callback) {
    _onWindowBlur = callback;
    if (callback != null) {
      _installMethodHandler();
    }
  }

  DesktopWindowController({
    MethodChannel? channel,
    this.isSupportedOverride,
    bool installMethodHandler = true,
  }) : channel = channel ?? _defaultChannel {
    if (installMethodHandler) {
      _installMethodHandler();
    }
  }

  void _installMethodHandler() {
    try {
      channel.setMethodCallHandler(handleIncomingCall);
    } catch (_) {
      // ServicesBinding may not be initialized in pure unit tests.
    }
  }

  @visibleForTesting
  Future<dynamic> handleIncomingCall(MethodCall call) async {
    switch (call.method) {
      case 'onWindowClose':
        _onWindowClose?.call();
        return null;
      case 'onTrayClick':
        _onTrayClick?.call();
        return null;
      case 'onSingleInstanceWakeup':
        _onSingleInstanceWakeup?.call();
        return null;
      case 'onTrayMenuAction':
        final action = call.arguments?.toString();
        if (action != null && action.isNotEmpty) {
          _onTrayMenuAction?.call(action);
        }
        return null;
      case 'onWindowMinimize':
        isMinimizedNotifier.value = true;
        _onWindowMinimize?.call();
        return null;
      case 'onWindowRestore':
        isMinimizedNotifier.value = false;
        isHiddenToTrayNotifier.value = false;
        _onWindowRestore?.call();
        return null;
      case 'onWindowMaximize':
        isMinimizedNotifier.value = false;
        isHiddenToTrayNotifier.value = false;
        isMaximizedNotifier.value = true;
        _onWindowMaximize?.call();
        return null;
      case 'onWindowUnmaximize':
        isMinimizedNotifier.value = false;
        isHiddenToTrayNotifier.value = false;
        isMaximizedNotifier.value = false;
        _onWindowUnmaximize?.call();
        return null;
      case 'onWindowFocus':
        isMinimizedNotifier.value = false;
        isHiddenToTrayNotifier.value = false;
        isFocusedNotifier.value = true;
        _onWindowFocus?.call();
        return null;
      case 'onWindowBlur':
        isFocusedNotifier.value = false;
        _onWindowBlur?.call();
        return null;
      default:
        return null;
    }
  }

  bool get isSupported {
    if (isSupportedOverride != null) return isSupportedOverride!;
    if (kIsWeb) return false;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return false;
    return Platform.isWindows;
  }

  Future<void> minimize() async {
    isMinimizedNotifier.value = true;
    if (!isSupported) return;
    try {
      await channel.invokeMethod('minimize');
    } catch (_) {}
  }

  Future<void> maximize() async {
    if (!isSupported) return;
    try {
      await channel.invokeMethod('maximize');
    } catch (_) {}
  }

  Future<void> restore() async {
    isMinimizedNotifier.value = false;
    if (!isSupported) return;
    try {
      await channel.invokeMethod('restore');
    } catch (_) {}
  }

  Future<void> unmaximize() async {
    isMinimizedNotifier.value = false;
    if (!isSupported) return;
    try {
      await channel.invokeMethod('unmaximize');
    } catch (_) {}
  }

  Future<void> toggleMaximize() async {
    if (!isSupported) return;
    try {
      await channel.invokeMethod('toggleMaximize');
    } catch (_) {}
  }

  Future<bool> isMaximized() async {
    if (!isSupported) return isMaximizedNotifier.value;
    try {
      final res = await channel.invokeMethod<bool>('isMaximized');
      final val = res ?? isMaximizedNotifier.value;
      isMaximizedNotifier.value = val;
      return val;
    } catch (_) {
      return isMaximizedNotifier.value;
    }
  }

  Future<Rect> getBounds() async {
    if (!isSupported) return Rect.zero;
    try {
      final res = await channel.invokeMethod<Map>('getBounds');
      if (res != null) {
        final x = (res['x'] as num?)?.toDouble() ?? 0.0;
        final y = (res['y'] as num?)?.toDouble() ?? 0.0;
        final width = (res['width'] as num?)?.toDouble() ?? 0.0;
        final height = (res['height'] as num?)?.toDouble() ?? 0.0;
        return Rect.fromLTWH(x, y, width, height);
      }
    } catch (_) {}
    return Rect.zero;
  }

  Future<void> setBounds(Rect bounds) async {
    if (!isSupported) return;
    try {
      await channel.invokeMethod('setBounds', <String, dynamic>{
        'x': bounds.left,
        'y': bounds.top,
        'width': bounds.width,
        'height': bounds.height,
      });
    } catch (_) {}
  }

  Future<bool> isFullScreen() async {
    if (!isSupported) return isFullScreenNotifier.value;
    try {
      final res = await channel.invokeMethod<bool>('isFullScreen');
      final val = res ?? isFullScreenNotifier.value;
      isFullScreenNotifier.value = val;
      return val;
    } catch (_) {
      return isFullScreenNotifier.value;
    }
  }

  Future<void> setFullScreen(bool isFullScreen) async {
    if (_isFullScreenTransitioning) return;
    if (isFullScreenNotifier.value == isFullScreen) return;

    _isFullScreenTransitioning = true;
    try {
      if (isFullScreen) {
        final maximized = await isMaximized();
        if (maximized) {
          wasMaximizedBeforeFullScreen = true;
          savedBoundsBeforeFullScreen = null;
          await unmaximize();
          // Give Windows a brief moment to finish unmaximizing
          if (isSupported) {
            await Future.delayed(const Duration(milliseconds: 20));
          }
        } else {
          wasMaximizedBeforeFullScreen = false;
          savedBoundsBeforeFullScreen = await getBounds();
        }

        isFullScreenNotifier.value = true;
        if (isSupported) {
          try {
            await channel.invokeMethod('setFullScreen', true);
          } catch (_) {}
        }
      } else {
        isFullScreenNotifier.value = false;
        if (isSupported) {
          try {
            await channel.invokeMethod('setFullScreen', false);
          } catch (_) {}
        }

        if (wasMaximizedBeforeFullScreen) {
          wasMaximizedBeforeFullScreen = false;
          await maximize();
        } else {
          if (savedBoundsBeforeFullScreen != null &&
              savedBoundsBeforeFullScreen != Rect.zero) {
            await setBounds(savedBoundsBeforeFullScreen!);
          }
          savedBoundsBeforeFullScreen = null;
        }
      }
    } finally {
      _isFullScreenTransitioning = false;
    }
  }

  Future<void> toggleFullScreen() async {
    final cur = await isFullScreen();
    await setFullScreen(!cur);
  }

  Future<void> close() async {
    if (!isSupported) return;
    try {
      await channel.invokeMethod('close');
    } catch (_) {}
  }

  Future<void> startDragging() async {
    if (!isSupported) return;
    try {
      await channel.invokeMethod('startDragging');
    } catch (_) {}
  }

  Future<void> setPreventClose(bool prevent) async {
    if (!isSupported) return;
    _installMethodHandler();
    try {
      await channel.invokeMethod('setPreventClose', prevent);
    } catch (_) {}
  }

  Future<void> hide() async {
    isHiddenToTrayNotifier.value = true;
    if (!isSupported) return;
    try {
      await channel.invokeMethod('hide');
    } catch (_) {}
  }

  Future<void> show() async {
    isHiddenToTrayNotifier.value = false;
    isMinimizedNotifier.value = false;
    if (!isSupported) return;
    try {
      await channel.invokeMethod('show');
    } catch (_) {}
  }

  Future<void> focus() async {
    isMinimizedNotifier.value = false;
    if (!isSupported) return;
    try {
      await channel.invokeMethod('focus');
    } catch (_) {}
  }

  Future<void> destroy() async {
    isHiddenToTrayNotifier.value = false;
    if (!isSupported) return;
    try {
      await channel.invokeMethod('destroy');
    } catch (_) {}
  }

  Future<void> initTray({
    String tooltip = 'Lumina Audio',
    String nowPlayingLabel = 'Lumina Audio — 待機中',
    bool isPlaying = false,
  }) async {
    if (!isSupported) return;
    _installMethodHandler();
    try {
      await channel.invokeMethod('trayInit', <String, dynamic>{
        'tooltip': tooltip,
        'nowPlayingLabel': nowPlayingLabel,
        'isPlaying': isPlaying,
      });
    } catch (_) {}
  }

  Future<void> updateTray({
    String? tooltip,
    String? nowPlayingLabel,
    bool? isPlaying,
  }) async {
    if (!isSupported) return;
    final args = <String, dynamic>{
      'tooltip': ?tooltip,
      'nowPlayingLabel': ?nowPlayingLabel,
      'isPlaying': ?isPlaying,
    };
    try {
      await channel.invokeMethod('trayUpdate', args);
    } catch (_) {}
  }

  Future<void> destroyTray() async {
    if (!isSupported) return;
    try {
      await channel.invokeMethod('trayDestroy');
    } catch (_) {}
  }

  Future<bool> openUrl(String url) async {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return false;
    }
    if (!isSupported) return false;
    try {
      final res = await channel.invokeMethod<dynamic>('openUrl', trimmed);
      if (res is bool) return res;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> dpapiProtect(String plaintext) async {
    if (!isSupported) return null;
    try {
      return await channel.invokeMethod<String>('dpapiProtect', plaintext);
    } catch (_) {
      return null;
    }
  }

  Future<String?> dpapiUnprotect(String ciphertextBase64) async {
    if (!isSupported) return null;
    try {
      return await channel.invokeMethod<String>(
        'dpapiUnprotect',
        ciphertextBase64,
      );
    } catch (_) {
      return null;
    }
  }
}
