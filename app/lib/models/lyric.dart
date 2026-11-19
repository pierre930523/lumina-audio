class LyricWord {
  final String text;
  final Duration start;
  final Duration end;

  const LyricWord({
    required this.text,
    required this.start,
    required this.end,
  });

  bool isActiveAt(Duration position) => position >= start;
}

class LyricLine {
  final Duration start;
  final Duration end;
  final String text;
  final List<LyricWord> words;
  final bool isSynced;

  const LyricLine({
    required this.start,
    required this.end,
    required this.text,
    this.words = const [],
    this.isSynced = true,
  });

  bool containsTimestamp(Duration position) =>
      isSynced && position >= start && position < end;
}
