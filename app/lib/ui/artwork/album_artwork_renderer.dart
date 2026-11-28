part of 'album_artwork_view.dart';

extension _AlbumArtworkRenderer on _AlbumArtworkViewState {
  Widget _buildPlaceholder(BuildContext context, BorderRadius radius) {
    if (widget.placeholder != null) {
      return widget.circular
          ? ClipOval(child: widget.placeholder!)
          : widget.placeholder!;
    }
    final glass = LuminaGlassTheme.of(context);
    final iconSize = (widget.size * 0.24).clamp(16.0, 44.0).toDouble();
    final gradientColors = glass.emptyCoverGradient.length >= 2
        ? glass.emptyCoverGradient
        : <Color>[glass.glassBg, glass.canvasBg];
    final Icon placeholderIcon = Icon(
      widget.circular ? Icons.person_rounded : Icons.music_note_rounded,
      size: iconSize,
      color: glass.emptyCoverIconColor,
    );
    final double medallionSize = iconSize * 1.9;
    final bool showMedallion = widget.size >= 52.0;

    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: widget.circular ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: widget.circular ? null : radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: gradientColors,
        ),
      ),
      child: widget.showPlaceholderIcon
          ? Center(
              child: showMedallion
                  ? Container(
                      width: medallionSize,
                      height: medallionSize,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: glass.isDark
                            ? const Color(0x12FFFFFF)
                            : const Color(0x52FFFFFF),
                        border: Border.all(
                          color: glass.glassBorder,
                          width: 0.8,
                        ),
                      ),
                      child: placeholderIcon,
                    )
                  : placeholderIcon,
            )
          : null,
    );
  }

  Widget _buildArtworkWidget(BuildContext context) {
    final glass = LuminaGlassTheme.of(context);
    final radius =
        widget.borderRadius ?? BorderRadius.circular(widget.size > 80 ? 12 : 6);
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final double effectiveScale =
        (widget.uiScale == null && UiScaleScope.isAppliedToMediaQuery(context))
            ? 1.0
            : (widget.uiScale ?? UiScaleScope.maybeOf(context));
    final int? targetCacheWidth = widget.fullResolution
        ? null
        : (widget.size * dpr * effectiveScale).ceil().clamp(128, 2048);

    final artworkTrackKey =
        widget.track?.responsiveArtworkKey ?? widget.album?.id ?? 'none';

    Widget imageContent;
    if (_resolvedCachePath != null && _resolvedCachePath!.isNotEmpty) {
      imageContent = Image.file(
        File(_resolvedCachePath!),
        key: ValueKey('cover_file_${_resolvedCachePath!}'),
        width: widget.size,
        height: widget.size,
        fit: widget.fit,
        gaplessPlayback: true,
        filterQuality: FilterQuality.high,
        isAntiAlias: true,
        cacheWidth: targetCacheWidth,
        errorBuilder: (_, _, _) => _buildPlaceholder(context, radius),
      );
    } else if (_resolvedCoverUrl != null && _resolvedCoverUrl!.isNotEmpty) {
      final netUrl = BaseStreamingProvider.normalizeCoverUrl(_resolvedCoverUrl);
      if (netUrl != null) {
        final targetSize = AlbumArtworkView.resolveCoverTargetSize(
          size: widget.size,
          fullResolution: widget.fullResolution,
          explicitTargetSize: widget.coverTargetSize,
        );
        final tidalUpgraded = AlbumArtworkView.maybeUpgradeTidalLargeCoverUrl(
          netUrl,
          size: widget.size,
          fullResolution: widget.fullResolution,
        );
        final primaryUrl = upgradeStreamingCoverUrl(
              tidalUpgraded,
              targetSize: targetSize,
            ) ??
            tidalUpgraded;
        final fallbackUrl = fallbackStreamingCoverUrl(
          primaryUrl,
          originalUrl: netUrl,
        );
        final effectiveNetUrl =
            (_highResFallbackActive && fallbackUrl != null)
                ? fallbackUrl
                : primaryUrl;
        final signature = _resolveSignature(widget);
        final reqFullResolution = widget.fullResolution;
        final reqCoverTargetSize = widget.coverTargetSize;
        imageContent = Image.network(
          effectiveNetUrl,
          key: ValueKey('cover_net_$effectiveNetUrl'),
          width: widget.size,
          height: widget.size,
          fit: widget.fit,
          headers: BaseStreamingProvider.defaultImageHttpHeaders,
          gaplessPlayback: true,
          filterQuality: FilterQuality.high,
          isAntiAlias: true,
          cacheWidth: targetCacheWidth,
          errorBuilder: (_, error, _) {
            debugPrint('[CoverLoadError] $effectiveNetUrl -> $error');
            if (!_highResFallbackActive &&
                fallbackUrl != null &&
                fallbackUrl != effectiveNetUrl) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted ||
                    _highResFallbackActive ||
                    _resolveSignature(widget) != signature ||
                    widget.fullResolution != reqFullResolution ||
                    widget.coverTargetSize != reqCoverTargetSize) {
                  return;
                }
                _setState(() => _highResFallbackActive = true);
              });
            }
            return _buildPlaceholder(context, radius);
          },
        );
      } else {
        imageContent = _buildPlaceholder(context, radius);
      }
    } else {
      imageContent = _buildPlaceholder(context, radius);
    }

    final isHighSpeed = ScrollVelocityScope.isHighSpeedOf(context);
    final wrappedContent = AnimatedSwitcher(
      duration: isHighSpeed
          ? Duration.zero
          : const Duration(milliseconds: 380),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: child,
      ),
      child: KeyedSubtree(
        key: ValueKey(
          'art_img_${artworkTrackKey}_${_resolvedCachePath ?? _resolvedCoverUrl ?? "placeholder"}',
        ),
        child: imageContent,
      ),
    );

    final BoxBorder? resolvedBorder = widget.border ??
        (widget.frameless
            ? null
            : Border.all(
                color: glass.isDark
                    ? Colors.white.withValues(alpha: 0.12)
                    : glass.glassBorder,
                width: 1,
              ));

    final List<BoxShadow>? resolvedShadow = widget.boxShadow ??
        (widget.frameless
            ? (widget.size > 44 ? glass.coverShadow : null)
            : (widget.size > 80
                  ? (glass.isDark
                        ? const [
                            BoxShadow(
                              color: Color(0x66000000),
                              blurRadius: 28,
                              offset: Offset(0, 10),
                            ),
                          ]
                        : glass.coverShadow)
                  : null));

    return Container(
      key: ValueKey('artwork_container_$_currentKey'),
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: widget.circular ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: widget.circular ? null : radius,
        border: resolvedBorder,
        boxShadow: resolvedShadow,
      ),
      child: widget.circular
          ? ClipOval(child: wrappedContent)
          : ClipRRect(
              borderRadius: radius,
              child: wrappedContent,
            ),
    );
  }
}
