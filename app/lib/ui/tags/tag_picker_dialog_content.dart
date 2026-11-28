part of 'tag_picker_dialog.dart';

extension _TagPickerDialogContent on _TagPickerDialogState {
  Widget _buildDialog(BuildContext context) {
    final headerTitle =
        widget.title ??
        (widget.entityIds.length > 1
            ? '批次管理標籤（${widget.entityIds.length} 項）'
            : '管理標籤');
    final canCreateInline = _query.isNotEmpty && !_hasExactMatch;
    final visibleTags = _filteredTags;

    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 540),
        child: FrostedGlassContainer(
          key: const Key('tag_picker_dialog'),
          blurSigma: LuminaTokens.glassDialogBlur,
          color: LuminaTokens.glassDialogBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
          border: Border.all(color: LuminaTokens.glassCardBorder),
          boxShadow: const [
            BoxShadow(
              color: Color(0x99000000),
              blurRadius: 32,
              offset: Offset(0, 14),
            ),
          ],
          padding: const EdgeInsets.all(LuminaTokens.spaceLg),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.label_rounded,
                      size: 19,
                      color: LuminaTokens.accentBlue,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        headerTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.glassTextPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: LuminaTokens.spaceSm),
                TextField(
                  key: const Key('tag_picker_search_input'),
                  controller: _searchController,
                  autofocus: true,
                  onChanged: (_) => _setState(() {}),
                  onSubmitted: (_) {
                    if (canCreateInline) {
                      _createAndSelectTag();
                    }
                  },
                  style: const TextStyle(
                    color: LuminaTokens.glassTextPrimary,
                    fontSize: 13,
                  ),
                  decoration: InputDecoration(
                    hintText: '搜尋現有標籤，或輸入新名稱建立...',
                    hintStyle: const TextStyle(color: LuminaTokens.textMuted),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      size: 18,
                      color: LuminaTokens.textMuted,
                    ),
                    filled: true,
                    fillColor: LuminaTokens.glassPillBg,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: LuminaTokens.spaceSm,
                      vertical: LuminaTokens.spaceXs,
                    ),
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
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
                      borderSide: const BorderSide(
                        color: LuminaTokens.focusRing,
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
                if (canCreateInline) _buildInlineCreateBox(),
                if (_errorMessage != null) ...[
                  const SizedBox(height: LuminaTokens.spaceXs),
                  Text(
                    _errorMessage!,
                    key: const Key('tag_picker_error_text'),
                    style: const TextStyle(
                      color: LuminaTokens.statusError,
                      fontSize: 12,
                    ),
                  ),
                ],
                const SizedBox(height: LuminaTokens.spaceSm),
                Flexible(child: _buildTagsList(visibleTags)),
                const SizedBox(height: LuminaTokens.spaceMd),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      key: const Key('btn_tag_picker_cancel'),
                      onPressed: _submitting
                          ? null
                          : () => Navigator.of(context).pop(_createdAny),
                      style: TextButton.styleFrom(
                        foregroundColor: LuminaTokens.glassTextSecondary,
                      ),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: LuminaTokens.spaceXs),
                    FilledButton(
                      key: const Key('btn_tag_picker_confirm'),
                      onPressed: _submitting ? null : _applyChanges,
                      style: FilledButton.styleFrom(
                        backgroundColor: LuminaTokens.glassSwitchOnTrack,
                        foregroundColor: LuminaTokens.onAccentDark,
                      ),
                      child: const Text('套用'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInlineCreateBox() {
    return Padding(
      padding: const EdgeInsets.only(top: LuminaTokens.spaceXs),
      child: Container(
        padding: const EdgeInsets.all(LuminaTokens.spaceXs),
        decoration: BoxDecoration(
          color: LuminaTokens.glassCardBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
          border: Border.all(
            color: LuminaTokens.accentBlue.withValues(alpha: 0.45),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                for (final hex in kLuminaTagColorSwatches)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: InkWell(
                      key: Key('tag_picker_swatch_$hex'),
                      borderRadius: BorderRadius.circular(999),
                      onTap: () => _setState(() => _selectedNewColor = hex),
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          color: parseLuminaTagColor(hex),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _selectedNewColor == hex
                                ? Colors.white
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const Key('btn_tag_picker_create_inline'),
              onPressed: _submitting ? null : _createAndSelectTag,
              style: FilledButton.styleFrom(
                backgroundColor: LuminaTokens.glassSwitchOnTrack,
                foregroundColor: LuminaTokens.onAccentDark,
              ),
              icon: const Icon(Icons.add_rounded, size: 17),
              label: Text(
                '+ 建立並套用「$_query」',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTagsList(List<TagSummary> visibleTags) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (visibleTags.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            '尚無符合的標籤，可直接輸入名稱建立',
            style: TextStyle(color: LuminaTokens.textMuted, fontSize: 12.5),
          ),
        ),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: visibleTags.length,
      itemBuilder: (context, index) {
        final tag = visibleTags[index];
        final checked = _selectedIds.contains(tag.id);
        return CheckboxListTile(
          key: Key('tag_picker_item_${tag.id}'),
          value: checked,
          dense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          activeColor: LuminaTokens.accentBlue,
          checkColor: LuminaTokens.onAccentDark,
          controlAffinity: ListTileControlAffinity.leading,
          onChanged: _submitting
              ? null
              : (val) {
                  _setState(() {
                    if (val == true) {
                      _selectedIds.add(tag.id);
                    } else {
                      _selectedIds.remove(tag.id);
                    }
                  });
                },
          title: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: parseLuminaTagColor(tag.color),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  tag.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.glassTextPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                '${tag.recursiveItemCount}',
                style: const TextStyle(
                  color: LuminaTokens.textMuted,
                  fontSize: 11.5,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
