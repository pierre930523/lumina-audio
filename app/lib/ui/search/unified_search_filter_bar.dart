part of 'unified_search_results_view.dart';

extension _UnifiedSearchFilterBar on _UnifiedSearchResultsViewState {
  Widget _buildSourceFilterBar(UnifiedSearchController ctrl) {
    final buckets = ctrl.streamingBuckets;
    final providerKinds = <String>[
      ...ctrl.orderedStreamingKinds,
      for (final p in widget.streamingManager.browsableProviders)
        if (!buckets.containsKey(p.kind)) p.kind,
    ];

    return SingleChildScrollView(
      controller: _filterScrollController,
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _buildSourceChip(
            chipKey: const Key('search_source_all'),
            selected: ctrl.selectedSource == 'all',
            onTap: () => ctrl.selectSource('all'),
            leading: const Icon(
              Icons.apps_rounded,
              size: 15,
              color: LuminaTokens.glassTextPrimary,
            ),
            label: '全部 (${ctrl.totalResultCount})',
            isLoading: ctrl.isAnyLoading,
            hasError: false,
          ),
          const SizedBox(width: LuminaTokens.spaceXs),
          _buildSourceChip(
            chipKey: const Key('search_source_local'),
            selected: ctrl.selectedSource == 'local',
            onTap: () => ctrl.selectSource('local'),
            leading: const Icon(
              Icons.library_music_rounded,
              size: 15,
              color: LuminaTokens.textSecondary,
            ),
            label: '本機曲庫 (${ctrl.localTotalCount})',
            isLoading: ctrl.isSearchingLocal,
            hasError: false,
          ),
          for (final kind in providerKinds)
            if (StreamingProviderMeta.byKind(kind) case final meta?) ...[
              const SizedBox(width: LuminaTokens.spaceXs),
              _buildProviderFilterChip(
                meta: meta,
                bucket: buckets[kind],
                selected: ctrl.selectedSource == kind,
                onTap: () => ctrl.selectSource(kind),
              ),
            ],
        ],
      ),
    );
  }

  Widget _buildProviderFilterChip({
    required StreamingProviderMeta meta,
    required ProviderSearchBucket? bucket,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final isLoading = bucket?.isLoading ?? false;
    final hasError = bucket?.hasError ?? false;
    final count = bucket?.totalCount ?? 0;
    final label = (isLoading && count == 0)
        ? meta.name
        : '${meta.name} ($count)';

    return _buildSourceChip(
      chipKey: Key('search_source_${meta.kind}'),
      selected: selected,
      onTap: bucket != null ? onTap : null,
      leading: meta.buildBadge(boxSize: 16, borderRadius: 4),
      label: label,
      isLoading: isLoading,
      hasError: hasError,
    );
  }

  Widget _buildSourceChip({
    required Key chipKey,
    required bool selected,
    required VoidCallback? onTap,
    required Widget leading,
    required String label,
    required bool isLoading,
    required bool hasError,
  }) {
    return ChoiceChip(
      key: chipKey,
      selected: selected,
      showCheckmark: false,
      surfaceTintColor: Colors.transparent,
      onSelected: onTap != null ? (_) => onTap() : null,
      backgroundColor: LuminaTokens.glassPillBg,
      selectedColor: LuminaTokens.glassSegmentSelectedBg,
      side: BorderSide(
        color: selected
            ? LuminaTokens.glassSegmentSelectedBorder
            : (hasError
                  ? LuminaTokens.statusWarning
                  : LuminaTokens.glassPillBorder),
      ),
      avatar: leading,
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: selected
                  ? Colors.white
                  : LuminaTokens.glassTextSecondary,
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
          if (isLoading) ...[
            const SizedBox(width: 6),
            const SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: LuminaTokens.glassTextPrimary,
              ),
            ),
          ] else if (hasError) ...[
            const SizedBox(width: 5),
            const Icon(
              Icons.error_outline_rounded,
              size: 14,
              color: LuminaTokens.statusWarning,
            ),
          ],
        ],
      ),
    );
  }
}
