import 'package:material_ui/material_ui.dart';

import '../../models/studio_models.dart';
import '../../services/audio_service.dart';
import '../common/frosted_glass_container.dart';
import '../theme/lumina_tokens.dart';

part 'playlist_improver_suggestion_tile.dart';

/// Frosted Glass review modal for Playlist Improver suggestions (deduplication,
/// broken-link repair, and lossless/Hi-Res quality upgrade).
class PlaylistImproverDialog extends StatefulWidget {
  final AudioService audioService;
  final PlaylistImprovementReport report;

  const PlaylistImproverDialog({
    super.key,
    required this.audioService,
    required this.report,
  });

  static Future<ApplyPlaylistImprovementsResult?> show({
    required BuildContext context,
    required AudioService audioService,
    required PlaylistImprovementReport report,
  }) {
    return showDialog<ApplyPlaylistImprovementsResult>(
      context: context,
      barrierColor: LuminaTokens.scrimBg,
      builder: (_) =>
          PlaylistImproverDialog(audioService: audioService, report: report),
    );
  }

  @override
  State<PlaylistImproverDialog> createState() => _PlaylistImproverDialogState();
}

class _PlaylistImproverDialogState extends State<PlaylistImproverDialog> {
  PlaylistImprovementKind? _filterKind;
  late final Set<String> _selectedIds;
  bool _applying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selectedIds = widget.report.suggestions
        .map((s) => s.suggestionId)
        .toSet();
  }

  List<PlaylistImprovementSuggestion> get _visibleSuggestions {
    final all = widget.report.suggestions;
    if (_filterKind == null) return all;
    return all.where((s) => s.kind == _filterKind).toList(growable: false);
  }

  Future<void> _applySelected() async {
    if (_applying || _selectedIds.isEmpty) return;
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      final result = await widget.audioService.applyPlaylistImprovements(
        widget.report.playlistId,
        ApplyPlaylistImprovementsRequest(
          suggestionIds: _selectedIds.toList(growable: false),
          reason: 'improver_ui',
        ),
      );
      if (!mounted) return;
      if (result == null) {
        setState(() {
          _applying = false;
          _error = '套用歌單優化失敗，請稍後再試';
        });
        return;
      }
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _applying = false;
        _error = '套用失敗：$e';
      });
    }
  }

  Widget _buildFilterChip({
    required Key chipKey,
    required String label,
    required PlaylistImprovementKind? kind,
  }) {
    final selected = _filterKind == kind;
    return ChoiceChip(
      key: chipKey,
      selected: selected,
      showCheckmark: false,
      surfaceTintColor: Colors.transparent,
      backgroundColor: LuminaTokens.glassPillBg,
      selectedColor: LuminaTokens.glassSegmentSelectedBg,
      side: BorderSide(
        color: selected
            ? LuminaTokens.glassSegmentSelectedBorder
            : LuminaTokens.glassPillBorder,
      ),
      onSelected: (_) => setState(() => _filterKind = kind),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: selected ? Colors.white : LuminaTokens.glassTextSecondary,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final visible = _visibleSuggestions;

    return Dialog(
      key: const Key('playlist_improver_dialog'),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 740, maxHeight: 620),
        child: FrostedGlassContainer(
          blurSigma: LuminaTokens.glassDialogBlur,
          color: LuminaTokens.glassDialogBg,
          borderRadius: BorderRadius.circular(LuminaTokens.radiusLg),
          border: Border.all(color: LuminaTokens.glassCardBorder),
          padding: const EdgeInsets.all(LuminaTokens.spaceLg),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.auto_fix_high_rounded,
                      color: LuminaTokens.hiResGoldText,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '歌單優化審查 · ${report.playlistName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.glassTextPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '關閉',
                      onPressed: _applying
                          ? null
                          : () => Navigator.of(context).pop(),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: LuminaTokens.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: LuminaTokens.spaceXs),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _buildFilterChip(
                      chipKey: const Key('improver_filter_all'),
                      label: '全部 (${report.suggestions.length})',
                      kind: null,
                    ),
                    _buildFilterChip(
                      chipKey: const Key('improver_filter_duplicate'),
                      label: '重複去重 (${report.duplicateCount})',
                      kind: PlaylistImprovementKind.duplicate,
                    ),
                    _buildFilterChip(
                      chipKey: const Key('improver_filter_repair'),
                      label: '失效修復 (${report.repairCount})',
                      kind: PlaylistImprovementKind.repair,
                    ),
                    _buildFilterChip(
                      chipKey: const Key('improver_filter_upgrade'),
                      label: '音質升級 (${report.upgradeCount})',
                      kind: PlaylistImprovementKind.upgrade,
                    ),
                  ],
                ),
                const SizedBox(height: LuminaTokens.spaceXs),
                Row(
                  children: [
                    Text(
                      '已選取 ${_selectedIds.length} / ${report.suggestions.length} 項變更',
                      style: const TextStyle(
                        color: LuminaTokens.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                    const Spacer(),
                    TextButton(
                      key: const Key('btn_improver_select_all'),
                      onPressed: _applying || visible.isEmpty
                          ? null
                          : () => setState(() {
                              _selectedIds.addAll(
                                visible.map((s) => s.suggestionId),
                              );
                            }),
                      child: const Text('全選'),
                    ),
                    TextButton(
                      key: const Key('btn_improver_clear_all'),
                      onPressed: _applying || _selectedIds.isEmpty
                          ? null
                          : () => setState(() {
                              for (final s in visible) {
                                _selectedIds.remove(s.suggestionId);
                              }
                            }),
                      child: const Text('清除選取'),
                    ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: LuminaTokens.spaceXs),
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        color: LuminaTokens.statusError,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                const Divider(color: LuminaTokens.glassCardDivider, height: 16),
                Expanded(
                  child: report.suggestions.isEmpty
                      ? const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.verified_rounded,
                                color: LuminaTokens.statusSuccess,
                                size: 36,
                              ),
                              SizedBox(height: 8),
                              Text(
                                '歌單狀態良好，無待優化項目',
                                style: TextStyle(
                                  color: LuminaTokens.textPrimary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        )
                      : visible.isEmpty
                      ? const Center(
                          child: Text(
                            '此分類下沒有建議項目',
                            style: TextStyle(color: LuminaTokens.textMuted),
                          ),
                        )
                      : ListView.builder(
                          itemCount: visible.length,
                          itemBuilder: (_, idx) {
                            final s = visible[idx];
                            return _PlaylistImproverSuggestionTile(
                              suggestion: s,
                              checked: _selectedIds.contains(s.suggestionId),
                              disabled: _applying,
                              onChanged: (v) => setState(() {
                                if (v) {
                                  _selectedIds.add(s.suggestionId);
                                } else {
                                  _selectedIds.remove(s.suggestionId);
                                }
                              }),
                            );
                          },
                        ),
                ),
                const SizedBox(height: LuminaTokens.spaceSm),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: LuminaTokens.glassTextSecondary,
                      ),
                      onPressed: _applying
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: LuminaTokens.spaceXs),
                    FilledButton.icon(
                      key: const Key('btn_apply_playlist_improvements'),
                      style: FilledButton.styleFrom(
                        backgroundColor: LuminaTokens.glassSwitchOnTrack,
                        foregroundColor: LuminaTokens.onAccentDark,
                      ),
                      onPressed: _applying || _selectedIds.isEmpty
                          ? null
                          : _applySelected,
                      icon: const Icon(Icons.check_rounded, size: 18),
                      label: Text(
                        _applying
                            ? '套用中...'
                            : '套用選取變更（自動建立快照）',
                      ),
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
}
