import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/audio_quality_tier.dart';
import '../../models/playback_state.dart';
import '../../models/signal_path.dart';
import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../../services/escape_dismiss_registry.dart';
import '../../services/ui_scale_controller.dart';
import '../theme/lumina_glass_theme.dart';
import '../theme/lumina_tokens.dart';
import 'audio_quality_badge.dart';
import 'bottom_player_bar_scope.dart';
import 'frosted_glass_container.dart';

part 'audio_info_popover_card.dart';
part 'audio_info_popover_anchor.dart';

/// Formats a raw backend identifier (e.g. `windows_asio`,
/// `windows_wasapi_exclusive`) into a crisp user-facing label.
String formatAudioBackendLabel(String rawBackend) {
  final normalized = rawBackend.trim().toLowerCase();
  if (normalized.isEmpty) return '';
  if (normalized == 'windows_asio' || normalized.contains('asio')) {
    return 'ASIO';
  }
  if (normalized == 'windows_wasapi_exclusive' ||
      normalized.contains('wasapi_exclusive') ||
      normalized.contains('wasapi exclusive')) {
    return 'WASAPI Exclusive';
  }
  if (normalized == 'windows_wasapi_shared' ||
      normalized.contains('wasapi_shared') ||
      normalized.contains('wasapi shared')) {
    return 'WASAPI Shared';
  }
  if (normalized.contains('wasapi')) {
    return 'WASAPI';
  }
  if (normalized == 'macos_core_audio_hog' ||
      normalized.contains('core_audio')) {
    return 'CoreAudio Exclusive';
  }
  if (normalized == 'mobile_direct') {
    return 'Direct USB DAC';
  }
  if (normalized == 'network_dlna' || normalized.contains('dlna')) {
    return 'DLNA';
  }
  if (normalized == 'network_airplay' || normalized.contains('airplay')) {
    return 'AirPlay';
  }
  return rawBackend.trim();
}

/// Formats an output backend and hardware device name as `<backend>: <name>`.
String formatAudioOutputDeviceLabel({
  required String backend,
  required String deviceName,
}) {
  final cleanName = deviceName.trim();
  final cleanBackend = formatAudioBackendLabel(backend);
  if (cleanName.isEmpty) {
    return cleanBackend.isNotEmpty ? cleanBackend : '系統預設輸出';
  }
  if (cleanBackend.isEmpty) return cleanName;
  return '$cleanBackend: $cleanName';
}

/// Controller allowing a parent container (such as `FloatingCapsuleMiniPlayer`)
/// to coordinate closing [AudioQualityBadgeWithPopover] alongside sibling
/// popovers.
class AudioInfoPopoverController extends ChangeNotifier {
  VoidCallback? _toggleCallback;
  VoidCallback? _closeCallback;
  bool _isOpen = false;

  bool get isOpen => _isOpen;

  void _attach({
    required VoidCallback toggle,
    required VoidCallback close,
    required bool isOpen,
  }) {
    _toggleCallback = toggle;
    _closeCallback = close;
    _isOpen = isOpen;
  }

  void _detach(VoidCallback close) {
    if (_closeCallback == close) {
      _toggleCallback = null;
      _closeCallback = null;
      _isOpen = false;
    }
  }

  void _setOpen(bool open) {
    if (_isOpen == open) return;
    _isOpen = open;
    notifyListeners();
  }

  void toggle() => _toggleCallback?.call();

  void close() => _closeCallback?.call();
}
