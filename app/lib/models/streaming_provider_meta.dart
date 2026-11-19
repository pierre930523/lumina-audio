import 'package:material_ui/material_ui.dart';

/// Shared visual and catalog metadata for supported streaming services.
class StreamingProviderMeta {
  final String kind;
  final String name;
  final String subtitle;
  final Color badgeColor;
  final List<String> providerMatchTokens;

  const StreamingProviderMeta({
    required this.kind,
    required this.name,
    required this.subtitle,
    required this.badgeColor,
    required this.providerMatchTokens,
  });

  static const List<StreamingProviderMeta> streamingServices = [
    StreamingProviderMeta(
      kind: 'apple_music',
      name: 'Apple Music',
      subtitle: 'Apple Music ALAC 高保真無損串流',
      badgeColor: Color(0xFFFA243C),
      providerMatchTokens: ['apple'],
    ),
    StreamingProviderMeta(
      kind: 'youtube_music',
      name: 'YouTube Music',
      subtitle: 'YouTube Music 高解析串流媒體庫',
      badgeColor: Color(0xFFFF0033),
      providerMatchTokens: ['youtube', 'yt music'],
    ),
    StreamingProviderMeta(
      kind: 'qobuz',
      name: 'Qobuz',
      subtitle: 'Qobuz Studio Hi-Res FLAC 無損串流',
      badgeColor: Color(0xFF2563EB),
      providerMatchTokens: ['qobuz'],
    ),
    StreamingProviderMeta(
      kind: 'tidal',
      name: 'Tidal',
      subtitle: 'Tidal Max / HiRes FLAC 無損串流',
      badgeColor: Color(0xFF0EA5E9),
      providerMatchTokens: ['tidal'],
    ),
    StreamingProviderMeta(
      kind: 'deezer',
      name: 'Deezer',
      subtitle: 'Deezer HiFi CD 品質串流',
      badgeColor: Color(0xFF9333EA),
      providerMatchTokens: ['deezer'],
    ),
  ];

  static StreamingProviderMeta? byKind(String kind) {
    for (final item in streamingServices) {
      if (item.kind == kind) return item;
    }
    return null;
  }

  static bool isStreamingKind(String kind) => byKind(kind) != null;

  bool matchesTrackProvider(String providerName) {
    final lower = providerName.toLowerCase();
    return providerMatchTokens.any(lower.contains);
  }

  Widget buildGlyph({double size = 16}) => switch (kind) {
    'apple_music' => Icon(
      Icons.music_note_rounded,
      color: Colors.white,
      size: size,
    ),
    'youtube_music' => Icon(
      Icons.play_circle_outline_rounded,
      color: Colors.white,
      size: size,
    ),
    'qobuz' => Text(
      'Q',
      style: TextStyle(
        color: Colors.white,
        fontSize: size * 0.875,
        fontWeight: FontWeight.w900,
      ),
    ),
    'tidal' => CustomPaint(
      size: Size(size * 0.875, size * 0.625),
      painter: _TidalDiamondPainter(),
    ),
    _ => Icon(Icons.equalizer_rounded, color: Colors.white, size: size),
  };

  Widget buildBadge({
    double boxSize = 26,
    double borderRadius = 6,
    Color? overrideBackground,
    double glyphOpacity = 1.0,
  }) {
    return Container(
      width: boxSize,
      height: boxSize,
      decoration: BoxDecoration(
        color: overrideBackground ?? badgeColor,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Center(
        child: Opacity(
          opacity: glyphOpacity,
          child: buildGlyph(size: boxSize * 0.62),
        ),
      ),
    );
  }
}

class _TidalDiamondPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white;
    final r = size.width / 6;
    void diamond(double cx, double cy) {
      final path = Path()
        ..moveTo(cx, cy - r)
        ..lineTo(cx + r, cy)
        ..lineTo(cx, cy + r)
        ..lineTo(cx - r, cy)
        ..close();
      canvas.drawPath(path, paint);
    }

    diamond(size.width * 0.2, size.height * 0.28);
    diamond(size.width * 0.5, size.height * 0.28);
    diamond(size.width * 0.8, size.height * 0.28);
    diamond(size.width * 0.5, size.height * 0.72);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
