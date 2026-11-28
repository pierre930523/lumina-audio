part of 'track_info_editor_dialog.dart';

extension _TrackInfoEditorPolicyTab on _TrackInfoEditorDialogState {
  Widget _buildMetadataPolicyTab() {
    final info = _fileInfo;
    final policy = info?.metaPolicy ?? MetadataPolicy.inherit;
    final effectivePolicy = info?.effectivePolicy ?? MetadataPolicy.file;
    final eff = info?.effectiveLayer;
    final file = info?.fileLayer;
    final cloud = info?.cloudLayer;

    final effLabel = switch (effectivePolicy) {
      MetadataPolicy.inherit => '跟隨全域設定',
      MetadataPolicy.file => '優先使用本地檔案標籤',
      MetadataPolicy.cloud => '優先使用雲端資料',
    };

    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 6, right: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '決定本地音訊檔案內嵌標籤與雲端匹配資料的優先順序（實際生效：$effLabel）。任何手動編輯一律優先於兩者。',
            style: const TextStyle(
              color: LuminaTokens.textSecondary,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          for (final candidate in MetadataPolicy.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  key: Key('policy_option_${candidate.toJson()}'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: _busy ? null : () => _applyTrackMetaPolicy(candidate),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 11,
                    ),
                    decoration: BoxDecoration(
                      color: policy == candidate
                          ? LuminaTokens.accentBlue.withValues(alpha: 0.16)
                          : LuminaTokens.cardElevatedBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: policy == candidate
                            ? LuminaTokens.accentBlue
                            : LuminaTokens.borderSubtle,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          policy == candidate
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_off_rounded,
                          color: policy == candidate
                              ? LuminaTokens.accentBlue
                              : LuminaTokens.textMuted,
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                switch (candidate) {
                                  MetadataPolicy.inherit => '跟隨全域設定',
                                  MetadataPolicy.file => '優先使用本地檔案標籤',
                                  MetadataPolicy.cloud => '優先使用雲端資料',
                                },
                                style: const TextStyle(
                                  color: LuminaTokens.textPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                switch (candidate) {
                                  MetadataPolicy.inherit =>
                                    '沿用曲庫設定中的預設詮釋資料優先權',
                                  MetadataPolicy.file =>
                                    '優先採用音訊檔案中的內嵌標籤（缺少欄位才由雲端補齊）',
                                  MetadataPolicy.cloud =>
                                    '優先採用雲端識別的權威詮釋資料（缺少欄位才由本地補齊）',
                                },
                                style: const TextStyle(
                                  color: LuminaTokens.textMuted,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (eff != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: LuminaTokens.cardElevatedBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: LuminaTokens.borderSubtle),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '即時顯示預覽',
                        style: TextStyle(
                          color: LuminaTokens.textPrimary,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      if (info?.hasUserEdits == true)
                        const Text(
                          '包含手動覆寫層',
                          style: TextStyle(
                            color: LuminaTokens.accentBlue,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _PolicyDiffLine('曲目標題', eff.title, file?.title, cloud?.title),
                  _PolicyDiffLine(
                    '藝術家',
                    eff.artistName,
                    file?.artistName,
                    cloud?.artistName,
                  ),
                  _PolicyDiffLine(
                    '年份',
                    eff.releaseYear?.toString(),
                    file?.releaseYear?.toString(),
                    cloud?.releaseYear?.toString(),
                  ),
                  _PolicyDiffLine('曲風', eff.genre, file?.genre, cloud?.genre),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PolicyDiffLine extends StatelessWidget {
  final String label;
  final String? effective;
  final String? fileVal;
  final String? cloudVal;

  const _PolicyDiffLine(
    this.label,
    this.effective,
    this.fileVal,
    this.cloudVal,
  );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: const TextStyle(color: LuminaTokens.textMuted, fontSize: 11.5),
            ),
          ),
          Expanded(
            child: Text(
              '生效：${effective ?? '—'}  |  本地：${fileVal ?? '—'}  |  雲端：${cloudVal ?? '—'}',
              style: const TextStyle(
                color: LuminaTokens.textSecondary,
                fontSize: 11.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
