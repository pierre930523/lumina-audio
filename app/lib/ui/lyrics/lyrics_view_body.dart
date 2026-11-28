part of 'lyrics_view.dart';

extension _LyricsViewBodyExt on _LyricsViewState {
  Widget _buildLyricsView(BuildContext context) {
    if (widget.lyrics.isEmpty) {
      return _LyricsEmptyState(onLoadLyrics: _promptManualLyrics);
    }

    final isSynced = _isSynced;
    final effectivePos = widget.currentPosition + _displayOffset;
    final activeIndex = isSynced
        ? (_lastActiveIndex >= 0 && _lastActiveIndex < widget.lyrics.length
            ? _lastActiveIndex
            : LyricsView.activeIndexForPosition(widget.lyrics, effectivePos))
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
        final lyricsScroll = SmoothScrollWrapper(
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
            itemBuilder: (context, index) => _buildLyricLineItem(
              index: index,
              activeIndex: activeIndex,
              isSynced: isSynced,
              effectivePos: effectivePos,
              align: align,
            ),
          ),
        );
        final lyricsViewport = NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (notification is UserScrollNotification) {
              if (notification.direction != ScrollDirection.idle) {
                _userIsScrolling = true;
                _userScrollTimer?.cancel();
                _userScrollTimer = Timer(const Duration(seconds: 4), () {
                  if (mounted) {
                    _mutateState(() => _userIsScrolling = false);
                    _autoScrollTo(_lastActiveIndex);
                  }
                });
              }
            }
            return false;
          },
          child: lyricsScroll,
        );
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
                        child: widget.isTransitionSettled
                            ? ShaderMask(
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
                                child: lyricsViewport,
                              )
                            : lyricsViewport,
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

  Widget _buildLyricLineItem({
    required int index,
    required int activeIndex,
    required bool isSynced,
    required Duration effectivePos,
    required TextAlign align,
  }) {
    final line = widget.lyrics[index];
    final distance = (index - activeIndex).abs();
    final sigma = isSynced ? LyricsView.blurSigmaForDistance(distance) : 0.0;
    final opacity = isSynced ? LyricsView.opacityForDistance(distance) : 0.85;
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
          fontWeight: isActive ? FontWeight.w800 : FontWeight.w600,
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
          if (!widget.isTransitionSettled || val <= 0.05) {
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

    final seekable = widget.onSeek != null && line.isSynced;
    final lineKey = _lineKeys.putIfAbsent(index, () => GlobalKey());
    return Padding(
      key: lineKey,
      padding: EdgeInsets.symmetric(vertical: 8 * _fontScale),
      child: AnimatedOpacity(
        opacity: opacity,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        child: InkWell(
          key: Key('lyric_line_$index'),
          borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
          mouseCursor:
              seekable ? SystemMouseCursors.click : SystemMouseCursors.basic,
          hoverColor: LuminaTokens.glassRowHoverBg,
          focusColor: LuminaTokens.focusRing.withValues(alpha: 0.2),
          onTap: seekable ? () => widget.onSeek!(line.start) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            child: widget.centered ? Center(child: content) : content,
          ),
        ),
      ),
    );
  }
}
