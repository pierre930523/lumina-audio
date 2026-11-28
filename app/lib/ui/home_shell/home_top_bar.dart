part of '../home_screen.dart';

extension _HomeTopBarBuilder on _HomeScreenState {
  Widget _buildTopBar({
    required bool isDesktop,
    required double availWidth,
    required double sidebarWidth,
  }) {
    final glass = LuminaGlassTheme.of(context);
    final preset = _scaleController.homeLayoutPreset;
    final canGoBack = _navController.canGoBack;
    final canGoForward = _navController.canGoForward;
    final inSettings = _isSettingsTab(_activeTab);
    final showSidebarArea = isDesktop && preset.usesSidebar;
    final contentAvailWidth =
        availWidth - (showSidebarArea && !_sidebarCollapsed ? sidebarWidth : 0.0);
    final metrics = _computeTopBarMetrics(
      isDesktop: isDesktop,
      availWidth: availWidth,
      contentAvailWidth: contentAvailWidth,
      preset: preset,
    );
    final isDspSelected = _activeTab == HomeTab.dsp;

    final leftControls = <Widget>[
      if (metrics.showSidebarSpacer)
        IgnorePointer(
          child: ClipRect(
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              alignment: Alignment.centerRight,
              widthFactor: _sidebarCollapsed ? 0.0 : 1.0,
              child: SizedBox(
                width: sidebarWidth,
                height: WindowDragBar.kDefaultHeight,
              ),
            ),
          ),
        ),
      SizedBox(width: isDesktop ? 8 : 4),
      if (metrics.showSidebarSpacer)
        IconButton(
          tooltip: _sidebarCollapsed ? '展開側欄' : '收合側欄',
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
          hoverColor: glass.pillHoverBg,
          icon: Icon(
            _sidebarCollapsed ? Icons.menu_rounded : Icons.menu_open_rounded,
            size: 19,
            color: glass.textSecondary,
          ),
          onPressed: () {
            _refreshState(() => _sidebarCollapsed = !_sidebarCollapsed);
          },
        ),
      IconButton(
        key: const Key('btn_nav_back'),
        tooltip: '返回上一頁',
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        padding: EdgeInsets.zero,
        hoverColor: glass.pillHoverBg,
        disabledColor: glass.textDisabled,
        icon: Icon(
          Icons.chevron_left_rounded,
          size: 22,
          color: canGoBack ? glass.textPrimary : glass.textDisabled,
        ),
        onPressed: canGoBack ? _goBack : null,
      ),
      IconButton(
        key: const Key('btn_nav_forward'),
        tooltip: '下一頁',
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        padding: EdgeInsets.zero,
        hoverColor: glass.pillHoverBg,
        disabledColor: glass.textDisabled,
        icon: Icon(
          Icons.chevron_right_rounded,
          size: 22,
          color: canGoForward ? glass.textPrimary : glass.textDisabled,
        ),
        onPressed: canGoForward ? _goForward : null,
      ),
    ];

    final rightControls = <Widget>[
      if (metrics.showScaleMenu) ...[
        _buildQuickScaleMenu(glass),
        const SizedBox(width: 6),
      ],
      if (metrics.showDspQuickBtn) ...[
        FrostedGlassContainer(
          blurSigma: LuminaTokens.glassPillBlur,
          color: isDspSelected ? glass.glassBgActive : glass.pillBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
          border: Border.all(
            color: isDspSelected ? glass.glassBorderStrong : glass.pillBorder,
          ),
          child: IconButton(
            key: const Key('btn_topbar_dsp'),
            tooltip: '64-bit DSP 音訊引擎',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            hoverColor: glass.pillHoverBg,
            icon: Icon(
              Icons.graphic_eq_rounded,
              size: 18,
              color: isDspSelected ? glass.textPrimary : glass.textSecondary,
            ),
            onPressed: () => _selectTab(HomeTab.dsp),
          ),
        ),
        const SizedBox(width: 6),
      ],
      if (metrics.showBookmarksBtn) ...[
        BookmarksMenuButton(
          controller: _bookmarksController,
          activeBookmarkId: _activeBookmarkId,
          defaultSaveNameBuilder: _defaultBookmarkName,
          onSaveNew: _saveCurrentAsBookmark,
          onUpdateActive: _updateActiveBookmark,
          onSelectBookmark: _openBookmark,
        ),
        const SizedBox(width: 6),
      ],
      HomeLayoutSwitcherButton(
        key: _layoutSwitcherKey,
        scaleController: _scaleController,
        onOpenAppearanceSettings: () => _selectTab(HomeTab.appearance),
      ),
      const SizedBox(width: 6),
      _buildCollapsibleTopSearch(
        contentAvailWidth,
        isDesktop: isDesktop,
        metrics: metrics,
        glass: glass,
      ),
      const SizedBox(width: 6),
      FrostedGlassContainer(
        blurSigma: LuminaTokens.glassPillBlur,
        color: inSettings ? glass.glassBgActive : glass.pillBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        border: Border.all(
          color: inSettings ? glass.glassBorderStrong : glass.pillBorder,
        ),
        child: IconButton(
          key: const Key('btn_open_settings_hub'),
          tooltip: '細項設定（通用 / 外觀 / 音樂庫 / DSP / 音區 / 串流與遠端）',
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
          hoverColor: glass.pillHoverBg,
          icon: Icon(
            inSettings ? Icons.settings_rounded : Icons.settings_outlined,
            size: 18,
            color: inSettings ? glass.textPrimary : glass.textSecondary,
          ),
          onPressed: () => _selectTab(_lastSettingsTab),
        ),
      ),
      if (metrics.showProfile) ...[
        SizedBox(width: metrics.isCompactTopBar ? 4 : 6),
        ProfileSwitcherBar(
          audioService: _effectiveAudioService,
          compact: metrics.isCompactProfile,
        ),
      ],
      if (isDesktop) ...[
        const SizedBox(width: 8),
        DesktopWindowCaptionButtons(
          height: 48.0,
          color: glass.textSecondary,
          controller: _windowController,
          audioService: _effectiveAudioService,
        ),
      ],
    ];

