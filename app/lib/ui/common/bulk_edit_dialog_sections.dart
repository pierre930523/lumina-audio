part of 'bulk_edit_dialog.dart';

extension _BulkEditDialogSections on _BulkEditDialogState {
  Widget _buildDialog(BuildContext context) {
    final count = _summary?.selectedCount ?? widget.entityIds.length;
    final entityLabel =
        widget.entityType == BulkEditEntityType.album ? '張專輯' : '首曲目';
    final headerTitle = widget.title ?? '批量編輯（$count $entityLabel）';

    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660, maxHeight: 680),
        child: FrostedGlassContainer(
          key: const Key('bulk_edit_dialog'),
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
                _buildHeader(headerTitle),
                if (_errorMessage != null) _buildErrorBanner(_errorMessage!),
                const SizedBox(height: LuminaTokens.spaceSm),
                Flexible(
                  child: _loading
                      ? const Padding(
                          padding: EdgeInsets.all(36),
                          child: Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : _buildBodyContent(),
                ),
                const SizedBox(height: LuminaTokens.spaceMd),
                _buildFooterActions(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorBanner(String message) => Padding(
    padding: const EdgeInsets.only(top: LuminaTokens.spaceXs),
    child: Container(
      key: const Key('bulk_edit_error_banner'),
      padding: const EdgeInsets.symmetric(
        horizontal: LuminaTokens.spaceSm,
        vertical: LuminaTokens.spaceXs,
      ),
      decoration: BoxDecoration(
        color: LuminaTokens.statusErrorBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(
          color: LuminaTokens.statusError.withValues(alpha: 0.6),
        ),
      ),
      child: Text(
        message,
        style: const TextStyle(color: LuminaTokens.statusError, fontSize: 12.5),
      ),
    ),
  );

  Widget _buildHeader(String headerTitle) {
    final userEditsCount = _summary?.hasUserEditsCount ?? 0;
    return Row(
      children: [
        const Icon(Icons.edit_note_rounded, size: 20, color: LuminaTokens.accentBlue),
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
        if (userEditsCount > 0)
          _buildFieldPill(
            key: const Key('bulk_edit_user_edits_badge'),
            label: '$userEditsCount 項含手動覆寫',
            color: LuminaTokens.accentBlue,
          ),
      ],
    );
  }

  Widget _buildBodyContent() => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '所有修改僅寫入非破壞性使用者覆寫層，未編輯的 <Mixed> 欄位將保留各自原值。',
          style: TextStyle(color: LuminaTokens.textMuted, fontSize: 12),
        ),
        const SizedBox(height: LuminaTokens.spaceSm),
        for (final spec in _fieldSpecs) _buildFieldRow(spec),
        const SizedBox(height: LuminaTokens.spaceSm),
        _buildMetaPolicySection(),
        const SizedBox(height: LuminaTokens.spaceMd),
        _buildTagsSection(),
      ],
    ),
  );

  Widget _buildFieldRow(_BulkFieldSpec spec) {
    final tri = _triStateFor(spec.key);
    final mode = _fieldModes[spec.key] ?? _BulkFieldEditMode.untouched;
    final isMixed = tri is TriStateMixed<Object?>;
    final isCleared = mode == _BulkFieldEditMode.clear;
    final hint = isCleared
        ? '將清除使用者覆寫（還原檔案/雲端層）'
        : (isMixed
              ? '<多重值 — 未修改則保留各別原值>'
              : (tri is TriStateEmpty<Object?> ? '空白（未修改則保留）' : null));

    return Padding(
      padding: const EdgeInsets.only(bottom: LuminaTokens.spaceSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                spec.label,
                style: const TextStyle(
                  color: LuminaTokens.glassTextSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              if (isMixed && mode == _BulkFieldEditMode.untouched)
                _buildFieldPill(
                  key: Key('bulk_field_mixed_badge_${spec.key}'),
                  label: '<Mixed>',
                  color: LuminaTokens.statusWarning,
                  tooltip: '共 ${tri.distinctCount} 種不同值',
                ),
              if (mode == _BulkFieldEditMode.setValue)
                _buildFieldPill(
                  key: Key('bulk_field_dirty_badge_${spec.key}'),
                  label: '將套用新值',
                  color: LuminaTokens.accentBlue,
                ),
              if (isCleared)
                _buildFieldPill(
                  key: Key('bulk_field_clear_badge_${spec.key}'),
                  label: '將清除覆寫',
                  color: LuminaTokens.statusError,
                ),
              const Spacer(),
              TextButton(
                key: Key('btn_bulk_clear_${spec.key}'),
                onPressed: _submitting ? null : () => _toggleClearField(spec.key),
                style: TextButton.styleFrom(
                  foregroundColor: isCleared
                      ? LuminaTokens.accentBlue
                      : LuminaTokens.textMuted,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  isCleared ? '取消清除' : '清除覆寫',
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            key: Key('bulk_field_input_${spec.key}'),
            controller: _controllers[spec.key],
            enabled: !_submitting && !isCleared,
            maxLines: spec.multiline ? 3 : 1,
            keyboardType:
                spec.isInt ? TextInputType.number : TextInputType.text,
            onChanged: (val) => _onFieldTextChanged(spec.key, val),
            style: const TextStyle(
              color: LuminaTokens.glassTextPrimary,
              fontSize: 13,
            ),
            decoration: LuminaSettingsStyles.inputDecoration(
              hintText: hint,
              borderRadius: LuminaTokens.radiusSm,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFieldPill({
    required Key key,
    required String label,
    required Color color,
    String? tooltip,
  }) {
    final pill = Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w700),
      ),
    );
    return tooltip != null ? Tooltip(message: tooltip, child: pill) : pill;
  }

  Widget _buildSectionCard(Widget child) => Container(
    padding: const EdgeInsets.all(LuminaTokens.spaceSm),
    decoration: BoxDecoration(
      color: LuminaTokens.glassCardBg,
      borderRadius: BorderRadius.circular(LuminaTokens.radiusMd),
      border: Border.all(color: LuminaTokens.glassCardBorder),
    ),
    child: child,
  );

  Widget _buildMetaPolicySection() {
    final policyTri = _summary?.metaPolicy ?? const TriStateEmpty<String>();
    final currentLabel = switch (policyTri) {
      TriStateCommon<String>(:final value) => value,
      TriStateMixed<String>() => '<Mixed>',
      TriStateEmpty<String>() => 'inherit',
    };

    return _buildSectionCard(
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '詮釋資料優先策略 (meta_policy)',
                  style: TextStyle(
                    color: LuminaTokens.glassTextPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '目前狀態：$currentLabel',
                  style: const TextStyle(color: LuminaTokens.textMuted, fontSize: 11.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: LuminaTokens.spaceSm),
          DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              key: const Key('bulk_edit_meta_policy_dropdown'),
              value: _selectedMetaPolicy,
              dropdownColor: LuminaTokens.glassMenuBg,
              style: const TextStyle(color: LuminaTokens.glassTextPrimary, fontSize: 12.5),
              items: const <DropdownMenuItem<String?>>[
                DropdownMenuItem<String?>(value: null, child: Text('保持不變')),
                DropdownMenuItem<String?>(value: 'inherit', child: Text('繼承全域 (inherit)')),
                DropdownMenuItem<String?>(value: 'file', child: Text('檔案優先 (file)')),
                DropdownMenuItem<String?>(value: 'cloud', child: Text('雲端優先 (cloud)')),
              ],
              onChanged: _submitting
                  ? null
                  : (val) => _setState(() => _selectedMetaPolicy = val),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTagsSection() {
    final tags = _summary?.tags ?? const <BulkTagSummaryItem>[];
    return _buildSectionCard(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.label_outline_rounded, size: 16, color: LuminaTokens.accentBlue),
              SizedBox(width: 6),
              Text(
                '自訂標籤（三態選取：未選 / 部分 / 全選）',
                style: TextStyle(
                  color: LuminaTokens.glassTextPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (tags.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '尚未建立自訂標籤',
                style: TextStyle(color: LuminaTokens.textMuted, fontSize: 12),
              ),
            )
          else
            for (final tag in tags)
              Row(
                children: [
                  Checkbox(
                    key: Key('bulk_tag_checkbox_${tag.tagId}'),
                    tristate: true,
                    value: _currentTagStates[tag.tagId],
                    activeColor: LuminaTokens.accentBlue,
                    checkColor: LuminaTokens.onAccentDark,
                    onChanged: _submitting
                        ? null
                        : (next) => _onTagCheckboxChanged(tag.tagId, next),
                  ),
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
                      style: const TextStyle(color: LuminaTokens.glassTextPrimary, fontSize: 12.5),
                    ),
                  ),
                  Text(
                    '${tag.assignedCount}/${tag.totalCount}',
                    style: const TextStyle(color: LuminaTokens.textMuted, fontSize: 11.5),
                  ),
                ],
              ),
        ],
      ),
    );
  }

  Widget _buildFooterActions(BuildContext context) => Wrap(
    spacing: LuminaTokens.spaceXs,
    runSpacing: LuminaTokens.spaceXs,
    alignment: WrapAlignment.spaceBetween,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      OutlinedButton.icon(
        key: const Key('btn_bulk_revert_file_meta'),
        onPressed: (_loading || _submitting) ? null : _confirmAndRevertToFileMeta,
        style: LuminaSettingsStyles.outlinedButtonStyle(),
        icon: const Icon(Icons.restore_rounded, size: 16, color: LuminaTokens.statusWarning),
        label: const Text('還原原始檔案標籤', style: TextStyle(fontSize: 12.5)),
      ),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            key: const Key('btn_bulk_edit_cancel'),
            onPressed: _submitting ? null : () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(foregroundColor: LuminaTokens.glassTextSecondary),
            child: const Text('取消'),
          ),
          const SizedBox(width: LuminaTokens.spaceXs),
          FilledButton(
            key: const Key('btn_bulk_edit_apply'),
            onPressed: (_loading || _submitting || !_hasPendingChanges)
                ? null
                : _submitPatch,
            style: LuminaSettingsStyles.filledButtonStyle(),
            child: const Text('套用修改'),
          ),
        ],
      ),
    ],
  );

  Widget _buildRevertConfirmDialog(BuildContext ctx, int count) => Dialog(
    backgroundColor: Colors.transparent,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: FrostedGlassContainer(
        key: const Key('bulk_revert_confirm_dialog'),
        blurSigma: LuminaTokens.glassDialogBlur,
        color: LuminaTokens.glassDialogBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
        border: Border.all(color: LuminaTokens.glassCardBorder),
        padding: const EdgeInsets.all(LuminaTokens.spaceLg),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '還原原始檔案標籤？',
                style: TextStyle(color: LuminaTokens.glassTextPrimary, fontSize: 15.5, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: LuminaTokens.spaceXs),
              Text(
                '將清除所選 $count 個項目的所有手動覆寫 (user_edits)，並重新以原始檔案與雲端詮釋資料計算有效顯示內容。',
                style: const TextStyle(color: LuminaTokens.glassTextSecondary, fontSize: 12.5),
              ),
              const SizedBox(height: LuminaTokens.spaceMd),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const Key('btn_cancel_bulk_revert'),
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: LuminaTokens.spaceXs),
                  FilledButton(
                    key: const Key('btn_confirm_bulk_revert'),
                    onPressed: () => Navigator.of(ctx).pop(true),
                    style: LuminaSettingsStyles.filledButtonStyle(
                      backgroundColor: LuminaTokens.statusWarning,
                      foregroundColor: LuminaTokens.onAccentDark,
                    ),
                    child: const Text('確認還原'),
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
