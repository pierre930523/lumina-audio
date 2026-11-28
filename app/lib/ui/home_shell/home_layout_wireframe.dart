import 'package:material_ui/material_ui.dart';

import '../../models/home_layout_preset.dart';
import '../theme/lumina_glass_theme.dart';

/// Compact miniature wireframe diagram representing a [HomeLayoutPreset]
/// inside the Quick Layout Switcher popover and Appearance settings grid.
class HomeLayoutWireframe extends StatelessWidget {
  final HomeLayoutPreset preset;
  final bool selected;
  final double height;
  final double? width;

  const HomeLayoutWireframe({
    super.key,
    required this.preset,
    this.selected = false,
    this.height = 54.0,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);
    final frameRadius = BorderRadius.circular(8);
    final borderColor = selected ? glass.accent : glass.glassBorderStrong;

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: glass.canvasBg,
        borderRadius: frameRadius,
        border: Border.all(
          color: borderColor,
          width: selected ? 1.6 : 1.0,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: CustomPaint(
          painter: _HomeLayoutWireframePainter(
            preset: preset,
            glass: glass,
            selected: selected,
          ),
          size: Size(width ?? double.infinity, height),
        ),
      ),
    );
  }
}

class _HomeLayoutWireframePainter extends CustomPainter {
  final HomeLayoutPreset preset;
  final LuminaGlassTheme glass;
  final bool selected;

  const _HomeLayoutWireframePainter({
    required this.preset,
    required this.glass,
    required this.selected,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final surfaceColor = glass.isDark
        ? Colors.white.withValues(alpha: 0.08)
        : const Color(0xFF0F172A).withValues(alpha: 0.07);
    final cardColor = glass.isDark
        ? Colors.white.withValues(alpha: 0.14)
        : const Color(0xFF0F172A).withValues(alpha: 0.12);
    final pillColor = selected
        ? glass.accent.withValues(alpha: glass.isDark ? 0.55 : 0.40)
        : (glass.isDark
              ? Colors.white.withValues(alpha: 0.22)
              : const Color(0xFF0F172A).withValues(alpha: 0.18));
    final rimColor = glass.glassBorderStrong;

    final surfacePaint = Paint()..color = surfaceColor;
    final cardPaint = Paint()..color = cardColor;
    final pillPaint = Paint()..color = pillColor;
    final rimPaint = Paint()
      ..color = rimColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    switch (preset) {
      case HomeLayoutPreset.topbarMinimal:
        _paintAi(canvas, w, h, surfacePaint, cardPaint, pillPaint, rimPaint);
      case HomeLayoutPreset.auraQuickResume:
        _paintAj(canvas, w, h, surfacePaint, cardPaint, pillPaint, rimPaint);
      case HomeLayoutPreset.classic:
        _paintClassic(
          canvas,
          w,
          h,
          surfacePaint,
          cardPaint,
          pillPaint,
          rimPaint,
        );
    }
  }

  void _paintAi(
    Canvas canvas,
    double w,
    double h,
    Paint surface,
    Paint card,
    Paint pill,
    Paint rim,
  ) {
    // Centered top capsule nav
    _paintTopCapsule(canvas, w, pill);

    // Segmented control bar
    final segW = w * 0.34;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(8, 12.5, segW, 4),
        const Radius.circular(2),
      ),
      surface,
    );

