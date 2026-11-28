import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Credentials passed to `lumina/external_playback` `configure`.
@immutable
class AppleMusicCredentials {
  final String developerToken;
  final String musicUserToken;
  final String storefront;

  const AppleMusicCredentials({
    required this.developerToken,
    required this.musicUserToken,
    this.storefront = 'us',
  });

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is AppleMusicCredentials &&
            other.developerToken == developerToken &&
            other.musicUserToken == musicUserToken &&
            other.storefront == storefront);
  }

  @override
  int get hashCode => Object.hash(developerToken, musicUserToken, storefront);
}

/// State update payload emitted from the host external playback bridge.
@immutable
class ExternalPlaybackEvent {
  final int epoch;
  final String status;
  final int positionMs;
  final int durationMs;
  final String? error;

  const ExternalPlaybackEvent({
    required this.epoch,
    required this.status,
    this.positionMs = 0,
    this.durationMs = 0,
    this.error,
  });

  factory ExternalPlaybackEvent.fromMap(Map<Object?, Object?> map) {
    return ExternalPlaybackEvent(
      epoch: (map['epoch'] as num?)?.toInt() ?? 0,
      status: map['status']?.toString().trim().toLowerCase() ?? 'stopped',
      positionMs: (map['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
      error: map['error']?.toString(),
    );
  }
}

/// Injectable platform bridge interface for external DRM playback hosts.
abstract interface class ExternalPlaybackBridge {
  void setStateHandler(void Function(ExternalPlaybackEvent event)? handler);
  Future<bool> isAvailable();
  Future<void> configure({
    required String developerToken,
    required String musicUserToken,
    String storefront = 'us',
  });
  Future<void> play({
    required String trackUri,
    String? previewUrl,
    required int epoch,
    String? externalWebUrl,
  });
  Future<void> pause({required int epoch});
  Future<void> resume({required int epoch});
  Future<void> seek({required Duration position, required int epoch});
  Future<void> setVolume(double volume);
  Future<void> stop({required int epoch});
  void dispose();
}

/// Default `MethodChannel('lumina/external_playback')` bridge communicating
/// with Win32 `ExternalMusicHost`. Gracefully handles [MissingPluginException]
/// when running headless or in tests.
class MethodChannelExternalPlaybackBridge implements ExternalPlaybackBridge {
  static const String channelName = 'lumina/external_playback';

  final MethodChannel _channel;
  void Function(ExternalPlaybackEvent event)? _stateHandler;
  bool _disposed = false;

  MethodChannelExternalPlaybackBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_handleHostCall);
  }

  Future<dynamic> _handleHostCall(MethodCall call) async {
    if (_disposed) return null;
    if (call.method == 'onState' && call.arguments is Map) {
      final event = ExternalPlaybackEvent.fromMap(
        call.arguments as Map<Object?, Object?>,
      );
      _stateHandler?.call(event);
    }
    return null;
  }

  @override
  void setStateHandler(void Function(ExternalPlaybackEvent event)? handler) {
    _stateHandler = handler;
  }

  @override
  Future<bool> isAvailable() async {
    if (_disposed) return false;
    try {
      final result = await _channel.invokeMethod<bool>('isAvailable');
      return result == true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> configure({
    required String developerToken,
    required String musicUserToken,
    String storefront = 'us',
  }) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>('configure', <String, dynamic>{
        'developerToken': developerToken,
        'musicUserToken': musicUserToken,
        'storefront': storefront,
      });
    } on MissingPluginException {
      // Headless / unsupported platform: fail gracefully.
    } on PlatformException {
      // Ignore host config failures; surfaced if play is invoked.
    }
  }

  @override
  Future<void> play({
    required String trackUri,
    String? previewUrl,
    required int epoch,
    String? externalWebUrl,
  }) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>('play', <String, dynamic>{
        'trackUri': trackUri,
        'previewUrl': ?previewUrl,
        'epoch': epoch,
        'externalWebUrl': ?externalWebUrl,
      });
    } on MissingPluginException {
      _stateHandler?.call(
        ExternalPlaybackEvent(
          epoch: epoch,
          status: 'error',
          error: 'Apple Music 外部播放宿主在此環境尚未就緒',
        ),
      );
    } on PlatformException catch (e) {
      _stateHandler?.call(
        ExternalPlaybackEvent(
          epoch: epoch,
          status: 'error',
          error: e.message ?? 'Apple Music 外部播放失敗',
        ),
      );
    }
  }

  @override
  Future<void> pause({required int epoch}) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>('pause', <String, dynamic>{
        'epoch': epoch,
      });
    } on MissingPluginException {
      // Headless / unsupported platform.
    } on PlatformException {
      // Ignore transient host errors on pause.
    }
  }

  @override
  Future<void> resume({required int epoch}) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>('resume', <String, dynamic>{
        'epoch': epoch,
      });
    } on MissingPluginException {
      // Headless / unsupported platform.
    } on PlatformException {
      // Ignore transient host errors on resume.
    }
  }

  @override
  Future<void> seek({required Duration position, required int epoch}) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>('seek', <String, dynamic>{
        'positionMs': position.inMilliseconds < 0 ? 0 : position.inMilliseconds,
        'epoch': epoch,
      });
    } on MissingPluginException {
      // Headless / unsupported platform.
    } on PlatformException {
      // Ignore transient host errors on seek.
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>('setVolume', <String, dynamic>{
        'volume': volume.clamp(0.0, 1.0),
      });
    } on MissingPluginException {
      // Headless / unsupported platform.
    } on PlatformException {
      // Ignore transient host errors on setVolume.
    }
  }

  @override
  Future<void> stop({required int epoch}) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>('stop', <String, dynamic>{
        'epoch': epoch,
      });
    } on MissingPluginException {
      // Headless / unsupported platform.
    } on PlatformException {
      // Ignore transient host errors on stop.
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stateHandler = null;
    _channel.setMethodCallHandler(null);
  }
}
