import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Directory _locateUiDirectory() {
  final candidates = <String>['lib/ui', 'app/lib/ui'];
  for (final path in candidates) {
    final dir = Directory(path);
    if (dir.existsSync()) return dir;
  }
  throw StateError('Could not locate lib/ui from cwd=${Directory.current.path}');
}

void main() {
  test('UI layer (app/lib/ui/**) has zero direct FFI, HTTP, WS, or concrete backend coupling', () {
    final uiDir = _locateUiDirectory();
    final dartFiles = uiDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

    expect(dartFiles, isNotEmpty);

    final forbiddenPatterns = <RegExp>[
      RegExp(r"import\s+'dart:ffi'"),
      RegExp(r'import\s+"dart:ffi"'),
      RegExp(r'package:http/'),
      RegExp(r'\bHttpClient\b'),
      RegExp(r'\bWebSocket\b'),
      RegExp(r'\bFfiAudioService\b'),
      RegExp(r'\bServerAudioService\b'),
      RegExp(r'\bMockAudioService\b'),
      RegExp(r'\bCoordinatingAudioService\b'),
      RegExp(r'\bStreamingPlaybackCoordinator\b'),
      RegExp(r'ffi_audio_service\.dart'),
      RegExp(r'server_audio_service\.dart'),
      RegExp(r'mock_audio_service\.dart'),
      RegExp(r'streaming_playback_coordinator\.dart'),
    ];

    final violations = <String>[];
    for (final file in dartFiles) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final trimmed = line.trim();
        if (trimmed.startsWith('//') || trimmed.startsWith('///')) continue;
        for (final pattern in forbiddenPatterns) {
          if (pattern.hasMatch(line)) {
            violations.add('${file.path}:${i + 1}: $trimmed (matched ${pattern.pattern})');
          }
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason: 'Found forbidden backend/transport coupling in UI layer:\n${violations.join('\n')}',
    );
  });
}
