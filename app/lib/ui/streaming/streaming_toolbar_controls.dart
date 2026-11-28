part of 'streaming_service_view.dart';

extension _StreamingToolbarControls on _StreamingServiceViewState {
  Widget _buildToolbarRight({
    required double availW,
    required bool showInlineFilter,
    required bool iconOnlySync,
  }) {
    final filterWidth = availW >= 1080 ? 176.0 : 144.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showInlineFilter)
          SizedBox(
            width: filterWidth,
            height: 34,
            child: _buildCompactFilterField(),
          )
        else
          _buildFilterToggleButton(expanded: false),
        const SizedBox(width: 6),
        _buildSyncPillButton(iconOnly: iconOnlySync),
        const SizedBox(width: 6),
        _buildSettingsIconButton(),
      ],
    );
  }

  Widget _buildCompactFilterField() {
    final hasFocus = _filterFocusNode.hasFocus;
    final hasQuery = _filterCtrl.text.isNotEmpty;
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: LuminaTokens.glassPillBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        border: Border.all(
          color: hasFocus ? LuminaTokens.focusRing : LuminaTokens.glassPillBorder,
          width: hasFocus ? 1.3 : 1.0,
        ),
      ),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 10, right: 6),
            child: Icon(
              Icons.search_rounded,
              color: LuminaTokens.textMuted,
              size: 15,
            ),
          ),
          Expanded(
            child: TextField(
              key: const Key('streaming_search_input'),
              controller: _filterCtrl,
              focusNode: _filterFocusNode,
              onChanged: (_) => _setState(() {}),
              maxLines: 1,
              textAlignVertical: TextAlignVertical.center,
              cursorColor: LuminaTokens.glassTextPrimary,
              style: const TextStyle(
                color: LuminaTokens.textPrimary,
                fontSize: 12.5,
                height: 1.2,
              ),
              decoration: const InputDecoration(
                isDense: true,
                isCollapsed: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: '篩選曲目...',
                hintStyle: TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 12,
                ),
                contentPadding: EdgeInsets.symmetric(vertical: 4),
              ),
            ),
          ),
          if (hasQuery)
            IconButton(
              key: const Key('btn_streaming_filter_clear'),
              tooltip: '清除篩選',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 26, height: 26),
              visualDensity: VisualDensity.compact,
              icon: const Icon(
                Icons.close_rounded,
                size: 14,
                color: LuminaTokens.textSecondary,
              ),
              onPressed: () {
                _filterCtrl.clear();
                _setState(() {});
              },
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildFilterToggleButton({required bool expanded}) {
    final hasQuery = _filterCtrl.text.isNotEmpty;
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: expanded || hasQuery
            ? LuminaTokens.glassNavActiveBg
            : LuminaTokens.glassPillBg,
        border: Border.all(
          color: expanded || hasQuery
              ? LuminaTokens.glassCoverRim
              : LuminaTokens.glassPillBorder,
        ),
      ),
      child: IconButton(
        key: const Key('btn_streaming_filter_toggle'),
        tooltip: expanded ? '收合篩選' : '篩選曲目',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 34, height: 34),
        visualDensity: VisualDensity.compact,
        icon: Icon(
          expanded
              ? Icons.close_rounded
              : (hasQuery ? Icons.filter_alt_rounded : Icons.search_rounded),
          size: 16,
          color: expanded || hasQuery
              ? Colors.white
              : LuminaTokens.glassTextSecondary,
        ),
        onPressed: () {
          _setState(() {
            _filterExpanded = !expanded;
          });
          if (!expanded) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _filterFocusNode.requestFocus();
            });
          }
        },
      ),
    );
  }

  Widget _buildSyncPillButton({required bool iconOnly}) {
    final pill = Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: const Key('btn_sync_streaming_provider'),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        hoverColor: LuminaTokens.glassPillHoverBg,
        onTap: _syncing ? null : _syncCatalog,
        child: Ink(
          height: 34,
          padding: EdgeInsets.symmetric(horizontal: iconOnly ? 10 : 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
            color: _syncing
                ? LuminaTokens.glassNavActiveBg
                : LuminaTokens.glassPillBg,
            border: Border.all(
              color: _syncing
                  ? LuminaTokens.glassCoverRim
                  : LuminaTokens.glassPillBorder,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_syncing)
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              else
                const Icon(
                  Icons.sync_rounded,
                  size: 15,
                  color: Colors.white,
                ),
              if (!iconOnly) ...[
                const SizedBox(width: 5),
                const Text(
                  '同步',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    if (iconOnly) {
      return Tooltip(message: '同步曲庫', child: pill);
    }
    return pill;
  }

  Widget _buildSettingsIconButton() {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: LuminaTokens.glassPillBg,
        border: Border.all(color: LuminaTokens.glassPillBorder),
      ),
      child: IconButton(
        key: const Key('btn_streaming_open_settings'),
        tooltip: '帳號設定',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 34, height: 34),
        visualDensity: VisualDensity.compact,
        icon: const Icon(
          Icons.settings_outlined,
          size: 17,
          color: LuminaTokens.glassTextSecondary,
        ),
        onPressed: widget.onOpenProviderSettings,
      ),
    );
  }
}
