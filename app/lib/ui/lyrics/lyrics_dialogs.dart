part of 'lyrics_view.dart';

Future<String?> _showManualLyricsDialog(BuildContext context) {
  final textController = TextEditingController();
  return showDialog<String>(
    context: context,
    barrierColor: LuminaTokens.scrimBg,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: FrostedGlassContainer(
          blurSigma: LuminaTokens.glassDialogBlur,
          color: LuminaTokens.glassDialogBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
          border: Border.all(color: LuminaTokens.glassCardBorder),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '手動載入歌詞檔案',
                style: TextStyle(
                  color: LuminaTokens.glassTextPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: LuminaTokens.spaceSm),
              const Text(
                '請輸入 .lrc 或 .txt 歌詞檔案的本機路徑：',
                style: TextStyle(
                  color: LuminaTokens.glassTextSecondary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: LuminaTokens.spaceSm),
              TextField(
                controller: textController,
                key: const Key('input_lyrics_file_path'),
                style: const TextStyle(
                  color: LuminaTokens.glassTextPrimary,
                  fontSize: 13,
                ),
                decoration: InputDecoration(
                  hintText: 'C:\\Music\\song.lrc',
                  hintStyle: const TextStyle(
                    color: LuminaTokens.glassTextTertiary,
                  ),
                  filled: true,
                  fillColor: LuminaTokens.glassCardBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                    borderSide: const BorderSide(
                      color: LuminaTokens.glassPillBorder,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                    borderSide: const BorderSide(
                      color: LuminaTokens.glassPillBorder,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                    borderSide: const BorderSide(
                      color: LuminaTokens.focusRing,
                      width: 2,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: LuminaTokens.spaceMd),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: LuminaTokens.glassTextSecondary,
                    ),
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: LuminaTokens.spaceXs),
                  FilledButton(
                    key: const Key('btn_confirm_lyrics_path'),
                    style: FilledButton.styleFrom(
                      backgroundColor: LuminaTokens.glassSwitchOnTrack,
                      foregroundColor: LuminaTokens.onAccentDark,
                    ),
                    onPressed: () =>
                        Navigator.of(ctx).pop(textController.text.trim()),
                    child: const Text('載入'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _LyricsEmptyState extends StatelessWidget {
  final VoidCallback onLoadLyrics;

  const _LyricsEmptyState({required this.onLoadLyrics});

  @override
  Widget build(BuildContext context) {
    return Center(
      key: const Key('lyrics_empty_state'),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Padding(
          padding: const EdgeInsets.all(LuminaTokens.spaceMd),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.lyrics_outlined,
                size: 54,
                color: LuminaTokens.glassTextTertiary,
              ),
              const SizedBox(height: LuminaTokens.spaceSm),
              const Text(
                '尚無歌詞資訊',
                style: TextStyle(
                  color: LuminaTokens.glassTextPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: LuminaTokens.space2xs + 2),
              const Text(
                '本曲目未內嵌歌詞，亦無同名 .lrc 歌詞檔',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: LuminaTokens.glassTextSecondary,
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(height: LuminaTokens.spaceMd),
              OutlinedButton.icon(
                key: const Key('btn_load_lyrics_file'),
                onPressed: onLoadLyrics,
                icon: const Icon(Icons.add_rounded, size: 17),
                label: const Text('匯入外部歌詞 (.lrc / .txt)'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: LuminaTokens.glassTextPrimary,
                  backgroundColor: LuminaTokens.glassPillBg,
                  side: const BorderSide(color: LuminaTokens.glassPillBorder),
                  padding: const EdgeInsets.symmetric(
                    horizontal: LuminaTokens.spaceMd,
                    vertical: LuminaTokens.spaceSm,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
                  ),
                ).copyWith(
                  mouseCursor: const WidgetStatePropertyAll(
                    SystemMouseCursors.click,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