    // 2 rows x 5 full-width square covers
    final margin = 8.0;
    final gap = 3.5;
    final cardSize = ((w - margin * 2 - gap * 4) / 5).clamp(6.0, 14.0);
    for (var row = 0; row < 2; row++) {
      final y = 19.5 + row * (cardSize + 4.5);
      for (var col = 0; col < 5; col++) {
        final x = margin + col * (cardSize + gap);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, cardSize, cardSize),
            const Radius.circular(2.5),
          ),
          card,
        );
      }
    }

    _paintFloatingPill(canvas, w, h, pill, rim);
  }

  void _paintAj(
    Canvas canvas,
    double w,
    double h,
    Paint surface,
    Paint card,
    Paint pill,
    Paint rim,
  ) {
    // Soft top ambient aura glow
    final auraRect = Rect.fromLTWH(0, 0, w, h * 0.45);
    final auraPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          glass.auraDefaultPrimary.withValues(alpha: 0.42),
          glass.auraDefaultSecondary.withValues(alpha: 0.16),
          Colors.transparent,
        ],
      ).createShader(auraRect);
    canvas.drawRect(auraRect, auraPaint);

    // Centered top capsule nav
    _paintTopCapsule(canvas, w, pill);

    // 2x3 quick resume horizontal cards
    final margin = 8.0;
    final gap = 3.5;
    final qW = (w - margin * 2 - gap * 2) / 3;
    const qH = 7.5;
    for (var row = 0; row < 2; row++) {
      final y = 13.0 + row * (qH + 2.5);
      for (var col = 0; col < 3; col++) {
        final x = margin + col * (qW + gap);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, qW, qH),
            const Radius.circular(2),
          ),
          surface,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x + 1.5, y + 1.5, 4.5, 4.5),
            const Radius.circular(1),
          ),
          card,
        );
      }
    }

    // Lower 1 row of 5 album covers
    final cardGap = 3.5;
    final cardSize = ((w - margin * 2 - cardGap * 4) / 5).clamp(6.0, 12.0);
    final rowY = 34.0;
    for (var col = 0; col < 5; col++) {
      final x = margin + col * (cardSize + cardGap);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, rowY, cardSize, cardSize),
          const Radius.circular(2),
        ),
        card,
      );
    }

    _paintFloatingPill(canvas, w, h, pill, rim);
  }

  void _paintClassic(
    Canvas canvas,
    double w,
    double h,
    Paint surface,
    Paint card,
    Paint pill,
    Paint rim,
  ) {
    final barH = 8.0;
    final bodyH = h - barH;
    final sidebarW = w * 0.25;

    canvas.drawRect(Rect.fromLTWH(0, 0, sidebarW, bodyH), surface);
    canvas.drawLine(Offset(sidebarW, 0), Offset(sidebarW, bodyH), rim);

    final mainLeft = sidebarW + 5;
    final mainW = w - mainLeft - 5;

    // 5 stat pills
    final statGap = 2.0;
    final statW = (mainW - statGap * 4) / 5;
    for (var i = 0; i < 5; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(mainLeft + i * (statW + statGap), 5, statW, 4),
          const Radius.circular(2),
        ),
        surface,
      );
    }

    // 5 album covers
    final covGap = 2.5;
    final covSize = ((mainW - covGap * 4) / 5).clamp(5.0, 11.0);
    for (var i = 0; i < 5; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(mainLeft + i * (covSize + covGap), 12, covSize, covSize),
          const Radius.circular(1.5),
        ),
        card,
      );
    }

    // Lower split: 62% recommended + 38% queue
    final splitTop = 26.0;
    final leftW = mainW * 0.60;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(mainLeft, splitTop, leftW, bodyH - splitTop - 4),
        const Radius.circular(2),
      ),
      surface,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          mainLeft + leftW + 3,
          splitTop,
          mainW - leftW - 3,
          bodyH - splitTop - 4,
        ),
        const Radius.circular(2),
      ),
      surface,
    );

    // Full-width docked bottom bar
    canvas.drawRect(Rect.fromLTWH(0, bodyH, w, barH), pill);
    canvas.drawLine(Offset(0, bodyH), Offset(w, bodyH), rim);
  }

  void _paintTopCapsule(Canvas canvas, double w, Paint pill) {
    final capW = w * 0.42;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH((w - capW) / 2, 4.0, capW, 5.5),
        const Radius.circular(3),
      ),
      pill,
    );
  }

  void _paintFloatingPill(
    Canvas canvas,
    double w,
    double h,
    Paint pill,
    Paint rim,
  ) {
    final pillW = w * 0.72;
    final rect = Rect.fromLTWH((w - pillW) / 2, h - 9.5, pillW, 6.5);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(3.5));
    canvas.drawRRect(rrect, pill);
    canvas.drawRRect(rrect, rim);
  }

  @override
  bool shouldRepaint(covariant _HomeLayoutWireframePainter oldDelegate) {
    return oldDelegate.preset != preset ||
        oldDelegate.selected != selected ||
        oldDelegate.glass != glass;
  }
}
