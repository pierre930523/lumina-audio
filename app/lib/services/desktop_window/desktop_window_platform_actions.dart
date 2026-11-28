part of '../desktop_window_controller.dart';

extension _DesktopWindowPlatformActions on DesktopWindowController {
  Future<void> _initTrayImpl({
    required String tooltip,
    required String nowPlayingLabel,
    required bool isPlaying,
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

  Future<void> _updateTrayImpl({
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

  Future<void> _updateSystemMediaControlsImpl({
    String? title,
    String? artist,
    String? album,
    String? artworkUrl,
    Duration? duration,
    Duration? position,
    bool isPlaying = false,
    String? tooltip,
    String? nowPlayingLabel,
  }) async {
    if (!isSupported) return;
    await updateTray(
      tooltip: tooltip,
      nowPlayingLabel: nowPlayingLabel,
      isPlaying: isPlaying,
    );
    try {
      final args = <String, dynamic>{
        'title': ?title,
        'artist': ?artist,
        'album': ?album,
        if (artworkUrl != null && artworkUrl.trim().isNotEmpty)
          'artworkUrl': artworkUrl.trim(),
        if (duration != null) 'durationMs': duration.inMilliseconds,
        if (position != null) 'positionMs': position.inMilliseconds,
        'isPlaying': isPlaying,
      };
      await channel.invokeMethod('mediaUpdateMetadata', args);
    } catch (_) {}
  }

  Future<void> _destroyTrayImpl() async {
    if (!isSupported) return;
    try {
      await channel.invokeMethod('trayDestroy');
    } catch (_) {}
  }

  Future<bool> _openUrlImpl(String url) async {
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

  Future<String?> _dpapiProtectImpl(String plaintext) async {
    if (!isSupported) return null;
    try {
      return await channel.invokeMethod<String>('dpapiProtect', plaintext);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _dpapiUnprotectImpl(String ciphertextBase64) async {
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
