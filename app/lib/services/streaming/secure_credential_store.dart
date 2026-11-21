import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../models/streaming_models.dart';

/// Encrypted persistent storage contract for streaming tokens and cookies.
abstract class SecureCredentialStore {
  Future<void> write(String key, String plaintext);
  Future<String?> read(String key);
  Future<void> delete(String key);
  Future<void> clearAll();
}

/// Windows DPAPI (`CryptProtectData` / `CryptUnprotectData`) credential store.
///
/// Encrypts secrets via the native `lumina/window` MethodChannel (or injected
/// callbacks for unit testing) and writes ONLY Base64 DPAPI ciphertext blobs to
/// `%LOCALAPPDATA%\LuminaAudio\credentials.dpapi.json` using atomic temp-file
/// write + rename. Plaintext secrets are NEVER written to disk.
class WindowsDpapiCredentialStore implements SecureCredentialStore {
  static const MethodChannel _defaultChannel = MethodChannel('lumina/window');

  final MethodChannel _channel;
  final File _storageFile;
  final Future<String?> Function(String plaintext)? protectFn;
  final Future<String?> Function(String ciphertextBase64)? unprotectFn;

  Future<void> _queue = Future<void>.value();

  WindowsDpapiCredentialStore({
    MethodChannel? channel,
    File? storageFile,
    this.protectFn,
    this.unprotectFn,
  })  : _channel = channel ?? _defaultChannel,
        _storageFile = storageFile ?? defaultStorageFile();

  File get storageFile => _storageFile;

  static File defaultStorageFile() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final baseDir = (localAppData != null && localAppData.trim().isNotEmpty)
        ? localAppData.trim()
        : Directory.systemTemp.path;
    final sep = Platform.pathSeparator;
    return File('$baseDir${sep}LuminaAudio${sep}credentials.dpapi.json');
  }

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        final result = await action();
        if (!completer.isCompleted) completer.complete(result);
      } catch (e, st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<String> _protect(String plaintext) async {
    try {
      final cipher = protectFn != null
          ? await protectFn!(plaintext)
          : await _channel.invokeMethod<String>('dpapiProtect', plaintext);
      if (cipher == null || cipher.trim().isEmpty) {
        throw const StreamingException(
          'Windows DPAPI 加密回傳空值，已中止寫入以防止明文洩漏',
        );
      }
      return cipher;
    } on StreamingException {
      rethrow;
    } on MissingPluginException catch (e) {
      throw StreamingException(
        'Windows DPAPI 原生通道未就緒，無法安全儲存憑證：${e.message ?? 'MissingPluginException'}',
      );
    } on PlatformException catch (e) {
      throw StreamingException(
        'Windows DPAPI 加密失敗：${e.message ?? e.code}',
      );
    }
  }

  Future<String> _unprotect(String ciphertextBase64) async {
    try {
      final plain = unprotectFn != null
          ? await unprotectFn!(ciphertextBase64)
          : await _channel.invokeMethod<String>(
              'dpapiUnprotect',
              ciphertextBase64,
            );
      if (plain == null) {
        throw const StreamingException('Windows DPAPI 解密回傳空值，憑證可能已損毀');
      }
      return plain;
    } on StreamingException {
      rethrow;
    } on MissingPluginException catch (e) {
      throw StreamingException(
        'Windows DPAPI 原生通道未就緒，無法解密憑證：${e.message ?? 'MissingPluginException'}',
      );
    } on PlatformException catch (e) {
      throw StreamingException(
        'Windows DPAPI 解密失敗：${e.message ?? e.code}',
      );
    }
  }

  Map<String, String> _readCipherMapSync() {
    if (!_storageFile.existsSync()) {
      return <String, String>{};
    }
    try {
      final raw = _storageFile.readAsStringSync();
      if (raw.trim().isEmpty) return <String, String>{};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return <String, String>{};
      }
      final result = <String, String>{};
      for (final entry in decoded.entries) {
        final k = entry.key?.toString();
        final v = entry.value?.toString();
        if (k != null && k.isNotEmpty && v != null && v.isNotEmpty) {
          result[k] = v;
        }
      }
      return result;
    } catch (_) {
      return <String, String>{};
    }
  }

  void _writeCipherMapAtomicSync(Map<String, String> entries) {
    final parent = _storageFile.parent;
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }
    final tmpFile = File('${_storageFile.path}.tmp');
    final encoded = const JsonEncoder.withIndent('  ').convert(entries);
    tmpFile.writeAsStringSync(encoded, flush: true);
    try {
      tmpFile.renameSync(_storageFile.path);
    } catch (_) {
      if (_storageFile.existsSync()) {
        _storageFile.deleteSync();
      }
      tmpFile.renameSync(_storageFile.path);
    }
  }

  @override
  Future<void> write(String key, String plaintext) {
    return _synchronized(() async {
      final ciphertext = await _protect(plaintext);
      final map = _readCipherMapSync();
      map[key] = ciphertext;
      _writeCipherMapAtomicSync(map);
    });
  }

  @override
  Future<String?> read(String key) {
    return _synchronized(() async {
      final map = _readCipherMapSync();
      final ciphertext = map[key];
      if (ciphertext == null || ciphertext.isEmpty) {
        return null;
      }
      return _unprotect(ciphertext);
    });
  }

  @override
  Future<void> delete(String key) {
    return _synchronized(() async {
      if (!_storageFile.existsSync()) return;
      final map = _readCipherMapSync();
      if (!map.containsKey(key)) return;
      map.remove(key);
      _writeCipherMapAtomicSync(map);
    });
  }

  @override
  Future<void> clearAll() {
    return _synchronized(() async {
      final tmpFile = File('${_storageFile.path}.tmp');
      if (tmpFile.existsSync()) {
        tmpFile.deleteSync();
      }
      if (_storageFile.existsSync()) {
        _storageFile.deleteSync();
      }
    });
  }
}

/// Ephemeral in-memory credential store for unit and widget tests.
class MemorySecureCredentialStore implements SecureCredentialStore {
  final Map<String, String> _entries = <String, String>{};

  Map<String, String> get debugEntries => Map<String, String>.unmodifiable(_entries);

  @override
  Future<void> write(String key, String plaintext) async {
    _entries[key] = plaintext;
  }

  @override
  Future<String?> read(String key) async => _entries[key];

  @override
  Future<void> delete(String key) async {
    _entries.remove(key);
  }

  @override
  Future<void> clearAll() async {
    _entries.clear();
  }
}
