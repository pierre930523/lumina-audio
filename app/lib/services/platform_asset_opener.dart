import 'dart:io';
import 'dart:typed_data';

/// Opens a verified local file path with the operating system's default viewer.
Future<bool> openFileWithOsViewer(String filePath) async {
  final trimmed = filePath.trim();
  if (trimmed.isEmpty) return false;
  final file = File(trimmed);
  if (!await file.exists()) return false;
  final absPath = file.absolute.path;
  try {
    if (Platform.isWindows) {
      await Process.start(
        'cmd',
        <String>['/c', 'start', '', absPath],
        mode: ProcessStartMode.detached,
      );
      return true;
    }
    if (Platform.isMacOS) {
      await Process.start(
        'open',
        <String>[absPath],
        mode: ProcessStartMode.detached,
      );
      return true;
    }
    if (Platform.isLinux) {
      await Process.start(
        'xdg-open',
        <String>[absPath],
        mode: ProcessStartMode.detached,
      );
      return true;
    }
    return false;
  } catch (_) {
    return false;
  }
}

/// Reveals a local audio file (or its parent directory) in the OS file manager.
Future<bool> revealFileInFolder(String filePath) async {
  var trimmed = filePath.trim();
  if (trimmed.isEmpty) return false;
  if (trimmed.startsWith('file://')) {
    try {
      trimmed = Uri.parse(trimmed).toFilePath(windows: Platform.isWindows);
    } catch (_) {
      return false;
    }
  }
  final file = File(trimmed);
  final fileExists = await file.exists();
  final parentDir = file.parent;
  final parentExists = await parentDir.exists();
  if (!fileExists && !parentExists) return false;

  final absFile = file.absolute.path;
  final absParent = parentDir.absolute.path;
  try {
    if (Platform.isWindows) {
      await Process.start(
        'explorer.exe',
        fileExists ? <String>['/select,$absFile'] : <String>[absParent],
        mode: ProcessStartMode.detached,
      );
      return true;
    }
    if (Platform.isMacOS) {
      await Process.start(
        'open',
        fileExists ? <String>['-R', absFile] : <String>[absParent],
        mode: ProcessStartMode.detached,
      );
      return true;
    }
    if (Platform.isLinux) {
      await Process.start(
        'xdg-open',
        <String>[absParent],
        mode: ProcessStartMode.detached,
      );
      return true;
    }
    return false;
  } catch (_) {
    return false;
  }
}

/// Persists PDF [bytes] to a sanitized temporary `.pdf` file and opens it via
/// [openFileWithOsViewer].
Future<bool> writeTempPdfAndOpen({
  required String assetId,
  required String displayName,
  required Uint8List bytes,
}) async {
  if (bytes.isEmpty) return false;
  try {
    final safeBase = (displayName.trim().isNotEmpty ? displayName : assetId)
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    final fileName = safeBase.toLowerCase().endsWith('.pdf')
        ? safeBase
        : '$safeBase.pdf';
    final tempDir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}lumina_album_assets',
    );
    if (!await tempDir.exists()) {
      await tempDir.create(recursive: true);
    }
    final safeId = assetId.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    final outFile = File(
      '${tempDir.path}${Platform.pathSeparator}${safeId}_$fileName',
    );
    await outFile.writeAsBytes(bytes, flush: true);
    return await openFileWithOsViewer(outFile.path);
  } catch (_) {
    return false;
  }
}
