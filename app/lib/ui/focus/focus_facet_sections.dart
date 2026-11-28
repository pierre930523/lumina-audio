part of 'focus_filter_drawer.dart';

extension _FocusFacetSections on _FocusFilterDrawerState {
  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        title,
        style: const TextStyle(
          color: LuminaTokens.glassTextTertiary,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  Widget _buildBucketGroup(FocusFacet facet, FocusFacetsResponse resp) {
    final buckets = resp.bucketsFor(facet);
    if (buckets.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            facet.displayLabel,
            style: const TextStyle(
              color: LuminaTokens.glassTextSecondary,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final b in buckets) _buildFacetChip(facet, b),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPreferenceGroup(FocusFacetsResponse resp) {
    final live = resp.bucketsFor(FocusFacet.preference);
    final buckets = live.isNotEmpty
        ? live
        : const <FocusFacetBucket>[
            FocusFacetBucket(value: 'favorite', label: '喜愛', count: 0),
            FocusFacetBucket(value: 'neutral', label: '普通', count: 0),
            FocusFacetBucket(value: 'banned', label: '已封鎖', count: 0),
          ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            FocusFacet.preference.displayLabel,
            style: const TextStyle(
              color: LuminaTokens.glassTextSecondary,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final b in buckets)
                _buildFacetChip(FocusFacet.preference, b),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPlayStatusGroup(FocusFacetsResponse resp) {
    final live = resp.bucketsFor(FocusFacet.playStatus);
    final buckets = live.isNotEmpty
        ? live
        : const <FocusFacetBucket>[
            FocusFacetBucket(value: 'played', label: '已聽', count: 0),
            FocusFacetBucket(value: 'unplayed', label: '未聽', count: 0),
          ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            FocusFacet.playStatus.displayLabel,
            style: const TextStyle(
              color: LuminaTokens.glassTextSecondary,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final b in buckets) _buildFacetChip(FocusFacet.playStatus, b),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInspectorGroup(FocusFacetsResponse resp) {
    final live = resp.bucketsFor(FocusFacet.inspector);
    final buckets = live.isNotEmpty
        ? live
        : const <FocusFacetBucket>[
            FocusFacetBucket(value: 'has_duplicates', label: '多版本重複', count: 0),
            FocusFacetBucket(value: 'missing_cover', label: '缺封面', count: 0),
            FocusFacetBucket(
              value: 'has_manual_edits',
              label: '含手動編輯',
              count: 0,
            ),
          ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            FocusFacet.inspector.displayLabel,
            style: const TextStyle(
              color: LuminaTokens.glassTextSecondary,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final b in buckets) _buildFacetChip(FocusFacet.inspector, b),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFacetChip(FocusFacet facet, FocusFacetBucket bucket) {
    final val = _valueForFacetBucket(facet, bucket.value);
    final activeMode = widget.controller.activeModeFor(facet, val);
    final isInclude = activeMode == FocusPredicateMode.include;
    final isExclude = activeMode == FocusPredicateMode.exclude;

    final bgColor = isExclude
        ? LuminaTokens.statusError.withValues(alpha: 0.18)
        : (isInclude
              ? LuminaTokens.accentBlue.withValues(alpha: 0.24)
              : LuminaTokens.glassPillBg);
    final borderColor = isExclude
        ? LuminaTokens.statusError.withValues(alpha: 0.65)
        : (isInclude
              ? LuminaTokens.accentBlue.withValues(alpha: 0.7)
              : LuminaTokens.glassPillBorder);
    final textColor = isExclude
        ? LuminaTokens.statusError
        : (isInclude ? Colors.white : LuminaTokens.glassTextPrimary);

    void trigger(FocusPredicateMode mode) {
      widget.controller.addOrTogglePredicate(
        FocusPredicate(facet: facet, value: val, mode: mode),
      );
    }

    return GestureDetector(
      onSecondaryTap: () => trigger(FocusPredicateMode.exclude),
      child: Container(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusPill),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              key: Key('focus_bucket_${facet.wireName}_${bucket.value}'),
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(LuminaTokens.radiusPill),
              ),
              onTap: () => trigger(FocusPredicateMode.include),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      bucket.label,
                      style: TextStyle(
                        color: textColor,
                        fontSize: 12,
                        fontWeight: (isInclude || isExclude)
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                    if (bucket.count > 0) ...[
                      const SizedBox(width: 5),
                      Text(
                        '${bucket.count}',
                        style: const TextStyle(
                          color: LuminaTokens.glassTextTertiary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Tooltip(
              message: '排除 ${bucket.label}',
              child: InkWell(
                key: Key(
                  'focus_bucket_exclude_${facet.wireName}_${bucket.value}',
                ),
                borderRadius: const BorderRadius.horizontal(
                  right: Radius.circular(LuminaTokens.radiusPill),
                ),
                onTap: () => trigger(FocusPredicateMode.exclude),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 7, 4),
                  child: Icon(
                    Icons.remove_rounded,
                    size: 13,
                    color: isExclude
                        ? LuminaTokens.statusError
                        : LuminaTokens.glassTextTertiary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildYearRangeRow(FocusIntRangeBounds bounds) {
    final hintMin = bounds.min?.toString() ?? '1960';
    final hintMax = bounds.max?.toString() ?? '2026';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text(
            '發行年份',
            style: TextStyle(
              color: LuminaTokens.glassTextSecondary,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(
            width: 72,
            height: 30,
            child: TextField(
              key: const Key('focus_year_min_input'),
              controller: _minYearCtrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(
                color: LuminaTokens.glassTextPrimary,
                fontSize: 12,
              ),
              decoration: _compactInputDecoration(hintMin),
              onSubmitted: (_) => _applyYearRange(),
            ),
          ),
          const Text('–', style: TextStyle(color: LuminaTokens.textMuted)),
          SizedBox(
            width: 72,
            height: 30,
            child: TextField(
              key: const Key('focus_year_max_input'),
              controller: _maxYearCtrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(
                color: LuminaTokens.glassTextPrimary,
                fontSize: 12,
              ),
              decoration: _compactInputDecoration(hintMax),
              onSubmitted: (_) => _applyYearRange(),
            ),
          ),
          OutlinedButton(
            key: const Key('btn_focus_apply_year'),
            onPressed: _applyYearRange,
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              backgroundColor: LuminaTokens.glassPillBg,
              foregroundColor: LuminaTokens.glassTextPrimary,
              side: const BorderSide(color: LuminaTokens.glassPillBorder),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            ),
            child: const Text('套用', style: TextStyle(fontSize: 11.5)),
          ),
        ],
      ),
    );
  }

  Widget _buildAddedAtRow() {
    const presets = <(int, String)>[
      (7, '近 7 天'),
      (30, '近 30 天'),
      (90, '近 90 天'),
      (365, '近 1 年'),
    ];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        const Text(
          '加入時間',
          style: TextStyle(
            color: LuminaTokens.glassTextSecondary,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        for (final (days, label) in presets)
          ActionChip(
            key: Key('focus_added_at_${days}d'),
            label: Text(
              label,
              style: const TextStyle(
                color: LuminaTokens.glassTextPrimary,
                fontSize: 11.5,
              ),
            ),
            surfaceTintColor: Colors.transparent,
            backgroundColor: LuminaTokens.glassPillBg,
            side: const BorderSide(color: LuminaTokens.glassPillBorder),
            visualDensity: VisualDensity.compact,
            onPressed: () => _applyAddedAtDays(days),
          ),
      ],
    );
  }

  InputDecoration _compactInputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: LuminaTokens.textMuted, fontSize: 11.5),
      isDense: true,
      filled: true,
      fillColor: LuminaTokens.glassPillBg,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        borderSide: const BorderSide(color: LuminaTokens.glassPillBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        borderSide: const BorderSide(color: LuminaTokens.glassPillBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        borderSide: const BorderSide(color: LuminaTokens.focusRing, width: 1.4),
      ),
    );
  }
}
