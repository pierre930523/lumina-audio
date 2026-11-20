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

  final MethodChannel channel;
  final bool? isSupportedOverride;

  DesktopWindowController({
    MethodChannel? channel,
    this.isSupportedOverride,
  }) : channel = channel ?? _defaultChannel;

  bool get isSupported {
    if (isSupportedOverride != null) return isSupportedOverride!;
    if (kIsWeb) return false;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return false;
    return Platform.isWindows;
  }

  Future<void> minimize() async {
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
    if (!isSupported) return;
    try {
      await channel.invokeMethod('restore');
    } catch (_) {}
  }

  Future<void> toggleMaximize() async {
    if (!isSupported) return;
    try {
      await channel.invokeMethod('toggleMaximize');
    } catch (_) {}
  }

  Future<bool> isMaximized() async {
    if (!isSupported) return false;
    try {
      final res = await channel.invokeMethod<bool>('isMaximized');
      return res ?? false;
    } catch (_) {
      return false;
    }
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
}
