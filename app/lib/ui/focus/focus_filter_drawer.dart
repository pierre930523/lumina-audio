import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_tokens.dart';
import '../theme/smooth_scroll.dart';
import 'focus_controller.dart';

part 'focus_facet_sections.dart';

/// Collapsible Liquid Glass multi-dimensional Focus facet drawer showing all 12
/// facets with live cross-filtered counts, range inputs, and `+` / `-` actions.
class FocusFilterDrawer extends StatefulWidget {
  final FocusController controller;

  const FocusFilterDrawer({super.key, required this.controller});

  @override
  State<FocusFilterDrawer> createState() => _FocusFilterDrawerState();
}

class _FocusFilterDrawerState extends State<FocusFilterDrawer> {
  final TextEditingController _minYearCtrl = TextEditingController();
  final TextEditingController _maxYearCtrl = TextEditingController();
  final GlideScrollController _scrollController = GlideScrollController();

  @override
  void dispose() {
    _minYearCtrl.dispose();
    _maxYearCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _applyYearRange() {
    final minY = int.tryParse(_minYearCtrl.text.trim());
    final maxY = int.tryParse(_maxYearCtrl.text.trim());
    if (minY == null && maxY == null) {
      widget.controller.setFacetSinglePredicate(FocusFacet.releaseYear, null);
      return;
    }
    widget.controller.setFacetSinglePredicate(
      FocusFacet.releaseYear,
      FocusValue.intRange(min: minY, max: maxY),
    );
  }

  void _applyAddedAtDays(int days) {
    final fromDate = DateTime.now()
        .toUtc()
        .subtract(Duration(days: days))
        .toIso8601String()
        .split('T')
        .first;
    widget.controller.setFacetSinglePredicate(
      FocusFacet.addedAt,
      FocusValue.dateRange(from: fromDate),
    );
  }

  FocusValue _valueForFacetBucket(FocusFacet facet, String rawValue) {
    if (facet == FocusFacet.bitDepth ||
        facet == FocusFacet.sampleRate ||
        facet == FocusFacet.channels) {
      final parsed = int.tryParse(rawValue);
      if (parsed != null) return FocusValue.int(parsed);
    }
    return FocusValue.string(rawValue);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        if (!widget.controller.drawerOpen) {
          return const SizedBox.shrink();
        }
        final facets =
            widget.controller.facets ?? const FocusFacetsResponse();
        final maxDrawerHeight =
            (MediaQuery.sizeOf(context).height * 0.36).clamp(180.0, 320.0);

        return Padding(
          padding: const EdgeInsets.only(top: LuminaTokens.spaceXs),
          child: FrostedGlassContainer(
            key: const Key('focus_filter_drawer'),
            blurSigma: LuminaTokens.glassCardBlur,
            color: LuminaTokens.glassDialogBg,
            borderRadius: BorderRadius.circular(LuminaTokens.glassCardRadius),
            border: Border.all(color: LuminaTokens.glassCardBorder),
            padding: const EdgeInsets.all(LuminaTokens.spaceMd),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxDrawerHeight),
              child: SmoothScrollWrapper(
                controller: _scrollController,
                child: SingleChildScrollView(
                  controller: _scrollController,
                  child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '多維度 Focus 篩選（左鍵包含 · 右鍵或減號排除）',
                          style: TextStyle(
                            color: LuminaTokens.glassTextPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        IconButton(
                          key: const Key('btn_focus_drawer_close'),
                          tooltip: '收合 Focus 面板',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 28,
                          ),
                          padding: EdgeInsets.zero,
                          icon: const Icon(
                            Icons.close_rounded,
                            size: 16,
                            color: LuminaTokens.glassTextSecondary,
                          ),
                          onPressed: () => widget.controller.toggleDrawer(false),
                        ),
                      ],
                    ),
                    const SizedBox(height: LuminaTokens.spaceSm),
                    _buildSectionTitle('音訊規格'),
                    _buildBucketGroup(FocusFacet.format, facets),
                    _buildBucketGroup(FocusFacet.bitDepth, facets),
                    _buildBucketGroup(FocusFacet.sampleRate, facets),
                    _buildBucketGroup(FocusFacet.channels, facets),
                    const Divider(
                      height: 18,
                      color: LuminaTokens.glassCardDivider,
                    ),
                    _buildSectionTitle('來源與狀態'),
                    _buildBucketGroup(FocusFacet.source, facets),
                    _buildPreferenceGroup(facets),
                    _buildPlayStatusGroup(facets),
                    _buildInspectorGroup(facets),
                    const Divider(
                      height: 18,
                      color: LuminaTokens.glassCardDivider,
                    ),
                    _buildSectionTitle('詮釋資料與標籤'),
                    _buildBucketGroup(FocusFacet.tag, facets),
                    _buildBucketGroup(FocusFacet.genre, facets),
                    _buildBucketGroup(FocusFacet.label, facets),
                    _buildYearRangeRow(facets.yearRange),
                    _buildAddedAtRow(),
                  ],
                ),
              ),
              ),
            ),
          ),
        );
      },
    );
  }
}
