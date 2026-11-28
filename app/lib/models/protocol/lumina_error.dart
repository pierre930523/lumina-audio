import 'package:flutter/foundation.dart';

import 'json_reader.dart';

/// Canonical cross-mode error code enum matching Rust `core_types::LuminaErrorCode`.
enum LuminaErrorCode {
  deviceOpenFailed('device_open_failed'),
  exclusiveModeConflict('exclusive_mode_conflict'),
  deviceNotFound('device_not_found'),
  deviceLost('device_lost'),
  streamResolveTimeout('stream_resolve_timeout'),
  streamAuthRequired('stream_auth_required'),
  networkDisconnected('network_disconnected'),
  httpError('http_error'),
  decodeFailed('decode_failed'),
  unsupportedFormat('unsupported_format'),
  invalidCommand('invalid_command'),
  invalidState('invalid_state'),
  notInitialized('not_initialized'),
  databaseError('database_error'),
  internal('internal');

  final String wireName;

  const LuminaErrorCode(this.wireName);

  static LuminaErrorCode fromWireName(String? raw) {
    final normalized = raw?.trim().toLowerCase() ?? '';
    for (final value in LuminaErrorCode.values) {
      if (value.wireName == normalized) {
        return value;
      }
    }
    return switch (normalized) {
      'auth_required' => LuminaErrorCode.streamAuthRequired,
      'device_in_use' => LuminaErrorCode.exclusiveModeConflict,
      'timeout' => LuminaErrorCode.streamResolveTimeout,
      'disconnected' => LuminaErrorCode.networkDisconnected,
      _ => LuminaErrorCode.internal,
    };
  }
}

/// Canonical structured error matching Rust `core_types::LuminaError`.
@immutable
class LuminaError implements Exception {
  final LuminaErrorCode code;
  final String message;
  final bool retryable;
  final String? provider;
  final int? httpStatus;
  final String? details;

  const LuminaError({
    required this.code,
    required this.message,
    this.retryable = false,
    this.provider,
    this.httpStatus,
    this.details,
  });

  factory LuminaError.fromJson(Map<String, Object?> json) {
    final r = JsonReader(json);
    return LuminaError(
      code: LuminaErrorCode.fromWireName(r.optionalString('code')),
      message: r.requiredString(
        'message',
        fallback: r.optionalString('error') ?? 'Unknown error',
      ),
      retryable: r.requiredBool('retryable', fallback: false),
      provider: r.nonEmptyString('provider'),
      httpStatus: r.optionalInt('http_status'),
      details: r.nonEmptyString('details'),
    );
  }

  /// Parses either a canonical `LuminaError` JSON object or a legacy
  /// `{"status":"error","error":"..."}` envelope.
  static LuminaError? tryParseJson(
    Map<String, Object?>? json, {
    int? fallbackHttpStatus,
  }) {
    if (json == null) return null;
    final r = JsonReader(json);
    if (r.containsKey('code') && r.containsKey('message')) {
      return LuminaError.fromJson(json);
    }
    final nestedError = r.optionalMap('error');
    if (nestedError != null) {
      return LuminaError.fromJson(nestedError);
    }
    final legacyErr = r.nonEmptyString('error') ?? r.nonEmptyString('last_error');
    if (legacyErr == null) return null;
    final legacyCode = r.nonEmptyString('last_error_code');
    final inferredCode = legacyCode != null
        ? LuminaErrorCode.fromWireName(legacyCode)
        : (fallbackHttpStatus != null && fallbackHttpStatus >= 400
              ? LuminaErrorCode.httpError
              : LuminaErrorCode.internal);
    return LuminaError(
      code: inferredCode,
      message: legacyErr,
      retryable: inferredCode == LuminaErrorCode.networkDisconnected ||
          inferredCode == LuminaErrorCode.streamResolveTimeout ||
          (fallbackHttpStatus != null && fallbackHttpStatus >= 500),
      provider: r.nonEmptyString('last_error_provider') ??
          r.nonEmptyString('provider'),
      httpStatus: r.optionalInt('http_status') ?? fallbackHttpStatus,
      details: r.nonEmptyString('details'),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'code': code.wireName,
      'message': message,
      'retryable': retryable,
      if (provider != null) 'provider': provider,
      if (httpStatus != null) 'http_status': httpStatus,
      if (details != null) 'details': details,
    };
  }

  LuminaError copyWith({
    LuminaErrorCode? code,
    String? message,
    bool? retryable,
    String? provider,
    int? httpStatus,
    String? details,
  }) {
    return LuminaError(
      code: code ?? this.code,
      message: message ?? this.message,
      retryable: retryable ?? this.retryable,
      provider: provider ?? this.provider,
      httpStatus: httpStatus ?? this.httpStatus,
      details: details ?? this.details,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LuminaError &&
        other.code == code &&
        other.message == message &&
        other.retryable == retryable &&
        other.provider == provider &&
        other.httpStatus == httpStatus &&
        other.details == details;
  }

  @override
  int get hashCode =>
      Object.hash(code, message, retryable, provider, httpStatus, details);

  @override
  String toString() =>
      'LuminaError(${code.wireName}: $message'
      '${provider != null ? ' [provider=$provider]' : ''}'
      '${httpStatus != null ? ' [http=$httpStatus]' : ''}'
      '${retryable ? ' [retryable]' : ''})';
}
