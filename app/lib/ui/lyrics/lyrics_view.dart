import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import '../../models/lyric.dart';
import '../../services/audio_service.dart';
import '../../services/now_playing_view_controller.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';
import 'word_by_word_text.dart';

class LyricsView extends StatefulWidget {
  final List<LyricLine> lyrics;
  final Duration currentPosition;
  final ValueChanged<Duration>? onSeek;
  final bool centered;
  final bool isPlaying;
  final String? trackId;
  final AudioService? audioService;
  final NowPlayingViewController? viewController;
  final void Function(String filePath)? onManualLyricsLoaded;
  final bool isTransitionSettled;

  const LyricsView({
    super.key,
    required this.lyrics,
    required this.currentPosition,
    this.onSeek,
    this.centered = true,
    this.isPlaying = true,
    this.trackId,
    this.audioService,
    this.viewController,
    this.onManualLyricsLoaded,
    this.isTransitionSettled = true,
  });

  static int activeIndexForPosition(List<LyricLine> lines, Duration pos) {
    if (lines.isEmpty) return 0;
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].containsTimestamp(pos)) {
        return i;
      }
    }
    for (int i = lines.length - 1; i >= 0; i--) {
      if (pos >= lines[i].start) {
        return i;
      }
    }
    return 0;
  }

  static double blurSigmaForDistance(int distance) {
    if (distance == 0) return 0.0;
    if (distance == 1) return 1.5;
    if (distance == 2) return 3.5;
    return 5.0;
  }

  static double opacityForDistance(int distance) {
    if (distance == 0) return 1.0;
    if (distance == 1) return 0.65;
    if (distance == 2) return 0.35;
    return 0.18;
  }

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> with WidgetsBindingObserver {
  final GlobalKey _viewportKey = GlobalKey();
  final Map<int, GlobalKey> _lineKeys = <int, GlobalKey>{};
  late final ScrollController _scrollController;
  int _lastActiveIndex = -1;
  double _fontScale = 1.0;
  Duration _displayOffset = Duration.zero;
  bool _showSettings = false;
  bool _pendingTrackScrollRestore = false;
  Timer? _autoCollapseTimer;
  bool _toolbarHovered = false;
  Timer? _userScrollTimer;
  bool _userIsScrolling = false;
  Timer? _refinementTimer;
  double? _lastConstraintsHeight;
  bool _needsSettleSnap = false;

  static bool _lyricsStructurallyEqual(List<LyricLine> a, List<LyricLine> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    if (a.isEmpty) return true;
    final aFirst = a.first;
    final bFirst = b.first;
    final aLast = a.last;
    final bLast = b.last;
    return aFirst.text == bFirst.text &&
        aFirst.words.length == bFirst.words.length &&
        aLast.text == bLast.text &&
        aLast.words.length == bLast.words.length;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final vc = widget.viewController;
    if (vc != null) {
      _fontScale = vc.lyricsFontScale;
      _displayOffset = vc.lyricsDisplayOffsetFor(widget.trackId);
      _showSettings = vc.lyricsSettingsExpanded;
      vc.addListener(_onViewControllerChanged);
    }
    _scrollController = ScrollController(
      initialScrollOffset: vc?.lyricsScrollOffsetFor(widget.trackId) ?? 0.0,
    );
    _scrollController.addListener(_onScroll);
    _lastActiveIndex = LyricsView.activeIndexForPosition(
      widget.lyrics,
      widget.currentPosition + _displayOffset,
    );
    if (_lastActiveIndex >= 0 && widget.isPlaying) {
      if (widget.isTransitionSettled) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && widget.isTransitionSettled) {
            _autoScrollTo(_lastActiveIndex, animate: false);
          }
        });
      } else {
        _needsSettleSnap = true;
      }
    }
  }

  void _onScroll() {
    if (_pendingTrackScrollRestore || !_scrollController.hasClients) return;
    widget.viewController?.saveLyricsScrollOffset(
      widget.trackId,
      _scrollController.offset,
    );
  }

  void _onViewControllerChanged() {
    final vc = widget.viewController;
    if (vc == null || !mounted) return;
    final nextFont = vc.lyricsFontScale;
    final nextOffset = vc.lyricsDisplayOffsetFor(widget.trackId);
    final nextSettings = vc.lyricsSettingsExpanded;
    if ((nextFont - _fontScale).abs() > 0.001 ||
        nextOffset != _displayOffset ||
        nextSettings != _showSettings) {
      final fontChanged = (nextFont - _fontScale).abs() > 0.001;
      if (nextSettings != _showSettings) {
        if (nextSettings) {
          _startAutoCollapseTimer();
        } else {
          _cancelAutoCollapseTimer();
        }
      }
      setState(() {
        _fontScale = nextFont;
        _displayOffset = nextOffset;
        _showSettings = nextSettings;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _lastActiveIndex >= 0) {
          _autoScrollTo(_lastActiveIndex, animate: false);
          if (fontChanged) {
            _scheduleRefinementPass(_lastActiveIndex);
          }
        }
      });
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _lastActiveIndex >= 0) {
        _autoScrollTo(_lastActiveIndex, animate: false);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancelAutoCollapseTimer();
    _userScrollTimer?.cancel();
    _refinementTimer?.cancel();
    widget.viewController?.removeListener(_onViewControllerChanged);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant LyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isTransitionSettled) {
      _refinementTimer?.cancel();
    }

    if (oldWidget.viewController != widget.viewController) {
      oldWidget.viewController?.removeListener(_onViewControllerChanged);
      widget.viewController?.addListener(_onViewControllerChanged);
      final vc = widget.viewController;
      if (vc != null) {
        _fontScale = vc.lyricsFontScale;
        _displayOffset = vc.lyricsDisplayOffsetFor(widget.trackId);
        _showSettings = vc.lyricsSettingsExpanded;
      }
    }

    final trackChanged = oldWidget.trackId != widget.trackId;
    final lyricsChanged =
        !_lyricsStructurallyEqual(oldWidget.lyrics, widget.lyrics);

    if (trackChanged || lyricsChanged) {
      _lastActiveIndex = -1;
      _lineKeys.clear();
    }

    if (trackChanged && widget.viewController != null) {
      _displayOffset = widget.viewController!.lyricsDisplayOffsetFor(
        widget.trackId,
      );
      _pendingTrackScrollRestore = true;
      final restoredTrackId = widget.trackId;
      final targetScroll = widget.viewController!.lyricsScrollOffsetFor(
        restoredTrackId,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _pendingTrackScrollRestore = false;
        if (!mounted ||
            widget.trackId != restoredTrackId ||
            !_scrollController.hasClients) {
          return;
        }
        final maxExtent = _scrollController.position.maxScrollExtent;
        final clamped = targetScroll.clamp(0.0, maxExtent).toDouble();
        if (targetScroll > 0.0 || !widget.isPlaying) {
          if ((_scrollController.offset - clamped).abs() > 0.5) {
            _scrollController.jumpTo(clamped);
          }
        } else if (widget.isTransitionSettled) {
          final active = LyricsView.activeIndexForPosition(
            widget.lyrics,
            widget.currentPosition + _displayOffset,
          );
          if (active >= 0) {
            _autoScrollTo(active, animate: false);
          }
        } else {
          _needsSettleSnap = true;
        }
      });
    }

    final effectivePos = widget.currentPosition + _displayOffset;
    final newActiveIndex = LyricsView.activeIndexForPosition(
      widget.lyrics,
      effectivePos,
    );

    if (newActiveIndex != _lastActiveIndex) {
      _lastActiveIndex = newActiveIndex;
      if (widget.isPlaying &&
          (!trackChanged || widget.viewController == null)) {
        if (widget.isTransitionSettled) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted &&
                widget.isTransitionSettled &&
                _lastActiveIndex == newActiveIndex) {
              _autoScrollTo(newActiveIndex);
            }
          });
        } else {
          _needsSettleSnap = true;
        }
      }
    }

    if (!oldWidget.isTransitionSettled && widget.isTransitionSettled) {
      if (_needsSettleSnap && _lastActiveIndex >= 0 && !_userIsScrolling) {
        _needsSettleSnap = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              widget.isTransitionSettled &&
              _lastActiveIndex >= 0 &&
              !_userIsScrolling) {
            _autoScrollTo(_lastActiveIndex, animate: false);
          }
        });
      }
    }
  }

  void _startAutoCollapseTimer() {
    _autoCollapseTimer?.cancel();
    if (_toolbarHovered) return;
    _autoCollapseTimer = Timer(const Duration(milliseconds: 4500), () {
      if (!mounted || !_showSettings || _toolbarHovered) return;
      _setSettingsExpanded(false);
    });
  }

  void _cancelAutoCollapseTimer() {
    _autoCollapseTimer?.cancel();
    _autoCollapseTimer = null;
  }

  void _resetAutoCollapseTimer() {
    _cancelAutoCollapseTimer();
    _startAutoCollapseTimer();
  }

  void _updateFontScale(double next) {
    _resetAutoCollapseTimer();
    final clamped = next.clamp(0.7, 1.6).toDouble();
    if (widget.viewController != null) {
      widget.viewController!.setLyricsFontScale(clamped);
    } else {
      final fontChanged = (clamped - _fontScale).abs() > 0.001;
      setState(() {
        _fontScale = clamped;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _lastActiveIndex >= 0) {
          _autoScrollTo(_lastActiveIndex, animate: false);
          if (fontChanged) {
            _scheduleRefinementPass(_lastActiveIndex);
          }
        }
      });
    }
  }

  void _updateDisplayOffset(Duration next) {
    _resetAutoCollapseTimer();
    if (widget.viewController != null) {
      widget.viewController!.setLyricsDisplayOffset(widget.trackId, next);
    } else {
      setState(() {
        _displayOffset = next;
      });
    }
  }

  void _setSettingsExpanded(bool expanded) {
    if (expanded) {
      _startAutoCollapseTimer();
    } else {
      _cancelAutoCollapseTimer();
    }
    if (widget.viewController != null) {
      widget.viewController!.setLyricsSettingsExpanded(expanded);
    } else {
      setState(() {
        _showSettings = expanded;
      });
    }
  }

  void _scheduleRefinementPass(
    int index, {
    Duration delay = const Duration(milliseconds: 330),
  }) {
    _refinementTimer?.cancel();
    if (!widget.isTransitionSettled) return;
    _refinementTimer = Timer(delay, () {
      if (mounted &&
          widget.isTransitionSettled &&
          _lastActiveIndex == index &&
          !_userIsScrolling) {
        _autoScrollTo(index, animate: false, isRefinement: true);
      }
    });
  }

  void _autoScrollTo(
    int index, {
    bool animate = true,
    bool isRefinement = false,
  }) {
    if (!widget.isTransitionSettled || _userIsScrolling) return;
    if (!_scrollController.hasClients || widget.lyrics.isEmpty) return;
    if (index < 0 || index >= widget.lyrics.length) return;

    final viewportBox =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    final itemBox =
        _lineKeys[index]?.currentContext?.findRenderObject() as RenderBox?;
    if (viewportBox != null &&
        itemBox != null &&
        viewportBox.hasSize &&
        itemBox.hasSize) {
      final offsetInViewport =
          itemBox.localToGlobal(Offset.zero, ancestor: viewportBox);
      final itemCenterY = offsetInViewport.dy + (itemBox.size.height * 0.5);
      final targetCenterY = viewportBox.size.height * 0.5;
      final delta = itemCenterY - targetCenterY;
      final targetOffset = (_scrollController.offset + delta).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      if ((targetOffset - _scrollController.offset).abs() > 0.01) {
        if (animate) {
          _scrollController.animateTo(
            targetOffset,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
          );
        } else {
          _scrollController.jumpTo(targetOffset);
        }
      }
      if (animate && !isRefinement) {
        _scheduleRefinementPass(index);
      }
      return;
    }

    // Fallback if unrendered: jump to approximate offset, and refine post-frame
    final estimatedLineHeight = 56.0 * _fontScale;
    final estimatedOffset = (index * estimatedLineHeight).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.jumpTo(estimatedOffset);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _autoScrollTo(
          index,
          animate: animate,
          isRefinement: isRefinement,
        );
      }
    });
  }

  Future<void> _promptManualLyrics() async {
    final textController = TextEditingController();
    final result = await showDialog<String>(
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

    if (result != null && result.isNotEmpty) {
      final tid = widget.trackId ?? widget.audioService?.currentState.track?.id;
      if (tid != null && widget.audioService != null) {
        await widget.audioService!.setUserLyrics(tid, result);
      }
      widget.onManualLyricsLoaded?.call(result);
    }
  }

  Future<void> _clearManualLyrics() async {
    final tid = widget.trackId ?? widget.audioService?.currentState.track?.id;
    if (tid != null && widget.audioService != null) {
      await widget.audioService!.clearUserLyrics(tid);
    }
    setState(() {});
  }

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

  Widget _buildEmptyState() {
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
                onPressed: _promptManualLyrics,
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

  @override
  Widget build(BuildContext context) {
    if (widget.lyrics.isEmpty) {
      return _buildEmptyState();
    }

    final isSynced = widget.lyrics.any(
      (l) =>
          l.isSynced &&
          (l.start > Duration.zero || l.end > Duration.zero || l.words.isNotEmpty),
    );

    final effectivePos = widget.currentPosition + _displayOffset;
    final activeIndex = isSynced
        ? LyricsView.activeIndexForPosition(widget.lyrics, effectivePos)
        : 0;
    final align = widget.centered ? TextAlign.center : TextAlign.start;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (_lastConstraintsHeight != null &&
            (_lastConstraintsHeight! - constraints.maxHeight).abs() > 1.0 &&
            _lastActiveIndex >= 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _autoScrollTo(_lastActiveIndex, animate: false);
          });
        }
        _lastConstraintsHeight = constraints.maxHeight;

        final verticalPad = constraints.maxHeight * 0.50;
        return Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  if (_showSettings) _setSettingsExpanded(false);
                },
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: 840,
                      maxHeight: constraints.maxHeight,
                    ),
                    child: KeyedSubtree(
                      key: const Key('lyrics_list_view'),
                      child: KeyedSubtree(
                        key: _viewportKey,
                        child: ShaderMask(
                          shaderCallback: (Rect bounds) {
                            return const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.white,
                                Colors.white,
                                Colors.transparent,
                              ],
                              stops: [0.0, 0.12, 0.84, 1.0],
                            ).createShader(bounds);
                          },
                          blendMode: BlendMode.dstIn,
                          child: NotificationListener<ScrollNotification>(
                            onNotification: (notification) {
                              if (notification is UserScrollNotification) {
                                if (notification.direction !=
                                    ScrollDirection.idle) {
                                  _userIsScrolling = true;
                                  _userScrollTimer?.cancel();
                                  _userScrollTimer =
                                      Timer(const Duration(seconds: 4), () {
                                    if (mounted) {
                                      setState(() => _userIsScrolling = false);
                                      _autoScrollTo(_lastActiveIndex);
                                    }
                                  });
                                }
                              }
                              return false;
                            },
                            child: SmoothScrollWrapper(
                              controller: _scrollController,
                              child: ListView.builder(
                                key: PageStorageKey<String>(
                                  'lyrics_scroll_${widget.trackId ?? 'default'}',
                                ),
                                controller: _scrollController,
                                padding: EdgeInsets.fromLTRB(
                                  28,
                                  verticalPad,
                                  28,
                                  verticalPad,
                                ),
                                // ignore: deprecated_member_use
                                cacheExtent: 400.0,
                                itemCount: widget.lyrics.length,
                                itemBuilder: (context, index) {
                                  final line = widget.lyrics[index];
                                  final distance = (index - activeIndex).abs();
                                  final sigma = isSynced
                                      ? LyricsView.blurSigmaForDistance(distance)
                                      : 0.0;
                                  final opacity = isSynced
                                      ? LyricsView.opacityForDistance(distance)
                                      : 0.85;
                                  final isActive = isSynced && index == activeIndex;

                                  Widget content;
                                  if (isSynced && line.words.isNotEmpty) {
                                    content = WordByWordText(
                                      line: line,
                                      currentPosition: effectivePos,
                                      isActiveLine: isActive,
                                      textAlign: align,
                                      fontScale: _fontScale,
                                    );
                                  } else {
                                    content = AnimatedDefaultTextStyle(
                                      duration: const Duration(milliseconds: 320),
                                      curve: Curves.easeOutCubic,
                                      style: TextStyle(
                                        color: isActive
                                            ? LuminaTokens.glassTextPrimary
                                            : LuminaTokens.glassTextSecondary,
                                        fontSize: (isActive ? 26.0 : 19.0) * _fontScale,
                                        fontWeight: isActive
                                            ? FontWeight.w800
                                            : FontWeight.w600,
                                        height: 1.45,
                                      ),
                                      child: Text(
                                        line.text,
                                        textAlign: align,
                                      ),
                                    );
                                  }

                                  if (widget.isTransitionSettled) {
                                    content = TweenAnimationBuilder<double>(
                                      tween: Tween<double>(begin: sigma, end: sigma),
                                      duration: const Duration(milliseconds: 320),
                                      curve: Curves.easeOutCubic,
                                      builder: (context, val, child) {
                                        if (!widget.isTransitionSettled ||
                                            val <= 0.05) {
                                          return child!;
                                        }
                                        return ImageFiltered(
                                          imageFilter: ui.ImageFilter.blur(
                                            sigmaX: val,
                                            sigmaY: val,
                                          ),
                                          child: child,
                                        );
                                      },
                                      child: content,
                                    );
                                  }

                                  final seekable =
                                      widget.onSeek != null && line.isSynced;
                                  final lineKey = _lineKeys.putIfAbsent(
                                    index,
                                    () => GlobalKey(),
                                  );
                                  return Padding(
                                    key: lineKey,
                                    padding: EdgeInsets.symmetric(
                                      vertical: 8 * _fontScale,
                                    ),
                                    child: AnimatedOpacity(
                                      opacity: opacity,
                                      duration: const Duration(milliseconds: 320),
                                      curve: Curves.easeOutCubic,
                                      child: InkWell(
                                        key: Key('lyric_line_$index'),
                                        borderRadius: BorderRadius.circular(
                                          LuminaTokens.radiusMd,
                                        ),
                                        mouseCursor: seekable
                                            ? SystemMouseCursors.click
                                            : SystemMouseCursors.basic,
                                        hoverColor: LuminaTokens.glassRowHoverBg,
                                        focusColor: LuminaTokens.focusRing
                                            .withValues(alpha: 0.2),
                                        onTap: seekable
                                            ? () => widget.onSeek!(line.start)
                                            : null,
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 6,
                                            horizontal: 12,
                                          ),
                                          child: widget.centered
                                              ? Center(child: content)
                                              : content,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Floating control toolbar toggle
            Positioned(
              bottom: LuminaTokens.spaceSm,
              left: _showSettings ? LuminaTokens.spaceSm : null,
              right: LuminaTokens.spaceSm,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.94, end: 1.0).animate(
                        animation,
                      ),
                      child: child,
                    ),
                  );
                },
                child: _showSettings
                    ? Center(
                        key: const ValueKey('lyrics_toolbar_expanded'),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: MouseRegion(
                            onEnter: (_) {
                              _toolbarHovered = true;
                              _cancelAutoCollapseTimer();
                            },
                            onExit: (_) {
                              _toolbarHovered = false;
                              _startAutoCollapseTimer();
                            },
                            child: _buildToolbar(),
                          ),
                        ),
                      )
                    : _LyricsToolbarToggleButton(
                        key: const ValueKey('lyrics_toolbar_collapsed'),
                        onTap: () => _setSettingsExpanded(true),
                      ),
              ),
            ),
          ],
        );
      },
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
