part of '../yt_dlp_service.dart';

int _compareVersionStringsImpl(String a, String b) {
  final normA = _normalizeVersionString(a);
  final normB = _normalizeVersionString(b);
  if (normA == normB) return 0;
  if (normA.isEmpty) return -1;
  if (normB.isEmpty) return 1;

  final splitA = _splitVersionPrerelease(normA);
  final splitB = _splitVersionPrerelease(normB);

  final partsA = splitA.core.split('.');
  final partsB = splitB.core.split('.');
  final maxLen = partsA.length > partsB.length ? partsA.length : partsB.length;

  for (var i = 0; i < maxLen; i++) {
    final rawA = i < partsA.length ? partsA[i] : '';
    final rawB = i < partsB.length ? partsB[i] : '';

    final intA = rawA.isEmpty ? 0 : int.tryParse(rawA);
    final intB = rawB.isEmpty ? 0 : int.tryParse(rawB);

    if (intA != null && intB != null) {
      if (intA != intB) return intA.compareTo(intB);
      continue;
    }

    if (rawA.isEmpty) return -1;
    if (rawB.isEmpty) return 1;

    final cmp = _compareAlphanumericSegment(rawA, rawB);
    if (cmp != 0) return cmp;
  }

  final preA = splitA.prerelease;
  final preB = splitB.prerelease;
  if (preA == preB) return 0;
  if (preA == null) return 1;
  if (preB == null) return -1;
  return _compareAlphanumericSegment(preA, preB);
}

String _normalizeVersionString(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return '';
  final plusIdx = s.indexOf('+');
  if (plusIdx >= 0) {
    s = s.substring(0, plusIdx);
  }
  if ((s.startsWith('v') || s.startsWith('V')) &&
      s.length > 1 &&
      RegExp(r'^[0-9]').hasMatch(s.substring(1))) {
    s = s.substring(1);
  }
  return s.trim();
}

({String core, String? prerelease}) _splitVersionPrerelease(String s) {
  final dashIdx = s.indexOf('-');
  if (dashIdx < 0) return (core: s, prerelease: null);
  return (
    core: s.substring(0, dashIdx),
    prerelease: s.substring(dashIdx + 1),
  );
}

int _compareAlphanumericSegment(String a, String b) {
  final tokenPattern = RegExp(r'(\d+|[^\d]+)');
  final tokensA = tokenPattern
      .allMatches(a)
      .map((m) => m.group(0)!)
      .toList();
  final tokensB = tokenPattern
      .allMatches(b)
      .map((m) => m.group(0)!)
      .toList();

  final maxLen = tokensA.length > tokensB.length
      ? tokensA.length
      : tokensB.length;
  for (var i = 0; i < maxLen; i++) {
    if (i >= tokensA.length) return -1;
    if (i >= tokensB.length) return 1;
    final ta = tokensA[i];
    final tb = tokensB[i];
    final ia = int.tryParse(ta);
    final ib = int.tryParse(tb);
    if (ia != null && ib != null) {
      if (ia != ib) return ia.compareTo(ib);
    } else {
      final cmp = ta.toLowerCase().compareTo(tb.toLowerCase());
      if (cmp != 0) return cmp;
    }
  }
  return 0;
}

String? _parseYtDlpVersionOutputImpl(String output) {
  final first = _firstNonEmptyLine(output);
  if (first == null) return null;
  final token = first.split(RegExp(r'\s+')).first.trim();
  return token.isEmpty ? null : token;
}

String? _parseDenoVersionOutputImpl(String output) {
  final first = _firstNonEmptyLine(output);
  if (first == null) return null;
  final match = RegExp(
    r'deno\s+v?([0-9][^\s()]*)',
    caseSensitive: false,
  ).firstMatch(first);
  if (match != null) return match.group(1);
  return first;
}

String? _parseFfmpegVersionOutputImpl(String output) {
  final first = _firstNonEmptyLine(output);
  if (first == null) return null;
  final match = RegExp(
    r'ffmpeg\s+version\s+([^\s]+)',
    caseSensitive: false,
  ).firstMatch(first);
  if (match != null) return match.group(1);
  return first;
}

String? _firstNonEmptyLine(String text) {
  for (final line in LineSplitter.split(text)) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

String? _parseSha256ForAssetImpl(String sumsContent, String assetName) {
  final lowerTarget = assetName.toLowerCase();
  final pattern = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$');
  for (final rawLine in LineSplitter.split(sumsContent)) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final match = pattern.firstMatch(line);
    if (match == null) continue;
    final hash = match.group(1)!.toLowerCase();
    final name = match.group(2)!.trim().toLowerCase();
    if (name == lowerTarget ||
        name.endsWith('/$lowerTarget') ||
        name.endsWith('\\$lowerTarget')) {
      return hash;
    }
  }
  return null;
}

String _joinPath(String base, String child) {
  final sep = Platform.pathSeparator;
  final cleanBase = base.replaceAll(RegExp(r'[/\\]+$'), '');
  final cleanChild = child.replaceAll(RegExp(r'^[/\\]+'), '');
  if (cleanBase.isEmpty) return cleanChild;
  return '$cleanBase$sep$cleanChild';
}
