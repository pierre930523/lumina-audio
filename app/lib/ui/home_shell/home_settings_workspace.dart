part of '../home_screen.dart';

const List<_NavItemSpec> _settingsSubTabs = [
  _NavItemSpec(tab: HomeTab.general, keyName: 'nav_tab_general', label: '通用', icon: Icons.tune_outlined, activeIcon: Icons.tune_rounded),
  _NavItemSpec(tab: HomeTab.appearance, keyName: 'nav_tab_appearance', label: '外觀與縮放', icon: Icons.aspect_ratio_outlined, activeIcon: Icons.aspect_ratio_rounded),
  _NavItemSpec(tab: HomeTab.librarySettings, keyName: 'nav_tab_library_settings', label: '音樂庫', icon: Icons.library_music_outlined, activeIcon: Icons.library_music_rounded),
  _NavItemSpec(tab: HomeTab.dsp, keyName: 'nav_tab_dsp', label: 'DSP 音訊引擎', icon: Icons.graphic_eq_rounded, activeIcon: Icons.graphic_eq_rounded),
  _NavItemSpec(tab: HomeTab.zones, keyName: 'nav_tab_zones', label: '輸出與音區', icon: Icons.speaker_group_outlined, activeIcon: Icons.speaker_group_rounded),
  _NavItemSpec(tab: HomeTab.settings, keyName: 'nav_tab_settings', label: '網路與串流來源', icon: Icons.dns_outlined, activeIcon: Icons.dns_rounded),
  _NavItemSpec(tab: HomeTab.about, keyName: 'nav_tab_about', label: '關於', icon: Icons.info_outline_rounded, activeIcon: Icons.info_rounded),
];

