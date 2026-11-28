import 'package:material_ui/material_ui.dart';

import '../../models/playback_state.dart';

/// 4-color WCAG-safe dark ambient palette aligned to `shaders/mesh_fluid_bg.frag`.
@immutable
class AmbientPalette {
  final Color colorA;
  final Color colorB;
  final Color colorC;
  final Color colorD;

  const AmbientPalette({
    required this.colorA,
    required this.colorB,
    required this.colorC,
    required this.colorD,
  });

  static const AmbientPalette defaultFallback = AmbientPalette(
    colorA: Color(0xFF1E2922),
    colorB: Color(0xFF211E38),
    colorC: Color(0xFF172024),
    colorD: Color(0xFF0E1014),
  );

  static const List<AmbientPalette> _fallbackPalettes = [
    defaultFallback,
    AmbientPalette(
      colorA: Color(0xFF2D1635),
      colorB: Color(0xFF3A1A2E),
      colorC: Color(0xFF1D1736),
      colorD: Color(0xFF0E0B14),
    ),
    AmbientPalette(
      colorA: Color(0xFF123029),
      colorB: Color(0xFF162C38),
      colorC: Color(0xFF1E2924),
      colorD: Color(0xFF0A110F),
    ),
    AmbientPalette(
      colorA: Color(0xFF332016),
      colorB: Color(0xFF291D2E),
      colorC: Color(0xFF1F2632),
      colorD: Color(0xFF100C0B),
    ),
  ];

  /// Deterministically selects a dark WCAG-safe fallback palette for [track].
  static AmbientPalette fallbackFor(TrackInfo? track) {
    if (track == null) return defaultFallback;
    final seed = '${track.album.trim().toLowerCase()}|${track.title.trim().toLowerCase()}';
    if (seed == '|') return defaultFallback;
    // FNV-1a 32-bit hash for cross-run determinism (unlike String.hashCode).
    var hash = 0x811c9dc5;
    for (final unit in seed.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return _fallbackPalettes[hash % _fallbackPalettes.length];
  }

  /// Linearly interpolates between two [AmbientPalette] instances.
  static AmbientPalette lerp(AmbientPalette a, AmbientPalette b, double t) {
    final clamped = t.clamp(0.0, 1.0).toDouble();
    return AmbientPalette(
      colorA: Color.lerp(a.colorA, b.colorA, clamped) ?? a.colorA,
      colorB: Color.lerp(a.colorB, b.colorB, clamped) ?? a.colorB,
      colorC: Color.lerp(a.colorC, b.colorC, clamped) ?? a.colorC,
      colorD: Color.lerp(a.colorD, b.colorD, clamped) ?? a.colorD,
    );
  }

  List<Color> get colors => [colorA, colorB, colorC, colorD];

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AmbientPalette &&
        other.colorA == colorA &&
        other.colorB == colorB &&
        other.colorC == colorC &&
        other.colorD == colorD;
  }

  @override
  int get hashCode => Object.hash(colorA, colorB, colorC, colorD);

  @override
  String toString() =>
      'AmbientPalette(A: $colorA, B: $colorB, C: $colorC, D: $colorD)';
}
