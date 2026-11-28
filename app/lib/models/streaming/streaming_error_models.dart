import 'package:flutter/foundation.dart';

/// Cooperative cancellation token for multi-step OAuth / polling / sync flows.
class CancellationToken {
  bool _cancelled = false;
  final List<VoidCallback> _listeners = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final snapshot = List<VoidCallback>.from(_listeners);
    _listeners.clear();
    for (final cb in snapshot) {
      try {
        cb();
      } catch (_) {}
    }
  }

  void addListener(VoidCallback cb) {
    if (_cancelled) {
      cb();
      return;
    }
    _listeners.add(cb);
  }

  void removeListener(VoidCallback cb) {
    _listeners.remove(cb);
  }

  void throwIfCancelled() {
    if (_cancelled) {
      throw const StreamingException('操作已取消', isCancelled: true);
    }
  }
}

/// Structured error classification for streaming authentication, catalog sync,
/// and lazy stream URL resolution failures.
enum StreamingErrorKind {
  unknown,
  network,
  authExpired,
  drmRestricted,
  regionRestricted,
  trackUnavailable,
  rateLimited,
  cancelled,
  webViewUnavailable,
}

/// Structured exception thrown when real streaming API authentication, sync,
/// or stream resolution fails.
class StreamingException implements Exception {
  final String message;
  final int? statusCode;
  final bool isTokenExpired;
  final bool isDrmRestricted;
  final bool isCancelled;
  final bool isWebViewUnavailable;
  final StreamingErrorKind? _explicitKind;

  const StreamingException(
    this.message, {
    this.statusCode,
    this.isTokenExpired = false,
    this.isDrmRestricted = false,
    this.isCancelled = false,
    this.isWebViewUnavailable = false,
    StreamingErrorKind? kind,
  }) : _explicitKind = kind;

  /// Effective error classification, inferred from existing flags/statusCode
  /// when [kind] was not explicitly supplied.
  StreamingErrorKind get kind {
    final explicit = _explicitKind;
    if (explicit != null) return explicit;
    if (isCancelled) return StreamingErrorKind.cancelled;
    if (isWebViewUnavailable) return StreamingErrorKind.webViewUnavailable;
    if (isTokenExpired || statusCode == 401) {
      return StreamingErrorKind.authExpired;
    }
    if (statusCode == 451) return StreamingErrorKind.regionRestricted;
    if (statusCode == 429) return StreamingErrorKind.rateLimited;
    if (isDrmRestricted) return StreamingErrorKind.drmRestricted;
    if (statusCode == 404 || statusCode == 410) {
      return StreamingErrorKind.trackUnavailable;
    }
    return StreamingErrorKind.unknown;
  }

  bool get isRegionRestricted => kind == StreamingErrorKind.regionRestricted;

  bool get isUnavailable => kind == StreamingErrorKind.trackUnavailable;

  static final RegExp _regionPattern = RegExp(
    r'(geo[\s_-]?block|geo[\s_-]?restrict|region[\s_-]?restrict|'
    r'not\s+(?:made\s+this\s+video\s+)?available\s+in\s+your\s+(?:country|region|territory|location)|'
    r'unavailable\s+in\s+your\s+(?:country|region|territory|location)|'
    r'country[\s_-]?block|country[\s_-]?restrict|notavailableincountry|'
    r'territory[\s_-]?restrict|not\s+available\s+in\s+this\s+storefront|'
    r'blocked\s+in\s+your\s+country|地區限制|區域限制)',
    caseSensitive: false,
  );

  static final RegExp _unavailablePattern = RegExp(
    r'(takedown|taken\s+down|copyright\s+(?:claim|strike|removal)|'
    r'video\s+unavailable|track\s+unavailable|song\s+unavailable|'
    r'track\s+not\s+found|no\s+longer\s+available|has\s+been\s+removed|'
    r'removed\s+by\s+the\s+uploader|private\s+video|account\s+associated\s+with\s+this\s+video\s+has\s+been\s+terminated|'
    r'deleted\s+track|asset\s+not\s+ready\s+for\s+playback|not\s+streamable|'
    r'streamnotallowed|trackrestrictedbyrightholders|rights_error|data_error|no\s+data|'
    r'已下架|無法播放此曲目)',
    caseSensitive: false,
  );

  /// Classifies HTTP status codes and API error strings into a structured
  /// [StreamingErrorKind] for region-blocking, takedowns, and rate limits.
  static StreamingErrorKind? classifyKind({
    int? statusCode,
    String? message,
    bool isDrmRestricted = false,
  }) {
    if (statusCode == 451) return StreamingErrorKind.regionRestricted;
    final text = message?.trim() ?? '';
    if (text.isNotEmpty && _regionPattern.hasMatch(text)) {
      return StreamingErrorKind.regionRestricted;
    }
    if (statusCode == 404 || statusCode == 410) {
      return StreamingErrorKind.trackUnavailable;
    }
    if (text.isNotEmpty && _unavailablePattern.hasMatch(text)) {
      return StreamingErrorKind.trackUnavailable;
    }
    if (statusCode == 429) return StreamingErrorKind.rateLimited;
    if (isDrmRestricted) return StreamingErrorKind.drmRestricted;
    return null;
  }

  @override
  String toString() => statusCode != null
      ? 'StreamingException($statusCode): $message'
      : 'StreamingException: $message';
}
