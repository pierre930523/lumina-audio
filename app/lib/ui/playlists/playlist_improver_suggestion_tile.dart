part of 'playlist_improver_dialog.dart';

String _formatImproverTrackSpec(PlaylistTrackSummary t) {
  final codec = t.codec.trim().isEmpty ? 'AUDIO' : t.codec.toUpperCase();
  if (t.isDsd) return 'DSD ${(t.sampleRateHz / 44100).round()}x ($codec)';
  final khz = t.sampleRateHz > 0
      ? '${(t.sampleRateHz / 1000).toStringAsFixed(t.sampleRateHz % 1000 == 0 ? 0 : 1)} kHz'
      : '';
  final bits = t.bitDepth > 0 ? '${t.bitDepth}-bit' : '';
  return <String>[
    codec,
    if (bits.isNotEmpty) bits,
    if (khz.isNotEmpty) khz,
  ].join(' · ');
}

(String, Color) _improverKindBadge(PlaylistImprovementKind kind) =>
    switch (kind) {
      PlaylistImprovementKind.duplicate => (
        '重複去重',
        LuminaTokens.statusWarning,
      ),
      PlaylistImprovementKind.repair => ('失效修復', LuminaTokens.statusError),
      PlaylistImprovementKind.upgrade => ('音質升級', LuminaTokens.hiResGoldText),
    };

class _PlaylistImproverSuggestionTile extends StatelessWidget {
  final PlaylistImprovementSuggestion suggestion;
  final bool checked;
  final bool disabled;
  final ValueChanged<bool> onChanged;

  const _PlaylistImproverSuggestionTile({
    required this.suggestion,
    required this.checked,
    required this.disabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final s = suggestion;
    final (kindLabel, kindColor) = _improverKindBadge(s.kind);
    final cur = s.currentTrack;
    final cand = s.candidateTrack;
    final deltaScore = (cur != null && cand != null)
        ? (cand.qualityScore - cur.qualityScore)
        : null;

    final originSummary = cur != null
        ? '${cur.title}・${cur.artistName.isEmpty ? "未知藝人" : cur.artistName}・${_formatImproverTrackSpec(cur)}・品質 ${cur.qualityScore.toStringAsFixed(0)}'
        : '失效項目：${s.rawEntry}';

    final targetSummary = switch (s.kind) {
      PlaylistImprovementKind.duplicate =>
        '移除重複（保留位置 #${(s.duplicateOfPosition ?? 0) + 1}）',
      PlaylistImprovementKind.repair || PlaylistImprovementKind.upgrade =>
        cand != null
            ? '替換為 ${cand.title}・${cand.artistName.isEmpty ? "未知藝人" : cand.artistName}・${_formatImproverTrackSpec(cand)}'
            : '替換候選曲目',
    };

    return Container(
      margin: const EdgeInsets.only(bottom: LuminaTokens.spaceXs),
      padding: const EdgeInsets.symmetric(
        horizontal: LuminaTokens.spaceSm,
        vertical: LuminaTokens.spaceXs,
      ),
      decoration: BoxDecoration(
        color: checked
            ? LuminaTokens.glassNavActiveBg
            : LuminaTokens.glassCardBg,
        borderRadius: BorderRadius.circular(LuminaTokens.radiusSm),
        border: Border.all(
          color: checked
              ? LuminaTokens.glassSegmentSelectedBorder
              : LuminaTokens.glassCardBorder,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Checkbox(
            key: Key('improver_checkbox_${s.suggestionId}'),
            value: checked,
            activeColor: LuminaTokens.glassSwitchOnTrack,
            checkColor: LuminaTokens.onAccentDark,
            onChanged: disabled ? null : (v) => onChanged(v == true),
          ),
          const SizedBox(width: LuminaTokens.spaceXs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: kindColor.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: kindColor.withValues(alpha: 0.65),
                        ),
                      ),
                      child: Text(
                        kindLabel,
                        style: TextStyle(
                          color: kindColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '#${s.position + 1}',
                      style: const TextStyle(
                        color: LuminaTokens.textMuted,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (deltaScore != null && deltaScore > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: LuminaTokens.hiResGoldBg,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: LuminaTokens.hiResGoldBorder,
                          ),
                        ),
                        child: Text(
                          '+Δ${deltaScore.toStringAsFixed(0)} 品質分',
                          style: const TextStyle(
                            color: LuminaTokens.hiResGoldText,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    if (s.confidence > 0)
                      Text(
                        '信心 ${(s.confidence * 100).round()}%',
                        style: const TextStyle(
                          color: LuminaTokens.textMuted,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  originSummary,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: LuminaTokens.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.arrow_forward_rounded,
                      size: 14,
                      color: kindColor,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        targetSummary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: LuminaTokens.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                if (s.reason.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      s.reason,
                      style: const TextStyle(
                        color: LuminaTokens.textMuted,
                        fontSize: 11.5,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
