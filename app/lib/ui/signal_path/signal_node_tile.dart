import 'package:material_ui/material_ui.dart';
import '../../models/signal_path.dart';
import '../theme/lumina_tokens.dart';
import 'quality_badge.dart';

class SignalNodeTile extends StatelessWidget {
  final SignalPathNode node;
  final bool isLast;

  const SignalNodeTile({
    super.key,
    required this.node,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final dotColor = QualityBadge.colorForQuality(node.quality);
    final labelColor = QualityBadge.textColorForQuality(node.quality);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Column(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: LuminaTokens.borderControl, width: 2),
                ),
              ),
              if (!isLast)
                Expanded(
                  child: Container(
                    width: 2,
                    color: LuminaTokens.borderControl.withValues(alpha: 0.55),
                  ),
                ),
            ],
          ),
          const SizedBox(width: LuminaTokens.spaceSm),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: LuminaTokens.spaceMd),
              child: Container(
                padding: const EdgeInsets.all(LuminaTokens.spaceSm),
                decoration: BoxDecoration(
                  color: LuminaTokens.cardElevatedBg,
                  borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
                  border: Border.all(color: LuminaTokens.borderSubtle),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            node.title,
                            style: const TextStyle(
                              color: LuminaTokens.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(width: LuminaTokens.spaceXs),
                        Text(
                          node.quality.label,
                          style: TextStyle(
                            color: labelColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: LuminaTokens.space2xs),
                    Text(
                      node.subtitle,
                      style: const TextStyle(
                        color: LuminaTokens.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      node.detail,
                      style: const TextStyle(
                        color: LuminaTokens.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