extension _HomeSettingsWorkspace on _HomeScreenState {
  Widget _buildSettingsWorkspace({
    required bool isDesktop,
    required double availWidth,
    double topBarHeight = 0.0,
  }) {
    final glass = LuminaGlassTheme.of(context);
    final isDark = glass.isDark;
    final usesFloatingPill =
        _scaleController.homeLayoutPreset.usesFloatingPlayerPill;
    final railBg = isDark ? LuminaTokens.glassSettingsRailBg : glass.sidebarBg;
    final railBlur =
        isDark ? LuminaTokens.glassSettingsRailBlur : glass.glassCardBlur;
    final railBorder =
        isDark ? LuminaTokens.glassSettingsRailBorder : glass.sidebarBorder;
    final headerColor = isDark ? Colors.white : glass.textPrimary;

    final activeSpec = _settingsSubTabs.firstWhere(
      (s) => s.tab == _activeTab,
      orElse: () => _settingsSubTabs.first,
    );

    final rawDetailBody = switch (_activeTab) {
      HomeTab.general => GeneralSettingsPanel(
        audioService: _effectiveAudioService,
        scaleController: _scaleController,
        recommendationSettings: _recommendationSettings,
        librarySettings: _librarySettingsController,
      ),
      HomeTab.appearance => AppearanceAndScalePanel(
        scaleController: _scaleController,
      ),
      HomeTab.librarySettings => LibrarySettingsPanel(
        audioService: _effectiveAudioService,
        settingsController: _librarySettingsController,
        albumLayoutController: _albumLayoutController,
        onLibraryChanged: () {
          _libraryCache.setIncludeHiddenSync(
            _albumLayoutController.showHiddenAlbums,
          );
          _libraryCache.refresh(_effectiveAudioService);
          _refreshState();
        },
      ),
      HomeTab.dsp => DspControlPanel(audioService: _effectiveAudioService),
      HomeTab.zones => OutputZonePanel(audioService: _effectiveAudioService),
      HomeTab.settings => ProvidersAndRemotePanel(
        audioService: _effectiveAudioService,
        streamingManager: _streamingManager,
        onProvidersChanged: _refreshProviders,
      ),
      HomeTab.about => AboutSettingsPanel(audioService: _effectiveAudioService),
      _ => const SizedBox.shrink(),
    };

    final fallbackMiniHeight = availWidth >= 740
        ? 84.0
        : (availWidth >= 480 ? 99.0 : 114.0);

    return ValueListenableBuilder<double?>(
      valueListenable: _measuredMiniPlayerHeight,
      builder: (context, measuredHeight, _) {
        final floatingBottomPad = usesFloatingPill
            ? (measuredHeight ?? fallbackMiniHeight)
            : 0.0;

        return SettingsWorkspaceScope(
          managedByWorkspace: true,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final maxW = constraints.maxWidth;
              final railWidth = LuminaResponsive.settingsRailWidth(maxW);
              final outerPadH =
                  LuminaResponsive.settingsContentHorizontalPadding(maxW);
              final outerTopPad = maxW >= 900 ? 32.0 : 18.0;
              final outerBottomPad = math.max(120.0, floatingBottomPad + 48.0);
              final useSideRail = isDesktop && maxW >= 680;
              final columnGap = maxW >= 960 ? 32.0 : 20.0;
              final containerW = math.min(
                1060.0,
                math.max(0.0, maxW - outerPadH * 2),
              );
              final centeredLeft =
                  outerPadH + math.max(0.0, (maxW - outerPadH * 2 - containerW) / 2);

              final railCard = FrostedGlassContainer(
                key: const Key('settings_secondary_rail'),
                width: railWidth,
                blurSigma: railBlur,
                color: railBg,
                enableBackdropBlur: true,
                borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
                border: Border.all(color: railBorder, width: 1),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 16, 16, 10),
                      child: Text(
                        '設定',
                        style: TextStyle(
                          color: headerColor,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    for (final spec in _settingsSubTabs)
                      _buildSettingsRailItem(glass, spec),
                    const SizedBox(height: 8),
                    Divider(color: glass.glassBorder, height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 11,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.translate_rounded,
                            size: 15,
                            color: glass.textTertiary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '繁體中文',
                            style: TextStyle(
                              color: glass.textTertiary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );

              final detailSection = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    activeSpec.label,
                    style: TextStyle(
                      color: headerColor,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 18),
                  rawDetailBody,
                ],
              );

              final Widget centeredBody;
              if (useSideRail) {
                centeredBody = Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: railWidth),
                    SizedBox(width: columnGap),
                    Expanded(child: detailSection),
                  ],
                );
              } else {
                centeredBody = Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: 44,
                      child: ListView(
                        controller: _settingsTabBarScrollController,
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final spec in _settingsSubTabs)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                key: Key(spec.keyName),
                                selected: _activeTab == spec.tab,
                                onSelected: (_) => _selectTab(spec.tab),
                                backgroundColor: glass.pillBg,
                                selectedColor: glass.glassBgActive,
                                checkmarkColor: glass.textPrimary,
                                side: BorderSide(
                                  color: _activeTab == spec.tab
                                      ? glass.glassBorderStrong
                                      : glass.pillBorder,
                                ),
                                label: Text(
                                  spec.label,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: _activeTab == spec.tab
                                        ? (isDark
                                              ? Colors.white
                                              : glass.textPrimary)
                                        : glass.textSecondary,
                                    fontWeight: _activeTab == spec.tab
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Divider(color: glass.glassBorder, height: 1),
                    const SizedBox(height: 16),
                    detailSection,
                  ],
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (topBarHeight > 0) SizedBox(height: topBarHeight),
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        SmoothScrollWrapper(
                          controller: _settingsScrollController,
                          child: Scrollbar(
                            key: const Key('settings_outer_scrollbar'),
                            controller: _settingsScrollController,
                            child: _BottomEdgeFadeMask(
                              key: const Key('main_content_bottom_fade_mask'),
                              fadeHeight: 28.0,
                              child: SingleChildScrollView(
                                key: const Key('settings_outer_scroll'),
                                controller: _settingsScrollController,
                                padding: EdgeInsets.fromLTRB(
                                  outerPadH,
                                  outerTopPad,
                                  outerPadH,
                                  outerBottomPad,
                                ),
                                child: Center(
                                  child: ConstrainedBox(
                                    key: const Key('settings_centered_container'),
                                    constraints: const BoxConstraints(
                                      maxWidth: 1060.0,
                                    ),
                                    child: centeredBody,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (useSideRail)
                          AnimatedBuilder(
                            animation: _settingsScrollController,
                            child: railCard,
                            builder: (context, child) {
                              final offset =
                                  _settingsScrollController.positions.length == 1
                                      ? _settingsScrollController.offset
                                      : 0.0;
                              final stickyTopMin = math.min(24.0, outerTopPad);
                              final topY = (outerTopPad - offset)
                                  .clamp(stickyTopMin, outerTopPad)
                                  .toDouble();
                              return Positioned(
                                left: centeredLeft,
                                top: topY,
                                width: railWidth,
                                child: child!,
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildSettingsRailItem(LuminaGlassTheme glass, _NavItemSpec spec) {
    final isSelected = _activeTab == spec.tab;
    final activeColor =
        glass.isDark ? LuminaTokens.glassNavActiveBg : glass.glassBgActive;
    final selectedTextColor =
        glass.isDark ? Colors.white : glass.textPrimary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1.5),
      child: Material(
        color: isSelected ? activeColor : Colors.transparent,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        child: InkWell(
          key: Key(spec.keyName),
          borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
          hoverColor: glass.glassBgHover,
          onTap: () => _selectTab(spec.tab),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Text(
              spec.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: isSelected ? selectedTextColor : glass.textSecondary,
                fontSize: 13.5,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
