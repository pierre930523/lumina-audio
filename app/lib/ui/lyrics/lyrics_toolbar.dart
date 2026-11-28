part of 'lyrics_view.dart';

extension _LyricsToolbarExt on _LyricsViewState {
  ButtonStyle _toolbarIconStyle(Color foreground) {
    return IconButton.styleFrom(
      foregroundColor: foreground,
      hoverColor: LuminaTokens.glassPillHoverBg,
      focusColor: LuminaTokens.focusRing.withValues(alpha: 0.25),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
      ),
    ).copyWith(
      mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.click),
      side: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? const BorderSide(color: LuminaTokens.focusRing, width: 1.5)
            : const BorderSide(color: Colors.transparent, width: 1.5),
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: LuminaTokens.spaceSm + 2,
        vertical: LuminaTokens.space2xs,
      ),
      decoration: BoxDecoration(
        color: LuminaTokens.glassDrawerBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        border: Border.all(
          color: LuminaTokens.glassPillBorder,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const Key('btn_lyrics_font_down'),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            style: _toolbarIconStyle(LuminaTokens.glassTextSecondary),
            tooltip: '縮小歌詞字體',
            icon: const Icon(Icons.text_decrease_rounded, size: 17),
            onPressed: () => _updateFontScale(_fontScale - 0.1),
          ),
          Text(
            '${(_fontScale * 100).round()}%',
            style: const TextStyle(
              color: LuminaTokens.glassTextPrimary,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              fontFeatures: [ui.FontFeature.tabularFigures()],
            ),
          ),
          IconButton(
            key: const Key('btn_lyrics_font_up'),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            style: _toolbarIconStyle(LuminaTokens.glassTextSecondary),
            tooltip: '放大歌詞字體',
            icon: const Icon(Icons.text_increase_rounded, size: 17),
            onPressed: () => _updateFontScale(_fontScale + 0.1),
          ),
          const SizedBox(width: LuminaTokens.spaceXs),
          const SizedBox(
            height: 16,
            child: VerticalDivider(
              color: LuminaTokens.glassPillBorder,
              width: 1,
            ),
          ),
          const SizedBox(width: LuminaTokens.spaceXs),
          IconButton(
            key: const Key('btn_lyrics_offset_minus'),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            style: _toolbarIconStyle(LuminaTokens.glassTextSecondary),
            tooltip: '歌詞提前 0.5 秒',
            icon: const Icon(Icons.fast_rewind_rounded, size: 17),
            onPressed: () => _updateDisplayOffset(
              _displayOffset - const Duration(milliseconds: 500),
            ),
          ),
          Text(
            _displayOffset == Duration.zero
                ? '0.0s'
                : '${_displayOffset.inMilliseconds > 0 ? '+' : ''}${(_displayOffset.inMilliseconds / 1000).toStringAsFixed(1)}s',
            key: const Key('lyrics_offset_label'),
            style: const TextStyle(
              color: LuminaTokens.glassTextPrimary,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              fontFeatures: [ui.FontFeature.tabularFigures()],
            ),
          ),
          IconButton(
            key: const Key('btn_lyrics_offset_plus'),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            style: _toolbarIconStyle(LuminaTokens.glassTextSecondary),
            tooltip: '歌詞延後 0.5 秒',
            icon: const Icon(Icons.fast_forward_rounded, size: 17),
            onPressed: () => _updateDisplayOffset(
              _displayOffset + const Duration(milliseconds: 500),
            ),
          ),
          const SizedBox(width: LuminaTokens.spaceXs),
          const SizedBox(
            height: 16,
            child: VerticalDivider(
              color: LuminaTokens.glassPillBorder,
              width: 1,
            ),
          ),
          const SizedBox(width: LuminaTokens.spaceXs),
          IconButton(
            key: const Key('btn_load_lyrics_file'),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            style: _toolbarIconStyle(LuminaTokens.glassTextPrimary),
            tooltip: '載入自訂 .lrc / .txt 歌詞',
            icon: const Icon(Icons.file_open_outlined, size: 17),
            onPressed: _promptManualLyrics,
          ),
          IconButton(
            key: const Key('btn_clear_lyrics_file'),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            style: _toolbarIconStyle(LuminaTokens.glassTextTertiary),
            tooltip: '清除自訂歌詞',
            icon: const Icon(Icons.delete_sweep_outlined, size: 17),
            onPressed: _clearManualLyrics,
          ),
          const SizedBox(width: LuminaTokens.spaceXs),
          const SizedBox(
            height: 16,
            child: VerticalDivider(
              color: LuminaTokens.glassPillBorder,
              width: 1,
            ),
          ),
          const SizedBox(width: LuminaTokens.spaceXs),
          IconButton(
            key: const Key('btn_lyrics_toolbar_close'),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            style: _toolbarIconStyle(LuminaTokens.glassTextSecondary),
            tooltip: '收合歌詞設定',
            icon: const Icon(Icons.close_rounded, size: 16),
            onPressed: () => _setSettingsExpanded(false),
          ),
        ],
      ),
    );
  }
}

class _LyricsToolbarToggleButton extends StatefulWidget {
  final VoidCallback onTap;

  const _LyricsToolbarToggleButton({super.key, required this.onTap});

  @override
  State<_LyricsToolbarToggleButton> createState() =>
      _LyricsToolbarToggleButtonState();
}

class _LyricsToolbarToggleButtonState
    extends State<_LyricsToolbarToggleButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '開啟歌詞字體與時間偏移設定',
      child: Semantics(
        button: true,
        label: '歌詞設定',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: const Key('btn_lyrics_toolbar_toggle'),
            onTap: widget.onTap,
            onHover: (v) {
              if (_hovered != v) setState(() => _hovered = v);
            },
            onFocusChange: (v) {
              if (_focused != v) setState(() => _focused = v);
            },
            mouseCursor: SystemMouseCursors.click,
            hoverColor: Colors.transparent,
            focusColor: Colors.transparent,
            borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
            child: AnimatedContainer(
              duration: LuminaTokens.focusDuration,
              curve: LuminaTokens.motionCurve,
              height: 38,
              padding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 7,
              ),
              decoration: BoxDecoration(
                color: _hovered
                    ? LuminaTokens.glassPillHoverBg
                    : LuminaTokens.glassDrawerBg,
                borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
                border: Border.all(
                  color: _focused
                      ? LuminaTokens.focusRing
                      : (_hovered
                            ? LuminaTokens.glassCoverRim
                            : LuminaTokens.glassPillBorder),
                  width: 1,
                ),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.tune_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
                  SizedBox(width: 7),
                  Text(
                    'Aa',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
