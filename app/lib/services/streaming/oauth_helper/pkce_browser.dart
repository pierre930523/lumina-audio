import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../../../models/streaming_models.dart';

/// RFC 7636 PKCE verifier and S256 challenge pair.
class PkcePair {
  final String verifier;
  final String challenge;

  const PkcePair({
    required this.verifier,
    required this.challenge,
  });
}

/// Generates a cryptographically random PKCE verifier and S256 challenge.
PkcePair generatePkcePair({int byteLength = 48}) {
  final rng = Random.secure();
  final bytes = List<int>.generate(byteLength, (_) => rng.nextInt(256));
  final verifier = base64UrlEncode(bytes).replaceAll('=', '');
  final digest = sha256.convert(ascii.encode(verifier));
  final challenge = base64UrlEncode(digest.bytes).replaceAll('=', '');
  return PkcePair(verifier: verifier, challenge: challenge);
}

/// Generates an opaque CSRF state token for OAuth authorization URLs.
String generateOAuthState({int byteLength = 24}) {
  final rng = Random.secure();
  final bytes = List<int>.generate(byteLength, (_) => rng.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

/// Opens an `http://` or `https://` URL in the user's default system browser.
///
/// Prefers the native `lumina/window` `openUrl` MethodChannel (backed by
/// Win32 `ShellExecuteW`), falling back on Windows to `cmd /c start`.
/// Strictly rejects non-HTTP(S) schemes.
Future<bool> openSystemBrowser(
  String url, {
  MethodChannel? channel,
  Future<bool> Function(String url)? urlOpener,
}) async {
  final trimmed = url.trim();
  if (trimmed.contains('\r') ||
      trimmed.contains('\n') ||
      trimmed.contains('\x00')) {
    throw const StreamingException('不合法的瀏覽器網址字元');
  }
  final uri = Uri.tryParse(trimmed);
  final scheme = uri?.scheme.toLowerCase();
  if (uri == null ||
      (scheme != 'http' && scheme != 'https') ||
      uri.host.isEmpty) {
    throw StreamingException('僅允許開啟 http:// 或 https:// 網址：$url');
  }

  if (urlOpener != null) {
    return urlOpener(trimmed);
  }

  final ch = channel ?? const MethodChannel('lumina/window');
  try {
    await ch.invokeMethod<dynamic>('openUrl', trimmed);
    return true;
  } on MissingPluginException {
    // Fall back below on desktop OSes when MethodChannel is unavailable.
  } on PlatformException catch (e) {
    throw StreamingException('無法透過原生視窗開啟瀏覽器：${e.message ?? e.code}');
  }

  if (Platform.isWindows) {
    await Process.start('cmd', <String>['/c', 'start', '', trimmed]);
    return true;
  }
  if (Platform.isMacOS) {
    await Process.start('open', <String>[trimmed]);
    return true;
  }
  if (Platform.isLinux) {
    await Process.start('xdg-open', <String>[trimmed]);
    return true;
  }
  return false;
}
