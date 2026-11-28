import 'package:flutter/foundation.dart';

import '../studio_models.dart';
import 'lumina_error.dart';

/// Transport connection lifecycle state exposed across FFI, Remote, and Mock modes.
enum ConnectionPhase {
  disconnected,
  connecting,
  connected,
  reconnecting,
  failed,
}

@immutable
class ConnectionStatus {
  final ConnectionPhase phase;
  final ConnectionMode mode;
  final String? endpointUrl;
  final int reconnectAttempt;
  final Duration? nextRetryDelay;
  final int? lastConnectedAtMs;
  final LuminaError? lastError;

  const ConnectionStatus({
    required this.phase,
    required this.mode,
    this.endpointUrl,
    this.reconnectAttempt = 0,
    this.nextRetryDelay,
    this.lastConnectedAtMs,
    this.lastError,
  });

  const ConnectionStatus.localConnected()
      : phase = ConnectionPhase.connected,
        mode = ConnectionMode.localOrUsbDac,
        endpointUrl = null,
        reconnectAttempt = 0,
        nextRetryDelay = null,
        lastConnectedAtMs = null,
        lastError = null;

  bool get isConnected => phase == ConnectionPhase.connected;

  ConnectionStatus copyWith({
    ConnectionPhase? phase,
    ConnectionMode? mode,
    String? endpointUrl,
    bool clearEndpointUrl = false,
    int? reconnectAttempt,
    Duration? nextRetryDelay,
    bool clearNextRetryDelay = false,
    int? lastConnectedAtMs,
    LuminaError? lastError,
    bool clearLastError = false,
  }) {
    return ConnectionStatus(
      phase: phase ?? this.phase,
      mode: mode ?? this.mode,
      endpointUrl: clearEndpointUrl ? null : (endpointUrl ?? this.endpointUrl),
      reconnectAttempt: reconnectAttempt ?? this.reconnectAttempt,
      nextRetryDelay: clearNextRetryDelay
          ? null
          : (nextRetryDelay ?? this.nextRetryDelay),
      lastConnectedAtMs: lastConnectedAtMs ?? this.lastConnectedAtMs,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ConnectionStatus &&
        other.phase == phase &&
        other.mode == mode &&
        other.endpointUrl == endpointUrl &&
        other.reconnectAttempt == reconnectAttempt &&
        other.nextRetryDelay == nextRetryDelay &&
        other.lastConnectedAtMs == lastConnectedAtMs &&
        other.lastError == lastError;
  }

  @override
  int get hashCode => Object.hash(
        phase,
        mode,
        endpointUrl,
        reconnectAttempt,
        nextRetryDelay,
        lastConnectedAtMs,
        lastError,
      );
}
