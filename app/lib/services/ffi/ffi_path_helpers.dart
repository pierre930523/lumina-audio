part of '../ffi_audio_service.dart';

bool _ffiIsLoopbackUrl(String? url) {
  if (url == null || url.isEmpty) return false;
  final host = Uri.tryParse(url.trim())?.host.toLowerCase();
  return host == '127.0.0.1' || host == 'localhost' || host == '::1';
}

String _resolveFfiDatabasePath({
  String? databasePathOverride,
  String? localAppDataOverride,
  String? tempDirOverride,
  bool? isFlutterTestOverride,
}) {
  if (databasePathOverride != null && databasePathOverride.isNotEmpty) {
    return databasePathOverride;
  }
  final isTest =
      isFlutterTestOverride ?? Platform.environment.containsKey('FLUTTER_TEST');
  final tempRoot = tempDirOverride ?? Directory.systemTemp.path;
  final legacyPath =
      '$tempRoot${Platform.pathSeparator}lumina_desktop_library.db';
  if (isTest) {
    return legacyPath;
  }

  final localAppData =
      localAppDataOverride ?? Platform.environment['LOCALAPPDATA'];
  if (localAppData == null || localAppData.isEmpty) {
    return legacyPath;
  }

  final appDirPath = '$localAppData${Platform.pathSeparator}LuminaAudio';
  final targetPath =
      '$appDirPath${Platform.pathSeparator}lumina_desktop_library.db';
  try {
    final appDir = Directory(appDirPath);
    if (!appDir.existsSync()) {
      appDir.createSync(recursive: true);
    }
    final targetFile = File(targetPath);
    final legacyFile = File(legacyPath);
    if (!targetFile.existsSync() && legacyFile.existsSync()) {
      legacyFile.copySync(targetPath);
      for (final suffix in const ['-wal', '-shm']) {
        final legacySidecar = File('$legacyPath$suffix');
        final targetSidecar = File('$targetPath$suffix');
        if (legacySidecar.existsSync() && !targetSidecar.existsSync()) {
          try {
            legacySidecar.copySync(targetSidecar.path);
          } catch (_) {}
        }
      }
    }
  } catch (_) {
    return legacyPath;
  }
  return targetPath;
}

String _resolveFfiL2CacheRootDir({
  String? rootDirOverride,
  String? databasePathOverride,
  String? localAppDataOverride,
  String? tempDirOverride,
  bool? isFlutterTestOverride,
}) {
  if (rootDirOverride != null && rootDirOverride.isNotEmpty) {
    return rootDirOverride;
  }
  if (databasePathOverride != null && databasePathOverride.isNotEmpty) {
    return '${File(databasePathOverride).parent.path}${Platform.pathSeparator}l2_cache';
  }
  final isTest =
      isFlutterTestOverride ?? Platform.environment.containsKey('FLUTTER_TEST');
  final tempRoot = tempDirOverride ?? Directory.systemTemp.path;
  if (isTest) {
    return '$tempRoot${Platform.pathSeparator}lumina_l2_cache';
  }
  final localAppData =
      localAppDataOverride ?? Platform.environment['LOCALAPPDATA'];
  if (localAppData == null || localAppData.isEmpty) {
    return '$tempRoot${Platform.pathSeparator}lumina_l2_cache';
  }
  return '$localAppData${Platform.pathSeparator}LuminaAudio${Platform.pathSeparator}l2_cache';
}
