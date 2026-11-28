part of 'tags_view.dart';

extension _TagsViewWidgets on _TagsViewState {
  Widget _buildView(BuildContext context) {
    final rows = _buildVisibleRows();
    final byId = _tagsById;

    return Column(
      key: const Key('tags_view'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            LuminaTokens.spaceLg,
            LuminaTokens.spaceXs,
            LuminaTokens.spaceLg,
            LuminaTokens.spaceSm,
          ),
          child: Row(
            children: [
              const Icon(
                Icons.label_rounded,
                size: 20,
                color: LuminaTokens.accentBlue,
              ),
              const SizedBox(width: 8),
              Text(
                '自訂巢狀標籤（${_tags.length}）',
                style: const TextStyle(
                  color: LuminaTokens.glassTextPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              SizedBox(
                width: 210,
                height: 34,
                child: TextField(
                  key: const Key('tags_search_input'),
                  controller: _searchController,
                  onChanged: (_) => _setState(() {}),
                  style: const TextStyle(
                    color: LuminaTokens.glassTextPrimary,
                    fontSize: 12.5,
                  ),
                  decoration: InputDecoration(
                    hintText: '篩選標籤...',
                    hintStyle: const TextStyle(color: LuminaTokens.textMuted),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      size: 16,
                      color: LuminaTokens.textMuted,
                    ),
                    filled: true,
                    fillColor: LuminaTokens.glassPillBg,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10),
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
                  ),
                ),
              ),
              const SizedBox(width: LuminaTokens.spaceSm),
              FilledButton.icon(
                key: const Key('btn_create_tag'),
                onPressed: _handleCreateTag,
                style: FilledButton.styleFrom(
                  backgroundColor: LuminaTokens.glassSwitchOnTrack,
                  foregroundColor: LuminaTokens.onAccentDark,
                ),
                icon: const Icon(Icons.add_rounded, size: 17),
                label: const Text('新增標籤', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
        ),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LuminaTokens.spaceLg,
              0,
              LuminaTokens.spaceLg,
              LuminaTokens.spaceXs,
            ),
            child: Container(
              key: const Key('tags_view_error_banner'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: LuminaTokens.statusErrorBg,
                borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                border: Border.all(
                  color: LuminaTokens.statusError.withValues(alpha: 0.5),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    size: 16,
                    color: LuminaTokens.statusError,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: LuminaTokens.statusError,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (_statusMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LuminaTokens.spaceLg,
              0,
              LuminaTokens.spaceLg,
              LuminaTokens.spaceXs,
            ),
            child: Text(
              _statusMessage!,
              key: const Key('tags_view_status_banner'),
              style: const TextStyle(
                color: LuminaTokens.statusSuccess,
                fontSize: 12,
              ),
            ),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : rows.isEmpty
              ? Center(
                  child: FrostedGlassContainer(
                    blurSigma: LuminaTokens.glassCardBlur,
                    color: LuminaTokens.glassCardBg,
                    borderRadius: BorderRadius.circular(
                      LuminaTokens.glassCardRadius,
                    ),
                    border: Border.all(color: LuminaTokens.glassCardBorder),
                    padding: const EdgeInsets.all(LuminaTokens.spaceLg),
                    child: const Text(
                      '尚未建立任何標籤，點擊右上角「新增標籤」開始分類。',
                      style: TextStyle(
                        color: LuminaTokens.glassTextSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                )
              : SmoothScrollWrapper(
                  controller: _scrollController,
                  child: ListView.separated(
                    key: const Key('tags_tree_list'),
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(
                      LuminaTokens.spaceLg,
                      LuminaTokens.spaceXs,
                      LuminaTokens.spaceLg,
                      LuminaTokens.bottomScrollClearance,
                    ),
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, index) =>
                        _buildTagRow(rows[index], byId),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildTagRow(_TagTreeRow row, Map<String, TagSummary> byId) {
    final tag = row.tag;
    final dotColor = parseLuminaTagColor(tag.color);
    final hasChildren = tag.childIds.isNotEmpty;
    final isCollapsed = _collapsedTagIds.contains(tag.id);
    final isHighlighted = widget.initialTagId == tag.id;

    return Padding(
      padding: EdgeInsets.only(left: row.depth * 24.0),
      child: FrostedGlassContainer(
        key: Key('tag_tree_row_${tag.id}'),
        blurSigma: 0,
        enableBackdropBlur: false,
        color: isHighlighted
            ? LuminaTokens.glassCardActiveBg
            : LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
        border: Border.all(
          color: isHighlighted
              ? LuminaTokens.accentBlue.withValues(alpha: 0.55)
              : LuminaTokens.glassCardBorder,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            if (hasChildren)
              IconButton(
                key: Key('btn_tag_expand_${tag.id}'),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                icon: Icon(
                  isCollapsed
                      ? Icons.chevron_right_rounded
                      : Icons.expand_more_rounded,
                  size: 18,
                  color: LuminaTokens.glassTextSecondary,
                ),
                onPressed: () {
                  _setState(() {
                    if (isCollapsed) {
                      _collapsedTagIds.remove(tag.id);
                    } else {
                      _collapsedTagIds.add(tag.id);
                    }
                  });
                },
              )
            else
              const SizedBox(width: 26),
            Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: InkWell(
                key: Key('tag_row_tap_${tag.id}'),
                borderRadius: BorderRadius.circular(6),
                onTap: () => _openTagFocus(tag, FocusEntity.albums),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          tag.name,
                          style: const TextStyle(
                            color: LuminaTokens.glassTextPrimary,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        for (final parentId in tag.parentIds)
                          if (byId[parentId] case final parent?)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: LuminaTokens.glassPillBg,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: LuminaTokens.glassPillBorder,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '隸屬 ${parent.name}',
                                    style: const TextStyle(
                                      color: LuminaTokens.glassTextSecondary,
                                      fontSize: 10.5,
                                    ),
                                  ),
                                  const SizedBox(width: 3),
                                  GestureDetector(
                                    key: Key(
                                      'btn_tag_unlink_parent_${parent.id}_${tag.id}',
                                    ),
                                    onTap: () =>
                                        _handleUnlinkParent(parent.id, tag),
                                    child: const Icon(
                                      Icons.close_rounded,
                                      size: 12,
                                      color: LuminaTokens.textMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '直接 ${tag.directItemCount} 項 · 含子層 ${tag.recursiveItemCount} 項',
                      style: const TextStyle(
                        color: LuminaTokens.textMuted,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            TextButton(
              key: Key('btn_tag_focus_albums_${tag.id}'),
              onPressed: () => _openTagFocus(tag, FocusEntity.albums),
              style: TextButton.styleFrom(
                foregroundColor: LuminaTokens.accentBlue,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('查看專輯', style: TextStyle(fontSize: 12)),
            ),
            TextButton(
              key: Key('btn_tag_focus_tracks_${tag.id}'),
              onPressed: () => _openTagFocus(tag, FocusEntity.tracks),
              style: TextButton.styleFrom(
                foregroundColor: LuminaTokens.glassTextSecondary,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('查看曲目', style: TextStyle(fontSize: 12)),
            ),
            IconButton(
              key: Key('btn_tag_link_parent_${tag.id}'),
              tooltip: '設定父標籤',
              visualDensity: VisualDensity.compact,
              icon: const Icon(
                Icons.account_tree_outlined,
                size: 17,
                color: LuminaTokens.glassTextSecondary,
              ),
              onPressed: () => _handleLinkParent(tag),
            ),
            IconButton(
              key: Key('btn_tag_edit_${tag.id}'),
              tooltip: '編輯標籤',
              visualDensity: VisualDensity.compact,
              icon: const Icon(
                Icons.edit_outlined,
                size: 17,
                color: LuminaTokens.glassTextSecondary,
              ),
              onPressed: () => _handleEditTag(tag),
            ),
            IconButton(
              key: Key('btn_tag_delete_${tag.id}'),
              tooltip: '刪除標籤',
              visualDensity: VisualDensity.compact,
              icon: const Icon(
                Icons.delete_outline_rounded,
                size: 17,
                color: LuminaTokens.statusError,
              ),
              onPressed: () => _handleDeleteTag(tag),
            ),
          ],
        ),
      ),
    );
  }
}
