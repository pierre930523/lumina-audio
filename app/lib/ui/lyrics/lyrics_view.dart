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

part 'lyrics_dialogs.dart';
part 'lyrics_scroll_sync.dart';
part 'lyrics_toolbar.dart';
part 'lyrics_view_body.dart';

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

  static int activeIndexForPosition(
    List<LyricLine> lines,
    Duration pos, {
    int? hintIndex,
  }) {
    if (lines.isEmpty) return 0;
    if (hintIndex != null && hintIndex >= 0 && hintIndex < lines.length) {
      if (lines[hintIndex].containsTimestamp(pos)) {
        return hintIndex;
      }
      final next = hintIndex + 1;
      if (next < lines.length && lines[next].containsTimestamp(pos)) {
        return next;
      }
    }
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
  late final GlideScrollController _scrollController;
  int _lastActiveIndex = -1;
  bool _isSynced = false;
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

  void _mutateState(VoidCallback fn) => setState(fn);

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

  static bool _computeIsSynced(List<LyricLine> lines) {
    for (final l in lines) {
      if (l.isSynced &&
          (l.start > Duration.zero ||
              l.end > Duration.zero ||
              l.words.isNotEmpty)) {
        return true;
      }
    }
    return false;
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
    _scrollController = GlideScrollController(
      initialScrollOffset: vc?.lyricsScrollOffsetFor(widget.trackId) ?? 0.0,
    );
    _scrollController.addListener(_onScroll);
    _isSynced = _computeIsSynced(widget.lyrics);
    _lastActiveIndex = _isSynced
        ? LyricsView.activeIndexForPosition(
            widget.lyrics,
            widget.currentPosition + _displayOffset,
          )
        : 0;
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
        _lastActiveIndex = _isSynced
            ? LyricsView.activeIndexForPosition(
                widget.lyrics,
                widget.currentPosition + _displayOffset,
                hintIndex: _lastActiveIndex,
              )
            : 0;
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
      _isSynced = _computeIsSynced(widget.lyrics);
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
    final newActiveIndex = _isSynced
        ? LyricsView.activeIndexForPosition(
            widget.lyrics,
            effectivePos,
            hintIndex: _lastActiveIndex,
          )
        : 0;

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

  @override
  Widget build(BuildContext context) => _buildLyricsView(context);
}