    final leftEstW = (isDesktop ? 8.0 : 4.0) +
        80.0 +
        (metrics.showBrandWordmark ? 114.0 : 0.0);
    final rightEstW = (metrics.showScaleMenu ? 94.0 : 0.0) +
        (metrics.showDspQuickBtn ? 42.0 : 0.0) +
        (metrics.showBookmarksBtn ? 42.0 : 0.0) +
        42.0 +
        40.0 +
        48.0 +
        (metrics.showProfile
            ? ((metrics.isCompactTopBar ? 4.0 : 6.0) +
                (metrics.isCompactProfile ? 44.0 : 150.0))
            : 0.0) +
        (isDesktop ? 188.0 : 0.0);
    final capsuleHalfW = _estimateCapsuleHalfWidth(metrics);
    final canTrueCenterCapsule = metrics.showCapsuleInTopBar &&
        !_topSearchExpanded &&
        (availWidth / 2 - capsuleHalfW) > leftEstW + 16 &&
        (availWidth / 2 + capsuleHalfW) < availWidth - rightEstW - 16;

    final Widget rowContent;
    if (canTrueCenterCapsule) {
      rowContent = Row(
        children: [
          ...leftControls,
          if (metrics.showBrandWordmark) _buildSidebarlessWordmark(glass),
          const Spacer(),
          Row(
            key: const ValueKey('topbar_right_controls'),
            mainAxisSize: MainAxisSize.min,
            children: rightControls,
          ),
        ],
      );
    } else if (metrics.showCapsuleInTopBar) {
      rowContent = Row(
        children: [
          ...leftControls,
          if (metrics.showBrandWordmark) _buildSidebarlessWordmark(glass),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: _buildFloatingNavCapsule(
                    showIcons: metrics.showCapsuleIcons,
                    showDrawerLabel: metrics.showDrawerLabel,
                  ),
                ),
              ),
            ),
          ),
          Row(
            key: const ValueKey('topbar_right_controls'),
            mainAxisSize: MainAxisSize.min,
            children: rightControls,
          ),
        ],
      );
    } else {
      rowContent = Row(
        children: [
          ...leftControls,
          _buildTopBarTitle(
            glass: glass,
            isDesktop: isDesktop,
            isCompactTopBar: metrics.isCompactTopBar,
            isSidebarless: metrics.isSidebarless,
            showBrandWordmark: metrics.showBrandWordmark,
          ),
          Row(
            key: const ValueKey('topbar_right_controls'),
            mainAxisSize: MainAxisSize.min,
            children: rightControls,
          ),
        ],
      );
    }

    return WindowDragBar(
      controller: _windowController,
      height: WindowDragBar.kDefaultHeight,
      backgroundColor: Colors.transparent,
      border: null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: ValueListenableBuilder<bool>(
                valueListenable: _headerScrimVisible,
                builder: (context, visible, _) {
                  final showVeil =
                      visible &&
                      ((_activeTab == HomeTab.home &&
                              preset == HomeLayoutPreset.auraQuickResume) ||
                          inSettings);
                  return AnimatedOpacity(
                    opacity: showVeil ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0.0, 0.58, 1.0],
                          colors: [
                            glass.canvasBg.withValues(
                              alpha: glass.isDark ? 0.72 : 0.80,
                            ),
                            glass.canvasBg.withValues(
                              alpha: glass.isDark ? 0.34 : 0.40,
                            ),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          rowContent,
          if (canTrueCenterCapsule)
            Center(
              child: _buildFloatingNavCapsule(
                showIcons: metrics.showCapsuleIcons,
                showDrawerLabel: metrics.showDrawerLabel,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSidebarlessWordmark(LuminaGlassTheme glass) {
    return IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.only(left: 4, right: 6),
        child: Text(
          'Lumina Audio',
          key: const Key('topbar_brand_wordmark'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: glass.textPrimary,
            fontSize: 14.5,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.25,
          ),
        ),
      ),
    );
  }

  Widget _buildTopBarTitle({
    required LuminaGlassTheme glass,
    required bool isDesktop,
    required bool isCompactTopBar,
    required bool isSidebarless,
    required bool showBrandWordmark,
  }) {
    final showDefaultTitle = isSidebarless ? showBrandWordmark : (!isDesktop || _sidebarCollapsed);
    final isDetailTab =
        _activeTab == HomeTab.albumDetail ||
        _activeTab == HomeTab.artistDetail ||
        _activeTab == HomeTab.podcastDetail;
    final stickyTitle = isDetailTab ? _resolveStickyTitle() : '';

    return Expanded(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: isCompactTopBar ? 4 : 8),
        child: AnimatedBuilder(
          animation: _stickyTitleFadeAnimation,
          builder: (context, _) {
            final t = _stickyTitleFadeAnimation.value;
            return Stack(
              alignment: Alignment.centerLeft,
              children: [
                if (showDefaultTitle)
                  Opacity(
                    opacity: (1.0 - t).clamp(0.0, 1.0),
                    child: IgnorePointer(
                      child: Text(
                        'Lumina Audio',
                        key: isSidebarless ? const Key('topbar_brand_wordmark') : null,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: glass.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                if (isDetailTab && stickyTitle.isNotEmpty)
                  FadeTransition(
                    opacity: _stickyTitleFadeAnimation,
                    child: IgnorePointer(
                      ignoring: t < 0.05,
                      child: Text(
                        stickyTitle,
                        key: const Key('top_bar_sticky_title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: glass.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildCompactNavStrip() {
    final glass = LuminaGlassTheme.of(context);
    final selectedText = glass.isDark ? Colors.white : glass.textPrimary;
    final foregroundTabs = [
      ..._browseNavItems,
      ..._libraryNavItems,
      ..._mediaNavItems,
    ];
    return SizedBox(
      height: 40,
      child: ListView(
        controller: _compactNavScrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        children: [
          for (final item in foregroundTabs)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                key: Key(item.keyName),
                selected: _activeTab == item.tab,
                onSelected: (_) => _selectTab(item.tab),
                backgroundColor: glass.pillBg,
                selectedColor: glass.glassBgActive,
                checkmarkColor: selectedText,
                side: BorderSide(
                  color: _activeTab == item.tab
                      ? glass.glassBorderStrong
                      : glass.pillBorder,
                ),
                label: Text(
                  item.label,
                  style: TextStyle(
                    fontSize: 12,
                    color: _activeTab == item.tab ? selectedText : glass.textSecondary,
                    fontWeight: _activeTab == item.tab ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
          for (final p in _loggedInStreamingProviders)
            if (StreamingProviderMeta.byKind(p.kind) case final meta?)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  key: Key('nav_streaming_${meta.kind}'),
                  selected:
                      _activeTab == HomeTab.streamingProvider &&
                      _selectedStreamingKind == meta.kind,
                  onSelected: (_) => _openStreamingProvider(meta.kind),
                  backgroundColor: glass.pillBg,
                  selectedColor: glass.glassBgActive,
                  checkmarkColor: selectedText,
                  side: BorderSide(
                    color: (_activeTab == HomeTab.streamingProvider &&
                            _selectedStreamingKind == meta.kind)
                        ? glass.glassBorderStrong
                        : glass.pillBorder,
                  ),
                  label: Text(
                    meta.name,
                    style: TextStyle(
                      fontSize: 12,
                      color: (_activeTab == HomeTab.streamingProvider &&
                              _selectedStreamingKind == meta.kind)
                          ? selectedText
                          : glass.textSecondary,
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
