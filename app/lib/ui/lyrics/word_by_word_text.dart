import 'package:material_ui/material_ui.dart';
import '../../models/lyric.dart';
import '../theme/lumina_tokens.dart';

class WordByWordText extends StatelessWidget {
  final LyricLine line;
  final Duration currentPosition;
  final bool isActiveLine;
  final TextAlign textAlign;
  final double fontScale;

  const WordByWordText({
    super.key,
    required this.line,
    required this.currentPosition,
    required this.isActiveLine,
    this.textAlign = TextAlign.center,
    this.fontScale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    if (!isActiveLine || line.words.isEmpty) {
      return Text(
        line.text,
        textAlign: textAlign,
        style: TextStyle(
          color: isActiveLine
              ? LuminaTokens.textPrimary
              : LuminaTokens.textSecondary,
          fontSize: (isActiveLine ? 28.0 : 21.0) * fontScale,
          fontWeight: isActiveLine ? FontWeight.w800 : FontWeight.w600,
          height: 1.4,
        ),
      );
    }

    return RichText(
      textAlign: textAlign,
      text: TextSpan(
        children: line.words.map((word) {
          final sung = word.isActiveAt(currentPosition);
          return TextSpan(
            text: word.text,
            style: TextStyle(
              color: sung ? LuminaTokens.textPrimary : LuminaTokens.textMuted,
              fontSize: 28.0 * fontScale,
              fontWeight: sung ? FontWeight.w800 : FontWeight.w600,
              height: 1.4,
            ),
          );
        }).toList(),
      ),
    );
  }
}
