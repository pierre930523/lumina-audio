part of 'album_collection_card.dart';

extension _AlbumCollectionCardParts on _AlbumCollectionCardState {
  Widget _buildPlayButton() {
    return Tooltip(
      message: '播放專輯',
      child: Semantics(
        button: true,
        label: '播放專輯 ${widget.album.title}',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => _setPlayHovered(true),
          onExit: (_) => _setPlayHovered(false),
          child: GestureDetector(
            key: Key('album_card_play_${widget.album.id}'),
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPlayAlbum,
            child: ScaleTransition(
              scale: _playScaleAnimation,
              child: ClipOval(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: AnimatedBuilder(
                    animation: _playHoverCurve,
                    builder: (context, _) {
                      final t = _playHoverCurve.value;
                      final bgColor = Color.lerp(
                        LuminaTokens.glassDrawerBg,
                        LuminaTokens.glassSwitchOnTrack,
                        t,
                      )!;
                      final borderColor = Color.lerp(
                        LuminaTokens.glassCoverRim,
                        LuminaTokens.glassSwitchOnTrack,
                        t,
                      )!;
                      final iconColor = t >= 0.5
                          ? LuminaTokens.onAccentDark
                          : Colors.white;
                      return Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: bgColor,
                          border: Border.all(color: borderColor, width: 1.0),
                        ),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          size: 20,
                          color: iconColor,
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
    );
  }

  Widget _buildQuickListenLaterPill() {
    final ll = widget.listenLaterController;
    final saved = ll != null &&
        ll.isSaved(
          entityType: 'album',
          entityId: widget.album.effectiveGroupId,
        );
    return Tooltip(
      message: saved ? '已在稍後收聽' : '加入稍後收聽',
      child: GestureDetector(
        key: Key('album_card_listen_later_${widget.album.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: _addToListenLater,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: LuminaTokens.glassDrawerBg,
            border: Border.all(color: LuminaTokens.glassCoverRim),
          ),
          child: Icon(
            saved ? Icons.watch_later_rounded : Icons.watch_later_outlined,
            size: 16,
            color: saved ? LuminaTokens.accentBlue : Colors.white,
          ),
        ),
      ),
    );
  }

  Widget _buildMoreButton() {
    return Tooltip(
      message: '更多選項',
      child: Semantics(
        button: true,
        label: '更多選項 ${widget.album.title}',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => _setState(() => _moreHovered = true),
          onExit: (_) => _setState(() => _moreHovered = false),
          child: Builder(
            builder: (btnCtx) => GestureDetector(
              key: Key('album_card_more_${widget.album.id}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => _openMoreMenu(btnCtx),
              child: ClipOval(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _moreHovered
                          ? LuminaTokens.glassPillHoverBg
                          : LuminaTokens.glassDrawerBg,
                      border: Border.all(
                        color: _moreHovered
                            ? LuminaTokens.glassSegmentSelectedBorder
                            : LuminaTokens.glassCoverRim,
                        width: 1.0,
                      ),
                    ),
                    child: const Icon(
                      Icons.more_horiz_rounded,
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCoverArea(double side) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _onCoverHoverEnter(),
      onExit: (_) => _onCoverHoverExit(),
      child: SizedBox(
        width: side,
        height: side,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (_overlayMounted)
              Positioned.fill(
                key: const ValueKey('album_ambient_glow'),
                child: IgnorePointer(
                  child: FadeTransition(
                    opacity: _glowOpacityAnimation,
                    child: Transform.translate(
                      offset: const Offset(0, 6),
                      child: Transform.scale(
                        scale: 1.08,
                        child: ImageFiltered(
                          imageFilter: ui.ImageFilter.blur(
                            sigmaX: 16,
                            sigmaY: 16,
                            tileMode: TileMode.decal,
                          ),
                          child: _buildGlowSource(side),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (_overlayMounted)
              Positioned.fill(
                key: const ValueKey('album_depth_shadow'),
                child: IgnorePointer(
                  child: ScaleTransition(
                    scale: _coverScaleAnimation,
                    child: FadeTransition(
                      opacity: _hoverCurve,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: _AlbumCollectionCardState._coverRadius,
                          boxShadow: [
                            BoxShadow(
                              color: Color(0x88000000),
                              blurRadius: 24,
                              offset: Offset(0, 10),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ScaleTransition(
              key: const ValueKey('album_cover_foreground'),
              scale: _coverScaleAnimation,
              child: SizedBox(
                width: side,
                height: side,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Opacity(
                      opacity: widget.album.isHidden ? 0.58 : 1.0,
                      child: AlbumArtworkView(
                        album: widget.album,
                        size: side,
                        revision: widget.coverRevision,
                        audioService: widget.audioService,
                        libraryCache: widget.libraryCache,
                        fullResolution: false,
                        borderRadius: _AlbumCollectionCardState._coverRadius,
                        fit: BoxFit.cover,
                        border: Border.all(
                          color: widget.isSelected
                              ? LuminaTokens.accentBlue
                              : Colors.white.withValues(alpha: 0.08),
                          width: widget.isSelected ? 2.0 : 1.0,
                        ),
                        boxShadow: const [],
                        onArtworkResolved: _handleArtworkResolved,
                      ),
                    ),
                    if (widget.multiSelectMode || widget.isSelected)
                      Positioned(
                        left: 8,
                        top: 8,
                        child: AlbumSelectionCheckbox(
                          key: Key(
                            'album_select_checkbox_${widget.album.selectionKey}',
                          ),
                          selected: widget.isSelected,
                          onTap: widget.onToggleSelect ?? () {},
                        ),
                      ),
                    if (!widget.showHiddenMode &&
                        widget.album.totalVersionCount > 1)
                      Positioned(
                        right: 8,
                        top: 8,
                        child: IgnorePointer(
                          child: AlbumVersionCountBadge(
                            key: Key(
                              'album_version_count_badge_${widget.album.selectionKey}',
                            ),
                            count: widget.album.totalVersionCount,
                          ),
                        ),
                      ),
                    if (widget.showHiddenMode)
                      Positioned(
                        right: 8,
                        top: 8,
                        child: IgnorePointer(
                          child: _buildHiddenModeBadge(widget.album),
                        ),
                      ),
                    if (_overlayMounted && !widget.multiSelectMode)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: ClipRRect(
                            borderRadius:
                                _AlbumCollectionCardState._coverRadius,
                            child: FadeTransition(
                              opacity: _hoverCurve,
                              child: const DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    stops: [0.35, 1.0],
                                    colors: [
                                      Colors.transparent,
                                      Color(0xB3080A0F),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (_overlayMounted && !widget.multiSelectMode) ...[
                      Positioned(
                        left: 10,
                        bottom: 10,
                        child: _buildActionEntrance(child: _buildPlayButton()),
                      ),
                      if (widget.listenLaterController != null)
                        Positioned(
                          left: 52,
                          bottom: 10,
                          child: _buildActionEntrance(
                            child: _buildQuickListenLaterPill(),
                          ),
                        ),
                      Positioned(
                        right: 10,
                        bottom: 10,
                        child: _buildActionEntrance(child: _buildMoreButton()),
                      ),
                    ],
                    if (widget.album.preference == 1 ||
                        widget.album.preference == -1)
                      Positioned(
                        left: 8,
                        top: widget.multiSelectMode || widget.isSelected
                            ? 38
                            : 8,
                        child: IgnorePointer(
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: LuminaTokens.glassDrawerBg,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: LuminaTokens.glassPillBorder,
                              ),
                            ),
                            child: Icon(
                              PreferenceToggleButton.iconFor(
                                widget.album.preference,
                              ),
                              size: 13,
                              color: PreferenceToggleButton.colorFor(
                                widget.album.preference,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHiddenModeBadge(CanonicalAlbumSummary album) {
    if (album.isHidden) {
      return AlbumStatusPill.hidden(
        key: Key('album_hidden_badge_${album.selectionKey}'),
      );
    }
    if (album.isPrimary) {
      return AlbumStatusPill.primary(
        key: Key('album_primary_badge_${album.selectionKey}'),
        locked: album.isPrimaryLocked,
      );
    }
    return AlbumStatusPill.secondary(
      key: Key('album_secondary_badge_${album.selectionKey}'),
    );
  }

  Widget _buildCard(BuildContext context) {
    final album = widget.album;
    final content = LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 180.0;
        final maxH = constraints.maxHeight;
        final textReserve = 54.0;
        final coverSide = maxH.isFinite
            ? math.max(48.0, math.min(maxW, maxH - textReserve))
            : maxW;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildCoverArea(coverSide),
            const SizedBox(height: 10),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Text(
                album.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: LuminaTokens.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                ),
              ),
            ),
            const SizedBox(height: 2),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Text(
                _albumSubtitle(album),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: LuminaTokens.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        );
      },
    );

    final wrappedContainer = widget.showCardContainer
        ? Container(
            key: Key('album_surface_${album.id}'),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: LuminaTokens.glassCardBg,
              borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
              border: Border.all(color: LuminaTokens.glassCardBorder),
            ),
            child: content,
          )
        : Container(
            key: Key('album_surface_${album.id}'),
            color: Colors.transparent,
            padding: EdgeInsets.zero,
            child: content,
          );

    return RepaintBoundary(
      child: ScrollCardEntrance(
        child: Semantics(
          button: true,
          label: '${album.title} ${album.artist}',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTapCard ?? widget.onOpenAlbumDetail,
            onSecondaryTapUp: (details) =>
                _openMoreMenu(context, globalPosition: details.globalPosition),
            child: wrappedContainer,
          ),
        ),
      ),
    );
  }
}
