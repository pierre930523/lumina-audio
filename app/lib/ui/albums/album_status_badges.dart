import 'package:material_ui/material_ui.dart';

import '../theme/lumina_tokens.dart';

/// Compact frosted pill showing the total version count on an album card/tile.
class AlbumVersionCountBadge extends StatelessWidget {
  final int count;

  const AlbumVersionCountBadge({
    super.key,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: LuminaTokens.glassDrawerBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        border: Border.all(color: LuminaTokens.glassCoverRim),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.layers_rounded,
            size: 11,
            color: LuminaTokens.glassTextPrimary,
          ),
          const SizedBox(width: 4),
          Text(
            '$count 版本',
            style: const TextStyle(
              color: LuminaTokens.glassTextPrimary,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Frosted-glass status pill used on album cards, list tiles, and detail rows
/// (`主版本`, `副版本`, `已隱藏`, `手動鎖定`).
class AlbumStatusPill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color accentColor;
  final bool subtle;

  const AlbumStatusPill({
    super.key,
    required this.label,
    this.icon,
    required this.accentColor,
    this.subtle = false,
  });

  factory AlbumStatusPill.primary({Key? key, bool locked = false}) =>
      AlbumStatusPill(
        key: key,
        label: '主版本',
        icon: locked ? Icons.lock_rounded : Icons.star_rounded,
        accentColor: LuminaTokens.statusSuccess,
      );

  factory AlbumStatusPill.secondary({Key? key}) => AlbumStatusPill(
    key: key,
    label: '副版本',
    accentColor: LuminaTokens.accentBlue,
    subtle: true,
  );

  factory AlbumStatusPill.hidden({Key? key}) => AlbumStatusPill(
    key: key,
    label: '已隱藏',
    icon: Icons.visibility_off_rounded,
    accentColor: LuminaTokens.statusWarning,
  );

  factory AlbumStatusPill.manualLocked({Key? key}) => AlbumStatusPill(
    key: key,
    label: '手動鎖定',
    icon: Icons.push_pin_rounded,
    accentColor: LuminaTokens.accentPurpleText,
    subtle: true,
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: subtle ? 0.14 : 0.2),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: accentColor.withValues(alpha: subtle ? 0.42 : 0.6),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: accentColor),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              color: accentColor,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Frosted circular checkbox shown on album cards and list tiles in multi-select mode.
class AlbumSelectionCheckbox extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;

  const AlbumSelectionCheckbox({
    super.key,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: LuminaTokens.hoverDuration,
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected
              ? LuminaTokens.accentBlue
              : LuminaTokens.glassDrawerBg,
          border: Border.all(
            color: selected
                ? LuminaTokens.accentBlue
                : LuminaTokens.glassCoverRim,
            width: 1.5,
          ),
        ),
        child: selected
            ? const Icon(
                Icons.check_rounded,
                size: 15,
                color: LuminaTokens.onAccentDark,
              )
            : null,
      ),
    );
  }
}
