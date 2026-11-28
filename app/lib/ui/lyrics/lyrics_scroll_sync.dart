part of 'lyrics_view.dart';

extension _LyricsScrollSyncExt on _LyricsViewState {
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
      _mutateState(() {
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
      _mutateState(() {
        _displayOffset = next;
        _lastActiveIndex = _isSynced
            ? LyricsView.activeIndexForPosition(
                widget.lyrics,
                widget.currentPosition + _displayOffset,
                hintIndex: _lastActiveIndex,
              )
            : 0;
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
      _mutateState(() {
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
    final result = await _showManualLyricsDialog(context);
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
    _mutateState(() {});
  }
}
