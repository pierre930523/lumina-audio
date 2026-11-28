part of 'streaming_service_view.dart';

extension _StreamingToolbar on _StreamingServiceViewState {
  Widget _buildCompactToolbar({
    required double availW,
    required String subtitleLine,
    required Color statusDotColor,
  }) {
    final isWideInlineFilter = availW >= 900;
    final isExpandedCompactSearch = !isWideInlineFilter && _filterExpanded;
    final isCompactSync = availW < 620;
    final horizontalPad = availW < 620 ? 10.0 : 12.0;

    return FrostedGlassContainer(
      key: const Key('streaming_compact_toolbar'),
      height: _StreamingServiceViewState._toolbarHeight,
      blurSigma: LuminaTokens.glassPillBlur,
      color: LuminaTokens.glassSidebarBg,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: LuminaTokens.glassSidebarBorder),
      padding: EdgeInsets.symmetric(horizontal: horizontalPad),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.28),
          blurRadius: 16,
          offset: const Offset(0, 6),
        ),
      ],
      child: Row(
        children: [
          if (isExpandedCompactSearch) ...[
            _buildToolbarLeft(
              subtitleLine: subtitleLine,
              statusDotColor: statusDotColor,
              maxWidth: availW < 540 ? 128.0 : 170.0,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                height: 34,
                child: _buildCompactFilterField(),
              ),
            ),
            const SizedBox(width: 6),
            _buildFilterToggleButton(expanded: true),
            const SizedBox(width: 6),
            _buildSyncPillButton(iconOnly: true),
            const SizedBox(width: 6),
            _buildSettingsIconButton(),
          ] else if (availW < 540) ...[
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _buildToolbarLeft(
                  subtitleLine: subtitleLine,
                  statusDotColor: statusDotColor,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: _buildSegmentedTabPill(availW: availW),
              ),
            ),
            const SizedBox(width: 6),
            _buildToolbarRight(
              availW: availW,
              showInlineFilter: false,
              iconOnlySync: isCompactSync,
            ),
          ] else ...[
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _buildToolbarLeft(
                  subtitleLine: subtitleLine,
                  statusDotColor: statusDotColor,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _buildSegmentedTabPill(availW: availW),
            const SizedBox(width: 8),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: _buildToolbarRight(
                  availW: availW,
                  showInlineFilter: isWideInlineFilter,
                  iconOnlySync: isCompactSync,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildToolbarLeft({
    required String subtitleLine,
    required Color statusDotColor,
    double? maxWidth,
  }) {
    final browsable =
        widget.streamingManager?.browsableProviders ?? const <StreamingProvider>[];
    final canSwitch =
        browsable.length >= 2 && widget.onSwitchStreamingProvider != null;

    Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        widget.provider.buildBadge(boxSize: 32, borderRadius: 8),
        const SizedBox(width: 9),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      widget.provider.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: LuminaTokens.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    key: const Key('streaming_status_dot'),
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: statusDotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  if (canSwitch) ...[
                    const SizedBox(width: 3),
                    const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 15,
                      color: LuminaTokens.textMuted,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 1),
              Text(
                subtitleLine,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 11,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    if (maxWidth != null) {
      content = ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: content,
      );
    }

    if (!canSwitch) {
      return content;
    }

    return PopupMenuButton<String>(
      key: const Key('streaming_provider_switcher'),
      tooltip: '切換串流服務',
      padding: EdgeInsets.zero,
      offset: const Offset(0, 44),
      color: LuminaTokens.glassMenuBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: LuminaTokens.glassPillBorder),
      ),
      onSelected: (kind) {
        if (kind != widget.provider.kind) {
          widget.onSwitchStreamingProvider?.call(kind);
        }
      },
      itemBuilder: (context) => [
        for (final p in browsable)
          PopupMenuItem<String>(
            key: Key('streaming_switch_item_${p.kind}'),
            value: p.kind,
            child: Row(
              children: [
                p.meta.buildBadge(boxSize: 20, borderRadius: 5),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    p.meta.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: p.kind == widget.provider.kind
                          ? Colors.white
                          : LuminaTokens.glassTextSecondary,
                      fontSize: 13,
                      fontWeight: p.kind == widget.provider.kind
                          ? FontWeight.w600
                          : FontWeight.w500,
                    ),
                  ),
                ),
                if (p.kind == widget.provider.kind)
                  const Icon(
                    Icons.check_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
              ],
            ),
          ),
      ],
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: content,
        ),
      ),
    );
  }

  Widget _buildSegmentedTabPill({required double availW}) {
    final showIcons = availW >= 780;
    final horizontalPad = availW >= 840
        ? 12.0
        : (availW >= 620 ? 9.0 : 7.0);
    final fontSize = availW < 560 ? 11.5 : 12.5;

    return Container(
      height: 36,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: LuminaTokens.glassSegmentTrackBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        border: Border.all(color: LuminaTokens.glassSegmentTrackBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final t in _StreamingServiceViewState._tabs)
            _buildSegmentedTabItem(
              tab: t,
              selected: _selectedTab == t.idx,
              showIcon: showIcons,
              horizontalPad: horizontalPad,
              fontSize: fontSize,
            ),
        ],
      ),
    );
  }

  Widget _buildSegmentedTabItem({
    required ({int idx, String keyName, String label, IconData icon}) tab,
    required bool selected,
    required bool showIcon,
    required double horizontalPad,
    required double fontSize,
  }) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: Key(tab.keyName),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        onTap: () => _setState(() {
          _userSelectedTab = true;
          _selectedTab = tab.idx;
          if (tab.idx != 2) {
            _activePlaylist = null;
          }
        }),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          height: 30,
          padding: EdgeInsets.symmetric(horizontal: horizontalPad),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
            color: selected
                ? LuminaTokens.glassSegmentSelectedBg
                : Colors.transparent,
            border: selected
                ? Border.all(color: LuminaTokens.glassSegmentSelectedBorder)
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (showIcon) ...[
                Icon(
                  tab.icon,
                  size: 14,
                  color: selected
                      ? Colors.white
                      : LuminaTokens.glassTextSecondary,
                ),
                const SizedBox(width: 5),
              ],
              Text(
                tab.label,
                style: TextStyle(
                  color: selected
                      ? Colors.white
                      : LuminaTokens.glassTextSecondary,
                  fontSize: fontSize,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
